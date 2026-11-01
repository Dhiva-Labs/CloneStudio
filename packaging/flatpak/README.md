# Flatpak

`com.dhivalabs.clone_studio.yml` builds the Clone Studio Flatpak bundle that
CI attaches to releases (`clone-studio-<version>-x86_64.flatpak` and
`-aarch64.flatpak`).

## How CI builds it

The `flatpak` job in `.github/workflows/ci.yml` unpacks the installed tree of
the `.deb` built earlier in the same run into `packaging/flatpak/tree/` and
runs flatpak-builder on the manifest in the
`ghcr.io/flathub-infra/flatpak-github-actions:gnome-51` image, natively on an
x64 and an arm64 runner. The bundle therefore ships the same Flutter build as
the `.deb`, `.rpm`, Arch package and AppImage.

The manifest has two modules:

- **host-commands**: `/app/bin/apt-mark`, `flatpak`, `snap`, `dconf` and
  `pkexec`, links to one script that runs the command of the same name on the
  host with `flatpak-spawn --host`. These are the commands whose answer is
  about the host, not the sandbox: which apps are installed, the desktop
  settings, and running the reinstall script as root.
- **clone-studio**: the installed tree, with the desktop file and icons
  renamed to the app ID, and the AppStream metadata.

`openssl` (the TLS identity), `df` and `chmod` come from the GNOME runtime
and run inside the sandbox.

CI then installs the bundle and checks, inside the sandbox, that every ELF
file under `/app` finds its libraries (`ldd-check.sh`), that `openssl`, `df`
and `chmod` work and the five host commands are the shims, and that
`flatpak list --app` run inside the sandbox is answered by the host (it must
list this app). Last, `packaging/linux-distros/smoke.sh` makes the app's TLS
identity with the sandbox's openssl and starts the app under Xvfb, waiting
for a painted Flutter UI.

To install the bundle (the GNOME 51 runtime comes from Flathub):

```sh
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user ./clone-studio-1.1.1-x86_64.flatpak
flatpak run com.dhivalabs.clone_studio
```

## Permissions

| Permission | Why |
|---|---|
| `--socket=wayland`, `--socket=fallback-x11`, `--share=ipc`, `--device=dri` | display and GPU for the Flutter UI |
| `--share=network` | discovery (UDP broadcast) and the TLS transfer, as client and server |
| `--filesystem=home` | everything it moves: personal folders, `~/.config`, `~/.local/share`, browser profiles, `~/.ssh` and dotfiles, read on the old computer and written on the new one; also its identity (`~/.local/share/clone_studio`) and resume journal (`~/.clone-studio`) |
| `--filesystem=/media`, `/run/media`, `/mnt` | the USB drive transport |
| `--talk-name=org.freedesktop.Flatpak` | the host-command shims (`flatpak-spawn --host`) |

`--talk-name=org.freedesktop.Flatpak` lets the app run any command on the
host. That is a sandbox escape, used here for exactly the five commands
above. An app that can write `~/.bashrc` and `~/.ssh`, which a migration tool
must, could escape anyway, so the sandbox here is about packaging, not
containment.

## Flathub

A Flathub submission would differ in two ways:

1. The `clone-studio` module's `tree` directory source becomes an `archive`
   source pointing at the release `.deb` with its sha256, or the app is built
   from source with the Flutter SDK and every pub package listed as sources,
   since Flathub builds offline.
2. Flathub reviews `--filesystem=home` and `--talk-name=org.freedesktop.Flatpak`
   closely; for a migration tool the reasons are the table above.

Each release also needs a `<release>` line in
`com.dhivalabs.clone_studio.metainfo.xml`.
