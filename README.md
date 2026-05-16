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

## Playlist format support

- **M3U8** — UTF-8 encoded, Windows absolute paths
- **XML** — iTunes plist format; one playlist per file; track order and paths read from the plist structure

## Notes

- If an output folder already exists, the script will ask before overwriting
- Missing tracks are counted and logged but do not stop processing
- Filenames with special characters (brackets, apostrophes) are handled correctly
- Set `$ApplyReplayGain = $false` to skip loudness measurement and encode at unity gain
- Set `$ApplyEQ = $false` to bypass all EQ processing
