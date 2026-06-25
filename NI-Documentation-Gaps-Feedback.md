# Documentation & Discoverability Gaps in NI Tooling — Field Feedback

These are **recurring, general patterns** observed while using NI (and adjacent ecosystem) tools
to build automated, headless / CI workflows. They are written as reusable categories — each
briefly illustrated — because they mark the spots where an engineer, **and increasingly the LLM
they rely on to read the docs**, cannot succeed on the first attempt. As more people use
assistants to learn NI products, these gaps translate directly into failed adoptions and support
load.

**The throughline:** tools that fail silently or with bare error codes, plus install endpoints,
package names, and automation contracts that aren't treated as stable, documented interfaces,
are exactly what an LLM cannot reverse-engineer — so it guesses, or acts on the wrong source.

| Gap (general pattern) | Why it matters | How it showed up in practice | Recommendation |
|---|---|---|---|
| **1. Link rot in install/setup docs** | A single dead link can silently break a whole automated pipeline; both humans and LLMs follow the "official" link and hit a 404. | A documented installer download URL began returning 404 and hard-failed an unattended build, with no fallback. | Treat download endpoints as a **versioned, monitored API**; avoid version-specific filenames; prefer package-feed installs. |
| **2. Overlapping, similarly-named tools — and no clear first-party path** | When several products (often mixing first-party and community) solve one need with near-identical names but different CLIs, it's easy — especially for an LLM — to confidently apply the **wrong** one's instructions. Sometimes the de-facto answer is an unendorsed community project the model can't recognize as authoritative. | Multiple "install a package" tools shared a brand/name but had **divergent commands**; and a common need (headless test reporting) had no documented first-party option — only a community library. | Publish **disambiguation guides** and a single "supported path" per common task; explicitly endorse or absorb the de-facto community solutions. |
| **3. Product name ≠ package / feed name** | Searching by a product's marketing name doesn't surface the installable artifact or its feed, so automated provisioning silently installs nothing. | Searching a toolkit's product name in the package feed returned no match; the real package had an internal id in a separate feed. | Provide a **product → package-id → feed** mapping, discoverable by the product's common name. |
| **4. Silent "success with zero work"** | Tools that return success while producing empty output (0 items processed, empty report) give automation nothing to detect — the costliest failure mode to diagnose. | An analysis tool repeatedly emitted empty "0 analyzed" reports under benign-looking misconfigurations, with no warning. | **Warn loudly** on no-op / zero-result outcomes; exit non-zero where appropriate. |
| **5. Opaque numeric error codes** | Bare codes with no actionable text — and little online mapping — are disproportionately expensive for an LLM to resolve; the real detail often sits in a separate log the tool doesn't surface. | Several failures surfaced only as negative numeric codes; the actionable cause lived in a session-log file that had to be found manually. | Make errors **name the offending item/flag** and point to the log; publish a searchable **code → cause → remedy** index. |
| **6. Undocumented version- & environment-specific behavior** | File locations, what a base/container image actually contains, and OS PATH/registry semantics shift between versions and environments; docs written for the desktop case break silently in containers/CI. | Expected default content was absent from a slim container image; an installer's registry-PATH change wasn't visible to a containerized process, so a baked-in tool read as "not found." | Publish **per-version layout notes + an image content manifest**; document container / headless / PATH behavior as first-class. |
| **7. Undocumented headless & extensibility contracts** | Automation entry points (headless/CLI/COM) and customization hooks exist but aren't documented, so they're only usable via trial and error — exactly what an LLM can't shortcut. | Driving a tool headlessly, and authoring a custom CLI operation, both required reverse-engineering undocumented init/readiness and folder/search-path rules. | Document the **headless-automation and extensibility contracts** (init/readiness, search paths, constraints) with a minimal worked example. |

**Highest-leverage fixes, across all seven:** make tools **fail loudly and specifically**, and
treat **install endpoints, package/feed names, and automation contracts as documented, versioned
interfaces**. That is what lets an engineer — or an LLM acting for one — succeed without
reverse-engineering.

<sub>Compiled from hands-on experience building containerized, headless LabVIEW CI/CD automation. Examples are kept generic; specifics available on request.</sub>
