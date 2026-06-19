# escape=`
# =============================================================================
# LabVIEW CI image for challenge-of-champions
# =============================================================================
# Extends the official NI LabVIEW Windows container (LabVIEW 2026) with the VI
# Analyzer support package (ni-viawin-labview-support), which provides the full
# default VI Analyzer test set (~90 tests). Without this package the analyzer
# reports "0 tests run".
#
# Project VIPM dependencies (OpenG — used by only a handful of VIs) are
# intentionally NOT baked in: every project VI already loads on the bare NI base
# image (the snapshot pipeline renders all 222 VIs there), so the analyzer can
# load and test them without applying the .vipc, keeping the build fast and
# reliable.
#
# Third-party add-ons that ARE wanted in the image (e.g. Antidoc — Wovalab's
# LabVIEW code-documentation generator, package wovalab_lib_antidoc_cli) are
# installed through the VIPM hook below: stage an Antidoc .vipc under
# .github/labview/vipm/ and it is applied at image-build time. VIPM is a
# Windows-only application, so Antidoc-based documentation CI runs on this
# Windows image, not the Linux one.
# =============================================================================
FROM nationalinstruments/labview:latest-windows

SHELL ["powershell", "-NoLogo", "-NoProfile", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

# Feed/package values are ARGs so they are explicit and easy to revise per LabVIEW major version.
ARG NIPM_FEED_NAME=LV2026
ARG NIPM_FEED_URL=https://download.ni.com/support/nipkg/products/ni-l/ni-labview-2026/26.1/released
ARG VIA_SUPPORT_PACKAGE=ni-viawin-labview-support

# Worker version: a short content hash of the build inputs (this Dockerfile +
# install-vipc.ps1 + any applied *.vipc), computed by the build workflow and
# passed in here. It is stamped into the image (env + label) so any CI job can
# read back exactly which worker it pulled and link to that worker's manifest on
# the dashboard. Defaults to 'dev' for local/ad-hoc builds.
ARG CI_WORKER_VERSION=dev

# VIPC automation assets. install-vipc.ps1 plus any *.vipc are staged here; the
# build workflow also copies repo-root *.vipc (e.g. "COTC Dependencies.vipc")
# into .github/labview/vipm/ before the build, so "a repo that features a .vipc"
# gets that configuration baked into the Windows worker automatically. With no
# .vipc staged the VIPM hook below is a no-op.
COPY .github/labview/vipm/ C:/vipm/

# Install the VI Analyzer support package (ni-viawin-labview-support). This package
# makes the full default VI Analyzer test configuration available to the analyzer,
# which run-vi-analyzer.ps1 invokes in "directory mode" (passing the workspace
# directory as -ConfigPath runs that full default suite against every VI). nipkg
# install is idempotent — if the package is already present in the base image it
# exits cleanly.
RUN if (-not (Get-Command nipkg -ErrorAction SilentlyContinue)) { throw 'nipkg was not found in the LabVIEW base image.' }; `
    nipkg feed-add --name=$env:NIPM_FEED_NAME $env:NIPM_FEED_URL; `
    nipkg update; `
    nipkg install --accept-eulas -y $env:VIA_SUPPORT_PACKAGE; `
    if (Test-Path 'C:\ProgramData\National Instruments\NI Package Manager\cache') { `
      Remove-Item -Path 'C:\ProgramData\National Instruments\NI Package Manager\cache\*' -Force -Recurse -ErrorAction SilentlyContinue `
    }

# Install the NI Unit Test Framework (UTF) so the headless unit-test runner can
# execute the project's .lvtest files (run-unit-tests.ps1 drives the built-in
# 'LabVIEWCLI -OperationName RunUnitTests' operation that ships with the LabVIEW
# command line interface). UTF is
# an NI add-on (not on VIPM); it installs from the same NI Package Manager feed as the
# VI Analyzer support package above. The package is PINNED by name - ni-utf-labview-support,
# the UTF analog of ni-viawin-labview-support - exactly like the VI Analyzer install. A
# UTF_PACKAGE build-arg overrides the name for other feeds, and if the pinned install
# fails the build falls back to discovering a unit-test-framework / utf-labview-support
# package on the feed. This step is BEST-EFFORT and never fails the build: if UTF cannot
# be installed it emits a ::warning:: and the unit-test runner degrades gracefully (it
# reports "no tests found" without UTF).
ARG UTF_SUPPORT_PACKAGE=ni-utf-labview-support
ARG UTF_PACKAGE=
RUN $ErrorActionPreference = 'Continue'; `
    $pkg = if ($env:UTF_PACKAGE) { $env:UTF_PACKAGE } else { $env:UTF_SUPPORT_PACKAGE }; `
    Write-Host "Installing NI Unit Test Framework package: $pkg"; `
    nipkg install --accept-eulas -y $pkg; `
    if ($LASTEXITCODE -ne 0) { `
      Write-Host "::warning::UTF package '$pkg' did not install (exit $LASTEXITCODE); searching the feed for an alternative."; `
      $alt = @(nipkg list-available 2>$null) | Where-Object { $_ -match '(?i)(utf-labview-support|unit.?test.?framework)' } | ForEach-Object { (([string]$_).Trim() -split '\s+')[0] } | Select-Object -First 1; `
      if ($alt) { Write-Host "Retrying with discovered package: $alt"; nipkg install --accept-eulas -y $alt } `
    }; `
    if ($LASTEXITCODE -ne 0) { `
      Write-Host "::warning::NI Unit Test Framework could not be installed; the unit-test runner will report 'no tests found'. Pin the name with the UTF_PACKAGE build-arg and rebuild." `
    } elseif (Test-Path 'C:\ProgramData\National Instruments\NI Package Manager\cache') { `
      Remove-Item -Path 'C:\ProgramData\National Instruments\NI Package Manager\cache\*' -Force -Recurse -ErrorAction SilentlyContinue `
    }

# Install VIPM (the JKI VI Package Manager) from the NI Package Manager feed so the
# VIPC hook below can bake in VIPM-distributed add-ons - Antidoc, Caraya, VI Tester,
# and crucially the "UTF JUnit Report" library (ni_lib_utf_junit_report) that the
# built-in 'LabVIEWCLI -OperationName RunUnitTests' operation links against to emit
# its JUnit results file (without it RunUnitTests fails with LabVIEW CLI error -350053).
# VIPM was previously fetched by install-vipc.ps1 from an external JKI installer URL,
# but that URL now 404s (and the replacement is auth-gated). NI publishes VIPM on the
# SAME feed as the support packages above (package 'ni-vipm'), so installing it here is
# fully reproducible and needs no external, auth-gated download; install-vipc.ps1 then
# finds vipm.exe already present and skips its (dead) download path. BEST-EFFORT: a
# failure emits a ::warning:: and leaves the core image (LabVIEW + VI Analyzer + UTF)
# intact - only VIPM-distributed add-ons are then absent.
ARG VIPM_PACKAGE=ni-vipm
RUN $ErrorActionPreference = 'Continue'; `
    Write-Host "Installing VIPM from the NI feed: $env:VIPM_PACKAGE"; `
    nipkg install --accept-eulas -y $env:VIPM_PACKAGE; `
    if ($LASTEXITCODE -ne 0) { `
      Write-Host "::warning::VIPM package '$($env:VIPM_PACKAGE)' did not install (exit $LASTEXITCODE); VIPM-distributed add-ons (including the UTF JUnit Report library) will not be baked in." `
    } elseif (Test-Path 'C:\ProgramData\National Instruments\NI Package Manager\cache') { `
      Remove-Item -Path 'C:\ProgramData\National Instruments\NI Package Manager\cache\*' -Force -Recurse -ErrorAction SilentlyContinue `
    }

# Optional VIPC support hook. If .vipc files exist, an installer script must be
# present so dependencies are handled explicitly.
RUN $vipcFiles = Get-ChildItem -Path 'C:\vipm' -Filter '*.vipc' -Recurse -ErrorAction SilentlyContinue; `
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
