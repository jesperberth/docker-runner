#!/bin/bash
set -e

if [[ -z "${GITHUB_URL}" ]]; then
    echo "GITHUB_URL is required"
    exit 1
fi

if [[ -z "${GITHUB_TOKEN}" && -z "${GITHUB_PAT}" ]]; then
    echo "Set GITHUB_TOKEN (registration token) or GITHUB_PAT (PAT)"
    exit 1
fi

GITHUB_URL="${GITHUB_URL%/}"

# Detect whether a value looks like a PAT. If so, exchange it for a short-lived
# registration/remove token for the configured repo or org.
looks_like_pat() {
    local value="$1"
    [[ "$value" == ghp_* || "$value" == github_pat_* || "$value" == gho_* || "$value" == ghu_* || "$value" == ghs_* ]]
}

resolve_runner_scope() {
    if [[ "$GITHUB_URL" =~ ^https://github.com/([^/]+)/([^/]+)$ ]]; then
        local owner="${BASH_REMATCH[1]}"
        local repo="${BASH_REMATCH[2]}"
        repo="${repo%.git}"
        echo "repos/${owner}/${repo}"
        return 0
    fi

    if [[ "$GITHUB_URL" =~ ^https://github.com/([^/]+)$ ]]; then
        local org="${BASH_REMATCH[1]}"
        echo "orgs/${org}"
        return 0
    fi

    echo "Unsupported GITHUB_URL format: ${GITHUB_URL}" >&2
    echo "Use repo URL: https://github.com/<owner>/<repo> or org URL: https://github.com/<org>" >&2
    return 1
}

request_runner_token() {
    local pat="$1"
    local action="$2"
    local scope_path
    scope_path="$(resolve_runner_scope)"

    curl -fsSL -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${pat}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/${scope_path}/actions/runners/${action}" | jq -r '.token'
}

PAT_VALUE="${GITHUB_PAT:-}"
if [[ -z "${PAT_VALUE}" ]] && looks_like_pat "${GITHUB_TOKEN}"; then
    PAT_VALUE="${GITHUB_TOKEN}"
fi

RUNNER_REG_TOKEN="${GITHUB_TOKEN}"
if [[ -n "${PAT_VALUE}" ]]; then
    RUNNER_REG_TOKEN="$(request_runner_token "${PAT_VALUE}" "registration-token")"
    if [[ -z "${RUNNER_REG_TOKEN}" || "${RUNNER_REG_TOKEN}" == "null" ]]; then
        echo "Failed to create registration token from PAT. Check URL scope and token permissions."
        exit 1
    fi
fi

# Generate dynamic runner name using hostname
RUNNER_NAME="${RUNNER_NAME_PREFIX:-ubuntu-runner}-$(hostname)"

# Register runner with GitHub using a registration token or PAT
./config.sh --url "${GITHUB_URL}" \
            --token "${RUNNER_REG_TOKEN}" \
            --name "${RUNNER_NAME}" \
            --work "_work" \
            --unattended \
            --replace \
            --ephemeral

# Cleanup on shutdown
cleanup() {
    echo "Removing runner..."
    local remove_token="${GITHUB_TOKEN}"
    if [[ -n "${PAT_VALUE}" ]]; then
        remove_token="$(request_runner_token "${PAT_VALUE}" "remove-token")"
    fi

    if [[ -n "${remove_token}" && "${remove_token}" != "null" ]]; then
        ./config.sh remove --token "${remove_token}" || true
    fi
}
trap cleanup EXIT SIGINT SIGTERM

# Run the runner loop
./run.sh