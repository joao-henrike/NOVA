#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STACK_DIR="$ROOT_DIR/bootstrap/github-oidc"
DEPLOY_DIR="$ROOT_DIR/.deploy"
PLAN_FILE="$DEPLOY_DIR/github-oidc-role.tfplan"
TF_DATA_DIR="$DEPLOY_DIR/github-oidc-terraform-data"
EXPECTED_AWS_ACCOUNT_ID="760396521507"
ROLE_NAME="cloudstart-nova-github-actions-cd"
CONFIRMATION="${1:-}"

fatal() {
  echo "ERROR: $*" >&2
  exit 1
}

[ "$CONFIRMATION" = "CREATE_GITHUB_OIDC_ROLE" ] || fatal "This creates an AWS IAM OIDC provider and deployment role. Re-run with the exact argument CREATE_GITHUB_OIDC_ROLE after reviewing scripts/bootstrap-github-oidc-role.sh and bootstrap/github-oidc/README.md."

for command_name in aws terraform python3; do
  command -v "$command_name" >/dev/null 2>&1 || fatal "$command_name is required."
done

actual_account="$(aws sts get-caller-identity --query Account --output text)"
[ "$actual_account" = "$EXPECTED_AWS_ACCOUNT_ID" ] || fatal "AWS account mismatch: expected $EXPECTED_AWS_ACCOUNT_ID, got $actual_account."

mkdir -p "$DEPLOY_DIR"
chmod 700 "$DEPLOY_DIR"
export TF_DATA_DIR
TF_DATA_DIR="$TF_DATA_DIR"

echo "AWS account verified: $actual_account"
echo "Initializing isolated GitHub OIDC bootstrap stack."
terraform -chdir="$STACK_DIR" init -backend=false -input=false -no-color
terraform -chdir="$STACK_DIR" fmt -check -diff
terraform -chdir="$STACK_DIR" validate -no-color

provider_arn="$(aws iam list-open-id-connect-providers --output json | python3 -c '
import json
import sys
items = json.load(sys.stdin).get("OpenIDConnectProviderList", [])
matches = [
    item["Arn"]
    for item in items
    if item.get("Arn", "").endswith(":oidc-provider/token.actions.githubusercontent.com")
]
if len(matches) > 1:
    raise SystemExit("More than one GitHub OIDC provider was returned; refusing to choose automatically.")
print(matches[0] if matches else "")
')"

# The GitHub OIDC provider can be shared by other repositories and roles.
# Reuse it as a read-only data source; never import/update its audiences or tags.
if [ -n "$provider_arn" ]; then
  TF_VAR_existing_github_oidc_provider_arn="$provider_arn"
  export TF_VAR_existing_github_oidc_provider_arn
  echo "Reusing existing GitHub OIDC provider without changing its audiences or tags."
else
  unset TF_VAR_existing_github_oidc_provider_arn
  echo "No GitHub OIDC provider exists; Terraform will create one for this account."
fi

# Detach any provider imported by an older version of this bootstrap stack.
# state rm only removes the management reference; it does not delete the IAM provider.
for address in 'aws_iam_openid_connect_provider.github' 'aws_iam_openid_connect_provider.github[0]'; do
  if terraform -chdir="$STACK_DIR" state show "$address" >/dev/null 2>&1; then
    echo "Detaching previously managed shared OIDC provider from local Terraform state: $address"
    terraform -chdir="$STACK_DIR" state rm "$address"
  fi
done

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  if ! terraform -chdir="$STACK_DIR" state show aws_iam_role.github_actions_cd >/dev/null 2>&1; then
    fatal "IAM role $ROLE_NAME already exists but is not in this stack's local state. Review it and import it manually before applying; this script will not adopt or overwrite an unknown role."
  fi
fi

rm -f "$PLAN_FILE"
terraform -chdir="$STACK_DIR" plan \
  -input=false \
  -no-color \
  -var="expected_account_id=$EXPECTED_AWS_ACCOUNT_ID" \
  -out="$PLAN_FILE"

echo
echo "The plan reuses an existing GitHub OIDC provider unchanged, or creates it only when missing."
echo "It creates/updates only the NOVA development deployment role and never deletes a shared OIDC provider."
echo "No root application infrastructure, databases, or ECS services are changed by this bootstrap."
terraform -chdir="$STACK_DIR" apply -input=false -auto-approve "$PLAN_FILE"

role_arn="$(terraform -chdir="$STACK_DIR" output -raw github_actions_cd_role_arn)"
case "$role_arn" in
  "arn:aws:iam::$EXPECTED_AWS_ACCOUNT_ID:role/$ROLE_NAME") ;;
  *) fatal "Terraform returned an unexpected deployment role ARN: $role_arn" ;;
esac

echo
echo "GitHub Actions deployment role created:"
echo "$role_arn"
echo
if command -v gh >/dev/null 2>&1 && gh auth status --hostname github.com >/dev/null 2>&1; then
  current_role_arn="$(gh variable get AWS_CD_ROLE_ARN --repo joao-henrike/NOVA 2>/dev/null || true)"
  if [ "$current_role_arn" = "$role_arn" ]; then
    echo "GitHub repository variable AWS_CD_ROLE_ARN already matches the created role."
  elif [ -n "$current_role_arn" ]; then
    echo "AWS_CD_ROLE_ARN already contains a different value; refusing to overwrite it automatically." >&2
    printf 'Review and update it with: gh variable set AWS_CD_ROLE_ARN --repo joao-henrike/NOVA --body "%s"\n' "$role_arn"
  elif gh variable set AWS_CD_ROLE_ARN --repo joao-henrike/NOVA --body "$role_arn"; then
    echo "GitHub repository variable AWS_CD_ROLE_ARN was published successfully."
  else
    echo "The IAM role was created, but GitHub rejected the variable update." >&2
    printf 'Set it manually with: gh variable set AWS_CD_ROLE_ARN --repo joao-henrike/NOVA --body "%s"\n' "$role_arn"
  fi
else
  echo "GitHub CLI is unavailable or not authenticated with repository Variables write permission."
  printf 'After authenticating gh, set it with: gh variable set AWS_CD_ROLE_ARN --repo joao-henrike/NOVA --body "%s"\n' "$role_arn"
fi
