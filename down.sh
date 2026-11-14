#!/usr/bin/env bash
# Destroy AWSGoat (all modules by default) from a Docker container, plus the IAM
# testing identities.
#   AWS_PROFILE=awsgoat ./down.sh             # module-2 then module-1
#   AWS_PROFILE=awsgoat ./down.sh module-1    # just one module
set -euo pipefail
dir=$(dirname "$0")
"$dir/deploy/testing-identities.sh" down
"$dir/deploy/run.sh" down "$@"
