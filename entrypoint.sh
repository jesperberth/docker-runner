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

github_api() {
    local method="$1"
    local endpoint="$2"
    curl -fsSL -X "${method}" \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${PAT_VALUE}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/${endpoint}"
}

prune_offline_runners_with_prefix() {
    local enabled="${AUTO_REMOVE_OFFLINE_RUNNERS:-true}"
    if [[ "${enabled}" != "true" ]]; then
        return 0
    fi

    if [[ -z "${PAT_VALUE}" ]]; then
        echo "Skipping offline runner cleanup: set GITHUB_PAT (or PAT in GITHUB_TOKEN) to enable API cleanup."
        return 0
    fi

    local prefix="${RUNNER_NAME_PREFIX:-ubuntu-runner}-"
    local scope_path
    scope_path="$(resolve_runner_scope)"

    echo "Pruning offline runners with prefix '${prefix}'..."
    local response
    response="$(github_api GET "${scope_path}/actions/runners?per_page=100")"

    local ids
    ids="$(echo "${response}" | jq -r --arg prefix "${prefix}" '.runners[] | select((.status == "offline") and (.name | startswith($prefix))) | .id')"

    if [[ -z "${ids}" ]]; then
        echo "No matching offline runners found."
        return 0
    fi

    while IFS= read -r id; do
        [[ -z "${id}" ]] && continue
        github_api DELETE "${scope_path}/actions/runners/${id}" >/dev/null || true
        echo "Removed offline runner id=${id}"
    done <<< "${ids}"
}

cleanup_local_runner_files() {
    rm -f .runner .credentials .credentials_rsaparams || true
}

remove_existing_runner_config_if_any() {
    if [[ -f .runner ]]; then
        echo "Existing runner config detected. Removing local runner state before re-registering..."

        local remove_token="${GITHUB_TOKEN}"
        if [[ -n "${PAT_VALUE}" ]]; then
            remove_token="$(request_runner_token "${PAT_VALUE}" "remove-token")"
        fi

        if [[ -n "${remove_token}" && "${remove_token}" != "null" ]]; then
            ./config.sh remove --token "${remove_token}" --unattended || true
        fi

        cleanup_local_runner_files
    fi
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

prune_offline_runners_with_prefix
remove_existing_runner_config_if_any

# Generate dynamic runner name using hostname
RUNNER_NAME="${RUNNER_NAME_PREFIX:-ubuntu-runner}-$(hostname)"

RUNNER_EPHEMERAL="${RUNNER_EPHEMERAL:-true}"
CONFIG_ARGS=(
    --url "${GITHUB_URL}"
    --token "${RUNNER_REG_TOKEN}"
    --name "${RUNNER_NAME}"
    --work "_work"
    --unattended
    --replace
)

if [[ "${RUNNER_EPHEMERAL}" == "true" ]]; then
    CONFIG_ARGS+=(--ephemeral)
fi

# Register runner with GitHub using a registration token or PAT
./config.sh "${CONFIG_ARGS[@]}"

# Cleanup on shutdown
cleanup() {
    echo "Removing runner..."

    # Ephemeral runners remove themselves after one job, which also deletes local
    # config files. In that case, skip explicit remove to avoid noisy warnings.
    if [[ ! -f .runner ]]; then
        echo "Local runner config already removed; skipping server removal step."
        return 0
    fi

    local remove_token="${GITHUB_TOKEN}"
    if [[ -n "${PAT_VALUE}" ]]; then
        remove_token="$(request_runner_token "${PAT_VALUE}" "remove-token")"
    fi

    if [[ -n "${remove_token}" && "${remove_token}" != "null" ]]; then
        ./config.sh remove --token "${remove_token}" || true
    fi

    cleanup_local_runner_files
}
trap cleanup EXIT SIGINT SIGTERM

# Run the runner loop
./run.sh