#!/usr/bin/env bash
# visual-check.sh
#
# Builds the screenshot variant of Plic from this tree, runs it against the
# fake homeserver, opens a few rooms and captures the window of each. The
# captures are what to look at before a release: the 0.5.38 freeze passed
# 328 unit tests and would have been visible in the first one of these.
#
# The variant lives in its own checkout with its own storage names, so it
# never touches the real account's data. Its session on the fake server
# (@alex:pebble.dev) persists between runs.
#
# Usage: scripts/visual-check.sh [output-dir]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VARIANT="${PLIC_VARIANT:-/Volumes/SSD2TO/dev/plic-screenshots}"
SERVER="${PLIC_FAKE_SERVER:-/Volumes/SSD2TO/dev/screenshot-homeserver}"
OUT="${1:-$SERVER/captures/visual-check/$(date +%Y%m%d-%H%M)}"
DEFAULTS_DOMAIN="$HOME/Library/Containers/im.plic/Data/Library/Preferences/im.plic"

# Rooms on the fake server worth a look: a group room with media and
# pills, a direct chat, and a room with many members for the inspector.
ROOMS=(
  "design-system:!LYlamK7QH4m3Sdc_FGHWbblzP9VT3XeT2Xf5iKTutYI"
  "jordan-dm:!QsbGXUcT74Z0ofDX2gt9whaPTyzMkfjMOnUPHJZSnsE"
  "general:!Tg3D_GO7Z3848jbT8pgfEJ-0UCyhP6miIZT4AVLlm7U"
)

step() { printf '\n==> %s\n' "$*"; }

step "Syncing sources into the variant"
for dir in Relay RelayKit RelayShareExtension Packages/RelayInterface; do
  rsync -a --delete --exclude '.git' "$HERE/$dir/" "$VARIANT/$dir/"
done
# The variant keeps its own stores and Keychain items, so a run never opens
# the real account. Re-applied after every sync, since the sync undoes it.
find "$VARIANT/RelayKit" "$VARIANT/Relay" "$VARIANT/RelayShareExtension" -name '*.swift' -print0 \
  | xargs -0 perl -pi -e 's/-debug(\.json)?"/-screenshots$1"/g'
if grep -rlq -- '-debug"' "$VARIANT/RelayKit" "$VARIANT/Relay"; then
  echo "A storage name still says -debug; refusing to run the variant." >&2; exit 1
fi

step "Building the variant"
xcodebuild build -project "$VARIANT/Relay.xcodeproj" -scheme Relay \
  -destination 'platform=macOS,arch=arm64' \
  -clonedSourcePackagesDirPath "$HERE/.spm-cache" \
  -derivedDataPath "$VARIANT/.derived" -quiet 2>&1 | grep -E 'error:|warning: .*Relay' || true
APP="$VARIANT/.derived/Build/Products/Debug/Plic.app"
[[ -d "$APP" ]] || { echo "No app at $APP" >&2; exit 1; }

step "Starting the fake homeserver"
if ! "$SERVER/native-runtime" inspect >/dev/null 2>&1; then
  "$SERVER/native-runtime" run -d -e CONTINUWUITY_SERVER_NAME=pebble.dev -e CONTINUWUITY_PORT=8008 \
    -e CONTINUWUITY_ALLOW_REGISTRATION=true -e CONTINUWUITY_REGISTRATION_TOKEN=seed-token \
    -e CONTINUWUITY_LOG=warn >/dev/null
  sleep 3
fi
curl -sf -m 5 http://127.0.0.1:8008/_matrix/client/versions >/dev/null || { echo "Fake homeserver not answering" >&2; exit 1; }

# A tiny helper that prints the window number of the variant's main window,
# for screencapture. Compiled once per run; needs no screen permission.
HELPER="$(mktemp -d)/plic-window"
cat > "$HELPER.swift" <<'SWIFT'
import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    if let bounds = w[kCGWindowBounds as String] as? [String: CGFloat], (bounds["Width"] ?? 0) > 600,
       let id = w[kCGWindowNumber as String] as? Int {
        print(id); break
    }
}
SWIFT
swiftc -O -o "$HELPER" "$HELPER.swift" 2>/dev/null

mkdir -p "$OUT"
quit_plic() { osascript -e 'tell application id "im.plic" to quit' >/dev/null 2>&1 || true; sleep 2; pkill -x Plic 2>/dev/null || true; sleep 1; }

for entry in "${ROOMS[@]}"; do
  name="${entry%%:*}"; room="${entry#*:}"
  step "Capturing $name"
  quit_plic
  defaults write "$DEFAULTS_DOMAIN" selectedRoomId -string "$room"
  open -a "$APP"
  sleep 12
  pid="$(pgrep -x Plic | head -1)"
  wid="$("$HELPER" "$pid" || true)"
  if [[ -z "$wid" ]]; then
    echo "No window found for $name" >&2; continue
  fi
  screencapture -x -o -l "$wid" "$OUT/$name.png"
  echo "    $OUT/$name.png"
done

quit_plic
if [[ -d /Applications/Plic.app ]]; then open -a /Applications/Plic.app; fi
step "Done. Look at every capture before releasing."
ls -1 "$OUT"
