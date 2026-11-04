import unittest
from unittest.mock import Mock
from uuid import uuid4

from sqlalchemy import create_engine
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.models.item import Item, ItemStatus
from app.models.user import User
from app.repositories.items import ItemRepository
from app.schemas.item import ItemCreate, ItemUpdate


class ItemRepositoryTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.engine = create_engine(
            "sqlite+pysqlite:///:memory:",
            connect_args={"check_same_thread": False},
            poolclass=StaticPool,
        )
        Base.metadata.create_all(cls.engine)

    @classmethod
    def tearDownClass(cls) -> None:
        Base.metadata.drop_all(cls.engine)
        cls.engine.dispose()

    def setUp(self) -> None:
        self.session = Session(self.engine)
        self.repository = ItemRepository()
        user = User(email=f"{uuid4()}@example.com", name="Repository Test User")
        self.session.add(user)
        self.session.commit()
        self.user_id = user.id

    def tearDown(self) -> None:
        self.session.query(Item).delete(synchronize_session=False)
        self.session.query(User).filter(User.id == self.user_id).delete(
            synchronize_session=False,
        )
        self.session.commit()
        self.session.close()

    def test_create_get_update_delete(self) -> None:
        created = self.repository.create(
            self.session,
            user_id=self.user_id,
            data=ItemCreate(name="Backend API", description="CloudStart backend"),
        )

        self.assertIsNotNone(created.id)
        self.assertEqual(created.status, ItemStatus.ACTIVE)

        loaded = self.repository.get(self.session, created.id, user_id=self.user_id)
        self.assertIsNotNone(loaded)
        self.assertEqual(loaded.name, "Backend API")

        updated = self.repository.update(
            self.session,
            created.id,
            user_id=self.user_id,
            data=ItemUpdate(name="Backend API v2", status=ItemStatus.INACTIVE),
        )

        self.assertEqual(updated.name, "Backend API v2")
        self.assertEqual(updated.status, ItemStatus.INACTIVE)

        self.assertTrue(
            self.repository.delete(self.session, created.id, user_id=self.user_id)
        )
        self.assertIsNone(
            self.repository.get(self.session, created.id, user_id=self.user_id)
        )

    def test_create_rolls_back_when_commit_fails(self) -> None:
        session = Mock(spec=Session)
        session.commit.side_effect = SQLAlchemyError("insert failed")

        with self.assertRaisesRegex(SQLAlchemyError, "insert failed"):
            self.repository.create(
                session,
                user_id=self.user_id,
                data=ItemCreate(name="Rollback create"),
            )

        session.add.assert_called_once()
        session.flush.assert_called_once()
        session.refresh.assert_called_once()
        session.commit.assert_called_once()
        session.rollback.assert_called_once()

    def test_update_rolls_back_when_commit_fails(self) -> None:
        item = Item(
            id=uuid4(),
            user_id=self.user_id,
            name="Before update",
            status=ItemStatus.ACTIVE,
        )
        session = Mock(spec=Session)
        session.scalar.return_value = item
        session.commit.side_effect = SQLAlchemyError("update failed")

        with self.assertRaisesRegex(SQLAlchemyError, "update failed"):
            self.repository.update(
                session,
                item.id,
                user_id=self.user_id,
                data=ItemUpdate(name="After update"),
            )

        self.assertEqual(item.name, "After update")
        session.flush.assert_called_once()
        session.refresh.assert_called_once()
        session.commit.assert_called_once()
        session.rollback.assert_called_once()

    def test_create_rolls_back_when_refresh_fails_before_commit(self) -> None:
        session = Mock(spec=Session)
        session.refresh.side_effect = SQLAlchemyError("refresh failed")

        with self.assertRaisesRegex(SQLAlchemyError, "refresh failed"):
            self.repository.create(
                session,
                user_id=self.user_id,
                data=ItemCreate(name="Refresh rollback create"),
            )

        session.add.assert_called_once()
        session.flush.assert_called_once()
        session.refresh.assert_called_once()
        session.commit.assert_not_called()
        session.rollback.assert_called_once()

    def test_update_rolls_back_when_refresh_fails_before_commit(self) -> None:
        item = Item(
            id=uuid4(),
            user_id=self.user_id,
            name="Before refresh failure",
            status=ItemStatus.ACTIVE,
        )
        session = Mock(spec=Session)
        session.scalar.return_value = item
        session.refresh.side_effect = SQLAlchemyError("refresh failed")

        with self.assertRaisesRegex(SQLAlchemyError, "refresh failed"):
            self.repository.update(
                session,
                item.id,
                user_id=self.user_id,
                data=ItemUpdate(name="Updated before refresh failure"),
            )

        session.flush.assert_called_once()
        session.refresh.assert_called_once_with(item)
        session.commit.assert_not_called()
        session.rollback.assert_called_once()

    def test_delete_rolls_back_when_commit_fails(self) -> None:
        item = Item(
            id=uuid4(),
            user_id=self.user_id,
            name="Delete rollback",
            status=ItemStatus.ACTIVE,
        )
        session = Mock(spec=Session)
        session.scalar.return_value = item
        session.commit.side_effect = SQLAlchemyError("delete failed")

        with self.assertRaisesRegex(SQLAlchemyError, "delete failed"):
            self.repository.delete(
                session,
                item.id,
                user_id=self.user_id,
            )

        session.delete.assert_called_once_with(item)
        session.commit.assert_called_once()
        session.rollback.assert_called_once()

    def test_list_filters_by_status(self) -> None:
        self.repository.create(
            self.session,
            user_id=self.user_id,
            data=ItemCreate(name=f"active-{uuid4()}", status=ItemStatus.ACTIVE),
        )
        self.repository.create(
            self.session,
            user_id=self.user_id,
            data=ItemCreate(name=f"inactive-{uuid4()}", status=ItemStatus.INACTIVE),
        )

        inactive = self.repository.list(
            self.session,
            user_id=self.user_id,
            status=ItemStatus.INACTIVE,
        )

        self.assertTrue(inactive)
        self.assertTrue(
            all(item.status == ItemStatus.INACTIVE for item in inactive)
        )


if __name__ == "__main__":
    unittest.main()
