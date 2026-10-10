#!/bin/bash
# Chromium policies from the settings (root: from save-config.sh and at build time).
#   WEB_BUTTON=app      only WEB_URL and the sites in WEB_ALLOW can be opened
#   browser, kiosk      free browsing (a kiosk page may load other sites)
# Always: no sign-in, no sync, no extensions, no downloads, no developer tools, no guest or incognito.
# The URLs are validated by save-config.sh (no quotes or backslashes), so they can go into JSON as they are.
. /opt/openthinrdp/lib/common.sh
D=/etc/chromium/policies/managed
mkdir -p "$D"
origin(){ echo "$1" | sed -E 's#^(https?://[^/]+).*#\1#'; }
{
  echo '{'
  if [ "$(cfg WEB_BUTTON)" = app ] && [ -n "$(cfg WEB_URL)" ]; then
    echo '  "URLBlocklist": ["*"],'
    printf '  "URLAllowlist": ["%s"' "$(origin "$(cfg WEB_URL)")"
    for u in $(cfg WEB_ALLOW); do printf ', "%s"' "$u"; done
    echo ', "chrome://print"],'
  fi
  [ -n "$(cfg WEB_URL)" ] && printf '  "HomepageLocation": "%s",\n  "HomepageIsNewTabPage": false,\n' "$(cfg WEB_URL)"
  cat <<'EOF'
  "BrowserSignin": 0,
  "SyncDisabled": true,
  "BrowserGuestModeEnabled": false,
  "BrowserAddPersonEnabled": false,
  "IncognitoModeAvailability": 1,
  "DeveloperToolsAvailability": 2,
  "DownloadRestrictions": 3,
  "ExtensionInstallBlocklist": ["*"],
  "PasswordManagerEnabled": true,
  "DefaultBrowserSettingEnabled": false,
  "MetricsReportingEnabled": false,
  "PromotionalTabsEnabled": false,
  "TranslateEnabled": false,
  "BackgroundModeEnabled": false,
  "AutoplayAllowed": false
}
EOF
} > "$D/openthinrdp.json.new"
if cmp -s "$D/openthinrdp.json.new" "$D/openthinrdp.json"; then rm -f "$D/openthinrdp.json.new"
else chmod 644 "$D/openthinrdp.json.new"; mv -f "$D/openthinrdp.json.new" "$D/openthinrdp.json"; fi
exit 0
