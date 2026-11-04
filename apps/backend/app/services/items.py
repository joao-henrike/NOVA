from uuid import UUID

from sqlalchemy.orm import Session

from app.models.item import Item, ItemStatus
from app.repositories.items import ItemRepository
from app.schemas.item import ItemCreate, ItemUpdate


class ItemNotFoundError(Exception):
    pass


class ItemService:
    def __init__(self, repository: ItemRepository | None = None) -> None:
        self.repository = repository or ItemRepository()

    def list(
        self,
        session: Session,
        *,
        user_id: UUID,
        offset: int,
        limit: int,
        status: ItemStatus | None,
    ) -> list[Item]:
        return self.repository.list(
            session,
            user_id=user_id,
            offset=offset,
            limit=limit,
            status=status,
        )

    def get(self, session: Session, item_id: UUID, *, user_id: UUID) -> Item:
        item = self.repository.get(session, item_id, user_id=user_id)
        if item is None:
            raise ItemNotFoundError
        return item

    def create(
        self,
        session: Session,
        *,
        user_id: UUID,
        data: ItemCreate,
    ) -> Item:
        return self.repository.create(session, user_id=user_id, data=data)

    def update(
        self,
        session: Session,
        item_id: UUID,
        *,
        user_id: UUID,
        data: ItemUpdate,
    ) -> Item:
        item = self.repository.update(
            session,
            item_id,
            user_id=user_id,
            data=data,
        )
        if item is None:
            raise ItemNotFoundError
        return item

    def delete(self, session: Session, item_id: UUID, *, user_id: UUID) -> None:
        deleted = self.repository.delete(session, item_id, user_id=user_id)
        if not deleted:
            raise ItemNotFoundError
