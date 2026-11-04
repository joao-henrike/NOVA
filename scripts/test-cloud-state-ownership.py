#!/usr/bin/env python3
"""Offline contract tests for legacy Terraform state collision detection."""
import runpy
import unittest
from pathlib import Path

module = runpy.run_path(str(Path(__file__).with_name("check-cloud-state-ownership.py")))
analyze = module["analyze"]


def item(kind, name, attrs):
    return {"mode": "managed", "type": kind, "name": name,
            "instances": [{"attributes": attrs}]}


class OwnershipTests(unittest.TestCase):
    def setUp(self):
        self.canonical = {"resources": [item("aws_vpc", "this", {"id": "vpc-new"})]}
        self.legacy = {"cloudstart/terraform.tfstate": {
            "resources": [item("aws_lb_target_group", "frontend", {
                "id": "arn:tg-old", "name": "cloudstart-dev-frontend-tg",
            })]
        }}

    def test_foreign_vpc_target_group_blocks(self):
        errors, _ = analyze(self.canonical, self.legacy, lambda kind, name: {
            "id": "arn:tg-old", "vpc": "vpc-old",
        })
        self.assertEqual(len(errors), 1)
        self.assertIn("FOREIGN_VPC=vpc-old", errors[0])
        self.assertIn("NOT_IN_CANONICAL_STATE", errors[0])

    def test_absent_stale_legacy_resource_does_not_block(self):
        errors, notices = analyze(self.canonical, self.legacy, lambda kind, name: None)
        self.assertEqual(errors, [])
        self.assertEqual(len(notices), 1)

    def test_duplicated_ownership_blocks(self):
        self.canonical["resources"].append(item("aws_iam_role", "ecs_execution", {
            "id": "cloudstart-dev-ecs-execution", "name": "cloudstart-dev-ecs-execution",
        }))
        self.legacy["cloudstart/terraform.tfstate"]["resources"] = [
            item("aws_iam_role", "ecs_execution", {
                "id": "cloudstart-dev-ecs-execution", "name": "cloudstart-dev-ecs-execution",
            })
        ]
        errors, _ = analyze(self.canonical, self.legacy,
                            lambda kind, name: {"id": name})
        self.assertEqual(len(errors), 1)
        self.assertIn("DOUBLE_STATE_OWNERSHIP", errors[0])

    def test_legacy_global_role_blocks_even_without_vpc(self):
        self.legacy["cloudstart/terraform.tfstate"]["resources"] = [
            item("aws_iam_role", "ecs_frontend_task", {
                "id": "cloudstart-dev-ecs-frontend-task",
                "name": "cloudstart-dev-ecs-frontend-task",
            })
        ]
        errors, _ = analyze(self.canonical, self.legacy,
                            lambda kind, name: {"id": name})
        self.assertEqual(len(errors), 1)
        self.assertIn("NOT_IN_CANONICAL_STATE", errors[0])

    def test_live_id_mismatch_blocks(self):
        errors, _ = analyze(self.canonical, self.legacy,
                            lambda kind, name: {"id": "arn:another", "vpc": "vpc-new"})
        self.assertEqual(len(errors), 1)
        self.assertIn("STALE_ID", errors[0])

    def test_empty_legacy_passes(self):
        errors, notices = analyze(self.canonical, {}, lambda kind, name: None)
        self.assertEqual(errors, [])
        self.assertEqual(notices, [])

    def test_ignores_data_sources(self):
        legacy = {"legacy": {"resources": [{
            "mode": "data", "type": "aws_iam_role", "name": "role",
            "instances": [{"attributes": {"name": "cloudstart-dev-ecs-execution"}}],
        }]}}
        errors, _ = analyze(self.canonical, legacy, lambda kind, name: {
            "id": name,
        })
        self.assertEqual(errors, [])


if __name__ == "__main__":
    unittest.main()
