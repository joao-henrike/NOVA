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
        user_id: UUID,
        offset: int = 0,
        limit: int = 50,
        status: ItemStatus | None = None,
    ) -> list[Item]:
        statement = (
            select(Item)
            .where(Item.user_id == user_id)
            .order_by(Item.created_at.desc(), Item.id.desc())
            .offset(offset)
            .limit(limit)
        )
        if status is not None:
            statement = statement.where(Item.status == status)

        return list(session.scalars(statement))

    def get(
        self,
        session: Session,
        item_id: UUID,
        *,
        user_id: UUID,
    ) -> Item | None:
        statement = select(Item).where(
            Item.id == item_id,
            Item.user_id == user_id,
        )
        return session.scalar(statement)

    def create(
        self,
        session: Session,
        *,
        user_id: UUID,
        data: ItemCreate,
    ) -> Item:
        item = Item(user_id=user_id, **data.model_dump())
        try:
            session.add(item)
            session.flush()
            session.refresh(item)
            session.commit()
            return item
        except SQLAlchemyError:
            session.rollback()
            raise

    def update(
        self,
        session: Session,
        item_id: UUID,
        *,
        user_id: UUID,
        data: ItemUpdate,
    ) -> Item | None:
        item = self.get(session, item_id, user_id=user_id)
        if item is None:
            return None

        try:
            for field, value in data.model_dump(exclude_unset=True).items():
                setattr(item, field, value)

            session.flush()
            session.refresh(item)
            session.commit()
            return item
        except SQLAlchemyError:
            session.rollback()
            raise

    def delete(
        self,
        session: Session,
        item_id: UUID,
        *,
        user_id: UUID,
    ) -> bool:
        item = self.get(session, item_id, user_id=user_id)
        if item is None:
            return False

        try:
            session.delete(item)
            session.commit()
            return True
        except SQLAlchemyError:
            session.rollback()
            raise
