# NOVA — State recovery (06 Nov 2026)

This one-time script targets only the confirmed AWS dev account/region/identities recorded in NOVA's 06 Nov 2026 audit. It backs up Terraform state before changes and requires an exact typed confirmation. It may remove five unused objects from the old VPC and modify remote Terraform state, so read and approve the action summary before continuing.

From AWS CloudShell, in the main branch:

```bash
cd ~/NOVA
git status --short
python3 recovery/legacy-state-2026-11-06/recover.py
# Only after RECOVERY PASS:
make deploy
```

Never use `make destroy-all` as a workaround for State collisions. Preserve existing AWS RDS snapshots; this script does not restore database content. Do not run concurrent Terraform commands while recovering State. A git pull of this code itself does not modify AWS.
