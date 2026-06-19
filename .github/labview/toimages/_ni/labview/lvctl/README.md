# lvctl — LabVIEW Control CLI

`lvctl` is a command-line tool for automating LabVIEW on Windows via COM/ActiveX (VI Server). It can convert VIs to/from XML, convert VIs to image JSON, run arbitrary VIs, and read/write LabVIEW properties.

## Requirements

- **Windows** (COM automation is Windows-only)
- **LabVIEW** installed (any recent version; tested with LabVIEW 2026)

If LabVIEW is not already running, `lvctl` will launch it automatically and minimize the window. Subsequent calls reuse the running instance.

## Installation

Build from source (requires Go 1.26.3+):

```sh
cd src/labview/lvctl
go build -o lvctl.exe .
```

The embedded generator assets must be present before building. Copy them from:
- `src/labview/vi-xml/VIs/LV AI Core.zip`
- `src/shared/labview/lv_listener.zip`

## Commands

### `toxml` — Convert a VI to XML

```sh
lvctl toxml <path-to-vi> [output.xml]
```

Converts a LabVIEW `.vi` file to XML. If output is omitted, writes to stdout.

| Flag | Description |
|------|-------------|
| `--vi-to-xmlvi` | Custom generator VI path (uses embedded VI by default) |
| `--max-file-size` | Maximum input file size in MiB (default: 10) |
| `--timeout` | Operation timeout (default: 2m) |

**Examples:**
```sh
# Convert to stdout
lvctl toxml "My Test.vi"

# Convert to a file
lvctl toxml "My Test.vi" output.xml

# Verbose output
lvctl -v toxml "My Test.vi"
```

### `fromxml` — Convert XML back to a VI

```sh
lvctl fromxml <path-to-xml> <output.vi>
```

Converts an XML file (produced by `toxml`) back to a `.vi` file.

| Flag | Description |
|------|-------------|
| `--xml-to-vivi` | Custom generator VI path (uses embedded VI by default) |
| `--max-file-size` | Maximum input file size in MiB (default: 10) |
| `--timeout` | Operation timeout (default: 2m) |

**Example:**
```sh
lvctl fromxml output.xml "Restored Test.vi"
```

### `toimages` — Convert a VI to image JSON

```sh
lvctl toimages <path-to-vi>
```

By default, uses the embedded `toimages/` asset tree (compiled into the binary), extracts it into a cache directory, runs `Get VI Info.vi` against a `.vi`, and writes the generated image JSON to stdout.

| Flag | Description |
|------|-------------|
| `--get-vi-info-vi` | Custom path to `Get VI Info.vi` |
| `--max-file-size` | Maximum input file size in MiB (default: 10) |
| `--timeout` | Operation timeout (default: 2m) |

**Examples:**
```sh
# Write image JSON to stdout using embedded toimages assets
lvctl toimages "My Test.vi"

# Use an explicit Get VI Info.vi path
lvctl toimages --get-vi-info-vi "C:\\path\\to\\Get VI Info.vi" "My Test.vi"
```

### `run` — Run any VI

```sh
lvctl run <path-to-vi> [flags]
```

Runs a VI, optionally setting controls and reading indicators.

| Flag | Description |
|------|-------------|
| `-s, --set name=value` | Set a control value (repeatable) |
| `-g, --get name` | Read an indicator after execution (repeatable) |
| `--search-dirs dir` | Additional VI search directories (repeatable) |
| `--timeout` | Execution timeout (default: 2m) |

**Examples:**
```sh
# Run a VI with inputs and read the result
lvctl run "X Plus Y.vi" -s "X=5" -s "Y=3" -g "X+Y"
# Output: 8

# Run a VI with no inputs/outputs (just execute it)
lvctl run "Initialize Hardware.vi"

# Read multiple indicators (outputs as JSON)
lvctl run "Analyze.vi" -s "Input=42" -g "Mean" -g "StdDev"
```

### `get` — Read a LabVIEW property

```sh
lvctl get <property> [--vi <path>]
```

Reads a property from the LabVIEW Application object, or from a specific VI.

**Examples:**
```sh
# Application properties
lvctl get Version        # => 26.1.1f1
lvctl get AppName        # => LabVIEW.exe

# VI properties
lvctl get ExecState --vi "My Test.vi"
```

### `set` — Write a LabVIEW property

```sh
lvctl set <property> <value> [--vi <path>] [--int] [--bool]
```

Writes a property on the LabVIEW Application object or a VI.

| Flag | Description |
|------|-------------|
| `--vi path` | Target a VI instead of the Application |
| `--int` | Interpret value as an integer |
| `--bool` | Interpret value as a boolean |

**Examples:**
```sh
# Set an application property
lvctl set ShowFPOnLoad false --bool

# Set a VI property
lvctl set FPWinOpen true --bool --vi "My Test.vi"
```

### `call` — Call a LabVIEW method

```sh
lvctl call <method> [args...] [--vi <path>]
```

Invokes a method on the LabVIEW Application or a VI.

**Examples:**
```sh
# Quit LabVIEW
lvctl call Quit

# Get a VI's version info
lvctl call GetVIVersion --vi "My Test.vi"

# Call an application method with arguments
lvctl call MassCompile "C:\VIs"
```

## LabVIEW COM/ActiveX Reference

`lvctl` uses the `LabVIEW.Application` COM ProgID. The reference below is generated from `labview.tlb` (LabVIEW 2026). Members prefixed with `_` are internal/undocumented.

### Application Properties

| Property | Type | R/W | Description |
|----------|------|-----|-------------|
| `AppName` | string | R | Application name |
| `UserName` | string | R/W | User name |
| `Version` | string | R | Version number (e.g. `26.1.1f1`) |
| `AppKind` | AppKindEnum | R | Application kind (dev, runtime, etc.) |
| `AppTargetOS` | AppTargOSEnum | R | Target operating system |
| `AppTargetCPU` | AppTargCPUEnum | R | Target CPU |
| `OSName` | string | R | Operating system name |
| `OSVersion` | string | R | OS version number |
| `OSBuildNumber` | string | R | OS build number |
| `OSDetailedName` | string | R | Detailed OS name |
| `ExportedVIs` | variant | R | Exported VIs in memory |
| `ApplicationDirectory` | string | R | LabVIEW install directory path |
| `AllVIsInMemory` | variant | R | All VIs currently in memory |
| `AllVIsPathsInMemory` | variant | R | Paths of all VIs in memory |
| `AllDirtyVIsAndLibs` | variant | R | Unsaved VIs and libraries |
| `AutomaticClose` | bool | R/W | Close LabVIEW when last reference released |
| `ShowFPTipStrips` | bool | R/W | Show front panel tip strips |
| `PrintingColorDepth` | bool | R/W | Color/grayscale printing |
| `PrintDefaultPrinter` | string | R/W | Default printer name |
| `PrintMethod` | PrintMethodsEnum | R/W | Print method |
| `PrintersAvailable` | variant | R | Available printers |
| `CmdArgs` | variant | R | Command line arguments |
| `DefaultDataLocation` | string | R | Default data directory |
| `RTHostConnected` | bool | R | User interface available |
| `VIServerPort` | int | R/W | VI Server TCP port |
| `Language` | string | R | Application language |
| `AllProjects` | variant | R | All open projects |
| `SaveVersions` | variant | R | Saveable LabVIEW versions |
| `SaveVersion` | string | R | Current save version |
| `VersionYear` | string | R | Version year |
| `FullVersionYear` | string | R | Full version year |
| `VersionYearNumberOnly` | string | R | Version year (number only) |
| `VersionDisplayName` | string | R | Display name of this version |
| `AutoInlining` | bool | R/W | Compiler auto-inlining |
| `ShowAutoErrDialog` | bool | R/W | Show automatic error dialog |
| `EnableBinaryCompatibilityLoad` | bool | R/W | Enable binary compatibility load |
| `IgnoreUnresolvedDLLRef` | bool | R | Ignore unresolved DLL references |
| `NativeEventTracingEnabled` | bool | R/W | ETW event tracing enabled |
| `TargetStructureEnabled` | bool | R/W | Target structure enabled |
| `ImageTableMaxCount` | int | R | Image table max count |
| `ImageTableCount` | int | R | Image table current count |
| `PrintSetupFileWrapText` | int | R/W | Printing file wrap text length |
| `PrintSetupPNGCompressLevel` | int | R/W | PNG compression level |
| `PrintSetupJPEGQuality` | int | R/W | JPEG quality |
| `PrintSetupCustomConnector` | bool | R/W | Print custom connector |
| `PrintSetupCustomDescription` | bool | R/W | Print custom description |
| `PrintSetupCustomPanel` | bool | R/W | Print custom panel |
| `PrintSetupCustomPanelBorder` | bool | R/W | Print custom panel border |
| `PrintSetupCustomControls` | bool | R/W | Print custom controls |
| `PrintSetupCustomControlDesc` | bool | R/W | Print custom control descriptions |
| `PrintSetupCustomControlTypes` | bool | R/W | Print custom control types |
| `PrintSetupCustomDiagram` | bool | R/W | Print custom diagram |
| `PrintSetupCustomDiagramHidden` | bool | R/W | Print custom diagram hidden |
| `PrintSetupCustomDiagramRepeat` | bool | R/W | Print custom diagram repeat |
| `PrintSetupCustomSubVIs` | bool | R/W | Print custom list of subVIs |
| `PrintSetupCustomHierarchy` | bool | R/W | Print custom hierarchy |
| `PrintSetupCustomHistory` | bool | R/W | Print custom history |
| `PrintSetupCustomExpressVIConfigInfo` | bool | R/W | Print Express VI configuration |
| `PrintSetupCustomLabel` | variant | R/W | Print custom control label/caption |
| `PrintSetupCustomClusterConstants` | bool | R/W | Print custom cluster constants |

### Application Methods

| Method | Parameters | Returns | Description |
|--------|-----------|---------|-------------|
| `Quit()` | — | — | Quit LabVIEW |
| `BringToFront()` | — | — | Bring application windows to front |
| `GetVIReference(viPath, password, resvForCall, options)` | string, string, bool, int | IDispatch | Load a VI and return a reference |
| `GetVIVersion(viPath, versNum)` | string, ptr | string | Get file format version of a VI |
| `GetVIEditorVersion(viPath, versNum)` | string, ptr | string | Get LabVIEW version that last saved a VI |
| `MassCompile(directory, logFile, appendLog, viCacheSize, reloadLVSBs, userStop)` | string, string, bool, int, bool, ptr | — | Mass compile all VIs in a directory |
| `OpenProject(Path)` | string | IDispatch | Load a LabVIEW project |
| `NewProject()` | — | IDispatch | Create an empty project |
| `OpenLibrary(Path)` | string | IDispatch | Open a project library |
| `CreateLibrary(createPalette)` | bool | IDispatch | Create a new project library |
| `ResolveSymbolicPath(symbolicPath, actualPath)` | string, ptr | — | Convert symbolic path to absolute |
| `BrowseDataSocket(prompt, selectedURL)` | string, ptr | — | Launch DataSocket browser dialog |
| `LibraryGetFileLVVersion(libPath, versNum)` | string, ptr | string | Get file format version of a library |
| `ProjectGetFileLVVersion(projectPath, versNum)` | string, ptr | string | Get file format version of a project |
| `GetHierImgScaled(imgDepth, imgdata, maxwidth, maxheight, VIToHighlight)` | int, ptr, int, int, variant | — | Get scaled hierarchy image |
| `AllMethodsOfLVClass(MethodNames, MethodPaths, Path, scope, OnlyVIsWithClassIn)` | ptr, ptr, string, enum, bool | — | List all methods of a class |
| `AllMethodsOfLVClass2(MethodNames, MethodPaths, Path, scope)` | ptr, ptr, string, enum | — | List all methods of a class (v2) |
| `LVClassImplementingVIPath(PathToVI, ClassPath, MethodName, scope)` | ptr, string, string, enum | — | Find VI implementing a class method |
| `BuildObjectCache(VIPaths, ObjCacheName, LogFilePath, AppendToLogFile, ObjCachePath)` | variant, string, string, bool, ptr | — | Build adjacent object cache |
| `InstallAdjCache(AdjCachePath, LogFilePath, AppendToLogFile)` | string, string, bool | — | Install adjacent cache |
| `ClearUserAndLVAddonsCompiledObjectCache()` | — | — | Delete compiled code in object caches |
| `ExportVIsStringsUTF8(viRefArray, stringFile, interactive, logFile, createCaptions, exportDiagram, errArray)` | variant, string, bool, string, bool, bool, ptr | — | Export UI strings of VIs to file |
| `NativeEventTracingSetup(ContextName, options)` | string, string | — | Configure ETW event tracing |
| `IsCalleeInlined(callerVIRef, calleeVIRef)` | variant, variant | bool | Check if callee is inlined |
| `SetGlobalBackwardCompatibleLoadEnabled(Enabled)` | bool | — | Enable/disable backward compatible RTE |
| `IsGlobalBackwardCompatibleLoadEnabled()` | — | bool | Check if backward compatible RTE enabled |
| `PackedLibraryIsLoadableInBinaryCompatibleLV(libPath)` | string | bool | Check if PPL supports binary compat |
| `CreateLVClassInterfaceLibrary(createPalette, Name, directory)` | bool, string, string | variant | Create a new LabVIEW interface |
| `NewProjectWithPrivateContexts()` | — | IDispatch | Create project with private contexts |

### VI Properties

| Property | Type | R/W | Description |
|----------|------|-----|-------------|
| `Name` | string | R/W | VI file name |
| `Path` | string | R | Full file path |
| `Description` | string | R/W | VI description |
| `HistoryText` | string | R | Revision history text |
| `VIType` | VITypeEnum | R | VI type (standard, global, polymorphic, etc.) |
| `ExecState` | ExecStateEnum | R | Execution state |
| `ExecPriority` | VIPriorityEnum | R/W | Execution priority |
| `PreferredExecSystem` | VIExecSysEnum | R/W | Preferred execution system |
| `AllowDebugging` | bool | R/W | Allow debugging |
| `ShowFPOnLoad` | bool | R/W | Show front panel on load |
| `ShowFPOnCall` | bool | R/W | Show front panel on call |
| `CloseFPAfterCall` | bool | R/W | Close front panel after call |
| `RunOnOpen` | bool | R/W | Run when opened |
| `SuspendOnCall` | bool | R/W | Suspend on call |
| `IsReentrant` | bool | R/W | Is reentrant |
| `ReentrancyType` | variant | R/W | Reentrancy type |
| `ExecInlining` | bool | R/W | Inline subVI |
| `ExecInlineIfPossible` | bool | R/W | Inline subVI if possible |
| `ExecIsInlineable` | bool | R | Inlining is allowed |
| `ExecInliningEnum` | int | R/W | Inline enum value |
| `EditMode` | bool | R/W | Edit mode on open |
| `IsProbe` | bool | R | Is probe VI |
| `IsCloneVI` | bool | R | Is clone VI |
| `CloneName` | string | R | Clone name |
| `NumClones` | int | R | Number of clones |
| `FPWinOpen` | bool | R/W | Front panel window open |
| `FPWinIsFrontMost` | bool | R/W | Front panel is frontmost |
| `FPWinBounds` | variant | R/W | Front panel window bounds |
| `FPWinOrigin` | variant | R/W | Front panel window origin |
| `FPWinPanelBounds` | variant | R/W | Front panel panel bounds |
| `FPWinTitle` | string | R/W | Front panel window title |
| `FPWinCustomTitle` | bool | R/W | Use custom title |
| `FPState` | FPStateEnum | R/W | Front panel window state |
| `FPBehavior` | FPBehaviorEnum | R/W | Front panel behavior |
| `FPTitleBarVisible` | bool | R/W | Title bar visible |
| `FPWinClosable` | bool | R/W | Window closeable |
| `FPResizable` | bool | R/W | Old resizable flag |
| `FPResizeable` | bool | R/W | Resizable |
| `FPMinimizeable` | bool | R/W | Minimizable |
| `FPKeepWinProps` | bool | R/W | Keep window proportions |
| `FPAllowRTPopup` | bool | R/W | Allow runtime popup |
| `FPHiliteReturnButton` | bool | R/W | Highlight return button |
| `FPSizeToScreen` | bool | R/W | Size to screen (deprecated) |
| `FPAutoCenter` | bool | R/W | Auto center (deprecated) |
| `FPShowScrollBars` | bool | R/W | Show scroll bars |
| `FPShowMenuBar` | bool | R/W | Show menu bar |
| `FPTransparency` | int | R/W | Window transparency |
| `FPRunTransparently` | bool | R/W | Run VI transparently |
| `FPMonitor` | int | R/W | Target monitor |
| `TBVisible` | bool | R/W | Toolbar visible |
| `TBShowRunButton` | bool | R/W | Show run button |
| `TBShowFreeRunButton` | bool | R/W | Show free run button |
| `TBShowAbortButton` | bool | R/W | Show abort button |
| `RevisionNumber` | int | R/W | Revision number |
| `HistUseDefaults` | bool | R/W | History: use defaults |
| `HistAddCommentsAtSave` | bool | R/W | Always add comments at save |
| `HistPromptAtClose` | bool | R/W | Prompt for comments at close |
| `HistPromptForCommentsAtSave` | bool | R/W | Prompt for comments at save |
| `HistRecordAppComments` | bool | R/W | Record app comments |
| `HelpDocumentTag` | string | R/W | Help document tag |
| `HelpDocumentPath` | string | R/W | Help document path |
| `HelpDocumentUrl` | string | R/W | Help document web URL |
| `HelpUseOnline` | bool | R/W | Use web URL for help |
| `CodeSize` | int | R | Compiled code size |
| `DataSize` | int | R | Total data size |
| `FPSize` | int | R | Front panel size |
| `BDSize` | int | R | Block diagram size |
| `Callers` | variant | R | Caller VI names |
| `Callees` | variant | R | Callee VI names |
| `VIModificationBitSet` | int | R | VI modifications bitset |
| `FPModificationBitSet` | int | R | Front panel modifications bitset |
| `BDModificationBitSet` | int | R | Block diagram modifications bitset |
| `LogFilePath` | string | R/W | Auto-log file path |
| `LogAtFinish` | bool | R/W | Log at finish |
| `PrintLogFileAtFinish` | bool | R/W | Print log at finish |
| `RunTimeMenuPath` | string | R/W | Runtime menu path |
| `ExpandWhenDroppedAsSubVI` | bool | R/W | Expand when dropped as subVI |
| `Library` | IDispatch | R | Owning library reference |
| `OwningApp` | IDispatch | R | Owning application reference |
| `PrintingOrientation` | PageOrientationEnum | R/W | Page orientation |
| `PrintingHeaders` | bool | R/W | Page headers |
| `PrintingFPScaling` | bool | R/W | Front panel scaling |
| `PrintingBDScaling` | bool | R/W | Block diagram scaling |
| `PrintMargins` | variant | R/W | Print margins |
| `PrintHeaderVIName` | bool | R/W | Header: VI name |
| `PrintHeaderDatePrint` | bool | R/W | Header: date printed |
| `PrintHeaderModifyDate` | bool | R/W | Header: modify date |
| `PrintHeaderPageNumber` | bool | R/W | Header: page number |
| `PrintHeaderVIIcon` | bool | R/W | Header: VI icon |
| `PrintingHeaderVIPath` | bool | R/W | Header: VI path |

### VI Methods

| Method | Parameters | Returns | Description |
|--------|-----------|---------|-------------|
| `Run(async)` | bool | — | Run the VI (`true` = wait, `false` = async) |
| `Abort()` | — | — | Abort execution |
| `SetControlValue(controlName, value)` | string, variant | — | Set a front panel control/indicator value |
| `GetControlValue(controlName)` | string | variant | Get a front panel control/indicator value |
| `Call(paramNames, paramVals)` | ptr, ptr | — | Call the VI as a subVI |
| `Call2(paramNames, paramVals, openFP, CloseFPAfterCall, SuspendOnCall, bringAppToFront)` | ptr, ptr, bool, bool, bool, bool | — | Call VI with front panel options |
| `SaveInstrument(viPath, saveACopy, withoutDiagram)` | string, bool, bool | — | Save the VI |
| `SaveForPrevious(viPath, warnings, Version)` | string, ptr, string | — | Save for a previous LabVIEW version |
| `Revert()` | — | — | Discard changes and reload from disk |
| `MakeCurValueDefault()` | — | — | Make current control values the defaults |
| `ReinitializeAllToDefault()` | — | — | Reset all controls to defaults |
| `GetLockState(pwdInCache)` | ptr | variant | Get VI lock state |
| `SetLockState(lockState, interactive, password, putInCache)` | variant, bool, string, bool | — | Set VI lock state |
| `GetPanelImage(visibleOnly, imgDepth, img, colors, bounds)` | bool, int, ptr, ptr, ptr | — | Get front panel image |
| `PrintPanel(entirePanel)` | bool | — | Print front panel |
| `PrintVIToPrinter(format, scalePanel, scaleDiagram, pageHeaders, pageBreaks, sectionHeaders)` | enum, bool, bool, bool, bool, bool | — | Print VI to printer |
| `PrintVIToHTML(htmlFilePath, append, format, imageFormat, imageDepth, imageDirectory)` | string, bool, enum, enum, int, string | — | Save VI info to HTML |
| `PrintVIToRTF(rtfFilePath, append, format, imageFormat, imageDepth, imageDirectory, helpFormat)` | string, bool, enum, int, int, string, bool | — | Save VI info to RTF |
| `PrintVIToText(textFilePath, append, format)` | string, bool, enum | — | Save VI info to text |
| `ExportVIStrings(stringFile, interactive, logFile, captions, exportDiagram)` | string, bool, string, bool, bool | — | Export UI strings to file |
| `ExportVIStringsUTF8(stringFile, interactive, logFile, captions, exportDiagram)` | string, bool, string, bool, bool | — | Export UI strings (UTF-8) |
| `ImportVIStrings(stringFile, interactive, logFile)` | string, bool, string | — | Import UI strings from file |
| `SetVIIcon(imageFile)` | string | — | Set VI icon from image file |
| `OpenFrontPanel(activate, state)` | bool, FPStateEnum | — | Open front panel window |
| `CloseFrontPanel()` | — | — | Close front panel window |
| `CenterFrontPanel()` | — | — | Center front panel on screen |
| `FPRunTimePosRunUnchanged()` | — | — | Keep position when running |
| `FPRunTimePosRunCentered(monitor, size)` | int, variant | — | Center front panel when running |
| `FPRunTimePosRunMax(monitor)` | int | — | Maximize front panel when running |
| `FPRunTimePosRunMin(monitor)` | int | — | Minimize front panel when running |
| `FPRunTimePosRunCustom(position, size)` | variant, variant | — | Custom position when running |
| `FPGetRuntimePos(Type, position, size, monitor, useCurPos, useCurSize)` | ptr, ptr, ptr, ptr, ptr, ptr | — | Get default runtime position |
| `SaveRunTimeMenu(filePath)` | string | — | Save runtime menu to file |
| `DisconnectFromLibrary()` | — | — | Disconnect VI from owning library |
| `GetVIDependencies(dependencyNames, dependencyPaths, wholeHierarchy, ...)` | many | — | Get VI dependencies |

### Enums

#### ExecStateEnum — VI Execution State

| Name | Value | Description |
|------|-------|-------------|
| `eBad` | 0 | Broken or not loaded |
| `eIdle` | 1 | Not running |
| `eRunTopLevel` | 2 | Running as top-level VI |
| `eRunning` | 3 | Running as subVI |

#### AppKindEnum — Application Kind

| Name | Value | Description |
|------|-------|-------------|
| `eInvalidAppKind` | 0 | Invalid |
| `eDevSysKind` | 1 | Development system |
| `eRunTimeSysKind` | 2 | Runtime system |
| `eStudEdKind` | 3 | Student edition |
| `eEmbeddedKind` | 4 | Embedded |
| `eEvaluationKind` | 5 | Evaluation |

#### FPStateEnum — Front Panel State

| Name | Value | Description |
|------|-------|-------------|
| `eInvalidFPState` | 0 | Invalid |
| `eVisible` | 1 | Visible (standard) |
| `eClosed` | 2 | Closed |
| `eHidden` | 3 | Hidden |
| `eMinimized` | 4 | Minimized |
| `eMaximized` | 5 | Maximized |

#### FPBehaviorEnum — Front Panel Behavior

| Name | Value | Description |
|------|-------|-------------|
| `eInvalidFPBehavior` | 0 | Invalid |
| `eDefaultFPBehavior` | 1 | Default |
| `eFloating` | 2 | Floating |
| `eFloatingAutoHide` | 3 | Floating, auto-hide |
| `eModal` | 4 | Modal |

#### VITypeEnum — VI Type

| Name | Value | Description |
|------|-------|-------------|
| `eInvalidVIType` | 0 | Invalid |
| `eStandardVIType` | 1 | Standard VI |
| `eControlVIType` | 2 | Control VI |
| `eGlobalVIType` | 3 | Global VI |
| `ePolymorphicVIType` | 4 | Polymorphic VI |
| `eConfigurationVIType` | 5 | Configuration VI |
| `eSubSystemVIType` | 6 | Subsystem VI |
| `eFacadeVIType` | 7 | Facade VI |
| `eMethodVIType` | 8 | Method VI |
| `eStatechartVIType` | 9 | Statechart VI |

#### VIPriorityEnum — VI Priority

| Name | Value | Description |
|------|-------|-------------|
| `ePriInvalid` | 0 | Invalid |
| `ePriBackground` | 1 | Background |
| `ePriNormal` | 2 | Normal |
| `ePriAboveNormal` | 3 | Above normal |
| `ePriHigh` | 4 | High |
| `ePriCritical` | 5 | Time critical |
| `ePriSubroutine` | 6 | Subroutine |

#### VIExecSysEnum — Preferred Execution System

| Name | Value | Description |
|------|-------|-------------|
| `eESysInvalid` | 0 | Invalid |
| `eESysUserInterface` | 1 | User interface |
| `eESysNormal` | 2 | Standard |
| `eESysInstrIO` | 3 | Instrument I/O |
| `eESysDAQ` | 4 | Data acquisition |
| `eESysOther1` | 5 | Other 1 |
| `eESysOther2` | 6 | Other 2 |
| `eESysSameAsCaller` | 7 | Same as caller |

#### VILockStateEnum — VI Lock State

| Name | Value | Description |
|------|-------|-------------|
| `eInvalidLockState` | 0 | Invalid |
| `eUnlockedState` | 1 | Unlocked |
| `eLockedNoPwdState` | 2 | Locked (no password) |
| `ePwdProtectedState` | 3 | Password protected |

#### FPRunTimePosEnum — Front Panel Runtime Position

| Name | Value | Description |
|------|-------|-------------|
| `eRTPUnchanged` | 0 | Unchanged |
| `eRTPCentered` | 1 | Centered |
| `eRTPMaximized` | 2 | Maximized |
| `eRTPMinimized` | 3 | Minimized |
| `eRTPCustom` | 4 | Custom position |

#### PageOrientationEnum

| Name | Value |
|------|-------|
| `ePortrait` | 0 |
| `eLandscape` | 1 |
| `eRotatedPortrait` | 2 |
| `eRotatedLandscape` | 3 |

#### PrintFormatEnum

| Name | Value |
|------|-------|
| `eCustom` | 0 |
| `eStandard` | 1 |
| `eUsingPanel` | 2 |
| `eUsingSubVI` | 3 |
| `eComplete` | 4 |

#### HTMLImageFormatEnum

| Name | Value |
|------|-------|
| `ePNG` | 0 |
| `eJPEG` | 1 |
| `eGIF` | 2 |

## Global Flags

| Flag | Description |
|------|-------------|
| `-v, --verbose` | Enable verbose/debug logging to stderr |
| `--version` | Print version and exit |

## Behavior

- **Auto-launch**: If LabVIEW is not running, `lvctl` launches it via COM. The window is minimized automatically.
- **Reuse**: If LabVIEW is already running, `lvctl` attaches to the existing instance without disturbing it.
- **No cleanup**: `lvctl` does not quit LabVIEW. Once launched, it stays running for fast subsequent calls.
- **Quiet by default**: Status messages only appear with `-v`. Stdout contains only the command's output (XML, indicator values, property values).
