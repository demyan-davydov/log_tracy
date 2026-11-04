#!/bin/bash
cd "$(dirname "$0")/.." || exit 1 # the project root
APP_NAME="DltExplorer"
BUNDLE_NAME="$APP_NAME.app"

echo "Building $APP_NAME..."
dub build --build=release

if [ $? -ne 0 ]; then
    echo "Build failed!"
    exit 1
fi

echo "Creating bundle structure..."
rm -rf "$BUNDLE_NAME"
mkdir -p "$BUNDLE_NAME/Contents/MacOS"
mkdir -p "$BUNDLE_NAME/Contents/Resources"

# Copy binary
cp dlt_explorer "$BUNDLE_NAME/Contents/MacOS/$APP_NAME"
chmod +x "$BUNDLE_NAME/Contents/MacOS/$APP_NAME"

# Copy resources
cp -r resources/* "$BUNDLE_NAME/Contents/Resources/"
cp resources/main.htm "$BUNDLE_NAME/Contents/Resources/" 2>/dev/null || :

# Copy dylibs
cp *.dylib "$BUNDLE_NAME/Contents/MacOS/"

# Clear quarantine attributes
xattr -cr "$BUNDLE_NAME"

# Create Info.plist
cat > "$BUNDLE_NAME/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>app.icns</string>
    <key>CFBundleIdentifier</key>
    <string>com.demiandavidov.dltexplorer</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "Done! $BUNDLE_NAME created."
echo "Note: Ensure 'resources/app.icns' exists for the icon to appear."
