# Tested status

- **Receivers:**
  - **u-blox SimpleRTK2B** — validated end-to-end, the original
    tested baseline (raw capture, RINEX conversion, dual-cloud
    upload, compression, and the web dashboard in `shared` NMEA
    mode).
  - **Septentrio (SBF)** — validated end-to-end, including
    `GNSS_FORMAT=sbf` raw capture, RINEX conversion, and the web
    dashboard in **`NMEA_SOURCE_MODE=dedicated`** (Septentrio's USB
    interface exposes two independent virtual serial ports; raw SBF
    and NMEA were run on separate ports with no shared-stream
    filtering relay needed). This testing surfaced and fixed three
    real bugs — see **Issues found during Septentrio testing** below.
  - **NovAtel (OEM6/OEM7)** — implemented (RTKLIB
    supports the format, and `GNSS_FORMAT=nov` selects it, see
    [receiver-setup.md](receiver-setup.md)), but **not yet tested
    against real NovAtel hardware**.
- **Host OS:**
  - **Ubuntu Server** and **AlmaLinux** (RHEL-family) — validated.
  - **Debian** — proven via the original bare-metal deployment this
    project was containerized from.
  - **Arch Linux** — validated end-to-end (Septentrio testing above
    was performed on Arch). See [host-setup.md](host-setup.md) for
    Arch-specific host setup notes (`dialout` group, kernel module
    loading, `docker-buildx`) that don't apply on Ubuntu/Debian/RHEL.
  - Other distributions should work (Docker itself is the actual
    dependency, not the host distro) but haven't been explicitly
    tested.
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
- **Compression pipeline** (Hatanaka+gzip for RINEX, gzip for nav, zstd
  for raw): validated end-to-end in Docker on multiple host OSes
  against live receivers over multi-day continuous runs, including the
  `.obs.gz` fallback path. This testing surfaced and fixed two real
  issues beyond the compression logic itself — see
  [Compression](../README.md#compression) (an upstream RTKLIB bug)
  and [Upload efficiency](upload-efficiency.md) (a cloud
  transaction-cap issue). Retention cleanup was confirmed working
  correctly against live data with the upload-state-cache logic,
  deleting local files only after both remotes confirmed a copy.
- **Web dashboard** (`gnss2cloud-web`, optional, `profiles: ["web"]`):
  validated end-to-end against a live u-blox SimpleRTK2B in
  `NMEA_SOURCE_MODE=shared`, and against a live Septentrio receiver in
  `NMEA_SOURCE_MODE=dedicated` — filtered NMEA fan-out (GSV/VTG/GSA
  only), REST log/status API, WebSocket live feed, and both uptime
  indicators confirmed against real hardware in both modes, including
  a full RINEX-integrity check to confirm the fan-out doesn't affect
  the archival pipeline. **NovAtel has not been tested against the
  dashboard at all** — see
  [Known limitations](../README.md#known-limitations).

## Issues found during Septentrio/Arch testing

All three fixed and merged:

1. **`GNSS_FORMAT` wasn't reaching the container.** `docker-compose.yml`
   read it from `.env` for variable substitution but never listed it
   in the `gnss2cloud` service's `environment:` block, so it silently
   never propagated — raw capture defaulted to u-blox/UBX parsing
   regardless of what `.env` said.
2. **`NMEA_SOURCE_MODE=dedicated`'s device was not mapped into the
   container.** `docker-compose.yml`'s `devices:` list only ever
   included `/dev/gnss0`; `NMEA_DEVICE_PATH` (the second port) needs
   its own entry.
3. **`entrypoint.sh` built an invalid `serial://` URL for
   `NMEA_DEVICE_PATH`.** The variable is documented/set as a full path
   (`/dev/gnss_nmea0`), but `str2str`'s `serial://` scheme expects a
   bare device name relative to `/dev/` (matching `GNSS_DEVICE`'s
   existing convention) — the leading `/dev/` needs stripping before
   use, otherwise `str2str` crash-loops trying to open a
   double-prefixed path.
4. **`health_check.sh` hardcoded the `.ubx` extension** when checking
   for recent raw data, ignoring `GNSS_FORMAT` entirely. With a `.sbf`
   (or `.gps`, for NovAtel) raw file, its `find` never matched
   anything, producing a false "Device handle open but no recent
   data" alert even while capture was healthy and actively writing
   data. Fixed by deriving the expected extension from `GNSS_FORMAT`,
   the same mapping `entrypoint.sh` already used.

**Not yet implemented:** push notifications (e.g. ntfy.sh) for health
alerts — currently alerts are written to `logs/health.log` only.
Authentication for the web dashboard is also not yet implemented — see
[Web dashboard](../README.md#web-dashboard-optional-monitoring-only)
and [Known limitations](../README.md#known-limitations).
