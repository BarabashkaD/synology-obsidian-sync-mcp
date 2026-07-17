#!/bin/bash
set -Eeuo pipefail

BASE_ROOT="/volume1/docker/obsidian-users"
MCP_IMAGE="ghcr.io/es617/obsidian-sync-mcp:latest"
COUCHDB_IMAGE="couchdb:3"
CURL_IMAGE="curlimages/curl:8.10.1"
LOCK_DIR="${BASE_ROOT}/.create.lock"
INSTALL_IN_PROGRESS=0
BASE_DIR=""
USER_CONNECTION_FILE=""

log()  { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "Run this script as root: sudo -i"
}

find_command() {
    command -v "$1" 2>/dev/null || true
}

get_compose_command() {
    if docker compose version >/dev/null 2>&1; then
        COMPOSE=(docker compose)
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE=(docker-compose)
    else
        die "Docker Compose is not available"
    fi
}

http_request() {
    if command -v curl >/dev/null 2>&1; then
        curl "$@"
    else
        docker run --rm --network host "$CURL_IMAGE" "$@"
    fi
}

prepare_http_client() {
    if command -v curl >/dev/null 2>&1; then
        log "Using host curl"
        return 0
    fi

    log "Host curl is not installed; using Docker helper: $CURL_IMAGE"
    docker image inspect "$CURL_IMAGE" >/dev/null 2>&1 \
        || docker pull "$CURL_IMAGE"
}

get_user_home() {
    local user="$1"
    local home=""

    if command -v getent >/dev/null 2>&1; then
        home="$(getent passwd "$user" 2>/dev/null | awk -F: 'NR==1 {print $6}')"
    fi

    if [[ -z "$home" ]]; then
        home="$(awk -F: -v u="$user" '$1==u {print $6; exit}' /etc/passwd 2>/dev/null || true)"
    fi

    if [[ -z "$home" || "$home" == "/var/services/homes" ]]; then
        home="/var/services/homes/${user}"
    fi

    printf '%s\n' "$home"
}

check_synology_user_and_home() {
    local user="$1"
    local synouser_bin=""

    synouser_bin="$(find_command synouser)"
    if [[ -z "$synouser_bin" && -x /usr/syno/sbin/synouser ]]; then
        synouser_bin="/usr/syno/sbin/synouser"
    fi

    if [[ -n "$synouser_bin" ]]; then
        "$synouser_bin" --get "$user" >/dev/null 2>&1 \
            || die "Synology local user '$user' does not exist"
    else
        id "$user" >/dev/null 2>&1 \
            || die "Local user '$user' does not exist"
    fi

    id "$user" >/dev/null 2>&1 \
        || die "User '$user' is not available through the local account database"

    [[ -d /var/services/homes ]] \
        || die "Synology User Home service is not enabled: /var/services/homes is missing"

    USER_HOME="$(get_user_home "$user")"

    [[ "$USER_HOME" == /var/services/homes/* ]] \
        || die "User '$user' does not use Synology User Home: detected home '$USER_HOME'"

    [[ -d "$USER_HOME" ]] \
        || die "Home directory '$USER_HOME' does not exist. Enable User Home service and sign in once as '$user'"

    USER_GROUP="$(id -gn "$user")"
    [[ -n "$USER_GROUP" ]] || die "Cannot determine primary group for '$user'"

    log "Synology user: $user"
    log "Home directory: $USER_HOME"
}

is_private_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^10\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && return 0
    [[ "$ip" =~ ^192\.168\.[0-9]+\.[0-9]+$ ]] && return 0
    [[ "$ip" =~ ^172\.([1][6-9]|2[0-9]|3[0-1])\.[0-9]+\.[0-9]+$ ]] && return 0
    return 1
}

detect_nas_ip() {
    local ip_bin=""
    local candidate=""

    ip_bin="$(find_command ip)"
    if [[ -z "$ip_bin" && -x /sbin/ip ]]; then
        ip_bin="/sbin/ip"
    fi

    if [[ -n "$ip_bin" ]]; then
        candidate="$($ip_bin -4 route get 1.1.1.1 2>/dev/null \
            | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
    fi

    if ! is_private_ipv4 "$candidate"; then
        candidate=""
    fi

    if [[ -z "$candidate" ]] && command -v hostname >/dev/null 2>&1; then
        while read -r address; do
            if is_private_ipv4 "$address"; then
                candidate="$address"
                break
            fi
        done < <(hostname -I 2>/dev/null | tr ' ' '\n')
    fi

    if [[ -z "$candidate" ]] && command -v ifconfig >/dev/null 2>&1; then
        while read -r address; do
            if is_private_ipv4 "$address"; then
                candidate="$address"
                break
            fi
        done < <(ifconfig 2>/dev/null \
            | awk '/inet addr:/ {sub("addr:","",$2); print $2} /inet / && $2 !~ /:/ {print $2}')
    fi

    [[ -n "$candidate" ]] \
        || die "Cannot determine the private LAN IPv4 address of this NAS"

    NAS_IP="$candidate"
    log "Detected NAS LAN IP: $NAS_IP"
}

list_stack_ids() {
    local dir=""

    if [[ -d "$BASE_ROOT" ]]; then
        for dir in "$BASE_ROOT"/*; do
            [[ -d "$dir" && -f "$dir/.env" ]] || continue
            basename "$dir"
        done
    fi

    if command -v docker >/dev/null 2>&1; then
        docker ps -a --format '{{.Image}} {{.Names}}' 2>/dev/null \
            | awk '$1 ~ /es617\/obsidian-sync-mcp/ {
                name=$2
                sub(/^obsidian-mcp-/, "", name)
                if (name != "") print name
            }'
    fi
}

show_status() {
    local ids=""
    local configured=0
    local all_mcp=0
    local running_mcp=0
    local env_file=""

    mkdir -p "$BASE_ROOT"

    ids="$(list_stack_ids | sed '/^$/d' | sort -u || true)"
    if [[ -n "$ids" ]]; then
        configured="$(printf '%s\n' "$ids" | wc -l | tr -d ' ')"
    fi

    all_mcp="$(docker ps -a --format '{{.Image}}' 2>/dev/null \
        | grep -c 'es617/obsidian-sync-mcp' || true)"
    running_mcp="$(docker ps --format '{{.Image}}' 2>/dev/null \
        | grep -c 'es617/obsidian-sync-mcp' || true)"

    log "Detected Obsidian user stacks: $configured"
    log "MCP containers: $all_mcp total, $running_mcp running"

    for env_file in "$BASE_ROOT"/*/.env; do
        [[ -f "$env_file" ]] || continue
        printf '  %-20s CouchDB=%s MCP=%s\n' \
            "$(basename "$(dirname "$env_file")")" \
            "$(sed -n 's/^COUCHDB_PORT=//p' "$env_file" | head -n1)" \
            "$(sed -n 's/^MCP_PORT=//p' "$env_file" | head -n1)"
    done
}

port_in_env_files() {
    local port="$1"
    local env_file=""

    for env_file in "$BASE_ROOT"/*/.env; do
        [[ -f "$env_file" ]] || continue
        if grep -Eq "^(COUCHDB_PORT|MCP_PORT)=${port}$" "$env_file"; then
            return 0
        fi
    done

    return 1
}

port_in_use() {
    local port="$1"

    port_in_env_files "$port" && return 0

    if [[ -n "$(docker ps -aq --filter "publish=${port}" 2>/dev/null)" ]]; then
        return 0
    fi

    if docker ps -a --format '{{.Ports}}' 2>/dev/null \
        | grep -Eq "(^|[[:space:],])([^,]*:)?${port}->"; then
        return 0
    fi

    if command -v ss >/dev/null 2>&1; then
        if ss -ltn 2>/dev/null | awk 'NR>1 {print $4}' \
            | grep -Eq "(^|:|\])${port}$"; then
            return 0
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -ltn 2>/dev/null | awk 'NR>2 {print $4}' \
            | grep -Eq "(^|:|\])${port}$"; then
            return 0
        fi
    fi

    return 1
}

select_free_ports() {
    local index=0
    local couchdb_port=0
    local mcp_port=0

    for index in $(seq 1 200); do
        couchdb_port=$((5980 + index))
        mcp_port=$((8780 + index))

        if ! port_in_use "$couchdb_port" && ! port_in_use "$mcp_port"; then
            COUCHDB_PORT="$couchdb_port"
            MCP_PORT="$mcp_port"
            log "Selected free ports: CouchDB=$COUCHDB_PORT, MCP=$MCP_PORT"
            return 0
        fi
    done

    die "Cannot find a free CouchDB/MCP port pair"
}

validate_arguments() {
    local vault_name_re='^[A-Za-z0-9._ -]+$'

    [[ "$DSM_USER" =~ ^[A-Za-z0-9._-]+$ ]] \
        || die "Invalid Synology username"

    [[ "$VAULT_NAME" =~ $vault_name_re ]] \
        || die "Vault name may contain only letters, digits, spaces, dot, underscore and hyphen"

    STACK_ID="$(printf '%s' "$DSM_USER" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9_.-]/-/g')"

    [[ -n "$STACK_ID" ]] || die "Cannot generate stack ID"
}

write_couchdb_config() {
    cat > "$BASE_DIR/config/livesync.ini" <<'EOF'
[couchdb]
single_node=true
max_document_size=50000000

[chttpd]
require_valid_user=true
max_http_request_size=4294967296
enable_cors=true
bind_address=0.0.0.0

[chttpd_auth]
require_valid_user=true

[httpd]
WWW-Authenticate=Basic realm="couchdb"
enable_cors=true
bind_address=0.0.0.0

[cors]
origins=app://obsidian.md,capacitor://localhost,http://localhost
credentials=true
methods=GET,PUT,POST,HEAD,DELETE
headers=accept,authorization,content-type,origin,referer,cache-control
max_age=3600
EOF

    chown root:root "$BASE_DIR/config/livesync.ini"
    chmod 644 "$BASE_DIR/config/livesync.ini"
}

write_env_file() {
    local safe_vault_name="${VAULT_NAME//\"/\\\"}"

    umask 077
    cat > "$BASE_DIR/.env" <<EOF
NAS_IP=${NAS_IP}
STACK_ID=${STACK_ID}
DSM_USER=${DSM_USER}
VAULT_NAME="${safe_vault_name}"

COUCHDB_ADMIN_USER=admin
COUCHDB_ADMIN_PASSWORD=${COUCHDB_ADMIN_PASSWORD}
COUCHDB_DATABASE=obsidian
COUCHDB_PORT=${COUCHDB_PORT}

LIVESYNC_USER=${STACK_ID}
LIVESYNC_PASSWORD=${LIVESYNC_PASSWORD}

COUCHDB_PASSPHRASE=${COUCHDB_PASSPHRASE}
COUCHDB_OBFUSCATE_PROPERTIES=true

MCP_AUTH_TOKEN=${MCP_AUTH_TOKEN}
MCP_PORT=${MCP_PORT}
EOF

    chown root:root "$BASE_DIR/.env"
    chmod 600 "$BASE_DIR/.env"
}

write_compose_file() {
    cat > "$BASE_DIR/docker-compose.yml" <<EOF
services:
  couchdb:
    image: ${COUCHDB_IMAGE}
    container_name: obsidian-couchdb-${STACK_ID}
    restart: unless-stopped

    ports:
      - "${NAS_IP}:${COUCHDB_PORT}:5984"

    environment:
      COUCHDB_USER: "${COUCHDB_ADMIN_USER}"
      COUCHDB_PASSWORD: "${COUCHDB_ADMIN_PASSWORD}"

    volumes:
      - ./couchdb-data:/opt/couchdb/data
      - ./config/livesync.ini:/opt/couchdb/etc/local.d/livesync.ini:ro

  mcp:
    image: ${MCP_IMAGE}
    container_name: obsidian-mcp-${STACK_ID}
    restart: unless-stopped

    ports:
      - "${NAS_IP}:${MCP_PORT}:8787"

    environment:
      COUCHDB_URL: "http://couchdb:5984"
      COUCHDB_USER: "${LIVESYNC_USER}"
      COUCHDB_PASSWORD: "${LIVESYNC_PASSWORD}"
      COUCHDB_DATABASE: "${COUCHDB_DATABASE}"
      COUCHDB_PASSPHRASE: "${COUCHDB_PASSPHRASE}"
      COUCHDB_OBFUSCATE_PROPERTIES: "${COUCHDB_OBFUSCATE_PROPERTIES}"
      VAULT_NAME: "${VAULT_NAME}"
      MCP_AUTH_TOKEN: "${MCP_AUTH_TOKEN}"
      BASE_URL: "http://${NAS_IP}:${MCP_PORT}"
      DATA_DIR: "/data"
      MCP_REFRESH_DAYS: "14"

    volumes:
      - ./mcp-data:/data

    depends_on:
      - couchdb
EOF

    chown root:root "$BASE_DIR/docker-compose.yml"
    chmod 600 "$BASE_DIR/docker-compose.yml"
}

write_user_connection_file() {
    USER_SECRET_DIR="$USER_HOME/.config/obsidian-sync-mcp"
    USER_CONNECTION_FILE="$USER_SECRET_DIR/connection.txt"

    mkdir -p "$USER_SECRET_DIR"
    cat > "$USER_CONNECTION_FILE" <<EOF
OBSIDIAN LIVESYNC
Server URI: http://${NAS_IP}:${COUCHDB_PORT}
Username: ${STACK_ID}
Password: ${LIVESYNC_PASSWORD}
Database: obsidian
E2EE passphrase: ${COUCHDB_PASSPHRASE}
Obfuscate Properties: true

OBSIDIAN MCP
Endpoint: http://${NAS_IP}:${MCP_PORT}/mcp
Auth token: ${MCP_AUTH_TOKEN}
Vault name: ${VAULT_NAME}
EOF

    chown -R "$DSM_USER:$USER_GROUP" "$USER_SECRET_DIR"
    chmod 700 "$USER_SECRET_DIR"
    chmod 600 "$USER_CONNECTION_FILE"
}

wait_for_couchdb() {
    log "Waiting for CouchDB"
    for _ in $(seq 1 60); do
        if http_request -fsS \
            -u "${COUCHDB_ADMIN_USER}:${COUCHDB_ADMIN_PASSWORD}" \
            "http://${NAS_IP}:${COUCHDB_PORT}/_up" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done

    return 1
}

initialize_couchdb() {
    local database=""

    for database in _users _replicator _global_changes "$COUCHDB_DATABASE"; do
        http_request -sS \
            -u "${COUCHDB_ADMIN_USER}:${COUCHDB_ADMIN_PASSWORD}" \
            -X PUT "http://${NAS_IP}:${COUCHDB_PORT}/${database}" >/dev/null
    done

    http_request -fsS \
        -u "${COUCHDB_ADMIN_USER}:${COUCHDB_ADMIN_PASSWORD}" \
        -X PUT \
        "http://${NAS_IP}:${COUCHDB_PORT}/_users/org.couchdb.user:${LIVESYNC_USER}" \
        -H "Content-Type: application/json" \
        --data-binary "{
            \"name\":\"${LIVESYNC_USER}\",
            \"password\":\"${LIVESYNC_PASSWORD}\",
            \"roles\":[],
            \"type\":\"user\"
        }" >/dev/null

    http_request -fsS \
        -u "${COUCHDB_ADMIN_USER}:${COUCHDB_ADMIN_PASSWORD}" \
        -X PUT \
        "http://${NAS_IP}:${COUCHDB_PORT}/${COUCHDB_DATABASE}/_security" \
        -H "Content-Type: application/json" \
        --data-binary "{
            \"admins\":{
                \"names\":[\"${COUCHDB_ADMIN_USER}\"],
                \"roles\":[]
            },
            \"members\":{
                \"names\":[\"${LIVESYNC_USER}\"],
                \"roles\":[]
            }
        }" >/dev/null

    http_request -fsS \
        -u "${LIVESYNC_USER}:${LIVESYNC_PASSWORD}" \
        "http://${NAS_IP}:${COUCHDB_PORT}/${COUCHDB_DATABASE}" >/dev/null
}

wait_for_mcp() {
    local status=""

    log "Waiting for MCP HTTP endpoint"
    for _ in $(seq 1 60); do
        status="$(http_request -sS -o /dev/null -w '%{http_code}' \
            "http://${NAS_IP}:${MCP_PORT}/mcp" 2>/dev/null || true)"

        if [[ "$status" =~ ^[1-5][0-9][0-9]$ ]]; then
            return 0
        fi
        sleep 2
    done

    return 1
}

cleanup_on_exit() {
    local exit_code=$?

    trap - EXIT
    rmdir "$LOCK_DIR" 2>/dev/null || true

    if [[ "$exit_code" -ne 0 && "$INSTALL_IN_PROGRESS" -eq 1 ]]; then
        warn "Installation failed; removing the incomplete stack"

        if [[ -n "$BASE_DIR" && -d "$BASE_DIR" ]]; then
            (
                cd "$BASE_DIR" 2>/dev/null || exit 0
                "${COMPOSE[@]}" down --remove-orphans >/dev/null 2>&1 || true
            )
            rm -rf "$BASE_DIR"
        fi

        if [[ -n "$USER_CONNECTION_FILE" ]]; then
            rm -f "$USER_CONNECTION_FILE"
        fi
    fi

    exit "$exit_code"
}

main() {
    require_root

    command -v docker >/dev/null 2>&1 || die "Docker is not installed"
    docker info >/dev/null 2>&1 || die "Docker service is not running"
    command -v openssl >/dev/null 2>&1 || die "openssl is not available"

    get_compose_command
    prepare_http_client
    mkdir -p "$BASE_ROOT"
    chmod 700 "$BASE_ROOT"

    if [[ "${1:-}" == "--status" ]]; then
        show_status
        exit 0
    fi

    [[ $# -ge 1 && $# -le 2 ]] || {
        echo "Usage:"
        echo "  $0 SYNOLOGY_USER [VAULT_NAME]"
        echo "  $0 --status"
        exit 1
    }

    DSM_USER="$1"
    VAULT_NAME="${2:-${DSM_USER}Vault}"

    validate_arguments
    check_synology_user_and_home "$DSM_USER"
    detect_nas_ip

    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        die "Another stack creation process is already running"
    fi
    trap cleanup_on_exit EXIT

    show_status

    BASE_DIR="$BASE_ROOT/$STACK_ID"
    [[ ! -e "$BASE_DIR" ]] \
        || die "Stack '$STACK_ID' already exists at $BASE_DIR"

    if docker ps -a --format '{{.Names}}' \
        | grep -Eq "^(obsidian-couchdb|obsidian-mcp)-${STACK_ID}$"; then
        die "Docker containers for stack '$STACK_ID' already exist"
    fi

    select_free_ports

    COUCHDB_ADMIN_USER="admin"
    COUCHDB_ADMIN_PASSWORD="$(openssl rand -hex 24)"
    COUCHDB_DATABASE="obsidian"
    COUCHDB_OBFUSCATE_PROPERTIES="true"

    LIVESYNC_USER="$STACK_ID"
    LIVESYNC_PASSWORD="$(openssl rand -hex 24)"

    COUCHDB_PASSPHRASE="$(openssl rand -hex 32)"
    MCP_AUTH_TOKEN="$(openssl rand -hex 32)"

    mkdir -p \
        "$BASE_DIR/config" \
        "$BASE_DIR/couchdb-data" \
        "$BASE_DIR/mcp-data"

    chown root:root "$BASE_DIR" "$BASE_DIR/config" \
        "$BASE_DIR/couchdb-data" "$BASE_DIR/mcp-data"
    chmod 700 "$BASE_DIR" "$BASE_DIR/config" \
        "$BASE_DIR/couchdb-data" "$BASE_DIR/mcp-data"

    INSTALL_IN_PROGRESS=1

    write_couchdb_config
    write_env_file
    write_compose_file

    cd "$BASE_DIR"

    "${COMPOSE[@]}" config >/dev/null
    "${COMPOSE[@]}" pull
    "${COMPOSE[@]}" up -d couchdb

    wait_for_couchdb || die "CouchDB did not become ready"
    initialize_couchdb

    "${COMPOSE[@]}" up -d mcp
    wait_for_mcp || die "MCP did not become ready"

    write_user_connection_file

    INSTALL_IN_PROGRESS=0

    log "Stack created successfully"
    log "User: $DSM_USER"
    log "CouchDB: http://${NAS_IP}:${COUCHDB_PORT}"
    log "MCP: http://${NAS_IP}:${MCP_PORT}/mcp"
    log "Root configuration: $BASE_DIR"
    log "User connection file: $USER_CONNECTION_FILE"

    "${COMPOSE[@]}" ps
}

main "$@"
