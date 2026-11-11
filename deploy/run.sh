#!/usr/bin/env bash
# Builds the deploy image and runs awsgoat.sh inside it. Only needs Docker.
# Credentials: AWS_PROFILE from ~/.aws (mounted read-only), or AWS_ACCESS_KEY_ID /
# AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN from the environment.
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE=awsgoat-deploy

docker build -q --platform linux/amd64 -t "$IMAGE" deploy >/dev/null

args=(--rm --platform linux/amd64 -v "$PWD:/src:ro")
[ -d "$HOME/.aws" ] && args+=(-v "$HOME/.aws:/root/.aws:ro")
for v in AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION AWSGOAT_FORCE AWSGOAT_STATE_BUCKET; do
  [ -n "${!v:-}" ] && args+=(-e "$v")
done
[ -t 1 ] && args+=(-t)

exec docker run "${args[@]}" "$IMAGE" "$@"
