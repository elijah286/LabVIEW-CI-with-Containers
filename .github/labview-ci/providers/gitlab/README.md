# LabVIEW CI GitLab provider

This package is the source-owned adapter installed as `.gitlab/labview-ci/` by
`install.py --provider gitlab` and by the browser configurator. It uses native
GitLab CI jobs, GitLab artifacts, the project container registry, and GitLab
Pages; it does not invoke GitHub Actions or post GitHub commit statuses.

Windows LabVIEW jobs require a self-managed Windows shell runner with Docker.
Linux jobs require a runner that permits Docker-in-Docker. Set the
`LVCI_WINDOWS_RUNNER_TAG` and `LVCI_LINUX_RUNNER_TAG` CI/CD variables if the
defaults do not match the project's registered runners.

Custom-worker jobs read the installed catalog's `containers.default` release and
pass its pinned NI image tag (plus the Windows NIPM feed and VIPM installer) to
the Dockerfiles. Set `LVCI_CONTAINER_RELEASE` to another qualified catalog
release id, such as `2026q1`, when the project must remain on that release.