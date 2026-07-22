# Clone Studio

Move everything to your new Linux computer — safely, step by step.

Clone Studio is a beginner-proof migration assistant for Linux laptops and
desktops. Run it on both computers, pick which one is old and which one is
new, and it moves your files, apps, settings, SSH keys and Wi-Fi networks
across — over Wi-Fi, a direct network cable, or a USB drive. Nothing ever
touches the internet.

## Features

- **Three transports** — same-network Wi-Fi (automatic discovery), direct
  ethernet cable (link-local, fastest), or a USB drive / external disk
  (no network needed; works even when the computers never meet).
- **Four modes** — Safe Transfer (apps + personal folders only),
  Recommended (adds settings, browser profiles, SSH keys), Custom
  (per-category checkboxes), and Whole Disk Clone (preview in this release).
- **Secure by design** — TLS-encrypted transfers; the 6-digit pairing code
  is cryptographically bound to the connection so a man-in-the-middle is
  rejected, not just inconvenienced.
- **Fail-safe by design** — every completed file is journaled; atomic
  `.partial` writes mean no half-files; a dropped connection, closed lid or
  reboot resumes from where it left off. Files already on the new computer
  are never overwritten — both copies are kept.
- **Honest receipts** — end-of-transfer verification pass plus a
  plain-English summary of what moved.
- **App migration** — your manually installed apt packages, flatpaks and
  snaps come over as a list with a one-command reinstall script.

## Install

```bash
sudo apt install ./clone-studio_1.0.0_amd64.deb
```

Or run from source: `flutter run -d linux` (Flutter 3.44+).

## Development

```bash
flutter test        # protocol, transfer-engine, resume and bundle tests
flutter analyze
flutter build linux --release
```

Useful test overrides (never needed in normal use):

- `CLONE_STUDIO_SOURCE_ROOT` — scan/send this directory instead of $HOME
- `CLONE_STUDIO_TARGET_ROOT` — restore into this directory instead of $HOME
- `CLONE_STUDIO_DRIVE_DIR` — treat this directory as a plugged-in drive

## Roadmap

- Whole Disk Clone (full system copy via bootable USB helper)
- Multi-trip USB transfers for drives smaller than the selection
- Optional bundle encryption
- Wi-Fi password migration (NetworkManager, needs polkit helper)
