import unittest
from datetime import UTC, datetime
from uuid import uuid4

import jwt
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.core.config import settings
from app.core.security import (
    create_access_token,
    create_pkce_challenge,
    create_pkce_verifier,
)
from app.db.base import Base
from app.db.session import get_db
from app.main import app
from app.models.user import User
from app.services.providers import (
    apple_authorization_url,
    claims_to_identity,
    generate_apple_client_secret,
    google_authorization_url,
)


class ApplicationApiTest(unittest.TestCase):
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

        def override_get_db():
            with cls.session_factory() as session:
                yield session

        app.dependency_overrides[get_db] = override_get_db
        cls.client = TestClient(app)

        with cls.session_factory() as session:
            user = User(
                email="test@example.com",
                name="Test User",
                email_verified=True,
            )
            session.add(user)
            session.commit()
            session.refresh(user)
            cls.user_id = user.id

    @classmethod
    def tearDownClass(cls) -> None:
        app.dependency_overrides.clear()
        cls.engine.dispose()

    def setUp(self) -> None:
        self.original_secret = settings.auth_jwt_secret_key
        settings.auth_jwt_secret_key = "x" * 64

    def tearDown(self) -> None:
        settings.auth_jwt_secret_key = self.original_secret
        with self.session_factory() as session:
            session.query(User).filter(User.id != self.user_id).delete(
                synchronize_session=False,
            )
            session.commit()

    def _auth_headers(self) -> dict[str, str]:
        token, _ = create_access_token(self.user_id)
        return {"Authorization": f"Bearer {token}"}

    def test_items_requires_authentication(self) -> None:
        response = self.client.get("/api/items")
        self.assertEqual(response.status_code, 401)

    def test_items_crud(self) -> None:
        headers = self._auth_headers()

        created = self.client.post(
            "/api/items",
            json={
                "name": "CloudStart API",
                "description": "Authentication integration test",
            },
            headers=headers,
        )
        self.assertEqual(created.status_code, 201)
        item = created.json()
        item_id = item["id"]
        self.assertEqual(item["status"], "active")

        fetched = self.client.get(f"/api/items/{item_id}", headers=headers)
        self.assertEqual(fetched.status_code, 200)
        self.assertEqual(fetched.json()["name"], "CloudStart API")

        updated = self.client.patch(
            f"/api/items/{item_id}",
            json={"name": "CloudStart API v2", "status": "inactive"},
            headers=headers,
        )
        self.assertEqual(updated.status_code, 200)
        self.assertEqual(updated.json()["status"], "inactive")

        listed = self.client.get(
            "/api/items?status=inactive",
            headers=headers,
        )
        self.assertEqual(listed.status_code, 200)
        self.assertTrue(any(x["id"] == item_id for x in listed.json()))

        deleted = self.client.delete(
            f"/api/items/{item_id}",
            headers=headers,
        )
        self.assertEqual(deleted.status_code, 204)

        missing = self.client.get(f"/api/items/{item_id}", headers=headers)
        self.assertEqual(missing.status_code, 404)

    def test_missing_user_is_rejected(self) -> None:
        token, _ = create_access_token(uuid4())
        response = self.client.get(
            "/api/items",
            headers={"Authorization": f"Bearer {token}"},
        )
        self.assertEqual(response.status_code, 401)


class OAuthProtocolTest(unittest.TestCase):
    def setUp(self) -> None:
        self.original = {
            "google_client_id": settings.google_client_id,
            "google_client_secret": settings.google_client_secret,
            "google_redirect_uri": settings.google_redirect_uri,
            "apple_client_id": settings.apple_client_id,
            "apple_team_id": settings.apple_team_id,
            "apple_key_id": settings.apple_key_id,
            "apple_private_key": settings.apple_private_key,
            "apple_redirect_uri": settings.apple_redirect_uri,
            "auth_cookie_secure": settings.auth_cookie_secure,
        }

        settings.google_client_id = "google-client-id"
        settings.google_client_secret = "google-client-secret"
        settings.google_redirect_uri = "https://cloudstart.example.com/api/auth/google/callback"

        settings.apple_client_id = "com.example.cloudstart.web"
        settings.apple_team_id = "TEAM123456"
        settings.apple_key_id = "KEY1234567"
        settings.apple_redirect_uri = "https://cloudstart.example.com/api/auth/apple/callback"
        settings.auth_cookie_secure = True

    def tearDown(self) -> None:
        for name, value in self.original.items():
            setattr(settings, name, value)

    def test_pkce_s256(self) -> None:
        verifier = create_pkce_verifier()
        challenge = create_pkce_challenge(verifier)

        self.assertGreaterEqual(len(verifier), 43)
        self.assertEqual(len(challenge), 43)

    def test_google_authorization_request(self) -> None:
        url = google_authorization_url(
            "state-value",
            "nonce-value",
            "challenge-value",
        )
        self.assertIn("response_type=code", url)
        self.assertIn("state=state-value", url)
        self.assertIn("nonce=nonce-value", url)
        self.assertIn("code_challenge=challenge-value", url)
        self.assertIn("code_challenge_method=S256", url)

    def test_apple_authorization_request(self) -> None:
        url = apple_authorization_url(
            "state-value",
            "nonce-value",
        )
        self.assertIn("response_type=code", url)
        self.assertIn("response_mode=form_post", url)
        self.assertIn("scope=name+email", url)
        self.assertIn("state=state-value", url)
        self.assertIn("nonce=nonce-value", url)

    def test_identity_uses_provider_subject(self) -> None:
        subject, email, verified, name = claims_to_identity(
            {
                "sub": "apple-subject-123",
                "email": "USER@EXAMPLE.COM",
                "email_verified": "true",
                "name": "User",
            }
        )
        self.assertEqual(subject, "apple-subject-123")
        self.assertEqual(email, "user@example.com")
        self.assertTrue(verified)
        self.assertEqual(name, "User")

    def test_apple_client_secret_claims(self) -> None:
        try:
            from cryptography.hazmat.primitives import serialization
            from cryptography.hazmat.primitives.asymmetric import ec

            private_key = ec.generate_private_key(ec.SECP256R1())
            settings.apple_private_key = private_key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            ).decode()

            token = generate_apple_client_secret()
            header = jwt.get_unverified_header(token)
            claims = jwt.decode(
                token,
                private_key.public_key(),
                algorithms=["ES256"],
                audience="https://appleid.apple.com",
            )

            self.assertEqual(header["alg"], "ES256")
            self.assertEqual(header["kid"], "KEY1234567")
            self.assertEqual(claims["iss"], "TEAM123456")
            self.assertEqual(claims["sub"], "com.example.cloudstart.web")
            self.assertGreater(
                claims["exp"],
                int(datetime.now(UTC).timestamp()),
            )
        except ModuleNotFoundError as exc:
            self.fail(f"cryptography dependency missing: {exc}")


if __name__ == "__main__":
    unittest.main()
