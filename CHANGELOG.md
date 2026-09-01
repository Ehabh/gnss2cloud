# Changelog

## [0.5.0] - 2026-08-31
- Added a live web dashboard: real-time CN0 view, satellite
  and status info, fed via a new NMEA bridge service
  (`NMEA_SOURCE_MODE=shared` or `dedicated`).
- Validated the full pipeline end-to-end on Septentrio (SBF) hardware
  and Arch Linux as a host, both previously untested.
- Fixed four bugs found during that validation: `GNSS_FORMAT` not
  reaching the container, the dedicated NMEA device not being mapped
  in correctly, an invalid `serial://` URL in `entrypoint.sh`, and
  `health_check.sh` hardcoding the `.ubx` extension.
- Addressed Trivy-flagged vulnerabilities in `gnss2cloud-web` and
  `gnss2cloud`'s `supercronic` binary.
- Reorganized documentation into `docs/`, with new Arch Linux and
  receiver-specific (Septentrio, NovAtel) setup guidance.

## [0.4.0] - 2026-08-22
- Added compression before upload: RINEX obs → Hatanaka+gzip
  (`.crx.gz`, fallback `.obs.gz`), nav → gzip, raw → zstd.
- Added upload-state cache to avoid re-checking confirmed files
  against cloud remotes every hour.
- Fixed a RTKLIB `convbin` bug causing duplicate satellites in u-blox
  data — switched to the `rtklibexplorer/RTKLIB` fork.
- Fixed a cloud transaction-cap issue caused by redundant hourly
  remote checks.

## [0.3.1] - 2026-08-20
- Fixed a bug that silently broke `retention_cleanup.sh`'s main loop.

## [0.3.0] - 2026-08-17
- Added documentation for tested platforms and receiver support.
