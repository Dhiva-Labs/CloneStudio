# Changelog

## 1.1.1 - 2026-10-16

### Added
- Linux arm64 build: `clone-studio_1.1.1_arm64.deb` next to the amd64 one, built natively on an ARM64 runner and smoke-run there.
- `packaging/build_deb.sh` builds the `.deb` from the release bundle for the architecture of the build machine.
- Snap packaging (`snap/`, strict confinement) for amd64 and arm64. CI builds both snaps; they are not on the Snap Store yet.
- CI builds, tests and packages Clone Studio on x64 and arm64 runners, and attaches the `.deb` of both architectures to a published release without overwriting files the release already has.

No other application changes since 1.1.0; the in-app version label reads 1.1.1.

## 1.1.0 - 2026-07-23

Selection-first flow and file-by-file control: choose what moves before connecting, a full folder tree with tri-state folders and live size totals, review and untick on the new computer, and a list of installed apps (apt, flatpak, snap) to pick from.
