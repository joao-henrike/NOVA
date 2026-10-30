from datetime import UTC, datetime
from uuid import UUID

from sqlalchemy import delete, exists, select, update
from sqlalchemy.orm import Session, aliased

from app.models.auth import AuthIdentity, AuthProvider, OAuthState, RefreshToken
from app.models.user import User


def _as_utc(value: datetime) -> datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=UTC)
    return value.astimezone(UTC)


class AuthRepository:
    def get_identity(
        self,
        session: Session,
        *,
        provider: AuthProvider,
        provider_subject: str,
    ) -> AuthIdentity | None:
        return session.scalar(
            select(AuthIdentity).where(
                AuthIdentity.provider == provider,
                AuthIdentity.provider_subject == provider_subject,
            )
        )

    def get_user_by_email(self, session: Session, email: str) -> User | None:
        return session.scalar(
            select(User).where(User.email == email)
        )

    def create_user(
        self,
        session: Session,
        *,
        email: str | None,
        name: str | None,
        email_verified: bool,
    ) -> User:
        user = User(
            email=email,
            name=name,
            email_verified=email_verified,
        )
        session.add(user)
        session.flush()
        return user

    def create_identity(
        self,
        session: Session,
        *,
        user_id: UUID,
        provider: AuthProvider,
        provider_subject: str,
    ) -> AuthIdentity:
        identity = AuthIdentity(
            user_id=user_id,
            provider=provider,
            provider_subject=provider_subject,
        )
        session.add(identity)
        session.flush()
        return identity

    def save_oauth_state(
        self,
        session: Session,
        *,
        provider: AuthProvider,
        state: str,
        nonce: str,
        code_verifier: str | None,
        redirect_uri: str,
        expires_at: datetime,
    ) -> OAuthState:
        session.execute(
            delete(OAuthState).where(
                OAuthState.expires_at <= datetime.now(UTC)
            )
        )
        record = OAuthState(
            provider=provider,
            state=state,
            nonce=nonce,
            code_verifier=code_verifier,
            redirect_uri=redirect_uri,
            expires_at=expires_at,
        )
        session.add(record)
        session.commit()
        return record

    def consume_oauth_state(
        self,
        session: Session,
        *,
        provider: AuthProvider,
        state: str,
    ) -> OAuthState | None:
        record = session.scalar(
            select(OAuthState)
            .where(
                OAuthState.provider == provider,
                OAuthState.state == state,
            )
            .with_for_update()
        )

        if record is None:
            session.rollback()
            return None

        now = datetime.now(UTC)
        if _as_utc(record.expires_at) <= now:
            session.delete(record)
            session.commit()
            return None

        session.delete(record)
        session.commit()
        return record

    def prune_expired_refresh_families(
        self,
        session: Session,
        *,
        now: datetime,
        batch_size: int = 100,
    ) -> None:
        if batch_size < 1:
            raise ValueError("Refresh-token cleanup batch size must be positive.")

        expired_token = aliased(RefreshToken)
        unexpired_token = aliased(RefreshToken)
        expired_families = (
            select(expired_token.family_id)
            .where(expired_token.expires_at <= now)
            .where(
                ~exists(
                    select(1).where(
                        unexpired_token.family_id == expired_token.family_id,
                        unexpired_token.expires_at > now,
                    )
                )
            )
            .distinct()
            .limit(batch_size)
        )
        session.execute(
            delete(RefreshToken).where(
                RefreshToken.family_id.in_(expired_families)
            )
        )

    def create_refresh_token(
        self,
        session: Session,
        *,
        user_id: UUID,
        family_id: UUID,
        token_hash: str,
        expires_at: datetime,
        replaced_by_hash: str | None = None,
    ) -> RefreshToken:
        # Keep replay-detection history while any token in a family can still
        # be presented. Once every token has expired, the whole family is safe
        # to remove. Batching bounds the work on login and refresh requests.
        self.prune_expired_refresh_families(
            session,
            now=datetime.now(UTC),
        )
        record = RefreshToken(
            user_id=user_id,
            family_id=family_id,
            token_hash=token_hash,
            expires_at=expires_at,
            replaced_by_hash=replaced_by_hash,
        )
        session.add(record)
        session.flush()
        return record

    def get_refresh_token_for_update(
        self,
        session: Session,
        token_hash: str,
    ) -> RefreshToken | None:
        return session.scalar(
            select(RefreshToken)
            .where(RefreshToken.token_hash == token_hash)
            .with_for_update()
        )

    def revoke_refresh_token(
        self,
        record: RefreshToken,
        *,
        replaced_by_hash: str | None = None,
    ) -> None:
        record.revoked_at = datetime.now(UTC)
        record.replaced_by_hash = replaced_by_hash

    def has_active_refresh_family(
        self,
        session: Session,
        *,
        user_id: UUID,
        family_id: UUID,
    ) -> bool:
        statement = (
            select(RefreshToken.id)
            .where(
                RefreshToken.user_id == user_id,
                RefreshToken.family_id == family_id,
                RefreshToken.revoked_at.is_(None),
                RefreshToken.expires_at > datetime.now(UTC),
            )
            .limit(1)
        )
        return session.scalar(statement) is not None

    def revoke_family(self, session: Session, family_id: UUID) -> None:
        session.execute(
            update(RefreshToken)
            .where(
                RefreshToken.family_id == family_id,
                RefreshToken.revoked_at.is_(None),
            )
            .values(revoked_at=datetime.now(UTC))
        )
        session.commit()
