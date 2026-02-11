#!/bin/bash
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

# Copy libraries
# Assuming libsciter.so is available in the project root or system path
if [ -f "libsciter.so" ]; then
    cp "libsciter.so" "$DIST_DIR/"
else
    echo "Warning: libsciter.so not found in project root."
fi

# Copy resources
cp -r resources "$DIST_DIR/"
cp resources/main.htm "$DIST_DIR/" 2>/dev/null || :

# Copy desktop file
cp dlt_explorer.desktop "$DIST_DIR/"

echo "Done! Linux distribution created in '$DIST_DIR'."
echo "To install, copy '$DIST_DIR' to /opt/$APP_NAME and link the desktop file."
