#!/bin/bash
# Removes GitLab Client and, optionally, its local clones and saved tokens.
# Usage: scripts/uninstall.sh          keep clones and tokens
#        scripts/uninstall.sh --data   also delete local clones, settings and the tokens in the Keychain
#
# Tokens are only deleted from this Mac's Keychain. They stay valid on the GitLab servers until
# they expire; revoke them in Settings → Domains first if you want them gone.
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/config.sh

DELETE_DATA=false
[ "${1:-}" = "--data" ] && DELETE_DATA=true

osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true

for app in "/Applications/${APP_NAME}.app" "$HOME/Applications/${APP_NAME}.app"; do
    [ -d "$app" ] || continue
    app_id="$(defaults read "$app/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
    if [ "$app_id" = "$BUNDLE_ID" ]; then
        rm -rf "$app" && echo "Removed $app"
    fi
done

if $DELETE_DATA; then
    rm -rf "$HOME/Library/Application Support/GitLabClient" && echo "Removed local clones"
    rm -rf "$HOME/Library/Caches/GitLabClient" && echo "Removed worktrees cache"
    # One generic password per domain; delete until none is left.
    removed=0
    while security delete-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; do removed=$((removed + 1)); done
    echo "Removed $removed saved token(s) from the Keychain"
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
else
    echo "Kept local clones and saved tokens (run with --data to delete them)."
fi
echo "Done."
