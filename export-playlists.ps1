#Requires -Version 7.0
<#
.SYNOPSIS
    Playlist Export Tool
    Reads .m3u8 or iTunes .xml playlists, re-encodes audio to MP3 with
    album ReplayGain, silence removal and EQ, and saves numbered files
    into per-playlist output folders.

    Configure all settings in export-playlists.ini
#>

Set-StrictMode -Off

# -- Load configuration from INI file ------------------------------------------
function Read-IniFile {
    param([string]$Path)
    $config = @{}
    $currentSection = ""
    
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "ERROR: Configuration file not found: $Path" -ForegroundColor Red
        exit 1
    }
    
    $lines = [System.IO.File]::ReadAllLines($Path)
    foreach ($line in $lines) {
        $line = $line.Trim()
        
        # Skip empty lines and comments
        if (-not $line -or $line.StartsWith("#")) { continue }
        
        # Section header [Name]
        if ($line -match '^\[(.+)\]$') {
            $currentSection = $matches[1]
            $config[$currentSection] = @{}
            continue
        }
        
        # Key=Value pairs
        if ($line -match '^(.+?)\s*=\s*(.*)$') {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            
            # Remove quotes if present
            $value = $value -replace '^"(.*)"$', '$1'
            $value = $value -replace "^'(.*)'$", '$1'
            
            # Convert string values to appropriate types
            if ($value -eq 'true') { $value = $true }
            elseif ($value -eq 'false') { $value = $false }
            elseif ($value -match '^\d+$') { $value = [int]$value }
            elseif ($value -match '^\d+\.?\d*$') { $value = [double]$value }
            
            if ($currentSection) {
                $config[$currentSection][$key] = $value
            }
        }
    }
    
    return $config
}

# Load INI configuration
$configFile = Join-Path $PSScriptRoot "export-playlists.ini"
if (-not (Test-Path -LiteralPath $configFile)) {
    Write-Host "ERROR: Configuration file not found: $configFile" -ForegroundColor Red
    Write-Host "Please ensure export-playlists.ini is in the same folder as this script."
    Read-Host "Press Enter to exit"
    exit 1
}

$iniConfig = Read-IniFile $configFile

# Extract variables from INI (with defaults as fallback)
$PlaylistDir        = $iniConfig["Paths"]["PlaylistDir"]
$OutputDir          = $iniConfig["Paths"]["OutputDir"]
$FfmpegPath         = $iniConfig["Paths"]["FfmpegPath"]

$OutputBitrate      = $iniConfig["Audio"]["OutputBitrate"]
$ChannelLayout      = $iniConfig["Audio"]["ChannelLayout"]
$SilenceThresholdDB = $iniConfig["Audio"]["SilenceThresholdDB"]

$ApplyReplayGain    = $iniConfig["ReplayGain"]["ApplyReplayGain"]
$TargetLUFS         = $iniConfig["ReplayGain"]["TargetLUFS"]
$LimiterCeiling     = $iniConfig["ReplayGain"]["LimiterCeiling"]
$ParallelJobs       = $iniConfig["ReplayGain"]["ParallelJobs"]

$ApplyEQ            = $iniConfig["EQ"]["ApplyEQ"]
$EQ_HighpassHz      = $iniConfig["EQ"]["EQ_HighpassHz"]
$EQ_LowMidBoostHz   = $iniConfig["EQ"]["EQ_LowMidBoostHz"]
$EQ_LowMidBoostDB   = $iniConfig["EQ"]["EQ_LowMidBoostDB"]
$EQ_PresenceHz      = $iniConfig["EQ"]["EQ_PresenceHz"]
$EQ_PresenceDB      = $iniConfig["EQ"]["EQ_PresenceDB"]
$EQ_HiShelfHz       = $iniConfig["EQ"]["EQ_HiShelfHz"]
$EQ_HiShelfDB       = $iniConfig["EQ"]["EQ_HiShelfDB"]

# -- Auto-detect CPU cores if $ParallelJobs not explicitly set ----------------
if ($ParallelJobs -eq 0) {
    try {
        $cores = (Get-CimInstance Win32_Processor).NumberOfLogicalProcessors
        $ParallelJobs = [Math]::Max(4, $cores - 1)
        Write-Host "Auto-detected $cores CPU cores → using $ParallelJobs parallel jobs" -ForegroundColor Cyan
    }
    catch {
        Write-Host "Could not auto-detect CPU cores, using default: 4" -ForegroundColor Yellow
        $ParallelJobs = 4
    }
}

# -- Global error trap ---------------------------------------------------------
trap {
    Write-Host "`nUNEXPECTED ERROR: $_" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

# -- Helper: convert iTunes file://localhost/ URL to Windows path --------------
function ConvertFrom-iTunesPath {
    param([string]$RawPath)
    $path = $RawPath -replace '^file://localhost/', ''
    $path = [System.Uri]::UnescapeDataString($path)
    $path = $path -replace '/', '\'
    return $path
}

# -- Helper: sanitise a string for use as a folder name -----------------------
function Get-SafeFolderName {
    param([string]$Name)
    return ($Name -replace '[\\/:*?"<>|]', '_').Trim().TrimEnd(' .')
}

# -- Helper: read manifest JSON file from output folder --------------------------
function Get-ExportManifest {
    param([string]$OutputFolder)
    $manifestPath = Join-Path $OutputFolder ".export-manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        return $null
    }
    try {
        return Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

# -- Helper: write manifest JSON file to output folder ---------------------------
function Set-ExportManifest {
    param([string]$OutputFolder, [object]$Manifest)
    $manifestPath = Join-Path $OutputFolder ".export-manifest.json"
    $manifest | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
}

# -- Helper: compute hash of XML or M3U8 file for change detection ---------------
function Get-PlaylistHash {
    param([string]$FilePath)
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha256.ComputeHash($bytes)
    return [Convert]::ToBase64String($hash)
}

# -- Helper: compare old and new track lists, return action map -------------------
function Compare-TrackLists {
    param([string[]]$OldPaths, [string[]]$NewPaths)
    
    $added    = @()
    $removed  = @()
    $unchanged = @()
    
    $oldSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $newSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    
    foreach ($p in $OldPaths) { $oldSet.Add($p) | Out-Null }
    foreach ($p in $NewPaths) { $newSet.Add($p) | Out-Null }
    
    # Find unchanged and modified tracks
    foreach ($oldPath in $OldPaths) {
        if ($newSet.Contains($oldPath)) {
            $unchanged += $oldPath
        } else {
            $removed += $oldPath
        }
    }
    
    # Find added tracks
    foreach ($newPath in $NewPaths) {
        if (-not $oldSet.Contains($newPath)) {
            $added += $newPath
        }
    }
    
    return [PSCustomObject]@{
        Added      = $added
        Removed    = $removed
        Unchanged  = $unchanged
        TotalAdded = $added.Count
        TotalRemoved = $removed.Count
    }
}

# -- Helper: parse .m3u8 and return ordered array of file paths ----------------
function Get-M3U8Tracks {
    param([string]$FilePath)
    $tracks = [System.Collections.Generic.List[string]]::new()
    foreach ($line in [System.IO.File]::ReadAllLines($FilePath, [System.Text.Encoding]::UTF8)) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        $tracks.Add($trimmed)
    }
    return $tracks.ToArray()
}

# -- Helper: parse iTunes XML plist and return playlist name + ordered paths ---
function Get-XMLPlaylist {
    param([string]$FilePath)
    try {
        [xml]$plist = Get-Content -Path $FilePath -Encoding UTF8 -Raw
    }
    catch {
        return $null
    }

    # Build hashtable: TrackID (string) -> file path
    $trackMap = @{}
    $rootNodes = $plist.plist.dict.ChildNodes
    $i = 0
    while ($i -lt $rootNodes.Count) {
        $node = $rootNodes[$i]
        if ($node.Name -eq 'key' -and $node.InnerText -eq 'Tracks') {
            $tracksDict = $rootNodes[$i + 1]
            $tdNodes = $tracksDict.ChildNodes
            $j = 0
            while ($j -lt $tdNodes.Count) {
                if ($tdNodes[$j].Name -eq 'key') {
                    $trackId = $tdNodes[$j].InnerText
                    if (($j + 1) -lt $tdNodes.Count -and $tdNodes[$j + 1].Name -eq 'dict') {
                        $infoNodes = $tdNodes[$j + 1].ChildNodes
                        $location = $null
                        $k = 0
                        while ($k -lt $infoNodes.Count) {
                            if ($infoNodes[$k].Name -eq 'key' -and $infoNodes[$k].InnerText -eq 'Location') {
                                if (($k + 1) -lt $infoNodes.Count) {
                                    $location = $infoNodes[$k + 1].InnerText
                                }
                                break
                            }
                            $k++
                        }
                        if ($location) {
                            $trackMap[$trackId] = ConvertFrom-iTunesPath $location
                        }
                    }
                    $j += 2
                }
                else {
                    $j++
                }
            }
            break
        }
        $i++
    }

    # Find playlist name and ordered track list
    $playlistName  = $null
    $orderedTracks = [System.Collections.Generic.List[string]]::new()

    $i = 0
    while ($i -lt $rootNodes.Count) {
        $node = $rootNodes[$i]
        if ($node.Name -eq 'key' -and $node.InnerText -eq 'Playlists') {
            $playlistsArray = $rootNodes[$i + 1]
            if ($playlistsArray -and $playlistsArray.ChildNodes.Count -gt 0) {
                $playlistDict = $playlistsArray.ChildNodes[0]
                $pdNodes = $playlistDict.ChildNodes
                $p = 0
                while ($p -lt $pdNodes.Count) {
                    if ($pdNodes[$p].Name -eq 'key' -and $pdNodes[$p].InnerText -eq 'Name') {
                        if (($p + 1) -lt $pdNodes.Count) {
                            $playlistName = $pdNodes[$p + 1].InnerText
                        }
                    }
                    if ($pdNodes[$p].Name -eq 'key' -and $pdNodes[$p].InnerText -eq 'Playlist Items') {
                        if (($p + 1) -lt $pdNodes.Count) {
                            $itemsArray = $pdNodes[$p + 1]
                            foreach ($itemDict in $itemsArray.ChildNodes) {
                                $itemNodes = $itemDict.ChildNodes
                                $q = 0
                                while ($q -lt $itemNodes.Count) {
                                    if ($itemNodes[$q].Name -eq 'key' -and $itemNodes[$q].InnerText -eq 'Track ID') {
                                        if (($q + 1) -lt $itemNodes.Count) {
                                            $tid = $itemNodes[$q + 1].InnerText
                                            if ($trackMap.ContainsKey($tid)) {
                                                $orderedTracks.Add($trackMap[$tid])
                                            }
                                        }
                                        break
                                    }
                                    $q++
                                }
                            }
                        }
                    }
                    $p++
                }
            }
            break
        }
        $i++
    }

    return @{ Name = $playlistName; Tracks = $orderedTracks.ToArray() }
}

# -- Helper: measure integrated loudness of a file, returns LUFS or $null -----
function Measure-TrackLUFS {
    param([string]$FilePath, [string]$FfmpegExe)
    # Use System.Diagnostics.Process to reliably capture ffmpeg stderr
    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName               = $FfmpegExe
    $pinfo.Arguments              = "-hide_banner -i `"$FilePath`" -af ebur128=peak=true -f null -"
    $pinfo.RedirectStandardError  = $true
    $pinfo.RedirectStandardOutput = $false
    $pinfo.UseShellExecute        = $false
    $pinfo.CreateNoWindow         = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $pinfo
    $proc.Start() | Out-Null
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    # Match the summary line: "    I:         -14.5 LUFS"
    if ($stderr -match 'Integrated loudness:\s+I:\s+([-\w.]+)\s+LUFS') {
        if ($Matches[1] -eq '-inf') {
            return -70.0  # Return safe floor value for pure silence
        }
        return [double]$Matches[1]
    }
    return $null
}

# ------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------

# Validate ffmpeg
try {
    $null = & $FfmpegPath -version 2>&1
}
catch {
    Write-Host "ERROR: ffmpeg not found at: $FfmpegPath" -ForegroundColor Red
    Write-Host "Install ffmpeg and update FfmpegPath in export-playlists.ini"
    Read-Host "Press Enter to exit"
    exit 1
}

# Validate playlist directory
if (-not (Test-Path $PlaylistDir)) {
    Write-Host "ERROR: Playlist directory not found: $PlaylistDir" -ForegroundColor Red
    Write-Host "Update PlaylistDir in export-playlists.ini"
    Read-Host "Press Enter to exit"
    exit 1
}

# Create output directory if needed
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

$logFile  = Join-Path $OutputDir "export_log.txt"
$runStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Add-Content -Path $logFile -Value "`n========================================`nExport run: $runStamp`n========================================"

# Find playlist files
$playlistFiles = Get-ChildItem -Path $PlaylistDir -File |
    Where-Object { $_.Extension -in @('.m3u8', '.xml') } |
    Sort-Object Name

if ($playlistFiles.Count -eq 0) {
    Write-Host "No .m3u8 or .xml files found in: $PlaylistDir" -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit 0
}

Write-Host "Found $($playlistFiles.Count) playlist(s) in: $PlaylistDir" -ForegroundColor Cyan
Write-Host "Output root : $OutputDir" -ForegroundColor Cyan

# -- Process each playlist -----------------------------------------------------
foreach ($playlistFile in $playlistFiles) {
    Write-Host "`n----------------------------------------" -ForegroundColor Cyan
    Write-Host "Processing : $($playlistFile.Name)" -ForegroundColor Cyan

    $sourceFormat = $playlistFile.Extension.TrimStart('.')
    $playlistName = $null
    $trackPaths   = @()

    if ($playlistFile.Extension -eq '.m3u8') {
        $playlistName = [System.IO.Path]::GetFileNameWithoutExtension($playlistFile.Name)
        $trackPaths   = @(Get-M3U8Tracks -FilePath $playlistFile.FullName)
    }
    elseif ($playlistFile.Extension -eq '.xml') {
        $result = Get-XMLPlaylist -FilePath $playlistFile.FullName
        if ($null -eq $result) {
            Write-Host "  ERROR: Failed to parse XML file." -ForegroundColor Red
            Add-Content -Path $logFile -Value "[$($playlistFile.Name)] ERROR: XML parse failed"
            continue
        }
        $playlistName = if ($result.Name) { $result.Name } else { [System.IO.Path]::GetFileNameWithoutExtension($playlistFile.Name) }
        $trackPaths   = $result.Tracks
    }

    $safeName     = Get-SafeFolderName -Name $playlistName
    $outputFolder = Join-Path $OutputDir $safeName
    $totalTracks  = $trackPaths.Count

    Write-Host "  Playlist  : $playlistName"
    Write-Host "  Tracks    : $totalTracks"
    Write-Host "  Output    : $outputFolder"

    # -- Manifest-based change detection ------------------------------------------
    $tracksToProcess = @()
    $playlistHashNow = Get-PlaylistHash -FilePath $playlistFile.FullName
    $existingManifest = $null
    
    if (Test-Path $outputFolder) {
        $existingManifest = Get-ExportManifest -OutputFolder $outputFolder
        
        if ($existingManifest) {
            # Manifest exists - check if playlist has changed
            if ($existingManifest.PlaylistHash -eq $playlistHashNow) {
                Write-Host "  ✓ Playlist unchanged since last run." -ForegroundColor Green
                Write-Host "  Skipped." -ForegroundColor Yellow
                Add-Content -Path $logFile -Value "[$playlistName] SKIPPED (no changes since $(($existingManifest.LastRunTime)?.Substring(0,10) ?? 'previous run'))"
                continue
            }
            
            # Playlist has changed - detect what's new/removed
            $comparison = Compare-TrackLists -OldPaths $existingManifest.EncodedTracks -NewPaths $trackPaths
            Write-Host "  ⚠ Playlist changed:" -ForegroundColor Yellow
            Write-Host "    Added  : $($comparison.TotalAdded)"
            Write-Host "    Removed: $($comparison.TotalRemoved)"
            Write-Host "    Changed: $($comparison.Unchanged.Count) unchanged"
            
            # Ask user what to do
            Write-Host "  Options: (A)ll tracks, (N)ew only, (S)kip, (D)elete & recreate?" -ForegroundColor Cyan
            $action = Read-Host "  Choose"
            
            # Save old manifest LUFS before deletion (for "New only" option)
            $oldManifestLUFS = @()
            if ($null -ne $existingManifest.TrackLUFS) {
                $oldManifestLUFS = @($existingManifest.TrackLUFS)
            }
            
            if ($action -in @('d', 'D')) {
                # Delete and recreate
                Write-Host "  Deleting and recreating folder..."
                Remove-Item -Path $outputFolder -Recurse -Force
                New-Item -ItemType Directory -Path $outputFolder | Out-Null
                $tracksToProcess = @(0..($totalTracks - 1))
                $loadedLUFS = @()
            }
            elseif ($action -in @('n', 'N')) {
                # Encode only new tracks (but renumber all)
                Write-Host "  Encoding added tracks only..."
                # We need to track which indices are new
                $newIndices = @()
                for ($i = 0; $i -lt $trackPaths.Count; $i++) {
                    if ($trackPaths[$i] -in $comparison.Added) {
                        $newIndices += $i
                    }
                }
                $tracksToProcess = @($newIndices)  # FORCE ARRAY to prevent scalar auto-unboxing
                # Still remove old files since we're renumbering (if tracks were reordered)
                Remove-Item -Path $outputFolder -Recurse -Force
                New-Item -ItemType Directory -Path $outputFolder | Out-Null
                # Load LUFS from old manifest for album gain calculation
                $loadedLUFS = $oldManifestLUFS
            }
            elseif ($action -in @('a', 'A')) {
                # Re-encode all
                Write-Host "  Re-encoding all tracks..."
                Remove-Item -Path $outputFolder -Recurse -Force
                New-Item -ItemType Directory -Path $outputFolder | Out-Null
                $tracksToProcess = @(0..($totalTracks - 1))
                $loadedLUFS = @()
            }
            else {
                Write-Host "  Skipped." -ForegroundColor Yellow
                Add-Content -Path $logFile -Value "[$playlistName] SKIPPED (user declined update)"
                continue
            }
        }
        else {
            # Folder exists but no manifest (legacy or manual) - treat as new
            Write-Host "  ⚠ Folder exists (no manifest found)." -ForegroundColor Yellow
            $answer = Read-Host "  Overwrite? (y/n)"
            if ($answer -notin @('y', 'Y')) {
                Write-Host "  Skipped." -ForegroundColor Yellow
                Add-Content -Path $logFile -Value "[$playlistName] SKIPPED (folder exists, user declined overwrite)"
                continue
            }
            Remove-Item -Path $outputFolder -Recurse -Force
            New-Item -ItemType Directory -Path $outputFolder | Out-Null
            $tracksToProcess = @(0..($totalTracks - 1))
            $loadedLUFS = @()
        }
    }
    else {
        # Folder doesn't exist - create and encode all
        New-Item -ItemType Directory -Path $outputFolder | Out-Null
        $tracksToProcess = @(0..($totalTracks - 1))
        $loadedLUFS = @()
    }
    
    # Ensure $loadedLUFS is initialized
    if (-not $PSBoundParameters.ContainsKey('loadedLUFS')) {
        $loadedLUFS = @()
    }

    if ($totalTracks -eq 0) {
        Write-Host "  No tracks found in playlist." -ForegroundColor Yellow
        Add-Content -Path $logFile -Value "[$playlistName] ERROR: No tracks found"
        Remove-Item -Path $outputFolder -Force -ErrorAction SilentlyContinue
        continue
    }

    # -- Phase 1: Measure loudness ---------------------------------------------
    if (-not $ParallelJobs -or $ParallelJobs -lt 1) { $ParallelJobs = 4 }
    $missingCount = 0
    $lufsValues = @(0..$($totalTracks-1) | ForEach-Object { $null })  # Initialize full array with nulls

    if (-not $ApplyReplayGain) {
        Write-Host "`n  [Phase 1] Skipped (ReplayGain disabled)." -ForegroundColor DarkGray
        $albumGainDB = 0.0
    }
    else {
        # Populate LUFS array from loadedLUFS for tracks NOT being re-measured
        for ($i = 0; $i -lt $loadedLUFS.Count; $i++) {
            if ($i -notin $tracksToProcess) {
                $lufsValues[$i] = $loadedLUFS[$i]
            }
        }

        # Measure only tracks in $tracksToProcess
        Write-Host "`n  [Phase 1] Measuring loudness ($($tracksToProcess.Count) tracks of $totalTracks, up to $ParallelJobs at a time)..." -ForegroundColor Yellow
        $measureFuncDef = "function Measure-TrackLUFS { ${function:Measure-TrackLUFS} }"
        $ffExe          = $FfmpegPath
        
        $processedCount = 0

        $tracksToProcess | ForEach-Object -Parallel {
            . ([scriptblock]::Create($using:measureFuncDef))
            $i       = $_
            $src     = ($using:trackPaths)[$i]
            $missing = -not (Test-Path -LiteralPath $src)
            $lufs    = $null

            if (-not $missing) {
                $lufs = Measure-TrackLUFS -FilePath $src -FfmpegExe $using:ffExe
            }

            [PSCustomObject]@{ Index = $i; Path = $src; LUFS = $lufs; Missing = $missing }
        } -ThrottleLimit $ParallelJobs | ForEach-Object {
            $r = $_
            $trackNum = $r.Index + 1
            $leaf     = Split-Path $r.Path -Leaf
            $pctComplete = [int](($processedCount / $tracksToProcess.Count) * 100)
            
            Write-Progress -Activity "Phase 1: Measuring loudness" -Status "Track $trackNum of $totalTracks" -PercentComplete $pctComplete
            
            if ($r.Missing) {
                Write-Host "    [$trackNum/$totalTracks] WARNING: File not found: $leaf" -ForegroundColor Yellow
                $lufsValues[$r.Index] = $null
            }
            elseif ($null -eq $r.LUFS) {
                Write-Host "    [$trackNum/$totalTracks] WARNING: Could not measure loudness, excluded from album average: $leaf" -ForegroundColor Yellow
                $lufsValues[$r.Index] = $null
            }
            else {
                Write-Host "    [$trackNum/$totalTracks] $($r.LUFS) LUFS  $leaf"
                $lufsValues[$r.Index] = $r.LUFS
            }
        }
        Write-Progress -Activity "Phase 1: Measuring loudness" -Completed

        # Calculate album gain from all measured LUFS (including loaded ones)
        $validLUFS = @($lufsValues | Where-Object { $null -ne $_ })
        if ($validLUFS.Count -gt 0) {
            $avgLUFS     = ($validLUFS | Measure-Object -Average).Average
            $albumGainDB = $TargetLUFS - $avgLUFS
        }
        else {
            $albumGainDB = 0.0
            Write-Host "  WARNING: No valid loudness readings. Gain set to 0 dB." -ForegroundColor Yellow
        }
    }

    $albumGainStr = "{0:F2}" -f $albumGainDB
    Write-Host "  Album gain : ${albumGainStr} dB" -ForegroundColor Green

    # -- Phase 2: Encode -------------------------------------------------------
    $phase2TrackCount = if ($tracksToProcess.Count -eq 0) { $totalTracks } else { $tracksToProcess.Count }
    Write-Host "`n  [Phase 2] Encoding ($phase2TrackCount of $totalTracks tracks, up to $ParallelJobs at a time)..." -ForegroundColor Yellow
    $padWidth = [Math]::Max($totalTracks.ToString().Length, 2)

    # Helper function for Phase 2 encoding (passed to parallel threads)
    function Encode-TrackMP3 {
        param(
            [int]$Index,
            [string]$SrcPath,
            [string]$OutputFolder,
            [string]$FfmpegExe,
            [string]$AlbumGainStr,
            [int]$SilenceThresholdDB,
            [bool]$ApplyEQ,
            [int]$EQ_HighpassHz,
            [int]$EQ_LowMidBoostHz,
            [int]$EQ_LowMidBoostDB,
            [int]$EQ_PresenceHz,
            [int]$EQ_PresenceDB,
            [int]$EQ_HiShelfHz,
            [int]$EQ_HiShelfDB,
            [double]$LimiterCeiling,
            [string]$OutputBitrate,
            [string]$ChannelLayout,
            [string]$PadWidth
        )

        $trackNum = $Index + 1
        $srcBase  = [System.IO.Path]::GetFileNameWithoutExtension($SrcPath)
        $prefix   = $trackNum.ToString().PadLeft([int]$PadWidth, '0')
        $outName  = "$prefix - $srcBase.mp3"
        $outPath  = Join-Path $OutputFolder $outName

        # Check if file exists
        if (-not (Test-Path -LiteralPath $SrcPath)) {
            return [PSCustomObject]@{
                Index    = $Index
                Status   = 'MISSING'
                Message  = "SKIPPED (missing): $(Split-Path $SrcPath -Leaf)"
                OutName  = $outName
            }
        }

        # Build ffmpeg audio filter chain
        $silStart    = "silenceremove=start_periods=1:start_duration=0.3:start_threshold=${SilenceThresholdDB}dB:detection=rms"
        $silEnd      = "areverse,silenceremove=start_periods=1:start_duration=0.3:start_threshold=${SilenceThresholdDB}dB:detection=rms,areverse"
        $filterChain = "volume=${AlbumGainStr}dB,${silStart},${silEnd}"

        if ($ApplyEQ) {
            $filterChain += ",highpass=f=$EQ_HighpassHz"
            $filterChain += ",equalizer=f=${EQ_LowMidBoostHz}:width_type=o:width=2:g=$EQ_LowMidBoostDB"
            $filterChain += ",equalizer=f=${EQ_PresenceHz}:width_type=o:width=1.5:g=$EQ_PresenceDB"
            $filterChain += ",highshelf=f=${EQ_HiShelfHz}:width_type=s:width=1:g=$EQ_HiShelfDB"
        }

        # Peak limiter - prevents clipping from gain boost and EQ
        $filterChain += ",alimiter=limit=${LimiterCeiling}:attack=5:release=50:level=false"

        # Add mono downmix with intelligent pan filter if needed
        if ($ChannelLayout -eq "mono") {
            # Option 1: Production Save - hotter sum (0.6*L + 0.6*R) to recover width loss
            # Includes frequency compensation: -1.5dB at 300Hz, +2.5dB at 3kHz
            $filterChain += ",pan=mono|c0=0.6*c0+0.6*c1"
            $filterChain += ",equalizer=f=300:width_type=o:w=1:g=-1.5"
            $filterChain += ",equalizer=f=3000:width_type=o:w=1.2:g=2.5"
        }

        $ffOutput = & $FfmpegExe -hide_banner -y `
            -i $SrcPath `
            -map 0:a `
            -af $filterChain `
            -codec:a libmp3lame `
            -b:a $OutputBitrate `
            -map_metadata 0 `
            $outPath 2>&1

        if ($LASTEXITCODE -ne 0) {
            return [PSCustomObject]@{
                Index    = $Index
                Status   = 'ERROR'
                Message  = "ERROR: ffmpeg failed (exit code $LASTEXITCODE)"
                OutName  = $outName
            }
        }

        return [PSCustomObject]@{
            Index    = $Index
            Status   = 'OK'
            Message  = "Encoded: $outName"
            OutName  = $outName
        }
    }

    # Serialize Encode-TrackMP3 function for parallel scope
    $encodeFuncDef = "function Encode-TrackMP3 { ${function:Encode-TrackMP3} }"
    
    $processedCount = 0
    $encodedOK  = 0
    $encodedErr = 0

    $tracksToProcess | ForEach-Object -Parallel {
        . ([scriptblock]::Create($using:encodeFuncDef))
        Encode-TrackMP3 `
            -Index $_ `
            -SrcPath ($using:trackPaths)[$_] `
            -OutputFolder $using:outputFolder `
            -FfmpegExe $using:FfmpegPath `
            -AlbumGainStr $using:albumGainStr `
            -SilenceThresholdDB $using:SilenceThresholdDB `
            -ApplyEQ $using:ApplyEQ `
            -EQ_HighpassHz $using:EQ_HighpassHz `
            -EQ_LowMidBoostHz $using:EQ_LowMidBoostHz `
            -EQ_LowMidBoostDB $using:EQ_LowMidBoostDB `
            -EQ_PresenceHz $using:EQ_PresenceHz `
            -EQ_PresenceDB $using:EQ_PresenceDB `
            -EQ_HiShelfHz $using:EQ_HiShelfHz `
            -EQ_HiShelfDB $using:EQ_HiShelfDB `
            -LimiterCeiling $using:LimiterCeiling `
            -OutputBitrate $using:OutputBitrate `
            -ChannelLayout $using:ChannelLayout `
            -PadWidth $using:padWidth
    } -ThrottleLimit $ParallelJobs | ForEach-Object {
        $r = $_
        $processedCount++
        $trackNum = $r.Index + 1
        $pctComplete = [int](($processedCount / $phase2TrackCount) * 100)
        
        Write-Progress -Activity "Phase 2: Encoding audio" -Status "Track $trackNum of $totalTracks - $($r.Status)" -PercentComplete $pctComplete
        Write-Host "    [$trackNum/$totalTracks] $($r.Message)" -ForegroundColor $(if ($r.Status -eq 'OK') { 'Green' } elseif ($r.Status -eq 'MISSING') { 'Yellow' } else { 'Red' })

        if ($r.Status -eq 'OK') {
            $encodedOK++
        }
        elseif ($r.Status -eq 'ERROR') {
            $encodedErr++
            Add-Content -Path $logFile -Value "  [$playlistName] TRACK ERROR [$trackNum/$totalTracks]: $($r.OutName)"
        }
        elseif ($r.Status -eq 'MISSING') {
            $missingCount++
            Add-Content -Path $logFile -Value "  [$playlistName] TRACK MISSING [$trackNum/$totalTracks]: $($r.OutName)"
        }
    }
    Write-Progress -Activity "Phase 2: Encoding audio" -Completed

    # -- Write manifest for next run -------------------------------------------
    $manifest = [PSCustomObject]@{
        PlaylistName  = $playlistName
        PlaylistHash  = $playlistHashNow
        EncodedTracks = $trackPaths
        TrackLUFS     = @($lufsValues)
        LastRunTime   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        TotalTracks   = $totalTracks
        SourceFormat  = $sourceFormat
    }
    Set-ExportManifest -OutputFolder $outputFolder -Manifest $manifest

    # -- Log summary -----------------------------------------------------------
    $summary = "[$playlistName] Format=$sourceFormat Total=$totalTracks Encoded=$encodedOK Missing=$missingCount Errors=$encodedErr AlbumGain=${albumGainStr}dB"
    Add-Content -Path $logFile -Value $summary
    Write-Host "`n  Done  - Encoded: $encodedOK  Missing: $missingCount  Errors: $encodedErr" -ForegroundColor Green
}

# -- Finished ------------------------------------------------------------------
Write-Host "`n----------------------------------------" -ForegroundColor Cyan
Write-Host "All playlists processed." -ForegroundColor Cyan
Write-Host "Log file: $logFile" -ForegroundColor Cyan

# -- Phase 3: Robocopy to removable media (optional) ----
try {
    Write-Host "`n════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  [Phase 3] Sync to Removable Media" -ForegroundColor Cyan
    Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    
    # Get source folder size and file count
    $srcSize = 0
    $srcFileCount = 0
    if (Test-Path -LiteralPath $OutputDir) {
        $srcStats = Get-ChildItem -LiteralPath $OutputDir -Recurse -File | Measure-Object -Property Length -Sum
        $srcSize = $srcStats.Sum
        $srcFileCount = $srcStats.Count
    }
    $srcSizeGB = [Math]::Round($srcSize / 1GB, 2)
    $playlistCount = (Get-ChildItem -LiteralPath $OutputDir -Directory).Count
    
    Write-Host "`n  Source Folder : $OutputDir"
    Write-Host "  Total Size    : $srcSizeGB GB ($srcFileCount files, $playlistCount playlists)"
    
    # List removable drives
    Write-Host "`n  Detecting removable drives..."
    $volumes = Get-Volume | Where-Object { $_.DriveType -eq 'Removable' }
    
    if ($volumes.Count -eq 0) {
        Write-Host "  No removable drives detected.`n" -ForegroundColor Yellow
    } else {
        Write-Host "`n  Available removable media:`n" -ForegroundColor Yellow
        $drives = @()
        for ($i = 0; $i -lt $volumes.Count; $i++) {
            $vol = $volumes[$i]
            $driveLetter = $vol.DriveLetter
            $label = if ($vol.FileSystemLabel) { $vol.FileSystemLabel } else { "(no label)" }
            $freeGB = [Math]::Round($vol.SizeRemaining / 1GB, 2)
            Write-Host "    [$($i+1)] $driveLetter`:\  [$label] - $freeGB GB free"
            $drives += $driveLetter
        }
        
        Write-Host "`n  ─────────────────────────────────────────────────────────────" -ForegroundColor Gray
        Write-Host "`n  (N) Don't sync                  [Default]" -ForegroundColor Green
        Write-Host "      Leave everything as-is`n"
        Write-Host "  (S) Sync changed files only"
        Write-Host "      Copy new/updated files to media"
        Write-Host "      Keep existing files on media untouched`n"
        Write-Host "  (M) Mirror - full sync & cleanup" -ForegroundColor Red
        Write-Host "      Copy all files from source to media"
        Write-Host "      ⚠ DELETE everything on media not in source`n"
        Write-Host "  (D) Select different drive"
        Write-Host "      Choose from available removable media"
        
        Write-Host "`n  ─────────────────────────────────────────────────────────────`n" -ForegroundColor Gray
        $phase3Action = Read-Host "  Choose: (N)o / (S)ync / (M)irror / (D)rive select"
        
        if ($phase3Action -in @('d', 'D')) {
            $driveChoice = Read-Host "  Select drive number (1-$($drives.Count))"
            if ($driveChoice -match '^\d+$' -and [int]$driveChoice -ge 1 -and [int]$driveChoice -le $drives.Count) {
                $selectedDrive = $drives[[int]$driveChoice - 1]
                Write-Host "  Selected: $selectedDrive`:" -ForegroundColor Cyan
                # Ask again for sync type
                Write-Host "`n  (N) Don't sync" -ForegroundColor Green
                Write-Host "  (S) Sync changed files only"
                Write-Host "  (M) Mirror - full sync & cleanup`n" -ForegroundColor Red
                $phase3Action = Read-Host "  Choose: (N)o / (S)ync / (M)irror"
            } else {
                Write-Host "  Invalid selection." -ForegroundColor Red
                $phase3Action = 'n'
            }
        } else {
            # Get the first removable drive for default display
            $selectedDrive = if ($volumes.Count -gt 0) { $volumes[0].DriveLetter } else { $null }
        }
        
        if ($phase3Action -in @('s', 'S', 'm', 'M')) {
            if (-not $selectedDrive) {
                Write-Host "  Error: No drive selected." -ForegroundColor Red
            } else {
                $destPath = "$selectedDrive`:"
                $destVolume = Get-Volume -DriveLetter $selectedDrive -ErrorAction SilentlyContinue
                if (-not $destVolume) {
                    Write-Host "  Error: Drive $destPath not accessible." -ForegroundColor Red
                } else {
                    $destFreeGB = [Math]::Round($destVolume.SizeRemaining / 1GB, 2)
                    $destLabel = if ($destVolume.FileSystemLabel) { $destVolume.FileSystemLabel } else { "(no label)" }
                    
                    # Get existing files on destination
                    $destSize = 0
                    $destFileCount = 0
                    if (Test-Path -LiteralPath $destPath) {
                        $destStats = Get-ChildItem -LiteralPath $destPath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
                        $destSize = $destStats.Sum
                        $destFileCount = $destStats.Count
                    }
                    $destSizeGB = [Math]::Round($destSize / 1GB, 2)
                    
                    Write-Host "`n  ────────────────────────────────────────────────────────────"
                    Write-Host "  Destination   : $destPath`\ [$destLabel]" -ForegroundColor Cyan
                    Write-Host "  Current       : $destSizeGB GB ($destFileCount files)"
                    Write-Host "  Free Space    : $destFreeGB GB available"
                    
                    if ($phase3Action -in @('s', 'S')) {
                        $resultGB = [Math]::Round(($srcSize + $destSize) / 1GB, 2)
                        Write-Host "  ────────────────────────────────────────────────────────────"
                        Write-Host "  Action: Copy new/changed files"
                        Write-Host "          Keep existing files on media"
                        Write-Host "  Result: ~$resultGB GB total (old + new)"
                    } else {
                        Write-Host "  ────────────────────────────────────────────────────────────"
                        Write-Host "  Action: Mirror all files from source"
                        Write-Host "          ⚠ DELETE $destSizeGB GB of existing media" -ForegroundColor Red
                        Write-Host "  Result: ~$srcSizeGB GB (exact copy)"
                    }
                    
                    Write-Host "`n  ────────────────────────────────────────────────────────────`n" -ForegroundColor Gray
                    $confirm = Read-Host "  Proceed with copy? (Y)es / (N)o"
                    
                    if ($confirm -in @('y', 'Y')) {
                        Write-Host "`n  Starting robocopy..." -ForegroundColor Yellow
                        
                        $robocopyArgs = @(
                            $OutputDir,
                            $destPath,
                            "/R:1", "/W:1", "/NFL", "/NDL", "/NP"
                        )
                        
                        if ($phase3Action -in @('s', 'S')) {
                            # Sync without delete - add /S flag
                            $robocopyArgs += "/S"
                        } else {
                            # Mirror with delete (dangerous!) - add /S and /MIR flags
                            $robocopyArgs += @("/S", "/MIR")
                        }
                        
                        # Add log file to end (use forward slash to avoid \r carriage return)
                        $robocopyArgs += "/UNILOG+:$destPath/robocopy.log"
                        
                        & robocopy $robocopyArgs
                        $robocopyExitCode = $LASTEXITCODE
                        
                        # Robocopy exit codes: 0-7 = success (with varying levels of info)
                        if ($robocopyExitCode -le 7) {
                            Write-Host "`n  ✓ Sync completed successfully." -ForegroundColor Green
                            if (Test-Path "$destPath\robocopy.log") {
                                Write-Host "  Log: $destPath\robocopy.log" -ForegroundColor Cyan
                            }
                        } else {
                            Write-Host "`n  ⚠ Robocopy reported issues (exit code: $robocopyExitCode)." -ForegroundColor Yellow
                            if (Test-Path "$destPath\robocopy.log") {
                                Write-Host "  Log: $destPath\robocopy.log" -ForegroundColor Cyan
                            }
                        }
                    } else {
                        Write-Host "  Sync cancelled." -ForegroundColor Yellow
                    }
                }
            }
        }
    }
} catch {
    Write-Host "  Phase 3 error: $_" -ForegroundColor Yellow
}

Write-Host "`n----------------------------------------" -ForegroundColor Cyan
Read-Host "`nPress Enter to exit"
