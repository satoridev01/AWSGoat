#!/usr/bin/env bash
# Deploy AWSGoat (all modules by default) from a Docker container.
#   AWS_PROFILE=awsgoat ./up.sh               # module-1 and module-2
#   AWS_PROFILE=awsgoat ./up.sh module-2      # just one module
exec "$(dirname "$0")/deploy/run.sh" up "$@"
