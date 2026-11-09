# Clone Studio

[![ARM64 builds](https://github.com/Dhiva-Labs/CloneStudio/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Dhiva-Labs/CloneStudio/actions/workflows/ci.yml)
![Linux x64 | arm64](https://img.shields.io/badge/Linux-x64%20%7C%20arm64-informational?logo=linux&logoColor=white)
![Linux: deb | rpm | Arch | AppImage | Flatpak](https://img.shields.io/badge/Linux-deb%20%7C%20rpm%20%7C%20Arch%20%7C%20AppImage%20%7C%20Flatpak-informational?logo=linux&logoColor=white)

Move everything to your new Linux computer — safely, step by step.

**Documentation:** step-by-step guides at [learn.dhivalabs.com](https://learn.dhivalabs.com/apps/clonestudio/): [install](https://learn.dhivalabs.com/apps/clonestudio/install) · [beginner guide](https://learn.dhivalabs.com/apps/clonestudio/getting-started) · [troubleshooting](https://learn.dhivalabs.com/apps/clonestudio/faq). New to the topic? Try the [Files, backups and recovery](https://learn.dhivalabs.com/tracks/files/) learning track.

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

Download the `.deb` for your computer from the
[releases page](https://github.com/Dhiva-Labs/CloneStudio/releases):
`clone-studio_<version>_amd64.deb` for Intel / AMD, or
`clone-studio_<version>_arm64.deb` for ARM. Then:

```bash
sudo apt install ./clone-studio_*_$(dpkg --print-architecture).deb
```

Or run from source: `flutter run -d linux` (Flutter 3.44+).

To build the package yourself:

```bash
flutter build linux --release
packaging/build_deb.sh          # writes dist/clone-studio_<version>_<arch>.deb
```

The package is built for the architecture of the machine it runs on: `amd64`
on an x64 machine and `arm64` on an arm64 one.

### Other distributions

CI builds these from the same release build as the `.deb`, for x64
(`x86_64`) and arm64 (`aarch64`), and attaches them to releases from the next
release on. They are built on Ubuntu 24.04, so they need a distribution at
least that new (glibc 2.39): Fedora 40 or later, RHEL/Rocky/Alma 10, openSUSE
Tumbleweed, current Arch Linux. openSUSE Leap 15 and RHEL 9 are too old. The
`.rpm` declares the glibc version it needs, so dnf and zypper refuse a system
that is too old instead of installing an app that cannot start.

On these distributions the "Applications" category lists Flatpak and snap
apps; the list of manually installed packages comes from `apt-mark`, which
only Debian and Ubuntu have.

**Fedora, RHEL, Rocky, Alma** (`.rpm`; dnf installs openssl and GTK 3 with
it):

```bash
sudo dnf install ./clone-studio-<version>-1.x86_64.rpm     # or .aarch64.rpm
```

**openSUSE Tumbleweed** (the same `.rpm`; it is not signed):

```bash
sudo zypper install --allow-unsigned-rpm ./clone-studio-<version>-1.x86_64.rpm
```

**Arch Linux, Manjaro, EndeavourOS** (`.pkg.tar.zst`; depends on `gtk3` and
`openssl`):

```bash
sudo pacman -U ./clone-studio-<version>-1-x86_64.pkg.tar.zst  # or -aarch64
```

Each release also carries `clone-studio-bin-<version>-aur.tar.gz`, the
PKGBUILD and `.SRCINFO` of an AUR `clone-studio-bin` package that repackages
the release `.deb`. It is not on the AUR yet.

**AppImage** (any glibc distribution with GTK 3 and the `openssl` command):

```bash
chmod +x CloneStudio-<version>-x86_64.AppImage                # or -aarch64
./CloneStudio-<version>-x86_64.AppImage
```

**Flatpak** (the GNOME 51 runtime comes from Flathub):

```bash
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user ./clone-studio-<version>-x86_64.flatpak # or -aarch64
flatpak run com.dhivalabs.clone_studio
```

The Flatpak has the access a migration needs: your whole home directory
(dotfiles, `~/.config` and `~/.ssh` included), mounted media for the USB
transport, the network, and permission to run commands on the host, which
it uses to ask the host's `apt-mark`, `flatpak`, `snap` and `dconf` what is
installed and to run the reinstall script with `pkexec`. See
[packaging/flatpak/README.md](packaging/flatpak/README.md).

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

## Sponsors

Dhiva Labs is an independent, self-funded lab. [Sponsorships](https://github.com/sponsors/Dhiva-Labs) help bring this project and the rest of Dhiva Labs to every platform, iPhone and Mac included.

[![Sponsor Dhiva Labs](https://img.shields.io/badge/Sponsor-Dhiva%20Labs-ea4aaa?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/Dhiva-Labs)

Monthly sponsors at $10 and up are listed here:

<!-- sponsors -->
*Be the first: [sponsor Dhiva Labs](https://github.com/sponsors/Dhiva-Labs).*
<!-- sponsors -->
