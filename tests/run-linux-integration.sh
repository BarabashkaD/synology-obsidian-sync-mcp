#!/bin/bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ID="${TEST_ID:-$$}"
TEST_USER="${TEST_USER:-obsidian-ci-${TEST_ID}}"
TEST_ROOT="${TEST_ROOT:-/tmp/obsidian-sync-mcp-test-${TEST_ID}}"
HOME_ROOT="$TEST_ROOT/homes"
STACK_ROOT="$TEST_ROOT/stacks"
STACK_DIR="$STACK_ROOT/$TEST_USER"
COMPOSE=()
USER_CREATED=0

log() { printf '[TEST] %s\n' "$*"; }
fail() { printf '[TEST ERROR] %s\n' "$*" >&2; exit 1; }

require_safe_test_values() {
    [[ "$TEST_USER" =~ ^obsidian-ci-[A-Za-z0-9_-]+$ ]] \
        || fail "TEST_USER must start with obsidian-ci-"
    [[ "$TEST_ROOT" == /tmp/obsidian-sync-mcp-test-* ]] \
        || fail "TEST_ROOT must be below /tmp/obsidian-sync-mcp-test-*"
}

get_compose_command() {
    if docker compose version >/dev/null 2>&1; then
        COMPOSE=(docker compose)
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE=(docker-compose)
    else
        fail "Docker Compose is not available"
    fi
}

cleanup() {
    local exit_code=$?

    trap - EXIT
    if [[ -f "$STACK_DIR/docker-compose.yml" ]]; then
        (
            cd "$STACK_DIR"
            "${COMPOSE[@]}" down --remove-orphans --volumes
        ) || true
    fi

    if (( USER_CREATED == 1 )) && id "$TEST_USER" >/dev/null 2>&1; then
        userdel "$TEST_USER" || true
    fi

    if [[ "$TEST_ROOT" == /tmp/obsidian-sync-mcp-test-* ]]; then
        rm -rf "$TEST_ROOT"
    fi

    exit "$exit_code"
}

wait_for_couchdb() {
    local url="$1"
    local admin_user="$2"
    local admin_password="$3"

    for _ in $(seq 1 30); do
        curl -fsS -u "$admin_user:$admin_password" "$url/_up" >/dev/null \
            && return 0
        sleep 2
    done
    return 1
}

main() {
    local couchdb_url=""
    local document_url=""
    local status_output=""

    [[ "$(id -u)" -eq 0 ]] || fail "Run this test as root"
    require_safe_test_values
    command -v useradd >/dev/null 2>&1 || fail "useradd is required"
    command -v userdel >/dev/null 2>&1 || fail "userdel is required"
    command -v curl >/dev/null 2>&1 || fail "curl is required"
    docker info >/dev/null 2>&1 || fail "Docker is not running"
    get_compose_command

    trap cleanup EXIT
    mkdir -p "$HOME_ROOT"
    useradd --create-home --home-dir "$HOME_ROOT/$TEST_USER" \
        --shell /bin/bash "$TEST_USER"
    USER_CREATED=1

    log "Running a real installation for $TEST_USER"
    BASE_ROOT="$STACK_ROOT" \
    USER_HOME_ROOT="$HOME_ROOT" \
    NAS_IP="127.0.0.1" \
    COUCHDB_PORT_BASE="15980" \
    MCP_PORT_BASE="18780" \
        "$REPO_ROOT/create-obsidian-user-stack.sh" "$TEST_USER" "CI Vault"

    [[ -f "$STACK_DIR/.env" ]] || fail "Installer did not create .env"
    [[ -f "$STACK_DIR/docker-compose.yml" ]] || fail "Installer did not create Compose configuration"
    [[ -f "$HOME_ROOT/$TEST_USER/.config/obsidian-sync-mcp/connection.txt" ]] \
        || fail "Installer did not create the user connection file"

    # The generated values contain only validated names, addresses, ports and hex secrets.
    set -a
    # shellcheck disable=SC1090
    source "$STACK_DIR/.env"
    set +a

    [[ "$(stat -c '%a' "$STACK_DIR/.env")" == "600" ]] \
        || fail ".env permissions are not 600"
    [[ "$(stat -c '%U' "$HOME_ROOT/$TEST_USER/.config/obsidian-sync-mcp/connection.txt")" == "$TEST_USER" ]] \
        || fail "Connection file owner is incorrect"

    docker inspect -f '{{.State.Running}}' "obsidian-couchdb-$TEST_USER" | grep -qx true \
        || fail "CouchDB container is not running"
    docker inspect -f '{{.State.Running}}' "obsidian-mcp-$TEST_USER" | grep -qx true \
        || fail "MCP container is not running"

    log "Testing MCP authentication, protocol and note tools"
    docker cp "$REPO_ROOT/tests/test-mcp.mjs" \
        "obsidian-mcp-$TEST_USER:/tmp/test-mcp.mjs"
    docker exec \
        -e MCP_URL="http://127.0.0.1:8787/mcp" \
        "obsidian-mcp-$TEST_USER" node /tmp/test-mcp.mjs

    couchdb_url="http://127.0.0.1:$COUCHDB_PORT"
    document_url="$couchdb_url/$COUCHDB_DATABASE/linux-integration-test"

    log "Testing the generated LiveSync account and CouchDB persistence"
    curl -fsS -u "$LIVESYNC_USER:$LIVESYNC_PASSWORD" \
        -H 'Content-Type: application/json' \
        -X PUT "$document_url" \
        --data-binary '{"type":"test","value":"persisted"}' >/dev/null
    curl -fsS -u "$LIVESYNC_USER:$LIVESYNC_PASSWORD" "$document_url" \
        | grep -q '"value":"persisted"' \
        || fail "LiveSync user could not read its document"

    (
        cd "$STACK_DIR"
        "${COMPOSE[@]}" restart couchdb
    )
    wait_for_couchdb "$couchdb_url" "$COUCHDB_ADMIN_USER" "$COUCHDB_ADMIN_PASSWORD" \
        || fail "CouchDB did not recover after restart"
    curl -fsS -u "$LIVESYNC_USER:$LIVESYNC_PASSWORD" "$document_url" \
        | grep -q '"value":"persisted"' \
        || fail "CouchDB document did not survive restart"

    log "Testing status and duplicate protection"
    status_output="$(BASE_ROOT="$STACK_ROOT" USER_HOME_ROOT="$HOME_ROOT" \
        NAS_IP="127.0.0.1" "$REPO_ROOT/create-obsidian-user-stack.sh" --status)"
    grep -Eq "^[[:space:]]*$TEST_USER[[:space:]]+CouchDB=$COUCHDB_PORT MCP=$MCP_PORT$" \
        <<< "$status_output" || fail "Status did not report the installed stack and ports"

    if BASE_ROOT="$STACK_ROOT" USER_HOME_ROOT="$HOME_ROOT" NAS_IP="127.0.0.1" \
        "$REPO_ROOT/create-obsidian-user-stack.sh" "$TEST_USER" "CI Vault"; then
        fail "Duplicate installation unexpectedly succeeded"
    fi

    log "Linux integration test passed"
}

main "$@"
