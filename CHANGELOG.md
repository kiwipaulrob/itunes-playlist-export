# Changelog

## 2026-05-19 — v1.8.3
- Phase 3 robocopy: `/TEE /NP /NDL` flags for clean console logging
- Clarified mono EQ workflow documentation

## 2026-05-17 — v1.8.2
- **CRITICAL:** Fixed INI parser `return` vs `continue` bug that skipped processing
- v1.8.1: Critical bug fixes from external code review
- v1.8: Comprehensive stability and performance overhaul

## 2026-05-17 — v1.7.x
- v1.7.1: Hotfix — removed invalid `$using:` prefix from `-ThrottleLimit` parameter
- v1.7: Bug fixes for "New only" mode; Phase 3 robocopy with intelligent mono downmix

## 2026-05-16 — v1.6.x
- v1.6.1: Mono downmixing with intelligent pan filter
- v1.6: Single INI configuration file; mono channel support
- v1.5.1: TrackLUFS manifest storage for consistent ReplayGain on updates

## 2026-05-16 — v1.5
- CPU core auto-scaling with intelligent parallelisation

## 2026-05-16 — v1.4
- SHA256 hash method invocation fix (v1.4.1)
- Smart change detection with manifest-based playlist tracking

## 2026-04-28 — v1.3
- Strip corrupted artwork to fix ffmpeg transcode failures

## 2026-04-28 — v1.2
- Phase 2 parallelisation with progress bars
- FFmpeg threading optimisations

## 2026-04-23 — Initial release v1.0
- Export script, config template, launcher, and documentation
