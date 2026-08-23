# Changelog
See README for further details.

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
