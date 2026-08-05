#!/bin/bash
set -e

# Start the scheduler in the background as the unprivileged 'gnss' user
# (already the case, since this whole container runs as 'gnss', not root).
supercronic /etc/gnss2cloud.cron >> /data/logs/supercronic.log 2>&1 &

# str2str becomes the container's main (PID 1) process. If it exits,
# Docker's restart policy (set in docker-compose.yml) brings it back.
exec str2str -in serial://${GNSS_DEVICE}:${GNSS_BAUD} \
    -out file:///data/raw/%Y%m%d%h.ubx::S=1
