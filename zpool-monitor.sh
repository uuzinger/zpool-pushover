#!/usr/bin/env bash
set -euo pipefail

# ----------------- load env settings -----------------
ENV_FILE="${ENV_FILE:-/etc/zpool-monitor.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

# ----------------- defaults (can be overridden by env) -----------------
POOL="${POOL:-pool}"

LOGFILE="${LOGFILE:-/var/log/poolStatusCheck.log}"
STATE_DIR="${STATE_DIR:-/var/lib/poolStatusCheck}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-3600}"

ZPOOL="${ZPOOL:-/usr/sbin/zpool}"
CURL="${CURL:-/usr/bin/curl}"
LOGGER="${LOGGER:-/usr/bin/logger}"

PO_TOKEN="${PO_TOKEN:-}"
PO_UK="${PO_UK:-}"
PO_API_URL="${PO_API_URL:-https://api.pushover.net/1/messages.json}"

PO_PRIORITY_ALARM="${PO_PRIORITY_ALARM:-0}"
PO_PRIORITY_INFO="${PO_PRIORITY_INFO:--1}"
PO_SOUND_ALARM="${PO_SOUND_ALARM:-}"
PO_SOUND_INFO="${PO_SOUND_INFO:-}"

NOTIFY_SCRUB_START="${NOTIFY_SCRUB_START:-1}"
NOTIFY_SCRUB_END="${NOTIFY_SCRUB_END:-1}"
NOTIFY_RESILVER_START="${NOTIFY_RESILVER_START:-0}"
NOTIFY_RESILVER_END="${NOTIFY_RESILVER_END:-0}"

# ----------------- state files -----------------
mkdir -p "$STATE_DIR"
touch "$LOGFILE"

LAST_ALERT_FILE="$STATE_DIR/${POOL}.last_alert_epoch"
LAST_HEALTH_FILE="$STATE_DIR/${POOL}.last_health"          # healthy|unhealthy|unknown
LAST_ACTIVITY_FILE="$STATE_DIR/${POOL}.last_activity"      # none|scrub|scrub_paused|resilver|unknown
LAST_SCRUB_ID_FILE="$STATE_DIR/${POOL}.last_scrub_id"      # used to avoid duplicate "end" notifications

# ----------------- helpers -----------------
ts() { date "+%Y-%m-%d %H:%M:%S"; }
now_epoch() { date +%s; }

log() {
  local msg="$1"
  echo "$(ts) - $msg" >> "$LOGFILE"
  "$LOGGER" -t "zpool-monitor" -- "$msg" || true
}

read_file() { local f="$1"; [[ -f "$f" ]] && cat "$f" 2>/dev/null || true; }
write_file() { local f="$1" v="$2"; printf "%s" "$v" > "$f"; }

read_epoch() { local f="$1"; [[ -f "$f" ]] && cat "$f" 2>/dev/null || echo 0; }

send_pushover() {
  local title="$1"
  local message="$2"
  local priority="$3"
  local sound="$4"

  # If creds missing, don't hard-fail cron; just log.
  if [[ -z "$PO_TOKEN" || -z "$PO_UK" ]]; then
    log "WARN: Pushover not configured (PO_TOKEN/PO_UK missing). Would have sent: $title"
    return 0
  fi

  "$CURL" -sS \
    -F "token=$PO_TOKEN" \
    -F "user=$PO_UK" \
    -F "title=$title" \
    -F "message=$message" \
    -F "priority=$priority" \
    ${sound:+-F "sound=$sound"} \
    "$PO_API_URL" >/dev/null
}

scan_line() {
  # returns the "scan:" content (without "scan: ")
  awk -F': ' '/^[[:space:]]*scan:/{print $2; exit}'
}

extract_progress_pct() {
  awk '
    /% done/ {
      for (i=1;i<=NF;i++) if ($i ~ /%/) { print $i; exit }
    }'
}

detect_activity() {
  # outputs: activity|scan_line
  local status="$1"
  local scan
  scan="$(echo "$status" | scan_line || true)"
  [[ -z "${scan:-}" ]] && { echo "unknown|no scan line"; return; }

  if [[ "$scan" =~ ^scrub\ in\ progress ]]; then
    echo "scrub|$scan"
  elif [[ "$scan" =~ ^scrub\ paused ]]; then
    echo "scrub_paused|$scan"
  elif [[ "$scan" =~ ^resilver\ in\ progress ]]; then
    echo "resilver|$scan"
  else
    # includes “scrub repaired … on …” and “none requested”
    echo "none|$scan"
  fi
}

# A simple "scrub id" to de-dupe end notifications:
# when scrub completes, scan line becomes "scrub repaired ... on <DATE>"
# we store that whole line; if it changes, it's a new completion.
scrub_completion_id() {
  local scan="$1"
  # Only meaningful for completion lines
  if [[ "$scan" =~ ^scrub\ repaired ]]; then
    echo "$scan"
  else
    echo ""
  fi
}

# ----------------- main -----------------
if [[ ! -x "$ZPOOL" ]]; then
  log "ERROR: zpool not found at $ZPOOL"
  exit 2
fi

status_x="$("$ZPOOL" status -x "$POOL" 2>&1 || true)"
full_status="$("$ZPOOL" status "$POOL" 2>&1 || true)"

healthy_line="pool '$POOL' is healthy"
is_healthy=false
[[ "$status_x" == "$healthy_line" ]] && is_healthy=true

prev_health="$(read_file "$LAST_HEALTH_FILE")"
prev_health="${prev_health:-unknown}"

# ---- activity detection ----
activity_and_scan="$(detect_activity "$full_status")"
activity="${activity_and_scan%%|*}"
scan="${activity_and_scan#*|}"
prev_activity="$(read_file "$LAST_ACTIVITY_FILE")"
prev_activity="${prev_activity:-unknown}"

pct="$(echo "$full_status" | extract_progress_pct || true)"

# Log activity context every run
if [[ "$activity" == "scrub" || "$activity" == "scrub_paused" || "$activity" == "resilver" ]]; then
  if [[ -n "${pct:-}" ]]; then
    log "ACTIVITY: $POOL $activity ($pct) - $scan"
  else
    log "ACTIVITY: $POOL $activity - $scan"
  fi
else
  log "ACTIVITY: $POOL none - $scan"
fi

# ---- scrub start/end notifications (exactly once per scrub) ----
# Start = transition into "scrub"
if [[ "$prev_activity" != "scrub" && "$activity" == "scrub" ]]; then
  if [[ "$NOTIFY_SCRUB_START" == "1" ]]; then
    send_pushover "Zpool $POOL scrub started" "scan: $scan" "$PO_PRIORITY_INFO" "$PO_SOUND_INFO"
    log "Pushover sent: scrub started."
  else
    log "Scrub started; notification disabled by NOTIFY_SCRUB_START."
  fi
fi

# End = transition out of "scrub" into "none" AND we have a completion line
# (After scrub ends, scan line typically becomes "scrub repaired ... on ...")
if [[ "$prev_activity" == "scrub" && "$activity" == "none" ]]; then
  completion_id="$(scrub_completion_id "$scan")"
  last_completion_id="$(read_file "$LAST_SCRUB_ID_FILE")"

  if [[ -n "$completion_id" ]]; then
    if [[ "$completion_id" != "$last_completion_id" ]]; then
      if [[ "$NOTIFY_SCRUB_END" == "1" ]]; then
        send_pushover "Zpool $POOL scrub finished" "scan: $scan" "$PO_PRIORITY_INFO" "$PO_SOUND_INFO"
        log "Pushover sent: scrub finished."
      else
        log "Scrub finished; notification disabled by NOTIFY_SCRUB_END."
      fi
      write_file "$LAST_SCRUB_ID_FILE" "$completion_id"
    else
      log "Scrub finished detected, but end notification already sent for this completion."
    fi
  else
    # Edge case: transition happened but we didn't see a completion line
    log "Scrub ended transition detected, but no completion line found; no end notification sent."
  fi
fi

# Optional resilver start/end notifications (same pattern)
if [[ "$prev_activity" != "resilver" && "$activity" == "resilver" ]]; then
  if [[ "$NOTIFY_RESILVER_START" == "1" ]]; then
    send_pushover "Zpool $POOL resilver started" "scan: $scan" "$PO_PRIORITY_INFO" "$PO_SOUND_INFO"
    log "Pushover sent: resilver started."
  fi
fi
if [[ "$prev_activity" == "resilver" && "$activity" == "none" ]]; then
  if [[ "$NOTIFY_RESILVER_END" == "1" ]]; then
    send_pushover "Zpool $POOL resilver finished" "scan: $scan" "$PO_PRIORITY_INFO" "$PO_SOUND_INFO"
    log "Pushover sent: resilver finished."
  fi
fi

# Persist activity state after handling transitions
write_file "$LAST_ACTIVITY_FILE" "$activity"

# ---- health alerting (unchanged behavior + cooldown) ----
if [[ "$is_healthy" == false ]]; then
  log "ALARM: zpool $POOL not healthy"
  log "DETAIL: $status_x"

  last_alert="$(read_epoch "$LAST_ALERT_FILE")"
  now="$(now_epoch)"

  if (( now - last_alert >= COOLDOWN_SECONDS )); then
    details="$(echo "$full_status" | sed -n '1,80p')"
    msg=$(
      cat <<EOF
zpool '$POOL' is NOT healthy.

zpool status -x:
$status_x

scan:
$scan

zpool status (top):
$details
EOF
    )
    msg="${msg:0:1000}"
    send_pushover "Zpool $POOL unhealthy" "$msg" "$PO_PRIORITY_ALARM" "$PO_SOUND_ALARM"
    write_file "$LAST_ALERT_FILE" "$now"
    log "Pushover sent (cooldown ${COOLDOWN_SECONDS}s)."
  else
    log "Alarm suppressed due to cooldown (${COOLDOWN_SECONDS}s)."
  fi

  write_file "$LAST_HEALTH_FILE" "unhealthy"
else
  log "OK: zpool $POOL is healthy"

  # Optional recovery notification (transition unhealthy -> healthy)
  if [[ "${prev_health:-unknown}" == "unhealthy" ]]; then
    msg=$(
      cat <<EOF
zpool '$POOL' has recovered and is healthy.

scan:
$scan

zpool status -x:
$status_x
EOF
    )
    msg="${msg:0:1000}"
    send_pushover "Zpool $POOL recovered" "$msg" "$PO_PRIORITY_INFO" "$PO_SOUND_INFO"
    log "Recovery pushover sent."
  fi

  write_file "$LAST_HEALTH_FILE" "healthy"
fi
