#!/bin/bash
set -e

# Delegate to unified single-source packaging pipeline
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/package_preview_dmg.sh" "$@"
