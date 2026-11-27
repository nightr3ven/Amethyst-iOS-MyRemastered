#!/bin/zsh
# Rebuild Air's launcher executable from ./Air, drop it into the known-good
# signed Air bundle (work/air), re-sign with the dev team, and install on the iPhone.
#
# usage: tools/deploy-air.sh [--no-build] [--no-install]
set -e
# Lives in the Air repo's tools/. The workspace around the repo (default: its
# parent folder) holds work/air, the known-good signed bundle.
AIR="${0:A:h:h}"
ROOT="${AIR_WORKSPACE:-${AIR:h}}"
BUILD="$AIR/Natives/build"
APP="$ROOT/work/air/Payload/AngelAuraAmethyst.app"
PROFILE="${AIR_PROFILE:?set AIR_PROFILE to your .mobileprovision path}"
DEVICE="${AIR_DEVICE:?set AIR_DEVICE to your device id (xcrun devicectl list devices)}"
EXTRA='<key>com.apple.developer.kernel.extended-virtual-addressing</key><true/><key>com.apple.developer.kernel.increased-memory-limit</key><true/>'

build=1; install=1
for a in "$@"; do
  case $a in --no-build) build=0;; --no-install) install=0;; esac
done

if (( build )); then
  SDK=$(xcrun --sdk iphoneos --show-sdk-path)
  $(xcrun -f swiftc) -parse-as-library -emit-object -target arm64-apple-ios14.0 -sdk "$SDK" \
    -o "$BUILD/AmeTabBar.o" "$AIR/Natives/AmeTabBar.swift"
  cmake --build "$BUILD" --target AngelAuraAmethyst -j8 2>&1 | grep -E " error:|Undefined symbols|Built target AngelAura" || true
fi

NEW="$BUILD/AngelAuraAmethyst.app/AngelAuraAmethyst"
[[ -f "$NEW" ]] || { echo "no built executable at $NEW"; exit 1; }
cp "$NEW" "$APP/AngelAuraAmethyst"

# Localizations and other bundle resources that live next to the sources
if [[ -d "$AIR/Natives/resources/en.lproj" ]]; then
  for l in "$AIR"/Natives/resources/*.lproj; do
    [[ -d "$APP/${l:t}" ]] && cp "$l"/*.strings "$APP/${l:t}/" 2>/dev/null || true
  done
fi

# MobileGlues built from source (tools/build-mg.sh) with the redesign's draw
# fixes. MG_ORIGINAL=1 puts back the original prebuilt library instead.
MG_BUILT="/tmp/airsrc-mg/Natives/build/mobileglues-nospace/libmobileglues.dylib"
[[ -f "$MG_BUILT" ]] || MG_BUILT="$(ls -t /private/tmp/claude-*/**/airsrc/Natives/build/mobileglues-nospace/libmobileglues.dylib 2>/dev/null | head -1)"
if [[ "$MG_ORIGINAL" == "1" ]]; then
  cp "$ROOT/work/libmobileglues.orig.dylib" "$APP/Frameworks/libmobileglues.dylib" && echo "MobileGlues: original prebuilt"
elif [[ -n "$MG_BUILT" && -f "$MG_BUILT" ]]; then
  cp "$MG_BUILT" "$APP/Frameworks/libmobileglues.dylib" && echo "MobileGlues: built from source ($MG_BUILT)"
fi

# Bundled resources added by the redesign
cp "$AIR/Natives/resources/default_controls.json" "$APP/default_controls.json"

zsh "$AIR/tools/sign.sh" "$APP" "$PROFILE" gerwitz.air "$EXTRA" | tail -1

if (( install )); then
  xcrun devicectl device install app --device $DEVICE "$APP" 2>&1 | grep -E "bundleID|rror" | head -3
fi
