#!/bin/bash
set -e

# Generate dynamic runner name using hostname
RUNNER_NAME="${RUNNER_NAME_PREFIX:-ubuntu-runner}-$(hostname)"

# Register runner with GitHub using a registration token or PAT
./config.sh --url "${GITHUB_URL}" \
            --token "${GITHUB_TOKEN}" \
            --name "${RUNNER_NAME}" \
            --work "_work" \
            --unattended \
            --replace \
            --ephemeral

# Cleanup on shutdown
cleanup() {
    echo "Removing runner..."
    ./config.sh remove --token "${GITHUB_TOKEN}"
}
trap cleanup EXIT SIGINT SIGTERM

# Run the runner loop
./run.sh