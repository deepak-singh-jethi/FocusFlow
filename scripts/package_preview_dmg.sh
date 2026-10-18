#!/bin/bash
set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH_PATH="/tmp/focusflow-preview-build"
STAGING_DIR="/tmp/focusflow-preview-staging"
STAGING_APP="$STAGING_DIR/FocusFlow.app"
DMG_OUTPUT="$PROJECT_ROOT/releases/FocusFlow-Testing-Preview-Tasks1-8-macOS14-arm64.dmg"
TEMP_DMG="/tmp/FocusFlow_Preview_temp.dmg"
BG_IMAGE="/tmp/dmg_background.png"
VOL_NAME="FocusFlow"

echo "=== Building Testing Preview macOS DMG for FocusFlow (Tasks 1-8) ==="

# 1. Always perform a fresh release build from checked-out source
BUILD_COMMIT=$(git rev-parse HEAD)
echo "Building fresh release binary from commit $BUILD_COMMIT..."
swift build -c release --scratch-path "$SCRATCH_PATH"

if [ ! -f "$SCRATCH_PATH/release/FocusFlow" ]; then
    echo "Error: Release build failed, binary not found at $SCRATCH_PATH/release/FocusFlow"
    exit 1
fi
echo "Verified fresh binary built at $SCRATCH_PATH/release/FocusFlow from commit $BUILD_COMMIT"

# 2. Assemble fresh staging application bundle directly from tracked project assets
echo "Assembling fresh staging application bundle at $STAGING_APP..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_APP/Contents/MacOS"
mkdir -p "$STAGING_APP/Contents/Resources/Soundscapes"

# Copy binary and set executable permissions
cp "$SCRATCH_PATH/release/FocusFlow" "$STAGING_APP/Contents/MacOS/FocusFlow"
chmod 755 "$STAGING_APP/Contents/MacOS/FocusFlow"

# Verify binary architecture
file "$STAGING_APP/Contents/MacOS/FocusFlow" | grep -q "arm64" || {
    echo "Error: Staged executable is not arm64 compatible!"
    exit 1
}

# Copy metadata from tracked Assets/Info.plist and lint
cp "$PROJECT_ROOT/Assets/Info.plist" "$STAGING_APP/Contents/Info.plist"
plutil -lint "$STAGING_APP/Contents/Info.plist"

# Copy app resources
cp "$PROJECT_ROOT/Assets/AppIcon.icns" "$STAGING_APP/Contents/Resources/AppIcon.icns"
cp "$PROJECT_ROOT/Assets/Soundscapes/Rain.mp3" "$STAGING_APP/Contents/Resources/Soundscapes/Rain.mp3"
cp "$PROJECT_ROOT/Assets/Soundscapes/Ocean.mp3" "$STAGING_APP/Contents/Resources/Soundscapes/Ocean.mp3"
cp "$PROJECT_ROOT/Assets/Soundscapes/Forest.mp3" "$STAGING_APP/Contents/Resources/Soundscapes/Forest.mp3"

# Verify all soundscapes are non-empty
for f in "$STAGING_APP/Contents/Resources/Soundscapes/"*.mp3; do
    if [ ! -s "$f" ]; then
        echo "Error: Soundscape file $f is missing or empty!"
        exit 1
    fi
done

# 3. Apply verified ad-hoc code signature with entitlements
echo "Signing staging application bundle..."
codesign --force --sign - --entitlements "$PROJECT_ROOT/FocusFlow.entitlements" "$STAGING_APP"
echo "Verifying application bundle signature..."
codesign --verify --deep --strict --verbose=2 "$STAGING_APP"

# 4. Generate DMG background if needed
if [ ! -f "$BG_IMAGE" ]; then
    echo "Rendering high-res background graphic..."
    swift "$PROJECT_ROOT/scripts/make_dmg_background.swift"
fi

# 5. Cleanup previous mounts or temp DMGs
rm -f "$TEMP_DMG"
hdiutil info | grep '/Volumes/FocusFlow' | awk '{print $1}' | while read -r dev; do
    hdiutil detach "$dev" -force 2>/dev/null || true
done
sleep 1

# 6. Create temporary read-write HFS+ disk image
echo "Creating temporary disk image..."
hdiutil create -size 140m -fs HFS+ -volname "$VOL_NAME" "$TEMP_DMG"

# 7. Mount the temporary disk image
echo "Mounting disk image in read-write mode..."
ATTACH_INFO=$(hdiutil attach -readwrite -noverify -noautoopen "$TEMP_DMG")
MOUNT_POINT=$(echo "$ATTACH_INFO" | grep "/Volumes/" | awk -F'\t' '{print $NF}' | sed 's/^[ \t]*//')
DEVICE=$(echo "$ATTACH_INFO" | grep -E '^/dev/' | head -n 1 | awk '{print $1}')

echo "Mounted on device $DEVICE at $MOUNT_POINT"

# 8. Populate volume contents from freshly staged app bundle
echo "Copying staged FocusFlow.app into volume..."
cp -R "$STAGING_APP" "$MOUNT_POINT/"

echo "Creating Applications symlink..."
ln -sfn /Applications "$MOUNT_POINT/Applications"

echo "Installing background artwork..."
mkdir -p "$MOUNT_POINT/.background"
cp "$BG_IMAGE" "$MOUNT_POINT/.background/background.png"

# Hide internal files
SetFile -a V "$MOUNT_POINT/.background" 2>/dev/null || true
SetFile -a V "$MOUNT_POINT/.background/background.png" 2>/dev/null || true

echo "Applying custom volume icon..."
if [ -f "$PROJECT_ROOT/Assets/AppIcon.icns" ]; then
    cp "$PROJECT_ROOT/Assets/AppIcon.icns" "$MOUNT_POINT/.VolumeIcon.icns"
    SetFile -a C "$MOUNT_POINT" 2>/dev/null || true
    SetFile -a V "$MOUNT_POINT/.VolumeIcon.icns" 2>/dev/null || true
fi

# 9. Configure Finder window view options & icon layout via AppleScript
echo "Configuring Finder window geometry and layout..."
osascript <<APPLESCRIPT
tell application "Finder"
    open disk "$VOL_NAME"
    delay 1.5
    set theWindow to (first Finder window whose name is "$VOL_NAME")
    set current view of theWindow to icon view
    set toolbar visible of theWindow to false
    set statusbar visible of theWindow to false
    set the bounds of theWindow to {340, 160, 1000, 580} -- 660x420
    set theViewOptions to icon view options of theWindow
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 128
    set text size of theViewOptions to 12
    set label position of theViewOptions to bottom
    set bgFile to file "background.png" of folder ".background" of disk "$VOL_NAME"
    set background picture of theViewOptions to bgFile
    set position of item "FocusFlow.app" of theWindow to {170, 210}
    set position of item "Applications" of theWindow to {490, 210}
    delay 1.5
    update disk "$VOL_NAME"
    delay 1
    close theWindow
end tell
APPLESCRIPT

# 10. Flush and unmount
echo "Flushing and unmounting..."
sync
sleep 2
hdiutil detach "$DEVICE" -force || diskutil eject "$DEVICE"
sleep 2

# 11. Convert to compressed read-only DMG
echo "Compressing into final release DMG..."
mkdir -p "$PROJECT_ROOT/releases"
rm -f "$DMG_OUTPUT"
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_OUTPUT"
rm -f "$TEMP_DMG"

# 12. Code-sign the DMG container (ad-hoc) and verify
echo "Signing DMG container with ad-hoc signature..."
codesign --force --sign - "$DMG_OUTPUT"
echo "Verifying DMG container signature..."
codesign --verify --verbose=2 "$DMG_OUTPUT"

# 13. Verify DMG integrity
echo "Verifying DMG integrity..."
hdiutil verify "$DMG_OUTPUT"

echo "=== Successfully built $DMG_OUTPUT from commit $BUILD_COMMIT ==="
