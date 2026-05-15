# Playlist Export Tool — Specification

## Overview

A Windows PowerShell script (launched via a `.bat` double-click file) that reads a directory of `.m3u8` or iTunes `.xml` playlist files, copies and re-encodes the referenced audio files into per-playlist output directories, renames them with a sequential numeric prefix, trims silence from start/end, and bakes in album-level ReplayGain normalization.

**Single tool dependency: `ffmpeg.exe`** — no foobar2000, mp3gain, or other tools required.

**Requires PowerShell 7+** (`pwsh.exe`) for parallel loudness measurement. Download from https://aka.ms/powershell. The `.bat` launcher calls `pwsh.exe` and shows a clear error if PS7 is not installed.

---

## Working Rules

- **Always ask before writing code.** Propose changes and wait for explicit approval before editing any script file.
- Do not write code without being explicitly asked.
- Configuration variables go in `export-playlists.config.ps1`, not in the main script and not as command-line arguments.
- Update the specification before writing code.

---

## Auto-Detection Features

### CPU Core Auto-Scaling (v1.5+)

The script automatically detects the number of CPU cores and scales parallel jobs accordingly:

- **Default config setting**: `$ParallelJobs = 0` (auto-detect mode)
- **On startup**: Script reads logical CPU core count and sets `$ParallelJobs = (cores - 1)`, minimum 4
  - 4-core CPU → 4 parallel jobs (no scaling possible, use minimum)
  - 8-core CPU → 7 parallel jobs (leaves 1 core free for OS)
  - 16-core CPU → 15 parallel jobs
- **Override**: Set `$ParallelJobs` to an explicit number in config to disable auto-detection
- **Error handling**: If core detection fails, defaults to 4

This ensures optimal performance on any hardware without manual configuration.

---

## Change Detection (v1.4+)

The script now tracks playlist changes via a **manifest file** (`.export-manifest.json`) stored in each output folder.

### How It Works

1. **First run**: Creates output folder and encodes all tracks. Manifest saved after completion.
2. **Subsequent runs**: 
   - Compares playlist file hash against manifest
   - If **unchanged**: Skips entire playlist (✓ Playlist unchanged since last run)
   - If **changed**: Detects added/removed/reordered tracks and offers options:
     - **(A)ll tracks** — Re-encode all tracks (full rebuild)
     - **(N)ew only** — Encode only added tracks, delete and recreate folder (ensures correct sequential numbering)
     - **(D)elete & recreate** — Same as (A), with explicit delete step
     - **(S)kip** — Skip this playlist

### Manifest Structure

```json
{
  "PlaylistName": "Nuggets 124 - Covers VI",
  "PlaylistHash": "SHA256 base64-encoded hash",
  "EncodedTracks": ["P:\\music\\...", "P:\\music\\..."],
  "LastRunTime": "2026-05-16 06:46:00",
  "TotalTracks": 27,
  "SourceFormat": "m3u8"
}
```

### Notes

- SHA256 hash detects any change to the playlist file (added/removed/reordered tracks)
- Manifest is **per-playlist** (one per output folder)
- If folder exists but no manifest → treat as legacy export, ask user to overwrite or skip
- Track numbering may shift if tracks are added mid-list (sequential 01, 02, 03… always preserves order)

---

## Confirmed Parameters

| Setting | Value |
|---|---|
| Source drive | `P:` (fixed, no remapping) |
| Input file formats | MP3 and M4A |
| Output format | MP3 (all sources re-encoded to MP3) |
| Playlist formats | `.m3u8` (foobar2000 export) and `.xml` (iTunes plist export) |
| Filename handling | Prepend sequential prefix; original filename unchanged |
| ReplayGain | Album mode, baked into audio (re-encoded); can be disabled via `$ApplyReplayGain` |
| Silence removal | Trim from start and end of each track |
| Existing output folder | Ask user (y/n) before overwriting |
| Configuration | Separate config file (`export-playlists.config.ps1`) |

---

## Playlist Formats

### M3U8 Format (foobar2000 export)
```
#EXTM3U
#EXTINF:201,Proud Mary (orig. Creedence Clearwater Revival) - Ros Sereysothea
P:\music\Various Artists\Cambodia Rocks Vol. 1\02 Proud Mary (orig. Creedence Clear.mp3
#EXTINF:249,Rehab (orig. Amy Winehouse) - The Jolly Boys
P:\music\The Jolly Boys\Great Expectation\03 Rehab (orig. Amy Winehouse).mp3
...
```
- UTF-8 encoding
- Absolute Windows paths on `P:`
- Lines starting with `#` are metadata — skip
- Blank lines — skip
- Playlist name derived from filename (strip `.m3u8`)

### XML Format (iTunes plist export)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist ...>
<plist version="1.0">
<dict>
  <key>Tracks</key>
  <dict>
    <key>120354</key>
    <dict>
      <key>Track ID</key><integer>120354</integer>
      <key>Location</key><string>file://localhost/P:/music/Artist/Album/Track.mp3</string>
      <key>Kind</key><string>MPEG audio file</string>
      ...
    </dict>
  </dict>
  <key>Playlists</key>
  <array>
    <dict>
      <key>Name</key><string>Playlist Name</string>
      <key>Playlist Items</key>
      <array>
        <dict><key>Track ID</key><integer>120354</integer></dict>
        ...
      </array>
    </dict>
  </array>
</dict>
</plist>
```
- Parse using PowerShell's built-in `[xml]` type
- Build lookup hashtable: Track ID → file path
- File paths are URL-encoded (`%20` → space, etc.) and prefixed with `file://localhost/`
- Decode paths: strip `file://localhost/`, URL-decode, convert forward slashes to backslashes
- Playlist track order defined by the `Playlist Items` array
- Playlist name derived from `<key>Name</key>` inside the playlist dict
- Support both "MPEG audio file" (MP3) and "AAC audio file" / "Apple Lossless audio file" (M4A) kinds

---

## Files

| File | Purpose |
|---|---|
| `export-playlists.config.ps1` | All user-configurable variables — edit this file only |
| `export-playlists.ps1` | Main script logic — do not edit |
| `export-playlists.bat` | Double-click launcher |

---

## Configuration File (`export-playlists.config.ps1`)

```powershell
# ============================================================
# Playlist Export Tool — Configuration
# Edit this file to configure the tool. Do not edit the .ps1.
# ============================================================

# --- Paths ---
$PlaylistDir        = "C:\Playlists"     # Folder containing .m3u8 or .xml playlist files
$OutputDir          = "D:\Exported"      # Root output folder
$FfmpegPath         = "ffmpeg.exe"       # Full path, or just "ffmpeg.exe" if ffmpeg is in PATH

# --- Audio ---
$OutputBitrate      = "192k"            # Output MP3 bitrate (192k is sufficient for 40mm drivers)
$SilenceThresholdDB = -60               # Silence detection level in dB (lower = less aggressive)

# --- ReplayGain (album-level loudness normalisation) ---
# Set $ApplyReplayGain = $false to skip loudness measurement and apply no volume adjustment
$ApplyReplayGain    = $true
$TargetLUFS         = -16.0              # Target loudness in LUFS (-16 is good for small speakers; -14 is louder)
$LimiterCeiling     = 0.95              # Peak limiter ceiling as linear amplitude (0.95 = -0.45 dBFS)
$ParallelJobs       = 0                 # Parallel jobs: 0 = auto-detect (cores - 1, min 4); set explicit number to override

# --- EQ (optimised for dual 40mm portable speaker) ---
# Set $ApplyEQ = $false to bypass all EQ filters
$ApplyEQ            = $true
$EQ_HighpassHz      = 80                # Roll off sub-bass below this frequency (Hz)
$EQ_LowMidBoostHz   = 150              # Centre frequency for low-mid warmth boost (Hz)
$EQ_LowMidBoostDB   = 3                # Low-mid boost amount (dB)
$EQ_PresenceHz      = 3500             # Centre frequency for presence/clarity boost (Hz)
$EQ_PresenceDB      = 2                # Presence boost amount (dB)
$EQ_HiShelfHz       = 12000            # High shelf cut start frequency (Hz)
$EQ_HiShelfDB       = -2               # High shelf cut amount (dB) — tames MP3 harshness
```

---

## Processing Flow

For each playlist file (`.m3u8` or `.xml`) found in `$PlaylistDir`:

### Step 1 — Setup
1. Detect file type (`.m3u8` or `.xml`) and parse accordingly
2. Derive playlist name:
   - m3u8: strip extension from filename
   - XML: use `<key>Name</key>` value from playlist dict
3. Sanitise name for folder use (replace `\ / : * ? " < > |` with `_`)
4. If output folder already exists → prompt user: **"Folder exists. Overwrite? (y/n)"**
   - `y` → clear existing folder and proceed
   - `n` → skip this playlist, move to next
5. Create output folder: `<OutputDir>\<playlist name>\`
6. Collect ordered list of source file paths — must always be an array, even for single-track playlists (PowerShell unwraps single-element arrays returned via the pipeline; wrap in `@()` to prevent)

### Step 2 — Album Loudness Measurement (Phase 1)
If `$ApplyReplayGain = $false`: skip this phase entirely, set `album_gain_dB = 0`.

Otherwise, measure all tracks in parallel (up to `$ParallelJobs` simultaneously) using `ForEach-Object -Parallel` (requires PowerShell 7+):
- Run `ffmpeg` with `ebur128` filter in measurement-only mode (`-f null`)
- Capture stderr (contains LUFS data); do not redirect stdout (avoids potential deadlock if ffmpeg writes unexpected stdout while stderr buffer is being read)
- Extract **Integrated Loudness (I)** in LUFS from stderr using regex `Integrated loudness:\s+I:\s+([-\d.]+)\s+LUFS` — anchored on the summary section heading, not per-frame `I:` values (per-frame values read ~-70 LUFS during silence; matching them instead of the summary produces ~54 dB of album gain and severe clipping)
- Results collected as objects with track index, sorted back into playlist order before display
- Collect all per-track LUFS values; exclude any track where measurement failed

Calculate album gain:
```
album_average_LUFS = mean of all successfully measured per-track LUFS values
album_gain_dB      = TargetLUFS − album_average_LUFS
```
If all tracks fail measurement: set `album_gain_dB = 0`, log warning.

### Step 3 — Encode (Phase 2)
For each track at position N of T:
- Build output filename: `<NN> - <original_filename_with_extension_changed_to_.mp3>`
  - `NN` zero-padded to width of T (e.g. 22 tracks → `01`–`22`; 100+ → `001`)
  - Original filename preserved exactly (including any embedded track number)
  - Extension always `.mp3` (m4a files renamed accordingly)
- Run `ffmpeg` combined filter chain (in order):
  1. **Volume gain**: `volume=<album_gain_dB>dB` — 0 dB if `$ApplyReplayGain = $false`
  2. **Silence trim start**: `silenceremove=start_periods=1:start_duration=0.3:start_threshold=<SilenceThresholdDB>dB:detection=rms`
  3. **Silence trim end** (reverse trick): `areverse, silenceremove=..., areverse`
     - Use `detection=rms` (average energy) rather than `peak` — avoids clipping quiet-but-audible intros/outros (e.g. soft cymbal rolls, piano fades)
  4. **EQ filters** (if `$ApplyEQ = $true`):
     - Highpass: `highpass=f=<EQ_HighpassHz>`
     - Low-mid boost: `equalizer=f=<EQ_LowMidBoostHz>:width_type=o:width=2:g=<EQ_LowMidBoostDB>`
     - Presence boost: `equalizer=f=<EQ_PresenceHz>:width_type=o:width=1.5:g=<EQ_PresenceDB>`
     - High shelf cut: `highshelf=f=<EQ_HiShelfHz>:width_type=s:width=1:g=<EQ_HiShelfDB>`
     - Note: use `highshelf` filter (not `equalizer`) for a proper shelf rolloff, not a bell/notch
  5. **Peak limiter**: `alimiter=limit=<LimiterCeiling>:attack=5:release=50:level=false` — always applied regardless of `$ApplyReplayGain`
- Encode as MP3 (`libmp3lame`) at `$OutputBitrate`
- Preserve ID3 tags from source (`-map_metadata 0`)
- Overwrite output if exists (`-y`)

### Step 4 — Logging
After each playlist, append to `export_log.txt` in `$OutputDir`:
- Playlist name and source format (m3u8/xml)
- Track count (found / missing / encoded successfully)
- Album gain applied (dB)
- Any errors (missing file, ffmpeg failure, path decode failure)

---

## Output Structure Example

Input: `Nuggets 124 - Covers VI.m3u8` (22 tracks)

```
D:\Exported\
├── Nuggets 124 - Covers VI\
│   ├── 01 - 02 Proud Mary (orig. Creedence Clear.mp3
│   ├── 02 - 03 Rehab (orig. Amy Winehouse).mp3
│   ├── 03 - 01 Slow Hands (orig. Interpol).mp3
│   ...
│   └── 22 - 01 Sabali (Theophilus London Remix).mp3
└── export_log.txt
```

---

## Error Handling

| Condition | Behaviour |
|---|---|
| Source file not found on disk | Log warning, skip track, continue — missing count tracked in Phase 2 only (Phase 1 skips silently to avoid double-counting) |
| ffmpeg not found | Abort with clear error message |
| ffmpeg fails on a track | Log error with exit code and ffmpeg stderr output, skip track, continue |
| All tracks missing in a playlist | Log error, skip playlist, delete empty output folder |
| Album loudness measurement fails for a track | Exclude that track from album average, log warning; if ALL tracks fail, apply 0 dB gain |
| Output folder exists | Prompt user y/n |
| XML parse error | Log error, skip file, continue to next playlist |
| URL-decode failure on XML path | Log warning, attempt raw path, skip if still not found |

---

## Deliverables

1. `export-playlists.config.ps1` — user configuration (edit this)
2. `export-playlists.ps1` — main script (do not edit)
3. `export-playlists.bat` — double-click launcher
