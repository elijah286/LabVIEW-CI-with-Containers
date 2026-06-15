# Example LabVIEW project (lives in the master tooling repo)

A tiny, self-contained LabVIEW project that the tooling repo **runs its own CI on**.
It serves two purposes:

1. **Live demo** — the master repo's dashboard shows real Mass Compile / VI Analyzer /
   VIDiff / Snapshot results, so a visitor immediately sees what the tooling produces.
2. **Integration test** — every change to the tooling is validated against a real
   (if minimal) LabVIEW project, so regressions surface before consumers hit them.

This is "dogfooding": the master repo is both the **source of truth** and its own
**first consumer**.

## Layout (after you add the VIs in LabVIEW)

```
example/
  Example Project.lvproj         LabVIEW project that lists the VIs below
  Add.vi                          two numeric inputs -> sum (clean compile)
  Average.vi                      array in -> mean out (calls Add.vi)
  Greeting.vi                     string in -> formatted string out
  Main.vi                         top-level VI wiring the above for a demo run
  example.vipc                    (optional) a dependency so the image-build path is exercised
```

> The `.vi` / `.lvproj` files are LabVIEW binaries and must be created in LabVIEW
> (2021+). Keep them trivial — the point is breadth of capability coverage, not
> complexity. A handful of VIs that **compile cleanly**, have a couple of VI
> Analyzer-relevant style points, and change over a few commits is enough to make
> Mass Compile, VI Analyzer, VIDiff, and Snapshots all light up on the dashboard.

## How CI runs on it

Because this project lives **inside** the tooling repo, its CI references the
repo's own composite actions by local path (it does not pull `@v1` from itself).
See [`workflows/example-ci.yml`](workflows/example-ci.yml) — copy it to
`.github/workflows/` in the master repo. The settings it honors come from
[`labview-ci.yml`](labview-ci.yml) (copied to the repo root's `.github/`).

## What a visitor learns

Opening the master dashboard, a visitor sees this example's results and the
**Apply to New Repo** button — which installs the *same* tooling into their repo,
always sourced from this master repo. That's the whole story in one screen.
