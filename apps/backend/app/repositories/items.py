from uuid import UUID

from sqlalchemy import select
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from app.models.item import Item, ItemStatus
from app.schemas.item import ItemCreate, ItemUpdate


class ItemRepository:
    def list(
        self,
        session: Session,
        *,
        offset: int = 0,
        limit: int = 50,
        status: ItemStatus | None = None,
    ) -> list[Item]:
        statement = (
            select(Item)
            .order_by(Item.created_at.desc(), Item.id.desc())
            .offset(offset)
            .limit(limit)
        )
        if status is not None:
            statement = statement.where(Item.status == status)

        return list(session.scalars(statement))

    def get(self, session: Session, item_id: UUID) -> Item | None:
        return session.get(Item, item_id)

    def create(self, session: Session, data: ItemCreate) -> Item:
        item = Item(**data.model_dump())
        try:
            session.add(item)
            session.commit()
            session.refresh(item)
            return item
        except SQLAlchemyError:
            session.rollback()
            raise

    def update(self, session: Session, item: Item, data: ItemUpdate) -> Item:
        try:
            for field, value in data.model_dump(exclude_unset=True).items():
                setattr(item, field, value)

            session.commit()
            session.refresh(item)
            return item
        except SQLAlchemyError:
            session.rollback()
            raise

    def delete(self, session: Session, item: Item) -> None:
        try:
            session.delete(item)
            session.commit()
        except SQLAlchemyError:
            session.rollback()
            raise
