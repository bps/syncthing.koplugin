# syncthing.koplugin

A [KOReader](https://koreader.rocks/) plugin that runs [Syncthing](https://syncthing.net/) directly on your e-reader (Kindle or Kobo), letting you sync books and files over your local network without a computer.

## Features

- Start / stop Syncthing from the KOReader tools menu
- Auto-download — detects device architecture (ARM / ARM64) and fetches the correct binary from GitHub releases
- Connection info — shows the Web UI URL so you can configure sync from a browser on another device
- Sync status — quick view of folder sync progress
- Automatically enables Wi-Fi if needed
- Opens firewall on Kindle (`iptables`); no-op on Kobo where it isn't needed

## Installation

### Via Updates Manager (recommended)

If you already have the [Updates Manager](https://github.com/advokatb/updatesmanager.koplugin) plugin installed, add this to your `KOReader/settings/updatesmanager_config.json`:

```json
{
  "plugins": [
    {
      "owner": "bps",
      "repo": "syncthing.koplugin",
      "description": "Syncthing plugin"
    }
  ]
}
```

Then check for updates in **☰ → Tools → Updates Manager → Plugins → Check for Updates**.

### Manual

1. Download the latest release ZIP from [Releases](https://github.com/bps/syncthing.koplugin/releases).
2. Extract the `syncthing.koplugin` folder into your KOReader `plugins/` directory:
   - **Kobo:** `/mnt/onboard/.adds/koreader/plugins/`
   - **Kindle:** `/mnt/us/koreader/plugins/`
3. Restart KOReader.
4. Open the menu: **☰ → Tools → Syncthing → Download binary**.
5. Once downloaded: **☰ → Tools → Syncthing → Start Syncthing**.
6. Open the Syncthing Web UI in a browser on another device (the URL is shown in *Connection info*).

## Directory layout

```
syncthing.koplugin/
├── main.lua          # plugin entry point
├── _meta.lua         # version metadata (used by Updates Manager)
├── cacert.pem        # Mozilla CA bundle (for Kobo, which lacks a system CA store)
├── bin/
│   └── syncthing     # binary (auto-downloaded or user-provided, not checked in)
├── LICENSE
└── README.md
```

Syncthing's config, keys, and index database are stored under KOReader's settings directory (`settings/syncthing/`), not inside the plugin, so they survive plugin updates.

## Notes

- The Syncthing binary is *not* included — the plugin downloads it on first use (**☰ → Tools → Syncthing → Download binary**). If auto-download fails (no HTTPS support, rate-limited, etc.), you can [install it manually](https://syncthing.net/downloads/): download the Linux ARM or ARM64 build, extract the `syncthing` binary to `syncthing.koplugin/bin/syncthing`, and `chmod +x` it.
- Syncthing's `--home` is set to `settings/syncthing/` under KOReader's data directory. It stores `config.xml`, TLS keys, and the index database. Back it up if you want to preserve your device ID and folder configs.
- The Web UI listens on `0.0.0.0:8384` (all interfaces). The first time you open it, Syncthing will prompt you to set a password. *Do that* — anyone on your network can reach the UI otherwise.
- Syncthing can use significant CPU and battery. Stop it when you're done syncing.

## License

This project is licensed under the [GNU Affero General Public License v3.0](LICENSE), the same license used by KOReader.
