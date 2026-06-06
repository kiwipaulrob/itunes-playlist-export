# Contributing to iTunes Playlist Export

Thank you for your interest in contributing! This document provides guidelines and instructions for contributing to this PowerShell project.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Environment](#development-environment)
- [Project Structure](#project-structure)
- [Coding Standards](#coding-standards)
- [Making Changes](#making-changes)
- [Testing](#testing)
- [Pull Request Process](#pull-request-process)
- [Release Process](#release-process)

## Code of Conduct

This project is maintained by a small team. Please be respectful, constructive, and collaborative in all interactions.

## Getting Started

1. **Fork the repository** on GitHub
2. **Clone your fork**:
   ```powershell
   git clone https://github.com/your-username/itunes-playlist-export.git
   ```
3. **Add the upstream remote**:
   ```powershell
   git remote add upstream https://github.com/kiwipaulrob/itunes-playlist-export.git
   ```
4. **Create a feature branch** from `main`:
   ```powershell
   git checkout -b feature/my-feature
   ```

## Development Environment

### Requirements

- **PowerShell 7.0+** — Install from [https://aka.ms/powershell](https://aka.ms/powershell)
- **ffmpeg** — Recommended: Gyan.dev "essentials" build from [https://ffmpeg.org/download](https://ffmpeg.org/download)
- **Git** — For version control

### Setup

1. Clone the repository (see above)
2. Install PowerShell 7 and ffmpeg
3. Copy `export-playlists.ini` to your preferred location and configure paths
4. Place some `.m3u8` or `.xml` playlist files in your playlist directory
5. Run the script:
   ```powershell
   pwsh ./export-playlists.ps1
   ```

### Testing on Sample Data

Create a small test playlist with 2–3 short audio files (~30 seconds each) to quickly validate changes:

1. Place test audio files in a temporary folder
2. Create a `.m3u8` file listing those files
3. Run the script with a separate output directory
4. Verify encoding, gain, and silence trimming

## Project Structure

```
itunes-playlist-export/
├── export-playlists.ps1         # Main PowerShell script
├── export-playlists.ini         # Configuration file
├── export-playlists.bat         # Windows launcher (double-click entry)
├── CHANGELOG.md                 # Version history
├── CONTRIBUTING.md              # This file
├── DEVELOPMENT_PROGRESS.md      # Architecture and maintenance guide
├── playlist-export-spec.md       # Locked specification (reference)
├── README.md                    # User-facing quick-start guide
├── README-full.md               # Comprehensive user documentation
└── export-playlist-script.zip   # Packaged release archive
```

## Coding Standards

### PowerShell Style

- **Naming**: Use `PascalCase` for functions and script-level variables. Use `$camelCase` for local variables and parameters.
- **Functions**: Use `<Verb>-<Noun>` naming per PowerShell conventions (e.g., `Get-M3u8Tracks`, `Measure-TrackLUFS`).
- **Comments**: Use `<# #>` block comments for function documentation. Use `#` inline comments for complex logic.
- **Line length**: Prefer lines under 120 characters for readability.
- **Quoting**: Use double quotes `"` only when interpolation is needed; single quotes `'` for literal strings.

### Best Practices

- **Avoid `Invoke-Expression`** — Use the `&` call operator with array arguments instead.
- **Use `-LiteralPath`** — For all file operations to safely handle bracket characters in filenames.
- **Scope variables explicitly** — Use `$script:` scope when modifying variables inside parallel jobs.
- **Validate parameters** — Use `[Parameter(Mandatory)]`, `[ValidateNotNullOrEmpty()]`, and type constraints.
- **Error handling** — Use `try/catch` for external process calls; check exit codes for ffmpeg operations.
- **No Write-Host** — Use `Write-Output` or `Write-Progress` instead (unless interactive prompts require it).

### Git Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>: <short description>

<body>
```

Types:
- `feat` — New feature
- `fix` — Bug fix
- `docs` — Documentation changes
- `refactor` — Code restructuring
- `perf` — Performance improvements
- `test` — Adding or updating tests
- `chore` — Maintenance tasks

Examples:
```
fix: correct INI parser return vs continue bug
docs: add CHANGELOG and CONTRIBUTING guides
feat: implement parallel measurement phase
```

## Making Changes

1. **Sync with upstream** before starting work:
   ```powershell
   git fetch upstream
   git rebase upstream/main
   ```

2. **Make focused commits** — Each commit should represent a single logical change.

3. **Update documentation** if your change affects:
   - User-facing configuration (INI keys)
   - Command-line usage or behavior
   - The changelog (add entry under `[Unreleased]`)

4. **Test your changes** with sample playlists before submitting.

## Testing

This project does not yet have an automated test suite. Manual testing is required:

### Pre-Submit Checklist

- [ ] Script runs without errors on a test playlist (2–3 tracks)
- [ ] ReplayGain is correctly applied (verify with ffmpeg loudness tool or ear)
- [ ] EQ is applied correctly (verify output sounds different from input)
- [ ] Silence trimming works (check start/end of output files)
- [ ] Manifest creation and change detection works (run twice, verify skip)
- [ ] Parallel encoding completes without errors
- [ ] Error logging catches missing source files
- [ ] INI parsing handles all section/key variations
- [ ] Files with special characters (brackets, apostrophes, spaces) are handled

### Test Scenarios

| Scenario | How to Test |
|----------|-------------|
| Full encode (no manifest) | Delete manifest, run script |
| Incremental (hash unchanged) | Run script twice on same playlist |
| Incremental (hash changed) | Modify playlist file, re-run |
| Missing source files | Reference non-existent paths in playlist |
| Silent tracks | Include a silent audio file |
| Mono output | Set `ChannelLayout = mono` |
| No ReplayGain | Set `ApplyReplayGain = false` |
| No EQ | Set `ApplyEQ = false` |

## Pull Request Process

1. **Ensure your branch is up to date** with upstream `main`
2. **Run through the test scenarios** relevant to your change
3. **Update `CHANGELOG.md`** with your change under `[Unreleased]`
4. **Create a pull request** on GitHub with:
   - Clear title describing the change
   - Description of what and why
   - Any relevant issue numbers
   - Screenshots or logs if applicable
5. **Respond to feedback** promptly — maintainers will review and may request changes

### PR Checklist

- [ ] Code follows project style guidelines
- [ ] All manual tests pass
- [ ] Documentation updated (README, INI comments, etc.)
- [ ] CHANGELOG.md updated
- [ ] No unrelated changes in the PR

## Release Process

1. Update version number in `export-playlists.ps1` (top of file)
2. Update `HANDOVER.md` version and date header
3. Update `CHANGELOG.md` — move entries from `[Unreleased]` to new version section
4. Update `README.md` changelog if needed
5. Create a git tag: `git tag v<major>.<minor>.<patch>`
6. Push tag: `git push upstream v<major>.<minor>.<patch>`
7. Create GitHub release with packaged ZIP archive
