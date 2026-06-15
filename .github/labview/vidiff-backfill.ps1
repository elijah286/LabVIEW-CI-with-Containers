<#
.SYNOPSIS
    Generate VIDiff reports across history using ONE warm Windows LabVIEW container.

.DESCRIPTION
    Windows-container counterpart of vidiff-backfill.sh. Walks every VI-touching
    commit oldest -> newest and produces a VIDiff report comparing it to the
    PREVIOUS VI-touching commit (the same base the VI Browser uses), so each
    changed VI gets a Windows-rendered side-by-side diff to compare against the
    Linux render.

    A single container is started and kept warm; each commit pair is rendered via
    `docker exec` (no per-commit container churn or image re-pull). Reports are
    staged deploy-ready under:
        <OutRoot>\push-<headsha>\windows\vidiff\...   (index.html, changes.json, per-VI)
        <OutRoot>\push-<headsha>\windows\vidiff-meta.json

.NOTES
    'Continue' (not 'Stop') is deliberate: git/docker write progress to stderr,
    which WinPS 5.1 would otherwise turn into terminating NativeCommandErrors.
    Success is judged by $LASTEXITCODE / output presence.
#>
param(
    [string]$WorkspaceRoot     = (Get-Location).Path,
    [string]$OutRoot           = '',
    [string]$Image             = 'nationalinstruments/labview:latest-windows',
    [int]   $MaxCommits        = 0,
    # File listing already-deployed Windows report paths (one per line, e.g.
    # 'vidiff/push-<sha>/windows/vidiff/changes.json'). Used to skip done commits.
    [string]$SkipListPath      = '',
    [int]   $TimeBudgetMinutes = 300
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$WorkspaceRoot = (Resolve-Path $WorkspaceRoot).Path
if ($OutRoot -eq '') { $OutRoot = Join-Path $WorkspaceRoot 'ci-out\vidiff-backfill' }
$OpsHost = Join-Path $WorkspaceRoot '.github\labview'

$TempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$WorkTreesHost = Join-Path $TempRoot 'lvci-vidiff-wt'
New-Item -ItemType Directory -Force -Path $OutRoot, $WorkTreesHost | Out-Null

$ContainerName = "lvci-vidiff-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ── VI-touching commits, oldest first ────────────────────────────────────────
$Commits = @(& git -C $WorkspaceRoot log --reverse --format='%H' -- '*.vi' '*.ctl')
if ($MaxCommits -gt 0 -and $Commits.Count -gt $MaxCommits) {
    $Commits = $Commits[($Commits.Count - $MaxCommits)..($Commits.Count - 1)]
}
Write-Host "VI-touching commits to consider: $($Commits.Count)"

# Set of already-done head SHAs (from the deployed report list) for incremental skip.
$Done = New-Object System.Collections.Generic.HashSet[string]
if ($SkipListPath -ne '' -and (Test-Path $SkipListPath)) {
    foreach ($line in (Get-Content $SkipListPath)) {
        if ($line -match 'push-([0-9a-f]+)/windows') { [void]$Done.Add($Matches[1]) }
    }
    Write-Host "Already-done Windows commits: $($Done.Count)"
}

# ── Start the long-lived container ───────────────────────────────────────────
& docker pull $Image | Out-Null
Write-Host "Starting warm container $ContainerName ..."
# NOTE: report OUTPUT is intentionally NOT a bind-mount. On Windows containers,
# files written inside the container to a host bind-mount are not reliably visible
# back on the host. We write to a container-internal dir (C:\cout) and `docker cp`
# each commit's report out to the host instead.
& docker run -d --name $ContainerName `
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
$prev      = ''
$processed = 0
$skipped   = 0

try {
    foreach ($sha in $Commits) {
        if ($prev -eq '') { $prev = $sha; continue }
        $short = $sha.Substring(0, 7)

        # Resume: skip commits whose Windows report is already deployed.
        if ($Done.Contains($sha)) {
            $skipped++; $prev = $sha; continue
        }

        $changed = @(& git -C $WorkspaceRoot diff --name-only $prev $sha -- '*.vi' '*.ctl')
        if ($changed.Count -eq 0) { $prev = $sha; continue }

        if ((Get-Date) -gt $deadline) {
            Write-Host "Time budget reached - stopping before $short. Re-run to resume."
            break
        }

        Write-Host "[$short] vs $($prev.Substring(0,7)): $($changed.Count) changed VI(s)"

        $bwt = Join-Path $WorkTreesHost "base-$sha"
        $hwt = Join-Path $WorkTreesHost "head-$sha"
        foreach ($wt in @($bwt, $hwt)) {
            if (Test-Path $wt) { & git -C $WorkspaceRoot worktree remove --force $wt 2>$null | Out-Null }
        }
        & git -C $WorkspaceRoot worktree add --detach $bwt $prev 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warning "worktree(base) failed for $short; skipping."; $prev = $sha; continue }
        & git -C $WorkspaceRoot worktree add --detach $hwt $sha 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warning "worktree(head) failed for $short; skipping."; $prev = $sha; continue }

        $reportHostDir = Join-Path $OutRoot "push-$sha\windows"
        New-Item -ItemType Directory -Force -Path $reportHostDir | Out-Null

        # Changed-file list is delivered into the container via the C:\wt mount
        # (host -> container direction across a Windows bind-mount is reliable).
        # Write LF-only so the container's regex match isn't broken by stray \r.
        $changedFile = Join-Path $WorkTreesHost "changed-$sha.txt"
        [System.IO.File]::WriteAllText($changedFile, (($changed -join "`n") + "`n"), $Utf8NoBom)

        try {
            # Render into a CONTAINER-INTERNAL dir, then copy the result to the host.
            $cOut = "C:\cout\$sha"
            & docker exec $ContainerName powershell -NoProfile -Command "Remove-Item -Recurse -Force '$cOut' -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force -Path '$cOut\vidiff' | Out-Null" | Out-Null
            & docker exec $ContainerName powershell -NoProfile -ExecutionPolicy Bypass `
                -File 'C:\ops\vidiff.ps1' `
                -BaseDir          "C:\wt\base-$sha" `
                -HeadDir          "C:\wt\head-$sha" `
                -ReportDir        "$cOut\vidiff" `
                -OpsDir           'C:\ops' `
                -ChangedFilesPath "C:\wt\changed-$sha.txt"
            if ($LASTEXITCODE -ne 0) { Write-Warning "vidiff returned $LASTEXITCODE for $short (continuing)." }

            # Copy the rendered report tree out of the container to the host.
            & docker cp "${ContainerName}:$cOut\vidiff" "$reportHostDir\vidiff"
            if ($LASTEXITCODE -ne 0) { Write-Warning "docker cp failed for $short (continuing)." }
            & docker exec $ContainerName powershell -NoProfile -Command "Remove-Item -Recurse -Force '$cOut' -ErrorAction SilentlyContinue" | Out-Null

            # Only count it if the report actually landed on the host.
            if (Test-Path (Join-Path $reportHostDir 'vidiff\changes.json')) {
                $meta = "{`n  `"head_sha`":  `"$sha`",`n  `"base_sha`":  `"$prev`",`n  `"pr_number`": `"`",`n  `"platform`":  `"windows`",`n  `"outcome`":   `"success`"`n}"
                [System.IO.File]::WriteAllText((Join-Path $reportHostDir 'vidiff-meta.json'), $meta, $Utf8NoBom)
                $processed++
            }
            else {
                Write-Warning "No changes.json produced for $short (report not generated)."
            }
        }
        finally {
            Remove-Item $changedFile -Force -ErrorAction SilentlyContinue
            foreach ($wt in @($bwt, $hwt)) {
                & git -C $WorkspaceRoot worktree remove --force $wt 2>$null | Out-Null
            }
        }
        $prev = $sha
    }
}
finally {
    & docker rm -f $ContainerName 2>$null | Out-Null
    & git -C $WorkspaceRoot worktree prune 2>$null | Out-Null
}

Write-Host ""
Write-Host "=== VIDiff backfill (Windows) complete: $processed generated, $skipped skipped ==="
exit 0
