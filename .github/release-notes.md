> [!WARNING]
> **This build is not signed or notarized by Apple.** macOS will refuse to open it at first and needs your explicit permission. Only download it from this page, and check the SHA-256 checksum at the bottom if you want to be sure the file wasn't altered. If you'd rather not, build it yourself from source — see the [README](https://github.com/Aivun/NASDriveHealth#2-build-the-app).

### Installing

1. Download the `.zip` below and double-click it to unzip.
2. Move **NAS Drive Health.app** to your **Applications** folder.
3. Open it. macOS will say it *can't be opened* / *Apple could not verify it is free of malware*. Click **Done** (not *Move to Bin*).
4. Open **System Settings → Privacy & Security**, scroll down to the message about *NAS Drive Health* and click **Open Anyway**, then confirm with your password or Touch ID.
5. Open the app again. A drive icon appears in the menu bar → **Set up…**

You only need to do this once per version.

<details>
<summary>Terminal alternative</summary>

```bash
xattr -dr com.apple.quarantine "/Applications/NAS Drive Health.app"
open "/Applications/NAS Drive Health.app"
```
</details>

If macOS asks whether *NAS Drive Health* may **access data from other apps**, click **Allow** — that's how the widget reads the settings you enter in the app.

### Setup

You need a TrueNAS 25.04+ account with an API key — see the [README](https://github.com/Aivun/NASDriveHealth#1-create-a-read-only-account-on-truenas). VM start/stop/restart additionally needs the `VM_WRITE` role.

Requires macOS 14 Sonoma or newer (Apple Silicon or Intel).
