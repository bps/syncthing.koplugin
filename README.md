# syncthing.koplugin

A [KOReader](https://koreader.rocks/) plugin that runs [Syncthing](https://syncthing.net/) directly on your e-reader (Kindle or Kobo), letting you sync books and files over your local network without a computer.

## Features

- Start / stop Syncthing from the KOReader tools menu
- Auto-download — detects device architecture (ARM / ARM64) and fetches the correct binary from GitHub releases
- Connection info — shows the Web UI URL so you can configure sync from a browser on another device
- Sync status — quick view of folder sync progress
- Automatically enables Wi-Fi if needed
- Opens firewall on Kindle (`iptables`); no-op on Kobo where it isn't needed

## Setup

1. Copy the `syncthing.koplugin` directory into your KOReader `plugins/` folder:
   - **Kobo:** `/mnt/onboard/.adds/koreader/plugins/syncthing.koplugin/`
   - **Kindle:** `/mnt/us/koreader/plugins/syncthing.koplugin/`
2. Restart KOReader.
3. Open the menu: **☰ → Tools → Syncthing → Download binary**.
4. Once downloaded: **☰ → Tools → Syncthing → Start Syncthing**.
5. Open the Syncthing Web UI in a browser on another device (the URL is shown in *Connection info*).

### Manual binary install

If auto-download doesn't work (no `wget`/`curl` with HTTPS, rate-limited, etc.), download the binary yourself:

1. Go to [syncthing.net/downloads](https://syncthing.net/downloads/).
2. Download the **Linux ARM** (32-bit) or **Linux ARM64** build matching your device.
3. Extract and copy the `syncthing` binary to `syncthing.koplugin/bin/syncthing`.
4. Ensure it's executable (`chmod +x`).

## Directory layout

```
syncthing.koplugin/
├── main.lua          # plugin entry point
├── cacert.pem        # Mozilla CA bundle (for Kobo, which lacks a system CA store)
├── bin/
│   └── syncthing     # binary (auto-downloaded or user-provided, not checked in)
├── LICENSE
└── README.md
```

Syncthing's config, keys, and index database are stored under KOReader's settings directory (`settings/syncthing/`), not inside the plugin, so they survive plugin updates.

## Notes

- Syncthing's `--home` is set to `settings/syncthing/` under KOReader's data directory. It stores `config.xml`, TLS keys, and the index database. Back it up if you want to preserve your device ID and folder configs.
- The Web UI listens on `0.0.0.0:8384` (all interfaces). The first time you open it, Syncthing will prompt you to set a password. *Do that* — anyone on your network can reach the UI otherwise.
- Syncthing can use significant CPU and battery. Stop it when you're done syncing.

## License

This project is licensed under the [GNU Affero General Public License v3.0](LICENSE), the same license used by KOReader.
