#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
mkdir -p build test-results
compiler="$(xcrun --find swiftc)"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
if [[ -x /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc ]]; then
  compiler=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
  sdk=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
fi
"$compiler" -swift-version 5 -parse-as-library -sdk "$sdk" -target "$(uname -m)-apple-macosx14.0" \
  Core/*.swift Tests/*.swift -o build/HoriStudyChecks
build/HoriStudyChecks 2>&1 | tee test-results/local-checks.txt
