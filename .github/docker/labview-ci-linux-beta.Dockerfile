# syntax=docker/dockerfile:1.7
# =============================================================================
# LabVIEW CI Linux Beta image
# =============================================================================
# Isolated Linux worker lane for proving VIPM/VIPC support without changing the
# stable Linux container path used by existing Linux actions.
# =============================================================================

ARG NIPM_FEED_URL=https://download.ni.com/support/nipkg/products/ni-l/ni-labview-2026/26.1/released
ARG VIPM_FEED_URL=https://download.ni.com/support/nipkg/products/ni-v/ni-vipm/26.1/released
ARG VIA_SUPPORT_PACKAGE=ni-vialin-labview-support
ARG VIPM_PACKAGE=ni-vipm

FROM nationalinstruments/labview:latest-linux

ARG NIPM_FEED_URL
ARG VIPM_FEED_URL
ARG VIA_SUPPORT_PACKAGE
ARG VIPM_PACKAGE
ARG CI_WORKER_VERSION=dev
ARG LABVIEW_VERSION=2026

COPY .github/labview/vipm/install-vipc-linux.sh /opt/lvci/vipm/install-vipc-linux.sh
COPY .github/labview/vipm-linux/ /opt/lvci/vipc/

RUN set -eux; \
    chmod +x /opt/lvci/vipm/install-vipc-linux.sh; \
    NIPKG_BIN="$(command -v nipkg 2>/dev/null || find /usr /opt -type f -name nipkg -perm -111 2>/dev/null | head -n 1 || true)"; \
    if [ -n "${NIPKG_BIN}" ]; then \
        echo "Using nipkg: ${NIPKG_BIN}"; \
        echo "Adding nipkg feed: ${NIPM_FEED_URL}"; \
        "${NIPKG_BIN}" feed-add --name=ni-labview-ci-beta "${NIPM_FEED_URL}" || true; \
        "${NIPKG_BIN}" update; \
        echo "Installing Linux worker packages with nipkg: ${VIA_SUPPORT_PACKAGE} ${VIPM_PACKAGE}"; \
        "${NIPKG_BIN}" install --accept-eulas --no-progress "${VIA_SUPPORT_PACKAGE}"; \
        "${NIPKG_BIN}" install --accept-eulas --no-progress "${VIPM_PACKAGE}"; \
    elif command -v apt-get >/dev/null 2>&1; then \
        echo "nipkg was not found; installing Linux worker packages with apt: ${VIA_SUPPORT_PACKAGE} ${VIPM_PACKAGE}"; \
        export DEBIAN_FRONTEND=noninteractive; \
        apt-get update; \
        if apt-get install -y --no-install-recommends "${VIA_SUPPORT_PACKAGE}" "${VIPM_PACKAGE}"; then \
            rm -rf /var/lib/apt/lists/*; \
        else \
            echo "apt-get could not install ${VIA_SUPPORT_PACKAGE} or ${VIPM_PACKAGE}. Collecting Linux package discovery diagnostics."; \
            echo "Apt sources:"; \
            find /etc/apt -maxdepth 3 -type f \( -name '*.list' -o -name '*.sources' \) -print -exec sed -n '1,80p' {} \; || true; \
            echo "apt-cache search results:"; \
            apt-cache search 'ni-.*\(vipm\|vialin\|labview\)' || true; \
            echo "Installed NI Debian packages:"; \
            dpkg-query -W -f='${Package} ${Version}\n' 2>/dev/null | grep -E '^(ni-|nipkg|labview)' | sort | head -n 200 || true; \
            echo "NI Package Manager feed architecture summaries:"; \
            apt-get install -y --no-install-recommends ca-certificates curl >/dev/null 2>&1 || true; \
            for FEED in "${NIPM_FEED_URL}" "${VIPM_FEED_URL}"; do \
                echo "Feed: ${FEED}"; \
                if command -v curl >/dev/null 2>&1; then \
                    curl -fsSL "${FEED}/Packages" | grep '^Architecture:' | sort | uniq -c || true; \
                    curl -fsSL "${FEED}/Packages" | grep -E '^(Package: (ni-vipm|ni-vialin-labview-support)|Architecture:)' | head -n 80 || true; \
                else \
                    echo "curl unavailable for feed inspection"; \
                fi; \
            done; \
            echo "Linux Beta cannot install VIPM from the tested package sources until NI publishes a Linux VIPM package or the base image includes nipkg/VIPM."; \
            exit 127; \
        fi; \
    else \
        echo "No supported package manager found for Linux worker packages."; \
        command -v dpkg || true; \
        command -v rpm || true; \
        find /usr /opt -maxdepth 4 -type f \( -name 'nipkg*' -o -name '*package*manager*' \) 2>/dev/null | sort | head -n 50 || true; \
        exit 127; \
    fi

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
