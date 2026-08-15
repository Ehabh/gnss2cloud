# gnss2cloud

Continuous GNSS raw data logging → RINEX conversion → dual-cloud upload,
packaged as a self-contained, non-root Docker container. Built around
RTKLIB, which supports multiple receiver manufacturers. 
However, this was developed and tested against a u-blox SimpleRTK2B; see
[Tested status](#tested-status) below for exactly what has and hasn't
been validated.

## What it does

1. Captures raw GNSS data continuously from the receiver, rotating to a
   new file every hour.
2. Converts each closed hour to RINEX 3.04 (`.obs` / `.nav`).
3. Uploads raw + RINEX files to two cloud providers in parallel
   (currently Backblaze B2 and Storm Developments, both S3-compatible or
   rclone-native, easy to add more).
4. Cleans up local files automatically, once a file is confirmed present
   on **both** remotes and at least 24 hours old.
5. Rotates its own logs.
6. Runs a health check every 5 minutes and reports (does not silently
   auto-fix) anomalies, such as: receiver disconnected, process stuck, no data
   flowing.

Everything above runs unattended, inside a single container, as an
unprivileged user, no root process runs at any point after the image is
built.

## Tested status

- **Receiver:** validated end-to-end against a **u-blox SimpleRTK2B**.
  NovAtel and Septentrio support is implemented (RTKLIB supports both
  formats, and gnss2cloud's `GNSS_FORMAT` variable selects the correct
  one, see `docs/receiver-setup.md`), but **not yet tested against real
  NovAtel or Septentrio hardware**.
- **Host OS:** validated on **Ubuntu Server** and **AlmaLinux**
  (RHEL-family). Debian is also proven via the original bare-metal
  deployment this project was containerized from. Other distributions
  should work (Docker itself is the actual dependency, not the host
  distro) but haven't been explicitly tested.
- Raw capture, RINEX conversion, and dual-cloud upload: proven on bare
  metal (Raspberry Pi 3B and a Debian mini PC) over a multi-day soak
  test, and validated end-to-end in the Docker container.
- Retention, log rotation, network-resilient uploads, and health
  monitoring: each deliberately tested against real failure conditions
  (power loss, receiver disconnects, a stuck-process bug) before being
  containerized.
- The Docker image adapts every bare-metal script to run without root
  (using [supercronic](https://github.com/aptible/supercronic) instead
  of system cron, which normally requires a root daemon).

**Not yet implemented:** push notifications (e.g. ntfy.sh) for health
alerts — currently alerts are written to `logs/health.log` only. See
[Known limitations](#known-limitations) below.

## Prerequisites

- A Linux host with Docker and Docker Compose installed
- A GNSS receiver connected via USB. Tested and documented for u-blox
  (see `docs/receiver-setup.md` for configuration steps); note that NovAtel and Septentrio are supported at
  the code level but not yet hands-on validated, see
  `docs/receiver-setup.md` for both.
- A udev rule on the **host** creating a stable `/dev/gnss0` symlink
  (see [Host setup](#host-setup) below, this must live on the host,
  Docker cannot manage this itself)
- Accounts with your chosen cloud storage providers, with an `rclone.conf`
  already configured and tested (see
  [rclone's docs](https://rclone.org/docs/) for provider-specific setup)

## Host setup

Before running the container, the host needs a stable device path. Create
`/etc/udev/rules.d/99-simplertk2b.rules` (must be a single line):

```
SUBSYSTEM=="tty", ATTRS{idVendor}=="1546", ATTRS{idProduct}=="01a9", SYMLINK+="gnss0"
```

Find your device's actual vendor/product IDs first with:
```bash
udevadm info -a -n /dev/ttyACM0 | grep -E 'idVendor|idProduct' | head -5
```
(`1546`/`01a9` above are u-blox's, confirm yours match, or use your own
receiver's IDs if you're not using a u-blox device.)

Apply it:
```bash
sudo udevadm control --reload-rules
sudo udevadm trigger
```

Verify:
```bash
ls -la /dev/gnss0
```

## Setup

1. Clone this repo:
   ```bash
   git clone https://github.com/ehabh/gnss2cloud.git
   cd gnss2cloud
   ```

2. Copy the environment template and fill it in:
   ```bash
   cp .env.example .env
   ```
   Edit `.env` — you'll need:
   - `STATION_NAME` — used as the folder name in your cloud buckets
   - `REMOTE_STORAGE_1` / `REMOTE_STORAGE_2` — two independent rclone
     remotes for redundant, parallel upload. Must match remote names in
     your `rclone.conf`, e.g. `b2:your-bucket-name` or
     `s3:your-bucket-name`. Any rclone-supported backend works (B2, S3,
     Azure Blob, GCS, etc.) — order doesn't matter, both are treated as
     equal, redundant copies, not a primary/fallback pair.
   - `PUID` / `PGID` — run `id` on the host to get your user's values, so
     bind-mounted files come out owned correctly
   - `DIALOUT_GID` — run `getent group dialout` on the host, so the
     container can access the serial device
   - `GNSS_FORMAT` — optional. Leave unset for u-blox (auto-detected).
     Set to `nov` for NovAtel or `sbf` for Septentrio — see
     `docs/receiver-setup.md`.

3. Place your working `rclone.conf` in the project root (referenced by
   `RCLONE_CONFIG` in `.env`, default `./rclone.conf`). ** only an example is available**

4. Build and start:
   ```bash
   docker compose up -d --build
   ```

5. Check it's running:
   ```bash
   docker compose ps
   docker compose logs -f
   ```

## Verifying it's working

```bash
# Raw files rotating hourly, current hour growing
ls -la ./data/raw/

# Conversion happening (check after :05 past the hour)
cat ./data/logs/convert.log

# Uploads happening (check after :10 past the hour)
cat ./data/logs/upload.log

# Health status (updates every 5 minutes)
cat ./data/logs/health.log
```

## Scaling to multiple stations

Run one container per station, each with its own `.env` (different
`STATION_NAME`, different `DATA_DIR`, same or different device if you
have multiple receivers on one host) and, if on separate hosts, its own
`docker compose up`. The image is identical across all stations — only
configuration differs.

## Known limitations

- **No push notifications yet.** Health check alerts go to
  `logs/health.log` only. To add ntfy.sh (or similar), add a `curl` call
  to the alert branches in `scripts/health_check.sh` and rebuild.
- **Health check is report-only by design**, not self-healing. If it
  detects a stuck process, it logs the recommended fix
  (`docker compose restart`) rather than doing it automatically, this
  was a deliberate choice after review, to avoid giving an unattended
  script standing privilege to restart services, and because a receiver
  that's genuinely unplugged can't be fixed by restarting anything.
- **Root cause of the "stuck process" bug is not fully understood.** In
  testing, `str2str` was observed to survive a receiver disconnect/
  reconnect as a live process while silently no longer writing data,
  detectable via the process no longer holding the device file descriptor
  open. The health check catches this reliably; the underlying cause in
  `str2str`/RTKLIB has not been root-caused.
- **supercronic runs as a background job inside the entrypoint script**,
  not supervised by an init system. During Docker validation, a real bug
  was found and fixed: without explicit detachment, `str2str`'s
  continuous output could leak into supercronic's log stream and stall
  job scheduling for extended periods. This is fixed via `setsid` and
  explicit fd redirection in `entrypoint.sh`. supercronic crashing
  outright (not observed) would still silently halt scheduled jobs until
  container restart — a future improvement would be a minimal init (e.g.
  `tini`) supervising both processes properly.
- **NovAtel and Septentrio support is untested.** `GNSS_FORMAT` threads
  the correct RTKLIB format token through the pipeline, but no real
  NovAtel or Septentrio hardware has been run against this container.
  See `docs/receiver-setup.md`.

## License

MIT — see [LICENSE](LICENSE).
