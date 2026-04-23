# ============================================================
# Playlist Export Tool — Configuration
# Edit this file to configure the tool. Do not edit export-playlists.ps1.
# ============================================================

# --- Paths ---
$PlaylistDir        = "C:\Playlists"     # Folder containing .m3u8 or .xml playlist files
$OutputDir          = "D:\Exported"      # Root output folder
$FfmpegPath         = "ffmpeg.exe"       # Full path if ffmpeg not in PATH e.g. "C:\tools\ffmpeg\ffmpeg.exe"

# --- Audio ---
$OutputBitrate      = "192k"            # Output MP3 bitrate (192k is sufficient for 40mm drivers)
$SilenceThresholdDB = -60               # Silence detection level in dB (lower = less aggressive)

# --- ReplayGain (album-level loudness normalisation) ---
# Set $ApplyReplayGain = $false to skip loudness measurement and apply no volume adjustment
$ApplyReplayGain    = $true
$TargetLUFS         = -16.0              # Target loudness in LUFS (-16 is good for small speakers; -14 is louder)
$LimiterCeiling     = 0.95              # Peak limiter ceiling as linear amplitude (0.95 = approx -0.45 dBFS)
$ParallelJobs       = 4                 # Tracks measured simultaneously in Phase 1 (4 is safe; raise on fast NVMe, lower on HDD)

# --- EQ (optimised for dual 40mm portable speaker) ---
# Set $ApplyEQ = $false to bypass all EQ processing
$ApplyEQ            = $true
$EQ_HighpassHz      = 80                # Roll off sub-bass below this frequency (Hz)
$EQ_LowMidBoostHz   = 150              # Centre frequency for low-mid warmth boost (Hz)
$EQ_LowMidBoostDB   = 3                # Low-mid boost gain (dB)
$EQ_PresenceHz      = 3500             # Centre frequency for presence/clarity boost (Hz)
$EQ_PresenceDB      = 2                # Presence boost gain (dB)
$EQ_HiShelfHz       = 12000            # High shelf cut start frequency (Hz)
$EQ_HiShelfDB       = -2               # High shelf cut gain (dB) — tames MP3 harshness
