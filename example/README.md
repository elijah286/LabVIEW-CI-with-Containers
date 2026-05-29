# Example LabVIEW project — Mini Systems Project

This is the example project the tooling runs its own CI on, so the dashboard
showcases real Mass Compile / VI Analyzer / VIDiff / Snapshot results.

It is the **Mini Systems Project** (a solar-tracker + generator-curriculum
LabVIEW application), seeded from
[`elijah286/mini-system-manager`](https://github.com/elijah286/mini-system-manager)
as its **last two genuine code revisions** (that repo's CI-prototype commits were
intentionally excluded):

| Example commit | From | Change |
|---|---|---|
| rev 1 | `mini-system-manager@18f9d59a` (2026-05-29) | *moved a constant* (`main.vi`) |
| rev 2 | `mini-system-manager@711230b4` (2026-06-01) | *resized the graph* (`Graph Popup.vi`) |

Because it lands as two revisions, every capability lights up:

- **Mass Compile** / **VI Analyzer** run on the latest revision.
- **VIDiff** and the **VI Browser** compare rev 2 against rev 1 — the visible
  diff is `Graph Popup.vi` ("resized the graph").
- **Snapshots** render every VI's block diagram across both revisions.

Only the LabVIEW source and project files were copied; the original repo's
`.github/` CI tooling was left behind (this repo provides the CI). The project
entry point is `Mini Systems Project.lvproj`.
