#!/bin/bash
# Builds Beamstage 7.app (universal: Apple silicon + Intel) with Syphon embedded.
# Needs only the Xcode Command Line Tools: xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Beamstage 7.app"
VERSION="7.0.0"
ARCHS="${ARCHS:-arm64 x86_64}"
MIN_OS="12.0"

rm -rf build/obj "$APP"
mkdir -p build/obj "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"

BINS=()
for arch in $ARCHS; do
  echo "Compiling ${arch}…"
  swiftc -O -whole-module-optimization \
    -target "$arch-apple-macos$MIN_OS" \
    -F vendor -framework Syphon \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -module-name Beamstage \
    -o "build/obj/Beamstage-$arch" \
    Sources/*.swift
  BINS+=("build/obj/Beamstage-$arch")
done
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/Beamstage"

cp -R vendor/Syphon.framework "$APP/Contents/Frameworks/"
cp vendor/Syphon-License.txt "$APP/Contents/Resources/"
cp resources/AppIcon.icns resources/remote.html "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Beamstage 7</string>
  <key>CFBundleDisplayName</key><string>Beamstage 7</string>
  <key>CFBundleIdentifier</key><string>app.beamstage.mapper7</string>
  <key>CFBundleExecutable</key><string>Beamstage</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Beamstage connects to your LaserCube over the local network.</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key><false/>
  <key>NSHumanReadableCopyright</key><string>Syphon is included under its BSD licence.</string>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>app.beamstage.project</string>
      <key>UTTypeDescription</key><string>Beamstage Project</string>
      <key>UTTypeConformsTo</key><array><string>public.json</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>beamstage</string></array></dict>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Beamstage Project</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSItemContentTypes</key><array><string>app.beamstage.project</string></array>
      <key>LSHandlerRank</key><string>Owner</string>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Media</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key><array><string>public.movie</string><string>com.compuserve.gif</string><string>public.image</string></array>
      <key>LSHandlerRank</key><string>Alternate</string>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo "Signing (ad hoc)…"
codesign --force --sign - "$APP/Contents/Frameworks/Syphon.framework"
codesign --force --sign - "$APP"
xattr -cr "$APP" 2>/dev/null || true

echo "Checking…"
"$APP/Contents/MacOS/Beamstage" --check

if [ "${ZIP:-1}" = "1" ]; then
  (cd build && rm -f "Beamstage-7-mac.zip" && ditto -c -k --keepParent "Beamstage 7.app" "Beamstage-7-mac.zip")
  echo "Built $APP and build/Beamstage-7-mac.zip"
else
  echo "Built $APP"
fi
