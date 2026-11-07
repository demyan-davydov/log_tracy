#!/bin/bash
cd "$(dirname "$0")/.." || exit 1 # the project root
APP_NAME="dlt_explorer"
DIST_DIR="dist_linux"

echo "Building $APP_NAME for Linux..."
dub build --build=release

if [ $? -ne 0 ]; then
    echo "Build failed!"
    exit 1
fi

echo "Creating distribution directory..."
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# Copy binary
cp "$APP_NAME" "$DIST_DIR/"
chmod +x "$DIST_DIR/$APP_NAME"

# Copy the Sciter library of this machine's architecture
case "$(uname -m)" in
    x86_64) LIB_ARCH=x64 ;;
    aarch64 | arm64) LIB_ARCH=arm64 ;;
    *) echo "No Sciter library for $(uname -m) in libs/linux."; exit 1 ;;
esac
cp "libs/linux/$LIB_ARCH/libsciter.so" "$DIST_DIR/" || exit 1

# The icon (the files of the interface are built into the binary)
cp resources/app.png "$DIST_DIR/"

# Copy desktop file
cp dlt_explorer.desktop "$DIST_DIR/"

echo "Done! Linux distribution created in '$DIST_DIR'."
echo "To install, copy '$DIST_DIR' to /opt/$APP_NAME and link the desktop file."
