import json
import unittest
from unittest.mock import Mock, patch

from sqlalchemy.exc import SQLAlchemyError

from app.api.routes.health import api_health, database_health, health, info


class HealthContractTest(unittest.TestCase):
    def test_health(self) -> None:
        self.assertEqual(health(), {"status": "ok"})

    def test_api_health(self) -> None:
        self.assertEqual(api_health(), {"status": "ok", "service": "backend"})


    @patch("app.api.routes.health.get_engine")
    def test_database_health_reports_reachable_database(self, get_engine) -> None:
        engine = Mock()
        connection = Mock()
        engine.connect.return_value.__enter__.return_value = connection
        get_engine.return_value = engine

        response = database_health()

        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            json.loads(response.body),
            {"status": "ok", "database": "reachable"},
        )
        connection.execute.assert_called_once()

    @patch("app.api.routes.health.get_engine", side_effect=RuntimeError("DB config missing"))
    def test_database_health_reports_configuration_failure(self, get_engine) -> None:
        response = database_health()

        self.assertEqual(response.status_code, 503)
        self.assertEqual(json.loads(response.body), {"status": "degraded"})
        get_engine.assert_called_once()

    @patch("app.api.routes.health.get_engine")
    def test_database_health_reports_database_errors(self, get_engine) -> None:
        engine = Mock()
        connection = Mock()
        connection.execute.side_effect = SQLAlchemyError("database unavailable")
        engine.connect.return_value.__enter__.return_value = connection
        get_engine.return_value = engine

        response = database_health()

        self.assertEqual(response.status_code, 503)
        self.assertEqual(json.loads(response.body), {"status": "degraded"})

    def test_info(self) -> None:
        result = info()
        self.assertEqual(result["service"], "backend")
        self.assertIn("environment", result)
        self.assertEqual(result["version"], "0.2.0")
