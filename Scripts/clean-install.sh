#!/bin/bash
# Removes all Console app data for a clean install.
# Run this AFTER quitting the app.

set -euo pipefail

BUNDLE_ID="com.deadratgames.console"
KEYCHAIN_SERVICE="com.openclaw.console"
LEGACY_KEYCHAIN_SERVICE="$BUNDLE_ID"

# Ensure the app is not running
if pgrep -xq "Console"; then
    echo "Error: Console is still running. Quit the app first."
    exit 1
fi

echo "=== Console Clean Install ==="
echo ""

# 1. TCC permissions
echo "[1/5] Resetting TCC permissions..."
for service in Microphone Accessibility AppleEvents SpeechRecognition; do
    if tccutil reset "$service" "$BUNDLE_ID" 2>&1; then
        echo "  ✓ $service reset"
    else
        echo "  ✗ $service per-app reset failed, trying full reset..."
        tccutil reset "$service" 2>&1 || echo "  ✗ $service full reset also failed — remove manually in System Settings > Privacy & Security"
    fi
done

# 2. SwiftData store
echo "[2/5] Removing SwiftData store..."
rm -f ~/Library/Application\ Support/default.store
rm -f ~/Library/Application\ Support/default.store-shm
rm -f ~/Library/Application\ Support/default.store-wal

# 3. App logs
echo "[3/5] Removing app logs..."
rm -rf ~/Library/Application\ Support/Console

# 4. UserDefaults (delete plist + flush cfprefsd cache)
echo "[4/5] Removing UserDefaults..."
defaults delete "$BUNDLE_ID" 2>/dev/null || true
rm -f ~/Library/Preferences/"${BUNDLE_ID}.plist"
killall cfprefsd 2>/dev/null || true
sleep 0.5

# 5. Keychain items
echo "[5/5] Removing Keychain items..."
KEYCHAIN_ACCOUNTS=(
    "lemon-squeezy-license-key"
    "lemon-squeezy-instance-id"
    "ai-provider-openai"
    "ai-provider-claude"
    "ai-provider-gemini"
    "ai-provider-grok"
    "keychain-access-probe"
)
for account in "${KEYCHAIN_ACCOUNTS[@]}"; do
    security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$account" 2>/dev/null || true
    security delete-generic-password -s "$LEGACY_KEYCHAIN_SERVICE" -a "$account" 2>/dev/null || true
done

echo ""
echo "Done. Build and run for a fresh start."
