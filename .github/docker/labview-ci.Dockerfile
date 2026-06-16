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

# Install the VI Analyzer support package AND verify its default TEST SUITE is on
# disk. The prebuilt nationalinstruments/labview base image registers
# ni-viawin-labview-support as "already installed" in the NIPKG database but has
# had the analyzer test libraries (project\_VI Analyzer\_tests\**\*.llb, ~90 tests)
# stripped to slim the image. A plain `nipkg install` then no-ops, the test files
# never materialize, and every VI Analyzer run reports "0 tests run" (empty report).
# So: install normally; if the test suite is not on disk, REMOVE then reinstall the
# package (which clears the "installed" DB flag and forces nipkg to re-fetch and
# re-lay every file from the feed); finally VERIFY the tests are present and FAIL the
# build if not — we must never publish a worker that silently analyzes nothing.
#
# ErrorActionPreference is set to Continue for this step: nipkg is a native command
# that writes progress/notices to stderr, and under the image's default 'Stop' that
# stderr would raise a terminating NativeCommandError and abort the build before our
# own verification logic runs. We gate success on the on-disk test count instead.
RUN $ErrorActionPreference = 'Continue'; `
    if (-not (Get-Command nipkg -ErrorAction SilentlyContinue)) { throw 'nipkg was not found in the LabVIEW base image.' }; `
    nipkg feed-add --name=$env:NIPM_FEED_NAME $env:NIPM_FEED_URL 2>&1 | Out-Host; `
    nipkg update 2>&1 | Out-Host; `
    nipkg install --accept-eulas -y $env:VIA_SUPPORT_PACKAGE 2>&1 | Out-Host; `
    $lvDir = (Get-ChildItem 'C:\Program Files\National Instruments' -Directory -Filter 'LabVIEW *' | Sort-Object Name -Descending | Select-Object -First 1).FullName; `
    $testsDir = Join-Path $lvDir 'project\_VI Analyzer\_tests'; `
    $count = if (Test-Path $testsDir) { @(Get-ChildItem -LiteralPath $testsDir -Recurse -Filter '*.llb' -ErrorAction SilentlyContinue).Count } else { 0 }; `
    Write-Host ('VI Analyzer test libraries after install: {0} (under {1})' -f $count, $testsDir); `
    if ($count -lt 1) { `
      Write-Host '=== Test suite missing on disk - removing then reinstalling the package to force a clean file lay-down ==='; `
      nipkg remove -y $env:VIA_SUPPORT_PACKAGE 2>&1 | Out-Host; `
      nipkg install --accept-eulas -y $env:VIA_SUPPORT_PACKAGE 2>&1 | Out-Host; `
      $count = if (Test-Path $testsDir) { @(Get-ChildItem -LiteralPath $testsDir -Recurse -Filter '*.llb' -ErrorAction SilentlyContinue).Count } else { 0 }; `
      Write-Host ('VI Analyzer test libraries after remove+install: {0}' -f $count); `
    }; `
    if ($count -lt 1) { `
      Write-Host '=== DIAGNOSTIC (tests still missing) ==='; `
      Write-Host '--- nipkg info for the support package ---'; `
      nipkg info $env:VIA_SUPPORT_PACKAGE 2>&1 | Out-Host; `
      Write-Host '--- installed packages mentioning via/analy/test ---'; `
      (nipkg list 2>&1 | Select-String -Pattern 'via|analy|test') | Out-Host; `
      Write-Host '--- contents of project\_VI Analyzer (what DID get laid down) ---'; `
      if (Test-Path (Join-Path $lvDir 'project\_VI Analyzer')) { Get-ChildItem -LiteralPath (Join-Path $lvDir 'project\_VI Analyzer') -Recurse -ErrorAction SilentlyContinue | Select-Object -First 40 -ExpandProperty FullName | Out-Host }; `
      throw ('VI Analyzer test suite not found under ' + $testsDir + ' after install + remove/reinstall - the worker would run 0 tests, so failing the build.'); `
    }; `
    Write-Host ('VI Analyzer test suite present: {0} test libraries.' -f $count); `
    if (Test-Path 'C:\ProgramData\National Instruments\NI Package Manager\cache') { `
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
