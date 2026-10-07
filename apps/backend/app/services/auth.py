from datetime import UTC, datetime, timedelta
from uuid import uuid4

from fastapi import Response
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.security import (
    create_access_token,
    generate_refresh_token,
    hash_refresh_token,
)
from app.models.auth import AuthProvider
from app.models.user import User
from app.repositories.auth import AuthRepository
from app.services.providers import claims_to_identity


class AuthenticationError(Exception):
    pass


class AuthService:
    def __init__(self, repository: AuthRepository | None = None) -> None:
        self.repository = repository or AuthRepository()

    def create_oauth_state(
        self,
        session: Session,
        *,
        provider: AuthProvider,
        state: str,
        nonce: str,
        code_verifier: str | None,
        redirect_uri: str,
    ) -> None:
        self.repository.save_oauth_state(
            session,
            provider=provider,
            state=state,
            nonce=nonce,
            code_verifier=code_verifier,
            redirect_uri=redirect_uri,
            expires_at=datetime.now(UTC)
            + timedelta(seconds=settings.auth_state_ttl_seconds),
        )

    def consume_oauth_state(
        self,
        session: Session,
        *,
        provider: AuthProvider,
        state: str,
    ):
        return self.repository.consume_oauth_state(
            session,
            provider=provider,
            state=state,
        )

    def sign_in_from_claims(
        self,
        session: Session,
        *,
        provider: AuthProvider,
        claims: dict,
    ) -> User:
        subject, email, email_verified, name = claims_to_identity(claims)

        identity = self.repository.get_identity(
            session,
            provider=provider,
            provider_subject=subject,
        )

        if identity is not None:
            user = session.get(User, identity.user_id)
            if user is None or not user.is_active:
                raise AuthenticationError("User account is inactive.")

            if email and not user.email:
                user.email = email
            if email_verified and not user.email_verified:
                user.email_verified = True
            if name and not user.name:
                user.name = name

            try:
                session.commit()
            except IntegrityError as exc:
                session.rollback()
                raise AuthenticationError(
                    "Unable to update authentication account."
                ) from exc

            return user

        if email and self.repository.get_user_by_email(session, email):
            raise AuthenticationError(
                "An account already exists for this email. "
                "Explicit account linking is required."
            )

        try:
            user = self.repository.create_user(
                session,
                email=email,
                name=name,
                email_verified=email_verified,
            )
            self.repository.create_identity(
                session,
                user_id=user.id,
                provider=provider,
                provider_subject=subject,
            )
            session.commit()
            return user
        except IntegrityError as exc:
            session.rollback()
            raise AuthenticationError(
                "Unable to create authentication account."
            ) from exc

    def issue_session(
        self,
        session: Session,
        *,
        user: User,
    ) -> tuple[str, str, int]:
        access_token, expires_in = create_access_token(user.id)
        refresh_token = generate_refresh_token()

        self.repository.create_refresh_token(
            session,
            user_id=user.id,
            family_id=uuid4(),
            token_hash=hash_refresh_token(refresh_token),
            expires_at=datetime.now(UTC)
            + timedelta(days=settings.auth_refresh_token_ttl_days),
        )
        session.commit()
        return access_token, refresh_token, expires_in

    def set_refresh_cookie(
        self,
        response: Response,
        refresh_token: str,
    ) -> None:
        response.set_cookie(
            key="nova_refresh_token",
            value=refresh_token,
            httponly=True,
            secure=settings.auth_cookie_secure,
            samesite="lax",
            max_age=settings.auth_refresh_token_ttl_days * 86400,
            path="/api/auth",
        )

    def rotate_refresh_token(
        self,
        session: Session,
        *,
        refresh_token: str,
    ) -> tuple[User, str, str, int]:
        record = self.repository.get_refresh_token_for_update(
            session,
            hash_refresh_token(refresh_token),
        )

        if record is None:
            raise AuthenticationError("Invalid refresh token.")

        now = datetime.now(UTC)

        if record.revoked_at is not None:
            self.repository.revoke_family(session, record.family_id)
            raise AuthenticationError("Refresh token reuse detected.")

        expires_at = record.expires_at
        if expires_at.tzinfo is None:
            expires_at = expires_at.replace(tzinfo=UTC)
        else:
            expires_at = expires_at.astimezone(UTC)

        if expires_at <= now:
            self.repository.revoke_refresh_token(record)
            session.commit()
            raise AuthenticationError("Refresh token expired.")

        user = session.get(User, record.user_id)
        if user is None or not user.is_active:
            self.repository.revoke_refresh_token(record)
            session.commit()
            raise AuthenticationError("User account is inactive.")

        new_refresh = generate_refresh_token()
        new_hash = hash_refresh_token(new_refresh)

        self.repository.revoke_refresh_token(
            record,
            replaced_by_hash=new_hash,
        )
        self.repository.create_refresh_token(
            session,
            user_id=user.id,
            family_id=record.family_id,
            token_hash=new_hash,
            expires_at=now
            + timedelta(days=settings.auth_refresh_token_ttl_days),
        )

        access_token, expires_in = create_access_token(user.id)
        session.commit()

        return user, access_token, new_refresh, expires_in

    def logout(
        self,
        session: Session,
        refresh_token: str | None,
    ) -> None:
        if not refresh_token:
            return

        record = self.repository.get_refresh_token_for_update(
            session,
            hash_refresh_token(refresh_token),
        )
        if record is not None:
            self.repository.revoke_family(session, record.family_id)
