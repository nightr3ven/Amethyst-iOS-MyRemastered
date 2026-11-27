#!/bin/zsh
# Build libmobileglues.dylib for iOS exactly like the Air Makefile's dep_mg
# target (pinned SPIRV-Cross/glslang + glslang crash-guard patches), without
# the Makefile's unrelated JDK 8 check.
#
# usage: tools/build-mg.sh            (configure if needed, then build)
set -e
AIR="${0:A:h:h}"
MG3REL="Natives/external/MobileGlues/src/main/cpp/3rdparty"
MG3="$AIR/$MG3REL"
# MobileGlues' CMake doesn't quote paths, so build through a space-free link.
LINK="${MG_SRC_LINK:-/tmp/airsrc-mg}"
ln -sfn "$AIR" "$LINK"
OUT="$LINK/Natives/build/mobileglues-nospace"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)

align() {
  local name=$1 url=$2 sha=$3
  if [[ -f "$MG3/$name/.air_pin_$sha" ]]; then echo "[mg] $name pinned ($sha)"; return; fi
  echo "[mg] $name: fetching pinned $sha"
  local tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/src.tgz" "$url"
  rm -rf "$MG3/$name"; mkdir -p "$MG3/$name"
  tar -xzf "$tmp/src.tgz" -C "$MG3/$name" --strip-components=1
  touch "$MG3/$name/.air_pin_$sha"
  rm -rf "$tmp"
}

mkdir -p /tmp/mgpin_patches
cp "$MG3"/*.patch /tmp/mgpin_patches/ 2>/dev/null || true
align SPIRV-Cross https://codeload.github.com/KhronosGroup/SPIRV-Cross/tar.gz/a0fba56c34a6700f1724bf9b751da5b488a3775c a0fba56
align glslang https://codeload.github.com/KhronosGroup/glslang/tar.gz/f5f664dee8146676b04a332a7233959fc3ce9681 f5f664d
cp /tmp/mgpin_patches/*.patch "$MG3/" 2>/dev/null || true

GUARD="$MG3/glslang/glslang/MachineIndependent/ParseHelper.cpp"
if grep -q "Defensive null guards" "$GUARD"; then
  echo "[mg] glslang guards present"
else
  for p in glslang-lvalue-nullguard.patch glslang-pool-zero-and-size-guards.patch; do
    [[ -f "$MG3/$p" ]] || { echo "[mg] ERROR: missing $p"; exit 1; }
    if git -C "$AIR" apply --check -p1 --directory="$MG3REL/glslang" "$MG3/$p" 2>/dev/null; then
      git -C "$AIR" apply -p1 --directory="$MG3REL/glslang" "$MG3/$p" && echo "[mg] applied $p"
    elif git -C "$AIR" apply --check -R -p1 --directory="$MG3REL/glslang" "$MG3/$p" 2>/dev/null; then
      echo "[mg] $p already applied"
    else
      echo "[mg] ERROR: $p neither applies nor is applied"; exit 1
    fi
  done
fi

mkdir -p "$OUT"
if [[ ! -f "$OUT/CMakeCache.txt" ]]; then
  (cd "$OUT" && cmake -DMACOS=1 -DCMAKE_CROSSCOMPILING=true -DCMAKE_SYSTEM_NAME=Darwin \
     -DCMAKE_SYSTEM_PROCESSOR=aarch64 -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_ARCHITECTURES=arm64 \
     -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_C_FLAGS="-arch arm64" -DCMAKE_BUILD_TYPE=RelWithDebInfo \
     "$LINK/Natives/external/MobileGlues/MobileGlues-cpp/")
fi
cmake --build "$OUT" --config RelWithDebInfo -j10 --target mobileglues
ls -la "$OUT"/libmobileglues*.dylib
