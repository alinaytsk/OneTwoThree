"""The current user of an API request.

The frontend signs in with Cognito directly and sends the ID token as `Authorization: Bearer`.
Checking that token is `app.auth_tokens`' job - it has no FastAPI and no database behind it, so
the agenda parser Lambda can reuse it outside the VPC. This module turns it into a dependency
and maps the account onto a row in `users`.
"""

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.orm import Session

from app.auth_tokens import Identity, TokenError, signing_keys
from app.auth_tokens import verify_id_token as check_id_token
from app.config import settings
from app.db import get_db
from app.models import User
from app.services import users as users_service

# Re-exported so callers (and tests) keep reaching them through app.auth.
__all__ = ["Identity", "LOCAL_IDENTITY", "bearer", "get_current_user", "signing_keys", "verify_id_token"]

bearer = HTTPBearer(auto_error=False, description="Cognito ID token")

# Everyone is this user while auth is disabled (no Cognito pool configured).
LOCAL_IDENTITY = Identity(sub="local-dev", email="dev@localhost", name="Local developer")


def unauthorized(detail: str) -> HTTPException:
    return HTTPException(status.HTTP_401_UNAUTHORIZED, detail, headers={"WWW-Authenticate": "Bearer"})


def verify_id_token(token: str) -> Identity:
    try:
        return check_id_token(token)
    except TokenError as exc:
        raise unauthorized(str(exc)) from exc


def get_current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer),
    db: Session = Depends(get_db),
) -> User:
    if not settings.auth_enabled:
        identity = LOCAL_IDENTITY
    elif credentials is None:
        raise unauthorized("Sign in required")
    else:
        identity = verify_id_token(credentials.credentials)
    return users_service.get_or_create(db, identity.sub, identity.email, identity.name)
