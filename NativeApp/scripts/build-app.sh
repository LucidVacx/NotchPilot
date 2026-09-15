#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
output_dir="$project_dir/outputs"
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/notchpilot-build.XXXXXX")"
module_cache="$staging_dir/module-cache"
scratch_dir="$staging_dir/swift-build"
app_dir="$staging_dir/NotchPilot.app"
output_app="$output_dir/NotchPilot.app"
output_zip="$output_dir/NotchPilot-beta.zip"
trap 'rm -rf "$staging_dir"' EXIT

cd "$project_dir"
mkdir -p "$module_cache"
export CLANG_MODULE_CACHE_PATH="$module_cache"
swift build --disable-sandbox --scratch-path "$scratch_dir" -c release --product NotchPilot -debug-info-format none
binary_dir="$(swift build --disable-sandbox --scratch-path "$scratch_dir" -c release --show-bin-path)"

mkdir -p "$app_dir/Contents/MacOS"
mkdir -p "$app_dir/Contents/Resources"
cp "$binary_dir/NotchPilot" "$app_dir/Contents/MacOS/NotchPilot"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/../LICENSE" "$app_dir/Contents/Resources/LICENSE"
for resource_bundle in "$binary_dir"/*.bundle(N); do
    ditto --norsrc "$resource_bundle" "$app_dir/Contents/Resources/${resource_bundle:t}"
done
ditto --norsrc "$project_dir/Resources/ThirdParty" "$app_dir/Contents/Resources/ThirdParty"
chmod 755 "$app_dir/Contents/MacOS/NotchPilot"
xattr -cr "$app_dir"
codesign --force --deep --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"

rm -rf "$output_app"
rm -f "$output_zip"
ditto --norsrc "$app_dir" "$output_app"
xattr -cr "$output_app"
codesign --force --deep --sign - "$output_app"
xattr -cr "$output_app"
codesign --verify --deep --strict "$output_app"
ditto -c -k --norsrc --keepParent "$output_app" "$output_zip"

echo "$output_app"
echo "$output_zip"
