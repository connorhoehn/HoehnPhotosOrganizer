"""
authz.py - Shared authorization module for HoehnPhotosOrganizer Lambda handlers.

Provides three things handlers need:

  1. `extract_principal(event)` - Pull userId, email, role, groups, and
     permVersion out of a Lambda event. Prefers the claims that API Gateway's
     Cognito authorizer already injected at
     `event.requestContext.authorizer.claims`; falls back to verifying a raw
     Authorization bearer token against the Cognito user pool's JWKS.

  2. `Policy.can(principal, action, resource, ctx)` - A small, pure-Python
     re-expression of the concept used by the VNL backend's CASL abilities
     (see videonowandlater/backend/src/lib/abilities.ts). We deliberately do
     NOT pull in CASL or MongoDB-style condition objects; the rule set for
     this app is narrow enough that simple Python predicates are clearer.

  3. `require(principal, action, resource, ctx)` - Raises HTTPForbidden when
     a caller isn't allowed. Also exposes HTTPForbidden itself so handlers
     can catch it and map to an API Gateway 403 response whose shape matches
     the existing `_error_response` helper in album_handler.py et al.

Design notes
------------
- JWKS is fetched lazily and cached at module scope so warm Lambda invocations
  re-use it. The PyJWT `PyJWKClient` performs its own caching too; we wrap it
  so callers don't have to know about that detail.
- `Policy` is deliberately stateless and network-free so it can be unit tested
  without Cognito, DynamoDB, or HTTP stubs.
- Roles are kept as plain strings ("admin" | "owner" | "member" | "viewer" |
  "guest") for parity with claim values. Resources are strings as well
  ("Album" | "Photo" | "Person" | "Face" | "Thread" | "ShareLink").
- `ctx` is a plain dict passed to `can()`. Ownership checks look up
  `ctx["owner_id"]` / `ctx["member_ids"]` / `ctx["share_link_token"]` -
  handlers populate these from the row they just loaded from DynamoDB.

Environment variables
---------------------
- COGNITO_USER_POOL_ID - e.g. "us-east-1_AbCdEfGhI"
- AWS_REGION            - e.g. "us-east-1" (AWS_REGION is set automatically
                          in every Lambda runtime)
- COGNITO_APP_CLIENT_ID - optional; if set we additionally verify the `aud`
                          (for id tokens) or `client_id` (for access tokens)
                          claim matches.
"""

from __future__ import annotations

import json
import logging
import os
import re
from dataclasses import dataclass, field
from typing import Any, Iterable

import jwt
from jwt import PyJWKClient

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------


class HTTPForbidden(Exception):
    """
    Raised when a principal isn't allowed to perform an action on a resource.

    Carries `status_code = 403` and `to_response()` which matches the shape
    produced by `_error_response` in the existing Lambda handlers:

        {
            "statusCode": 403,
            "headers": {"Content-Type": "application/json"},
            "body": '{"error": "..."}'
        }
    """

    status_code: int = 403

    def __init__(self, message: str = "Forbidden") -> None:
        super().__init__(message)
        self.message = message

    def to_response(self) -> dict[str, Any]:
        return {
            "statusCode": self.status_code,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": self.message}),
        }


class HTTPUnauthorized(Exception):
    """Raised when the caller's identity can't be established at all (401)."""

    status_code: int = 401

    def __init__(self, message: str = "Unauthorized") -> None:
        super().__init__(message)
        self.message = message

    def to_response(self) -> dict[str, Any]:
        return {
            "statusCode": self.status_code,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": self.message}),
        }


# ---------------------------------------------------------------------------
# Principal
# ---------------------------------------------------------------------------


VALID_ROLES: tuple[str, ...] = ("admin", "owner", "member", "viewer", "guest")


@dataclass
class Principal:
    """The authenticated (or anonymous-guest) caller of a request."""

    user_id: str
    email: str | None
    role: str  # one of VALID_ROLES
    groups: list[str] = field(default_factory=list)
    perm_version: int = 0

    @property
    def is_admin(self) -> bool:
        return self.role == "admin"

    @property
    def is_guest(self) -> bool:
        return self.role == "guest"


# ---------------------------------------------------------------------------
# Claim extraction
# ---------------------------------------------------------------------------


_BEARER_RE = re.compile(r"^Bearer\s+(.+)$", re.IGNORECASE)

# Module-level cache of PyJWKClient. Lambda containers can live 15 minutes+
# and JWKS rotates rarely, so this is a meaningful warm-start win.
_jwks_client: PyJWKClient | None = None
_jwks_issuer: str | None = None


def _get_jwks_client() -> tuple[PyJWKClient, str]:
    """Return a cached PyJWKClient plus the expected issuer string."""
    global _jwks_client, _jwks_issuer

    if _jwks_client is not None and _jwks_issuer is not None:
        return _jwks_client, _jwks_issuer

    region = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION")
    user_pool_id = os.environ.get("COGNITO_USER_POOL_ID")
    if not region or not user_pool_id:
        raise HTTPUnauthorized(
            "JWT verification is not configured: "
            "set COGNITO_USER_POOL_ID and AWS_REGION."
        )

    issuer = f"https://cognito-idp.{region}.amazonaws.com/{user_pool_id}"
    jwks_url = f"{issuer}/.well-known/jwks.json"
    # PyJWKClient fetches lazily and keeps its own per-kid cache.
    _jwks_client = PyJWKClient(jwks_url, cache_keys=True)
    _jwks_issuer = issuer
    return _jwks_client, issuer


def _verify_bearer_token(token: str) -> dict[str, Any]:
    """Verify a raw Cognito JWT and return its claims dict."""
    client, issuer = _get_jwks_client()
    try:
        signing_key = client.get_signing_key_from_jwt(token).key
    except Exception as exc:  # noqa: BLE001 - any JWKS failure -> 401
        logger.warning("JWKS lookup failed: %s", exc)
        raise HTTPUnauthorized("Invalid token") from exc

    # Cognito tokens are RS256. `aud` differs between id tokens (has `aud`)
    # and access tokens (has `client_id`), so we verify audience manually
    # when COGNITO_APP_CLIENT_ID is set.
    app_client_id = os.environ.get("COGNITO_APP_CLIENT_ID")
    options = {"verify_aud": False}

    try:
        claims = jwt.decode(
            token,
            signing_key,
            algorithms=["RS256"],
            issuer=issuer,
            options=options,
        )
    except jwt.PyJWTError as exc:
        logger.warning("JWT verification failed: %s", exc)
        raise HTTPUnauthorized(f"Invalid token: {exc}") from exc

    if app_client_id:
        token_use = claims.get("token_use")
        if token_use == "id" and claims.get("aud") != app_client_id:
            raise HTTPUnauthorized("Token audience mismatch")
        if token_use == "access" and claims.get("client_id") != app_client_id:
            raise HTTPUnauthorized("Token client_id mismatch")

    return claims


def _extract_claims(event: dict[str, Any]) -> dict[str, Any]:
    """Pull claims from API Gateway, or verify a bearer token, or raise 401."""
    request_ctx = event.get("requestContext") or {}
    authorizer = request_ctx.get("authorizer") or {}
    # REST API (proxy integration) puts claims here. HTTP API v2 with a JWT
    # authorizer uses authorizer.jwt.claims; we handle both.
    claims = authorizer.get("claims")
    if not claims:
        jwt_section = authorizer.get("jwt") or {}
        claims = jwt_section.get("claims")

    if isinstance(claims, dict) and claims:
        return claims

    # Fallback: verify a raw bearer token ourselves.
    headers = event.get("headers") or {}
    auth_header = headers.get("Authorization") or headers.get("authorization") or ""
    match = _BEARER_RE.match(auth_header)
    if not match:
        raise HTTPUnauthorized("Missing bearer token")

    return _verify_bearer_token(match.group(1))


def _as_groups(raw: Any) -> list[str]:
    """Cognito returns groups as list OR comma-separated string depending on path."""
    if raw is None:
        return []
    if isinstance(raw, list):
        return [str(g) for g in raw]
    if isinstance(raw, str):
        # Handle both "a,b,c" and "[a b c]" (space-separated, no commas).
        stripped = raw.strip().strip("[]")
        if not stripped:
            return []
        parts: Iterable[str]
        if "," in stripped:
            parts = stripped.split(",")
        else:
            parts = stripped.split()
        return [p.strip() for p in parts if p.strip()]
    return []


def _role_from_claims(claims: dict[str, Any], groups: list[str]) -> str:
    """Prefer explicit custom:role; else derive from groups with admin>owner>member>viewer."""
    explicit = claims.get("custom:role")
    if isinstance(explicit, str) and explicit in VALID_ROLES:
        return explicit

    # Ordered check so highest privilege wins when a user is in multiple groups.
    for role in ("admin", "owner", "member", "viewer"):
        if role in groups:
            return role

    # Authenticated Cognito users without any group default to viewer.
    return "viewer"


def extract_principal(event: dict[str, Any]) -> Principal:
    """
    Derive the current Principal from an API Gateway Lambda event.

    Order of precedence:
      1. `event.requestContext.authorizer.claims` (REST API Cognito authorizer)
      2. `event.requestContext.authorizer.jwt.claims` (HTTP API v2 JWT authorizer)
      3. `Authorization: Bearer <jwt>` header verified against Cognito JWKS.

    Raises HTTPUnauthorized if no valid identity can be established.
    """
    claims = _extract_claims(event)

    user_id = (
        claims.get("sub")
        or claims.get("cognito:username")
        or claims.get("username")
        or ""
    )
    if not user_id:
        raise HTTPUnauthorized("Missing user identity")

    email = claims.get("email")
    if not isinstance(email, str) or not email:
        email = None

    groups = _as_groups(claims.get("cognito:groups"))
    role = _role_from_claims(claims, groups)

    # permVersion is stored as a string in the Cognito claim (see
    # pre_token_generation.py) - coerce defensively.
    perm_version_raw = claims.get("permVersion", 0)
    try:
        perm_version = int(perm_version_raw)
    except (TypeError, ValueError):
        perm_version = 0

    return Principal(
        user_id=str(user_id),
        email=email,
        role=role,
        groups=groups,
        perm_version=perm_version,
    )


# ---------------------------------------------------------------------------
# Policy
# ---------------------------------------------------------------------------


VALID_ACTIONS: tuple[str, ...] = ("read", "write", "delete", "invite")
VALID_RESOURCES: tuple[str, ...] = (
    "Album",
    "Photo",
    "Person",
    "Face",
    "Thread",
    "ShareLink",
)


class Policy:
    """
    Authorization rules, translated from the CASL `defineAbilityFor` concept
    in videonowandlater/backend/src/lib/abilities.ts.

    Rule summary
    ------------
    - admin  : every action on every resource.
    - owner  : manage (read/write/delete/invite) Albums / Photos / People /
               Faces / Threads / ShareLinks they own. Ownership is decided
               by `ctx["owner_id"] == principal.user_id`.
    - member : read any resource that lists them in `ctx["member_ids"]`, and
               may *write* Photos into an Album they're a member of (i.e.
               contribute). Cannot delete, cannot invite.
    - viewer : read-only access to resources they're a member of.
    - guest  : read-only, and ONLY when a valid share-link context is
               supplied (`ctx["share_link_token"]` truthy, `ctx["resource_type"]`
               compatible). Used for the public /a/{token} endpoint.

    The class is pure: `can()` performs no I/O, so callers are responsible
    for populating `ctx` with whatever ownership / membership info they've
    already fetched from DynamoDB.
    """

    # ---- Public API ------------------------------------------------------

    def can(
        self,
        principal: Principal,
        action: str,
        resource: str,
        ctx: dict[str, Any] | None = None,
    ) -> bool:
        if action not in VALID_ACTIONS:
            logger.debug("Unknown action %r - denying.", action)
            return False
        if resource not in VALID_RESOURCES:
            logger.debug("Unknown resource %r - denying.", resource)
            return False

        ctx = ctx or {}

        # Admin short-circuit.
        if principal.role == "admin":
            return True

        if principal.role == "owner":
            return self._owner_can(principal, action, resource, ctx)

        if principal.role == "member":
            return self._member_can(principal, action, resource, ctx)

        if principal.role == "viewer":
            return self._viewer_can(principal, action, resource, ctx)

        if principal.role == "guest":
            return self._guest_can(action, resource, ctx)

        # Unknown role - fail closed.
        return False

    # ---- Role-specific helpers ------------------------------------------

    @staticmethod
    def _is_owner(principal: Principal, ctx: dict[str, Any]) -> bool:
        owner_id = ctx.get("owner_id")
        return bool(owner_id) and owner_id == principal.user_id

    @staticmethod
    def _is_member(principal: Principal, ctx: dict[str, Any]) -> bool:
        member_ids = ctx.get("member_ids") or []
        if not isinstance(member_ids, (list, tuple, set)):
            return False
        return principal.user_id in member_ids

    def _owner_can(
        self,
        principal: Principal,
        action: str,
        resource: str,
        ctx: dict[str, Any],
    ) -> bool:
        # An "owner" role holder still has to actually own *this* resource.
        # If no ownership context is supplied at all (e.g. `can(owner,
        # "write", "Album")` to check "can this user create an album?"),
        # we allow write/read but not delete/invite - they need a concrete
        # target.
        if self._is_owner(principal, ctx):
            return True  # owner of the resource - full control
        if not ctx:
            # Subject-level check with no concrete resource: owners can
            # read their own listings and create new items.
            return action in ("read", "write")
        # Owner role but not owner of this specific resource -> fall back
        # to member/viewer rules if applicable.
        if self._is_member(principal, ctx):
            return self._member_can(principal, action, resource, ctx)
        return False

    def _member_can(
        self,
        principal: Principal,
        action: str,
        resource: str,
        ctx: dict[str, Any],
    ) -> bool:
        if not self._is_member(principal, ctx) and not self._is_owner(principal, ctx):
            return False
        if action == "read":
            return True
        if action == "write" and resource == "Photo":
            # Members can contribute photos to albums they're in.
            return True
        # Members cannot delete or invite.
        return False

    def _viewer_can(
        self,
        principal: Principal,
        action: str,
        resource: str,  # noqa: ARG002 - symmetry with other role helpers
        ctx: dict[str, Any],
    ) -> bool:
        if action != "read":
            return False
        return self._is_member(principal, ctx) or self._is_owner(principal, ctx)

    @staticmethod
    def _guest_can(action: str, resource: str, ctx: dict[str, Any]) -> bool:
        # Guests only ever read, and only through an active share link.
        if action != "read":
            return False
        token = ctx.get("share_link_token")
        if not token:
            return False
        # Share links gate access to Albums + their Photos only.
        return resource in ("Album", "Photo", "ShareLink")


# ---------------------------------------------------------------------------
# Convenience
# ---------------------------------------------------------------------------


_default_policy = Policy()


def require(
    principal: Principal,
    action: str,
    resource: str,
    ctx: dict[str, Any] | None = None,
    policy: Policy | None = None,
) -> None:
    """
    Raise HTTPForbidden if `principal` isn't permitted to perform `action`
    on `resource`. `ctx` is passed through to `Policy.can()`.
    """
    policy = policy or _default_policy
    if not policy.can(principal, action, resource, ctx):
        logger.info(
            "Forbidden: user=%s role=%s action=%s resource=%s",
            principal.user_id,
            principal.role,
            action,
            resource,
        )
        raise HTTPForbidden(f"Forbidden: cannot {action} {resource}")


# ---------------------------------------------------------------------------
# Usage example (for docs; does not run in Lambda)
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    # Example 1: extracting a principal from an API-Gateway event that already
    # has Cognito authorizer claims attached.
    fake_event = {
        "requestContext": {
            "authorizer": {
                "claims": {
                    "sub": "user-123",
                    "email": "connor@example.com",
                    "cognito:groups": ["owner"],
                    "custom:role": "owner",
                    "permVersion": "1737158400",
                }
            }
        },
        "headers": {},
    }
    me = extract_principal(fake_event)
    logger.info("Principal: %s", me)

    # Example 2: checking permissions with the Policy class. No I/O.
    p = Policy()
    album_ctx = {"owner_id": "user-123"}
    assert p.can(me, "write", "Album", album_ctx) is True
    assert p.can(me, "delete", "Album", {"owner_id": "someone-else"}) is False

    # Example 3: require() raises HTTPForbidden, which carries a
    # ready-to-return API-Gateway response body.
    guest = Principal(
        user_id="anon", email=None, role="guest", groups=[], perm_version=0
    )
    try:
        require(guest, "write", "Album", {"owner_id": "user-123"})
    except HTTPForbidden as exc:
        logger.info("Got expected 403: %s", exc.to_response())
