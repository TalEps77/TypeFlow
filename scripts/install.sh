#!/bin/bash
# install.sh — Build and install TypeFlow
#
# Usage:
#   ./scripts/install.sh          Build .app and install to /Applications (recommended)
#   ./scripts/install.sh --cli    Install CLI commands (vocamac, vocamac-build) to ~/.local/bin
#   ./scripts/install.sh --help   Show this help message

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# APP_NAME (executable) / DISPLAY_NAME / APP_DIR — see scripts/app-name.sh.
. "$SCRIPT_DIR/app-name.sh"

# ─── Help ───────────────────────────────────────────────────────────────────────

show_help() {
    echo "${DISPLAY_NAME} Installer"
    echo ""
    echo "Usage:"
    echo "  ./scripts/install.sh          Build and install to /Applications (recommended)"
    echo "  ./scripts/install.sh --cli    Install CLI commands to ~/.local/bin"
    echo "  ./scripts/install.sh --help   Show this help"
    echo ""
    echo "Default mode builds ${APP_DIR} and copies it to /Applications."
    echo "Permissions (Microphone, Accessibility, Input Monitoring) are granted"
    echo "directly to ${DISPLAY_NAME} — no terminal permission workarounds needed."
    echo ""
    echo "CLI mode installs 'vocamac' and 'vocamac-build' shell commands."
    echo "Note: In CLI mode, macOS permissions are granted to your terminal app"
    echo "(Terminal, iTerm2, etc.) instead of VocaMac."
}

# ─── App Install (default) ──────────────────────────────────────────────────────

install_app() {
    echo "🔨 Building ${APP_DIR}..."
    "$SCRIPT_DIR/build.sh"
    echo ""

    # Kill any running instance — matched by executable name, not display name
    pkill -f "$APP_NAME" 2>/dev/null || true
    sleep 1

    # Copy to /Applications
    echo "📦 Installing to /Applications..."
    if [ -d "/Applications/${APP_DIR}" ]; then
        rm -rf "/Applications/${APP_DIR}"
    fi
    cp -R "$PROJECT_DIR/${APP_DIR}" "/Applications/${APP_DIR}"

    # The bundle folder was renamed VocaMac.app → TypeFlow.app. A pre-rename
    # install would otherwise linger in /Applications alongside the new one.
    STALE_APP="/Applications/VocaMac.app"
    RENAMED_FROM_STALE=false
    if [ "$STALE_APP" != "/Applications/${APP_DIR}" ] && [ -d "$STALE_APP" ]; then
        echo "🧹 Removing pre-rename install at ${STALE_APP}..."
        rm -rf "$STALE_APP" 2>/dev/null && RENAMED_FROM_STALE=true \
            || echo "   ⚠️  Could not remove (try: sudo rm -rf \"$STALE_APP\")"
    fi

    echo "🚀 Launching ${DISPLAY_NAME}..."
    open "/Applications/${APP_DIR}"

    echo ""
    echo "✅ ${DISPLAY_NAME} installed to /Applications and launched!"
    echo ""
    echo "┌─────────────────────────────────────────────────────────────┐"
    echo "│  First-time setup:                                         │"
    echo "│                                                            │"
    echo "│  1. Grant Microphone permission when prompted              │"
    echo "│  2. Grant Accessibility in System Settings                 │"
    echo "│  3. Grant Input Monitoring in System Settings              │"
    echo "│  4. Restart the app after granting Input Monitoring        │"
    echo "│                                                            │"
    echo "│  Then hold Right Option (⌥) and start talking!             │"
    echo "└─────────────────────────────────────────────────────────────┘"
    if [ "$RENAMED_FROM_STALE" = true ]; then
        echo ""
        echo "⚠️  Accessibility and Input Monitoring grants are keyed to the"
        echo "   bundle's path, so the rename invalidated the old ones. In"
        echo "   System Settings → Privacy & Security, remove the stale"
        echo "   \"VocaMac\" row from BOTH Accessibility and Input Monitoring,"
        echo "   then add ${DISPLAY_NAME} and toggle it on."
    fi
    echo ""
    echo "To rebuild after code changes:  ./scripts/install.sh"
    echo "To uninstall:                   ./scripts/uninstall.sh"
}

# ─── CLI Install ────────────────────────────────────────────────────────────────

install_cli() {
    echo "🔨 Building ${DISPLAY_NAME} (release)..."
    cd "$PROJECT_DIR"
    swift build -c release

    BINARY_PATH=".build/arm64-apple-macosx/release/${APP_NAME}"

    if [ ! -f "$BINARY_PATH" ]; then
        echo "❌ Build failed — binary not found at $BINARY_PATH"
        exit 1
    fi

    echo "📦 Installing CLI commands to ~/.local/bin..."
    mkdir -p "$HOME/.local/bin"

    # Create vocamac launcher
    cat > "$HOME/.local/bin/vocamac" << LAUNCHER
#!/bin/bash
# VocaMac launcher — kills any running instance and starts fresh
killall VocaMac 2>/dev/null
sleep 0.5
"$PROJECT_DIR/$BINARY_PATH" &
echo "VocaMac started (PID: \$!)"
LAUNCHER
    chmod +x "$HOME/.local/bin/vocamac"

    # Create vocamac-build command
    cat > "$HOME/.local/bin/vocamac-build" << BUILDER
#!/bin/bash
# VocaMac rebuild — rebuilds from source
cd "$PROJECT_DIR"
killall VocaMac 2>/dev/null
swift build -c release
echo "✅ VocaMac rebuilt successfully"
BUILDER
    chmod +x "$HOME/.local/bin/vocamac-build"

    # Check PATH
    if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        echo ""
        echo "⚠️  ~/.local/bin is not in your PATH. Add it:"
        echo ""
        echo "    echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc"
        echo "    source ~/.zshrc"
        echo ""
    fi

    echo ""
    echo "✅ CLI commands installed!"
    echo ""
    echo "  vocamac          Launch VocaMac in background"
    echo "  vocamac-build    Rebuild from source"
    echo ""
    echo "⚠️  In CLI mode, grant permissions to your terminal app"
    echo "   (Terminal/iTerm2) in System Settings → Privacy & Security:"
    echo "   • Microphone"
    echo "   • Accessibility"
    echo "   • Input Monitoring"
}

# ─── Main ───────────────────────────────────────────────────────────────────────

case "${1:-}" in
    --cli)
        install_cli
        ;;
    --help|-h)
        show_help
        ;;
    *)
        install_app
        ;;
esac
