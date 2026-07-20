#!/usr/bin/env bash
# Guard against drift between the three places the notification-event catalog
# lives (CROW-768): the canonical `NotificationEvent` Swift enum and the two web
# mirrors that render/gate it. They are separate languages, so nothing enforces
# agreement at build time — this does, cheaply, in CI and locally.
#
#   - Swift enum cases      → Packages/CrowCore/Sources/CrowCore/Models/NotificationEvent.swift
#   - client dispatch list  → .../web/app.js         (ALL_EVENTS = base ++ AUTOMATION_EVENTS)
#   - Settings tab list     → .../web/settings.js    (EVENT_ORDER)
#
# Exit non-zero (with a diff) if any of the three disagree on the set of events.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENUM="$ROOT/Packages/CrowCore/Sources/CrowCore/Models/NotificationEvent.swift"
APP="$ROOT/Packages/CrowDaemon/Sources/CrowDaemon/Resources/web/app.js"
SETTINGS="$ROOT/Packages/CrowDaemon/Sources/CrowDaemon/Resources/web/settings.js"

# Swift: `case fooBar` lines inside the enum (skip the computed `isAutomationEvent`
# switch, whose `case` lines are indented deeper and list multiple names).
swift_events() {
  grep -oE '^    case [a-zA-Z]+$' "$ENUM" | awk '{print $2}' | sort
}

# app.js: the base literal array concatenated with AUTOMATION_EVENTS.
app_events() {
  node -e '
    const fs = require("fs");
    const s = fs.readFileSync(process.argv[1], "utf8");
    const all = s.match(/const ALL_EVENTS = \[([\s\S]*?)\]\.concat\(AUTOMATION_EVENTS\)/);
    const auto = s.match(/const AUTOMATION_EVENTS = \[([\s\S]*?)\];/);
    const names = (x) => (x.match(/'"'"'([^'"'"']+)'"'"'/g) || []).map((v) => v.slice(1, -1));
    console.log(names(all[1]).concat(names(auto[1])).sort().join("\n"));
  ' "$APP"
}

# settings.js: the EVENT_ORDER array.
settings_events() {
  node -e '
    const fs = require("fs");
    const s = fs.readFileSync(process.argv[1], "utf8");
    const order = s.match(/const EVENT_ORDER = \[([\s\S]*?)\];/);
    const names = (order[1].match(/'"'"'([^'"'"']+)'"'"'/g) || []).map((v) => v.slice(1, -1));
    console.log(names.sort().join("\n"));
  ' "$SETTINGS"
}

status=0
if ! diff <(swift_events) <(app_events) >/tmp/notif-app.diff 2>&1; then
  echo "MISMATCH: NotificationEvent.swift vs app.js (< Swift, > app.js):" >&2
  cat /tmp/notif-app.diff >&2
  status=1
fi
if ! diff <(swift_events) <(settings_events) >/tmp/notif-settings.diff 2>&1; then
  echo "MISMATCH: NotificationEvent.swift vs settings.js (< Swift, > settings.js):" >&2
  cat /tmp/notif-settings.diff >&2
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "notification-event catalogs agree ($(swift_events | wc -l | tr -d ' ') events)"
fi
exit "$status"
