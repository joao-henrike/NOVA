from typing import Annotated

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.orm import Session

from app.core.security import ensure_active_user, require_bearer_token
from app.db.session import get_db
from app.models.user import User
from app.repositories.auth import AuthRepository

bearer_scheme = HTTPBearer(auto_error=False)
auth_repository = AuthRepository()


def get_current_user(
    credentials: Annotated[
        HTTPAuthorizationCredentials | None,
        Depends(bearer_scheme),
    ],
    db: Annotated[Session, Depends(get_db)],
) -> User:
    user_id, session_id = require_bearer_token(credentials)
    user = ensure_active_user(db.get(User, user_id))

    if not auth_repository.has_active_refresh_family(
        db,
        user_id=user.id,
        family_id=session_id,
    ):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Session is no longer active",
            headers={"WWW-Authenticate": "Bearer"},
        )

    return user


CurrentUser = Annotated[User, Depends(get_current_user)]
