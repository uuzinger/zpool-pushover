````markdown
# Zpool Monitor (cron + Pushover) — README

This project provides a lightweight ZFS `zpool` monitoring script designed to run from `cron`. It:
- Logs pool health and scan activity (scrub/resilver) every run
- Sends Pushover notifications when a pool becomes unhealthy (rate-limited)
- Optionally sends exactly one notification when a scrub starts and exactly one when it ends (configurable)

## Files

- `zpool-monitor.sh`  
  The main monitoring script. Intended to be run periodically via `cron`.

- `/etc/zpool-monitor.env`  
  Environment configuration file (recommended). Stores pool name, Pushover credentials, log/state paths, and notification toggles.

- State directory (default: `/var/lib/poolStatusCheck/`)  
  The script writes a few small files here to remember prior state (so it can detect “scrub started” and “scrub ended” transitions and enforce cooldown).

## Requirements

- ZFS tools installed (`zpool` available, typically `/usr/sbin/zpool`)
- `curl` installed for Pushover delivery
- Permissions to run `zpool status` (usually run via root cron)
- Optional but recommended: `flock` (from `util-linux`) to avoid overlapping cron runs

## Install

1) Copy the script into place:

```bash
sudo install -m 0755 zpool-monitor.sh /usr/local/sbin/zpool-monitor.sh
````

2. Create the environment file:

```bash
sudo nano /etc/zpool-monitor.env
sudo chmod 600 /etc/zpool-monitor.env
```

Example `/etc/zpool-monitor.env`:

```bash
# Which pool to monitor
POOL="pool"

# Logging / state
LOGFILE="/var/log/poolStatusCheck.log"
STATE_DIR="/var/lib/poolStatusCheck"

# Cooldown for repeated "unhealthy" notifications (seconds)
COOLDOWN_SECONDS=3600

# Pushover credentials
PO_TOKEN="XXX"
PO_UK="YYY"

# Enable scrub start/end notifications (0/1)
NOTIFY_SCRUB_START=1
NOTIFY_SCRUB_END=1

# Optional: enable resilver start/end notifications (0/1)
NOTIFY_RESILVER_START=0
NOTIFY_RESILVER_END=0

# Pushover tuning
PO_PRIORITY_ALARM=0
PO_PRIORITY_INFO=-1
PO_SOUND_ALARM=""
PO_SOUND_INFO=""
```

3. Create the state directory (if you keep defaults):

```bash
sudo mkdir -p /var/lib/poolStatusCheck
sudo chmod 700 /var/lib/poolStatusCheck
```

4. Ensure the log file is writable by the user running the script (root recommended):

```bash
sudo touch /var/log/poolStatusCheck.log
sudo chmod 640 /var/log/poolStatusCheck.log
sudo chown root:adm /var/log/poolStatusCheck.log 2>/dev/null || sudo chown root:root /var/log/poolStatusCheck.log
```

## Cron setup

Recommended cron entry (runs every 5 minutes, prevents overlapping runs):

```cron
*/5 * * * * /usr/bin/flock -n /var/run/zpool-monitor.lock ENV_FILE=/etc/zpool-monitor.env /usr/local/sbin/zpool-monitor.sh
```

If you don’t want `flock`, use:

```cron
*/5 * * * * ENV_FILE=/etc/zpool-monitor.env /usr/local/sbin/zpool-monitor.sh
```

### Quick test (manual run)

Run once manually to confirm everything works:

```bash
sudo ENV_FILE=/etc/zpool-monitor.env /usr/local/sbin/zpool-monitor.sh
```

Then check logs:

```bash
sudo tail -n 50 /var/log/poolStatusCheck.log
```

If using systemd-journald, you can also check:

```bash
sudo journalctl -t zpool-monitor -n 50
```

## What the script does

Every run, the script:

1. Runs `zpool status -x POOL` to determine whether the pool is healthy.
2. Runs `zpool status POOL` and extracts:

   * the `scan:` line (scrub/resilver info)
   * an optional “% done” line (progress)
3. Logs:

   * `ACTIVITY: ...` lines for scrub/resilver/none
   * `OK:` when healthy
   * `ALARM:` when unhealthy
4. Notifications:

   * Unhealthy: sends a Pushover alert when the pool is not healthy, rate-limited by `COOLDOWN_SECONDS`.
   * Scrub start: sends once when the script detects a transition into “scrub in progress” (if enabled).
   * Scrub end: sends once when the script detects a transition out of scrub and sees a new completion line like `scrub repaired ... on ...` (if enabled).
   * (Optional) Resilver start/end notifications can be enabled similarly.

## Scrub notifications: “once at start, once at end”

This is enforced by state tracking files inside `STATE_DIR`:

* `${POOL}.last_activity` tracks last seen activity (`scrub`, `resilver`, `none`, etc.)
* `${POOL}.last_scrub_id` stores the last scrub completion `scan:` line to prevent duplicates

Because of this, you can run the script frequently and it will not spam you during an ongoing scrub.

## Configuration reference

All of these can go in `/etc/zpool-monitor.env`:

* `POOL`
  Pool name to check (required).

* `LOGFILE`
  Log path. Default: `/var/log/poolStatusCheck.log`

* `STATE_DIR`
  Directory to store state files. Default: `/var/lib/poolStatusCheck`

* `COOLDOWN_SECONDS`
  Minimum seconds between “unhealthy” alerts. Default: `3600`

* `PO_TOKEN`, `PO_UK`
  Pushover application token and user key.

* `NOTIFY_SCRUB_START` / `NOTIFY_SCRUB_END`
  `1` to enable scrub start/end notifications; `0` to disable.

* `NOTIFY_RESILVER_START` / `NOTIFY_RESILVER_END`
  Optional resilver notifications.

* `PO_PRIORITY_ALARM`, `PO_PRIORITY_INFO`
  Pushover priority values:

  * `-2` no notification
  * `-1` quiet
  * `0` normal
  * `1` high
  * `2` emergency (requires retry/expire)

* `PO_SOUND_ALARM`, `PO_SOUND_INFO`
  Optional Pushover sound names (empty string = default).

* `ENV_FILE`
  Path to config file. You typically pass this from cron:
  `ENV_FILE=/etc/zpool-monitor.env`

## Troubleshooting

### No Pushover messages

* Confirm credentials in `/etc/zpool-monitor.env`
* Confirm `curl` path: `/usr/bin/curl`
* Run manually with `sudo` and check log output:

  ```bash
  sudo ENV_FILE=/etc/zpool-monitor.env /usr/local/sbin/zpool-monitor.sh
  ```

### Script runs in terminal but not from cron

* Cron has a minimal environment; always pass `ENV_FILE=...`
* Use absolute paths (the script already does)
* Ensure cron user has permission to run `zpool status` (root recommended)

### Too many alerts during an incident

* Increase `COOLDOWN_SECONDS`
* Make sure `STATE_DIR` is writable and persistent (so cooldown and “already notified” state can be stored)

## Notes / extensions

* Multiple pools: you can run multiple cron entries with different env files, e.g.:

  * `/etc/zpool-monitor-poolA.env`
  * `/etc/zpool-monitor-poolB.env`

* Scrub paused behavior: the script treats `scrub paused` as distinct from `scrub in progress`. If you prefer “paused still counts as scrubbing” for start/end semantics, adjust the activity transition logic in the script.

## Security

* Protect `/etc/zpool-monitor.env` since it contains secrets:

  ```bash
  sudo chmod 600 /etc/zpool-monitor.env
  ```
* Keep `STATE_DIR` root-owned if running via root cron.

---

If you want, I can also add a `logrotate` stanza for `poolStatusCheck.log` so it doesn’t grow forever.

```
```
