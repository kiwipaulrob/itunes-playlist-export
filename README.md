# iTunes Playlist Exporter

A PowerShell 7 batch tool that exports iTunes playlists to MP3 with **album-level ReplayGain loudness normalisation**, **custom EQ optimisation**, and **silence trimming**.

Perfect for creating portable music collections for Bluetooth speakers, car audio, or any playback device where loudness consistency and frequency response matter.

---

## Features

✓ **Batch export** — Process 20+ playlists in one run  
✓ **Format auto-detection** — Handles both `.m3u8` (UTF-8) and `.xml` (iTunes plist) playlists  
✓ **Album-level ReplayGain** — Measures all tracks in parallel, calculates unified gain, bakes it into audio  
✓ **Silence trimming** — Removes silence from start and end of every track  
✓ **Custom EQ** — Pre-configured for dual-40mm portable Bluetooth speakers (easily customised)  
✓ **Peak limiting** — Prevents clipping after gain application  
✓ **M4A to MP3** — Automatically re-encodes M4A files; MP3 files copied or re-encoded as configured  
✓ **Sequential numbering** — Adds track number prefix to output filenames while preserving original names  
✓ **Parallel processing** — Phase 1 loudness measurement runs up to 4 tracks simultaneously  
✓ **Overwrite protection** — Asks before overwriting existing playlist output folders  
✓ **Detailed logging** — Writes `export_log.txt` to each output folder with per-track timing and results  

---

## Requirements

- **PowerShell 7.0+** (not Windows PowerShell 5.1)  
  Install from: https://aka.ms/powershell
  
- **ffmpeg** (essentials build recommended)  
  Download from: https://ffmpeg.org/download  
  Extract to PATH or set full path in config
  
- **Windows** with access to music files on any drive (local or network)

---

## Installation

1. **Download or clone this repository**
2. **Extract all files to a folder** (e.g., `C:\Users\YourName\Downloads\iTunes Playlist Exporter\`)
3. **Edit `export-playlists.config.ps1`** with your paths and preferences (see Configuration below)
4. **Double-click `export-playlists.bat`** to run

That's it. The `.bat` file launches PowerShell 7 and runs the script with your config.

---

## Configuration

Open `export-playlists.config.ps1` in a text editor and set these variables:

### Paths
```powershell
$PlaylistDir    = "C:\Users\YourName\Music\Playlists"     # Folder containing .m3u8 and/or .xml files
$OutputDir      = "C:\Users\YourName\Music\Export"        # Root output folder (playlists go in subfolders)
$FfmpegPath     = "C:\path\to\ffmpeg.exe"                 # Full path to ffmpeg executable
```

### Audio Quality
```powershell
$OutputBitrate      = "192k"            # MP3 bitrate: 192k is good for 40mm speakers; use 256k for higher fidelity
$SilenceThresholdDB = -60               # Silence detection threshold; -60dB is conservative
```

### ReplayGain (Loudness Normalisation)
```powershell
$ApplyReplayGain    = $true             # Set to $false to skip loudness measurement
$TargetLUFS         = -16.0             # Target loudness in LUFS (-16 = good for portable speakers)
$LimiterCeiling     = 0.95              # Peak limiter prevents clipping (0.0–1.0)
$ParallelJobs       = 4                 # Simultaneous LUFS measurements in Phase 1
```

### EQ (Frequency Response Shaping)
```powershell
$ApplyEQ            = $true             # Set to $false to skip all EQ
$EQ_HighpassHz      = 80                # Roll off sub-bass below 80Hz (protects small drivers)
$EQ_LowMidBoostHz   = 150               # Boost warmth at 150Hz
$EQ_LowMidBoostDB   = 3                 # Boost amount: 3dB
$EQ_PresenceHz      = 3500              # Boost clarity at 3.5kHz
$EQ_PresenceDB      = 2                 # Boost amount: 2dB
$EQ_HiShelfHz       = 12000             # Roll off harsh highs above 12kHz
$EQ_HiShelfDB       = -2                # Cut amount: -2dB
```

**EQ is optimised for dual-40mm Bluetooth speakers** — adjust frequencies and amounts for your device.

---

## Usage

### Quick Start
1. Ensure all playlists (`.m3u8` or `.xml`) are in `$PlaylistDir`
2. Ensure all music files are on drive `P:` (or update the path in the `Get-M3U8Tracks` / `Get-XMLTracks` functions)
3. Double-click `export-playlists.bat`
4. When prompted for each playlist: press `y` to overwrite or `n` to skip

### What Happens
**Phase 1** (if `$ApplyReplayGain = $true`):
- Measures loudness of all tracks in parallel
- Calculates album-level gain to reach `$TargetLUFS`
- Reports integrated loudness and calculated gain

**Phase 2**:
- Re-encodes each track with gain, silence trim, EQ, and limiter applied
- Adds sequential number prefix to filename
- Copies/re-encodes to output folder
- Reports per-track processing time

**Output**:
- Music files saved to `$OutputDir\PlaylistName\`
- Log file: `$OutputDir\PlaylistName\export_log.txt`

---

## File Format Support

### M3U8 Playlists
- UTF-8 encoded file list
- Absolute or relative Windows paths
- One track per line

Example:
```
P:\music\Artist\Album\01 - Track.mp3
P:\music\Artist\Album\02 - Track.mp3
```

### iTunes XML Playlists
- iTunes plist XML format (one playlist per file)
- Playlist name read from `<key>Name</key>`
- File paths URL-encoded (`file://localhost/P:/...`)
- Track order defined by Track ID array at bottom of file

---

## Output Format

Each playlist produces:
```
OutputDir\
├── PlaylistName\
│   ├── 1-01 Track Name.mp3          (sequential prefix added, original name preserved)
│   ├── 2-02 Another Track.mp3
│   ├── 3-03 Third Track.mp3
│   └── export_log.txt                (detailed processing log)
```

**Sequential prefixes ensure correct playback order** even if filenames are naturally unsorted.

---

## Troubleshooting

### "PowerShell 7 not found"
- Install from https://aka.ms/powershell
- Verify with: `pwsh --version` in Command Prompt

### "ffmpeg not found"
- Install ffmpeg from https://ffmpeg.org/download
- Either add to PATH or set `$FfmpegPath` in config to full path

### "File not found" / "Skipped"
- Check that music files exist at paths listed in the playlist
- iTunes playlists can become stale if files are moved/renamed — update the playlist in iTunes and re-export the XML

### Square bracket `[` in filename causes error
- Use `-LiteralPath` in PowerShell (script handles this automatically as of v1.1)

### ReplayGain seems too loud or quiet
- Check `$TargetLUFS` in config (default -16 LUFS)
- Adjust `$LimiterCeiling` if output is distorted (should be 0.90–0.99)

### Output sounds thin or lacks bass
- Check that speaker enclosure is **airtight** (esp. around driver gaskets and passive radiator)
- Adjust `$EQ_LowMidBoostDB` upward if more warmth needed

---

## Advanced Configuration

### For Different Speaker Types

**Portable Bluetooth speaker (40mm drivers)**  
Default config is tuned for this.

**Car audio (full-range)**  
```powershell
$EQ_HighpassHz   = 40        # Can go lower; car has space
$EQ_LowMidBoostHz = 200      # Shift warmer boost slightly higher
$EQ_PresenceHz   = 4000      # Shift presence slightly higher
$EQ_HiShelfHz    = 10000     # Keep highs a bit more extended
$EQ_HiShelfDB    = -1        # Lighter cut
```

**Headphones (need more presence, less bass boost)**  
```powershell
$EQ_HighpassHz      = 40
$EQ_LowMidBoostDB   = 1       # Reduce bass boost
$EQ_PresenceHz      = 3000    # Sharpen presence
$EQ_PresenceDB      = 3       # Increase presence
$TargetLUFS         = -14     # Slightly louder for headphone listening
```

**Disable all processing for archival**  
```powershell
$ApplyReplayGain = $false
$ApplyEQ         = $false
$SilenceThresholdDB = -100    # Effectively disable silence trim
$OutputBitrate   = "320k"     # Maximum quality
```

---

## Performance

- **Phase 1 loudness measurement**: ~2–5 seconds per track (parallel, up to `$ParallelJobs` simultaneously)
- **Phase 2 re-encoding**: ~10–20 seconds per track when run in serial; with parallelisation (v1.2+), 4-8 simultaneous transcodes reduce total time by 60–70%

A 20-track playlist takes roughly **2–4 minutes** on a modern CPU with parallelisation enabled (significantly faster than earlier versions).

---

## License

This script is provided as-is for personal use.

---

## Support

If the script fails:
1. Check `export_log.txt` in the output folder for detailed error messages
2. Verify all file paths in the config are correct
3. Ensure PowerShell 7 and ffmpeg are installed and up-to-date
4. Check that all music files are on a drive that Windows can read (local, USB, or network share)

---

## Changelog

**v1.2** (Apr 2026)
- **Phase 2 parallelisation**: Transcoding now runs up to `$ParallelJobs` tracks simultaneously (~60–70% faster on 8-core CPUs)
- **Progress bars**: Real-time `Write-Progress` feedback for both Phase 1 (loudness measurement) and Phase 2 (encoding) with percentage complete
- **Robustness**: Explicit ffmpeg exit code checking, robust error reporting

**v1.1** (Apr 2026)
- Fixed `-LiteralPath` for filenames containing square brackets
- Added `$ParallelJobs` config variable for Phase 1 tuning
- Improved error messages

**v1.0** (Apr 2026)
- Initial release
