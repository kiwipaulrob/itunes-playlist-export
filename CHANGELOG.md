# Changelog

All notable changes to the iTunes Playlist Export project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.8.3] — 2026-05-19

### Changed
- **Phase 3 robocopy args** — Updated to `/R:1 /W:1 /TEE /NP /NDL` for real-time monitoring, reduced log I/O bloat, and cleaner directory listings.
- **Mono EQ guidance** — Removed confusing "Option 2: Create separate INI file" guidance; emphasized single-run workflow. Added `EQ_PresenceDB = 0` recommendation for mono (pan filter already handles presence). Explained cumulative presence peak stacking rationale.

## [1.8.2] — 2026-05-18

### Fixed
- **CRITICAL INI parser bug** — `return` used instead of `continue` in `foreach` loop caused the function to exit on the first comment line, returning an empty config and crashing the script on startup with "Cannot index into a null array". Introduced in v1.8 INI refactoring. Fixed by replacing `return` with `continue` in two locations.

## [1.8.1] — 2026-05-17

### Fixed
- **Phase 1 counter variable scope** — `$encodedCount` and `$failedCount` were used in parallel jobs without `$script:` scope, causing summary to always show "Encoded: 0, Failed: 0". Added `$script:` prefix in `Receive-Job` loop.
- **Robocopy log path carriage return** — Double-quoted robocopy path with `\r` was interpreted as carriage return (e.g., `"D:\robocopy.log"` → `"D:<CR>obocopy.log"`). Changed to forward slash: `"D:/robocopy.log"`.

### Removed
- Duplicate `$encodeFuncDef` serialization block (leftover from debugging).

## [1.8.0] — 2026-05-10

### Added
- **Real-time progress bars** — `Write-Progress` piped directly into job results for Phase 1 & 2 showing percentage complete in real-time during parallel encoding.
- **Silent track handling** — Tracks with LUFS = `null` (inaudible) excluded from album gain calculation, preventing one silent track from dragging down entire album gain.

### Changed
- **Universal `-LiteralPath`** — All file path parameters wrapped with `-LiteralPath` instead of `-Path` to prevent PowerShell interpreting `[` and `]` as wildcards.
- **Phase 3 robocopy safety** — Changed from `Invoke-Expression` (unsafe) to `&` call operator with array argument passing, preventing injection attacks.
- **`Get-SafeFolderName`** — Now trims trailing spaces and dots from folder names to prevent edge cases.
- **INI parser refactoring** — Switched from `ForEach-Object` pipeline to `[System.IO.File]::ReadAllLines()` + `foreach` loop for cleaner code.

## [1.7.1] — 2026-05-05

### Fixed
- **Parallel job throttle limit** — `-ThrottleLimit $using:ParallelJobs` (with `$using` scope) fixed to `-ThrottleLimit $ParallelJobs` (implicit scope). Resolved parallel job limiting on systems with >8 cores.

## [1.7.0] — 2026-04-28

### Added
- **Phase 3: Removable Media Sync** — Auto-detect removable drives. Interactive menu with three modes: (N)one / (S)ync changed / (M)irror full. Robocopy integration with logging.

### Fixed
- **"New Only" update bugs** — LUFS array indexing off-by-one fixed. Manifest loading edge case (empty array) handled. Album gain calculation with partial LUFS data corrected.

### Changed
- **Mono downmix** — Introduced intelligent pan filter: `pan=mono|c0=0.6*c0+0.6*c1` with pre-applied EQ (-1.5dB @ 300Hz, +2.5dB @ 3kHz) instead of simple `-ac 1`.

## [1.6.1] — 2026-04-20

### Changed
- **INI consolidation** — Combined separate `export-playlists-stereo.config.ps1` and `export-playlists-mono.config.ps1` into single `export-playlists.ini`. Mono variant now configured via `ChannelLayout = mono`.

## [1.6.0] — 2026-04-15

### Changed
- **INI migration** — Replaced PowerShell `.config.ps1` files with standard `.ini` format. Added `Read-IniFile` parser function with sections: `[Paths]`, `[Audio]`, `[ReplayGain]`, `[EQ]`.

## [1.5.1] — 2026-04-10

### Fixed
- **Serialization bug** — Script block serialization in parallel job context fixed. FFmpeg path and config variables now pass correctly to jobs.

## [1.5.0] — 2026-04-05

### Added
- **CPU-aware parallelization** — Auto-detect CPU core count on startup. Sets `$ParallelJobs = [Math]::Max(4, $cores - 1)` unless overridden in config, preventing over-subscription on high-core systems.

## [1.4.1] — 2026-03-30

### Fixed
- **SHA256 hash computation** — Uses binary file read (not text) before computing hash, preventing encoding-related hash mismatches.

## [1.4.0] — 2026-03-25

### Added
- **Manifest & change detection system** — Introduced `.export-manifest.json` per playlist with hash-based change detection. Interactive prompts: (A)ll / (N)ew / (D)elete / (S)kip for incremental updates.

## [1.3.0] — 2026-03-20

### Fixed
- **Artwork removal** — FFmpeg `-map 0:a` strips embedded artwork from output, preventing file bloat and crashes on MP4 files with large artwork.

## [1.2.0] — 2026-03-15

### Added
- **Phase 2 parallelization** — Parallel track encoding using `Invoke-Command -AsJob` with configurable `$ParallelJobs` limit. Significant runtime improvement on multi-core systems.

## [1.1.0] — 2026-03-10

### Fixed
- Bracket `[` wildcard crash in filenames
- `$ParallelJobs` null crash when not defined
- Added `$using:` scope for PowerShell 7 parallel context

## [1.0.0] — 2026-03-05

### Added
- **Initial release**
- M3U8 and XML playlist parsing
- ReplayGain (LUFS) measurement and baking
- 5-band parametric EQ
- Silence trimming (start/end of tracks)
- Sequential filename prefixes
- Basic logging

[1.8.3]: https://github.com/kiwipaulrob/itunes-playlist-export/compare/v1.8.2...v1.8.3
[1.8.2]: https://github.com/kiwipaulrob/itunes-playlist-export/compare/v1.8.1...v1.8.2
[1.8.1]: https://github.com/kiwipaulrob/itunes-playlist-export/compare/v1.8.0...v1.8.1
[1.8.0]: https://github.com/kiwipaulrob/itunes-playlist-export/compare/v1.7.1...v1.8.0
[1.7.1]: https://github.com/kiwipaulrob/itunes-playlist-export/compare/v1.7.0...v1.7.1
[1.7.0]: https://github.com/kiwipaulrob/itunes-playlist-export/compare/v1.6.1...v1.7.0
[1.6.1]: https://github.com/kiwipaulrob/itunes-playlist-export/compare/v1.6.0...v1.6.1
[1.6.0]: https://github.com/kiwipaulrob/itunes-playlist-export/compare/v1.5.1...v1.6.0
[1.5.1]: https://github.com/kiwipaulrob/itunes-playlist-export/compare/v1.5.0...v1.5.1
[1.5.0]: https://github.com/kiwipaulrob/itunes-playlist-export/compare/v1.4.1...v1.5.0
[1.4.1]: https://github.com/kiwipaulrob/itunes-playlist-export/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/kiwipaulrob/itunes-playlist-export/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/kiwipaulrob/itunes-playlist-export/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/kiwipaulrob/itunes-playlist-export/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/kiwipaulrob/itunes-playlist-export/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/kiwipaulrob/itunes-playlist-export/releases/tag/v1.0.0
