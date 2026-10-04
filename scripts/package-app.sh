#!/bin/sh
set -eu

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
repo_root=$(CDPATH= cd "$script_dir/.." && pwd)
cd "$repo_root"

swift build -c release
bin_dir=$(swift build -c release --show-bin-path)
executable="$bin_dir/CodexHUD"

if [ ! -x "$executable" ]; then
    printf 'Expected release executable at %s\n' "$executable" >&2
    exit 1
fi

app_bundle="$repo_root/.build/CodexHUD.app"
contents="$app_bundle/Contents"
resources="$contents/Resources"

rm -rf "$app_bundle"
mkdir -p "$contents/MacOS" "$resources"
cp "$executable" "$contents/MacOS/CodexHUD"

for resource_bundle in "$bin_dir"/*.bundle "$bin_dir"/*.resources; do
    if [ -d "$resource_bundle" ]; then
        cp -R "$resource_bundle" "$resources/"
    fi
done

cat > "$contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>CodexHUD</string>
	<key>CFBundleIdentifier</key>
	<string>com.codexhud.s1</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>CodexHUD</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

printf '%s\n' "$app_bundle"
