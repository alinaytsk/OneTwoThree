"""Cognito ID-token checking, with no FastAPI and no database behind it.

`app.auth` wraps this into the API's dependency; the agenda parser Lambda (outside the VPC,
without a database) imports it directly. Tokens are checked locally against the pool's signing
keys (JWKS), so no call to Cognito is made per request.
"""

import json
import urllib.request
from dataclasses import dataclass
from functools import lru_cache
from typing import Any

import jwt

from app.config import settings


@dataclass(frozen=True)
class Identity:
    sub: str
    email: str
    name: str | None


class TokenError(Exception):
    """The presented token is not a usable ID token of this user pool."""


@lru_cache
def signing_keys() -> dict[str, Any]:
    """Public keys of the user pool by key ID."""
    if settings.cognito_jwks:
        jwks = json.loads(settings.cognito_jwks)
    else:
        with urllib.request.urlopen(f"{settings.cognito_issuer}/.well-known/jwks.json", timeout=5) as resp:
            jwks = json.load(resp)
    return {key["kid"]: jwt.PyJWK(key).key for key in jwks["keys"]}


def verify_id_token(token: str) -> Identity:
    try:
        key = signing_keys().get(jwt.get_unverified_header(token).get("kid", ""))
        if key is None:
            raise TokenError("Unknown signing key")
        claims = jwt.decode(
            token,
            key,
            algorithms=["RS256"],
            audience=settings.cognito_client_id,
            issuer=settings.cognito_issuer,
            options={"require": ["exp", "iat", "sub", "aud", "iss"]},
        )
    except jwt.PyJWTError as exc:
        raise TokenError(f"Invalid token: {exc}") from exc
    if claims.get("token_use") != "id" or not claims.get("email"):
        raise TokenError("An ID token with an email is required")
    return Identity(sub=claims["sub"], email=claims["email"].lower(), name=claims.get("name"))
