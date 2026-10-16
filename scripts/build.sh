#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
# Use the installed command line tools without accepting or changing an Xcode license.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
compiler="$(xcrun --find swiftc)"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
if [[ -x /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc ]]; then
  compiler=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
  sdk=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
fi
mkdir -p build "$HOME/Library/Developer/HoriStudy/Builds"
output_dir="$(mktemp -d "$HOME/Library/Developer/HoriStudy/Builds/release.XXXXXX")"
app="$output_dir/HoriStudy.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
sources=(Core/*.swift App/*.swift)
architectures=("$(uname -m)")
if [[ "${1:-}" == "--universal" ]]; then architectures=(arm64 x86_64); fi
for arch in "${architectures[@]}"; do
  "$compiler" -O -swift-version 5 -parse-as-library -sdk "$sdk" -target "$arch-apple-macosx14.0" \
    "${sources[@]}" -o "$output_dir/HoriStudy-$arch"
done
if (( ${#architectures[@]} > 1 )); then
  xcrun lipo -create "$output_dir/HoriStudy-arm64" "$output_dir/HoriStudy-x86_64" -output "$app/Contents/MacOS/HoriStudy"
else
  /bin/cp -X "$output_dir/HoriStudy-${architectures[1]}" "$app/Contents/MacOS/HoriStudy"
fi
/bin/cp -X Config/Info.plist "$app/Contents/Info.plist"
/bin/cp -X Resources/chaoxing-adapter.js "$app/Contents/Resources/"
if [[ -f Resources/AppIcon.icns ]]; then /bin/cp -X Resources/AppIcon.icns "$app/Contents/Resources/"; fi
/usr/bin/codesign --force --sign - --options runtime "$app"
/usr/bin/codesign --verify --deep --strict "$app"
if [[ -L build/HoriStudy.app ]]; then /bin/rm build/HoriStudy.app; fi
if [[ -e build/HoriStudy.app ]]; then /bin/mv build/HoriStudy.app "$output_dir/previous-output.app"; fi
/bin/ln -s "$app" build/HoriStudy.app
print "Built: $PWD/build/HoriStudy.app"
