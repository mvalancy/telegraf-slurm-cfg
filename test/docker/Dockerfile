# A single-node Slurm cluster WITH slurmdbd (so sacct has real data) for testing
# these collectors against real Slurm. The Slurm version comes from the base
# image's packages — change BASE to test a different version:
#
#   ubuntu:22.04 -> Slurm 21.08   (no sdiag --json)
#   debian:12    -> Slurm 22.05
#   ubuntu:24.04 -> Slurm 23.11   (sdiag --json works)
#   debian:13    -> Slurm 24.11
#
# Built and driven by ../docker-test.sh — not meant to be run by hand.
ARG BASE=ubuntu:24.04
FROM ${BASE}

ARG TELEGRAF_VERSION=1.33.1
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      slurm-wlm slurmdbd munge mariadb-server procps curl iproute2 ca-certificates \
 && curl -fsSL -o /tmp/telegraf.tar.gz \
      "https://dl.influxdata.com/telegraf/releases/telegraf-${TELEGRAF_VERSION}_linux_amd64.tar.gz" \
 && tar -xzf /tmp/telegraf.tar.gz -C /tmp \
 && cp "$(find /tmp -type f -name telegraf | head -1)" /usr/local/bin/telegraf \
 && rm -rf /tmp/telegraf* /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
