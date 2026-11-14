#!/usr/bin/env bash
# Deploy AWSGoat (all modules by default) from a Docker container, plus the IAM
# testing identities the Prowler fork's --verify active adapters/enrichers need.
#   AWS_PROFILE=awsgoat ./up.sh               # module-1 and module-2
#   AWS_PROFILE=awsgoat ./up.sh module-2      # just one module
set -euo pipefail
dir=$(dirname "$0")
"$dir/deploy/run.sh" up "$@"
"$dir/deploy/testing-identities.sh" up
