#!/bin/bash
set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH_PATH="/tmp/focusflow-preview-build"
STAGING_DIR="/tmp/focusflow-preview-staging"
STAGING_APP="$STAGING_DIR/FocusFlow.app"

RELEASES_DIR="$PROJECT_ROOT/releases"
ARTIFACT_A_APP="$RELEASES_DIR/FocusFlow.app"
ARTIFACT_B_DMG="$RELEASES_DIR/FocusFlow-Preview-macOS14-arm64.dmg"
ARTIFACT_C_DMG="$RELEASES_DIR/FocusFlow-Testing-Preview-Tasks1-8-macOS14-arm64.dmg"

TEMP_DMG="/tmp/FocusFlow_temp_packaging.dmg"
BG_IMAGE="/tmp/dmg_background.png"
VOL_NAME="FocusFlow"

echo "=== FocusFlow Unified Release Packaging Pipeline (Tasks 1-8) ==="
echo "Project Root: $PROJECT_ROOT"
mkdir -p "$RELEASES_DIR"

# 1. Compile fresh release binary from checked-out source
BUILD_COMMIT=$(git rev-parse HEAD)
echo "Building fresh release binary from commit $BUILD_COMMIT..."
swift build -c release --scratch-path "$SCRATCH_PATH"

if [ ! -f "$SCRATCH_PATH/release/FocusFlow" ]; then
    echo "Error: Release build failed, binary not found at $SCRATCH_PATH/release/FocusFlow"
    exit 1
fi
echo "Verified fresh binary built at $SCRATCH_PATH/release/FocusFlow"

# 2. Assemble ONE canonical staging application bundle directly from tracked project assets
echo "Assembling canonical staging application bundle at $STAGING_APP..."
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

# Apply verified ad-hoc code signature with entitlements
echo "Signing canonical staging application bundle..."
codesign --force --sign - --entitlements "$PROJECT_ROOT/FocusFlow.entitlements" "$STAGING_APP"
echo "Verifying application bundle signature..."
codesign --verify --deep --strict --verbose=2 "$STAGING_APP"

CANONICAL_EXEC_HASH=$(shasum -a 256 "$STAGING_APP/Contents/MacOS/FocusFlow" | awk '{print $1}')
echo "Canonical Application Executable SHA-256: $CANONICAL_EXEC_HASH"

# 3. Synchronize Artifact A: Standalone FocusFlow.app
echo "--- Synchronizing Artifact A: $ARTIFACT_A_APP ---"
if [ -d "$ARTIFACT_A_APP" ]; then
    echo "Backing up previous FocusFlow.app..."
    tar -czf "/tmp/FocusFlow_app_backup_$(date +%s).tar.gz" -C "$RELEASES_DIR" "FocusFlow.app" 2>/dev/null || true
    rm -rf "$ARTIFACT_A_APP"
fi
cp -R "$STAGING_APP" "$ARTIFACT_A_APP"
codesign --verify --deep --strict --verbose=2 "$ARTIFACT_A_APP"
A_EXEC_HASH=$(shasum -a 256 "$ARTIFACT_A_APP/Contents/MacOS/FocusFlow" | awk '{print $1}')
if [ "$A_EXEC_HASH" != "$CANONICAL_EXEC_HASH" ]; then
    echo "Error: Artifact A executable hash does not match canonical bundle!"
    exit 1
fi
echo "Artifact A verified successfully."

# 4. Generate DMG background if needed
if [ ! -f "$BG_IMAGE" ]; then
    echo "Rendering high-res background graphic..."
    swift "$PROJECT_ROOT/scripts/make_dmg_background.swift"
fi

# Function to package a DMG from the canonical staging bundle
package_dmg() {
    local target_dmg="$1"
    local dmg_label="$2"

    echo "--- Packaging $dmg_label: $target_dmg ---"

    # Backup existing DMG if present
    if [ -f "$target_dmg" ]; then
        echo "Backing up existing $(basename "$target_dmg")..."
        cp -p "$target_dmg" "/tmp/$(basename "$target_dmg")_backup_$(date +%s).dmg" 2>/dev/null || true
    fi

    # Cleanup previous mounts or temp DMGs
    rm -f "$TEMP_DMG"
    hdiutil info | grep '/Volumes/FocusFlow' | awk '{print $1}' | while read -r dev; do
        hdiutil detach "$dev" -force 2>/dev/null || true
    done
    sleep 1

    # Create temporary read-write HFS+ disk image
    hdiutil create -size 140m -fs HFS+ -volname "$VOL_NAME" "$TEMP_DMG"

    # Mount disk image
    ATTACH_INFO=$(hdiutil attach -readwrite -noverify -noautoopen "$TEMP_DMG")
    MOUNT_POINT=$(echo "$ATTACH_INFO" | grep "/Volumes/" | awk -F'\t' '{print $NF}' | sed 's/^[ \t]*//')
    DEVICE=$(echo "$ATTACH_INFO" | grep -E '^/dev/' | head -n 1 | awk '{print $1}')
    echo "Mounted on device $DEVICE at $MOUNT_POINT"

    # Copy staged FocusFlow.app into volume
    cp -R "$STAGING_APP" "$MOUNT_POINT/"

    # Symlink Applications
    ln -sfn /Applications "$MOUNT_POINT/Applications"

    # Background artwork
    mkdir -p "$MOUNT_POINT/.background"
    cp "$BG_IMAGE" "$MOUNT_POINT/.background/background.png"
    SetFile -a V "$MOUNT_POINT/.background" 2>/dev/null || true
    SetFile -a V "$MOUNT_POINT/.background/background.png" 2>/dev/null || true

    # Volume icon
    if [ -f "$PROJECT_ROOT/Assets/AppIcon.icns" ]; then
        cp "$PROJECT_ROOT/Assets/AppIcon.icns" "$MOUNT_POINT/.VolumeIcon.icns"
        SetFile -a C "$MOUNT_POINT" 2>/dev/null || true
        SetFile -a V "$MOUNT_POINT/.VolumeIcon.icns" 2>/dev/null || true
    fi

    # Finder appearance
    osascript <<APPLESCRIPT
tell application "Finder"
    open disk "$VOL_NAME"
    delay 1.5
    set theWindow to (first Finder window whose name is "$VOL_NAME")
    set current view of theWindow to icon view
    set toolbar visible of theWindow to false
    set statusbar visible of theWindow to false
    set the bounds of theWindow to {340, 160, 1000, 580}
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

    # Flush and unmount
    sync
    sleep 2
    hdiutil detach "$DEVICE" -force || diskutil eject "$DEVICE"
    sleep 2

    # Convert to compressed read-only DMG
    rm -f "$target_dmg"
    hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$target_dmg"
    rm -f "$TEMP_DMG"

    # Ad-hoc sign DMG container and verify
    codesign --force --sign - "$target_dmg"
    codesign --verify --verbose=2 "$target_dmg"
    hdiutil verify "$target_dmg"

    # Mount and verify embedded executable SHA-256
    echo "Verifying embedded executable inside $(basename "$target_dmg")..."
    VERIFY_ATTACH=$(hdiutil attach -readonly -noverify -noautoopen "$target_dmg")
    VERIFY_MOUNT=$(echo "$VERIFY_ATTACH" | grep "/Volumes/" | awk -F'\t' '{print $NF}' | sed 's/^[ \t]*//')
    VERIFY_DEV=$(echo "$VERIFY_ATTACH" | grep -E '^/dev/' | head -n 1 | awk '{print $1}')

    EMBEDDED_HASH=$(shasum -a 256 "$VERIFY_MOUNT/FocusFlow.app/Contents/MacOS/FocusFlow" | awk '{print $1}')
    hdiutil detach "$VERIFY_DEV" -force >/dev/null 2>&1 || true

    if [ "$EMBEDDED_HASH" != "$CANONICAL_EXEC_HASH" ]; then
        echo "Error: Embedded executable in $(basename "$target_dmg") does not match canonical hash!"
        exit 1
    fi
    echo "Verified $(basename "$target_dmg") embedded executable matches canonical hash."
}

# 5. Build Artifact B: FocusFlow-Preview-macOS14-arm64.dmg
package_dmg "$ARTIFACT_B_DMG" "Artifact B (Preview DMG)"

# 6. Build Artifact C: FocusFlow-Testing-Preview-Tasks1-8-macOS14-arm64.dmg
package_dmg "$ARTIFACT_C_DMG" "Artifact C (Testing Preview Tasks 1-8 DMG)"

echo ""
echo "================================================================="
echo "=== ALL THREE RELEASE ARTIFACTS VERIFIED AND SYNCHRONIZED ==="
echo "================================================================="
echo "Source Commit: $BUILD_COMMIT"
echo "Canonical Executable SHA-256: $CANONICAL_EXEC_HASH"
echo ""
echo "Artifact A (Standalone App):"
echo "  Path: $ARTIFACT_A_APP"
echo "  Executable SHA-256: $A_EXEC_HASH"
echo ""
echo "Artifact B (Preview DMG):"
echo "  Path: $ARTIFACT_B_DMG"
echo "  DMG SHA-256: $(shasum -a 256 "$ARTIFACT_B_DMG" | awk '{print $1}')"
echo "  Size: $(stat -f%z "$ARTIFACT_B_DMG") bytes"
echo ""
echo "Artifact C (Testing Preview Tasks 1-8 DMG):"
echo "  Path: $ARTIFACT_C_DMG"
echo "  DMG SHA-256: $(shasum -a 256 "$ARTIFACT_C_DMG" | awk '{print $1}')"
echo "  Size: $(stat -f%z "$ARTIFACT_C_DMG") bytes"
echo "================================================================="
