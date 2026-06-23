# escape=`
# =============================================================================
# LabVIEW CI project dependency layer
# =============================================================================
# Starts from the shared LabVIEW + VIPM base image and applies only the staged
# project VIPC dependencies. VIPM and Git are expected to already be present in
# VIPM_BASE_IMAGE.
# =============================================================================
ARG VIPM_BASE_IMAGE
FROM ${VIPM_BASE_IMAGE}

SHELL ["powershell", "-NoLogo", "-NoProfile", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

ARG CI_WORKER_VERSION=dev
ARG VIPM_PUBLIC_REPO_URL=https://github.com/elijah286/LabVIEW-CI-with-Containers.git
ARG LVCI_UNIT_TESTS_INSTALLED=false

COPY .github/labview/vipm/ C:/vipm/

RUN $vipmExe = 'C:\Program Files\JKI\VI Package Manager\support\vipm.exe'; `
    if (-not (Test-Path $vipmExe)) { throw "VIPM was not found at $vipmExe. Rebuild the VIPM base image before applying the VIPC layer." }; `
    if ($env:LVCI_UNIT_TESTS_INSTALLED -ne 'true' -and -not $env:VIPM_REQUIRED_PACKAGES) { `
      $env:VIPM_REQUIRED_PACKAGES = '-'; `
      Write-Host 'Unit Tests capability is not installed; skipping UTF/JUnit-only required VIPM essentials.' `
    }; `
    $vipcFiles = Get-ChildItem -Path 'C:\vipm' -Filter '*.vipc' -Recurse -ErrorAction SilentlyContinue; `
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

ENV CI_WORKER_VERSION=${CI_WORKER_VERSION}
LABEL com.cotc.ci-worker.version=${CI_WORKER_VERSION} `
      com.cotc.ci-worker.platform=windows
