#!/usr/bin/env bash
# Builds clone-studio_<version>_<arch>.deb from the Linux release bundle,
# where <arch> is the architecture of the machine it runs on (amd64 or
# arm64).
#
# Run from the repo root after `flutter build linux --release`:
#
#     packaging/build_deb.sh [output-dir]        # default output-dir: dist/
#
# Layout: the bundle under /usr/lib/clone-studio, /usr/bin/clone-studio as a
# symlink to the binary, a .desktop entry and hicolor icons at 48, 128 and
# 256 pixels.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT_DIR="${1:-dist}"
# The package architecture follows the build machine, and so does Flutter's
# output directory (build/linux/x64 or build/linux/arm64).
DEB_ARCH="$(dpkg --print-architecture)"
case "$DEB_ARCH" in
  amd64) FLUTTER_ARCH=x64 ;;
  arm64) FLUTTER_ARCH=arm64 ;;
  *)
    echo "error: unsupported architecture '$DEB_ARCH' (amd64 or arm64)" >&2
    exit 1
    ;;
esac
BUNDLE="build/linux/$FLUTTER_ARCH/release/bundle"
VERSION="$(grep '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)"

[ -x "$BUNDLE/clone_studio" ] || {
  echo "error: $BUNDLE/clone_studio not found — run 'flutter build linux --release' first" >&2
  exit 1
}
for icon in assets/icon-48.png assets/icon-128.png assets/icon.png; do
  [ -f "$icon" ] || { echo "error: $icon missing" >&2; exit 1; }
done

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/clone-studio"

mkdir -p \
  "$PKG/DEBIAN" \
  "$PKG/usr/lib/clone-studio" \
  "$PKG/usr/bin" \
  "$PKG/usr/share/applications" \
  "$PKG/usr/share/doc/clone-studio" \
  "$PKG/usr/share/icons/hicolor/48x48/apps" \
  "$PKG/usr/share/icons/hicolor/128x128/apps" \
  "$PKG/usr/share/icons/hicolor/256x256/apps"

cp -r "$BUNDLE/." "$PKG/usr/lib/clone-studio/"
ln -s ../lib/clone-studio/clone_studio "$PKG/usr/bin/clone-studio"
install -m 0644 packaging/clone-studio.desktop \
  "$PKG/usr/share/applications/clone-studio.desktop"
cp assets/icon-48.png "$PKG/usr/share/icons/hicolor/48x48/apps/clone-studio.png"
cp assets/icon-128.png "$PKG/usr/share/icons/hicolor/128x128/apps/clone-studio.png"
cp assets/icon.png "$PKG/usr/share/icons/hicolor/256x256/apps/clone-studio.png"

cat > "$PKG/usr/share/doc/clone-studio/copyright" <<COPYRIGHT
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: clone-studio
Source: https://github.com/Dhiva-Labs/CloneStudio

Files: *
Copyright: $(date +%Y) Dhiva Labs
License: MIT
 See the LICENSE file at the project root (or
 https://opensource.org/license/mit) for the full license text.
COPYRIGHT

INSTALLED_SIZE="$(du -sk "$PKG/usr" | cut -f1)"
cat > "$PKG/DEBIAN/control" <<CONTROL
Package: clone-studio
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: ${DEB_ARCH}
Maintainer: Dhiva Labs <dhivakar1010@gmail.com>
Installed-Size: ${INSTALLED_SIZE}
Depends: libgtk-3-0t64 | libgtk-3-0, libglib2.0-0t64 | libglib2.0-0, openssl
Homepage: https://github.com/Dhiva-Labs/CloneStudio
Description: Move everything to your new Linux computer
 Clone Studio migrates files, apps, settings, SSH keys and desktop
 configuration from an old Linux computer to a new one - over Wi-Fi,
 a direct network cable, or a USB drive. Beginner-proof wizard,
 TLS-encrypted transfers with PIN pairing, journaled resume, and
 file-by-file selection with per-app picking.
 .
 Published by Dhiva-Labs.
CONTROL

# Normalize permissions: mkdir -p and cp inherit the caller's umask, which
# would otherwise leave group-writable dirs and files in the package. Only
# the real binary needs the executable bit back; every .so in the bundle
# ships non-executable already.
find "$PKG" -type d -exec chmod 0755 {} +
find "$PKG" -type f -exec chmod 0644 {} +
chmod 0755 "$PKG/usr/lib/clone-studio/clone_studio"

mkdir -p "$OUT_DIR"
DEB="$OUT_DIR/clone-studio_${VERSION}_${DEB_ARCH}.deb"
dpkg-deb --build --root-owner-group "$PKG" "$DEB" >/dev/null
echo "built $DEB"
