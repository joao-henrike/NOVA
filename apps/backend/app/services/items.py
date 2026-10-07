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
        offset: int,
        limit: int,
        status: ItemStatus | None,
    ) -> list[Item]:
        return self.repository.list(
            session,
            offset=offset,
            limit=limit,
            status=status,
        )

    def get(self, session: Session, item_id: UUID) -> Item:
        item = self.repository.get(session, item_id)
        if item is None:
            raise ItemNotFoundError
        return item

    def create(self, session: Session, data: ItemCreate) -> Item:
        return self.repository.create(session, data)

    def update(
        self,
        session: Session,
        item_id: UUID,
        data: ItemUpdate,
    ) -> Item:
        item = self.get(session, item_id)
        return self.repository.update(session, item, data)

    def delete(self, session: Session, item_id: UUID) -> None:
        item = self.get(session, item_id)
        self.repository.delete(session, item)
