#! /bin/bash

# Set strict mode
set -eux

echo "Running the teuthology runner ..."

echo "Ceph Branch: ${BRANCH}"
echo "Runner parameters: ${RUNNER_PARAMS}"

# Set teuthology run name
export TEUTHOLOGY_RUN_NAME="teuthology-run-${BRANCH}-${BUILD_NUMBER}"
