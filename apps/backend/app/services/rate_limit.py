import hashlib
import hmac
from datetime import UTC, datetime, timedelta
from ipaddress import ip_address
from math import ceil

from fastapi import Request
from sqlalchemy.orm import Session

from app.core.config import settings
from app.repositories.rate_limit import AuthRateLimitRepository


class RateLimitExceeded(Exception):
    def __init__(self, retry_after: int) -> None:
        super().__init__("Authentication rate limit exceeded.")
        self.retry_after = retry_after


def get_request_client_ip(request: Request) -> str:
    if settings.app_env.lower() != "local":
        forwarded_for = request.headers.get("x-forwarded-for")
        if not forwarded_for:
            raise ValueError("Missing ALB-forwarded client address.")

        candidate = forwarded_for.rsplit(",", 1)[-1].strip()
        try:
            return str(ip_address(candidate))
        except ValueError as exc:
            raise ValueError("Invalid ALB-forwarded client address.") from exc

    if request.client is None:
        return "unknown"

    try:
        return str(ip_address(request.client.host))
    except ValueError:
        # TestClient and some local ASGI transports use non-IP peer names.
        return request.client.host.lower()


def _bucket_key(*, scope: str, client_ip: str) -> str:
    signing_secret = settings.require_auth_signing_key().encode()
    derived_key = hmac.new(
        signing_secret,
        b"nova-auth-rate-limit-v1",
        hashlib.sha256,
    ).digest()
    message = f"{scope}:{client_ip}".encode()
    return hmac.new(derived_key, message, hashlib.sha256).hexdigest()


def check_rate_limit(
    session: Session,
    *,
    scope: str,
    client_ip: str,
    limit: int,
    window_seconds: int,
    now: datetime | None = None,
) -> int:
    if limit < 1 or window_seconds < 1:
        raise ValueError("Rate limit and window must be positive integers.")

    current_time = now or datetime.now(UTC)
    if current_time.tzinfo is None:
        current_time = current_time.replace(tzinfo=UTC)
    else:
        current_time = current_time.astimezone(UTC)

    window_number = int(current_time.timestamp()) // window_seconds
    window_start = datetime.fromtimestamp(
        window_number * window_seconds,
        tz=UTC,
    )
    count = AuthRateLimitRepository().increment_bucket(
        session,
        bucket_key=_bucket_key(scope=scope, client_ip=client_ip),
        window_start=window_start,
        now=current_time,
    )

    if count > limit:
        reset_at = window_start + timedelta(seconds=window_seconds)
        retry_after = max(1, ceil((reset_at - current_time).total_seconds()))
        raise RateLimitExceeded(retry_after)

    return count
