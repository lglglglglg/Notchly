#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
source_app="$project_root/build-release-stable/Build/Products/Release/Notchly.app"
stable_app="$project_root/dist/Notchly.app"
version="${NOTCHLY_VERSION:-0.13.9}"
versioned_archive="$project_root/dist/Notchly-${version}-alpha.zip"
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

rm -f "$versioned_archive"
ditto -c -k --sequesterRsrc --keepParent "$stable_app" "$versioned_archive"
codesign --verify --deep --strict "$stable_app"
shasum -a 256 "$versioned_archive"

echo "Packaged: $stable_app"
echo "Archive:  $versioned_archive"
