# Security

Do not publish generated `.env` files, CouchDB credentials, LiveSync encryption passphrases, MCP tokens, connection files or vault data.

Deploy CouchDB and MCP only on a trusted LAN or through a VPN. Do not expose their ports directly to the Internet.

The MCP service has read/write access to the vault. Keep reliable backups and review destructive tool actions.

A Synology administrator with root access can read service secrets and can technically decrypt the vault.

Report security issues privately to the repository owner instead of opening a public issue containing credentials or exploit details.
