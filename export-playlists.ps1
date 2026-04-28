#Requires -Version 7.0
<#
.SYNOPSIS
    Playlist Export Tool
    Reads .m3u8 or iTunes .xml playlists, re-encodes audio to MP3 with
    album ReplayGain, silence removal and EQ, and saves numbered files
    into per-playlist output folders.

    Configure all settings in export-playlists.config.ps1
#>

Set-StrictMode -Off

# -- Load configuration --------------------------------------------------------
$configFile = Join-Path $PSScriptRoot "export-playlists.config.ps1"
if (-not (Test-Path $configFile)) {
    Write-Host "ERROR: Configuration file not found: $configFile" -ForegroundColor Red
    Write-Host "Please ensure export-playlists.config.ps1 is in the same folder as this script."
    Read-Host "Press Enter to exit"
    exit 1
}
. $configFile

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
    return ($Name -replace '[\\/:*?"<>|]', '_').Trim()
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
    if ($stderr -match 'Integrated loudness:\s+I:\s+([-\d.]+)\s+LUFS') {
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
    Write-Host "Install ffmpeg and update `$FfmpegPath in export-playlists.config.ps1"
    Read-Host "Press Enter to exit"
    exit 1
}

# Validate playlist directory
if (-not (Test-Path $PlaylistDir)) {
    Write-Host "ERROR: Playlist directory not found: $PlaylistDir" -ForegroundColor Red
    Write-Host "Update `$PlaylistDir in export-playlists.config.ps1"
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

    # Check existing output folder
    if (Test-Path $outputFolder) {
        $answer = Read-Host "  Folder already exists. Overwrite? (y/n)"
        if ($answer -notin @('y', 'Y')) {
            Write-Host "  Skipped." -ForegroundColor Yellow
            Add-Content -Path $logFile -Value "[$playlistName] SKIPPED (folder exists, user declined overwrite)"
            continue
        }
        Remove-Item -Path $outputFolder -Recurse -Force
    }
    New-Item -ItemType Directory -Path $outputFolder | Out-Null

    if ($totalTracks -eq 0) {
        Write-Host "  No tracks found in playlist." -ForegroundColor Yellow
        Add-Content -Path $logFile -Value "[$playlistName] ERROR: No tracks found"
        Remove-Item -Path $outputFolder -Force -ErrorAction SilentlyContinue
        continue
    }

    # -- Phase 1: Measure loudness ---------------------------------------------
    if (-not $ParallelJobs -or $ParallelJobs -lt 1) { $ParallelJobs = 4 }
    $missingCount = 0

    if (-not $ApplyReplayGain) {
        Write-Host "`n  [Phase 1] Skipped (ReplayGain disabled)." -ForegroundColor DarkGray
        $albumGainDB = 0.0
    }
    else {
        Write-Host "`n  [Phase 1] Measuring loudness ($totalTracks tracks, up to $ParallelJobs at a time)..." -ForegroundColor Yellow
        $lufsValues     = @()
        $measureFuncDef = "function Measure-TrackLUFS { ${function:Measure-TrackLUFS} }"
        $ffExe          = $FfmpegPath

        $rawResults = 0..($totalTracks - 1) | ForEach-Object -Parallel {
            . ([scriptblock]::Create($using:measureFuncDef))
            $i       = $_
            $src     = ($using:trackPaths)[$i]
            $missing = -not (Test-Path -LiteralPath $src)
            $lufs    = $null

            if (-not $missing) {
                $lufs = Measure-TrackLUFS -FilePath $src -FfmpegExe $using:ffExe
            }

            [PSCustomObject]@{ Index = $i; Path = $src; LUFS = $lufs; Missing = $missing }
        } -ThrottleLimit $ParallelJobs

        foreach ($r in ($rawResults | Sort-Object Index)) {
            $trackNum = $r.Index + 1
            $leaf     = Split-Path $r.Path -Leaf
            $pctComplete = [int](($trackNum / $totalTracks) * 100)
            
            Write-Progress -Activity "Phase 1: Measuring loudness" -Status "Track $trackNum of $totalTracks" -PercentComplete $pctComplete
            
            if ($r.Missing) {
                Write-Host "    [$trackNum/$totalTracks] WARNING: File not found: $leaf" -ForegroundColor Yellow
                $lufsValues += $null
            }
            elseif ($null -eq $r.LUFS) {
                Write-Host "    [$trackNum/$totalTracks] WARNING: Could not measure loudness, excluded from album average: $leaf" -ForegroundColor Yellow
                $lufsValues += $null
            }
            else {
                Write-Host "    [$trackNum/$totalTracks] $($r.LUFS) LUFS  $leaf"
                $lufsValues += $r.LUFS
            }
        }
        Write-Progress -Activity "Phase 1: Measuring loudness" -Completed

        # Calculate album gain
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
    Write-Host "`n  [Phase 2] Encoding ($totalTracks tracks, up to $ParallelJobs at a time)..." -ForegroundColor Yellow
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

        $ffOutput = & $FfmpegExe -hide_banner -y `
            -i $SrcPath `
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

    $rawResults = 0..($totalTracks - 1) | ForEach-Object -Parallel {
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
            -PadWidth $using:padWidth
    } -ThrottleLimit $ParallelJobs

    $encodedOK  = 0
    $encodedErr = 0

    foreach ($r in ($rawResults | Sort-Object Index)) {
        $trackNum = $r.Index + 1
        $pctComplete = [int](($trackNum / $totalTracks) * 100)
        
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

    # -- Log summary -----------------------------------------------------------
    $summary = "[$playlistName] Format=$sourceFormat Total=$totalTracks Encoded=$encodedOK Missing=$missingCount Errors=$encodedErr AlbumGain=${albumGainStr}dB"
    Add-Content -Path $logFile -Value $summary
    Write-Host "`n  Done  - Encoded: $encodedOK  Missing: $missingCount  Errors: $encodedErr" -ForegroundColor Green
}

# -- Finished ------------------------------------------------------------------
Write-Host "`n----------------------------------------" -ForegroundColor Cyan
Write-Host "All playlists processed." -ForegroundColor Cyan
Write-Host "Log file: $logFile" -ForegroundColor Cyan
Read-Host "`nPress Enter to exit"
