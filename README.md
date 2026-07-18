# Synology Obsidian Sync MCP

Automated deployment of fully isolated Obsidian Self-hosted LiveSync + MCP stacks on Synology DSM.

Each Synology user receives a separate:

- CouchDB container and database;
- Obsidian Sync MCP container;
- Docker network;
- persistent data directories;
- CouchDB credentials;
- LiveSync E2EE passphrase;
- MCP authentication token;
- pair of TCP ports.

## Architecture

```text
Synology NAS
├── User A
│   ├── obsidian-couchdb-user-a
│   ├── obsidian-mcp-user-a
│   └── /volume1/docker/obsidian-users/user-a
│
└── User B
    ├── obsidian-couchdb-user-b
    ├── obsidian-mcp-user-b
    └── /volume1/docker/obsidian-users/user-b
```

The project is standalone. It is not a fork and does not use Git submodules.

Runtime dependencies are pulled as Docker images:

- `couchdb:3`;
- `ghcr.io/es617/obsidian-sync-mcp@sha256:59ab4dbe7af00417331c37c1c260df320d3bbd1bb7c6a3386a5d4c1c0ece5850`
  (upstream package version `0.5.2`);
- `curlimages/curl:8.10.1` only when Synology does not provide host `curl`.

Obsidian clients use the Self-hosted LiveSync community plugin to synchronize with the per-user CouchDB instance.

## Requirements

- Synology DSM 7.x;
- Container Manager or Docker package;
- Docker Compose v2 or legacy `docker-compose`;
- Bash and OpenSSL;
- root access for installation;
- an existing local Synology user;
- enabled Synology User Home service;
- an existing `/var/services/homes/<username>` directory;
- a fully qualified NAS hostname resolvable by the local DNS server;
- wildcard or explicit local DNS records for each user's `-sync` and `-mcp`
  service names;
- a TLS certificate covering the service names and DSM reverse proxy access.

## DSM reverse proxy deployment

The default deployment mode keeps CouchDB and MCP on NAS loopback ports and
publishes a separate HTTPS hostname for each service. For a NAS whose detected
name is `nas.home.example.com`, user `alice` receives:

```text
https://alice-sync.nas.home.example.com -> CouchDB
https://alice-mcp.nas.home.example.com  -> MCP
```

Before running the installer, configure the local DNS server so the NAS name
and both service names resolve to the NAS LAN address. A wildcard record such
as `*.nas.home.example.com` is the simplest option for multiple users. The
installer treats DNS resolution as a prerequisite and stops before creating a
stack if any required name resolves incorrectly.

Run the installer normally to detect the NAS address and fully qualified name:

```bash
sudo ./create-obsidian-user-stack.sh alice "Alice Vault"
```

Override detection when the DNS service domain differs from the NAS hostname:

```bash
sudo NAS_HOSTNAME=nas.home.example.com \
  OBSIDIAN_DOMAIN=obsidian.home.example.com \
  ./create-obsidian-user-stack.sh alice "Alice Vault"
```

After validating and starting the backends, the installer prints two rules to
create in **Control Panel > Login Portal > Advanced > Reverse Proxy**. Assign a
certificate covering the service names, such as
`*.obsidian.home.example.com`, to those HTTPS hostnames. CouchDB and MCP remain
bound to `127.0.0.1`, preventing direct HTTP access from the LAN.

At completion, the installer prints a human-readable report containing the
generated endpoints, credentials, proxy rules, Obsidian settings and required
validation steps. Because the report contains secrets, use
`SHOW_SECRETS_IN_REPORT=false` when output is captured by automation; the
secrets remain available in the protected user connection file.

`DEPLOYMENT_MODE=direct-http` is intended for isolated testing only. It exposes
the selected ports directly and does not require proxy DNS names.

## Linux integration test

GitHub Actions runs syntax checks, ShellCheck and a real container installation on
every pushed commit and pull request. The integration test creates a disposable
Linux user and isolated directories below `/tmp`, installs the stack, verifies
CouchDB access and persistence, tests MCP authentication and note operations,
exercises status and duplicate protection, and then removes its containers, user
and files.

Run the same test on a general Linux host with Docker, Compose, curl, OpenSSL and
the standard `useradd`/`userdel` account tools:

```bash
sudo tests/run-linux-integration.sh
```

The installer accepts `BASE_ROOT`, `USER_HOME_ROOT`, `NAS_IP`, `NAS_HOSTNAME`,
`OBSIDIAN_DOMAIN`, `DEPLOYMENT_MODE`,
`COUCHDB_PORT_BASE`, `MCP_PORT_BASE`, `MCP_IMAGE`, `COUCHDB_IMAGE` and
`CURL_IMAGE` environment overrides for isolated testing. `COUCHDB_UID` and
`COUCHDB_GID` can override the official CouchDB image's default `5984:5984`
data ownership. All defaults remain the Synology production values. Linux
integration does not replace final DSM
validation of `synouser`, User Home, volume permissions, networking or Container
Manager behavior.

## Local HTTPS reverse proxy

For an Ubuntu host serving a Windows Obsidian client, the local Reproxy helper
adds trusted HTTPS in front of an already-running CouchDB and MCP stack:

```bash
tests/setup-local-reproxy.sh 172.18.4.117
```

It runs a pinned [`umputun/reproxy`](https://github.com/umputun/reproxy)
container on port `8443`, attaches it to the existing user's stack network,
generates a private test CA, and prints the Windows hosts-file and
certificate-import instructions. It binds on all Ubuntu interfaces so WSL can
forward the port to Windows `localhost`; the printed Windows hosts entry maps
both service names to `127.0.0.1`. The default names follow the DSM convention:

```text
<current-user>-sync.obsidian.test
<current-user>-mcp.obsidian.test
```

By default it discovers containers ending in the current username. Override
the stack or local DNS suffix for another test configuration:

```bash
STACK_USER=another-user LOCAL_DOMAIN=lab.example.test HTTPS_PORT=9443 \
  tests/setup-local-reproxy.sh 192.168.1.20
```

The helper prints the exact Windows `hosts` entry required for the two names.
`COUCHDB_HOST` and `MCP_HOST` can override either generated hostname.

The generated CA private key is stored under
`~/.local/share/obsidian-sync-mcp-reproxy` and is for local testing only. Do not
copy it to client devices or use it for a public deployment. On DSM, use its
built-in reverse proxy with a publicly trusted certificate instead.

## Security model

- Each user's CouchDB, MCP process, credentials, encryption passphrase, token, volumes and network are isolated.
- Generated `.env` and connection files are never committed.
- Services are intended for LAN or VPN access, not direct Internet exposure.
- MCP has read/write access to notes; backups and deliberate tool approval are required.
- A NAS administrator can read service secrets and therefore can technically decrypt a vault.

## Repository workflow

Direct updates to `main` are blocked by a GitHub ruleset. Changes must be proposed through pull requests.

The initial installer is introduced separately through the repository's first pull request.

## Upstream projects

- Obsidian Sync MCP: https://github.com/es617/obsidian-sync-mcp
- Self-hosted LiveSync: https://github.com/vrtmrz/obsidian-livesync
- Apache CouchDB: https://couchdb.apache.org/

This repository contains Synology-oriented deployment automation and documentation only. It does not vendor upstream source code.
