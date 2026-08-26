FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git build-essential ca-certificates curl unzip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt
RUN git clone --branch main https://github.com/rtklibexplorer/RTKLIB.git \
    && cd RTKLIB && git checkout 3aedf054706095885e81e2f4adb7b34305c9200a
RUN cd /opt/RTKLIB/app/consapp/str2str/gcc && make
RUN cd /opt/RTKLIB/app/consapp/convbin/gcc && make

WORKDIR /opt
RUN git clone --depth 1 https://github.com/satoshi-pes/RNXCMP.git
RUN cd /opt/RNXCMP/source \
    && gcc -O2 -o rnx2crx rnx2crx.c \
    && gcc -O2 -o crx2rnx crx2rnx.c
    
# --- rclone (official static binary) ---
RUN curl https://rclone.org/install.sh | bash

# --- supercronic: non-root cron replacement (no root daemon needed) ---
ARG TARGETARCH
ARG SUPERCRONIC_VERSION=v0.2.48
RUN curl -fsSL -o /usr/local/bin/supercronic \
    "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${TARGETARCH}" \
    && chmod +x /usr/local/bin/supercronic

# ==========================================================================
FROM debian:bookworm-slim

# lsof/fuser not required at runtime - health check reads /proc directly.
# logrotate here runs as the non-root 'gnss' user (no `su` directive
# needed in its config) since /data/logs is entirely owned by that user -
# this only works because there's a single in-container user; see the
# bare-metal README notes if adapting this for a multi-user host setup.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates logrotate zstd socat \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/RTKLIB/app/consapp/str2str/gcc/str2str /usr/local/bin/str2str
COPY --from=builder /opt/RTKLIB/app/consapp/convbin/gcc/convbin /usr/local/bin/convbin
COPY --from=builder /usr/bin/rclone /usr/local/bin/rclone
COPY --from=builder /usr/local/bin/supercronic /usr/local/bin/supercronic
COPY --from=builder /opt/RNXCMP/source/rnx2crx /usr/local/bin/rnx2crx
COPY --from=builder /opt/RNXCMP/source/crx2rnx /usr/local/bin/crx2rnx

# --- Non-root user. Override at build time with --build-arg if your host
# user's UID/GID differ (check with `id` on the host) so bind-mounted
# files come out owned correctly instead of showing as a foreign UID. ---
ARG PUID=1000
ARG PGID=1000
RUN groupadd -g "${PGID}" gnss \
    && useradd -u "${PUID}" -g "${PGID}" -m -s /bin/bash gnss

COPY scripts/ /usr/local/bin/
RUN chmod +x /usr/local/bin/*.sh

COPY cron/gnss2cloud.cron /etc/gnss2cloud.cron
COPY logrotate/gnss2cloud-logrotate.conf /etc/gnss2cloud-logrotate.conf

RUN mkdir -p /data/raw /data/rinex /data/logs \
    && chown -R gnss:gnss /data

USER gnss
WORKDIR /home/gnss

ENV GNSS_DEVICE=gnss0
ENV GNSS_BAUD=460800

HEALTHCHECK --interval=2m --timeout=10s --retries=3 \
    CMD find /data/raw -type f -mmin -15 | grep -q . || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
