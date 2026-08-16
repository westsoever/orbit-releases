#!/usr/bin/env bash
# Shared helpers for assembling Orbit Access .app bundle resources.
# Used by run_orbit_access_app.sh and build-app-bundle.sh.

compile_orbit_app_icon_icns() {
  local appiconset="$1"
  local icns_out="$2"
  local iconset
  iconset="$(mktemp -d)/AppIcon.iconset"

  [[ -d "$appiconset" ]] || { echo "Missing AppIcon.appiconset: $appiconset" >&2; return 1; }

  mkdir -p "$iconset"
  cp "$appiconset/icon_16.png" "$iconset/icon_16x16.png"
  cp "$appiconset/icon_32.png" "$iconset/icon_16x16@2x.png"
  cp "$appiconset/icon_32.png" "$iconset/icon_32x32.png"
  cp "$appiconset/icon_64.png" "$iconset/icon_32x32@2x.png"
  cp "$appiconset/icon_128.png" "$iconset/icon_128x128.png"
  cp "$appiconset/icon_256.png" "$iconset/icon_128x128@2x.png"
  cp "$appiconset/icon_256.png" "$iconset/icon_256x256.png"
  cp "$appiconset/icon_512.png" "$iconset/icon_512x512.png"
  cp "$appiconset/icon_1024.png" "$iconset/icon_512x512@2x.png"

  iconutil -c icns -o "$icns_out" "$iconset"
}

find_orbit_access_resource_bundle() {
  local app_dir="$1"
  local swift_config="${2:-debug}"
  local bundle
  bundle="$(find "$app_dir/.build" -path "*/$swift_config/OrbitAccessApp_OrbitAccessApp.bundle" -type d 2>/dev/null | head -1)"
  if [[ -z "$bundle" ]]; then
    bundle="$(find "$app_dir/.build" -name "OrbitAccessApp_OrbitAccessApp.bundle" -type d 2>/dev/null | head -1)"
  fi
  [[ -n "$bundle" ]] || { echo "OrbitAccessApp resource bundle not found under $app_dir/.build" >&2; return 1; }
  printf '%s' "$bundle"
}

write_orbit_access_resource_bundle_plist() {
  local resource_bundle="$1"
  cat >"$resource_bundle/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.orbit.access.OrbitAccessApp.resources</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundlePackageType</key>
	<string>BNDL</string>
	<key>CFBundleVersion</key>
	<string>1</string>
</dict>
</plist>
EOF
}

install_orbit_access_bundle_resources() {
  local app_dir="$1"
  local bundle_root="$2"
  local swift_config="${3:-debug}"

  local resources="$bundle_root/Contents/Resources"
  local macos="$bundle_root/Contents/MacOS"
  local appiconset="$app_dir/Resources/Assets.xcassets/AppIcon.appiconset"
  local resource_bundle_dest="$macos/OrbitAccessApp_OrbitAccessApp.bundle"

  mkdir -p "$resources" "$macos"

  rm -rf "$resources/Assets.xcassets"
  compile_orbit_app_icon_icns "$appiconset" "$resources/AppIcon.icns"

  local resource_bundle
  resource_bundle="$(find_orbit_access_resource_bundle "$app_dir" "$swift_config")"
  rm -rf "$resource_bundle_dest"
  cp -R "$resource_bundle" "$resource_bundle_dest"
  write_orbit_access_resource_bundle_plist "$resource_bundle_dest"
}

set_plist_lsenvironment() {
  local plist="$1"
  local key="$2"
  local value="$3"
  /usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :LSEnvironment:$key string $value" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :LSEnvironment:$key $value" "$plist"
}

set_plist_key() {
  local plist="$1" key="$2" type="$3" value="$4"
  /usr/libexec/PlistBuddy -c "Add :$key $type $value" "$plist" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist" >/dev/null
}

orbit_build_sha() {
  git -C "$1" rev-parse --short HEAD 2>/dev/null || true
}

# Record which source tree this bundle was built from, and report it back to the caller through
# ORBIT_BUILD_SHA (empty outside a checkout) and ORBIT_BUILD_DIRTY (true|false).
#
# Named globals rather than a tab-separated echo: tab is IFS whitespace, so
# `IFS=$'\t' read -r sha dirty` silently *drops* a leading empty field and shifted "false" into
# the SHA whenever there was no SHA — which made the summary line claim "app was built from false".
#
# Custom plist keys rather than CFBundleVersion: Apple requires that to be one to three
# period-separated integers, so a SHA there would be a notarisation blocker on the publish
# path, and it is also what LaunchServices uses to arbitrate our two same-identifier bundles.
#   OrbitBuildSHA    git short SHA, or "unknown" outside a checkout (install.sh can build from a tarball)
#   OrbitBuildDirty  true when the tree had uncommitted edits, so a SHA match proves nothing
#   OrbitBuildTime   UTC ISO-8601 taken at the *start* of the build run, so any daemon whose
#                    started_at precedes it cannot be running this build's tree
stamp_orbit_build_identity() {
  local plist="$1" source_root="$2" build_started_at="$3"
  local sha dirty=false
  sha="$(orbit_build_sha "$source_root")"
  if [[ -n "$sha" && -n "$(git -C "$source_root" status --porcelain 2>/dev/null)" ]]; then
    dirty=true
  fi
  set_plist_key "$plist" OrbitBuildSHA string "${sha:-unknown}"
  set_plist_key "$plist" OrbitBuildDirty bool "$dirty"
  set_plist_key "$plist" OrbitBuildTime string "$build_started_at"
  ORBIT_BUILD_SHA="$sha"
  ORBIT_BUILD_DIRTY="$dirty"
}

# "cab386c (dirty)" / "cab386c" / "unknown (no git checkout)" — shared by both scripts' summaries.
format_build_identity() {
  local sha="$1" dirty="$2"
  if [[ -z "$sha" ]]; then
    printf 'unknown (no git checkout)'
  elif [[ "$dirty" == true ]]; then
    printf '%s (dirty)' "$sha"
  else
    printf '%s' "$sha"
  fi
}

codesign_orbit_access_bundle() {
  local bundle_root="$1"
  local executable_name="$2"
  local entitlements="$3"

  local executable="$bundle_root/Contents/MacOS/$executable_name"
  local resource_bundle="$bundle_root/Contents/MacOS/OrbitAccessApp_OrbitAccessApp.bundle"
  local lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

  [[ -f "$executable" ]] || { echo "Missing executable: $executable" >&2; return 1; }
  [[ -f "$entitlements" ]] || { echo "Missing entitlements: $entitlements" >&2; return 1; }

  xattr -cr "$bundle_root"
  rm -rf "$bundle_root/Contents/_CodeSignature"

  codesign --force --sign - "$resource_bundle"
  codesign --force --sign - --entitlements "$entitlements" "$executable"
  codesign --force --sign - "$bundle_root"

  if [[ -x "$lsregister" ]]; then
    "$lsregister" -f "$bundle_root" >/dev/null 2>&1 || true
  fi
}
