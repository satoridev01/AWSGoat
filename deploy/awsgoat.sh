#!/usr/bin/env bash
# AWSGoat deploy helper, runs inside the deploy/Dockerfile image.
#
#   awsgoat up   [module-1 module-2 ...]   deploy (default: all modules)
#   awsgoat down [module-1 module-2 ...]   destroy (default: all modules)
#   awsgoat status                         show what is deployed
#   awsgoat check                          list AWSGoat resources left in the account (exit 1 if any)
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

# Lists resources of the types AWSGoat creates that are still in the account.
# Exits 1 if anything is left. Account baseline is ignored: default VPC and its
# security groups, service-linked roles, OrganizationAccountAccessRole, the caller's
# own IAM user, the state bucket, and names in AWSGOAT_CHECK_IGNORE (space separated).
check() {
  local caller ignore found=0 out
  caller=$(aws sts get-caller-identity --query Arn --output text | awk -F/ '{print $NF}')
  ignore=" OrganizationAccountAccessRole $caller $BUCKET ${AWSGOAT_CHECK_IGNORE:-} "
  probe() { # label, aws args...
    local label=$1; shift
    # one name per line (names may contain spaces), minus the ignore list
    out=$(aws "$@" --output text 2>/dev/null | tr '\t' '\n' | grep -v -e '^None$' -e '^$' \
      | while IFS= read -r n; do case "$ignore" in (*" $n "*) ;; (*) echo "$n" ;; esac; done || true)
    if [ -n "$out" ]; then found=1; echo "LEFT  $label: $(printf '%s' "$out" | paste -sd ',' - | sed 's/,/, /g')"
    else echo "ok    $label"; fi
  }
  log "CHECK account $ACCOUNT_ID ($AWS_REGION)"
  probe "EC2 instances"     ec2 describe-instances --filters Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId'
  probe "EC2 key pairs"     ec2 describe-key-pairs --query 'KeyPairs[].KeyName'
  probe "Elastic IPs"       ec2 describe-addresses --query 'Addresses[].PublicIp'
  probe "VPCs (non-default)" ec2 describe-vpcs --filters Name=is-default,Values=false --query 'Vpcs[].VpcId'
  probe "Security groups"   ec2 describe-security-groups --query "SecurityGroups[?GroupName!='default'].GroupId"
  probe "Launch templates"  ec2 describe-launch-templates --query 'LaunchTemplates[].LaunchTemplateName'
  probe "Auto Scaling"      autoscaling describe-auto-scaling-groups --query 'AutoScalingGroups[].AutoScalingGroupName'
  probe "Load balancers"    elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
  probe "Target groups"     elbv2 describe-target-groups --query 'TargetGroups[].TargetGroupName'
  probe "ECS clusters"      ecs list-clusters --query 'clusterArns'
  probe "RDS instances"     rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'
  probe "RDS subnet groups" rds describe-db-subnet-groups --query "DBSubnetGroups[?DBSubnetGroupName!='default'].DBSubnetGroupName"
  probe "Lambda functions"  lambda list-functions --query 'Functions[].FunctionName'
  probe "Lambda layers"     lambda list-layers --query 'Layers[].LayerName'
  probe "API Gateway"       apigateway get-rest-apis --query 'items[].name'
  probe "DynamoDB tables"   dynamodb list-tables --query 'TableNames'
  probe "Secrets"           secretsmanager list-secrets --include-planned-deletion --query 'SecretList[].Name'
  probe "Log groups"        logs describe-log-groups --query 'logGroups[].logGroupName'
  probe "S3 buckets"        s3api list-buckets --query 'Buckets[].Name'
  probe "IAM users"         iam list-users --query 'Users[].UserName'
  probe "IAM roles"         iam list-roles --query "Roles[?!starts_with(Path, '/aws-service-role/')].RoleName"
  probe "IAM policies"      iam list-policies --scope Local --query 'Policies[].PolicyName'
  probe "Instance profiles" iam list-instance-profiles --query 'InstanceProfiles[].InstanceProfileName'
  [ $found -eq 0 ] && echo "CLEAN: nothing left from AWSGoat" || echo "NOT CLEAN: resources above are still in the account"
  return $found
}

cmd="${1:-}"; shift || true
ensure_bucket
case "$cmd" in
  up)     mods=("$@"); [ ${#mods[@]} -gt 0 ] || mods=("${ALL_MODULES[@]}")
          for m in "${mods[@]}"; do up "$m"; done ;;
  down)   mods=("$@"); [ ${#mods[@]} -gt 0 ] || mods=(module-2 module-1)
          for m in "${mods[@]}"; do down "$m"; done ;;
  status) status ;;
  check)  check ;;
  tf)     m="${1:?module required}"; shift
          dir=$(prepare "$m")
          set +e; terraform -chdir="$dir" "$@"; rc=$?; set -e
          push_state "$m" "$dir"; exit $rc ;;
  *)      sed -n '2,15p' "$0"; exit 2 ;;
esac
