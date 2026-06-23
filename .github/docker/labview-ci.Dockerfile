# escape=`
# =============================================================================
# LabVIEW CI final worker image
# =============================================================================
# Starts from the public LCWC base image, then applies only this repository's
# optional VIPC dependency layer and worker-version labels. Repositories with no
# selected VIPC files skip this build and simply tag/push the LCWC base image as
# their own worker image.
# =============================================================================
ARG LCWC_BASE_IMAGE=ghcr.io/elijah286/labview-ci-with-containers-labview-base:2026
FROM ${LCWC_BASE_IMAGE}

SHELL ["powershell", "-NoLogo", "-NoProfile", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

# Worker version: a short content hash of the build inputs (this Dockerfile +
# install-vipc.ps1 + any applied *.vipc), computed by the build workflow and
# passed in here. It is stamped into the image (env + label) so any CI job can
# read back exactly which worker it pulled and link to that worker's manifest on
# the dashboard. Defaults to 'dev' for local/ad-hoc builds.
ARG CI_WORKER_VERSION=dev
ARG VIPM_PUBLIC_REPO_URL=https://github.com/elijah286/LabVIEW-CI-with-Containers.git
ARG LVCI_UNIT_TESTS_INSTALLED=false

# VIPC automation assets. install-vipc.ps1 plus any *.vipc are staged here; the
# build workflow also copies repo-root *.vipc (e.g. "COTC Dependencies.vipc")
# into .github/labview/vipm/ before the build, so "a repo that features a .vipc"
# gets that configuration baked into the Windows worker automatically. With no
# .vipc staged the VIPM hook below is a no-op.
COPY .github/labview/vipm/ C:/vipm/

# Optional VIPC support hook. If .vipc files exist, an installer script must be
# present so dependencies are handled explicitly.
# VIPM 26.3 Community Edition only installs when the working dir is inside a PUBLIC
# Git repository, so install-vipc.ps1 runs the installs from a minimal .git context
# whose origin points at this build arg (default: this public worker repo). The
# build workflow passes the actual building repo's URL so forks use their own.
ARG VIPM_PUBLIC_REPO_URL=https://github.com/elijah286/LabVIEW-CI-with-Containers.git
RUN $vipcFiles = Get-ChildItem -Path 'C:\vipm' -Filter '*.vipc' -Recurse -ErrorAction SilentlyContinue; `
    if ($env:LVCI_UNIT_TESTS_INSTALLED -ne 'true' -and -not $env:VIPM_REQUIRED_PACKAGES) { `
      $env:VIPM_REQUIRED_PACKAGES = '-'; `
      Write-Host 'Unit Tests capability is not installed; skipping UTF/JUnit-only required VIPM essentials.' `
    }; `
    if ($vipcFiles -and $vipcFiles.Count -gt 0) { `
      if (Test-Path 'C:\vipm\install-vipc.ps1') { `
        Write-Host 'VIPC files detected. Running C:\vipm\install-vipc.ps1 ...'; `
        powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File 'C:\vipm\install-vipc.ps1' `
      } else { `
        throw 'VIPC files were detected in C:\vipm but install-vipc.ps1 was not provided.' `
      } `
    } else { `
      Write-Host 'No VIPC dependencies were provided. Skipping VIPM install hook.' `
    }

# Stamp the worker version so any consuming CI job can read it back from the
# pulled image (docker inspect / env) and link the dashboard to this worker's
# published manifest. ENV survives into `docker run`; LABEL is queryable without
# starting a container.
ENV CI_WORKER_VERSION=${CI_WORKER_VERSION}
LABEL com.cotc.ci-worker.version=${CI_WORKER_VERSION} `
      com.cotc.ci-worker.platform=windows
