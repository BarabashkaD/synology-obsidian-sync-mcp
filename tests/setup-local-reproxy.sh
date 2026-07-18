#!/bin/bash
set -Eeuo pipefail

REPROXY_DIR="${REPROXY_DIR:-${HOME}/.local/share/obsidian-sync-mcp-reproxy}"
REPROXY_IMAGE="${REPROXY_IMAGE:-ghcr.io/umputun/reproxy:v1.6.0}"
SERVICE_IP="${SERVICE_IP:-}"
HTTPS_PORT="${HTTPS_PORT:-8443}"
PROXY_BIND_IP="${PROXY_BIND_IP:-0.0.0.0}"
STACK_USER="${STACK_USER:-${USER}}"
STACK_ID="${STACK_ID:-$(printf '%s' "$STACK_USER" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/^-*//; s/-*$//')}"
LOCAL_DOMAIN="${LOCAL_DOMAIN:-obsidian.test}"
COUCHDB_CONTAINER="${COUCHDB_CONTAINER:-obsidian-couchdb-${STACK_USER}}"
MCP_CONTAINER="${MCP_CONTAINER:-obsidian-mcp-${STACK_USER}}"
STACK_NETWORK="${STACK_NETWORK:-}"
COUCHDB_PORT="${COUCHDB_PORT:-5984}"
MCP_PORT="${MCP_PORT:-8787}"
COUCHDB_HOST="${COUCHDB_HOST:-${STACK_ID}-sync.${LOCAL_DOMAIN}}"
MCP_HOST="${MCP_HOST:-${STACK_ID}-mcp.${LOCAL_DOMAIN}}"
COMPOSE=()

log() { printf '[INFO] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $0 [SERVICE_IP]

Creates a local HTTPS reverse proxy for the existing CouchDB and MCP stack.

Environment overrides:
  SERVICE_IP       Ubuntu address reachable from Windows (auto-detected if omitted)
  HTTPS_PORT       Reproxy HTTPS port (default: 8443)
  PROXY_BIND_IP    Ubuntu bind address (default: 0.0.0.0 for WSL localhost forwarding)
  STACK_USER       User suffix of the existing containers (default: current user)
  STACK_ID         DNS-safe user identifier (derived from STACK_USER)
  LOCAL_DOMAIN     Local service suffix (default: obsidian.test)
  STACK_NETWORK    Existing stack network (auto-detected if omitted)
  COUCHDB_CONTAINER Existing CouchDB container name
  MCP_CONTAINER    Existing MCP container name
  COUCHDB_PORT     CouchDB container port (default: 5984)
  MCP_PORT         MCP container port (default: 8787)
  COUCHDB_HOST     CouchDB hostname (default: <stack-id>-sync.<local-domain>)
  MCP_HOST         MCP hostname (default: <stack-id>-mcp.<local-domain>)
  REPROXY_DIR      Generated configuration directory
  REPROXY_IMAGE    Reproxy container image
EOF
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

detect_service_ip() {
    SERVICE_IP="$(ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')"
    [[ -n "$SERVICE_IP" ]] || SERVICE_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [[ -n "$SERVICE_IP" ]] || die "Could not detect SERVICE_IP; pass it as the first argument"
}

validate_settings() {
    [[ "$SERVICE_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
        || die "SERVICE_IP must be an IPv4 address: $SERVICE_IP"
    [[ "$PROXY_BIND_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
        || die "PROXY_BIND_IP must be an IPv4 address: $PROXY_BIND_IP"

    local port
    for port in "$HTTPS_PORT" "$COUCHDB_PORT" "$MCP_PORT"; do
        [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) \
            || die "Invalid port: $port"
    done

    [[ "$COUCHDB_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || die "Invalid COUCHDB_HOST"
    [[ "$MCP_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || die "Invalid MCP_HOST"
    [[ "$STACK_ID" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "Invalid STACK_ID"
    [[ "$LOCAL_DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
        || die "Invalid LOCAL_DOMAIN"
    [[ "$COUCHDB_HOST" != "$MCP_HOST" ]] || die "Test hostnames must be different"
}

detect_stack_network() {
    local couchdb_network=""
    local mcp_networks=""

    docker inspect "$COUCHDB_CONTAINER" >/dev/null 2>&1 \
        || die "CouchDB container is not available: $COUCHDB_CONTAINER"
    docker inspect "$MCP_CONTAINER" >/dev/null 2>&1 \
        || die "MCP container is not available: $MCP_CONTAINER"

    if [[ -z "$STACK_NETWORK" ]]; then
        couchdb_network="$(docker inspect "$COUCHDB_CONTAINER" \
            --format '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{"\n"}}{{end}}' \
            | head -n1)"
        [[ -n "$couchdb_network" ]] \
            || die "Could not detect a Docker network for $COUCHDB_CONTAINER"
        STACK_NETWORK="$couchdb_network"
    fi

    mcp_networks="$(docker inspect "$MCP_CONTAINER" \
        --format '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{"\n"}}{{end}}')"
    grep -Fxq "$STACK_NETWORK" <<<"$mcp_networks" \
        || die "$MCP_CONTAINER is not attached to Docker network $STACK_NETWORK"
}

generate_certificates() {
    local cert_dir="$REPROXY_DIR/certs"
    local ca_key="$cert_dir/local-test-ca.key"
    local ca_cert="$cert_dir/local-test-ca.crt"
    local server_key="$cert_dir/reproxy.key"
    local server_cert="$cert_dir/reproxy.crt"
    local server_csr="$cert_dir/reproxy.csr"
    local extensions="$cert_dir/reproxy.ext"

    mkdir -p "$cert_dir"
    if [[ ! -f "$ca_key" || ! -f "$ca_cert" ]]; then
        log "Generating local test certificate authority"
        openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 \
            -subj "/CN=Obsidian Sync MCP Local Test CA" \
            -keyout "$ca_key" -out "$ca_cert" >/dev/null 2>&1
    fi

    cat > "$extensions" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:${COUCHDB_HOST},DNS:${MCP_HOST},IP:${SERVICE_IP}
EOF
    log "Generating server certificate for $COUCHDB_HOST, $MCP_HOST and $SERVICE_IP"
    openssl req -new -newkey rsa:2048 -sha256 -nodes \
        -subj "/CN=${COUCHDB_HOST}" -keyout "$server_key" -out "$server_csr" \
        >/dev/null 2>&1
    openssl x509 -req -sha256 -days 397 -in "$server_csr" \
        -CA "$ca_cert" -CAkey "$ca_key" -CAcreateserial \
        -extfile "$extensions" -out "$server_cert" >/dev/null 2>&1

    rm -f "$server_csr" "$extensions"
    chmod 600 "$ca_key" "$server_key"
    chmod 644 "$ca_cert" "$server_cert"
}

write_configuration() {
    cat > "$REPROXY_DIR/reproxy.yml" <<EOF
${COUCHDB_HOST}:
  - route: "^/(.*)"
    dest: "http://${COUCHDB_CONTAINER}:${COUCHDB_PORT}/\$1"
    timeout: 10m
${MCP_HOST}:
  - route: "^/(.*)"
    dest: "http://${MCP_CONTAINER}:${MCP_PORT}/\$1"
    timeout: 10m
EOF
    cat > "$REPROXY_DIR/.env" <<EOF
REPROXY_UID=$(id -u)
REPROXY_GID=$(id -g)
REPROXY_IMAGE=${REPROXY_IMAGE}
SERVICE_IP=${SERVICE_IP}
HTTPS_PORT=${HTTPS_PORT}
PROXY_BIND_IP=${PROXY_BIND_IP}
STACK_NETWORK=${STACK_NETWORK}
STACK_ID=${STACK_ID}
LOCAL_DOMAIN=${LOCAL_DOMAIN}
COUCHDB_HOST=${COUCHDB_HOST}
MCP_HOST=${MCP_HOST}
EOF
    cat > "$REPROXY_DIR/docker-compose.yml" <<'EOF'
services:
  reproxy:
    image: "${REPROXY_IMAGE}"
    container_name: obsidian-local-reproxy
    user: "${REPROXY_UID}:${REPROXY_GID}"
    restart: unless-stopped
    ports:
      - "${PROXY_BIND_IP}:${HTTPS_PORT}:8443"
    networks:
      - backend
    volumes:
      - ./reproxy.yml:/config/reproxy.yml:ro
      - ./certs/reproxy.crt:/certs/reproxy.crt:ro
      - ./certs/reproxy.key:/certs/reproxy.key:ro
    command:
      - --listen=0.0.0.0:8443
      - --file.enabled
      - --file.name=/config/reproxy.yml
      - --ssl.type=static
      - --ssl.cert=/certs/reproxy.crt
      - --ssl.key=/certs/reproxy.key
      - --timeout.write=10m
      - --timeout.idle=10m
      - --timeout.resp-header=10m
      - --max=100M
      - --keep-host
      - --logger.stdout
networks:
  backend:
    external: true
    name: "${STACK_NETWORK}"
EOF
    chmod 600 "$REPROXY_DIR/.env"
}

verify_proxy() {
    local host="$1"
    local path="$2"
    local status=""

    status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
        --connect-timeout 2 --max-time 5 \
        --cacert "$REPROXY_DIR/certs/local-test-ca.crt" \
        --resolve "${host}:${HTTPS_PORT}:${SERVICE_IP}" \
        "https://${host}:${HTTPS_PORT}${path}")" || return 1
    [[ "$status" != "000" && "$status" -lt 500 ]]
}

main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then usage; exit 0; fi
    [[ $# -le 1 ]] || die "Expected at most one SERVICE_IP argument"
    SERVICE_IP="${1:-$SERVICE_IP}"

    command -v openssl >/dev/null 2>&1 || die "openssl is required"
    command -v curl >/dev/null 2>&1 || die "curl is required"
    command -v docker >/dev/null 2>&1 || die "Docker is required"
    docker info >/dev/null 2>&1 || die "Docker is not running or is not accessible"
    get_compose_command
    [[ -n "$SERVICE_IP" ]] || detect_service_ip
    validate_settings
    detect_stack_network
    mkdir -p "$REPROXY_DIR"
    generate_certificates
    write_configuration

    log "Starting Reproxy from $REPROXY_DIR"
    (cd "$REPROXY_DIR" && "${COMPOSE[@]}" up -d --force-recreate)

    for _ in $(seq 1 20); do
        verify_proxy "$COUCHDB_HOST" "/_up" && verify_proxy "$MCP_HOST" "/mcp" && break
        sleep 1
    done
    verify_proxy "$COUCHDB_HOST" "/_up" \
        || die "CouchDB proxy route failed; inspect: docker logs obsidian-local-reproxy"
    verify_proxy "$MCP_HOST" "/mcp" \
        || die "MCP proxy route failed; inspect: docker logs obsidian-local-reproxy"

    cat <<EOF

[READY] Local HTTPS reverse proxy is running.

Windows hosts file (run editor as Administrator):
  127.0.0.1 ${COUCHDB_HOST} ${MCP_HOST}

Import this certificate into Windows "Trusted Root Certification Authorities":
  ${REPROXY_DIR}/certs/local-test-ca.crt

After importing it, restart Obsidian and use:
  CouchDB: https://${COUCHDB_HOST}:${HTTPS_PORT}
  MCP:     https://${MCP_HOST}:${HTTPS_PORT}/mcp

Stop the proxy:
  docker compose --project-directory ${REPROXY_DIR} down
EOF
}

main "$@"
