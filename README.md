# Home Assistant Add-on: Config Sync (GitOps)

GitOps for Home Assistant — sync your configuration from a GitHub repo
with automatic validation and rollback.

## Installation

1. In Home Assistant, go to **Settings > Add-ons > Add-on Store**.
2. Click the three-dot menu (top right) and select **Repositories**.
3. Paste this URL and click **Add**:

   ```
   https://github.com/JLay2026/ha-addon-config-sync
   ```

4. Find **Config Sync (GitOps)** in the add-on list and click **Install**.
5. Go to the **Configuration** tab and set your `github_repo` URL.
6. Click **Start**.

## What it does

Every few minutes the add-on checks your GitHub repo for new commits.
When it finds changes, it copies the updated config files into HA's
`/config` directory, runs HA's built-in config validator, and reloads
if everything checks out. If validation fails, the files are automatically
rolled back to the previous version.

No SSH. No Samba. No manual tokens. Fully managed through the HA UI.

## Documentation

See [config-sync/DOCS.md](config-sync/DOCS.md) for full configuration
options, security details, and agent integration.

## License

MIT
