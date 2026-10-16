#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
[[ -d build/HoriStudy.app ]] || { print -u2 'Build the app first.'; exit 1; }
mkdir -p dist
app="${PWD}/build/HoriStudy.app"
/usr/bin/codesign --verify --deep --strict "$app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" dist/HoriStudy-macOS.zip
stage="$(mktemp -d /tmp/horistudy-dmg.XXXXXX)"
/usr/bin/ditto "$app" "$stage/HoriStudy.app"
/bin/ln -s /Applications "$stage/Applications"
/bin/cp README.md LICENSE "$stage/"
/usr/bin/hdiutil create -volname HoriStudy -srcfolder "$stage" -format UDZO -ov dist/HoriStudy-macOS.dmg
/usr/bin/hdiutil verify dist/HoriStudy-macOS.dmg
cd dist
/usr/bin/shasum -a 256 HoriStudy-macOS.zip HoriStudy-macOS.dmg > SHA256SUMS.txt
/usr/bin/unzip -tq HoriStudy-macOS.zip
