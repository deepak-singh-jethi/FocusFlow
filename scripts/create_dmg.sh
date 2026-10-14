#!/bin/bash
set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$PROJECT_ROOT/releases/FocusFlow.app"
DMG_OUTPUT="$PROJECT_ROOT/releases/FocusFlow-Preview-macOS14-arm64.dmg"
TEMP_DMG="/tmp/FocusFlow_temp.dmg"
BG_IMAGE="/tmp/dmg_background.png"
VOL_NAME="FocusFlow"

echo "=== Building Professional macOS DMG for FocusFlow ==="

# 1. Generate DMG background if needed
if [ ! -f "$BG_IMAGE" ]; then
    echo "Rendering high-res background graphic..."
    swift "$PROJECT_ROOT/scratch/make_dmg_background.swift"
fi

# 2. Cleanup previous runs
rm -f "$TEMP_DMG" "$DMG_OUTPUT"
hdiutil info | grep '/Volumes/FocusFlow' | awk '{print $1}' | while read -r dev; do
    hdiutil detach "$dev" -force 2>/dev/null || true
done
sleep 1

# 3. Create temporary read-write HFS+ disk image
echo "Creating temporary disk image..."
hdiutil create -size 140m -fs HFS+ -volname "$VOL_NAME" "$TEMP_DMG"

# 4. Mount the temporary disk image
echo "Mounting disk image in read-write mode..."
ATTACH_INFO=$(hdiutil attach -readwrite -noverify -noautoopen "$TEMP_DMG")
MOUNT_POINT=$(echo "$ATTACH_INFO" | grep "/Volumes/" | awk -F'\t' '{print $NF}' | sed 's/^[ \t]*//')
DEVICE=$(echo "$ATTACH_INFO" | grep -E '^/dev/' | head -n 1 | awk '{print $1}')

echo "Mounted on device $DEVICE at $MOUNT_POINT"

# 5. Populate volume contents
echo "Copying FocusFlow.app into volume..."
cp -R "$APP_PATH" "$MOUNT_POINT/"

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

# 6. Configure Finder window view options & icon layout via AppleScript
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

# 7. Flush and unmount
echo "Flushing and unmounting..."
sync
sleep 2
hdiutil detach "$DEVICE" -force || diskutil eject "$DEVICE"
sleep 2

# 8. Convert to compressed read-only DMG
echo "Compressing into final release DMG..."
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_OUTPUT"
rm -f "$TEMP_DMG"

# 9. Verify DMG
echo "Verifying DMG integrity..."
hdiutil verify "$DMG_OUTPUT"

echo "=== Successfully built $DMG_OUTPUT ==="
