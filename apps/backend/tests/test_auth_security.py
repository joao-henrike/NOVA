import unittest
from uuid import uuid4

import jwt
from fastapi import HTTPException

from app.core.config import Settings, settings
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
            session_id = uuid4()
            token, expires_in = create_access_token(user_id, session_id)
            decoded_user_id, decoded_session_id = decode_access_token(token)

            self.assertEqual(decoded_user_id, user_id)
            self.assertEqual(decoded_session_id, session_id)
            self.assertEqual(expires_in, 15 * 60)
        finally:
            settings.auth_jwt_secret_key = original_secret

    def test_access_token_algorithm_is_fixed(self) -> None:
        original_secret = settings.auth_jwt_secret_key
        settings.auth_jwt_secret_key = "x" * 64

        try:
            token, _ = create_access_token(uuid4(), uuid4())
            header = jwt.get_unverified_header(token)
            self.assertEqual(header["alg"], "HS256")
        finally:
            settings.auth_jwt_secret_key = original_secret

    def test_access_token_rejects_invalid_signature(self) -> None:
        original_secret = settings.auth_jwt_secret_key
        settings.auth_jwt_secret_key = "x" * 64

        try:
            token, _ = create_access_token(uuid4(), uuid4())
            header, payload, signature = token.split(".")
            replacement = "A" if signature[0] != "A" else "B"
            tampered_token = f"{header}.{payload}.{replacement}{signature[1:]}"

            with self.assertRaises(HTTPException) as rejected:
                decode_access_token(tampered_token)

            self.assertEqual(rejected.exception.status_code, 401)
        finally:
            settings.auth_jwt_secret_key = original_secret

    def test_access_token_rejects_invalid_registered_claims(self) -> None:
        original_secret = settings.auth_jwt_secret_key
        settings.auth_jwt_secret_key = "x" * 64

        try:
            token, _ = create_access_token(uuid4(), uuid4())
            payload = jwt.decode(token, options={"verify_signature": False})
            invalid_payloads = []

            wrong_issuer = dict(payload)
            wrong_issuer["iss"] = "unexpected-issuer"
            invalid_payloads.append(("issuer", wrong_issuer))

            wrong_audience = dict(payload)
            wrong_audience["aud"] = "unexpected-audience"
            invalid_payloads.append(("audience", wrong_audience))

            expired = dict(payload)
            expired["exp"] = 1
            invalid_payloads.append(("expiration", expired))

            missing_required_claim = dict(payload)
            missing_required_claim.pop("jti")
            invalid_payloads.append(("required claim", missing_required_claim))

            for claim, invalid_payload in invalid_payloads:
                forged_for_test = jwt.encode(
                    invalid_payload,
                    settings.auth_jwt_secret_key,
                    algorithm="HS256",
                )
                with self.subTest(claim=claim):
                    with self.assertRaises(HTTPException) as rejected:
                        decode_access_token(forged_for_test)
                    self.assertEqual(rejected.exception.status_code, 401)
        finally:
            settings.auth_jwt_secret_key = original_secret

    def test_access_token_rejects_non_string_session_id(self) -> None:
        original_secret = settings.auth_jwt_secret_key
        settings.auth_jwt_secret_key = "x" * 64

        try:
            token, _ = create_access_token(uuid4(), uuid4())
            payload = jwt.decode(token, options={"verify_signature": False})
            payload["sid"] = 123
            malformed_token = jwt.encode(
                payload,
                settings.auth_jwt_secret_key,
                algorithm="HS256",
            )

            with self.assertRaises(HTTPException) as rejected:
                decode_access_token(malformed_token)

            self.assertEqual(rejected.exception.status_code, 401)
        finally:
            settings.auth_jwt_secret_key = original_secret

    def test_apple_configuration_requires_private_key_source(self) -> None:
        configuration = Settings(
            apple_client_id="com.example.cloudstart.web",
            apple_team_id="TEAM123456",
            apple_key_id="KEY1234567",
            apple_redirect_uri="https://cloudstart.example.com/callback",
        )

        with self.assertRaisesRegex(
            RuntimeError,
            "Apple authentication is not configured",
        ):
            configuration.require_apple_config()

        configuration.apple_private_key = "test-private-key"
        configuration.require_apple_config()

    def test_unverified_provider_email_does_not_reserve_account_address(self) -> None:
        subject, email, verified, _ = claims_to_identity(
            {
                "sub": "unverified-provider-subject",
                "email": "victim@example.com",
                "email_verified": False,
                "name": "Attacker-controlled profile name",
            }
        )

        self.assertEqual(subject, "unverified-provider-subject")
        self.assertIsNone(email)
        self.assertFalse(verified)

    def test_verified_provider_email_is_normalized(self) -> None:
        _, email, verified, _ = claims_to_identity(
            {
                "sub": "verified-provider-subject",
                "email": " USER@EXAMPLE.COM ",
                "email_verified": "true",
            }
        )

        self.assertEqual(email, "user@example.com")
        self.assertTrue(verified)

    def test_email_cannot_be_marked_verified_when_provider_omits_it(self) -> None:
        _, email, verified, _ = claims_to_identity(
            {
                "sub": "provider-without-email",
                "email_verified": True,
            }
        )

        self.assertIsNone(email)
        self.assertFalse(verified)

    def test_provider_profile_fields_fit_database_columns(self) -> None:
        _, email, verified, name = claims_to_identity(
            {
                "sub": "profile-subject",
                "email": "not-verified@example.com",
                "email_verified": False,
                "name": "N" * 250,
            }
        )

        self.assertIsNone(email)
        self.assertFalse(verified)
        self.assertEqual(len(name or ""), 200)

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
