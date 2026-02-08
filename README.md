# Zpool Monitor (cron + Pushover)

A lightweight ZFS `zpool` monitoring script designed to run from `cron`.

It:

- Logs pool health and scan activity (scrub / resilver) every run
- Sends Pushover notifications when a pool becomes unhealthy (rate-limited)
- Optionally sends **exactly one** notification when a scrub starts and **exactly one** when it ends (fully configurable)

---

## Files

- **`zpool-monitor.sh`**  
  Main monitoring script. Intended to be run periodically via `cron`.

- **`/etc/zpool-monitor.env`**  
  Environment configuration file. Stores pool name, Pushover credentials, logging paths, and notification toggles.

- **State directory** (default: `/var/lib/poolStatusCheck/`)  
  Stores small state files so the script can detect transitions (scrub start/end) and enforce alert cooldowns.

---

## Requirements

- ZFS utilities installed (`zpool` available, typically `/usr/sbin/zpool`)
- `curl` installed (for Pushover delivery)
- Script should run as `root` (or a user with permission to run `zpool status`)
- Optional but recommended: `flock` (from `util-linux`) to prevent overlapping cron runs

---

## Installation

### 1. Install the script

```bash
sudo install -m 0755 zpool-monitor.sh /usr/local/sbin/zpool-monitor.sh
```

### 2. Create the environment file

```bash
sudo nano /etc/zpool-monitor.env
sudo chmod 600 /etc/zpool-monitor.env
```

Example `/etc/zpool-monitor.env`:

```bash
# Pool to monitor
POOL="pool"

# Logging / state
LOGFILE="/var/log/poolStatusCheck.log"
STATE_DIR="/var/lib/poolStatusCheck"

# Cooldown for repeated "unhealthy" alerts (seconds)
COOLDOWN_SECONDS=3600

# Pushover credentials
PO_TOKEN="XXX"
PO_UK="YYY"

# Scrub notifications (0 = disabled, 1 = enabled)
NOTIFY_SCRUB_START=1
NOTIFY_SCRUB_END=1

# Optional resilver notifications
NOTIFY_RESILVER_START=0
NOTIFY_RESILVER_END=0

# Pushover tuning
PO_PRIORITY_ALARM=0
PO_PRIORITY_INFO=-1
PO_SOUND_ALARM=""
PO_SOUND_INFO=""
```

### 3. Create the state directory

```bash
sudo mkdir -p /var/lib/poolStatusCheck
sudo chmod 700 /var/lib/poolStatusCheck
```

### 4. Create the log file

```bash
sudo touch /var/log/poolStatusCheck.log
sudo chmod 640 /var/log/poolStatusCheck.log
sudo chown root:root /var/log/poolStatusCheck.log
```

---

## Cron Setup

Recommended cron entry (runs every 5 minutes and prevents overlapping runs):

```cron
*/5 * * * * /usr/bin/flock -n /var/run/zpool-monitor.lock ENV_FILE=/etc/zpool-monitor.env /usr/local/sbin/zpool-monitor.sh
```

If you don’t want locking:

```cron
*/5 * * * * ENV_FILE=/etc/zpool-monitor.env /usr/local/sbin/zpool-monitor.sh
```

---

## Manual Test

Run once by hand to verify everything works:

```bash
sudo ENV_FILE=/etc/zpool-monitor.env /usr/local/sbin/zpool-monitor.sh
```

Check logs:

```bash
sudo tail -n 50 /var/log/poolStatusCheck.log
```

If using systemd-journald:

```bash
sudo journalctl -t zpool-monitor -n 50
```

---

## What the Script Does

Every run:

1. Checks pool health using `zpool status -x POOL`
2. Extracts scan activity from `zpool status POOL`
3. Logs:
   - Scrub / resilver activity and progress
   - Healthy or unhealthy state
4. Sends notifications:
   - **Unhealthy pool** (rate-limited)
   - **Scrub started** (once per scrub, optional)
   - **Scrub finished** (once per scrub, optional)
   - Optional resilver start/end notifications

---

## Scrub Notifications (Once at Start, Once at End)

The script tracks state transitions using files in `STATE_DIR`:

- `${POOL}.last_activity`  
  Tracks last known activity (`scrub`, `resilver`, `none`, etc.)

- `${POOL}.last_scrub_id`  
  Stores the final `scan:` completion line (`scrub repaired ... on ...`) to prevent duplicate “scrub finished” alerts

Because of this, the script can run every minute without spamming you.

---

## Configuration Reference

All settings below can be defined in `/etc/zpool-monitor.env`.

| Variable | Description |
|--------|------------|
| `POOL` | Name of the ZFS pool to monitor |
| `LOGFILE` | Path to log file |
| `STATE_DIR` | Directory for state tracking |
| `COOLDOWN_SECONDS` | Minimum time between unhealthy alerts |
| `PO_TOKEN` | Pushover application token |
| `PO_UK` | Pushover user key |
| `NOTIFY_SCRUB_START` | Notify when scrub starts (0/1) |
| `NOTIFY_SCRUB_END` | Notify when scrub ends (0/1) |
| `NOTIFY_RESILVER_START` | Notify when resilver starts (0/1) |
| `NOTIFY_RESILVER_END` | Notify when resilver ends (0/1) |
| `PO_PRIORITY_ALARM` | Priority for unhealthy alerts |
| `PO_PRIORITY_INFO` | Priority for scrub/resilver alerts |
| `PO_SOUND_ALARM` | Optional Pushover sound for alarms |
| `PO_SOUND_INFO` | Optional Pushover sound for info alerts |

---

## Troubleshooting

### No Pushover notifications
- Verify `PO_TOKEN` and `PO_UK`
- Ensure `curl` exists at `/usr/bin/curl`
- Run manually and check logs

### Works manually but not in cron
- Cron has a minimal environment — always pass `ENV_FILE=...`
- Ensure the script uses absolute paths
- Run as `root` for ZFS permissions

### Too many alerts
- Increase `COOLDOWN_SECONDS`
- Ensure `STATE_DIR` is writable and persistent

---

## Security Notes

- Protect the environment file (contains secrets):

```bash
sudo chmod 600 /etc/zpool-monitor.env
```

- Keep the state directory root-owned if running from root cron

---

## Optional Enhancements

- Add `logrotate` configuration for `poolStatusCheck.log`
- Run multiple pools using multiple env files
- Convert to a systemd timer instead of cron

---

This README is ready for direct upload to GitHub as `README.md`.

