#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
source_app="$project_root/build-release-stable/Build/Products/Release/Notchly.app"
stable_app="$project_root/dist/Notchly.app"
version="${NOTCHLY_VERSION:-0.13.12}"
zip_archive="$project_root/dist/Notchly-${version}-alpha-universal.zip"
dmg_archive="$project_root/dist/Notchly-${version}-alpha-universal.dmg"
signing_identity="${NOTCHLY_SIGNING_IDENTITY:--}"

cd "$project_root"
xcodegen generate
xcodebuild \
  -project Notchly.xcodeproj \
  -scheme Notchly \
  -configuration Release \
  -derivedDataPath build-release-stable \
  build CODE_SIGNING_ALLOWED=NO

mkdir -p "$project_root/dist"
rm -rf "$stable_app"
ditto "$source_app" "$stable_app"

if [[ "$signing_identity" == "-" ]]; then
  codesign --force --deep --sign - \
    --identifier com.notchly.app \
    "$stable_app"
else
  codesign --force --deep --sign "$signing_identity" "$stable_app"
fi

rm -f "$zip_archive" "$dmg_archive"
ditto -c -k --sequesterRsrc --keepParent "$stable_app" "$zip_archive"

dmg_staging="$(mktemp -d "$project_root/dist/Notchly-dmg.XXXXXX")"
trap 'rm -rf "$dmg_staging"' EXIT
ditto "$stable_app" "$dmg_staging/Notchly.app"
ln -s /Applications "$dmg_staging/Applications"
hdiutil create \
  -volname "Notchly" \
  -srcfolder "$dmg_staging" \
  -format UDZO \
  -ov \
  "$dmg_archive"

codesign --verify --deep --strict "$stable_app"
unzip -t "$zip_archive"
hdiutil verify "$dmg_archive"
shasum -a 256 "$zip_archive" "$dmg_archive"

echo "Packaged: $stable_app"
echo "ZIP:       $zip_archive"
echo "DMG:       $dmg_archive"
