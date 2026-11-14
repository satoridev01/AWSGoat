#!/usr/bin/env bash
# Creates/destroys the IAM identities used by the Prowler fork's `--verify` active
# adapter/enricher tests (PacuPrivescAdapter, StratusS3ExfiltrationEnricher) and by
# Prowler's own scans. Plain `aws iam` calls, no Terraform, so this stays outside
# deploy/run.sh's Docker flow; both identities are cheap IAM metadata (no billable
# resources). Kept in this repo, not created ad hoc, so the account is fully
# reproducible from git on every up/down cycle.
#
#   AWS_PROFILE=awsgoat ./deploy/testing-identities.sh up     # create/rotate, write local ~/.aws profile
#   AWS_PROFILE=awsgoat ./deploy/testing-identities.sh down   # delete everything
set -euo pipefail
cd "$(dirname "$0")/.."

ATTACKER_USER=awsgoat-attacker
ATTACKER_PROFILE=awsgoat-attacker
PROWLER_POLICY_NAME=ProwlerAdditionsReadOnly
PROWLER_POLICY_DOC=deploy/policies/prowler-additions-readonly.json
AUDIT_USER=satori-scout

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${PROWLER_POLICY_NAME}"

log() { printf '\n==> %s\n' "$*"; }

up() {
  log "$PROWLER_POLICY_NAME (extra read-only actions Prowler needs beyond SecurityAudit/ViewOnlyAccess)"
  if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
    echo "policy already exists"
  else
    aws iam create-policy --policy-name "$PROWLER_POLICY_NAME" \
      --policy-document "file://$PROWLER_POLICY_DOC" >/dev/null
    echo "policy created"
  fi
  aws iam attach-user-policy --user-name "$AUDIT_USER" --policy-arn "$POLICY_ARN"
  echo "attached to $AUDIT_USER"

  log "$ATTACKER_USER (disposable pacu privesc target; baseline ViewOnlyAccess + SecurityAudit, no escalation path)"
  if aws iam get-user --user-name "$ATTACKER_USER" >/dev/null 2>&1; then
    echo "user already exists"
  else
    aws iam create-user --user-name "$ATTACKER_USER" >/dev/null
    aws iam attach-user-policy --user-name "$ATTACKER_USER" --policy-arn arn:aws:iam::aws:policy/job-function/ViewOnlyAccess
    aws iam attach-user-policy --user-name "$ATTACKER_USER" --policy-arn arn:aws:iam::aws:policy/SecurityAudit
    echo "user created"
  fi

  # Rotate the access key every run (idempotent `up`, never leaves a stale key
  # behind) and write it straight to the local profile; the secret is never printed.
  for k in $(aws iam list-access-keys --user-name "$ATTACKER_USER" --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
    aws iam delete-access-key --user-name "$ATTACKER_USER" --access-key-id "$k"
  done
  tmp=$(mktemp)
  aws iam create-access-key --user-name "$ATTACKER_USER" --output json > "$tmp"
  python3 -c "
import json, subprocess
d = json.load(open('$tmp'))['AccessKey']
subprocess.run(['aws', 'configure', 'set', 'aws_access_key_id', d['AccessKeyId'], '--profile', '$ATTACKER_PROFILE'], check=True)
subprocess.run(['aws', 'configure', 'set', 'aws_secret_access_key', d['SecretAccessKey'], '--profile', '$ATTACKER_PROFILE'], check=True)
"
  rm -f "$tmp"
  aws configure set region us-east-1 --profile "$ATTACKER_PROFILE"
  echo "local profile '$ATTACKER_PROFILE' written"
}

down() {
  log "$ATTACKER_USER"
  if aws iam get-user --user-name "$ATTACKER_USER" >/dev/null 2>&1; then
    aws iam detach-user-policy --user-name "$ATTACKER_USER" --policy-arn arn:aws:iam::aws:policy/job-function/ViewOnlyAccess 2>/dev/null || true
    aws iam detach-user-policy --user-name "$ATTACKER_USER" --policy-arn arn:aws:iam::aws:policy/SecurityAudit 2>/dev/null || true
    for k in $(aws iam list-access-keys --user-name "$ATTACKER_USER" --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
      aws iam delete-access-key --user-name "$ATTACKER_USER" --access-key-id "$k"
    done
    aws iam delete-user --user-name "$ATTACKER_USER"
    echo "deleted"
  else
    echo "not present"
  fi

  log "$PROWLER_POLICY_NAME"
  if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
    aws iam detach-user-policy --user-name "$AUDIT_USER" --policy-arn "$POLICY_ARN" 2>/dev/null || true
    aws iam delete-policy --policy-arn "$POLICY_ARN"
    echo "deleted"
  else
    echo "not present"
  fi
}

cmd="${1:-}"
case "$cmd" in
  up)   up ;;
  down) down ;;
  *)    sed -n '2,11p' "$0"; exit 2 ;;
esac
