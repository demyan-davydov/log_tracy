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

# The desktop entry: what puts the app with its icon in the menu of applications
INSTALL_DIR="/opt/$APP_NAME"
cat > "$DIST_DIR/$APP_NAME.desktop" <<EOF
[Desktop Entry]
Name=DLT Explorer
Comment=DLT file viewer and analyzer
Exec=$INSTALL_DIR/$APP_NAME
Icon=$INSTALL_DIR/app.png
Terminal=false
Type=Application
Categories=Development;Utility;
EOF

echo "Done! Linux distribution created in '$DIST_DIR'."
echo "To install, copy '$DIST_DIR' to $INSTALL_DIR and link $APP_NAME.desktop."
