# UTF JUnit Report runner (vendored)

Headless runner for the **NI Unit Test Framework (UTF)**. Given a LabVIEW project,
`run utf and report.vi` runs every `.lvtest` in that project through UTF and writes a
JUnit-compatible XML report that the CI pipeline turns into the dashboard's **Unit
Tests** result.

## Provenance

These VIs are vendored verbatim from NI's open-source **UTF JUnit Report Library**:

- Source: <https://github.com/LabVIEW-DCAF/UTF-Test> (`source/`)
- License: **Apache-2.0** (see `LICENSE`)
- Author: Matt Pollock / National Instruments

Top-level VI: **`run utf and report.vi`**. Its dependencies are `create junit
report.vi`, `get result counts.vi`, `get result details.vi`, `get run time total.vi`
(all owned by `utf junit report.lvlib`), the NI **JUnit Results API** (ships in
LabVIEW `vi.lib`), and the **NI Unit Test Framework** toolkit (baked into the Windows
worker image by `.github/docker/labview-ci.Dockerfile`).

## How it is invoked

`.github/labview/run-unit-tests.ps1` runs each UTF-enabled tool by resolving the
project(s) under its configured `locations` (a folder/glob to search, or a `.lvproj`)
and driving this VI headlessly through **LabVIEWCLI RunVI**:

```
LabVIEWCLI -OperationName RunVI -VIPath "run utf and report.vi" \
  -LabVIEWPath "<LabVIEW.exe>" -Arguments "<project.lvproj>" "<out.xml>" -Headless
```

The script then harvests the JUnit XML (preferring the explicit output path, else any
`<testsuite>` XML the runner wrote beside the project) into the results directory as
`utf-*.xml`, which `build-unittest-report.py` merges into the unified report.

## Confirm-on-worker

The exact RunVI argument binding for `run utf and report.vi` depends on its connector
pane and must be confirmed on a real LabVIEW 2026 Windows worker. If the default
invocation needs adjusting, override it per tool in `.github/labview-ci.yml` without
editing this script:

```yaml
unitTests:
  tools:
    utf:
      enabled: true
      command: '"{cli}" -OperationName RunVI -VIPath "{runner}" -LabVIEWPath "{lv}" -Arguments "{proj}" "{out}" -Headless'
      locations:
        - "example/User-Defined Test/"
```

Tokens: `{cli}` = LabVIEWCLI, `{runner}` = this VI, `{lv}` = LabVIEW.exe,
`{proj}` = the resolved `.lvproj`, `{out}` = the JUnit output path, `{ver}` = LabVIEW year.
