# gnss2cloud

Continuous GNSS raw data logging → RINEX conversion → dual-cloud upload,
packaged as a self-contained, non-root Docker container. Built around
RTKLIB, which supports multiple receiver manufacturers. 
However, this was developed and tested against an Ardusimple SimpleRTK2B
(u-blox ZED-F9P) and SimpleRTK3B Pro (Septentrio mosaic-X5), across
Ubuntu, AlmaLinux, Debian, and Arch Linux hosts; see
[Tested status](#tested-status) below for exactly what has and hasn't
been validated.

## What it does

1. Captures raw GNSS data continuously from the receiver, rotating to a
   new file every hour.
2. Converts each closed hour to RINEX 3.04, then compresses it:
   Hatanaka + gzip for the observation file, plain gzip for the
   navigation file, zstd for the raw capture. If Hatanaka compression
   fails on a given hour (rare — see [Known limitations](#known-limitations)),
   the observation file falls back to plain gzip rather than being
   silently withheld.
3. Uploads raw + RINEX files (`.crx.gz`/`.obs.gz`, `.nav.gz`, `.zst`) to
   two cloud providers in parallel (S3-compatible or rclone-native).
4. Cleans up local files automatically, once a file is confirmed present
   on **both** remotes and at least 24 hours old.
5. Rotates its own logs.
6. Runs a health check every 5 minutes and reports (does not silently
   auto-fix) anomalies, such as: receiver disconnected, process stuck, no data
   flowing.
7. **Optionally** runs a read-only web dashboard, with station status, live
   satellite CN0, and a stationary-aware movement indicator, as a
   separate, opt-in container. See
   [Web dashboard](#web-dashboard-optional-monitoring-only) below.

Everything above runs unattended, inside a single container, as an
unprivileged user, no root process runs at any point after the image is
built.

## Tested status

Validated end-to-end against **u-blox** and **Septentrio** hardware,
on **Ubuntu, AlmaLinux, Debian, and Arch Linux** hosts, including the
web dashboard in both `shared` and `dedicated` NMEA modes. See
**[docs/tested-status.md](docs/tested-status.md)** for the full
breakdown of what's validated, what's implemented-but-untested
(currently: NovAtel hardware), and bugs found/fixed during testing.

**Not yet implemented:** push notifications (e.g. ntfy.sh) for health
alerts — currently alerts are written to `logs/health.log` only.
Authentication for the web dashboard is also not yet implemented — see
[Web dashboard](#web-dashboard-optional-monitoring-only) and
[Known limitations](#known-limitations) below.

## Compression

RINEX and raw files are compressed before upload:

- **Observation data** (`.obs`) — [Hatanaka-compressed](https://gssc.esa.int/navipedia/index.php/Hatanaka_RINEX_Compression)
  (`rnx2crx`) then gzipped, producing `.crx.gz`. This is the standard
  format expected by the wider GNSS tooling ecosystem (`teqc`,
  `gfzrnx`, IGS-style archives), chosen over a more aggressive
  compressor specifically for that compatibility.
- **Navigation data** (`.nav`) — plain gzip, producing `.nav.gz`.
  Hatanaka compression only applies to observation-type RINEX, not nav.
- **Raw receiver data** — [zstd](https://github.com/facebook/zstd),
  producing e.g. `.ubx.zst`. No compatibility constraint here (it's a
  proprietary receiver format, not something external tools read
  directly), so zstd was chosen for its better ratio and speed over
  gzip.

**Fallback:** `rnx2crx` performs real RINEX-spec validation as a
side effect of compression. If it rejects a file (see the RTKLIB bug
noted below), the observation file is compressed with plain gzip
instead (`.obs.gz`) rather than being left uncompressed and invisible
to the upload/retention scripts. `.obs.gz` files are functionally
equivalent to `.crx.gz` for upload/retention purposes, just larger.

**Known upstream bug:** the official [tomojitakasu/RTKLIB](https://github.com/tomojitakasu/RTKLIB)
`convbin` (as of `master`) has a bug causing "Duplicated satellite in
one epoch" errors on u-blox RXM-RAWX data.
This project builds `convbin`/`str2str` from the actively-maintained
[rtklibexplorer/RTKLIB](https://github.com/rtklibexplorer/RTKLIB) fork
instead (pinned to a specific commit in the Dockerfile for reproducible
builds), which resolves it.


## Upload efficiency

`upload_hourly.sh` avoids re-verifying every retained file against the
cloud every hour (which was found to blow through Backblaze B2's
transaction cap in multi-day testing) via a local marker-file cache.
See **[docs/upload-efficiency.md](docs/upload-efficiency.md)** for
details, and guidance for multi-station deployments sharing one cloud
account.

## Web dashboard (optional, monitoring only)

A read-only monitoring dashboard, packaged as a **separate, opt-in
container** (`gnss2cloud-web`) so it never runs, and never affects
the core pipeline, unless explicitly enabled.

**What it shows:** station status (health/upload/retention/conversion,
each pulled straight from the existing logs), live per-satellite CN0
grouped by constellation, a stationary-aware movement indicator
(speed + course, shown as a compass-style polar plot), and two uptime
figures: how long the receiver's data has been flowing without
interruption, and how long the main container has been running.

**What it deliberately does not do:** transmit, store, or display
*position*. Currently only NMEA GSV, VTG, and GSA sentences are used.

### Enabling it

```bash
docker compose --profile web up -d
```

Requires `NMEA_SOURCE_MODE` set in `.env` (see below) — without it,
the dashboard runs but its live satellite/movement panel stays empty,
since the main container has nothing to fan out.

### NMEA source modes

The receiver needs to emit GSV/VTG/GSA somewhere the dashboard can
reach. Two supported modes, both `.env`-driven:

- **`NMEA_SOURCE_MODE=shared`** — receiver puts NMEA on the *same*
  port as raw capture (the common case for a single-USB-port
  receiver, e.g. u-blox). A local filter relay
  (`grep`+`socat`) ensures only GSV/VTG/GSA ever reach the internal
  network port, even though the underlying stream is shared, the
  raw archival capture itself is completely unaffected. Validated
  end-to-end against u-blox.
- **`NMEA_SOURCE_MODE=dedicated`** — receiver has a genuinely separate
  NMEA-only port or virtual port (`NMEA_DEVICE_PATH`), e.g. via a
  UART-to-USB adapter, or a receiver whose USB interface exposes
  multiple independent virtual ports (Septentrio-style). Validated
  end-to-end against Septentrio's multi-virtual-port USB interface,
  a UART-adapter-based dedicated NMEA port has not yet been tested.

See `docs/receiver-setup.md` for per-receiver configuration steps —
**enabling GSV/VTG/GSA output at the receiver &
disabling GGA/RMC/GLL/ZDA on the same port**, and saving the configuration to the receiver's flash
memory, not just the live session.

### Security model

- **No credentials, no `.env`, no `rclone.conf`, no Docker socket** —
  the web container has none of these, by design. A compromise here
  cannot reach cloud credentials or control other containers.
- **Read-only mount of `./data/logs` only** (`:ro`) — never the full
  `./data` tree. Raw captures and RINEX output stay inaccessible to
  this container even under compromise.
- **Not published to the host by default** (`expose`, not `ports`) —
  reachable only from other containers on the compose network. Put a
  reverse proxy (TLS + at minimum HTTP basic auth) in front before
  any access beyond a trusted local network.
- **Authentication is not yet implemented.** An inert auth seam exists
  (`WEB_AUTH_ENABLED`, default off) so real auth can be added later
  without restructuring routes, but until then: **treat this service
  as trusted-network-only.**

### Relevant `.env` variables

```
NMEA_SOURCE_MODE=none        # none | shared | dedicated
NMEA_INTERNAL_PORT=5015
NMEA_DEVICE_PATH=            # dedicated mode only
NMEA_BAUD=9600                # dedicated mode only
WEB_AUTH_ENABLED=false        # inert today — see Security model above
```

## Prerequisites

- A Linux host with Docker and Docker Compose installed
- A GNSS receiver connected via USB. Tested and documented for
  **u-blox** and **Septentrio** (see `docs/receiver-setup.md` for
  configuration steps for each); NovAtel is supported at the code
  level but not yet hands-on validated — see `docs/receiver-setup.md`.
- A udev rule on the **host** creating a stable `/dev/gnss0` symlink
  (see [docs/host-setup.md](docs/host-setup.md), this must live on the host,
  Docker cannot manage this itself)
- Accounts with your chosen cloud storage providers, with an `rclone.conf`
  already configured and tested (see
  [rclone's docs](https://rclone.org/docs/) for provider-specific setup)

## Host setup

The host needs a stable device path (a udev rule) before the container
can start — Docker cannot create this itself. This is required, not
optional. See **[docs/host-setup.md](docs/host-setup.md)** for the
udev rule (including the multi-port-receiver case, e.g. Septentrio)
and distro-specific notes for Ubuntu/Debian, RHEL-family (SELinux),
and Arch Linux.

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

4. Starting v0.5.0, `data/raw`, `data/rinex`, and `data/logs` are present after
   cloning (tracked via `.gitkeep`). If your `PUID`/`PGID` don't match
   the user you cloned as, fix ownership before starting the container:
```bash
   sudo chown -R ${PUID:-1000}:${PGID:-1000} data/
```

5. Build and start:
```bash
   docker compose up -d --build
```

6. Check it's running:
   ```bash
   docker compose ps
   docker compose logs -f
   ```

7. **Optional — web dashboard.** Set `NMEA_SOURCE_MODE` in `.env`
   first (see [Web dashboard](#web-dashboard-optional-monitoring-only)),
   then:
   ```bash
   docker compose --profile web up -d
   ```
   Not published to the host by default — see
   [Web dashboard](#web-dashboard-optional-monitoring-only) for the
   security model before exposing it further.

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
  container restart.A future improvement would be a minimal init (e.g.
  `tini`) supervising both processes properly.
- **NovAtel support is untested.** `GNSS_FORMAT` threads the correct
  RTKLIB format token through the pipeline, but no real NovAtel
  hardware has been run against this container. See
  `docs/receiver-setup.md`.
- **`.nav.gz` uploads one cycle late.** The upload script requires a
  file be >5 minutes old before uploading; freshly-created `.nav.gz`
  files sit right at that boundary and consistently miss the same-hour
  upload, catching up the following hour instead. Self-healing (no data
  loss), but not yet resolved, either lowering the age threshold or
  delaying the upload schedule would fix it.
- **Upload-state markers have no automatic garbage collection** beyond
  what `retention_cleanup.sh` removes on successful deletion. If a
  file is ever deleted out-of-band (manually, or by a future change),
  its markers would be orphaned in `logs/upload_state/` — harmless
  (unused disk space) but not currently swept up separately.
- **Web dashboard has no authentication.** `WEB_AUTH_ENABLED` exists
  as an inert seam, not a working login system — see
  [Web dashboard](#web-dashboard-optional-monitoring-only).
- **Web dashboard's WebSocket endpoint has no rate limit or
  max-connection cap.** Low risk on a trusted network, worth adding
  before any wider exposure.
- **Satellites that drop out of view never expire from the
  dashboard's in-memory state** — the NMEA bridge publishes whatever
  it last saw per satellite and has no expiry/staleness logic, so a
  satellite that's no longer tracked can persist in the display
  indefinitely until the web container restarts.
- **`NMEA_SOURCE_MODE=dedicated` has been validated against
  Septentrio's multi-virtual-USB-port interface.** A genuinely
  separate UART-to-USB adapter-based dedicated NMEA port has not yet
  been tested.
- **Web dashboard has not been tested against NovAtel** at all
  (separately from the main pipeline's own NovAtel gap noted above).

## Roadmap

- **Configurable raw compression** (`RAW_COMPRESSION`) — let
  users choose between `zst` (current default), `xz`, `gz`, or `none`
  for the archived raw file, for compatibility with downstream
  pipelines that expect a specific format.
- **Multi-bucket scalability** — auto-detect `REMOTE_STORAGE_N`
  (currently fixed at exactly 2), with a configurable minimum to
  preserve the redundancy guarantee.
- **ARM/Raspberry Pi validation** for the compression pipeline
  specifically (validated on x86_64 so far).
- **Web dashboard follow-ups** (see
  [Web dashboard](#web-dashboard-optional-monitoring-only) and
  [Known limitations](#known-limitations)):
- Hands-on test of a genuinely separate UART-to-USB adapter-based
  `NMEA_SOURCE_MODE=dedicated` port (Septentrio's multi-virtual-port
  case is now validated — see Tested status above).
- Real authentication behind `WEB_AUTH_ENABLED`, plus activating
  the currently-inert security-event logging sink
  (`logs/security_events.log`).
- Reverse proxy + TLS/basic-auth documentation for any deployment
  beyond a trusted local network.
- Rate limiting / max-connection cap on the WebSocket endpoint.


## Acknowledgments

Thanks to [Storm Developments](https://stormdevelopments.ca) and
[Backblaze](https://www.backblaze.com) for providing free-tier
access to cloud storage, which helped in the development and testing
of this project.

Portions of this project (including the compression pipeline, the
RTKLIB bug investigation, and this documentation) were developed and
reviewed with assistance from [Claude](https://claude.ai) (Anthropic),
with additional help at various points from
[Microsoft Copilot](https://copilot.microsoft.com),
[Google AI Mode](https://support.google.com/websearch/answer/14901683), [Kimi AI](https://www.kimi.ai/)
and Brave's [Leo](https://brave.com/leo/).

## A note on validation

This project has been tested in the ways described throughout this
README — but "tested" here means real use on the hardware and
platforms listed in [Tested status](#tested-status), not formal or
independent certification. Configurations, receivers, or environments
outside what's documented as tested may behave differently. If you're
relying on this for something where correctness matters, it's worth
validating it against your own setup before trusting it in production
— the same way this project's own testing surfaced real bugs that
weren't obvious from code review alone.

## License

MIT — see [LICENSE](LICENSE).
