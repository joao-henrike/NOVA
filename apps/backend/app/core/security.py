import base64
import hashlib
import secrets
from datetime import datetime, timedelta, timezone
from uuid import UUID, uuid4

import jwt
from fastapi import HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials
from jwt.exceptions import InvalidTokenError

from app.core.config import settings
from app.models.user import User


def create_pkce_verifier() -> str:
    return secrets.token_urlsafe(64)


def create_pkce_challenge(verifier: str) -> str:
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")


def hash_refresh_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def create_access_token(user_id: UUID) -> tuple[str, int]:
    secret = settings.require_auth_signing_key()
    now = datetime.now(timezone.utc)
    expires_in = settings.auth_access_token_ttl_minutes * 60

    payload = {
        "sub": str(user_id),
        "iss": settings.auth_token_issuer,
        "aud": settings.auth_token_audience,
        "iat": now,
        "nbf": now,
        "exp": now + timedelta(seconds=expires_in),
        "jti": str(uuid4()),
    }

    return (
        jwt.encode(payload, secret, algorithm="HS256"),
        expires_in,
    )


def decode_access_token(token: str) -> UUID:
    try:
        payload = jwt.decode(
            token,
            settings.require_auth_signing_key(),
            algorithms=["HS256"],
            issuer=settings.auth_token_issuer,
            audience=settings.auth_token_audience,
            options={
                "require": [
                    "sub",
                    "iss",
                    "aud",
                    "iat",
                    "nbf",
                    "exp",
                    "jti",
                ],
            },
        )
        return UUID(payload["sub"])
    except (InvalidTokenError, ValueError, RuntimeError) as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid authentication token",
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc


def require_bearer_token(
    credentials: HTTPAuthorizationCredentials | None,
) -> UUID:
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Authentication required",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return decode_access_token(credentials.credentials)


def generate_refresh_token() -> str:
    return secrets.token_urlsafe(64)


def is_safe_state_match(expected: str, received: str) -> bool:
    return secrets.compare_digest(expected, received)


def ensure_active_user(user: User | None) -> User:
    if user is None or not user.is_active:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="User is inactive or does not exist",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return user
