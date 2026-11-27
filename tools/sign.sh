#!/bin/zsh
# usage: sign.sh <App.app> <profile.mobileprovision> <bundle-id> <extra-entitlements-xml-fragment>
set -e
APP="$1"; PROF="$2"; BID="$3"; EXTRA="$4"
ID="${AIR_SIGN_IDENTITY:?set AIR_SIGN_IDENTITY to your signing identity hash (security find-identity -v -p codesigning)}"
TEAM="${AIR_TEAM_ID:?set AIR_TEAM_ID to your Apple team ID}"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BID" "$APP/Info.plist"
find "$APP" -name "_CodeSignature" -type d -prune -exec rm -rf {} +
rm -f "$APP/embedded.mobileprovision"; cp "$PROF" "$APP/embedded.mobileprovision"
ENT="${APP:h}/ents.plist"
cat > "$ENT" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>application-identifier</key><string>$TEAM.$BID</string>
<key>com.apple.developer.team-identifier</key><string>$TEAM</string>
<key>get-task-allow</key><true/>
<key>keychain-access-groups</key><array><string>$TEAM.*</string><string>com.apple.token</string></array>
$EXTRA
</dict></plist>
XML
# sign nested code innermost first
find "$APP" -depth \( -name "*.dylib" -o -name "*.framework" -o -name "*.appex" \) -print0 | while IFS= read -r -d '' f; do
  codesign -f -s $ID --generate-entitlement-der "$f" >/dev/null 2>&1 || codesign -f -s $ID "$f"
done
codesign -f -s $ID --entitlements "$ENT" --generate-entitlement-der "$APP"
rm -f "$ENT"
codesign --verify --deep --strict "$APP" && echo "verified: $APP"
