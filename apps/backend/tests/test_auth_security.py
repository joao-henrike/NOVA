import unittest
from uuid import uuid4

import jwt

from app.core.config import settings
from app.core.security import (
    create_access_token,
    create_pkce_challenge,
    create_pkce_verifier,
    decode_access_token,
    hash_refresh_token,
    is_safe_state_match,
)
from app.services.providers import claims_to_identity


class AuthSecurityTest(unittest.TestCase):
    def test_pkce_verifier_and_challenge(self) -> None:
        verifier = create_pkce_verifier()
        challenge = create_pkce_challenge(verifier)

        self.assertGreaterEqual(len(verifier), 43)
        self.assertLessEqual(len(verifier), 128)
        self.assertNotEqual(verifier, challenge)

    def test_state_comparison_is_exact(self) -> None:
        self.assertTrue(is_safe_state_match("state-value", "state-value"))
        self.assertFalse(is_safe_state_match("state-value", "other-value"))

    def test_refresh_token_is_hashed(self) -> None:
        token = "opaque-refresh-token"
        digest = hash_refresh_token(token)

        self.assertNotEqual(token, digest)
        self.assertEqual(len(digest), 64)

    def test_access_token_contains_expected_claims(self) -> None:
        original_secret = settings.auth_jwt_secret_key
        settings.auth_jwt_secret_key = "x" * 64

        try:
            user_id = uuid4()
            token, expires_in = create_access_token(user_id)
            decoded_id = decode_access_token(token)

            self.assertEqual(decoded_id, user_id)
            self.assertEqual(expires_in, 15 * 60)
        finally:
            settings.auth_jwt_secret_key = original_secret

    def test_access_token_algorithm_is_fixed(self) -> None:
        original_secret = settings.auth_jwt_secret_key
        settings.auth_jwt_secret_key = "x" * 64

        try:
            token, _ = create_access_token(uuid4())
            header = jwt.get_unverified_header(token)
            self.assertEqual(header["alg"], "HS256")
        finally:
            settings.auth_jwt_secret_key = original_secret

    def test_provider_subject_is_canonical_identity(self) -> None:
        subject, email, verified, name = claims_to_identity(
            {
                "sub": "provider-subject",
                "email": " USER@EXAMPLE.COM ",
                "email_verified": "true",
                "name": "User",
            }
        )

        self.assertEqual(subject, "provider-subject")
        self.assertEqual(email, "user@example.com")
        self.assertTrue(verified)
        self.assertEqual(name, "User")


if __name__ == "__main__":
    unittest.main()
