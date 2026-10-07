from datetime import datetime, timedelta, timezone
from functools import lru_cache
from typing import Any
from urllib.parse import urlencode

import httpx
import jwt
from google.auth.transport.requests import Request
from google.oauth2 import id_token
from jwt import PyJWKClient
from jwt.exceptions import InvalidTokenError, PyJWKClientError

from app.core.config import settings


class ProviderAuthenticationError(Exception):
    pass


def google_authorization_url(
    state: str,
    nonce: str,
    code_challenge: str,
) -> str:
    settings.require_google_config()
    query = urlencode(
        {
            "client_id": settings.google_client_id,
            "redirect_uri": settings.google_redirect_uri,
            "response_type": "code",
            "scope": "openid email profile",
            "state": state,
            "nonce": nonce,
            "code_challenge": code_challenge,
            "code_challenge_method": "S256",
        }
    )
    return f"{settings.google_authorization_url}?{query}"


def apple_authorization_url(state: str, nonce: str) -> str:
    settings.require_apple_config()
    query = urlencode(
        {
            "client_id": settings.apple_client_id,
            "redirect_uri": settings.apple_redirect_uri,
            "response_type": "code",
            "scope": "name email",
            "response_mode": "form_post",
            "state": state,
            "nonce": nonce,
        }
    )
    return f"{settings.apple_authorization_url}?{query}"


def _post_form(url: str, data: dict[str, Any]) -> dict[str, Any]:
    try:
        response = httpx.post(
            url,
            data=data,
            timeout=10.0,
        )
        response.raise_for_status()
        payload = response.json()
    except (httpx.HTTPError, ValueError) as exc:
        raise ProviderAuthenticationError(
            "Authorization server request failed."
        ) from exc

    if not isinstance(payload, dict):
        raise ProviderAuthenticationError(
            "Authorization server returned invalid data."
        )

    if payload.get("error"):
        raise ProviderAuthenticationError("Authorization server rejected the request.")

    return payload


def exchange_google_code(
    code: str,
    code_verifier: str,
    redirect_uri: str,
) -> dict[str, Any]:
    settings.require_google_config()
    payload = _post_form(
        settings.google_token_url,
        {
            "code": code,
            "client_id": settings.google_client_id,
            "client_secret": settings.google_client_secret,
            "redirect_uri": redirect_uri,
            "grant_type": "authorization_code",
            "code_verifier": code_verifier,
        },
    )
    if not payload.get("id_token"):
        raise ProviderAuthenticationError("Google did not return an ID token.")
    return payload


def verify_google_id_token(
    token: str,
    expected_nonce: str,
) -> dict[str, Any]:
    settings.require_google_config()

    try:
        claims = id_token.verify_oauth2_token(
            token,
            Request(),
            settings.google_client_id,
        )
    except ValueError as exc:
        raise ProviderAuthenticationError(
            "Google ID token validation failed."
        ) from exc

    if claims.get("iss") not in (
        settings.google_issuer,
        "accounts.google.com",
    ):
        raise ProviderAuthenticationError("Invalid Google token issuer.")

    if claims.get("nonce") != expected_nonce:
        raise ProviderAuthenticationError("Invalid Google token nonce.")

    if not claims.get("sub"):
        raise ProviderAuthenticationError("Google token has no subject.")

    return claims


def generate_apple_client_secret() -> str:
    settings.require_apple_config()
    now = datetime.now(timezone.utc)
    max_ttl = 15_552_000
    ttl = min(settings.apple_client_secret_ttl_seconds, max_ttl)

    claims = {
        "iss": settings.apple_team_id,
        "iat": now,
        "exp": now + timedelta(seconds=ttl),
        "aud": settings.apple_issuer,
        "sub": settings.apple_client_id,
    }

    return jwt.encode(
        claims,
        settings.get_apple_private_key(),
        algorithm="ES256",
        headers={"kid": settings.apple_key_id},
    )


def exchange_apple_code(
    code: str,
    redirect_uri: str,
) -> dict[str, Any]:
    settings.require_apple_config()
    payload = _post_form(
        settings.apple_token_url,
        {
            "client_id": settings.apple_client_id,
            "client_secret": generate_apple_client_secret(),
            "code": code,
            "redirect_uri": redirect_uri,
            "grant_type": "authorization_code",
        },
    )
    if not payload.get("id_token"):
        raise ProviderAuthenticationError("Apple did not return an ID token.")
    return payload


@lru_cache
def get_apple_jwk_client() -> PyJWKClient:
    return PyJWKClient(
        settings.apple_jwks_url,
        cache_jwk_set=True,
        lifespan=300,
        cache_keys=True,
        timeout=5,
    )


def verify_apple_id_token(
    token: str,
    expected_nonce: str,
) -> dict[str, Any]:
    settings.require_apple_config()

    try:
        signing_key = get_apple_jwk_client().get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            signing_key,
            algorithms=["RS256"],
            audience=settings.apple_client_id,
            issuer=settings.apple_issuer,
            options={
                "require": [
                    "iss",
                    "aud",
                    "exp",
                    "iat",
                    "sub",
                ],
            },
        )
    except (InvalidTokenError, PyJWKClientError) as exc:
        raise ProviderAuthenticationError(
            "Apple ID token validation failed."
        ) from exc

    if claims.get("nonce") != expected_nonce:
        raise ProviderAuthenticationError("Invalid Apple token nonce.")

    return claims


def as_bool(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    return str(value).lower() == "true"


def claims_to_identity(
    claims: dict[str, Any],
) -> tuple[str, str | None, bool, str | None]:
    subject = str(claims["sub"])

    email = claims.get("email")
    email = (
        email.strip().lower()
        if isinstance(email, str) and email.strip()
        else None
    )

    email_verified = as_bool(claims.get("email_verified", False))
    name = claims.get("name")

    return subject, email, email_verified, name
