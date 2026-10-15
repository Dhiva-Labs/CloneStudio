# Publishing Clone Studio to the Snap Store

Snap name: `clone-studio` (the same name as the Debian package).

## Current state

Packaging for 1.1.0 is in `snap/`; `clone-studio_1.1.0_amd64.snap` builds
and was tested, but has not been registered or uploaded yet.

Verified in an Ubuntu 24.04 VM (strict, all plugs connected), with two
local users standing in for the old and new computers:

* The UI renders (Impeller on Mesa from gnome-42-2204).
* The scan lists personal folders, `~/.config`/dotfiles, browser profiles,
  `~/.ssh`, desktop settings (`dconf dump`) and 58 apps: the host's 50
  manual apt packages (identical to the host's `apt-mark showmanual`), a
  system and a user flatpak, and the snaps with launchers.
* Wi-Fi transport end to end: discovery, PIN pairing over TLS, transfer,
  receipt. Files, dotfiles (kept as `<name> (from old computer)` beside the
  new computer's own), `~/.ssh` with mode 600, browser profiles, the dconf
  dump and the generated reinstall lists all arrived.
* USB transport: drive listing with free space, preflight, export and
  import through `removable-media`.
* "Install my apps now" shows the run-it-manually fallback.
* Without `transfer-journal` the receiver writes the files but stops at
  100% with no receipt (`mkdir ~/.clone-studio` denied) - it really is
  required.

**The first upload will be held for manual review**, because the snap
declares personal-files and system-files plugs (see below). A revision in
review **blocks every later release of the snap** until it is approved or
rejected (BranchPilot and Disc Writer both hit this), so post the store
request below at the same time as the upload, and do not upload another
revision expecting it to go out first.

## Confinement: strict, and why not classic

Clone Studio touches more of the system than any other Dhiva Labs app, so
the choice was made from what the code actually does at runtime:

| What the app does | How | Works strictly confined? |
| --- | --- | --- |
| Scan and restore Desktop, Documents, Downloads, Pictures, Videos, Music | Dart file I/O under `$HOME` | Yes - `home` |
| Restore into `~/CloneStudio-Restore/` (app lists, dconf dump, ...) | Dart file I/O | Yes - `home` |
| Resume journal `~/.clone-studio/journal.json` on the receiver | Dart file I/O | Only with personal-files (`transfer-journal`) |
| App settings: `~/.config`, `~/.local/share`, `~/.bashrc`, `~/.zshrc`, `~/.profile`, `~/.gitconfig`, `~/.vimrc` | Dart file I/O | Only with personal-files (`app-settings`) |
| Browser profiles: `~/.mozilla`, `~/.config/{google-chrome,chromium,BraveSoftware}` | Dart file I/O | Only with personal-files (`browser-profiles`) |
| SSH keys `~/.ssh` (read on the old computer, written on the new) | Dart file I/O | Only with personal-files (`ssh-folder`); the stock `ssh-keys` interface is read-only |
| Discovery: UDP broadcast probe/answer on port 42424 | raw sockets, no avahi | Yes - `network`, `network-bind` |
| Transfer: TLS server on 42425 (or any free port) + client | `SecureServerSocket` | Yes - `network`, `network-bind` |
| Direct cable | same sockets over the link-local address NetworkManager assigns | Yes |
| USB drive: list `/media/$USER/*`, `/run/media/$USER/*`, write/read a bundle | Dart file I/O | Yes - `removable-media` |
| Device identity: self-signed certificate | runs `openssl req` | Yes - core22's openssl is on the AppArmor allow-list |
| Free-space checks | runs `df -B1 --output=avail` | Via a shim - see below |
| Installed apps list | runs `apt-mark showmanual`, `flatpak list --app`, `snap list` | Via shims + `host-packages` - see below |
| Desktop look & feel | runs `dconf dump /` | Yes - `dconf` is staged, `gsettings` reads the real database |
| Scheduled tasks | runs `crontab -l` | **No** |
| "Install my apps now" | runs `pkexec bash install_apps.sh` | **No** - the app falls back to telling the user to run the script in a terminal |
| Battery check before a USB export | reads `/sys/class/power_supply` | Yes - allowed by the default template |

Nothing in the core flow needs to run a host package manager or write
outside the user's home: apps are moved as a *list* plus a reinstall
script that the user runs on the new computer, outside the snap. The only
host-privileged step is the optional "Install my apps now" button
(`pkexec`), which already has a fallback. So the core flow - pick files,
settings and apps on the old computer, transfer, restore on the new one -
works strictly confined given the interfaces below.

Classic was rejected because:

* The store grants classic only to listed categories (IDEs, compilers,
  terminals, and similar), and lists "access to arbitrary files" among the
  reasons that do *not* qualify - which is the whole of Clone Studio's
  need.
* Everything classic would add (`pkexec`, `crontab -l`) is optional, and
  everything the core flow needs has a strict interface.
* A classic upload always goes to manual review and blocks the snap's
  releases while it waits (see BranchPilot's packaging/SNAP.md).

### Plugs

| Plug | Interface | Purpose | Auto-connected? |
| --- | --- | --- | --- |
| `home` | home | personal folders, `~/CloneStudio-Restore` | Yes |
| `network`, `network-bind` | network, network-bind | discovery and TLS transfer | Yes |
| `desktop`, `desktop-legacy`, `wayland`, `x11`, `unity7`, `gsettings` | (gnome extension) | GUI, dconf | Yes |
| `removable-media` | removable-media | USB drive transport | No - `snap connect` (auto-connect requested) |
| `transfer-journal` | personal-files, write `$HOME/.clone-studio` | receiver resume journal | No - store declaration needed |
| `app-settings` | personal-files, write `$HOME/.config`, `$HOME/.local/share`, five dotfiles (four names each, see below) | "App settings & dotfiles" | No - store declaration needed |
| `browser-profiles` | personal-files, write `$HOME/.mozilla` + three Chrome-family dirs | "Browser profiles" | No - store declaration needed |
| `ssh-folder` | personal-files, write `$HOME/.ssh` | "SSH keys" | No - store declaration needed |
| `host-packages` | system-files, read the host's dpkg status, apt extended_states, `/var/lib/flatpak/app` (under `/var/lib/snapd/hostfs`) | "Applications" (apt and flatpak) | No - store declaration needed |

The personal-files plugs are split one per category in the app so the
store can grant each independently, and so a user can connect only what
they want moved. `write` implies read: each category is read on the old
computer and written on the new one.

personal-files grants a directory together with everything below it, but a
file only by its exact name. The receiver writes every file to
`<name>.partial` and renames it into place, and when the new computer
already has the file - it always has `.bashrc` and `.profile` - it keeps
both by writing `<name> (from old computer)`. So each of the five top-level
dotfiles is listed four times: `.bashrc`, `.bashrc.partial`,
`.bashrc (from old computer)` and `.bashrc (from old computer).partial`.
Without the extra names the first dotfile aborts the whole receive (found
in testing: AppArmor denied creating `~/.bashrc (from old computer).partial`
and the transfer stopped at 98%).

After installing:

```bash
sudo snap connect clone-studio:transfer-journal   # required to receive
sudo snap connect clone-studio:app-settings
sudo snap connect clone-studio:browser-profiles
sudo snap connect clone-studio:ssh-folder
sudo snap connect clone-studio:removable-media
sudo snap connect clone-studio:host-packages
```

### Environment and shims

* `$HOME` inside a snap is `~/snap/clone-studio/<rev>`. The app honours
  `CLONE_STUDIO_SOURCE_ROOT` / `CLONE_STUDIO_TARGET_ROOT`, so the snap sets
  both to `$SNAP_REAL_HOME`. Its TLS identity stays under the snap's own
  `$HOME/.local/share/clone_studio`.
* `PATH` starts with `$SNAP/shims`, holding four small scripts
  (`snap/local/shims/`) that answer the exact queries the app makes, from
  what a confined snap can see:
  * `apt-mark showmanual` - the snap's `/var/lib/dpkg` is core22's, not the
    host's. The shim reads the host's dpkg status and apt extended_states
    through `/var/lib/snapd/hostfs` (the `host-packages` plug). Its output
    was diffed against the real `apt-mark showmanual` on Ubuntu 24.04:
    identical.
  * `flatpak list --app --columns=application` - apps with an active
    `current` deployment in the host's `/var/lib/flatpak/app` and the user's
    `~/.local/share/flatpak/app`.
  * `snap list` - a confined snap may not talk to snapd. The shim lists the
    snaps that have a launcher in `/var/lib/snapd/desktop/applications`
    (readable through the desktop interfaces), so graphical snaps are
    offered and bases, runtimes and CLI-only snaps are not.
  * `df` - core22's `df` is not on the AppArmor allow-list, and
    `/proc/self/mountinfo` is denied, so the shim uses `stat -f`.

### What does not work under strict confinement

* **Scheduled tasks** (`crontab -l`): the crontab binary is setgid and the
  host's `/var/spool/cron` is not visible to a snap. The category shows
  "Nothing found here".
* **"Install my apps now"**: a snap cannot run `pkexec`. The app shows
  "Run manually: bash ~/CloneStudio-Restore/packages/install_apps.sh",
  which works (the script runs outside the snap). The snap description
  says so up front.
* **Snap list** covers snaps with a desktop launcher only (see above).
* **OS name** shown to the other computer is the snap's base ("Ubuntu Core
  22"), because `/etc/os-release` inside a snap resolves to the base's
  `/usr/lib/os-release`. The host name, which identifies the computer, is
  correct.
* **Any category whose plug is not connected.** Hidden paths cannot be
  listed without their plug, but top-level dotfiles (`~/.bashrc`, ...) can
  still be *stat*ed, so the scan offers them and reading them then fails.
  The app does not handle an unreadable file mid-transfer, so the transfer
  stalls. Connect the plugs before moving settings.
* A *second* fresh migration into the same home (journal deleted) would
  name a top-level dotfile `<name> (from old computer 2)`, which is not in
  the plug and stops the receive. A resumed or repeated transfer is fine:
  the journal skips files already received.
* snapd denies every snap reads under `~/.local/share/flatpak/exports/share`;
  the scan skips that directory quietly (flatpak recreates it when the apps
  are reinstalled).

### App issues found while testing the snap (not snap-specific)

These are in the 1.1.0 code and affect the .deb as well; they are listed
here because confinement makes the first two more likely.

* **An unreadable source file breaks the stream.** `_sendFile` sends the
  file header, fails to open the file, then sends `file_end` without the
  promised bytes; the receiver reads the next message as data, times out
  and reports an interruption, and a resume hits the same file.
* **Any write error on the receiver is uncaught** (`FileSystemException`
  escapes `_receiveLoopInner`), so the transfer freezes with no message.
  This is what an unconnected `transfer-journal` looks like.
* **"Files that need another pass" counts kept-both files.** The journal
  records `.bashrc`, the file is written as `.bashrc (from old computer)`,
  and `_verify` compares the new computer's own `.bashrc` against the old
  size.
* **USB import drops the app list.** `importBundle` filters by the review
  tree's leaves (`Applications/...`), but the bundle carries the generated
  `CloneStudio-Restore/packages/*` files, which are filtered out. Wi-Fi and
  cable transfers are unaffected.
* Keeping the resume journal outside `~/.clone-studio` (for example under
  `$XDG_DATA_HOME`, which is private to the snap) would remove the one
  store grant the snap cannot work without.

## Store request

Post in the forum's **store-requests** category
(<https://forum.snapcraft.io/c/store-requests>), titled
"clone-studio: personal-files and system-files (auto-connect)":

> **clone-studio: request for personal-files, system-files and auto-connect**
>
> Clone Studio (https://github.com/Dhiva-Labs/CloneStudio) is a migration
> assistant that moves a user's files, settings and app list from an old
> Linux computer to a new one, over the LAN, a direct cable or a USB drive
> (TLS with PIN pairing; nothing goes to the internet). The user picks
> exactly what moves, category by category and file by file. The snap is
> strictly confined; we are asking for the following plugs, each named after
> the category it serves so they can be granted separately:
>
> * `transfer-journal` - personal-files, write `$HOME/.clone-studio`. The
>   receiving computer journals every verified file there so an interrupted
>   transfer resumes. Without it the snap cannot receive at all. Please
>   allow installation **and auto-connection**.
> * `app-settings` - personal-files, write `$HOME/.config`,
>   `$HOME/.local/share`, and `$HOME/.bashrc`, `$HOME/.zshrc`,
>   `$HOME/.profile`, `$HOME/.gitconfig`, `$HOME/.vimrc`. The "App settings
>   & dotfiles" category: read on the old computer, restored on the new
>   one. Existing files on the new computer are never overwritten: the old
>   one is saved next to it as `<name> (from old computer)`, and every file
>   is written as `<name>.partial` first and renamed when verified, so each
>   dotfile is also listed under those names.
> * `browser-profiles` - personal-files, write `$HOME/.mozilla`,
>   `$HOME/.config/google-chrome`, `$HOME/.config/chromium`,
>   `$HOME/.config/BraveSoftware`. The "Browser profiles" category.
> * `ssh-folder` - personal-files, write `$HOME/.ssh`. The "SSH keys"
>   category; the stock ssh-keys interface is read-only, and the new
>   computer has to write the keys.
> * `host-packages` - system-files, **read-only**:
>   `/var/lib/snapd/hostfs/var/lib/dpkg/status`,
>   `/var/lib/snapd/hostfs/var/lib/apt/extended_states`,
>   `/var/lib/snapd/hostfs/var/lib/flatpak/app`. The "Applications"
>   category lists the user's manually installed apt packages and flatpaks
>   so they can be reinstalled on the new computer. Inside the snap
>   `/var/lib/dpkg` is the base snap's, so the host's database is read
>   through hostfs. Nothing is installed by the snap; the user runs the
>   generated reinstall script themselves.
> * Auto-connection of `removable-media` for the USB-drive transport.
>
> Why personal-files rather than classic: everything the app does is file
> I/O in the user's home plus sockets; it never needs to run host tools as
> root. Moving settings is the product's purpose, so the write access is
> the feature, not a side effect - and the user ticks every item that is
> written. We would rather be strict with these grants than ask for
> classic.

## Building

```bash
snapcraft pack --use-lxd
```

Produces `clone-studio_1.1.0_amd64.snap` in the repository root (ignored by
git). Run on an arm64 machine it produces `clone-studio_1.1.0_arm64.snap`
instead: `architectures:` in `snap/snapcraft.yaml` builds on each architecture
it runs on. CI builds both and keeps them as workflow artifacts; it never
uploads to the Store. The Flutter part's `override-pull` deletes any host `build/`, because
its CMakeCache.txt names host paths and CMake refuses to reuse it.

**Do not add `libgtk-3-0` to stage-packages** (BranchPilot's snap does).
GTK, GLib, the X11/Wayland client libraries and Mesa come from the
gnome-42-2204 content snap; staging the archive's older copies puts them
first on `LD_LIBRARY_PATH`, EGL fails to initialise ("Failed to create EGL
context", "Impeller validation: Could not determine GL version") and the
window never appears. The first build of this snap did exactly that.

Known build stalls, from this and other Dhiva Labs snaps:

* The Flutter build can hang at "[4/11] Linux SDK" on an idle Dart
  download. Find the stuck process and kill it; the build carries on:

  ```bash
  C=$(lxc --project snapcraft list -c n --format csv | grep clone-studio)
  lxc --project snapcraft exec "$C" -- pgrep -a dart
  lxc --project snapcraft exec "$C" -- kill <pid>
  ```

* A stalled snap download inside the build container resumes after
  `lxc --project snapcraft exec "$C" -- systemctl restart snapd`.

## Smoke test before uploading

```bash
sudo snap install --dangerous ./clone-studio_1.1.0_amd64.snap
for p in transfer-journal app-settings browser-profiles ssh-folder \
         removable-media host-packages; do
  sudo snap connect clone-studio:$p
done
clone-studio
```

(`--dangerous` installs may connect personal-files and system-files plugs
locally; the store's declaration only governs store installs.)

## Uploading

```bash
snapcraft upload --release=stable clone-studio_1.1.0_amd64.snap
snapcraft upload --release=stable clone-studio_1.1.0_arm64.snap   # the arm64 build
snapcraft revisions clone-studio
snapcraft status clone-studio
```

Expect "will need manual review" for the plugs above. `snapcraft status`
must list a revision on `stable` before anything has shipped.
