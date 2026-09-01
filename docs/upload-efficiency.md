# Upload efficiency

`upload_hourly.sh` was set to re-scan all locally-retained files every
hour so it's self-healing after any failure — but without care, this means
every file gets re-verified against the cloud via API call for the
**entire** local retention window (up to `MIN_AGE_HOURS`), every
single hour, not just once. In multi-day testing this was found to
generate enough Backblaze B2 "Class C" (list/metadata) transactions to
exceed B2's daily transaction cap, this can cause a real operational cost.

**Fix:** once a file is confirmed present on a given remote, a marker
is written to `logs/upload_state/` (e.g. `<filename>.r1.ok`). Future
runs skip the API check entirely for any file+remote combo already
marked, so steady-state cost scales with *new* files per hour, not the
whole retention window. `retention_cleanup.sh` reads the same markers
(a local filesystem check, no API calls) rather than re-verifying
remotes itself, and removes the markers alongside the data files once
both are deleted.

**Worth knowing if scaling to many stations on one cloud account:**
transaction caps are typically account-wide, not per-bucket/station —
running several stations against the same provider account multiplies
the load. Check your provider's transaction/API quota dashboard
(e.g. Backblaze B2's "Caps & Alerts" page) if running more than a
handful of stations on one account.
