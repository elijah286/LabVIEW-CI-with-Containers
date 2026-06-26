<#
.SYNOPSIS
    Mass Compile a set of revisions using ONE warm Windows LabVIEW container.

.DESCRIPTION
    Windows-container "batch" counterpart of masscompile-windows-container.yml.
    Instead of starting a fresh container per revision (the standard per-commit
    job), this starts a SINGLE long-lived container and renders each requested
    revision via `docker exec`, so the multi-GB image pull and LabVIEW cold-start
    are paid ONCE for the whole batch rather than once per revision. For a large
    history that turns N×(startup+compile) into startup+N×compile.

    Trade-off (the reason this is opt-in and never the default): the container's
    mutable state — temp files, the LabVIEW object cache, the registry — carries
    over from one revision to the next inside the batch. A revision whose code
    modifies the system can therefore influence a later revision's result. The
    container IMAGE is never modified; only this short-lived instance accumulates
    state, and it is destroyed when the batch ends.

    A single container is started and kept warm; each revision is compiled via
    `docker exec` (no per-commit container churn or image re-pull). Reports are
    staged deploy-ready under:
        <OutRoot>\<sha>\index.html  summary.json  masscompile.log
    then published with keep_files semantics into gh-pages masscompile/<sha>/.

.NOTES
    'Continue' (not 'Stop') is deliberate: git/docker write progress to stderr,
    which WinPS 5.1 would otherwise turn into terminating NativeCommandErrors.
    Success is judged by output presence ($OutRoot\<sha>\summary.json).
#>
param(
    [string]$WorkspaceRoot     = (Get-Location).Path,
    [string]$OutRoot           = '',
    [string]$Image             = 'nationalinstruments/labview:latest-windows',
    # Explicit revisions to compile (space / comma / newline separated, full or
    # abbreviated SHAs). Blank = walk every project-touching commit in history.
    [string]$Shas              = '',
    [int]   $MaxCommits        = 0,
    # Re-render even revisions whose report is already deployed (ignore skip list).
    [switch]$Force,
    # File listing already-deployed report paths (one per line, e.g.
    # 'masscompile/<sha>/summary.json'). Used to skip done revisions.
    [string]$SkipListPath      = '',
    [int]   $TimeBudgetMinutes = 300,
    [string]$LabVIEWPath       = 'C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe',
    [string]$Repo              = $env:GITHUB_REPOSITORY,
    [string]$PagesUrl          = '',
    [string]$LabVIEWVersion    = '2026'
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$WorkspaceRoot = (Resolve-Path $WorkspaceRoot).Path
if ($OutRoot -eq '') { $OutRoot = Join-Path $WorkspaceRoot 'ci-out\masscompile-backfill' }
$OpsHost = Join-Path $WorkspaceRoot '.github\labview'

$TempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$WorkTreesHost = Join-Path $TempRoot 'lvci-mc-wt'
New-Item -ItemType Directory -Force -Path $OutRoot, $WorkTreesHost | Out-Null

$ContainerName = "lvci-mc-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ── Resolve the revision list, oldest first ──────────────────────────────────
# An explicit -Shas list (from the dashboard's "keep one container warm" batch
# dispatch) wins; each entry is expanded to a full SHA and the set is reordered
# into git's oldest→newest topological order so reports fill in chronologically.
# With no list we fall back to every commit that touched project source.
function Resolve-ShaList {
    $raw = @($Shas -split '[\s,]+' | Where-Object { $_ -ne '' })
    if ($raw.Count -eq 0) {
        $all = @(& git -C $WorkspaceRoot log --reverse --format='%H' -- '*.vi' '*.ctl' '*.lvproj' '*.lvlib' '*.lvclass')
        if ($MaxCommits -gt 0 -and $all.Count -gt $MaxCommits) {
            $all = $all[($all.Count - $MaxCommits)..($all.Count - 1)]
        }
        return $all
    }
    # Expand abbreviated SHAs and keep only those that resolve in this repo.
    $want = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($s in $raw) {
        $full = (& git -C $WorkspaceRoot rev-parse --verify "$s^{commit}" 2>$null)
        if ($LASTEXITCODE -eq 0 -and $full) { [void]$want.Add($full.Trim()) }
        else { Write-Warning "Skipping unknown revision '$s'." }
    }
    if ($want.Count -eq 0) { return @() }
    # Order them oldest→newest by intersecting with full history order.
    $ordered = @(& git -C $WorkspaceRoot rev-list --reverse HEAD | Where-Object { $want.Contains($_) })
    # A requested SHA not reachable from HEAD (e.g. a detached build) still runs,
    # appended after the ordered set so nothing the caller asked for is dropped.
    foreach ($s in $want) { if ($ordered -notcontains $s) { $ordered += $s } }
    return $ordered
}

$Commits = @(Resolve-ShaList)
Write-Host "Revisions to compile: $($Commits.Count)"
if ($Commits.Count -eq 0) { Write-Host 'Nothing to do.'; exit 0 }

# Set of already-done SHAs (from the deployed report list) for incremental skip.
$Done = New-Object System.Collections.Generic.HashSet[string]
if (-not $Force -and $SkipListPath -ne '' -and (Test-Path $SkipListPath)) {
    foreach ($line in (Get-Content $SkipListPath)) {
        if ($line -match 'masscompile/([0-9a-f]{7,40})/') { [void]$Done.Add($Matches[1]) }
    }
    Write-Host "Already-done revisions: $($Done.Count)"
}

# ── Start the long-lived container ───────────────────────────────────────────
& docker pull $Image | Out-Null
Write-Host "Starting warm container $ContainerName ..."
# NOTE: report OUTPUT is intentionally NOT a bind-mount. On Windows containers,
# files written inside the container to a host bind-mount are not reliably visible
# back on the host. We write to a container-internal dir (C:\cout) and `docker cp`
# each revision's report out to the host instead. The repo's .github\labview tree
# (masscompile.ps1 etc.) is mounted read-only-ish at C:\ops, and per-revision
# source worktrees are exposed under C:\wt.
& docker run -d --name $ContainerName `
    -e "GITHUB_REPOSITORY=$Repo" `
    -v "${OpsHost}:C:\ops" `
    -v "${WorkTreesHost}:C:\wt" `
    $Image powershell -NoProfile -Command "while (`$true) { Start-Sleep -Seconds 3600 }" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to start container." }

# Live bind-mount probe (host files created after start must be visible inside).
$probe = Join-Path $WorkTreesHost '.probe'
Set-Content -Path $probe -Value 'ok' -Encoding ascii
$probeSeen = (& docker exec $ContainerName powershell -NoProfile -Command "if (Test-Path 'C:\wt\.probe') { 'yes' } else { 'no' }").Trim()
Remove-Item $probe -Force -ErrorAction SilentlyContinue
if ($probeSeen -ne 'yes') {
    & docker rm -f $ContainerName | Out-Null
    throw "Live bind-mount probe failed (container cannot see new host files under C:\wt)."
}

$deadline  = (Get-Date).AddMinutes($TimeBudgetMinutes)
$processed = 0
$skipped   = 0

try {
    foreach ($sha in $Commits) {
        $short = $sha.Substring(0, [Math]::Min(7, $sha.Length))

        # Resume: skip revisions whose report is already deployed (unless -Force).
        if ($Done.Contains($sha)) { $skipped++; continue }

        if ((Get-Date) -gt $deadline) {
            Write-Host "Time budget reached - stopping before $short. Re-run to resume."
            break
        }

        Write-Host ""
        Write-Host "=== [$short] Mass Compile ==="

        $swt = Join-Path $WorkTreesHost "src-$sha"
        if (Test-Path $swt) { & git -C $WorkspaceRoot worktree remove --force $swt 2>$null | Out-Null }
        & git -C $WorkspaceRoot worktree add --detach $swt $sha 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warning "worktree failed for $short; skipping."; continue }

        $reportHostDir = Join-Path $OutRoot $sha

        try {
            # Compile into a CONTAINER-INTERNAL dir, then copy the result to the host.
            $cOut = "C:\cout\$sha"
            & docker exec $ContainerName powershell -NoProfile -Command "Remove-Item -Recurse -Force '$cOut' -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force -Path '$cOut' | Out-Null" | Out-Null
            & docker exec $ContainerName powershell -NonInteractive -ExecutionPolicy Bypass `
                -File 'C:\ops\masscompile.ps1' `
                -WorkspaceRoot "C:\wt\src-$sha" `
                -ReportDir     "$cOut" `
                -LabVIEWPath   $LabVIEWPath
            if ($LASTEXITCODE -ne 0) { Write-Warning "masscompile returned $LASTEXITCODE for $short (continuing)." }

            # Copy the compiled report (summary.json + masscompile.log + index.html)
            # out of the container to the host staging dir. Copy the directory
            # itself (no trailing '\.') so docker creates <reportHostDir> with the
            # contents inside; the '\.' content-copy form is rejected by Windows
            # CreateFile on Windows containers.
            & docker cp "${ContainerName}:$cOut" "$reportHostDir"
            if ($LASTEXITCODE -ne 0) { Write-Warning "docker cp failed for $short (continuing)." }
            & docker exec $ContainerName powershell -NoProfile -Command "Remove-Item -Recurse -Force '$cOut' -ErrorAction SilentlyContinue" | Out-Null

            if (-not (Test-Path (Join-Path $reportHostDir 'summary.json'))) {
                Write-Warning "No summary.json produced for $short (report not generated)."
                continue
            }

            # Replace the raw log dump with the navigable report on the HOST (Python),
            # exactly as the per-commit workflow does. Best-effort: a formatting
            # hiccup must never drop the basic report we already have.
            $msg = (& git -C $WorkspaceRoot log -1 --pretty=%s  $sha)
            $aut = (& git -C $WorkspaceRoot log -1 --pretty=%an $sha)
            $dat = (& git -C $WorkspaceRoot log -1 --pretty=%cI $sha)
            & python (Join-Path $OpsHost 'build-masscompile-report.py') `
                --log             (Join-Path $reportHostDir 'masscompile.log') `
                --workspace       $swt `
                --out             $reportHostDir `
                --platform        windows `
                --meta            (Join-Path $reportHostDir 'summary.json') `
                --sha             $sha `
                --repo            $Repo `
                --pages-url       $PagesUrl `
                --labview-version $LabVIEWVersion `
                --commit-msg      $msg `
                --author          $aut `
                --date            $dat 2>$null
            if ($LASTEXITCODE -ne 0) { Write-Warning "report builder returned $LASTEXITCODE for $short (basic report kept)." }

            $processed++
            Write-Host "[$short] report staged at $reportHostDir"
        }
        finally {
            & git -C $WorkspaceRoot worktree remove --force $swt 2>$null | Out-Null
        }
    }
}
finally {
    & docker rm -f $ContainerName 2>$null | Out-Null
    & git -C $WorkspaceRoot worktree prune 2>$null | Out-Null
}

Write-Host ""
Write-Host "=== Mass Compile backfill (Windows) complete: $processed compiled, $skipped skipped ==="
exit 0
