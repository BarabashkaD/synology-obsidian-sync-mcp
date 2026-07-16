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
- `ghcr.io/es617/obsidian-sync-mcp:latest`;
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
- an existing `/var/services/homes/<username>` directory.

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
