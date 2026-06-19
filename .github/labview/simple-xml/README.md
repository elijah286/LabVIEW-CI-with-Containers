# NI "Simple XML" library (vendored for headless UTF) — FILES NEEDED

This folder is the vendor slot for NI's **Simple XML** library (`Simple XML.lvlib`,
VIPM package `ni_lib_simple_xml`). It is the **third and final** library in the
dependency chain that NI's built-in `LabVIEWCLI -OperationName RunUnitTests`
operation links against but which is **not installed** on the LabVIEW 2026 CI
worker image:

```
RunUnitTests.lvclass : CreateJUnitReport.vi
        -> UTF Junit Report  (.github/labview/utf-junit)        [vendored OK]
        -> JUnit Results API (.github/labview/junit-results-api) [vendored OK]
        -> Simple XML        (.github/labview/simple-xml)        <-- THIS (needs files)
```

`run-unit-tests.ps1` → `Repair-SimpleXml` mirrors this folder into the running
LabVIEW's `vi.lib\NI\Simple XML\` (preserving the `_polymorphics\` and `_private\`
subfolders) so the JUnit API VIs (`Create JUnit Root.vi`, `Add Test Case.vi`,
`Save JUnit Report.vi`, …) resolve and the `-350053` operation-load failure clears.

## Why the binary VIs are not committed here

Unlike the first two libraries (NI **UTF Junit Report** and **JUnit Results API**,
both Apache-2.0 and published as source on GitHub), the **Simple XML** library is
**not available from any open-source repository**:

- It is distributed only as a **VIPM package** (`ni_lib_simple_xml`, "Simple XML by
  NI", v1.0.0.4, Jul 2016, **NI Sample Code License**) whose download is **sign-in
  gated** on vipm.io.
- The only copies on GitHub are a **renamed, namespaced fork** —
  `Simple XML Improved.lvlib`, embedded inside NI VeriStand driver libraries
  (`ni/niveristand-set-*`). Because LabVIEW resolves the static links by the exact
  qualified name `Simple XML.lvlib:Create Tag.vi`, that renamed fork **cannot**
  satisfy them.
- The modern VIPM CLI cannot install it headlessly in the container either: it
  requires **VIPM Pro activation** (a paid serial), so `vipm apply_vipc` silently
  skips it. (That is why the whole chain is vendored + mirrored instead.)

The binary `.vi`/`.ctl`/`.lvlib` files therefore have to be supplied from a machine
that already has the library installed.

## How to obtain the files (drop them into THIS folder)

On any Windows machine with **LabVIEW + the NI Unit Test Framework / JUnit toolchain
installed** (installing the JUnit Results API VIPM package pulls `ni_lib_simple_xml`
as a dependency), copy the contents of:

```
C:\Program Files\National Instruments\LabVIEW <YYYY>\vi.lib\NI\Simple XML\
```

(or wherever `Simple XML.lvlib` lives — search the machine for `Simple XML.lvlib`)
into this folder, preserving the subfolder layout. Alternatively, download the
`ni_lib_simple_xml` package from VIPM and extract `vi.lib\NI\Simple XML\` from it (a
`.vip` is a zip archive).

### Exact files expected (layout matters)

```
simple-xml/
  Simple XML.lvlib
  Convert to Pretty Print.vi
  Create Tag.vi
  Save Pretty Print.vi
  String to Number.vi
  _polymorphics/
    Create Tag - Root.vi
    Create Tag - Child.vi
    Create Tag - Child with Text.vi
  _private/
    Generate Error Cluster.vi
    Insert Newline.vi
    Insert Substring.vi
    Insert Tab.vi
    Parser States.ctl
```

(`Example.vi`, if present, is optional and not required by the JUnit API.)

The library's member URLs are `../<name>.vi`, `../_polymorphics/<name>.vi` and
`../_private/<name>.vi` (relative to the `.lvlib`), so keeping the `.lvlib` at the
folder root with the VIs as siblings and the two subfolders intact is what makes the
links resolve. `Repair-SimpleXml` keys off `Simple XML.lvlib` and mirrors the tree
recursively, so once these files are present the next unit-tests run completes the
chain with no further changes.

## Provenance / license

- Library: **Simple XML** by NI (VIPM package `ni_lib_simple_xml`), author Allen C.
  Smith. License: **NI Sample Code License (NI SCL)**.
- Keep the NI license/disclaimer alongside the files when vendoring them.
</content>
</invoke>
