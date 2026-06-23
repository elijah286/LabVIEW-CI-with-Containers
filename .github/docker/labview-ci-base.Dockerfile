# escape=`
# =============================================================================
# LabVIEW CI Windows base image
# =============================================================================
# Source-owned LCWC base layer for expensive Windows LabVIEW CI tooling. Client
# repositories copy/tag this image into their own GHCR worker package when they
# have no repo-specific VIPC dependencies, or build only a thin VIPC layer from
# it when they do.
# =============================================================================
FROM nationalinstruments/labview:latest-windows

SHELL ["powershell", "-NoLogo", "-NoProfile", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

ARG NIPM_FEED_NAME=LV2026
ARG NIPM_FEED_URL=https://download.ni.com/support/nipkg/products/ni-l/ni-labview-2026/26.1/released
ARG VIA_SUPPORT_PACKAGE=ni-viawin-labview-support

RUN if (-not (Get-Command nipkg -ErrorAction SilentlyContinue)) { throw 'nipkg was not found in the LabVIEW base image.' }; `
    nipkg feed-add --name=$env:NIPM_FEED_NAME $env:NIPM_FEED_URL; `
    nipkg update; `
    nipkg install --accept-eulas -y $env:VIA_SUPPORT_PACKAGE; `
    if (Test-Path 'C:\ProgramData\National Instruments\NI Package Manager\cache') { `
      Remove-Item -Path 'C:\ProgramData\National Instruments\NI Package Manager\cache\*' -Force -Recurse -ErrorAction SilentlyContinue `
    }

ARG UTF_FEED_NAME=LVUTF
ARG UTF_FEED_URL=https://download.ni.com/support/nipkg/products/ni-l/ni-labview-unit-test-framework-toolkit/25.1/released
ARG UTF_FEED_CRITICAL_NAME=LVUTFcritical
ARG UTF_FEED_CRITICAL_URL=https://download.ni.com/support/nipkg/products/ni-l/ni-labview-unit-test-framework-toolkit/25.1/released-critical
ARG UTF_SUPPORT_PACKAGE=ni-utf-labview-support
ARG UTF_PACKAGE=
RUN $ErrorActionPreference = 'Continue'; `
    Write-Host "Adding NI Unit Test Framework toolkit feed: $env:UTF_FEED_URL"; `
    nipkg feed-add --name=$env:UTF_FEED_NAME $env:UTF_FEED_URL; `
    if ($env:UTF_FEED_CRITICAL_URL) { `
      Write-Host "Adding NI Unit Test Framework toolkit feed (critical): $env:UTF_FEED_CRITICAL_URL"; `
      nipkg feed-add --name=$env:UTF_FEED_CRITICAL_NAME $env:UTF_FEED_CRITICAL_URL `
    }; `
    nipkg update; `
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

ARG VIPM_INSTALLER_URL=https://traffic.libsyn.com/secure/jkinc/vipm-26.3.3954-windows-setup.exe
RUN $ErrorActionPreference = 'Continue'; `
    $vipmSetup = Join-Path $env:TEMP 'vipm-setup.exe'; `
    Write-Host "Downloading VIPM 2026 Q3 installer: $env:VIPM_INSTALLER_URL"; `
    try { `
      Invoke-WebRequest -Uri $env:VIPM_INSTALLER_URL -OutFile $vipmSetup -UseBasicParsing; `
      Write-Host ('Downloaded {0:N1} MB; installing VIPM silently (/exenoui /qn) ...' -f ((Get-Item $vipmSetup).Length / 1MB)); `
      $p = Start-Process -Wait -PassThru -FilePath $vipmSetup -ArgumentList '/exenoui','/qn'; `
      Write-Host "VIPM installer exit code: $($p.ExitCode)"; `
      if ($p.ExitCode -ne 0) { Write-Host "::warning::VIPM 2026 Q3 installer returned exit $($p.ExitCode); VIPM-distributed add-ons may not be baked in." } `
    } catch { `
      Write-Host "::warning::VIPM 2026 Q3 install failed ($($_.Exception.Message)); VIPM-distributed add-ons will not be baked in." `
    } finally { `
      Remove-Item $vipmSetup -Force -ErrorAction SilentlyContinue `
    }

ARG GIT_INSTALLER_URL=https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/Git-2.54.0-64-bit.exe
ARG GIT_MINGIT_URL=https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/MinGit-2.54.0-64-bit.zip
RUN $ErrorActionPreference = 'Continue'; `
    function Add-MachinePath([string] $dir) { `
      $mp = [Environment]::GetEnvironmentVariable('Path','Machine'); `
      if ($mp -notlike ('*' + $dir + '*')) { [Environment]::SetEnvironmentVariable('Path', $dir + ';' + $mp, 'Machine') }; `
      $env:Path = $dir + ';' + $env:Path `
    }; `
    function Test-GitOk { try { $v = & git --version 2>$null; return ($LASTEXITCODE -eq 0 -and $v) } catch { return $false } }; `
    $ok = $false; `
    if (Get-Command winget -ErrorAction SilentlyContinue) { `
      Write-Host 'Installing Git via winget (Git.Git) ...'; `
      try { `
        & winget install -e --id Git.Git --accept-source-agreements --accept-package-agreements --silent --disable-interactivity; `
        Add-MachinePath 'C:\Program Files\Git\cmd'; `
        $ok = Test-GitOk `
      } catch { Write-Host ('winget Git install failed: ' + $_.Exception.Message) } `
    } else { Write-Host 'winget is not available in this base image; using the Git-for-Windows installer instead.' }; `
    if (-not $ok) { `
      $exe = Join-Path $env:TEMP 'git-setup.exe'; `
      try { `
        Write-Host "Downloading Git for Windows from $env:GIT_INSTALLER_URL"; `
        Invoke-WebRequest -Uri $env:GIT_INSTALLER_URL -OutFile $exe -UseBasicParsing; `
        Write-Host ('Downloaded {0:N1} MB; installing silently ...' -f ((Get-Item $exe).Length / 1MB)); `
        Start-Process -FilePath $exe -ArgumentList '/VERYSILENT','/NORESTART','/SP-','/SUPPRESSMSGBOXES','/NOCANCEL' -Wait; `
        Add-MachinePath 'C:\Program Files\Git\cmd'; `
        $ok = Test-GitOk `
      } catch { Write-Host ('Git-for-Windows installer failed: ' + $_.Exception.Message) } finally { Remove-Item $exe -Force -ErrorAction SilentlyContinue } `
    }; `
    if (-not $ok) { `
      $gitZip = Join-Path $env:TEMP 'mingit.zip'; `
      try { `
        Write-Host "Falling back to portable MinGit from $env:GIT_MINGIT_URL"; `
        Invoke-WebRequest -Uri $env:GIT_MINGIT_URL -OutFile $gitZip -UseBasicParsing; `
        Expand-Archive -Path $gitZip -DestinationPath 'C:\git' -Force; `
        Add-MachinePath 'C:\git\cmd'; `
        $ok = Test-GitOk `
      } catch { Write-Host ('MinGit fallback failed: ' + $_.Exception.Message) } finally { Remove-Item $gitZip -Force -ErrorAction SilentlyContinue } `
    }; `
    if ($ok) { Write-Host ('Installed Git: ' + (& git --version)) } `
    else { Write-Host '::warning::No Git could be installed; VIPM Community Edition cannot verify repository visibility.' }

LABEL com.cotc.ci-base.kind=labview-ci `
      com.cotc.ci-base.platform=windows