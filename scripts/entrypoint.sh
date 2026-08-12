#!/bin/bash
set -e
# Start the scheduler as a fully detached background session (setsid),
# with explicit stdin/stdout/stderr redirection. Without this, str2str's
# continuous \r-based status output was found to leak into supercronic's
# log stream once str2str became PID 1 via exec below, blocking job
# logging (and effectively scheduling) for up to ~45 minutes at a time.
setsid supercronic /etc/gnss2cloud.cron \
    < /dev/null >> /data/logs/supercronic.log 2>&1 &
# str2str becomes the container's main (PID 1) process. If it exits,
# Docker's restart policy (set in docker-compose.yml) brings it back.
exec str2str -in serial://${GNSS_DEVICE}:${GNSS_BAUD} \
    -out file:///data/raw/%Y%m%d%h.ubx::S=1
