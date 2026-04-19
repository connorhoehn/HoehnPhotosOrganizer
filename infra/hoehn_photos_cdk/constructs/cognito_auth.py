"""
cognito_auth.py — Cognito User Pool construct for HoehnPhotos authentication.

Design decisions:
- Invite-only: selfSignUpEnabled=False. Connor creates users via the AWS
  console or CLI. This is a personal/family app, not a public service.
- Email-only sign-in: no username aliases. All users authenticate with email.
- Auto-verify email: since users are admin-created, skip email verification.
- Pre-signup Lambda trigger: auto-confirms users so admin-created users are
  immediately active without requiring a confirmation step.
- Pre-token-generation Lambda trigger: injects custom claims (custom:role,
  permVersion) into Cognito-issued tokens so API handlers can authorize
  requests without a secondary database lookup.
- RETAIN removal policy: never accidentally destroy the user pool.
- Password policy: 8+ chars, uppercase, lowercase, digits (no symbols required).
"""

import os

from constructs import Construct
from aws_cdk import (
    RemovalPolicy,
    Duration,
    aws_cognito as cognito,
    aws_lambda as lambda_,
)

# Path to the lambdas/ directory, relative to this file. Matches the pattern
# used in stacks/sync_stack.py so _shared/ gets bundled alongside the handler.
_LAMBDAS_DIR = os.path.join(os.path.dirname(__file__), "..", "lambdas")


# Inline Python code for the pre-signup auto-confirm trigger.
_AUTO_CONFIRM_CODE = """\
def handler(event, context):
    event["response"]["autoConfirmUser"] = True
    if "email" in event["request"].get("userAttributes", {}):
        event["response"]["autoVerifyEmail"] = True
    return event
"""


class HoehnPhotosCognitoAuth(Construct):
    """
    Cognito User Pool and App Client for HoehnPhotos authentication.

    This construct is consumed by SyncStack, which attaches a
    CognitoUserPoolsAuthorizer to the API Gateway.

    Properties:
        user_pool:            the underlying cognito.UserPool
        user_pool_client:     the underlying cognito.UserPoolClient
        user_pool_id:         resolved CloudFormation user pool ID
        user_pool_client_id:  resolved CloudFormation client ID
    """

    def __init__(self, scope: Construct, id: str, **kwargs) -> None:
        super().__init__(scope, id, **kwargs)

        # ── Pre-Signup Lambda Trigger ──────────────────────────────────────
        # Auto-confirms admin-created users so they are immediately active.
        auto_confirm_fn = lambda_.Function(
            self,
            "AutoConfirmUser",
            runtime=lambda_.Runtime.PYTHON_3_12,
            handler="index.handler",
            code=lambda_.Code.from_inline(_AUTO_CONFIRM_CODE),
            description=(
                "Pre-signup trigger that auto-confirms users created via "
                "admin CLI / console. HoehnPhotos is invite-only."
            ),
            timeout=Duration.seconds(10),
            memory_size=128,
        )

        # ── Cognito User Pool ─────────────────────────────────────────────
        self._user_pool = cognito.UserPool(
            self,
            "UserPool",
            user_pool_name="hoehn-photos-users",
            self_sign_up_enabled=False,
            sign_in_aliases=cognito.SignInAliases(email=True),
            auto_verify=cognito.AutoVerifiedAttrs(email=True),
            sign_in_case_sensitive=False,
            password_policy=cognito.PasswordPolicy(
                min_length=8,
                require_lowercase=True,
                require_uppercase=True,
                require_digits=True,
                require_symbols=False,
            ),
            lambda_triggers=cognito.UserPoolTriggers(
                pre_sign_up=auto_confirm_fn,
            ),
            removal_policy=RemovalPolicy.RETAIN,
        )

        # ── Pre-Token-Generation Lambda Trigger ────────────────────────────
        # Injects custom claims (custom:role, permVersion) into access/ID
        # tokens at issuance time. Handler lives in
        # lambdas/pre_token_generation.py and shares authz helpers with the
        # API handler Lambdas via lambdas/_shared/ (auto-included by the
        # Code.from_asset bundle).
        self._pre_token_generation_fn = lambda_.Function(
            self,
            "PreTokenGenerationFunction",
            runtime=lambda_.Runtime.PYTHON_3_12,
            handler="pre_token_generation.handler",
            code=lambda_.Code.from_asset(_LAMBDAS_DIR),
            description=(
                "Cognito pre-token-generation trigger. Injects custom:role "
                "and permVersion claims into issued tokens so API handlers "
                "can authorize without a secondary lookup."
            ),
            timeout=Duration.seconds(5),
            memory_size=128,
        )

        # Attach the function as the PRE_TOKEN_GENERATION trigger. Using
        # add_trigger (instead of the lambda_triggers kwarg above) keeps the
        # pre-signup trigger wiring untouched and avoids re-creating the
        # user pool.
        self._user_pool.add_trigger(
            cognito.UserPoolOperation.PRE_TOKEN_GENERATION,
            self._pre_token_generation_fn,
        )

        # ── User Pool Client ─────────────────────────────────────────────
        self._user_pool_client = self._user_pool.add_client(
            "AppClient",
            user_pool_client_name="hoehn-photos-app",
            auth_flows=cognito.AuthFlow(
                user_password=True,
                user_srp=True,
            ),
            prevent_user_existence_errors=True,
            access_token_validity=Duration.minutes(60),
            refresh_token_validity=Duration.days(30),
        )

    # ── Public Properties ─────────────────────────────────────────────────

    @property
    def user_pool(self) -> cognito.UserPool:
        """The Cognito User Pool resource."""
        return self._user_pool

    @property
    def user_pool_client(self) -> cognito.UserPoolClient:
        """The Cognito User Pool Client resource."""
        return self._user_pool_client

    @property
    def user_pool_id(self) -> str:
        """CloudFormation-resolved User Pool ID for outputs / env vars."""
        return self._user_pool.user_pool_id

    @property
    def user_pool_client_id(self) -> str:
        """CloudFormation-resolved Client ID for outputs / env vars."""
        return self._user_pool_client.user_pool_client_id

    @property
    def pre_token_generation_fn(self) -> lambda_.Function:
        """The pre-token-generation trigger Lambda, exposed for stack outputs."""
        return self._pre_token_generation_fn
