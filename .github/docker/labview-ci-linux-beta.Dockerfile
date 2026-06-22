# syntax=docker/dockerfile:1.7
# =============================================================================
# LabVIEW CI Linux Beta image
# =============================================================================
# Isolated Linux worker lane for proving VIPM/VIPC support without changing the
# stable Linux container path used by existing Linux actions.
# =============================================================================

ARG VIPM_DEB_URL=https://traffic.libsyn.com/secure/jkinc/vipm_26.3.0-3954_amd64.deb

FROM nationalinstruments/labview:latest-linux

ARG VIPM_DEB_URL
ARG CI_WORKER_VERSION=dev
ARG LABVIEW_VERSION=2026

COPY .github/labview/vipm/install-vipc-linux.sh /opt/lvci/vipm/install-vipc-linux.sh
COPY .github/labview/vipm-linux/ /opt/lvci/vipc/

RUN set -eux; \
    chmod +x /opt/lvci/vipm/install-vipc-linux.sh; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl xvfb; \
    curl -fL --retry 3 --retry-delay 2 -o /tmp/vipm.deb "${VIPM_DEB_URL}"; \
    dpkg -i /tmp/vipm.deb || apt-get install -f -y --no-install-recommends; \
    rm -f /tmp/vipm.deb; \
    rm -rf /var/lib/apt/lists/*; \
    command -v vipm; \
    vipm --version || true

RUN --mount=type=secret,id=vipm_serial,required=false \
    --mount=type=secret,id=vipm_full_name,required=false \
    --mount=type=secret,id=vipm_email,required=false \
    set -eux; \
    if [ -f /run/secrets/vipm_serial ]; then export VIPM_SERIAL_NUMBER="$(cat /run/secrets/vipm_serial)"; fi; \
    if [ -f /run/secrets/vipm_full_name ]; then export VIPM_FULL_NAME="$(cat /run/secrets/vipm_full_name)"; fi; \
    if [ -f /run/secrets/vipm_email ]; then export VIPM_EMAIL="$(cat /run/secrets/vipm_email)"; fi; \
    export VIPC_DIR=/opt/lvci/vipc; \
    export LABVIEW_VERSION="${LABVIEW_VERSION}"; \
    /opt/lvci/vipm/install-vipc-linux.sh

ENV CI_WORKER_VERSION=${CI_WORKER_VERSION}
LABEL com.cotc.ci-worker.version=${CI_WORKER_VERSION} \
      com.cotc.ci-worker.platform=linux-beta
