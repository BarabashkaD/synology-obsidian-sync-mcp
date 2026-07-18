#!/bin/bash
set -Eeuo pipefail

BASE_ROOT="${BASE_ROOT:-/volume1/docker/obsidian-users}"
USER_HOME_ROOT="${USER_HOME_ROOT:-/var/services/homes}"
NAS_IP="${NAS_IP:-}"
DEPLOYMENT_MODE="${DEPLOYMENT_MODE:-dsm-reverse-proxy}"
NAS_HOSTNAME="${NAS_HOSTNAME:-}"
OBSIDIAN_DOMAIN="${OBSIDIAN_DOMAIN:-}"
SHOW_SECRETS_IN_REPORT="${SHOW_SECRETS_IN_REPORT:-true}"
# Upstream package version 0.5.2. GHCR does not publish versioned tags.
MCP_IMAGE="${MCP_IMAGE:-ghcr.io/es617/obsidian-sync-mcp@sha256:59ab4dbe7af00417331c37c1c260df320d3bbd1bb7c6a3386a5d4c1c0ece5850}"
COUCHDB_IMAGE="${COUCHDB_IMAGE:-couchdb:3}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.10.1}"
COUCHDB_UID="${COUCHDB_UID:-5984}"
COUCHDB_GID="${COUCHDB_GID:-5984}"
COUCHDB_PORT_BASE="${COUCHDB_PORT_BASE:-5980}"
MCP_PORT_BASE="${MCP_PORT_BASE:-8780}"
LOCK_DIR="${BASE_ROOT}/.create.lock"
INSTALL_IN_PROGRESS=0
BASE_DIR=""
USER_CONNECTION_FILE=""
SERVICE_BIND_IP=""
INTERNAL_SERVICE_IP=""
COUCHDB_PUBLIC_URL=""
MCP_PUBLIC_URL=""
SERVICE_ID=""

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

    if [[ -z "$home" || "$home" == "$USER_HOME_ROOT" ]]; then
        home="${USER_HOME_ROOT}/${user}"
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

    [[ -d "$USER_HOME_ROOT" ]] \
        || die "User home root is missing: $USER_HOME_ROOT"

    USER_HOME="$(get_user_home "$user")"

    [[ "$USER_HOME" == "$USER_HOME_ROOT"/* ]] \
        || die "User '$user' has home '$USER_HOME', outside '$USER_HOME_ROOT'"

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

is_ipv4() {
    local ip="$1"
    local octet=""
    local -a octets=()

    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
        (( 10#$octet <= 255 )) || return 1
    done
}

detect_nas_ip() {
    local ip_bin=""
    local candidate=""

    if [[ -n "$NAS_IP" ]]; then
        is_ipv4 "$NAS_IP" || die "Configured NAS_IP is not a valid IPv4 address: $NAS_IP"
        log "Using configured service IP: $NAS_IP"
        return 0
    fi

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

is_dns_name() {
    local name="$1"
    [[ ${#name} -le 253 ]] || return 1
    [[ "$name" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
    [[ "$name" == *.* ]] || return 1
    [[ "$name" != *..* ]]
}

resolve_ipv4() {
    local name="$1"

    if command -v getent >/dev/null 2>&1; then
        getent ahostsv4 "$name" 2>/dev/null | awk '{print $1}' | sort -u
    elif command -v nslookup >/dev/null 2>&1; then
        nslookup "$name" 2>/dev/null \
            | awk '/^Address: / {print $2}' | grep -E '^[0-9]+(\.[0-9]+){3}$' \
            | sort -u
    else
        die "DNS validation requires getent or nslookup"
    fi
}

detect_nas_hostname() {
    local detected=""

    if [[ -n "$NAS_HOSTNAME" ]]; then
        detected="${NAS_HOSTNAME%.}"
    else
        detected="$(hostname -f 2>/dev/null || true)"
        detected="${detected%.}"
    fi

    is_dns_name "$detected" \
        || die "Cannot detect a fully qualified NAS hostname. Set NAS_HOSTNAME, for example nas.home.example.com"

    NAS_HOSTNAME="${detected,,}"
    OBSIDIAN_DOMAIN="${OBSIDIAN_DOMAIN:-$NAS_HOSTNAME}"
    OBSIDIAN_DOMAIN="${OBSIDIAN_DOMAIN%.}"
    is_dns_name "$OBSIDIAN_DOMAIN" \
        || die "OBSIDIAN_DOMAIN must be a fully qualified DNS name"

    COUCHDB_HOSTNAME="${SERVICE_ID}-sync.${OBSIDIAN_DOMAIN}"
    MCP_HOSTNAME="${SERVICE_ID}-mcp.${OBSIDIAN_DOMAIN}"

    log "NAS hostname: $NAS_HOSTNAME"
    log "Obsidian service domain: $OBSIDIAN_DOMAIN"
}

validate_service_hostname_availability() {
    local env_file=""
    local configured_hostname=""

    for env_file in "$BASE_ROOT"/*/.env; do
        [[ -f "$env_file" ]] || continue
        while IFS= read -r configured_hostname; do
            if [[ "$configured_hostname" == "$COUCHDB_HOSTNAME" \
                || "$configured_hostname" == "$MCP_HOSTNAME" ]]; then
                die "Service hostname '$configured_hostname' is already used by stack '$(basename "$(dirname "$env_file")")'"
            fi
        done < <(sed -n -e 's/^COUCHDB_HOSTNAME=//p' -e 's/^MCP_HOSTNAME=//p' "$env_file")
    done
}

validate_proxy_dns() {
    local hostname=""
    local addresses=""

    for hostname in "$NAS_HOSTNAME" "$COUCHDB_HOSTNAME" "$MCP_HOSTNAME"; do
        addresses="$(resolve_ipv4 "$hostname" || true)"
        if ! grep -Fxq "$NAS_IP" <<< "$addresses"; then
            warn "DNS lookup for '$hostname' returned: ${addresses:-no IPv4 address}"
            die "Local DNS must resolve '$hostname' to NAS address $NAS_IP"
        fi
    done

    log "Validated NAS and per-user service names in local DNS"
}

configure_deployment() {
    case "$DEPLOYMENT_MODE" in
        dsm-reverse-proxy)
            detect_nas_hostname
            validate_proxy_dns
            validate_service_hostname_availability
            SERVICE_BIND_IP="127.0.0.1"
            INTERNAL_SERVICE_IP="127.0.0.1"
            COUCHDB_PUBLIC_URL="https://${COUCHDB_HOSTNAME}"
            MCP_PUBLIC_URL="https://${MCP_HOSTNAME}"
            ;;
        direct-http)
            SERVICE_BIND_IP="$NAS_IP"
            INTERNAL_SERVICE_IP="$NAS_IP"
            COUCHDB_HOSTNAME=""
            MCP_HOSTNAME=""
            COUCHDB_PUBLIC_URL="http://${NAS_IP}:${COUCHDB_PORT}"
            MCP_PUBLIC_URL="http://${NAS_IP}:${MCP_PORT}"
            ;;
        *)
            die "DEPLOYMENT_MODE must be 'dsm-reverse-proxy' or 'direct-http'"
            ;;
    esac
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
        couchdb_port=$((COUCHDB_PORT_BASE + index))
        mcp_port=$((MCP_PORT_BASE + index))

        if ! port_in_use "$couchdb_port" && ! port_in_use "$mcp_port"; then
            COUCHDB_PORT="$couchdb_port"
            MCP_PORT="$mcp_port"
            log "Selected free ports: CouchDB=$COUCHDB_PORT, MCP=$MCP_PORT"
            return 0
        fi
    done

    die "Cannot find a free CouchDB/MCP port pair"
}

validate_runtime_config() {
    [[ "$BASE_ROOT" == /* && "$BASE_ROOT" != "/" ]] \
        || die "BASE_ROOT must be an absolute path other than /"
    [[ "$USER_HOME_ROOT" == /* && "$USER_HOME_ROOT" != "/" ]] \
        || die "USER_HOME_ROOT must be an absolute path other than /"

    [[ "$COUCHDB_PORT_BASE" =~ ^[0-9]+$ ]] \
        || die "COUCHDB_PORT_BASE must be numeric"
    [[ "$MCP_PORT_BASE" =~ ^[0-9]+$ ]] \
        || die "MCP_PORT_BASE must be numeric"
    [[ "$COUCHDB_UID" =~ ^[0-9]+$ ]] || die "COUCHDB_UID must be numeric"
    [[ "$COUCHDB_GID" =~ ^[0-9]+$ ]] || die "COUCHDB_GID must be numeric"
    (( COUCHDB_PORT_BASE >= 1024 && COUCHDB_PORT_BASE <= 65335 )) \
        || die "COUCHDB_PORT_BASE must be between 1024 and 65335"
    (( MCP_PORT_BASE >= 1024 && MCP_PORT_BASE <= 65335 )) \
        || die "MCP_PORT_BASE must be between 1024 and 65335"

    [[ "$DEPLOYMENT_MODE" == "dsm-reverse-proxy" || "$DEPLOYMENT_MODE" == "direct-http" ]] \
        || die "DEPLOYMENT_MODE must be 'dsm-reverse-proxy' or 'direct-http'"
    [[ "$SHOW_SECRETS_IN_REPORT" == "true" || "$SHOW_SECRETS_IN_REPORT" == "false" ]] \
        || die "SHOW_SECRETS_IN_REPORT must be 'true' or 'false'"
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

    SERVICE_ID="$(printf '%s' "$STACK_ID" \
        | sed 's/[^a-z0-9-]/-/g; s/^-*//; s/-*$//')"

    [[ -n "$STACK_ID" ]] || die "Cannot generate stack ID"
    [[ -n "$SERVICE_ID" ]] || die "Cannot generate DNS service ID"
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

    chown "$COUCHDB_UID:$COUCHDB_GID" "$BASE_DIR/config/livesync.ini"
    chmod 644 "$BASE_DIR/config/livesync.ini"
}

write_env_file() {
    local safe_vault_name="${VAULT_NAME//\"/\\\"}"

    umask 077
    cat > "$BASE_DIR/.env" <<EOF
NAS_IP=${NAS_IP}
STACK_ID=${STACK_ID}
SERVICE_ID=${SERVICE_ID}
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

DEPLOYMENT_MODE=${DEPLOYMENT_MODE}
SERVICE_BIND_IP=${SERVICE_BIND_IP}
COUCHDB_HOSTNAME=${COUCHDB_HOSTNAME}
MCP_HOSTNAME=${MCP_HOSTNAME}
COUCHDB_PUBLIC_URL=${COUCHDB_PUBLIC_URL}
MCP_PUBLIC_URL=${MCP_PUBLIC_URL}
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
      - "${SERVICE_BIND_IP}:${COUCHDB_PORT}:5984"

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
      - "${SERVICE_BIND_IP}:${MCP_PORT}:8787"

    environment:
      COUCHDB_URL: "http://couchdb:5984"
      COUCHDB_USER: "${LIVESYNC_USER}"
      COUCHDB_PASSWORD: "${LIVESYNC_PASSWORD}"
      COUCHDB_DATABASE: "${COUCHDB_DATABASE}"
      COUCHDB_PASSPHRASE: "${COUCHDB_PASSPHRASE}"
      COUCHDB_OBFUSCATE_PROPERTIES: "${COUCHDB_OBFUSCATE_PROPERTIES}"
      VAULT_NAME: "${VAULT_NAME}"
      MCP_AUTH_TOKEN: "${MCP_AUTH_TOKEN}"
      BASE_URL: "${MCP_PUBLIC_URL}"
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
Server URI: ${COUCHDB_PUBLIC_URL}
Username: ${STACK_ID}
Password: ${LIVESYNC_PASSWORD}
Database: obsidian
E2EE passphrase: ${COUCHDB_PASSPHRASE}
Obfuscate Properties: true

OBSIDIAN MCP
Endpoint: ${MCP_PUBLIC_URL}/mcp
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
            "http://${INTERNAL_SERVICE_IP}:${COUCHDB_PORT}/_up" >/dev/null 2>&1; then
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
            -X PUT "http://${INTERNAL_SERVICE_IP}:${COUCHDB_PORT}/${database}" >/dev/null
    done

    http_request -fsS \
        -u "${COUCHDB_ADMIN_USER}:${COUCHDB_ADMIN_PASSWORD}" \
        -X PUT \
        "http://${INTERNAL_SERVICE_IP}:${COUCHDB_PORT}/_users/org.couchdb.user:${LIVESYNC_USER}" \
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
        "http://${INTERNAL_SERVICE_IP}:${COUCHDB_PORT}/${COUCHDB_DATABASE}/_security" \
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
        "http://${INTERNAL_SERVICE_IP}:${COUCHDB_PORT}/${COUCHDB_DATABASE}" >/dev/null
}

wait_for_mcp() {
    local status=""

    log "Waiting for MCP HTTP endpoint"
    for _ in $(seq 1 60); do
        status="$(http_request -sS -o /dev/null -w '%{http_code}' \
            "http://${INTERNAL_SERVICE_IP}:${MCP_PORT}/mcp" 2>/dev/null || true)"

        if [[ "$status" =~ ^[1-5][0-9][0-9]$ ]]; then
            return 0
        fi
        sleep 2
    done

    return 1
}

print_installation_report() {
    local report_livesync_password="$LIVESYNC_PASSWORD"
    local report_passphrase="$COUCHDB_PASSPHRASE"
    local report_mcp_token="$MCP_AUTH_TOKEN"

    if [[ "$SHOW_SECRETS_IN_REPORT" == "false" ]]; then
        report_livesync_password="<stored in user connection file>"
        report_passphrase="<stored in user connection file>"
        report_mcp_token="<stored in user connection file>"
    fi

    if [[ "$DEPLOYMENT_MODE" == "dsm-reverse-proxy" ]]; then
        cat <<EOF

===============================================================================
OBSIDIAN STACK INSTALLATION REPORT
===============================================================================

Installation status
  Backend installation: SUCCESS
  CouchDB readiness:     VALIDATED with administrator authentication
  LiveSync database:     VALIDATED with the generated user
  MCP HTTP endpoint:     REACHABLE
  DSM HTTPS proxy:       REQUIRES CONFIGURATION

Stack
  Synology user:         ${DSM_USER}
  Stack ID:              ${STACK_ID}
  DNS service ID:        ${SERVICE_ID}
  Vault name:            ${VAULT_NAME}
  Configuration:         ${BASE_DIR}
  User connection file:  ${USER_CONNECTION_FILE}

Internal services
  CouchDB target:        http://127.0.0.1:${COUCHDB_PORT}
  MCP target:            http://127.0.0.1:${MCP_PORT}/mcp
  Network exposure:      NAS loopback only

Public HTTPS services
  CouchDB hostname:      ${COUCHDB_HOSTNAME}
  CouchDB URL:           ${COUCHDB_PUBLIC_URL}
  MCP hostname:          ${MCP_HOSTNAME}
  MCP URL:               ${MCP_PUBLIC_URL}/mcp

LiveSync credentials
  Username:              ${LIVESYNC_USER}
  Password:              ${report_livesync_password}
  Database:              ${COUCHDB_DATABASE}
  E2EE passphrase:       ${report_passphrase}
  Obfuscate properties:  ${COUCHDB_OBFUSCATE_PROPERTIES}

MCP credentials
  Authentication token:  ${report_mcp_token}
  Vault name:             ${VAULT_NAME}

Required DSM steps
  1. Open Control Panel > Login Portal > Advanced > Reverse Proxy.
  2. Create the CouchDB rule:
       Name:                 Obsidian ${DSM_USER} Sync
       Source protocol:      HTTPS
       Source hostname:      ${COUCHDB_HOSTNAME}
       Source port:          443
       Destination protocol: HTTP
       Destination hostname: 127.0.0.1
       Destination port:     ${COUCHDB_PORT}
  3. Create the MCP rule:
       Name:                 Obsidian ${DSM_USER} MCP
       Source protocol:      HTTPS
       Source hostname:      ${MCP_HOSTNAME}
       Source port:          443
       Destination protocol: HTTP
       Destination hostname: 127.0.0.1
       Destination port:     ${MCP_PORT}
       Proxy read timeout:   600 seconds or longer
  4. Open Control Panel > Security > Certificate > Settings.
  5. Assign a trusted certificate covering both service hostnames. A wildcard
     certificate for *.${OBSIDIAN_DOMAIN} can cover all user stacks.
  6. Confirm the NAS firewall allows HTTPS port 443 from the intended LAN or
     VPN networks. Do not expose the internal CouchDB or MCP ports.

Obsidian Self-hosted LiveSync settings
  Remote type:           CouchDB
  Server URI:            ${COUCHDB_PUBLIC_URL}
  Username:              ${LIVESYNC_USER}
  Password:              ${report_livesync_password}
  Database:              ${COUCHDB_DATABASE}
  End-to-end encryption: Enabled
  Passphrase:            ${report_passphrase}
  Obfuscate properties:  Enabled

MCP client settings
  Endpoint:              ${MCP_PUBLIC_URL}/mcp
  Authorization token:   ${report_mcp_token}
  Vault:                 ${VAULT_NAME}

Final validation
  1. From a client, confirm ${COUCHDB_HOSTNAME} and ${MCP_HOSTNAME} resolve to
     ${NAS_IP}.
  2. Open ${COUCHDB_PUBLIC_URL}/_up. An unauthenticated 401 response confirms
     DNS, TLS and proxy routing; an authenticated request must return HTTP 200.
  3. Use "Test Database Connection" in Self-hosted LiveSync.
  4. Initialize an MCP session through ${MCP_PUBLIC_URL}/mcp using the token.
  5. Create a test note, confirm synchronization, then read it through MCP.

SECURITY NOTICE
  This report contains passwords, an encryption passphrase and an MCP token.
  The same values are stored in ${USER_CONNECTION_FILE} with user-only access.
===============================================================================
EOF
    else
        cat <<EOF

===============================================================================
OBSIDIAN STACK INSTALLATION REPORT - DIRECT HTTP TEST MODE
===============================================================================

Installation status:     SUCCESS
Synology/Linux user:     ${DSM_USER}
Vault name:              ${VAULT_NAME}
Configuration:           ${BASE_DIR}
User connection file:    ${USER_CONNECTION_FILE}

LiveSync
  Server URI:            ${COUCHDB_PUBLIC_URL}
  Username:              ${LIVESYNC_USER}
  Password:              ${report_livesync_password}
  Database:              ${COUCHDB_DATABASE}
  E2EE passphrase:       ${report_passphrase}
  Obfuscate properties:  ${COUCHDB_OBFUSCATE_PROPERTIES}

MCP
  Endpoint:              ${MCP_PUBLIC_URL}/mcp
  Authentication token: ${report_mcp_token}
  Vault:                 ${VAULT_NAME}

This mode exposes unencrypted HTTP endpoints and is intended only for isolated
testing. Use dsm-reverse-proxy mode for a DSM installation.
===============================================================================
EOF
    fi
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
                warn "Container status at failure:"
                "${COMPOSE[@]}" ps >&2 || true
                warn "CouchDB runtime state:"
                docker inspect --format '{{json .State}}' \
                    "obsidian-couchdb-${STACK_ID}" >&2 || true
                warn "CouchDB image user:"
                docker image inspect --format '{{json .Config.User}}' \
                    "$COUCHDB_IMAGE" >&2 || true
                warn "Generated directory ownership:"
                ls -ldn "$BASE_DIR" "$BASE_DIR/config" \
                    "$BASE_DIR/config/livesync.ini" \
                    "$BASE_DIR/couchdb-data" >&2 || true
                warn "Recent container logs:"
                "${COMPOSE[@]}" logs --no-color --tail 100 >&2 || true
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
    validate_runtime_config

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
    configure_deployment

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

    chown root:root "$BASE_DIR" "$BASE_DIR/config" "$BASE_DIR/mcp-data"
    chown "$COUCHDB_UID:$COUCHDB_GID" "$BASE_DIR/couchdb-data"
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

    "${COMPOSE[@]}" ps
    print_installation_report
}

main "$@"
