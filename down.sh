#!/usr/bin/env bash
# Destroy AWSGoat (all modules by default) from a Docker container.
#   AWS_PROFILE=awsgoat ./down.sh             # module-2 then module-1
#   AWS_PROFILE=awsgoat ./down.sh module-1    # just one module
exec "$(dirname "$0")/deploy/run.sh" down "$@"
