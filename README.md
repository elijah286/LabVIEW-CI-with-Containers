# LabVIEW-CI-with-Containers

Portable, container-based CI/CD for LabVIEW repositories — mass compile, VI Analyzer, VIDiff, VI snapshots, and a status dashboard.

<p align="center">
  <a href="https://elijah286.github.io/LabVIEW-CI-with-Containers/"><img src="https://img.shields.io/badge/View%20Example%20LabVIEW%20CI%20Dashboard-2ea44f?style=for-the-badge&logo=githubpages&logoColor=white" alt="View example LabVIEW CI Dashboard" height="42"></a>
  &nbsp;&nbsp;
  <a href="https://elijah286.github.io/LabVIEW-CI-with-Containers/integrate.html"><img src="https://img.shields.io/badge/Install%20This%20CI%20Tooling%20to%20Your%20Repo-1f6feb?style=for-the-badge&logo=github&logoColor=white" alt="Install this CI tooling to your repo" height="42"></a>
</p>

- **View example LabVIEW CI Dashboard** — the live dashboard for this repo's own
  [`example/`](example/README.md) LabVIEW project, showcasing the latest tooling
  capabilities ([https://elijah286.github.io/LabVIEW-CI-with-Containers/](https://elijah286.github.io/LabVIEW-CI-with-Containers/)).
- **Install this CI tooling to your repo** — the interactive installer that adds
  these capabilities to any LabVIEW repository, always sourced from here
  ([https://elijah286.github.io/LabVIEW-CI-with-Containers/integrate.html](https://elijah286.github.io/LabVIEW-CI-with-Containers/integrate.html)).

> The buttons go live once GitHub Pages is enabled (Settings ▸ Pages ▸ deploy from
> the `gh-pages` branch) and the dashboard/configurator workflows have run.

## Use it in your repo

```yaml
# .github/workflows/labview-ci.yml
jobs:
  labview-ci:
    uses: elijah286/LabVIEW-CI-with-Containers/.github/workflows/labview-ci.reusable.yml@v1
    secrets: inherit
```

Or install interactively from the dashboard's **Apply to New Repo** button, or via the installer in [`.github/labview-ci/`](.github/labview-ci/README.md).

See [`.github/labview-ci/standalone/README.md`](.github/labview-ci/README.md) for the versioning + release model.
