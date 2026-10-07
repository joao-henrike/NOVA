import unittest
from datetime import UTC, datetime, timedelta
from uuid import uuid4

from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.core.security import hash_refresh_token
from app.db.base import Base
from app.models.auth import AuthIdentity, AuthProvider, OAuthState, RefreshToken
from app.models.user import User
from app.services.auth import AuthenticationError, AuthService


class AuthServiceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.engine = create_engine(
            "sqlite+pysqlite:///:memory:",
            connect_args={"check_same_thread": False},
            poolclass=StaticPool,
        )
        Base.metadata.create_all(cls.engine)
        cls.session_factory = sessionmaker(
            bind=cls.engine,
            autoflush=False,
            expire_on_commit=False,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.engine.dispose()

    def setUp(self) -> None:
        self.auth = AuthService()

    def tearDown(self) -> None:
        with self.session_factory() as session:
            session.query(RefreshToken).delete(synchronize_session=False)
            session.query(OAuthState).delete(synchronize_session=False)
            session.query(AuthIdentity).delete(synchronize_session=False)
            session.query(User).delete(synchronize_session=False)
            session.commit()

    def test_provider_identity_is_created_and_reused(self) -> None:
        with self.session_factory() as session:
            first = self.auth.sign_in_from_claims(
                session,
                provider=AuthProvider.GOOGLE,
                claims={
                    "sub": "google-subject",
                    "email": "USER@example.com",
                    "email_verified": "true",
                    "name": "User",
                },
            )
            second = self.auth.sign_in_from_claims(
                session,
                provider=AuthProvider.GOOGLE,
                claims={
                    "sub": "google-subject",
                    "email": "user@example.com",
                    "email_verified": True,
                    "name": "Updated Name",
                },
            )

            self.assertEqual(first.id, second.id)
            identities = session.query(AuthIdentity).all()
            self.assertEqual(len(identities), 1)
            self.assertEqual(identities[0].provider_subject, "google-subject")

    def test_same_email_does_not_implicitly_link_accounts(self) -> None:
        with self.session_factory() as session:
            session.add(
                User(
                    email="existing@example.com",
                    name="Existing",
                    email_verified=True,
                )
            )
            session.commit()

            with self.assertRaises(AuthenticationError):
                self.auth.sign_in_from_claims(
                    session,
                    provider=AuthProvider.APPLE,
                    claims={
                        "sub": "apple-subject",
                        "email": "existing@example.com",
                        "email_verified": True,
                    },
                )

    def test_oauth_state_is_one_time_and_expires(self) -> None:
        with self.session_factory() as session:
            self.auth.create_oauth_state(
                session,
                provider=AuthProvider.GOOGLE,
                state="state-1",
                nonce="nonce-1",
                code_verifier="verifier-1",
                redirect_uri="https://example.com/callback",
            )
            consumed = self.auth.consume_oauth_state(
                session,
                provider=AuthProvider.GOOGLE,
                state="state-1",
            )
            second = self.auth.consume_oauth_state(
                session,
                provider=AuthProvider.GOOGLE,
                state="state-1",
            )

            self.assertIsNotNone(consumed)
            self.assertEqual(consumed.nonce, "nonce-1")
            self.assertIsNone(second)

            expired = self.auth.repository.save_oauth_state(
                session,
                provider=AuthProvider.GOOGLE,
                state="expired-state",
                nonce="nonce-2",
                code_verifier="verifier-2",
                redirect_uri="https://example.com/callback",
                expires_at=datetime.now(UTC) - timedelta(seconds=1),
            )
            self.assertEqual(expired.state, "expired-state")

            self.assertIsNone(
                self.auth.consume_oauth_state(
                    session,
                    provider=AuthProvider.GOOGLE,
                    state="expired-state",
                )
            )

    def test_refresh_token_rotation_and_reuse_detection(self) -> None:
        with self.session_factory() as session:
            user = User(
                email="refresh@example.com",
                email_verified=True,
            )
            session.add(user)
            session.commit()
            session.refresh(user)

            access_token, refresh_token, _ = self.auth.issue_session(
                session,
                user=user,
            )
            self.assertTrue(access_token)
            record = session.query(RefreshToken).one()
            family_id = record.family_id
            self.assertEqual(record.token_hash, hash_refresh_token(refresh_token))
            self.assertNotEqual(record.token_hash, refresh_token)

            rotated_user, _, new_refresh, _ = self.auth.rotate_refresh_token(
                session,
                refresh_token=refresh_token,
            )
            self.assertEqual(rotated_user.id, user.id)
            self.assertNotEqual(new_refresh, refresh_token)

            old_record = session.query(RefreshToken).filter_by(
                token_hash=hash_refresh_token(refresh_token),
            ).one()
            self.assertIsNotNone(old_record.revoked_at)
            self.assertEqual(old_record.family_id, family_id)

            with self.assertRaises(AuthenticationError):
                self.auth.rotate_refresh_token(
                    session,
                    refresh_token=refresh_token,
                )

            family = session.query(RefreshToken).filter_by(family_id=family_id).all()
            self.assertTrue(all(record.revoked_at is not None for record in family))

    def test_expired_refresh_token_is_revoked(self) -> None:
        with self.session_factory() as session:
            user = User(email="expired@example.com", email_verified=True)
            session.add(user)
            session.commit()
            session.refresh(user)

            _, refresh_token, _ = self.auth.issue_session(
                session,
                user=user,
            )
            record = session.query(RefreshToken).one()
            record.expires_at = datetime.now(UTC) - timedelta(seconds=1)
            session.commit()

            with self.assertRaises(AuthenticationError):
                self.auth.rotate_refresh_token(
                    session,
                    refresh_token=refresh_token,
                )

            session.refresh(record)
            self.assertIsNotNone(record.revoked_at)

    def test_inactive_user_cannot_refresh(self) -> None:
        with self.session_factory() as session:
            user = User(email="inactive@example.com", email_verified=True)
            session.add(user)
            session.commit()
            session.refresh(user)

            _, refresh_token, _ = self.auth.issue_session(
                session,
                user=user,
            )
            user.is_active = False
            session.commit()

            with self.assertRaises(AuthenticationError):
                self.auth.rotate_refresh_token(
                    session,
                    refresh_token=refresh_token,
                )

            record = session.query(RefreshToken).one()
            self.assertIsNotNone(record.revoked_at)


if __name__ == "__main__":
    unittest.main()
