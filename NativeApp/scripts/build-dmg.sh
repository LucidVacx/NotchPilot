#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
zsh "$project_dir/scripts/build-app.sh"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/Resources/Info.plist")"
output_dir="$project_dir/outputs"
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/notchpilot-dmg.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT

ditto -x -k "$output_dir/NotchPilot-beta.zip" "$stage_dir"
xattr -cr "$stage_dir/NotchPilot.app"
codesign --verify --deep --strict "$stage_dir/NotchPilot.app"
ln -s /Applications "$stage_dir/Applications"
cat > "$stage_dir/READ ME.txt" <<READ_ME
NotchPilot $version

Drag NotchPilot.app onto Applications.
Quit your old copy first; choose Replace when updating.
Launch NotchPilot from Applications, then eject this disk image.

Requires macOS 15+, Apple silicon and an installed Hermes CLI.
Use Option-Space or pull down at the notch to open the terminal.
On external displays, point at the small top-center notch and scroll
down to open or up to close. Hiding keeps the terminal session alive;
quitting NotchPilot closes it.

This beta is ad-hoc signed, not Apple-notarized. macOS may require
approval in Privacy & Security before first launch.

NotchPilot is available under the MIT license.
See Contents/Resources/LICENSE for the full license.
SwiftTerm is included under the MIT license; see the app's
Contents/Resources/ThirdParty directory for its full license.

Downloads and support: https://github.com/LucidVacx/NotchPilot
READ_ME

artifact="NotchPilot-$version-macOS-arm64.dmg"
hdiutil create -volname "NotchPilot $version" -srcfolder "$stage_dir" -format UDZO -ov "$output_dir/$artifact"
(cd "$output_dir" && shasum -a 256 "$artifact" > SHA256SUMS.txt)
echo "$output_dir/$artifact"
