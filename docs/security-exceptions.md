# NOVA — Accepted security exceptions

This file documents the current infrastructure security exceptions for **Checkov** and **Trivy**.

Checkov exceptions are maintained centrally in `.checkov.yaml`. Trivy exceptions are kept at the **resource level** with inline `#trivy:ignore:<ID>` directives so they remain scoped to the exact development resource that intentionally requires the exception.

These are explicit MVP decisions, not a blanket suppression. A newly introduced Checkov control that is not listed remains blocking in CI.

| Check | Current reason | Planned direction |
| --- | --- | --- |
| CKV_AWS_2 / CKV2_AWS_20 / CKV_AWS_378 / CKV_AWS_103 | Development ALB is HTTP-only | ACM + HTTPS listener |
| CKV_AWS_91 | ALB access logging not centralized yet | Centralized S3 log destination |
| CKV_AWS_150 | Deletion protection disabled for development | Enable in staging/prod |
| CKV2_AWS_28 | WAF not installed | Protect public edge with WAF |
| CKV_AWS_353 / CKV_AWS_118 / CKV_AWS_129 | RDS observability controls deferred | Centralized DB monitoring/logging |
| CKV_AWS_157 | Multi-AZ constrained by current MVP cost/free-tier profile | Enable for production |
| CKV_AWS_161 | IAM DB authentication not needed by current app | Re-evaluate with production auth design |
| CKV_AWS_293 | RDS deletion protection disabled for development | Enable in staging/prod |
| CKV_AWS_149 / CKV_AWS_145 / CKV_AWS_136 / CKV_AWS_119 | Customer-managed KMS encryption deferred | Introduce managed CMKs and key policy |
| CKV_AWS_18 / CKV_AWS_144 / CKV2_AWS_62 | State-bucket logging/replication/notifications deferred | Define DR/logging policy |
| CKV2_AWS_11 | VPC Flow Logs deferred | Centralize flow logs |
| CKV2_AWS_57 | Automatic secret rotation deferred | Add rotation mechanism |
| CKV_AWS_260 / CKV_AWS_130 | Public internet-facing ALB/subnets are intentional | Retain edge exposure but harden with HTTPS/WAF |
| Trivy AWS-0132 | Terraform state bucket uses SSE-S3 for the low-cost MVP | Move Terraform state to SSE-KMS with a customer-managed key |
| Trivy AWS-0053 / AWS-0054 | Development ALB is intentionally public and HTTP-only | Introduce ACM + HTTPS and then remove the exception |
| Trivy AWS-0104 | Development components require controlled outbound internet access through NAT for current dependencies | Replace broad egress with explicit destinations/endpoints where practical |


## Trivy CI policy

The CI workflow does not trust a repository-controlled Trivy configuration or ignore file when enforcing its blocking Terraform scan. It creates a minimal trusted configuration inside the GitHub runner and points Trivy at an empty temporary ignore file. Accepted exceptions are therefore visible only where the affected Terraform resource carries the corresponding inline directive.

This prevents a future repository change from silently weakening the global CI policy by modifying a local `trivy.yaml` or ignore file.
