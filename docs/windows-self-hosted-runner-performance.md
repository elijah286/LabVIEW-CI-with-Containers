# Speeding up Windows container pulls with a self-hosted runner

The Windows LabVIEW container image is large. A GitHub-hosted Windows runner is
ephemeral, so every workflow job starts with an empty Docker image store and must
download, decompress, and register the LabVIEW image layers again. Storing the
image in GHCR means the image is already built; it does not mean the hosted
runner has those layers on disk.

To make `Pull LabVIEW container image` fast after the first run, run the Windows
container jobs on a self-hosted Windows runner whose Docker image store persists
between jobs.

## What this improves

This helps the Windows container workflows that pull one of these images:

- `nationalinstruments/labview:latest-windows`
- `ghcr.io/<owner>/<repo>-labview:latest`
- `ghcr.io/<owner>/<repo>-labview:<labview-version>`
- `ghcr.io/<owner>/<repo>-labview:<worker-content-tag>`

The first pull is still slow because the runner has to populate its local Docker
store. Later jobs on the same runner can reuse the existing layers, so the pull
usually becomes a manifest check plus any changed layers.

This is most useful when the same repository or organization runs LabVIEW CI
often enough to keep a warm runner online.

## Security model

Use self-hosted runners only for code you trust.

Pull requests from forks or untrusted contributors can execute workflow code on a
self-hosted runner if the workflows allow it. For public repositories, do not put
these runners in a broad pool that untrusted PR workflows can reach.

Recommended controls:

- Put the runner in a dedicated runner group.
- Restrict that runner group to the repositories that need LabVIEW Windows
  containers.
- Prefer private repositories, trusted branches, or manually dispatched workflows.
- Do not use the same machine for unrelated secrets or sensitive workloads.
- Keep the runner account unprivileged except for the permissions required to run
  Docker.

## Runner requirements

Use a Windows host that can run Windows containers compatible with the LabVIEW
image.

Recommended starting point:

- Windows Server 2022.
- Docker or Mirantis Container Runtime configured for Windows containers.
- A GitHub Actions self-hosted runner installed as a service.
- At least 4 CPU cores and 16 GB RAM. More is better for concurrent LabVIEW jobs.
- At least 200 GB free disk for Docker images, containers, workspaces, and logs.
  Use more if you keep multiple LabVIEW versions or worker tags warm.
- Network access to `github.com`, `ghcr.io`, Docker Hub, and NI package feeds if
  this machine also builds worker images.

The runner must stay on the same machine or VM between jobs. Reimaging the VM or
deleting Docker's data root removes the cache and makes the next job cold again.

## Set up the Windows host

Run these commands from an elevated PowerShell session on the Windows host.

Enable containers:

```powershell
Install-WindowsFeature -Name Containers
Restart-Computer
```

Install and start a Docker-compatible Windows container engine. The exact command
depends on your organization and licensing, but after installation this should
work:

```powershell
docker version
docker info
```

Confirm Docker is using Windows containers. The `OSType` value should be
`windows`:

```powershell
docker info --format '{{.OSType}}'
```

If Docker is using Linux containers, switch it to Windows containers before using
this runner for LabVIEW CI.

## Install the GitHub Actions runner

Create the runner from GitHub:

1. Open the target repository or organization in GitHub.
2. Go to **Settings** > **Actions** > **Runners**.
3. Choose **New self-hosted runner**.
4. Select **Windows** and **x64**.
5. Follow GitHub's download and configure commands.

During configuration, add labels that make the runner easy to target, for
example:

```text
self-hosted, Windows, X64, labview-docker
```

Install it as a service so it survives reboots:

```powershell
.\svc.cmd install
.\svc.cmd start
```

If GitHub's runner setup page shows a different service helper for your runner
package, use the command GitHub provides. The important point is that the runner
runs as a service under an account that can access Docker.

Make sure the service account can run Docker:

```powershell
docker ps
```

If `docker ps` works in your interactive admin shell but fails in Actions, fix
the service account's Docker access before continuing.

## Warm the Docker image cache

After the runner is online, pre-pull the images your workflows use. This pays the
slow cost once during setup instead of during the first CI run.

For the NI base image:

```powershell
docker pull nationalinstruments/labview:latest-windows
```

For a repository's custom LabVIEW CI worker image:

```powershell
docker login ghcr.io
docker pull ghcr.io/<owner>/<repo>-labview:latest
docker pull ghcr.io/<owner>/<repo>-labview:2026
```

If you pin workers by content tag, pull that tag too:

```powershell
docker pull ghcr.io/<owner>/<repo>-labview:win-xxxxxxxxxxxx
```

Confirm the images are local:

```powershell
docker images
```

Do not run cleanup jobs such as `docker system prune -a` unless you intend to
discard the warm cache.

## Route LabVIEW Windows jobs to the runner

The Windows workflows must target the self-hosted labels instead of
`windows-2022`.

Use this shape when authoring or customizing a workflow:

```yaml
runs-on: [self-hosted, Windows, X64, labview-docker]
```

If this repository's generated workflows currently contain:

```yaml
runs-on: windows-2022
```

replace that line in the Windows container workflows you want to accelerate.
Common candidates are:

- `.github/workflows/masscompile-windows-container.yml`
- `.github/workflows/run-vi-analyzer-windows-container.yml`
- `.github/workflows/unit-tests-windows-container.yml`
- `.github/workflows/vidiff-windows-container.yml`
- `.github/workflows/run-antidoc-windows-container.yml`
- `.github/workflows/build-labview-image.yml`, if you also want worker image
  builds to use this machine

Keep Linux workflows on Linux runners. A Windows self-hosted runner cannot run
the Linux LabVIEW container jobs.

## Verify the cache is working

Run one Windows LabVIEW workflow once to populate or refresh the cache. Then run
it again on the same self-hosted runner.

In the Actions log, expand **Pull LabVIEW container image**.

A cold pull usually shows many layer download, checksum, extract, and `Pull
complete` lines and can take many minutes.

A warm pull should show that most or all layers already exist locally, or finish
after a short registry manifest check. The exact text varies by Docker version,
but the step should be dramatically shorter than a hosted cold pull.

You can also check the runner directly:

```powershell
docker images
docker system df
```

## Maintenance

Keep the machine patched, but avoid wiping Docker's image store during routine
maintenance.

Suggested maintenance tasks:

- Patch Windows and reboot during a maintenance window.
- Periodically update the Actions runner application.
- Monitor disk usage with `docker system df`.
- Remove obsolete LabVIEW worker tags deliberately when disk pressure requires it.
- Re-pull current tags after cleanup so the next CI run is warm.

Example targeted cleanup:

```powershell
docker images
docker rmi ghcr.io/<owner>/<repo>-labview:old-tag
docker pull ghcr.io/<owner>/<repo>-labview:latest
```

Avoid broad cleanup unless you accept a cold pull afterward:

```powershell
docker system prune -a
```

## Troubleshooting

If the job stays queued, check that the workflow's `runs-on` labels exactly match
the labels shown for the runner in GitHub.

If Docker commands fail in the workflow, check that the runner service account
can run Docker. Running the runner interactively as one user and as a service
under another can produce different Docker permissions.

If pulls are still slow every time, verify that jobs are landing on the same
self-hosted machine and that no cleanup task removes Docker layers between runs.

If the pull fails with a Windows version compatibility error, confirm the host OS
matches the Windows base image family used by the LabVIEW container. For the
current Windows workflows, start with Windows Server 2022.

If GHCR pulls fail, verify package visibility and credentials. The workflow's
`GITHUB_TOKEN` can read packages owned by the same repository when permissions
allow it, but manual pre-pull from the host may need `docker login ghcr.io` with
a GitHub token that has package read access.
