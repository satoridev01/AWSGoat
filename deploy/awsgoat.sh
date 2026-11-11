#!/usr/bin/env bash
# AWSGoat deploy helper, runs inside the deploy/Dockerfile image.
#
#   awsgoat up   [module-1 module-2 ...]   deploy (default: all modules)
#   awsgoat down [module-1 module-2 ...]   destroy (default: all modules)
#   awsgoat status                         show what is deployed
#   awsgoat tf <module> <terraform args>   run terraform with the module's state
#
# The repo is mounted read-only at /src and copied to a scratch dir on every run,
# because the modules' local-exec provisioners rewrite files in place.
# Terraform state lives in s3://awsgoat-tfstate-<account>/<module>/terraform.tfstate
# (versioned, not managed by Terraform, so a destroy can never delete its own state).
set -euo pipefail

ALL_MODULES=(module-1 module-2)
export AWS_REGION="${AWS_REGION:-us-east-1}" AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"
export TF_IN_AUTOMATION=1 TF_INPUT=0

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="${AWSGOAT_STATE_BUCKET:-awsgoat-tfstate-$ACCOUNT_ID}"
WORK=$(mktemp -d /tmp/awsgoat.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

log() { printf '\n==> %s\n' "$*"; }

ensure_bucket() {
  aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 && return
  log "Creating state bucket s3://$BUCKET"
  aws s3api create-bucket --bucket "$BUCKET" --region us-east-1 >/dev/null
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
}

state_key() { echo "$1/terraform.tfstate"; }

prepare() { # copy a pristine module and pull its state; echoes the module dir
  local m=$1 dir="$WORK/$1"
  [ -d "/src/modules/$m" ] || { echo "Unknown module: $m" >&2; exit 2; }
  rm -rf "$dir" && mkdir -p "$dir"
  tar -C "/src/modules/$m" --exclude=.terraform --exclude='terraform.tfstate*' -cf - . | tar -C "$dir" -xf -
  if aws s3api head-object --bucket "$BUCKET" --key "$(state_key "$m")" >/dev/null 2>&1; then
    aws s3 cp --quiet "s3://$BUCKET/$(state_key "$m")" "$dir/terraform.tfstate"
  fi
  terraform -chdir="$dir" init -input=false -no-color >"$dir/init.log" 2>&1 \
    || { cat "$dir/init.log"; exit 1; }
  echo "$dir"
}

push_state() {
  local m=$1 dir=$2
  [ -f "$dir/terraform.tfstate" ] && aws s3 cp --quiet "$dir/terraform.tfstate" "s3://$BUCKET/$(state_key "$m")"
  return 0
}

resource_count() { terraform -chdir="$1" state list 2>/dev/null | wc -l | tr -d ' '; }

up() {
  local m=$1 dir rc
  log "UP $m (account $ACCOUNT_ID)"
  dir=$(prepare "$m")
  if [ "$(resource_count "$dir")" -gt 0 ] && [ "${AWSGOAT_FORCE:-0}" != 1 ]; then
    echo "$m is already deployed ($(resource_count "$dir") resources); skipping. Set AWSGOAT_FORCE=1 to re-apply."
    terraform -chdir="$dir" output -no-color || true
    return 0
  fi
  set +e; terraform -chdir="$dir" apply -auto-approve -input=false -no-color; rc=$?; set -e
  push_state "$m" "$dir"
  [ $rc -eq 0 ] && terraform -chdir="$dir" output -no-color
  return $rc
}

down() {
  local m=$1 dir rc
  log "DOWN $m (account $ACCOUNT_ID)"
  dir=$(prepare "$m")
  if [ "$(resource_count "$dir")" -eq 0 ]; then echo "$m is not deployed; nothing to do."; return 0; fi
  set +e; terraform -chdir="$dir" destroy -auto-approve -input=false -no-color; rc=$?; set -e
  push_state "$m" "$dir"
  return $rc
}

status() {
  local m dir
  for m in "${ALL_MODULES[@]}"; do
    dir=$(prepare "$m")
    echo "$m: $(resource_count "$dir") resources"
    if [ "$(resource_count "$dir")" -gt 0 ]; then
      terraform -chdir="$dir" output -no-color 2>/dev/null | sed 's/^/  /' || true
    fi
  done
}

cmd="${1:-}"; shift || true
ensure_bucket
case "$cmd" in
  up)     mods=("$@"); [ ${#mods[@]} -gt 0 ] || mods=("${ALL_MODULES[@]}")
          for m in "${mods[@]}"; do up "$m"; done ;;
  down)   mods=("$@"); [ ${#mods[@]} -gt 0 ] || mods=(module-2 module-1)
          for m in "${mods[@]}"; do down "$m"; done ;;
  status) status ;;
  tf)     m="${1:?module required}"; shift
          dir=$(prepare "$m")
          set +e; terraform -chdir="$dir" "$@"; rc=$?; set -e
          push_state "$m" "$dir"; exit $rc ;;
  *)      sed -n '2,14p' "$0"; exit 2 ;;
esac
