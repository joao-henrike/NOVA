import json
import secrets
from typing import Annotated
from urllib.parse import urlparse

from fastapi import (
    APIRouter,
    Cookie,
    Depends,
    Form,
    HTTPException,
    Query,
    Response,
    status,
)
from fastapi.responses import JSONResponse, RedirectResponse
from sqlalchemy.orm import Session

from app.api.dependencies import CurrentUser
from app.core.config import settings
from app.core.security import (
    create_pkce_challenge,
    create_pkce_verifier,
    is_safe_state_match,
)
from app.db.session import get_db
from app.models.auth import AuthProvider
from app.schemas.auth import RefreshRequest, TokenResponse, UserRead
from app.services.auth import AuthService, AuthenticationError
from app.services.providers import (
    ProviderAuthenticationError,
    apple_authorization_url,
    exchange_apple_code,
    exchange_google_code,
    google_authorization_url,
    verify_apple_id_token,
    verify_google_id_token,
)


router = APIRouter(prefix="/api/auth", tags=["auth"])
service = AuthService()


def _validate_redirect_uri(uri: str, *, apple: bool = False) -> None:
    parsed = urlparse(uri)

    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise RuntimeError("Authentication redirect URI must be an absolute HTTP(S) URL.")

    if parsed.fragment:
        raise RuntimeError("Authentication redirect URI must not contain a fragment.")

    if apple:
        if parsed.scheme != "https":
            raise RuntimeError("Apple web authentication requires HTTPS.")
        if parsed.hostname in {"localhost", "127.0.0.1", "::1"}:
            raise RuntimeError(
                "Apple web authentication requires a registered domain."
            )


def _start_login(
    provider: AuthProvider,
    db: Session,
) -> Response:
    state = secrets.token_urlsafe(32)
    nonce = secrets.token_urlsafe(32)

    if provider is AuthProvider.GOOGLE:
        settings.require_google_config()
        redirect_uri = settings.google_redirect_uri
        _validate_redirect_uri(redirect_uri)
        verifier = create_pkce_verifier()
        challenge = create_pkce_challenge(verifier)
        authorization_url = google_authorization_url(
            state,
            nonce,
            challenge,
        )
        samesite = "lax"
    else:
        settings.require_apple_config()
        redirect_uri = settings.apple_redirect_uri
        _validate_redirect_uri(redirect_uri, apple=True)
        verifier = None
        authorization_url = apple_authorization_url(state, nonce)
        samesite = "none"

    service.create_oauth_state(
        db,
        provider=provider,
        state=state,
        nonce=nonce,
        code_verifier=verifier,
        redirect_uri=redirect_uri,
    )

    redirect = RedirectResponse(
        authorization_url,
        status_code=status.HTTP_302_FOUND,
    )
    redirect.set_cookie(
        key=f"nova_oauth_state_{provider.value}",
        value=state,
        httponly=True,
        secure=settings.auth_cookie_secure,
        samesite=samesite,
        max_age=settings.auth_state_ttl_seconds,
        path="/api/auth",
    )
    return redirect


def _clear_state_cookie(response: Response, provider: AuthProvider) -> None:
    response.delete_cookie(
        key=f"nova_oauth_state_{provider.value}",
        path="/api/auth",
    )


def _authentication_response(
    *,
    response: Response,
    user_id,
    access_token: str,
    refresh_token: str,
    expires_in: int,
    provider: AuthProvider,
) -> JSONResponse:
    payload = TokenResponse(
        access_token=access_token,
        expires_in=expires_in,
        user_id=user_id,
    )
    result = JSONResponse(
        content=payload.model_dump(mode="json"),
        headers={"Cache-Control": "no-store"},
    )
    service.set_refresh_cookie(result, refresh_token)
    _clear_state_cookie(result, provider)
    return result


@router.get("/google/login", include_in_schema=False)
def google_login(db: Session = Depends(get_db)) -> Response:
    return _start_login(AuthProvider.GOOGLE, db)


@router.get("/google/callback", include_in_schema=False)
def google_callback(
    code: str | None = Query(default=None),
    state: str | None = Query(default=None),
    error: str | None = Query(default=None),
    oauth_cookie: str | None = Cookie(
        default=None,
        alias="nova_oauth_state_google",
    ),
    db: Session = Depends(get_db),
) -> JSONResponse:
    if error or not code or not state:
        raise HTTPException(
            status_code=400,
            detail="Google authentication was not completed.",
        )

    if oauth_cookie is None or not is_safe_state_match(oauth_cookie, state):
        raise HTTPException(status_code=400, detail="Invalid OAuth state.")

    state_record = service.consume_oauth_state(
        db,
        provider=AuthProvider.GOOGLE,
        state=state,
    )
    if state_record is None or not state_record.code_verifier:
        raise HTTPException(
            status_code=400,
            detail="Expired or invalid OAuth state.",
        )

    try:
        token_payload = exchange_google_code(
            code,
            state_record.code_verifier,
            state_record.redirect_uri,
        )
        claims = verify_google_id_token(
            token_payload["id_token"],
            state_record.nonce,
        )
        user = service.sign_in_from_claims(
            db,
            provider=AuthProvider.GOOGLE,
            claims=claims,
        )
        access_token, refresh_token, expires_in = service.issue_session(
            db,
            user=user,
        )
    except (ProviderAuthenticationError, AuthenticationError, RuntimeError) as exc:
        raise HTTPException(
            status_code=401,
            detail="Google authentication failed.",
        ) from exc

    return _authentication_response(
        response=Response(),
        user_id=user.id,
        access_token=access_token,
        refresh_token=refresh_token,
        expires_in=expires_in,
        provider=AuthProvider.GOOGLE,
    )


@router.get("/apple/login", include_in_schema=False)
def apple_login(db: Session = Depends(get_db)) -> Response:
    return _start_login(AuthProvider.APPLE, db)


@router.post("/apple/callback", include_in_schema=False)
def apple_callback(
    code: Annotated[str | None, Form()] = None,
    state: Annotated[str | None, Form()] = None,
    error: Annotated[str | None, Form()] = None,
    user_data: Annotated[str | None, Form(alias="user")] = None,
    oauth_cookie: str | None = Cookie(
        default=None,
        alias="nova_oauth_state_apple",
    ),
    db: Session = Depends(get_db),
) -> JSONResponse:
    if error or not code or not state:
        raise HTTPException(
            status_code=400,
            detail="Apple authentication was not completed.",
        )

    if oauth_cookie is None or not is_safe_state_match(oauth_cookie, state):
        raise HTTPException(status_code=400, detail="Invalid OAuth state.")

    state_record = service.consume_oauth_state(
        db,
        provider=AuthProvider.APPLE,
        state=state,
    )
    if state_record is None:
        raise HTTPException(
            status_code=400,
            detail="Expired or invalid OAuth state.",
        )

    try:
        token_payload = exchange_apple_code(
            code,
            state_record.redirect_uri,
        )
        claims = verify_apple_id_token(
            token_payload["id_token"],
            state_record.nonce,
        )

        if user_data:
            try:
                apple_user = json.loads(user_data)
            except json.JSONDecodeError:
                apple_user = {}

            if isinstance(apple_user, dict):
                if not claims.get("email") and isinstance(
                    apple_user.get("email"),
                    str,
                ):
                    claims["email"] = apple_user["email"]

                name_data = apple_user.get("name")
                if isinstance(name_data, dict):
                    first = name_data.get("firstName", "")
                    last = name_data.get("lastName", "")
                    full_name = " ".join(
                        part
                        for part in (first, last)
                        if isinstance(part, str) and part.strip()
                    ).strip()
                    if full_name and not claims.get("name"):
                        claims["name"] = full_name

        user = service.sign_in_from_claims(
            db,
            provider=AuthProvider.APPLE,
            claims=claims,
        )
        access_token, refresh_token, expires_in = service.issue_session(
            db,
            user=user,
        )
    except (ProviderAuthenticationError, AuthenticationError, RuntimeError) as exc:
        raise HTTPException(
            status_code=401,
            detail="Apple authentication failed.",
        ) from exc

    return _authentication_response(
        response=Response(),
        user_id=user.id,
        access_token=access_token,
        refresh_token=refresh_token,
        expires_in=expires_in,
        provider=AuthProvider.APPLE,
    )


@router.post("/refresh", response_model=TokenResponse)
def refresh(
    data: RefreshRequest,
    response: Response,
    refresh_cookie: str | None = Cookie(
        default=None,
        alias="nova_refresh_token",
    ),
    db: Session = Depends(get_db),
) -> TokenResponse:
    token = data.refresh_token or refresh_cookie
    if not token:
        raise HTTPException(status_code=401, detail="Refresh token required.")

    try:
        user, access_token, new_refresh, expires_in = service.rotate_refresh_token(
            db,
            refresh_token=token,
        )
    except AuthenticationError as exc:
        response.delete_cookie("nova_refresh_token", path="/api/auth")
        raise HTTPException(status_code=401, detail="Invalid refresh token.") from exc

    service.set_refresh_cookie(response, new_refresh)
    return TokenResponse(
        access_token=access_token,
        expires_in=expires_in,
        user_id=user.id,
    )


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
def logout(
    response: Response,
    refresh_cookie: str | None = Cookie(
        default=None,
        alias="nova_refresh_token",
    ),
    data: RefreshRequest | None = None,
    db: Session = Depends(get_db),
) -> None:
    token = (data.refresh_token if data else None) or refresh_cookie
    service.logout(db, token)
    response.delete_cookie("nova_refresh_token", path="/api/auth")


@router.get("/me", response_model=UserRead)
def me(current_user: CurrentUser) -> UserRead:
    return current_user
