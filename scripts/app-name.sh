#!/bin/bash
# app-name.sh — single source of truth for the app's names.
#
# Source this from any script that needs to know what the bundle is called:
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   . "$SCRIPT_DIR/app-name.sh"
#
# Two names, deliberately different — do not collapse them:
#
#   APP_NAME      Internal executable / build-product name. This is the
#                 Package.swift target, the xcodebuild scheme, the
#                 Contents/MacOS binary filename, and the string that
#                 `pgrep -x` matches in VocaMacApp.ensureSingleInstance.
#                 It stays "VocaMac" so it keeps agreeing with the unchanged
#                 bundle id, the entitlements file, and the single-instance
#                 check. Renaming it breaks all three.
#
#   DISPLAY_NAME  User-visible product name — CFBundleName /
#                 CFBundleDisplayName and the .app bundle's own folder name.
#                 This is what shows up in /Applications, the Finder, and
#                 System Settings → Privacy & Security.
#
#   APP_DIR       Bundle folder name, derived: "${DISPLAY_NAME}.app".
#
# BUNDLE_ID and the Application Support directory are intentionally left on
# the old identifiers so existing installs keep their preferences, models,
# and history across the rename.

APP_NAME="VocaMac"
DISPLAY_NAME="TypeFlow"
APP_DIR="${DISPLAY_NAME}.app"
BUNDLE_ID="com.vocamac.app"
ENTITLEMENTS="VocaMac.entitlements"
