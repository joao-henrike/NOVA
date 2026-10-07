# NOVA — Accepted security exceptions

This file documents the current Checkov exceptions in `.checkov.yaml`.

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
