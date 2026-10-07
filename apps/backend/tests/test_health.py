import unittest

from app.api.routes.health import api_health, health, info


class HealthContractTest(unittest.TestCase):
    def test_health(self) -> None:
        self.assertEqual(health(), {"status": "ok"})

    def test_api_health(self) -> None:
        self.assertEqual(api_health(), {"status": "ok", "service": "backend"})

    def test_info(self) -> None:
        result = info()
        self.assertEqual(result["service"], "backend")
        self.assertIn("environment", result)
        self.assertEqual(result["version"], "0.2.0")
