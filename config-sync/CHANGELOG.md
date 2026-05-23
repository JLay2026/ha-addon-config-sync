# Changelog

## 1.0.0

- Initial release
- GitOps sync from GitHub to HA `/config`
- Supervisor API validation (check-config) before reload
- Automatic rollback on invalid config
- Configurable `sync_paths` allowlist
- Private repo support via GitHub PAT
- Multi-arch: amd64, aarch64, armv7, i386
