import unittest
from uuid import uuid4

from sqlalchemy import create_engine
from sqlalchemy.orm import Session
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.models.item import ItemStatus
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

    def tearDown(self) -> None:
        self.session.close()

    def test_create_get_update_delete(self) -> None:
        created = self.repository.create(
            self.session,
            ItemCreate(name="Backend API", description="CloudStart backend"),
        )

        self.assertIsNotNone(created.id)
        self.assertEqual(created.status, ItemStatus.ACTIVE)

        loaded = self.repository.get(self.session, created.id)
        self.assertIsNotNone(loaded)
        self.assertEqual(loaded.name, "Backend API")

        updated = self.repository.update(
            self.session,
            created,
            ItemUpdate(name="Backend API v2", status=ItemStatus.INACTIVE),
        )

        self.assertEqual(updated.name, "Backend API v2")
        self.assertEqual(updated.status, ItemStatus.INACTIVE)

        self.repository.delete(self.session, created)
        self.assertIsNone(self.repository.get(self.session, created.id))

    def test_list_filters_by_status(self) -> None:
        self.repository.create(
            self.session,
            ItemCreate(name=f"active-{uuid4()}", status=ItemStatus.ACTIVE),
        )
        self.repository.create(
            self.session,
            ItemCreate(name=f"inactive-{uuid4()}", status=ItemStatus.INACTIVE),
        )

        inactive = self.repository.list(
            self.session,
            status=ItemStatus.INACTIVE,
        )

        self.assertTrue(inactive)
        self.assertTrue(
            all(item.status == ItemStatus.INACTIVE for item in inactive)
        )


if __name__ == "__main__":
    unittest.main()
