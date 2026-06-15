# PrintToSingleFileHtml — Custom LabVIEWCLI Operation

This folder must contain the **PrintToSingleFileHtml** custom LabVIEWCLI operation VIs
before the VI Snapshots and VIDiff workflows can export HTML reports.

## Where to get these files

Copy all `.vi` and support files from NI's `labview-for-containers` repository:

```
https://github.com/ni/labview-for-containers/tree/main/examples/cicd-examples/helper-scripts/vidiff/PrintToSingleFileHtml/
```

The files you need are:
- `PrintToSingleFileHtml.vi`  (the main operation VI)
- Any support VIs in the same directory

## How it is used

The CI scripts pass this folder to `LabVIEWCLI.exe` via:

```
LabVIEWCLI.exe \
  -OperationName                PrintToSingleFileHtml \
  -AdditionalOperationDirectory "C:\workspace\.github\labview\PrintToSingleFileHtml" \
  -LabVIEWPath                  "C:\Program Files\National Instruments\LabVIEW 2024\LabVIEW.exe" \
  -VIPath                       "path\to\my.vi" \
  -ExportPath                   "path\to\output.html"
```

## Why it isn't included here

These are compiled LabVIEW VI binary files (`.vi`) that NI ships as examples in their
`labview-for-containers` repository. They cannot be created as text placeholders — they
must be the actual binary VI files compiled for the correct LabVIEW version.

Clone NI's repo and copy the matching LabVIEW 2024 VIs into this folder.
