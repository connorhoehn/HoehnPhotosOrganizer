"""
Cognito Pre Token Generation trigger for HoehnPhotosOrganizer.

Ported from VNL's TypeScript handler:
    videonowandlater/backend/src/handlers/auth-pre-token.ts

Injects two custom claims into Cognito-issued tokens:
  - custom:role  -> 'admin' | 'moderator' | 'user'
                    Derived from the user's Cognito groups using a fixed
                    precedence (admin > moderator > user).
  - permVersion  -> unix-timestamp integer (seconds). Clients compare this
                    against the value baked into their cached permission
                    state; a mismatch forces a re-fetch of abilities so stale
                    caches can be invalidated without a deploy.

Idempotent and defensive: any exception is logged and the original event is
returned untouched so a bug in this trigger can never block authentication.

Runtime: Python 3.12, AWS Lambda. No external dependencies.
"""

from __future__ import annotations

import logging
import time
from typing import Any

logger = logging.getLogger()
logger.setLevel(logging.INFO)


# Precedence order: earlier entries win over later ones.
_ROLE_PRECEDENCE: tuple[str, ...] = ("admin", "moderator")
_DEFAULT_ROLE = "user"


def _derive_role(groups: Any) -> str:
    """Return the highest-precedence role present in `groups`, else 'user'."""
    if not isinstance(groups, list):
        return _DEFAULT_ROLE
    for role in _ROLE_PRECEDENCE:
        if role in groups:
            return role
    return _DEFAULT_ROLE


def handler(event: dict, context: Any) -> dict:  # noqa: ARG001 - Lambda signature
    """
    Cognito Pre Token Generation Lambda entrypoint.

    Always returns the event. On any unexpected error we log and return the
    event unmodified so token issuance is never blocked by this trigger.
    """
    try:
        request = event.get("request") or {}
        group_config = request.get("groupConfiguration") or {}
        groups = group_config.get("groupsToOverride") or []

        role = _derive_role(groups)
        perm_version = int(time.time())

        # Defensive: ensure response.claimsOverrideDetails.claimsToAddOrOverride
        # exists without clobbering anything Cognito or a prior step populated.
        response = event.get("response") or {}
        claims_override = response.get("claimsOverrideDetails") or {}
        claims_to_add = dict(claims_override.get("claimsToAddOrOverride") or {})

        claims_to_add["custom:role"] = role
        # Cognito claim values must be strings; coerce explicitly.
        claims_to_add["permVersion"] = str(perm_version)

        claims_override["claimsToAddOrOverride"] = claims_to_add
        response["claimsOverrideDetails"] = claims_override
        event["response"] = response

        logger.info(
            "Injected role claim",
            extra={
                "username": event.get("userName"),
                "role": role,
                "permVersion": perm_version,
                "groupsCount": len(groups) if isinstance(groups, list) else 0,
            },
        )
    except Exception as err:  # noqa: BLE001 - must never break auth
        # Never block token issuance on our claim-injection logic.
        logger.error(
            "Pre-token trigger failed (returning event untouched): %s",
            err,
            exc_info=True,
        )

    return event
