# Example LabVIEW project — Mini Systems Project

This is the example project the tooling runs its own CI on, so the dashboard
showcases real Mass Compile / VI Analyzer / VIDiff / Snapshot results.

It is the **Mini Systems Project** (a solar-tracker + generator-curriculum
LabVIEW application), seeded from
[`elijah286/mini-system-manager`](https://github.com/elijah286/mini-system-manager)
as its **genuine code revision history** — twelve revisions spanning the project's
real evolution (that repo's CI-prototype commits and merge commits were
intentionally excluded):

| # | From | Date | Change |
|---|---|---|---|
| 1 | `mini-system-manager@5887ac1` | 2024-11-04 | *debugging the assignment of visa resources to curriculum code* |
| 2 | `mini-system-manager@c37e5ea` | 2024-11-04 | *Windows bug* |
| 3 | `mini-system-manager@0008bda` | 2024-11-04 | *mass compiled on windows* |
| 4 | `mini-system-manager@553622d` | 2024-11-04 | *improved resize appearance* |
| 5 | `mini-system-manager@035ca37` | 2024-11-21 | *Added new excercises* (+30 VIs) |
| 6 | `mini-system-manager@a7bf734` | 2024-11-21 | *Copy of excercise generated* |
| 7 | `mini-system-manager@3fbb38f` | 2024-11-21 | *Excercise manual correction* |
| 8 | `mini-system-manager@0af78bc` | 2024-11-21 | *Minor refinements* |
| 9 | `mini-system-manager@6a28235` | 2024-11-21 | *fixed errors in motor VIs* |
| 10 | `mini-system-manager@f0e2b16` | 2026-05-29 | *moved the send command button* |
| 11 | `mini-system-manager@18f9d59` | 2026-05-29 | *moved a constant* (`main.vi`) |
| 12 | `mini-system-manager@711230b` | 2026-06-01 | *resized the graph* (`Graph Popup.vi`) |

Because it lands as a dozen revisions spanning real growth — from 25 VIs early on
up to the full ~54-VI application — every capability lights up with a rich history:

- **Mass Compile** / **VI Analyzer** run on the latest revision.
- **VIDiff** and the **VI Browser** compare each revision against its predecessor
  — e.g. the most recent visible diff is `Graph Popup.vi` ("resized the graph").
- **Snapshots** render every VI's block diagram across all revisions.

Only the LabVIEW source and project files were copied; the original repo's
`.github/` CI tooling was left behind (this repo provides the CI). The project
entry point is `Mini Systems Project.lvproj`.
