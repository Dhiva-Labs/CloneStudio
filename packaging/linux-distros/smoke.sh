#!/usr/bin/env bash
# Smoke run of an installed Clone Studio, shared by every Linux format CI
# builds besides the .deb: the .rpm on Fedora and openSUSE, the Arch package,
# the AppImage and the Flatpak.
#
# usage: smoke.sh <command that starts Clone Studio...>
#
# Run it on a virtual display whose framebuffer Xvfb mirrors into a file:
#
#   xvfb-run -a -s "-screen 0 1280x800x24 -fbdir $SMOKE_FB" \
#     dbus-run-session -- bash smoke.sh clone-studio
#
# 1. Makes a TLS identity with the exact openssl command Identity.load()
#    runs (lib/core/identity.dart), with the openssl this format gives the
#    app, and reads the certificate back. Pairing cannot start without it.
# 2. Starts Clone Studio and passes once the screen shows a painted Flutter
#    UI. The native GTK runner opens its window before any Dart code runs,
#    so a window alone proves nothing. A Flutter UI paints hundreds of
#    distinct colours; a runner whose Dart snapshot did not start shows a
#    handful. This is the colour count of the .deb smoke run in ci.yml, read
#    from Xvfb's framebuffer file because the Flatpak builder image has no
#    ImageMagick or xdotool.
#
# Environment: SMOKE_FB (the -fbdir directory), HOME (a fresh directory),
# OPENSSL (how to run openssl here, default `openssl`; the Flatpak passes the
# one inside its sandbox), SMOKE_SECONDS (default 120).
set -euo pipefail
: "${SMOKE_FB:?set SMOKE_FB to the directory given to Xvfb -fbdir}"
[ $# -ge 1 ] || { echo "usage: $0 <command...>" >&2; exit 2; }
read -r -a openssl <<< "${OPENSSL:-openssl}"
secs="${SMOKE_SECONDS:-120}"
min_colours=200
log="$HOME/clone-studio-smoke.log"

# 1. The app's identity, made the app's way.
dir="$HOME/.local/share/clone_studio"
mkdir -p "$dir"
rm -f "$dir/key.pem" "$dir/cert.pem"
"${openssl[@]}" req -x509 -newkey rsa:2048 -sha256 -nodes \
  -days 3650 -keyout "$dir/key.pem" -out "$dir/cert.pem" \
  -subj "/CN=$HOSTNAME/O=Clone Studio"
"${openssl[@]}" x509 -noout -subject -enddate -in "$dir/cert.pem"
echo "made the TLS identity with $("${openssl[@]}" version)"

# Distinct pixel values on the screen, from the XWD file Xvfb keeps up to
# date (big-endian header, then the colour map, then the pixels).
colours() {
  python3 - "$SMOKE_FB/Xvfb_screen0" <<'EOF'
import struct, sys
data = open(sys.argv[1], 'rb').read()
h = struct.unpack('>25I', data[:100])
header_size, width, height, bpp, bpl, ncolours = h[0], h[4], h[5], h[11], h[12], h[19]
start = header_size + ncolours * 12
step = bpp // 8
seen = set()
for y in range(height):
    row = data[start + y * bpl:start + y * bpl + width * step]
    if step == 4:
        seen.update(memoryview(row).cast('I'))
    else:
        seen.update(row[i:i + step] for i in range(0, len(row), step))
print(len(seen))
EOF
}

"$@" > "$log" 2>&1 &
pid=$!
painted=0
n=0
for i in $(seq 1 "$secs"); do
  kill -0 "$pid" 2> /dev/null || { echo "Clone Studio exited early"; cat "$log"; exit 1; }
  n="$(colours)"
  echo "screenshot ${i}: $n distinct colours"
  if [ "$n" -ge "$min_colours" ]; then painted=1; break; fi
  sleep 1
done
# Still up a few seconds after painting.
sleep 5
kill -0 "$pid" 2> /dev/null || { echo "Clone Studio died"; cat "$log"; exit 1; }
kill "$pid"
cat "$log"
ok=1
if [ "$painted" = 0 ]; then
  echo "the window never painted a Flutter UI ($n colours, need $min_colours)"
  ok=0
fi
if grep -E 'error while loading shared libraries|cannot open shared object|undefined symbol' "$log"; then
  ok=0
fi
[ "$ok" = 1 ]
echo "Flutter UI painted: $n distinct colours"
