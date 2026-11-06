# NAS Drive Health — macOS desktop widget for TrueNAS

[![Build](https://github.com/Aivun/NASDriveHealth/actions/workflows/build.yml/badge.svg)](https://github.com/Aivun/NASDriveHealth/actions/workflows/build.yml)

A native WidgetKit widget (small / medium / large) plus a tiny menu bar app that shows the
health of every drive in your TrueNAS box — HDDs, SATA SSDs and NVMe alike. A second widget,
**NAS Virtual Machines**, lists your TrueNAS VMs with **Start**, **Stop** and **Settings** buttons.

Per drive it shows: status dot, device name, HDD/SSD/NVMe badge, model & size (large widget),
temperature, and ZFS read/write/checksum error counts. A drive turns **orange/red** when:

| Signal | Source (TrueNAS API) | Warning | Critical |
|---|---|---|---|
| ZFS member state | `pool.query`, `boot.get_state` | DEGRADED / OFFLINE | FAULTED / UNAVAIL / REMOVED |
| ZFS error counters | same | any read/write/checksum error | – |
| Temperature | `disk.temperatures` | ≥ warn threshold | ≥ crit threshold |
| TrueNAS Drive Health alerts (SMART failures, pending sectors, NVMe critical warnings, over-temp…) | `alert.list` | WARNING | ERROR / CRITICAL |

Pool-level problems (e.g. a pool DEGRADED because a disk vanished entirely) are shown too.

> **Why alerts instead of raw SMART attributes?** Since TrueNAS 25.10 the SMART UI/API was
> removed; the middleware now polls SMART itself ("Drive Health Management") and raises alerts.
> The widget surfaces exactly those alerts, matched to the drive by name/serial.

Requires **TrueNAS 25.04 or newer** (JSON-RPC over WebSocket — the old REST API is gone in 26.04)
and **macOS 14 Sonoma or newer**.

---

## 1. Create a read-only account on TrueNAS

Your existing SMB credentials can't use the API, so make a dedicated user that can only *read*:

1. **Credentials → Users → Add**
   - Username: `widget-monitor` (anything works), full name whatever you like
   - Set any long random password (you'll never use it)
   - Shell: `nologin`, **no** SMB access, no home directory needed
   - **TrueNAS Access** (sometimes labelled *Allow Access*): enable it and pick role **Readonly Admin**
2. Save, then create the key: **Credentials → Users → widget-monitor → API Keys → Add**
   (or top-right user menu → *My API Keys*, choosing `widget-monitor` as the user).
   Name it e.g. `mac-widget`, non-expiring or with an expiry you like.
3. **Copy the key now** — TrueNAS shows it only once.

Readonly Admin can call every `*.query` / read method and cannot change anything.

⚠️ Never use the key over plain `http://` — TrueNAS automatically **revokes** a user-linked key the
first time it's sent unencrypted. The app always uses `wss://` (HTTPS), so this only matters if
you test with curl.

## 2. Build the app

You need full Xcode 15+ (from the App Store, opened once) and an Apple ID added under
Xcode → Settings → Accounts — a free "Personal Team" is enough.

**One step:**

```bash
git clone https://github.com/<you>/NASDriveHealth.git
cd NASDriveHealth
bash build.sh
```

`build.sh` installs [XcodeGen](https://github.com/yonaskolb/XcodeGen) via Homebrew if needed,
finds your Team ID from your Apple Development certificate (or use `TEAM_ID=ABCDE12345 bash build.sh`),
generates the Xcode project, builds a Release app, copies it to `~/Applications` and launches it.
Re-run it after any code change.

**Manually**, if you prefer Xcode:

```bash
brew install xcodegen
# edit project.yml → DEVELOPMENT_TEAM: "ABCDE12345"   (your Team ID)
xcodegen generate
open NASDriveHealth.xcodeproj      # then Run the "NAS Drive Health" scheme
```

### Or download a release

Prebuilt apps are on the [Releases](https://github.com/Aivun/NASDriveHealth/releases) page. They are **not signed
or notarized by Apple**, so macOS asks for permission the first time (*System Settings → Privacy & Security →
Open Anyway*); the release notes walk you through it.

<details>
<summary>Making a release (maintainer)</summary>

Either push a tag — `git tag v1.2.0 && git push origin v1.2.0` — or go to **Actions → Release → Run workflow**
and enter the version. The workflow builds a universal, ad-hoc-signed app on GitHub's macOS runner and creates a
**draft** release with the zip, a SHA-256 checksum and the notes from `.github/release-notes.md`.
Check the draft, then press **Publish release** (for workflow runs this also creates the tag).
</details>

## 3. Configure

A drive icon appears in the menu bar. Click it → **Set up…**

- **Host**: `truenas.local`, `192.168.1.10`, or `192.168.1.10:8443` if you moved the web UI port
- **Username**: `widget-monitor`
- **API key**: the key from step 1
- Click **Save & Test Connection**. macOS will ask to allow **local network** access — allow it.

TrueNAS ships with a self-signed certificate, so the first test will show its **SHA-256
fingerprint**. Verify it before clicking *Trust this certificate*, e.g. from Terminal:

```bash
echo | openssl s_client -connect truenas.local:443 2>/dev/null | openssl x509 -noout -fingerprint -sha256
```

The app then pins exactly that certificate (if you regenerate the cert, click *Forget* and trust again).
Turn on **Launch at login** so the menu bar app keeps the widget fresh.

The API key is stored in the Keychain (shared with the widget via the App Group); if your signing
setup doesn't allow keychain sharing it falls back to a `0600` file inside the sandboxed App Group
container.

## 4. Add the widget

Right-click the desktop → **Edit Widgets…** → search **NAS Drive Health** → drag the small,
medium or large size onto the desktop (or into Notification Center). Add **NAS Virtual Machines**
the same way if you want the VM buttons. The ↻ button in the corner
refreshes on demand.

## VM controls (optional)

The **NAS Virtual Machines** widget (medium / large) and the menu bar app discover every VM from
`vm.query` and show three buttons per VM:

| Button | What it does |
|---|---|
| ▶ Start | `vm.start` — enabled when the VM is stopped |
| ■ Stop | graceful ACPI shutdown (`vm.stop`, not forced). **Click twice** — the first click turns it into *Stop?* for 10 s |
| ⚙ Settings | opens the Virtual Machines page of the TrueNAS web UI in your browser (path configurable in Settings, default `/ui/vm`) |

Listing VMs works with the read-only account. **Starting and stopping needs the `VM_WRITE` role**,
which *Readonly Admin* doesn't include. Give the widget account just that one extra role:

1. **Credentials → Groups → Add**: create a group, e.g. `nas-widget-vm`.
2. **Credentials → Groups → Privileges → Add**: name it e.g. `Widget VM control`, choose the local group
   `nas-widget-vm`, and under **Roles** pick only `VM_WRITE`. Save.
3. **Credentials → Users → widget-monitor → Edit**: add `nas-widget-vm` to **Auxiliary Groups**. Save.

The existing API key picks up the new role on its next call; no new key is needed. *Save & Test Connection*
in the app reports whether start/stop is allowed.

Errors (e.g. a VM that failed to start) appear under the VM list; click ✕ to dismiss them.

Note that `VM_WRITE` also allows editing or deleting VMs through the API. The app never does that, but treat
the key accordingly.

## Behaviour & tuning

- Default refresh: every 10 min (5–120 in Settings). Temperatures come from TrueNAS's cache, so
  polling **doesn't spin up sleeping disks**.
- Default thresholds: HDD 50 °C warn / 58 °C crit, SSD/NVMe 65 / 75 °C — adjustable in Settings.
- If the NAS is unreachable the widget keeps showing the last data with an *Offline* marker and
  goes grey after 3 missed refreshes.

## Files

```
build.sh                    One-step build & install
.github/workflows/          build check on every push; release builds (tag or manual run)
project.yml                 XcodeGen spec (app + widget extension, sandbox, app group)
Shared/TrueNASClient.swift  JSON-RPC 2.0 WebSocket client, API-key login, certificate pinning
Shared/HealthService.swift  Queries + health evaluation → HealthSnapshot
Shared/Storage.swift        Settings, API key, cached snapshot (App Group)
Shared/Models.swift, Style.swift
App/                        Menu bar app + settings window
Widget/DriveHealthWidget.swift  Drive health widget (3 sizes, refresh button)
Widget/VMWidget.swift       VM widget + start/stop intents
Shared/VMControl.swift      vm.start / vm.stop
```

## Troubleshooting

- **"rejected the API key (AUTH_ERR)"** — username must be the user the key belongs to; the key may
  have been revoked (e.g. after an http:// request) — create a new one.
- **Widget says "Not set up yet"** — the app and widget aren't sharing the App Group; make sure both
  targets are signed with the same team (`DEVELOPMENT_TEAM` in project.yml), regenerate, rebuild.
- **No temperatures** — some USB bridges / virtualised disks don't report them; health still works.
- Want per-attribute SMART history (reallocated sectors, SSD wear %)? Install the **Scrutiny** app on
  TrueNAS; its API could be added as an extra data source.

## License

Copyright (C) 2026 Ivan Dimov.

This program is free software: you can redistribute it and/or modify it under the terms of the
GNU General Public License as published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version. It is distributed WITHOUT ANY WARRANTY; see
[LICENSE](LICENSE) for details.

TrueNAS is a trademark of iXsystems, Inc.; this project is not affiliated with or endorsed by iXsystems.
