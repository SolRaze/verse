#!/bin/bash
#
# Nightly build. Three things, in order: derive a version from git, produce an unsigned .ipa,
# hand it to LiveContainer on the phone.
#
# Unsigned is deliberate. LiveContainer signs its guest apps itself, so a build that goes through
# it does not burn a 7-day free-profile slot and does not need -allowProvisioningUpdates. The
# trade is that app extensions do not run under LiveContainer: the widget and the Live Activity
# are not testable this way, only through a normal signed install.
#
# Override the target with VERSE_DEVICE / VERSE_LC_BUNDLE if the phone or the container changes.
set -euo pipefail

cd "$(dirname "$0")/.."

DEVICE="${VERSE_DEVICE:-8401270A-D055-5339-B34C-CE4CF673365B}"   # deuce, iPhone 17e
LC_BUNDLE="${VERSE_LC_BUNDLE:-com.kdt.livecontainer.J7C26745B5}"
APP_BUNDLE="${VERSE_APP_BUNDLE:-com.sol.verse}"
PORT="${VERSE_PORT:-8787}"

# Derived, never stored. The commit count only ever goes up, so every commit is already a bump
# and a push ships a new build number without a version file to edit. The date is the commit's,
# not today's — it identifies the code, not the moment someone happened to build it.
BUILD=$(git rev-list --count HEAD)
VERSION=$(git log -1 --format=%cd --date=format:%Y.%m.%d)
NAME="Verse-n${BUILD}"

echo "==> nightly ${VERSION} (${BUILD})"

xcodegen generate

DD=build/nightly
xcodebuild -scheme Verse -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DD" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build

APP="$DD/Build/Products/Release-iphoneos/Verse.app"
[ -d "$APP" ] || { echo "no .app at $APP"; exit 1; }

# An .ipa is a zip with the .app under Payload/. -y keeps symlinks as symlinks.
OUT=build/ipa
rm -rf "$OUT/Payload" "$OUT/$NAME.ipa"
mkdir -p "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/"

# App thinning. The prebuilt VLCKit binary ships fat (armv7/armv7s/arm64) and unstripped; only
# -exportArchive drops slices the deployment target cannot load, and this script wraps the .app
# by hand. iOS 26 runs no 32-bit code, so those two slices are ~58MB of unreachable payload.
# Safe here only because this path is deliberately unsigned — LiveContainer signs its guests, so
# there is no signature for lipo/strip to invalidate. -x -S drops local and debug symbols;
# exported symbols stay, so dynamic linking is unaffected.
for bin in "$OUT/Payload/Verse.app/Frameworks/"*.framework/*; do
  [ -f "$bin" ] && file -b "$bin" | grep -q 'Mach-O' || continue
  if lipo -info "$bin" 2>/dev/null | grep -q '^Architectures in the fat file'; then
    lipo -thin arm64 "$bin" -output "$bin.thin" && mv "$bin.thin" "$bin"
  fi
  strip -x -S "$bin" 2>/dev/null || true
done

(cd "$OUT" && zip -qry "$NAME.ipa" Payload)
rm -rf "$OUT/Payload"
echo "==> $OUT/$NAME.ipa"

# Two destinations, because "+ then pick the ipa" only works if the Files picker can actually
# reach the folder. LiveContainer's own Documents is where it looks first, but that folder is
# only browsable if LiveContainer exports it; Verse's Documents definitely is, since
# UIFileSharingEnabled and LSSupportsOpeningDocumentsInPlace are both set in project.yml.
# Whichever one LiveContainer can see wins — a stray copy costs 46MB, a failed install costs
# the whole trip to the phone.
push_to() {
  if xcrun devicectl device copy to --device "$DEVICE" \
      --domain-type appDataContainer --domain-identifier "$1" \
      --source "$OUT/$NAME.ipa" --destination "Documents/$NAME.ipa" --quiet 2>/dev/null; then
    echo "    -> $1"
  else
    echo "    -- $1 (no container on device, skipped)"
  fi
}

if [ -z "${CI:-}" ] && xcrun devicectl list devices 2>/dev/null | grep -q "$DEVICE"; then
  echo "==> copying to deuce"
  push_to "$LC_BUNDLE"
  push_to "$APP_BUNDLE"
  echo "==> Files > On My iPhone > Verse (or LiveContainer) > $NAME.ipa"
else
  echo "==> deuce not connected; ipa left at $OUT/$NAME.ipa"
fi

# Picker-free path. LiveContainer takes an install URL directly, which sidesteps the file picker
# and every question of which folder it can browse. Blocks until ctrl-c, hence the opt-in flag.
if [ "${1:-}" = "--serve" ]; then
  ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo 127.0.0.1)
  echo
  echo "==> open this on the phone:"
  echo "    livecontainer://install?url=http://$ip:$PORT/$NAME.ipa"
  echo "==> ctrl-c when the install finishes"
  cd "$OUT" && exec python3 -m http.server "$PORT" --bind 0.0.0.0
fi
