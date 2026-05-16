# iTunes Playlist Exporter

A PowerShell 7 batch tool that exports iTunes playlists to MP3 files — with album-level ReplayGain baked in, EQ optimised for small Bluetooth speakers, and silence trimmed from each track.

## What it does

1. Reads all `.m3u8` and `.xml` (iTunes plist) files from a playlist folder
2. For each playlist, re-encodes every track to MP3 with:
   - **Album-level ReplayGain** measured and baked into the audio (not tag-only)
   - **EQ** optimised for small dual-40mm driver Bluetooth speakers
   - **Silence trimmed** from the start and end of each track
   - **Peak limiter** applied to prevent clipping after gain
   - **Sequential number prefix** prepended to each filename
3. M4A files are re-encoded to MP3 automatically
4. Writes a log file to each output folder

## Requirements

- **PowerShell 7** — install from https://aka.ms/powershell (verify with `pwsh --version`)
- **ffmpeg** — recommended: gyan.dev "essentials" build from https://ffmpeg.org/download

## Files

| File | Description |
|------|-------------|
| `export-playlists.ps1` | Main script (requires PS 7.0+) |
| `export-playlists.ini` | All user-editable configuration variables |
| `export-playlists.bat` | Double-click launcher |

## Setup

1. Install PowerShell 7 and ffmpeg (see requirements above)
2. Edit `export-playlists.ini` — set your paths and preferences
3. Double-click `export-playlists.bat` to run

## Configuration

All settings are in `export-playlists.ini`:

```ini
[Paths]
PlaylistDir = C:\path\to\playlists
OutputDir = C:\path\to\output
FfmpegPath = C:\path\to\ffmpeg.exe

[Audio]
OutputBitrate = 192k
ChannelLayout = stereo
SilenceThresholdDB = -60

[ReplayGain]
ApplyReplayGain = true
TargetLUFS = -16.0
LimiterCeiling = 0.95
ParallelJobs = 0

[EQ]
ApplyEQ = true
EQ_HighpassHz = 80
EQ_LowMidBoostHz = 150
EQ_LowMidBoostDB = 3
EQ_PresenceHz = 3500
EQ_PresenceDB = 2
EQ_HiShelfHz = 12000
EQ_HiShelfDB = -2
```

## Mono Variant (Storage Optimisation)

For storage-limited devices, you can export to mono with automatic pan filter downmixing:

```ini
[Audio]
OutputBitrate = 160k
ChannelLayout = mono

[EQ]
EQ_LowMidBoostDB = 3.5
```

**How mono downmixing works:**
- Standard stereo-to-mono loses 3-6 dB of width information (guitars, synth pads, backing vocals disappear)
- Script applies an intelligent **pan filter** that preserves width by using a hotter stereo sum: `0.6*L + 0.6*R`
- Built-in **EQ** compensates for frequency imbalances: `-1.5dB at 300Hz` (removes mud), `+2.5dB at 3kHz` (restores presence)
- Your `EQ_LowMidBoostDB` is increased to `3.5dB` to restore warmth/body lost in the downmix

**Results:**
- File size: ~50% smaller than stereo
- Quality: Imperceptible loss for small speakers; recommended for storage-limited devices

## Playlist format support

- **M3U8** — UTF-8 encoded, Windows absolute paths
- **XML** — iTunes plist format; one playlist per file; track order and paths read from the plist structure

## Smart Playlist Updates

The script tracks which playlists have been encoded using a manifest file (`.export-manifest.json`):

- **First run:** All tracks encoded; manifest saved
- **Unchanged playlist:** Skipped instantly (no processing)
- **Changed playlist:** Script detects added/removed/reordered tracks and prompts:
  - **(A)ll** — Re-encode all tracks
  - **(N)ew** — Encode only new tracks; recalculate ReplayGain from all tracks
  - **(D)elete** — Delete folder and rebuild from scratch
  - **(S)kip** — Skip this playlist

This saves time when updating playlists frequently.

## Sync to Removable Media (Phase 3)

After encoding all playlists, the script optionally syncs your music files to a USB drive or other removable media:

**Options:**
- **(N) Don't sync** — Exit without copying (default)
- **(S) Sync changed files** — Copy new/updated files to media; keep existing files untouched (safe, incremental)
- **(M) Mirror with cleanup** — Copy everything and delete old files from media (full sync, but dangerous — **removes personal files**)
- **(D) Select drive** — Choose a different removable drive first

**How it works:**
- Auto-detects removable drives (USB, memory cards, external drives)
- Shows source size, destination info, and available free space
- Uses `robocopy` for fast, reliable file sync
- Writes a log to the destination drive: `robocopy.log`
- Safe by default: option (S) never deletes; option (M) prompts for confirmation first

**Example:** Copy your encoded playlists to a USB drive for car stereo or portable device in one step.

## Notes

- If an output folder already exists, the script will ask before overwriting
- Missing tracks are counted and logged but do not stop processing
- Filenames with special characters (brackets, apostrophes) are handled correctly
- Set `ApplyReplayGain = false` to skip loudness measurement and encode at unity gain
- Set `ApplyEQ = false` to bypass all EQ processing
- `ParallelJobs = 0` in config enables auto-detect (cores - 1, minimum 4)
