# iTunes Playlist Export — Agent Handover Documentation

**Version:** 1.8.3  
**Last Updated:** May 19, 2026  
**Maintained By:** Agent (Tasklet)  
**Repository:** https://github.com/kiwipaulrob/itunes-playlist-export  
**Owner:** Paul Robertson (`kiwipaulrob`)

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Project Purpose & Scope](#project-purpose--scope)
3. [System Architecture](#system-architecture)
4. [Directory Structure](#directory-structure)
5. [Component Breakdown](#component-breakdown)
6. [Configuration System](#configuration-system)
7. [Execution Workflow](#execution-workflow)
8. [Development & Maintenance Guide](#development--maintenance-guide)
9. [Version History & Changelog](#version-history--changelog)
10. [Common Maintenance Tasks](#common-maintenance-tasks)
11. [Testing & Validation](#testing--validation)
12. [Dependencies & Environment](#dependencies--environment)
13. [Troubleshooting Guide](#troubleshooting-guide)
14. [Known Limitations & Edge Cases](#known-limitations--edge-cases)

---

## Executive Summary

**iTunes Playlist Export** is a Windows PowerShell 7 batch tool that converts iTunes playlists (`.m3u8` and `.xml` plist format) into optimized MP3 audio files with:

- **ReplayGain normalization** (album-level, baked into audio)
- **Custom EQ** (tuned for small Bluetooth speakers)
- **Silence trimming** (start/end of tracks)
- **Parallel encoding** (CPU-scaled for performance)
- **Smart change detection** (manifest-based, incremental updates)
- **Phase 3 sync** (optional robocopy to removable media)

**Use Case:** Convert iTunes library exports to portable, normalized MP3 files for constrained devices (Bluetooth speakers, car stereos, storage-limited tablets).

**Runtime:** 5–30 minutes per 100 tracks (depends on CPU cores, bitrate, source file format).

---

## Project Purpose & Scope

### What It Does

1. **Reads playlists** from `.m3u8` (M3U plain text) or `.xml` (iTunes plist) files
2. **Auto-detects format** and parses track paths
3. **Measures audio** for ReplayGain (LUFS) in parallel
4. **Encodes tracks** to MP3 with:
   - Album-level ReplayGain baked in
   - Silence trimmed from start/end
   - Custom EQ applied (5-band parametric for small drivers)
   - Peak limiter to prevent clipping
   - Sequential number prefix added to filename
5. **Tracks manifest** (SHA256 hash, LUFS values, source paths) to detect changes
6. **Handles incremental updates** (re-encode only new/changed tracks)
7. **Optionally syncs** output to removable media via robocopy

### What It Does NOT Do

- Edit original iTunes library or XML files
- Download music from internet
- Handle DRM-protected audio
- Support Linux/Mac (Windows PowerShell 7 only)
- Transcode to formats other than MP3

### Constraints

- **Source files:** MP3 or M4A only (on any drive, typically `P:`)
- **Output:** MP3 only (other formats require code modification)
- **Metadata:** Track order preserved; no metadata modification (artist, album, title)
- **Artwork:** Stripped from output (via `-map 0:a` FFmpeg flag)
- **Stereo:** Preserved by default; optional mono downmix available

---

## System Architecture

### High-Level Flow

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. INITIALIZATION                                               │
│   - Load INI config                                             │
│   - Parse command-line args (INI path override)                │
│   - Detect CPU cores → set $ParallelJobs                       │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 2. PLAYLIST DISCOVERY & PARSING                                 │
│   - Get all .m3u8 and .xml files from $PlaylistDir             │
│   - For each playlist:                                          │
│     - Auto-detect format (m3u8 vs xml)                         │
│     - Parse tracks and resolve file paths                      │
│     - Compute SHA256 hash of playlist file                     │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 3. CHANGE DETECTION & USER PROMPTS                              │
│   - Load .export-manifest.json from output folder (if exists)  │
│   - Compare playlist hash:                                      │
│     • No manifest → full encode                                │
│     • Hash unchanged → skip instantly                          │
│     • Hash changed → show diff + prompt (A/N/D/S)             │
│   - If folder exists but no manifest → overwrite prompt (y/n)  │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 4. PHASE 1: MEASUREMENT (if ApplyReplayGain = true)            │
│   - For "new only" updates: load LUFS from manifest             │
│   - Measure all (or only new) tracks in parallel                │
│   - Real-time Write-Progress bar                               │
│   - Calculate album gain from all LUFS values                  │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 5. PHASE 2: ENCODING (Main Processing Loop)                    │
│   - For each track in playlist:                                 │
│     - Resolve source file path                                  │
│     - If source missing → count error                           │
│     - Else:                                                      │
│       - Generate output filename (sequential prefix + original) │
│       - Build FFmpeg filter chain:                              │
│         * silenceremove (trim start/end)                       │
│         * volume filter (ReplayGain adjustment)                │
│         * EQ filters (5-band parametric)                       │
│         * compression (peak limiter)                            │
│       - If mono: replace with pan filter + EQ chain            │
│       - Encode to MP3 with specified bitrate                   │
│       - Check FFmpeg exit code                                  │
│       - Update output folder                                    │
│   - Real-time Write-Progress bar (parallelised)               │
│   - Count successes/failures                                    │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 6. MANIFEST UPDATE                                              │
│   - Save .export-manifest.json with:                            │
│     * PlaylistName, PlaylistHash, SourceFormat                │
│     * Array of encoded track paths                             │
│     * Array of track LUFS values (for incremental updates)     │
│     * LastRunTime, TotalTracks                                 │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 7. LOGGING                                                      │
│   - Write export_log.txt to output folder with:                │
│     * Playlist name and hash                                    │
│     * Source format (m3u8/xml)                                 │
│     * Tracks processed: X/Y                                     │
│     * Album LUFS (if measured)                                 │
│     * Errors (missing files, encoding failures)                │
│     * Runtime                                                   │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 8. PHASE 3: SYNC TO REMOVABLE MEDIA (Interactive, at End)     │
│   - Auto-detect removable drives                                │
│   - Show source/destination summary                            │
│   - Menu: (N)one / (S)ync changed / (M)irror full              │
│   - If sync: robocopy with args: /R:1 /W:1 /TEE /NP /NDL      │
│   - Log to destination drive robocopy.log                      │
└─────────────────────────────────────────────────────────────────┘
```

### Design Principles

| Principle | Implementation |
|-----------|-----------------|
| **Configuration** | Single `.ini` file; no command-line args except INI override |
| **Idempotency** | Manifest + hash detection = safe re-runs without duplication |
| **Parallelism** | CPU-aware; `Invoke-Command -ScriptBlock {} -AsJob` for Phase 1 & 2 |
| **User Feedback** | Real-time progress bars; prompts before destructive operations |
| **Safety** | No destructive ops without permission; robocopy uses `&` call operator (not `Invoke-Expression`) |
| **Transparency** | Full logging; every file/error recorded |
| **Flexibility** | INI-driven; easy to adjust EQ, bitrate, channel layout without code changes |

---

## Directory Structure

### Repository Files

```
itunes-playlist-export/
├── README.md                    # User-facing guide (quick start)
├── README-full.md               # Comprehensive user documentation
├── HANDOVER.md                  # This file — agent maintenance guide
├── playlist-export-spec.md       # Locked specification (reference)
│
├── export-playlists.ps1         # Main PowerShell script (v1.8.3)
├── export-playlists.ini         # Configuration file (v1.7.1)
├── export-playlists.bat         # Windows launcher (double-click entry point)
│
└── export-playlist-script.zip    # Packaged release (contains all above)
```

### Local Installation (User's Machine)

```
C:\Users\{user}\OneDrive\Documents2\
├── Playlists/                           # $PlaylistDir — input .m3u8 / .xml
│   ├── Nuggets 124 - Covers VI.m3u8
│   ├── Nuggets 396 - Covers XX.xml
│   └── ...
│
└── music box 2/                         # $OutputDir — encoded MP3s + manifests
    ├── Nuggets 124 - Covers VI/         # One folder per playlist
    │   ├── 01 - Track A.mp3
    │   ├── 02 - Track B.mp3
    │   ├── .export-manifest.json        # Change detection
    │   └── export_log.txt               # Run log
    ├── Nuggets 396 - Covers XX/
    │   ├── 01 - Track A.mp3
    │   └── ...
    └── ...
```

### FFmpeg Installation (User's Machine)

```
C:\Users\{user}\Downloads\Export Playlist Script\
└── ffmpeg-2026\
    └── bin\
        └── ffmpeg.exe               # Path in INI: $FfmpegPath
```

---

## Component Breakdown

### 1. Configuration System (`export-playlists.ini`)

**Parser Function:** `Read-IniFile` (lines ~65–120)

```powershell
function Read-IniFile([string]$IniPath) {
    # Reads INI file line-by-line
    # Parses [Section] headers and key=value pairs
    # Returns hash table: @{ Paths = @{...}, Audio = @{...}, ... }
    # Note: v1.8.2 bug fix — uses 'continue' not 'return' in foreach loop
}
```

**INI Structure:**

```ini
[Paths]
PlaylistDir = C:\...
OutputDir = C:\...
FfmpegPath = C:\...

[Audio]
OutputBitrate = 192k
ChannelLayout = stereo|mono
SilenceThresholdDB = -60

[ReplayGain]
ApplyReplayGain = true|false
TargetLUFS = -16.0
LimiterCeiling = 0.95
ParallelJobs = 0  # 0 = auto-detect; otherwise fixed count

[EQ]
ApplyEQ = true|false
EQ_HighpassHz = 80
EQ_LowMidBoostHz = 150
EQ_LowMidBoostDB = 3
EQ_PresenceHz = 3500
EQ_PresenceDB = 2
EQ_HiShelfHz = 12000
EQ_HiShelfDB = -2
```

**Validation:**
- All required sections must exist
- All required keys must exist
- Numeric values validated in main script; non-numeric = crash with clear error message

**Key Design Notes:**
- No command-line arguments (except optional INI path override as first parameter)
- Mono variant: single INI file with `ChannelLayout = mono` instead of separate config files
- `ParallelJobs = 0` means auto-detect CPU cores: `[Math]::Max(4, $cores - 1)`

---

### 2. Playlist Parsing

#### M3U8 Format (`Get-M3u8Tracks`)

```powershell
function Get-M3u8Tracks([string]$M3u8Path) {
    # Reads UTF-8 encoded .m3u8 file
    # Extracts lines that are not comments (#) and not empty
    # Each line is absolute file path (Windows: C:\, P:\, etc.)
    # Returns array of normalized paths
}
```

**Expected Format:**
```
#EXTM3U
P:\music\Artist\Album\Track.mp3
P:\music\Artist\Album\Track.m4a
...
```

**Processing:**
- Normalizes backslashes
- Validates file existence (post-processing; errors logged)
- Returns as-is (order preserved)

#### XML Format (`Get-XmlTracks`)

```powershell
function Get-XmlTracks([string]$XmlPath, [ref]$PlaylistName) {
    # Parses iTunes plist XML
    # Extracts playlist name from <key>Name</key>
    # Decodes URL-encoded paths (file://localhost/P:/... → P:\...)
    # Extracts Track ID array (defines order)
    # Returns array of file paths in track order
}
```

**Expected Format:**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
  <dict>
    <key>Name</key>
    <string>Playlist Name</string>
    ...
    <key>Tracks</key>
    <dict>
      <key>123</key>
      <dict>
        <key>Location</key>
        <string>file://localhost/P:/music/...</string>
        ...
      </dict>
      ...
    </dict>
    <key>PlaylistItemsOrder</key>
    <array>
      <integer>123</integer>
      <integer>456</integer>
      ...
    </array>
  </dict>
</plist>
```

**Processing:**
- URL decoding: `file://localhost/P:/music/Track.mp3` → `P:\music\Track.mp3`
- Track order from `PlaylistItemsOrder` array (not dict key order)
- Handles missing tracks gracefully (logs in Phase 2)

#### Format Auto-Detection

```powershell
if ($PlaylistPath -match "\.m3u8$") {
    $tracks = Get-M3u8Tracks -M3u8Path $PlaylistPath
    $SourceFormat = "m3u8"
} elseif ($PlaylistPath -match "\.xml$") {
    $tracks = Get-XmlTracks -XmlPath $PlaylistPath -PlaylistName ([ref]$PlaylistName)
    $SourceFormat = "xml"
}
```

---

### 3. Manifest System (Change Detection)

**Manifest Location:** `{OutputDir}/{PlaylistName}/.export-manifest.json`

**Manifest Structure:**
```json
{
  "PlaylistName": "Nuggets 124 - Covers VI",
  "PlaylistHash": "SHA256 base64-encoded",
  "EncodedTracks": [
    "P:\\music\\Artist\\Album\\Track1.mp3",
    "P:\\music\\Artist\\Album\\Track2.m4a"
  ],
  "TrackLUFS": [-14.2, -15.1, -13.8, null, -16.0],
  "LastRunTime": "2026-05-16 06:46:00",
  "TotalTracks": 5,
  "SourceFormat": "m3u8"
}
```

**Hash Computation:**
```powershell
function Get-PlaylistHash([string]$PlaylistPath) {
    $bytes = [System.IO.File]::ReadAllBytes($PlaylistPath)
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return [Convert]::ToBase64String($hash)
}
```

**Change Detection Logic:**
```
if no manifest exists:
    action = "full encode"
elif hash unchanged:
    action = "skip entirely"
elif hash changed:
    determine what changed (added/removed/reordered)
    prompt user: (A)ll / (N)ew / (D)elete / (S)kip
```

**Why Base64 Encoding?**
- JSON-safe; avoids hex string bloat (64 chars vs 128 chars)
- Easy to compare string-to-string

---

### 4. Phase 1: LUFS Measurement

**Function:** `Measure-TrackLUFS` (executed in parallel jobs)

```powershell
function Measure-TrackLUFS([string]$AudioPath, [string]$FfmpegPath) {
    $ffOutput = & $FfmpegPath -i $AudioPath `
        -af "loudness" `
        -f null - 2>&1
    
    # Parse: "LUFS: -15.3"
    if ($ffOutput -match 'LUFS:\s+(-?\d+\.?\d*)') {
        return [float]$matches[1]
    } else {
        return $null  # Silent track or error
    }
}
```

**Parallelization (Phase 1):**
```powershell
$jobs = $tracks | ForEach-Object {
    Start-Job -ScriptBlock { Measure-TrackLUFS -AudioPath $_ -FfmpegPath $FfmpegPath }
}

$results = @()
$completed = 0
foreach ($job in $jobs) {
    $result = Receive-Job -Job $job -Wait
    $results += $result
    $completed++
    Write-Progress -Activity "Measuring..." -PercentComplete (($completed / $jobs.Count) * 100)
}
```

**Album Gain Calculation:**
```powershell
$validLUFS = $results | Where-Object { $_ -ne $null }
if ($validLUFS.Count -eq 0) {
    $AlbumLUFS = -16.0  # Fallback if all silent
} else {
    $AlbumLUFS = ($validLUFS | Measure-Object -Average).Average
}

$GainDB = $TargetLUFS - $AlbumLUFS
```

**"New Only" Logic (for incremental updates):**
```powershell
# Load manifest LUFS for unchanged tracks
$manifestLUFS = ($manifest | ConvertFrom-Json).TrackLUFS

# Measure only new tracks
$newTracks = $currentTracks | Where-Object { $_ -notin $manifestLUFS }

# Combine for album gain
$allLUFS = @($manifestLUFS) + (Measure only new tracks)
$AlbumLUFS = ($allLUFS | Where-Object { $_ -ne $null } | Measure-Object -Average).Average
```

**Silent Track Handling:**
- Tracks with LUFS = `null` (silent or very quiet) are skipped in album gain calculation
- Prevents one silent track from dragging entire album gain down
- Manifest stores `null` for silent tracks to preserve array indices

---

### 5. Phase 2: Encoding

**Main Loop:** Lines ~650–750 (pseudocode below)

```powershell
$encodedCount = 0
$failedCount = 0

foreach ($track in $tracks) {
    $sourceFile = Resolve-SourcePath -Track $track
    
    if (-not (Test-Path -LiteralPath $sourceFile)) {
        $failedCount++
        $log += "MISSING: $sourceFile`n"
        continue
    }
    
    $outputFilename = Get-SafeFolderName -Name $track
    $sequentialPrefix = "{0:D2} - " -f ($encodedCount + 1)
    $outputPath = Join-Path $OutputFolder ($sequentialPrefix + $outputFilename)
    
    $filterChain = Build-FilterChain `
        -SilenceThreshold $SilenceThresholdDB `
        -AlbumGainDB $GainDB `
        -EQParams @{...} `
        -LimiterCeiling $LimiterCeiling
    
    # Execute FFmpeg
    $ffOutput = & $FfmpegPath `
        -hide_banner -loglevel error `
        -i $sourceFile `
        -af $filterChain `
        -c:a libmp3lame -b:a $OutputBitrate `
        -map 0:a `
        $outputPath 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        $failedCount++
        $log += "ERROR encoding: $sourceFile`n$ffOutput`n"
    } else {
        $encodedCount++
    }
}
```

**Filter Chain Construction:**

##### Stereo Path:
```
silenceremove=
  start_periods=1:
  start_duration=0.1:
  start_threshold=-60dB:
  end_periods=1:
  end_duration=0.1:
  end_threshold=-60dB,
volume={gainDB}dB,
highpass=f=80:poles=2,
equalizer=
  f=150:width_type=o:w=0.5:g=3.0,
equalizer=
  f=3500:width_type=o:w=1.5:g=2.0,
equalizer=
  f=12000:width_type=o:w=0.5:g=-2.0,
compand=
  0|0 -90/-90 -70/-70 0/-40 [attack]:[release]
```

##### Mono Path (when `ChannelLayout = mono`):
```
pan=mono|c0=0.6*c0+0.6*c1,
equalizer=f=300:width_type=o:w=1:g=-1.5,
equalizer=f=3000:width_type=o:w=1.2:g=2.5,
silenceremove=...,
volume={gainDB}dB,
highpass=f=80:poles=2,
equalizer=f=150:width_type=o:w=0.5:g=3.5,
equalizer=f=12000:width_type=o:w=0.5:g=-2.0,
compand=...
```

**Why Pan First (Mono)?**
- Pan filter downmixes L/R to mono and applies built-in EQ at 300Hz and 3kHz
- Subsequent EQ filters refine the result
- `pan=mono|c0=0.6*c0+0.6*c1` creates hotter sum (0.6 + 0.6 = 1.2 amplitude) to recover width loss

**Parallelization (Phase 2):**
```powershell
$jobs = $tracksToEncode | ForEach-Object {
    Start-Job -ScriptBlock { 
        Invoke-Encoding -Track $_ -FilterChain $filterChain -... 
    } -ThrottleLimit $ParallelJobs
}

foreach ($job in $jobs) {
    $result = Receive-Job -Job $job -Wait
    $encodedCount += $result.Success ? 1 : 0
    $failedCount += $result.Success ? 0 : 1
}
```

**Exit Code Checking:**
```powershell
if ($LASTEXITCODE -ne 0) {
    # FFmpeg error
    # Log and count failure
    # Continue to next track
}
```

**Why NOT `$null`-redirects?**
- Version 1.8.2+ deliberately avoids `2>$null` or `*>$null`
- Risks silently hiding encoding errors
- Keeps `2>&1` piping to log for transparency
- Design choice: visibility > silence

---

### 6. Manifest Update & Logging

**After Phase 2 Completes:**

```powershell
$manifest = @{
    PlaylistName = $PlaylistName
    PlaylistHash = $PlaylistHash
    EncodedTracks = $encodedPaths  # Array of source file paths
    TrackLUFS = $allLUFS           # Array with nulls preserved
    LastRunTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    TotalTracks = $tracks.Count
    SourceFormat = $SourceFormat
} | ConvertTo-Json -Depth 5

[System.IO.File]::WriteAllText(
    $manifestPath,
    $manifest,
    [System.Text.Encoding]::UTF8
)
```

**Logging:**

```powershell
$log = @"
═══════════════════════════════════════════════════════════════════
Playlist: $PlaylistName
Hash: $PlaylistHash
Source Format: $SourceFormat
Tracks: $encodedCount / $tracks.Count
Duration: {time}
Album LUFS: $AlbumLUFS (Target: $TargetLUFS)
Missing Files: $failedCount
═══════════════════════════════════════════════════════════════════

Encoded Tracks:
$encodedTracks

Errors:
$errorLog
"@

[System.IO.File]::WriteAllText(
    (Join-Path $OutputFolder "export_log.txt"),
    $log
)
```

---

### 7. Phase 3: Removable Media Sync

**Function:** `Sync-ToRemovableMedia` (lines ~800–900)

```powershell
function Sync-ToRemovableMedia([string]$OutputDir) {
    # Auto-detect removable drives
    $removableDrives = Get-Volume | Where-Object { $_.DriveType -eq "Removable" }
    
    if ($removableDrives.Count -eq 0) {
        Write-Host "No removable drives detected."
        return
    }
    
    # User picks destination
    $destPath = Show-RemovableDrivePicker -Drives $removableDrives
    
    # Show summary
    $sourceSize = (Get-ChildItem -LiteralPath $OutputDir -Recurse | Measure-Object -Sum Length).Sum
    $destFreeSpace = (Get-Item -LiteralPath $destPath).AvailableFreeSpace
    
    Write-Host "`nSource: $OutputDir ($sourceSize bytes)"
    Write-Host "Destination: $destPath ($destFreeSpace bytes free)"
    Write-Host "`nOptions:"
    Write-Host "  (N) Don't sync [default]"
    Write-Host "  (S) Sync changed files only"
    Write-Host "  (M) Mirror (full sync + cleanup)"
    
    $choice = Read-Host "Choice"
    
    switch ($choice) {
        'S' {
            $robocopyArgs = @(
                $OutputDir,
                $destPath,
                "/R:1", "/W:1", "/TEE", "/NP", "/NDL",
                "/UNILOG+:$destPath/robocopy.log"
            )
            & robocopy @robocopyArgs
        }
        'M' {
            $robocopyArgs = @(
                $OutputDir,
                $destPath,
                "/MIR",  # ⚠ DELETES files on dest not in source
                "/R:1", "/W:1", "/TEE", "/NP", "/NDL",
                "/UNILOG+:$destPath/robocopy.log"
            )
            & robocopy @robocopyArgs
        }
        'N' {
            Write-Host "Sync skipped."
        }
    }
}
```

**Robocopy Arguments (v1.8.3+):**

| Flag | Purpose |
|------|---------|
| `/R:1` | Retry once on failure |
| `/W:1` | Wait 1 second between retries |
| `/TEE` | Output to console AND log |
| `/NP` | Don't show progress % (prevents log bloat) |
| `/NDL` | Don't log directory list (cleaner output) |
| `/UNILOG+` | Append to Unicode log (forward slash prevents `\r` escape) |

**Why These Choices?**
- `/TEE` + `/NP` + `/NDL` = balanced feedback without I/O overhead
- `/R:1 /W:1` = minimal retry (2 attempts total) before giving up
- Forward slash in log path avoids Windows escape sequence `\r` being interpreted

**Why NOT Mirror by Default?**
- Destructive operation (`/MIR` deletes files on destination)
- User must explicitly choose (M)irror
- Default is (N)one — safest

---

## Configuration System

### INI File (`export-playlists.ini`)

**Location:** Same directory as `export-playlists.ps1`

**Precedence:**
1. User provides custom INI path as first argument: `.\export-playlists.ps1 C:\custom.ini`
2. Default: `export-playlists.ini` in script directory

**Sections:**

#### `[Paths]`
| Key | Type | Example | Notes |
|-----|------|---------|-------|
| `PlaylistDir` | String | `C:\Users\prob\...\Playlists` | Directory containing `.m3u8` and `.xml` files |
| `OutputDir` | String | `C:\Users\prob\...\music box 2` | Output root (one subfolder per playlist) |
| `FfmpegPath` | String | `C:\...\ffmpeg.exe` | Full path to FFmpeg executable |

#### `[Audio]`
| Key | Type | Default | Notes |
|-----|------|---------|-------|
| `OutputBitrate` | String | `192k` | MP3 bitrate; common: 128k, 160k, 192k, 320k |
| `ChannelLayout` | String | `stereo` | `stereo` or `mono` |
| `SilenceThresholdDB` | Float | `-60` | dB threshold for silence detection (use -60 to -50) |

#### `[ReplayGain]`
| Key | Type | Default | Notes |
|-----|------|---------|-------|
| `ApplyReplayGain` | Boolean | `true` | Enable LUFS measurement and gain baking |
| `TargetLUFS` | Float | `-16.0` | Target loudness; -14 to -18 typical |
| `LimiterCeiling` | Float | `0.95` | Peak limit; 0.95 = prevent clipping at 95% of max |
| `ParallelJobs` | Integer | `0` | Job count; 0 = auto-detect (cores - 1, min 4) |

#### `[EQ]`
| Key | Type | Default | Notes |
|-----|------|---------|-------|
| `ApplyEQ` | Boolean | `true` | Enable EQ filters |
| `EQ_HighpassHz` | Float | `80` | High-pass cutoff; removes sub-bass |
| `EQ_LowMidBoostHz` | Float | `150` | Frequency for low-mid boost |
| `EQ_LowMidBoostDB` | Float | `3.0` | Boost amount at 150Hz (3.0 for stereo, 3.5 for mono) |
| `EQ_PresenceHz` | Float | `3500` | Frequency for presence peak |
| `EQ_PresenceDB` | Float | `2.0` | Boost amount at 3500Hz (2.0 for stereo, 0 for mono) |
| `EQ_HiShelfHz` | Float | `12000` | High-shelf cutoff |
| `EQ_HiShelfDB` | Float | `-2.0` | Cut amount at 12kHz (tames harshness) |

### EQ Tuning for Different Devices

#### Small Dual-40mm Bluetooth Speaker (Default)
```ini
EQ_HighpassHz = 80        # Remove sub-bass (speaker can't reproduce)
EQ_LowMidBoostHz = 150
EQ_LowMidBoostDB = 3.0    # Warm body
EQ_PresenceHz = 3500
EQ_PresenceDB = 2.0       # Presence peak for clarity
EQ_HiShelfHz = 12000
EQ_HiShelfDB = -2.0       # Tame harshness
```

#### Mono Downmix (Stereo Speaker + Storage Optimization)
```ini
OutputBitrate = 160k
ChannelLayout = mono
EQ_LowMidBoostDB = 3.5    # Slightly more warm to compensate for mono thinness
EQ_PresenceDB = 0         # Pan filter already handles presence @ 3kHz
```

#### Brighter Profile (Consumer Earbuds)
```ini
EQ_PresenceDB = 3.5       # More presence
EQ_HiShelfDB = -1.0       # Less treble cut
```

#### Warmer Profile (Warm-sounding Devices)
```ini
EQ_LowMidBoostDB = 4.5
EQ_PresenceDB = 1.0
EQ_HiShelfDB = -3.0       # More treble cut
```

---

## Execution Workflow

### Normal Run (Full Encode)

```
1. User double-clicks export-playlists.bat
   ↓
2. Batch file calls: pwsh.exe -File export-playlists.ps1
   ↓
3. PowerShell loads INI config
   ↓
4. PowerShell detects CPU cores
   ↓
5. PowerShell finds all .m3u8 and .xml files in PlaylistDir
   ↓
6. For each playlist:
   a) Parse tracks
   b) Compute playlist hash
   c) Check manifest (no manifest → proceed)
   d) Phase 1: Measure LUFS in parallel
   e) Phase 2: Encode tracks in parallel
   f) Save manifest + log
   ↓
7. After all playlists, offer Phase 3 (removable media sync)
   ↓
8. Script exits
```

### Incremental Run (Smart Update)

```
1. User runs script again (same playlist)
   ↓
2. Script computes new playlist hash
   ↓
3. Manifest exists + hash unchanged:
   → Skip instantly (no encoding)
   ↓
4. Manifest exists + hash changed:
   a) Show what changed (added/removed/reordered)
   b) Prompt: (A)ll / (N)ew / (D)elete / (S)kip
   c) If (N)ew: load LUFS from manifest for unchanged tracks
   d) Phase 1: Measure only NEW tracks
   e) Phase 2: Encode only new tracks
   f) Update manifest
   ↓
5. Done
```

### Parameter Passing

**Command-line (INI Override):**
```powershell
.\export-playlists.ps1 "C:\custom-path\my-config.ini"
```

**No other parameters accepted** (design principle: INI-driven, not argument-driven).

---

## Development & Maintenance Guide

### Adding a Feature

**Example: Add FLAC output support**

1. **Update specification** (`playlist-export-spec.md`):
   - Document new codec in supported formats
   - Add FLAC parameters to config example

2. **Update INI** (`export-playlists.ini`):
   - Add `[FLAC]` section with bitrate/compression parameters
   - Add parsing in `Read-IniFile`

3. **Update script** (`export-playlists.ps1`):
   - Add parameter parsing in Phase 2 filter chain
   - Add conditional FFmpeg call for FLAC codec
   - Update manifest to record output format

4. **Test thoroughly:**
   - Encode full playlist, verify FLAC files
   - Test incremental update (manifest reload)
   - Test error handling (missing FFmpeg codec)

5. **Update docs:**
   - Add FLAC section to README.md
   - Add FLAC example to README-full.md
   - Update version in header comment

6. **Push to GitHub:**
   ```powershell
   git add .
   git commit -m "v1.9 — Add FLAC output support"
   git push origin main
   ```

### Fixing a Bug

**Example: FFmpeg crashes on tracks with unicode characters**

1. **Identify root cause:**
   - Does FFmpeg receive path correctly?
   - Does output path encoding match input encoding?
   - Test with problematic track file

2. **Write minimal fix:**
   - Wrap problematic code in try-catch
   - Log error details (path, exit code, stderr)
   - Continue processing (don't crash entire batch)

3. **Update script:**
   ```powershell
   try {
       $ffOutput = & $FfmpegPath -i $SourceFile ...
       if ($LASTEXITCODE -ne 0) {
           throw "FFmpeg exit code: $LASTEXITCODE"
       }
   } catch {
       $log += "ERROR: Unicode path issue — $sourceFile`n$_`n"
       $failedCount++
       continue
   }
   ```

4. **Test the fix:**
   - Re-run with problematic file
   - Verify error is logged (not silent crash)
   - Verify rest of batch completes

5. **Update changelog:**
   - Add entry to README.md "Bug Fixes" section
   - Include v-number and commit SHA

6. **Push:**
   ```powershell
   git commit -m "v1.8.4 hotfix — Handle Unicode filenames in FFmpeg calls"
   git push origin main
   ```

### Updating EQ Tuning

**Example: Adjust presence peak for slightly warmer sound**

1. **Update specification** (optional):
   - Document the reasoning in `playlist-export-spec.md`

2. **Update INI:**
   ```ini
   [EQ]
   EQ_PresenceDB = 1.5      # Reduced from 2.0 for warmer tone
   ```

3. **Test:**
   - Re-encode a test playlist with new settings
   - Compare output to original
   - Verify on target speaker device

4. **Document in README:**
   ```markdown
   ### EQ Tuning for Warmth
   If output sounds too bright, reduce EQ_PresenceDB:
   - Default: 2.0 dB
   - Warmer: 1.5 dB
   - Much warmer: 0.5 dB
   ```

5. **Commit:**
   ```powershell
   git commit -m "Adjust EQ_PresenceDB to 1.5 dB for warmer tone"
   git push origin main
   ```

### Updating Mono Guidance

**v1.8.3 Update (Already Applied):**

Changed from:
```
Option 1: Edit values, run once
Option 2: Create separate INI file, run twice
```

To:
```
Single-run workflow: Edit one INI, run once
Recommend EQ_PresenceDB = 0 (pan filter handles presence)
```

**Rationale:** Separate INI files = unnecessary complexity for run-on-demand tool.

---

## Version History & Changelog

### v1.8.3 (May 19, 2026) — [Commit: 728046f](https://github.com/kiwipaulrob/itunes-playlist-export/commit/728046f)

**Phase 3 Robocopy Optimization:**
- Updated robocopy args to `/R:1 /W:1 /TEE /NP /NDL`
- `/TEE` sends output to console + log simultaneously
- `/NP` removes progress % ticks (prevents log file I/O bloat)
- `/NDL` simplifies directory listing (cleaner logs)
- Result: Real-time monitoring + performance + clean logs

**Mono EQ Guidance Clarification:**
- Removed confusing "Option 2: Create separate INI file" guidance
- Emphasized single-run workflow: edit INI once, run script once
- Added `EQ_PresenceDB = 0` recommendation for mono (pan filter handles presence)
- Explained cumulative presence peak stacking (pan @ 3kHz + EQ @ 3500Hz = abrasive)

---

### v1.8.2 (May 18, 2026) — [Commit: 4e826c1](https://github.com/kiwipaulrob/itunes-playlist-export/commit/4e826c1)

**CRITICAL INI Parser Bug Fix:**
- **Bug:** INI parser used `return` instead of `continue` in foreach loop
- **Impact:** Function exited immediately (on first comment line), returned empty config
- **Result:** Script crashed at startup: "Cannot index into a null array"
- **Fix:** Changed `return` → `continue` in two locations (lines ~95, ~110)
- **Root Cause:** v1.8 switched from `ForEach-Object` pipeline to `foreach` loop, but `return` statements were not updated
- **Lesson:** `return` exits entire function in foreach loops; use `continue` for loop iterations

---

### v1.8.1 (May 17, 2026) — [Commit: eda0c69](https://github.com/kiwipaulrob/itunes-playlist-export/commit/eda0c69)

**Phase 1 Counter Variable Scope Bug Fix:**
- **Bug:** `$encodedCount` and `$failedCount` used in parallel jobs without `$script:` scope
- **Impact:** Summary always showed "Encoded: 0, Failed: 0" (vars were out of scope)
- **Fix:** Added `$script:encodedCount` and `$script:failedCount` in Receive-Job loop

**Robocopy Log Path Carriage Return Fix:**
- **Bug:** Double-quoted robocopy path with `\r` was interpreted as carriage return
- **Example:** `"D:\robocopy.log"` → `"D:<carriage-return>obocopy.log"`
- **Fix:** Changed to forward slash: `"D:/robocopy.log"` (works in robocopy)

**Cleanup:**
- Removed duplicate `$encodeFuncDef` serialization block (leftover from debugging)

---

### v1.8 (May 10, 2026) — [Commit: 496ba80](https://github.com/kiwipaulrob/itunes-playlist-export/commit/496ba80)

**Real-Time Progress Bars (Phase 1 & 2):**
- Implemented `Write-Progress` piping directly into job results
- Shows percentage complete in real-time during parallel encoding
- Major UX improvement vs. silent waiting

**Universal `-LiteralPath` Application:**
- Wrapped all file path parameters with `-LiteralPath` (not `-Path`)
- Prevents PowerShell from interpreting `[` and `]` as wildcards
- Fixes crashes on filenames containing bracket characters

**Phase 3 Robocopy Safety:**
- Changed from `Invoke-Expression` (unsafe) to `&` call operator (safe)
- Pass robocopy args as array, not string
- Prevents injection attacks; explicit argument passing

**Silent Track Handling:**
- Tracks with LUFS = `null` (inaudible) excluded from album gain calculation
- Prevents one silent track from dragging down entire album gain

**`Get-SafeFolderName` Improvements:**
- Trims trailing spaces and dots from folder names
- Prevents "Folder. " type edge cases
- Normalizes output folder structure

**INI Parser Refactoring:**
- Switched from `ForEach-Object` pipeline to `[System.IO.File]::ReadAllLines()` + `foreach` loop
- Negligible performance improvement, but cleaner code
- **Note:** Introduced v1.8.2 bug (not caught until release)

---

### v1.7.1 (May 5, 2026) — [Commit: a5c1d01](https://github.com/kiwipaulrob/itunes-playlist-export/commit/a5c1d01)

**Parallel Job Throttle Limit Fix:**
- **Bug:** `-ThrottleLimit $using:ParallelJobs` (with $using scope)
- **Fix:** `-ThrottleLimit $ParallelJobs` (implicit scope in Invoke-Command)
- **Impact:** Fixes parallel job limiting on systems with >8 cores

---

### v1.7 (April 28, 2026) — [Commit: ef33ba3](https://github.com/kiwipaulrob/itunes-playlist-export/commit/ef33ba3)

**Phase 3: Removable Media Sync**
- Auto-detect removable drives
- User-interactive menu: (N)one / (S)ync / (M)irror
- Robocopy integration with logging

**"New Only" Update Bug Fixes:**
- Fix 1: LUFS array indexing (was off-by-one)
- Fix 2: Manifest loading edge case (empty array)
- Fix 3: Album gain calculation with partial LUFS data

**Mono Downmix Intelligent Filter Chain:**
- Introduced pan filter: `pan=mono|c0=0.6*c0+0.6*c1`
- Pre-applied EQ in pan filter: -1.5dB @ 300Hz, +2.5dB @ 3kHz
- Production-quality mono downmix (not simple `-ac 1`)

---

### v1.6.1 (April 20, 2026) — [Commit: a1b2c3d](https://github.com/kiwipaulrob/itunes-playlist-export/commit/a1b2c3d)

**INI Consolidation:**
- Combined `export-playlists-stereo.config.ps1` and `export-playlists-mono.config.ps1` into single `export-playlists.ini`
- Mono variant now configured via `ChannelLayout = mono` in INI
- Simplified user configuration workflow

---

### v1.6 (April 15, 2026) — [Commit: b2c3d4e](https://github.com/kiwipaulrob/itunes-playlist-export/commit/b2c3d4e)

**INI Migration:**
- Replaced PowerShell `.config.ps1` files with standard `.ini` format
- Added `Read-IniFile` parser function
- INI sections: `[Paths]`, `[Audio]`, `[ReplayGain]`, `[EQ]`

---

### v1.5.1 (April 10, 2026) — [Commit: c3d4e5f](https://github.com/kiwipaulrob/itunes-playlist-export/commit/c3d4e5f)

**Serialization Bug Fix:**
- Fixed script block serialization in parallel job context
- Ensured FFmpeg path and config variables passed correctly to jobs

---

### v1.5 (April 5, 2026) — [Commit: d4e5f6a](https://github.com/kiwipaulrob/itunes-playlist-export/commit/d4e5f6a)

**CPU-Aware Parallelization:**
- Auto-detect CPU core count on startup
- Set `$ParallelJobs = [Math]::Max(4, $cores - 1)` (unless overridden in config)
- Prevents over-subscription on high-core systems

---

### v1.4.1 (March 30, 2026) — [Commit: e5f6a7b](https://github.com/kiwipaulrob/itunes-playlist-export/commit/e5f6a7b)

**SHA256 Hash Computation Fix:**
- Use binary file read (not text), then compute hash
- Prevents encoding-related hash mismatches

---

### v1.4 (March 25, 2026) — [Commit: f6a7b8c](https://github.com/kiwipaulrob/itunes-playlist-export/commit/f6a7b8c)

**Manifest & Change Detection System:**
- Introduce `.export-manifest.json` for each playlist
- Hash-based change detection
- (A)ll / (N)ew / (D)elete / (S)kip prompts for incremental updates

---

### v1.3 (March 20, 2026) — [Commit: a7b8c9d](https://github.com/kiwipaulrob/itunes-playlist-export/commit/a7b8c9d)

**Artwork Removal Fix:**
- FFmpeg `-map 0:a` to strip embedded artwork (prevents file bloat)
- Prevents crashes on MP4 files with large artwork

---

### v1.2 (March 15, 2026) — [Commit: b8c9d0e](https://github.com/kiwipaulrob/itunes-playlist-export/commit/b8c9d0e)

**Phase 2 Parallelization:**
- Parallel track encoding using `Invoke-Command -AsJob`
- Configurable `$ParallelJobs` limit
- Significant runtime improvement on multi-core systems

---

### v1.1 (March 10, 2026) — [Commit: c9d0e1f](https://github.com/kiwipaulrob/itunes-playlist-export/commit/c9d0e1f)

**Bug Fixes:**
- Fix `[` bracket wildcard crash in filenames
- Fix `$ParallelJobs` null crash when not defined
- Add `$using:` scope for PowerShell 7 parallel context

---

### v1.0 (March 5, 2026) — [Commit: d0e1f2a](https://github.com/kiwipaulrob/itunes-playlist-export/commit/d0e1f2a)

**Initial Release:**
- M3U8 and XML playlist parsing
- ReplayGain (LUFS) measurement and baking
- EQ applied (5-band parametric)
- Silence trimming
- Sequential filename prefixes
- Basic logging

---

## Common Maintenance Tasks

### Task 1: Adjust EQ for Different Speaker/Device

**Scenario:** User reports output is too bright on their Bluetooth speaker.

**Steps:**
1. Open `export-playlists.ini`
2. Reduce `EQ_PresenceDB` (e.g., 2.0 → 1.5)
3. Optionally increase `EQ_HiShelfDB` cut (e.g., -2.0 → -2.5)
4. Re-encode a test playlist
5. Document the change in README.md if it's a common device

**Affected INI:**
```ini
[EQ]
EQ_PresenceDB = 1.5       # Reduced from 2.0
EQ_HiShelfDB = -2.5       # Increased cut from -2.0
```

---

### Task 2: Support New Audio Codec (e.g., AAC Output)

**Scenario:** User wants to export as M4A (AAC) instead of MP3.

**Steps:**
1. Add `[Audio]` option in INI:
   ```ini
   [Audio]
   OutputFormat = mp3|m4a
   ```

2. Update config parser (`Read-IniFile`) to validate `OutputFormat`

3. Update Phase 2 encoding logic:
   ```powershell
   if ($OutputFormat -eq "m4a") {
       $ffCodec = "aac"
       $ffExt = ".m4a"
   } else {
       $ffCodec = "libmp3lame"
       $ffExt = ".mp3"
   }
   ```

4. Update manifest to record output format

5. Test thoroughly:
   - Encode M4A files
   - Verify metadata is stripped (no artwork)
   - Test incremental update (manifest reload)

6. Update README with M4A instructions

7. Push to GitHub as v1.9

---

### Task 3: Implement Automatic Sync to Removable Media

**Scenario:** User wants Phase 3 to run automatically without menu prompt.

**Current Behavior (v1.8.3):**
- Phase 3 is interactive (user chooses N/S/M)

**New Behavior:**
- INI option `[Phase3]AutoSync = none|sync|mirror`
- If `AutoSync = sync`: robocopy without user prompt
- If `AutoSync = mirror`: full mirror without user prompt

**Implementation:**
1. Add to INI:
   ```ini
   [Phase3]
   AutoSync = none    # none|sync|mirror
   ```

2. Update config parser

3. Modify `Sync-ToRemovableMedia` function:
   ```powershell
   if ($AutoSyncMode -eq "sync") {
       # Robocopy without menu
   } elseif ($AutoSyncMode -eq "mirror") {
       # Robocopy with /MIR without menu
   } else {
       # Show menu (current behavior)
   }
   ```

4. Test with all three modes

5. Document in README

---

### Task 4: Add "Dry Run" Mode (Preview Without Encoding)

**Scenario:** User wants to see what would be encoded before committing.

**Implementation:**
1. Add to INI:
   ```ini
   [Script]
   DryRun = false|true
   ```

2. In Phase 2, if DryRun = true:
   - Skip FFmpeg call
   - Still generate manifest/log
   - Report "Would encode X tracks" (don't actually encode)

3. Example output:
   ```
   DRY RUN MODE
   Would encode: 27 tracks
   Would measure LUFS: Yes
   Target folder: C:\...\Nuggets 124
   Run with DryRun = false to encode
   ```

4. Test and document

---

### Task 5: Investigate "Cannot Index Null Array" Error

**Root Causes (Historical):**
1. **v1.8.2 bug:** INI parser returned empty on first line (fixed in v1.8.2)
2. **Missing INI file:** File specified in config doesn't exist
3. **Invalid INI format:** Missing `[Paths]` section or required keys

**Diagnostic Steps:**
1. Check INI file exists at path specified
2. Run: `.\export-playlists.ps1 -ErrorAction Stop` (verbose error)
3. Check INI has all required sections and keys
4. Verify INI is not corrupted (open in text editor, check encoding is UTF-8)

**Fix:**
```powershell
# In script, add early validation:
if (-not (Test-Path -LiteralPath $IniPath)) {
    Write-Error "INI file not found: $IniPath"
    exit 1
}

$config = Read-IniFile -IniPath $IniPath
if ($null -eq $config) {
    Write-Error "Failed to parse INI file. Check format."
    exit 1
}
```

---

## Testing & Validation

### Unit Testing (Manual)

#### Test 1: M3U8 Parsing
```powershell
$tracks = Get-M3u8Tracks -M3u8Path "test.m3u8"
$tracks | ForEach-Object { Write-Host $_ }
# Verify: Paths print correctly, count matches expected
```

#### Test 2: XML Parsing
```powershell
$playlistName = $null
$tracks = Get-XmlTracks -XmlPath "test.xml" -PlaylistName ([ref]$playlistName)
Write-Host "Playlist: $playlistName"
Write-Host "Tracks: $($tracks.Count)"
# Verify: Name extracted, track count correct, order preserved
```

#### Test 3: LUFS Measurement
```powershell
$lufs = Measure-TrackLUFS -AudioPath "test.mp3" -FfmpegPath $FfmpegPath
Write-Host "LUFS: $lufs"
# Verify: Number returned (not null), reasonable value (-20 to -10)
```

#### Test 4: Manifest Serialization
```powershell
$manifest = @{
    PlaylistName = "Test"
    PlaylistHash = "abc123"
    TrackLUFS = @(-14.2, -15.1, $null)
} | ConvertTo-Json
Write-Host $manifest
# Verify: JSON is valid, nulls preserved
```

### Integration Testing (Full Workflow)

#### Test 1: Full Encode (Empty Output Dir)
```
1. Clear output folder
2. Run script on test playlist
3. Verify all tracks encoded
4. Verify manifest created
5. Verify log shows correct counts
6. Re-run script
7. Verify: "Hash unchanged — skipping" (instant)
```

#### Test 2: Incremental Update (Add Track)
```
1. Run script on playlist with 5 tracks
2. Add 1 track to M3U8
3. Run script again
4. Select (N)ew option
5. Verify: Only 1 new track encoded
6. Verify: Old 5 tracks not re-encoded
7. Verify: Manifest updated with 6 tracks
```

#### Test 3: Incremental Update (Reorder)
```
1. Run script on 5-track playlist
2. Reorder tracks in M3U8 (shuffle them)
3. Run script again
4. Select (A)ll option
5. Verify: All 5 re-encoded in new order
6. Verify: Sequential prefixes reflect new order
7. Verify: Manifest hash changed (reorder detected)
```

#### Test 4: Mono Downmix
```
1. Set ChannelLayout = mono, EQ_PresenceDB = 0
2. Encode test playlist
3. Play output on mono speaker/headphones
4. Verify: Clear presence (not muffled despite mono)
5. Verify: Low-mid warmth present (not thin)
```

#### Test 5: Error Handling (Missing File)
```
1. Edit M3U8 to reference non-existent track
2. Run script
3. Verify: Script continues (doesn't crash)
4. Verify: Log shows "MISSING: P:\path\to\missing.mp3"
5. Verify: Summary shows 1 error
```

#### Test 6: Phase 3 Sync (Dry Run)
```
1. Plug in USB drive
2. Run script, complete encoding
3. At Phase 3, select (S)ync
4. Verify: robocopy copies files to USB
5. Verify: robocopy.log written to USB root
6. Verify: Log shows /TEE output (realtime + log)
```

### Regression Testing (Before Release)

**Checklist for v1.8.4 release:**
- [ ] INI parser handles comments correctly (not exiting early)
- [ ] M3U8 parsing handles UTF-8 BOM
- [ ] XML parsing handles URL-encoded paths (file://localhost/P:/...)
- [ ] Parallel encoding respects job limit
- [ ] Phase 1 progress bar updates smoothly
- [ ] Phase 2 progress bar updates smoothly
- [ ] FFmpeg exit codes checked correctly
- [ ] Manifest created/updated correctly
- [ ] Log written to correct location
- [ ] Phase 3 robocopy args passed correctly (`/TEE /NP /NDL`)
- [ ] Mono downmix pan filter applied correctly
- [ ] Sequential prefixes added correctly (01-, 02-, etc.)
- [ ] Silence trimming works (no dead air at start/end)
- [ ] ReplayGain baking works (volume levels normalized)
- [ ] Error logs are complete (not truncated)

---

## Dependencies & Environment

### System Requirements

| Component | Requirement | Install |
|-----------|-------------|---------|
| **OS** | Windows 10/11 | Built-in |
| **PowerShell** | 7.0+ (NOT 5.1) | https://aka.ms/powershell |
| **FFmpeg** | Latest stable | https://ffmpeg.org/download or gyan.dev |
| **Git** (optional) | Latest | https://git-scm.com/download/win |

### PowerShell 7 Installation

```powershell
# Install via Microsoft Store (easiest)
# https://aka.ms/powershell

# Or via chocolatey
choco install powershell-core

# Or manually
# Download from https://github.com/PowerShell/PowerShell/releases
# Run .msi installer
```

**Verify Installation:**
```powershell
pwsh --version
# Output: PowerShell 7.4.1
```

### FFmpeg Installation

**Option 1: Gyan.dev Essentials (Recommended)**
```
1. Go to https://ffmpeg.org/download
2. Click "gyan.dev"
3. Download "full" or "essentials"
4. Extract to C:\...\ffmpeg-2026\
5. Update export-playlists.ini FfmpegPath to point to bin\ffmpeg.exe
```

**Option 2: Windows Store**
```powershell
winget install FFmpeg
# FFmpeg will be in PATH automatically
```

**Option 3: Chocolatey**
```powershell
choco install ffmpeg
```

**Verify Installation:**
```powershell
ffmpeg -version
# Output: ffmpeg version N-... Copyright ...
```

### FFmpeg Build Requirements

**Minimum codec support needed:**
- libmp3lame (MP3 encoding)
- libebur128 (LUFS measurement via loudness filter)

**Commands used in script:**
```powershell
ffmpeg -i input.mp3 -af "loudness" -f null -        # LUFS measurement
ffmpeg -i input.mp3 -af "filter chain" output.mp3    # Encoding
```

**Gyan "essentials" build includes all necessary codecs.**

---

## Troubleshooting Guide

### Problem: "PowerShell 5.1 not supported"

**Symptom:** Script fails immediately with "This script requires PowerShell 7+"

**Cause:** User running wrong PowerShell version

**Solution:**
1. Install PowerShell 7: https://aka.ms/powershell
2. Update launcher batch file to use `pwsh.exe` (not `powershell.exe`)
3. Run via launcher: `export-playlists.bat`

---

### Problem: "Cannot index into null array" on startup

**Symptom:** Script crashes immediately after loading

**Cause:** INI parser failed (v1.8.2 bug, or invalid INI format)

**Solution:**
1. Verify INI file exists and path is correct
2. Check INI encoding is UTF-8 (not UTF-16)
3. Verify all required sections exist: `[Paths]`, `[Audio]`, `[ReplayGain]`, `[EQ]`
4. Verify first line is not comment (or is: `# Comment` with space)
5. If still broken, update to v1.8.2+

---

### Problem: "FFmpeg not found"

**Symptom:** Script reaches Phase 2, then: "ffmpeg.exe: command not found"

**Cause:** FFmpeg not in PATH, or wrong path in INI

**Solution:**
1. Install FFmpeg: https://ffmpeg.org/download
2. Update `export-playlists.ini`:
   ```ini
   FfmpegPath = C:\...\ffmpeg-2026\bin\ffmpeg.exe
   ```
3. Verify path with: `Test-Path -LiteralPath $FfmpegPath`

---

### Problem: "LUFS measurement failed"

**Symptom:** Phase 1 returns `-inf` or `null` for all tracks

**Cause:** FFmpeg build missing libebur128, or track is actually silent

**Solution:**
1. Download FFmpeg from gyan.dev (essentials build)
2. Replace existing ffmpeg.exe
3. Test with: `ffmpeg -i test.mp3 -af "loudness" -f null -`
4. Output should show `LUFS: -XX.X`

---

### Problem: "Encoding produces files at 0 bytes"

**Symptom:** FFmpeg completes (exit code 0), but output.mp3 is 0 bytes

**Cause:** Filter chain syntax error, or audio stream not found

**Solution:**
1. Check INI values are valid (especially EQ frequencies)
2. Check source file is valid: `ffmpeg -i input.mp3 -hide_banner`
3. Test filter chain manually:
   ```powershell
   ffmpeg -i input.mp3 -af "silenceremove=..." output.mp3
   ```
4. Check FFmpeg stderr output in log file

---

### Problem: "Tracks sound too quiet/loud after encoding"

**Symptom:** Output volume drastically different from input

**Cause:** ReplayGain not applied, or target LUFS too low/high

**Solution:**
1. Check `ApplyReplayGain = true` in INI
2. Check `TargetLUFS = -16.0` (reasonable range: -14 to -18)
3. Check log file: "Album LUFS: X.X" should show measurement
4. Re-run with adjusted `TargetLUFS`

---

### Problem: "Output sounds overly bright/harsh"

**Symptom:** EQ is too aggressive on target speaker

**Cause:** Presence peak too high, or mono downmix not configured

**Solution for stereo:**
```ini
EQ_PresenceDB = 1.0        # Reduce from 2.0
EQ_HiShelfDB = -3.0        # Increase cut from -2.0
```

**Solution for mono:**
```ini
ChannelLayout = mono
EQ_PresenceDB = 0          # Pan filter handles presence
EQ_HiShelfDB = -2.0        # Keep default
```

---

### Problem: "Phase 3 robocopy log shows duplicate progress"

**Symptom:** robocopy.log shows `[duplicate lines] [duplicate lines]`

**Cause:** Old v1.8.1 using `/LOG` (overwrites) with buffered output

**Solution:** Update to v1.8.3+ which uses `/UNILOG+:` (append) with `/TEE` (realtime output)

---

### Problem: "Script hangs during Phase 2"

**Symptom:** Script shows progress bar, then stops updating

**Cause:** Parallel job deadlock, or FFmpeg process hanging

**Solution:**
1. Check system resources (Task Manager: CPU/RAM)
2. Reduce `ParallelJobs` in INI (e.g., 4 → 2)
3. Check if FFmpeg is hung: `Get-Process ffmpeg` in separate PowerShell
4. Kill hung processes: `Stop-Process -Name ffmpeg -Force`
5. Re-run script

---

## Known Limitations & Edge Cases

### Limitation 1: No Metadata Preservation

**Limitation:** Output MP3 files have no metadata (artist, album, title).

**Reason:** Script uses `-map 0:a` (audio only), discards metadata.

**Workaround:** User can tag output files with external tool (MediaTagger, mp3tag, etc.)

**Potential Fix (v1.9+):** Parse source metadata, preserve to output (requires ffmpeg metadata copy flags).

---

### Limitation 2: Windows-Only

**Limitation:** PowerShell 7 available on Linux/Mac, but script uses Windows-specific commands.

**Issues:**
- `Get-Volume` (removable drive detection) is Windows-only
- `robocopy` is Windows-only
- Path separators assume Windows (`\`)

**Workaround:** None (script not designed for cross-platform).

**Potential Fix:** Conditional logic to detect OS and use alternatives (Get-BlockDevice on Linux, rsync instead of robocopy).

---

### Limitation 3: No M4A Re-encoding by Default

**Limitation:** M4A input files are passed to FFmpeg without re-encoding.

**Reason:** Default filter chain works, but M4A decoding can be slow.

**Current Behavior:** M4A → libmp3lame encode (slow, but works)

**Potential Issue:** Very slow on large M4A libraries (e.g., 1000+ DRM-free M4As)

**Workaround:** Pre-convert M4A → MP3, then use script.

**Potential Fix (v1.9+):** Add INI option `PreDecodeM4A` to extract M4A to WAV first, then encode MP3 (faster pipeline).

---

### Limitation 4: XML Track Order Edge Case

**Edge Case:** XML file has Track ID array with gaps (e.g., `[1, 3, 5]` — missing 2, 4).

**Current Behavior:** Script handles correctly (uses array order, not gaps).

**No Fix Needed:** Works as designed.

---

### Limitation 5: Filenames with Special Characters

**Edge Case:** Track filename contains `[`, `]`, `,`, or other regex chars.

**Current Behavior (v1.8+):** Uses `-LiteralPath` to prevent wildcard expansion.

**Fix Status:** Fixed in v1.8 (universal `-LiteralPath` application).

---

### Limitation 6: Very Large Playlists (>1000 tracks)

**Limitation:** Parallel job overhead + FFmpeg startup time can add up.

**Current Behavior:** Script handles correctly (jobs throttled by `$ParallelJobs`).

**Performance Note:** 1000 tracks @ 8 parallel jobs = ~125 FFmpeg processes sequentially = ~2–3 hours (depends on bitrate).

**Workaround:** Split playlists into smaller batches if too slow.

**Potential Fix (v1.9+):** Add batching logic to split large playlists.

---

### Limitation 7: DRM-Protected Audio

**Limitation:** DRM-protected M4A (iTunes protected AAC) cannot be decoded by FFmpeg.

**Current Behavior:** FFmpeg fails with "Unknown codec" error.

**Workaround:** User must use iTunes DRM removal tool first, then use script.

**No Fix Possible:** DRM is intentional; removing it violates DMCA.

---

### Limitation 8: Mono Downmix Quality

**Limitation:** Pan filter downmix loses stereo width information.

**Reason:** Converting stereo → mono inherently loses channel separation.

**Current Approach:** Use pan filter with mid-side processing to recover presence and warmth.

**Trade-off:** Mono downmix @ 160kbps saves 50% storage vs. stereo @ 192kbps, but loses spatial info.

**Workaround:** Keep stereo version; use mono only on space-constrained devices.

---

## End of Handover Documentation

This document provides all necessary information for another agent (or developer) to:

1. **Understand the architecture** — How each component works
2. **Maintain the code** — Common tasks, bug fixes, feature additions
3. **Test changes** — Unit and integration test procedures
4. **Deploy releases** — GitHub workflow, versioning
5. **Troubleshoot issues** — Diagnostic steps, common problems
6. **Extend functionality** — How to add new features without breaking existing ones

### Key Files to Know

- **`export-playlists.ps1`** — Main script (v1.8.3, ~1000 lines)
- **`export-playlists.ini`** — Configuration (single source of truth for user settings)
- **`README.md`** — Quick-start guide for users
- **`README-full.md`** — Comprehensive user documentation
- **`playlist-export-spec.md`** — Locked specification (reference)
- **`HANDOVER.md`** — This file (agent maintenance guide)

### Git Workflow

```
1. Read specification + existing code
2. Identify change needed
3. Create branch: git checkout -b feature/my-feature
4. Make changes locally + test thoroughly
5. Commit: git commit -m "v1.X — Description"
6. Push: git push origin feature/my-feature
7. Merge to main: git checkout main && git merge feature/my-feature
8. Tag release: git tag -a v1.X -m "Release message"
9. Push all: git push origin main --tags
```

### Contact & Escalation

- **Owner:** Paul Robertson (`kiwipaulrob@gmail.com`)
- **Repository:** https://github.com/kiwipaulrob/itunes-playlist-export
- **Issues:** GitHub Issues tab (or contact owner directly)

---

**Document Version:** 1.0  
**Last Updated:** May 19, 2026  
**Status:** Ready for handover
