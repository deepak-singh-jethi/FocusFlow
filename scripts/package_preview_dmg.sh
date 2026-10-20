#!/bin/bash
set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH_PATH="/tmp/focusflow-preview-build"
STAGING_DIR="/tmp/focusflow-preview-staging"
STAGING_APP="$STAGING_DIR/FocusFlow.app"

RELEASES_DIR="$PROJECT_ROOT/releases"
ARTIFACT_APP="$RELEASES_DIR/FocusFlow.app"
ARTIFACT_DMG="$RELEASES_DIR/FocusFlow-Testing-Preview-Tasks1-8-macOS14-arm64.dmg"
OBSOLETE_DMG="$RELEASES_DIR/FocusFlow-Preview-macOS14-arm64.dmg"

BACKUPS_ROOT="$PROJECT_ROOT/../FocusFlow_backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="${FOCUSFLOW_BACKUP_DIR:-$BACKUPS_ROOT/FocusFlow_releases_backup_$TIMESTAMP}"

TEMP_RW_DMG="/tmp/FocusFlow_temp_packaging_$TIMESTAMP.dmg"
CANDIDATE_DMG="/tmp/FocusFlow_candidate_$TIMESTAMP.dmg"
BG_IMAGE="/tmp/dmg_background.png"
VOL_NAME="FocusFlow"

echo "=== FocusFlow Release Packaging Pipeline (Single DMG & Standalone App) ==="
echo "Project Root: $PROJECT_ROOT"
mkdir -p "$RELEASES_DIR"

# 0. Always preserve a safe rollback backup of existing DMG before packaging
PREV_DMG_BACKUP="/tmp/FocusFlow_previous_backup_$TIMESTAMP.dmg"
if [ -f "$ARTIFACT_DMG" ]; then
    echo "--- Preserving safety rollback backup of existing DMG at $PREV_DMG_BACKUP ---"
    cp -p "$ARTIFACT_DMG" "$PREV_DMG_BACKUP"
fi

if [ "${FOCUSFLOW_ENABLE_BACKUP:-false}" = "true" ]; then
    mkdir -p "$BACKUP_DIR"
    echo "--- Backing up existing releases to: $BACKUP_DIR ---"
    if [ -d "$ARTIFACT_APP" ]; then
        echo "Backing up FocusFlow.app..."
        cp -R "$ARTIFACT_APP" "$BACKUP_DIR/FocusFlow.app"
    fi
    for dmg in "$RELEASES_DIR"/*.dmg; do
        if [ -f "$dmg" ]; then
            echo "Backing up $(basename "$dmg")..."
            cp -p "$dmg" "$BACKUP_DIR/$(basename "$dmg")"
        fi
    done
fi

# 1. Compile fresh release binary from current working tree
BUILD_COMMIT=$(git rev-parse HEAD)
GIT_DIRTY=$(git status --porcelain)
echo "Building fresh release binary from commit $BUILD_COMMIT..."
if [ -n "$GIT_DIRTY" ]; then
    echo "Note: Working tree contains uncommitted source changes which are included in this build."
fi

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

# Clean any extended attributes on staging app
xattr -cr "$STAGING_APP" 2>/dev/null || true

# Apply verified ad-hoc code signature with entitlements
echo "Signing canonical staging application bundle..."
codesign --force --sign - --entitlements "$PROJECT_ROOT/FocusFlow.entitlements" "$STAGING_APP"
echo "Verifying application bundle signature..."
codesign --verify --deep --strict --verbose=2 "$STAGING_APP"

CANONICAL_EXEC_HASH=$(shasum -a 256 "$STAGING_APP/Contents/MacOS/FocusFlow" | awk '{print $1}')
echo "Canonical Application Executable SHA-256: $CANONICAL_EXEC_HASH"

# 3. Generate DMG background if needed
if [ ! -f "$BG_IMAGE" ]; then
    echo "Rendering high-res background graphic..."
    swift "$PROJECT_ROOT/scripts/make_dmg_background.swift"
fi

# 4. Package single Testing Preview DMG at candidate location
echo "--- Packaging Single Testing Preview DMG: $ARTIFACT_DMG ---"

# Clean up any lingering temporary mount of FocusFlow
if mount | grep -q "/Volumes/$VOL_NAME"; then
    echo "Cleaning up lingering $VOL_NAME mount point..."
    diskutil eject "/Volumes/$VOL_NAME" 2>/dev/null || hdiutil detach "/Volumes/$VOL_NAME" -force 2>/dev/null || true
    sleep 1
fi
rm -f "$TEMP_RW_DMG" "$CANDIDATE_DMG"

# Create temporary read-write HFS+ disk image
hdiutil create -size 140m -fs HFS+ -volname "$VOL_NAME" "$TEMP_RW_DMG"

# Mount disk image
ATTACH_INFO=$(hdiutil attach -readwrite -noverify -noautoopen "$TEMP_RW_DMG")
MOUNT_POINT=$(echo "$ATTACH_INFO" | grep "/Volumes/" | awk -F'\t' '{print $NF}' | sed 's/^[ \t]*//')
DEVICE=$(echo "$ATTACH_INFO" | grep -E '^/dev/' | head -n 1 | awk '{print $1}')
echo "Mounted candidate volume on device $DEVICE at $MOUNT_POINT"

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
diskutil eject "$DEVICE" 2>/dev/null || hdiutil detach "$DEVICE" -force 2>/dev/null || true
sleep 2

# Convert to compressed read-only candidate DMG
hdiutil convert "$TEMP_RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$CANDIDATE_DMG"
rm -f "$TEMP_RW_DMG"

# Ad-hoc sign candidate DMG container and verify
codesign --force --sign - "$CANDIDATE_DMG"
codesign --verify --verbose=2 "$CANDIDATE_DMG"
hdiutil verify "$CANDIDATE_DMG"

# Mount and verify embedded executable SHA-256 matches canonical staging bundle
echo "Verifying embedded executable inside candidate DMG..."
VERIFY_ATTACH=$(hdiutil attach -readonly -noverify -noautoopen "$CANDIDATE_DMG")
VERIFY_MOUNT=$(echo "$VERIFY_ATTACH" | grep "/Volumes/" | awk -F'\t' '{print $NF}' | sed 's/^[ \t]*//')
VERIFY_DEV=$(echo "$VERIFY_ATTACH" | grep -E '^/dev/' | head -n 1 | awk '{print $1}')

EMBEDDED_HASH=$(shasum -a 256 "$VERIFY_MOUNT/FocusFlow.app/Contents/MacOS/FocusFlow" | awk '{print $1}')
diskutil eject "$VERIFY_DEV" 2>/dev/null || hdiutil detach "$VERIFY_DEV" -force >/dev/null 2>&1 || true

if [ "$EMBEDDED_HASH" != "$CANONICAL_EXEC_HASH" ]; then
    echo "Error: Candidate DMG embedded executable hash ($EMBEDDED_HASH) does not match canonical ($CANONICAL_EXEC_HASH)!"
    rm -f "$CANDIDATE_DMG"
    exit 1
fi
echo "Candidate DMG verified successfully with matching embedded hash."

# 5. Safely install validated artifacts into releases/
echo "--- Installing validated candidate DMG to $ARTIFACT_DMG ---"
mv -f "$CANDIDATE_DMG" "$ARTIFACT_DMG"

# Retire legacy Preview DMG to backup directory if present in releases
if [ -f "$OBSOLETE_DMG" ]; then
    echo "Moving obsolete legacy Preview DMG to backup: $BACKUP_DIR/$(basename "$OBSOLETE_DMG")"
    mv -f "$OBSOLETE_DMG" "$BACKUP_DIR/$(basename "$OBSOLETE_DMG")"
fi

# 6. Synchronize Standalone FocusFlow.app
echo "--- Synchronizing Standalone App: $ARTIFACT_APP ---"
rm -rf "$ARTIFACT_APP"
ditto "$STAGING_APP" "$ARTIFACT_APP"
xattr -cr "$ARTIFACT_APP" 2>/dev/null || true
codesign --verify --verbose=2 "$ARTIFACT_APP"

APP_EXEC_HASH=$(shasum -a 256 "$ARTIFACT_APP/Contents/MacOS/FocusFlow" | awk '{print $1}')
if [ "$APP_EXEC_HASH" != "$CANONICAL_EXEC_HASH" ]; then
    echo "Error: Standalone FocusFlow.app executable hash ($APP_EXEC_HASH) does not match canonical ($CANONICAL_EXEC_HASH)!"
    exit 1
fi

# 7. Inventory Verification: confirm exactly ONE DMG exists in releases/
DMG_COUNT=$(ls -1 "$RELEASES_DIR"/*.dmg 2>/dev/null | wc -l | tr -d ' ')
if [ "$DMG_COUNT" -ne 1 ]; then
    echo "Error: releases/ directory must contain exactly ONE DMG, but found $DMG_COUNT!"
    ls -la "$RELEASES_DIR"
    exit 1
fi

echo ""
echo "================================================================="
echo "=== RELEASE ARTIFACTS VERIFIED AND CONSOLIDATED (ONE DMG) ==="
echo "================================================================="
echo "Source Commit: $BUILD_COMMIT"
echo "Canonical Executable SHA-256: $CANONICAL_EXEC_HASH"
echo ""
echo "Standalone Application:"
echo "  Path: $ARTIFACT_APP"
echo "  Executable SHA-256: $APP_EXEC_HASH"
echo ""
echo "Single Testing Preview DMG:"
echo "  Path: $ARTIFACT_DMG"
echo "  DMG SHA-256: $(shasum -a 256 "$ARTIFACT_DMG" | awk '{print $1}')"
echo "  Size: $(stat -f%z "$ARTIFACT_DMG") bytes"
echo "  Embedded Executable SHA-256: $EMBEDDED_HASH"
echo ""
echo "Durable Backup Location:"
echo "  Directory: $BACKUP_DIR"
echo "  Backed Up Artifacts: $(ls -m "$BACKUP_DIR")"
echo "================================================================="
