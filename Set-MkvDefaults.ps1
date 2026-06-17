# ============================================================
#  Set-MkvDefaults.ps1
#  Interactive tool to set default audio/subtitle tracks and
#  show basic media info (resolution, codec, quality...) for
#  all video files in a folder (or a single file).
#
#  Supported containers:
#    - Matroska   (.mkv .mka .mks .webm)      -> edited in place with mkvpropedit (instant)
#    - MP4 family (.mp4 .m4v .mov .ts .m2ts)  -> edited with ffmpeg (fast remux, no re-encode)
#    - Others     (.avi .wmv .mpg ...)        -> info shown, default-track editing not supported
#
#  Tools used (auto-detected; locations remembered in media-defaults.config.json):
#    - mkvtoolnix (mkvmerge + mkvpropedit) : https://mkvtoolnix.download/
#    - ffmpeg (ffprobe + ffmpeg), OPTIONAL : https://ffmpeg.org/  (winget install Gyan.FFmpeg)
#        * ffprobe -> richer info (bitrate, HDR, bit depth)
#        * ffmpeg  -> required to EDIT mp4/mov default tracks
# ============================================================

[CmdletBinding()]
param(
    # Folder of media files, or a single media file. (Drag-and-drop friendly.)
    [Alias('Folder')]
    [string]$Path = "",

    # Also scan sub-folders.
    [switch]$Recurse,

    # Optional explicit tool locations (folder containing the .exe, or full path to the .exe).
    [string]$MkvToolNixDir = "",
    [string]$FfmpegDir      = ""
)

# --- Force UTF-8 everywhere so Hebrew/Polish/etc. display and read correctly ---
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
chcp 65001 > $null

# ============================================================
#  Small helpers
# ============================================================
function Write-Sep { Write-Host ("-" * 78) -ForegroundColor DarkGray }

function Exit-Script {
    param([int]$Code = 0)
    Write-Host ""
    Read-Host "Press Enter to exit" | Out-Null
    exit $Code
}

# Find an executable: explicit override -> PATH -> known install dirs.
function Resolve-Tool {
    param(
        [string]$ExeName,        # e.g. "mkvmerge.exe"
        [string]$Override = "",  # full path to exe, or a folder containing it
        [string[]]$SearchDirs = @()
    )

    if ($Override) {
        if (Test-Path -LiteralPath $Override -PathType Leaf) { return (Resolve-Path -LiteralPath $Override).Path }
        $candidate = Join-Path $Override $ExeName
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
    }

    $onPath = Get-Command $ExeName -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    foreach ($dir in $SearchDirs) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        $candidate = Join-Path $dir $ExeName
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    return $null
}

function ConvertTo-DoubleSafe {
    param($Value)
    $out = 0.0
    if ($null -ne $Value -and [double]::TryParse([string]$Value, [ref]$out)) { return $out }
    return $null
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -le 0) { return "?" }
    $units = @("B", "KB", "MB", "GB", "TB")
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt $units.Count - 1) { $Bytes /= 1024; $i++ }
    return ("{0:0.##} {1}" -f $Bytes, $units[$i])
}

function Format-Duration {
    param([double]$Seconds)
    if ($Seconds -le 0) { return "?" }
    $ts = [TimeSpan]::FromSeconds($Seconds)
    if ($ts.TotalHours -ge 1) { return ("{0}:{1:00}:{2:00}" -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds) }
    return ("{0}:{1:00}" -f $ts.Minutes, $ts.Seconds)
}

function Get-ResolutionLabel {
    param([int]$Height, [int]$Width)
    if ($Height -le 0) { return "" }
    if     ($Height -ge 2000) { return "4K (2160p)" }
    elseif ($Height -ge 1400) { return "1440p (QHD)" }
    elseif ($Height -ge 1000) { return "1080p (Full HD)" }
    elseif ($Height -ge 700)  { return "720p (HD)" }
    elseif ($Height -ge 560)  { return "576p (SD)" }
    elseif ($Height -ge 460)  { return "480p (SD)" }
    else                      { return "${Height}p" }
}

# Normalise codec names from either ffprobe (codec_name) or mkvmerge (codec string).
function Get-PrettyCodec {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return "?" }
    $r = $Raw.ToLower()
    switch -Regex ($r) {
        'hevc|h\.?265|h_265'        { return "H.265 (HEVC)" }
        'avc|h\.?264|h_264'         { return "H.264" }
        'av1'                       { return "AV1" }
        'vp9'                       { return "VP9" }
        'vp8'                       { return "VP8" }
        'mpeg-?4p2|mpeg4|divx|xvid' { return "MPEG-4" }
        'mpeg-?2|mpeg2'             { return "MPEG-2" }
        'e-?ac-?3|eac3'             { return "E-AC-3" }
        'truehd'                    { return "TrueHD" }
        'ac-?3|^ac3'                { return "AC-3" }
        'dts'                       { return "DTS" }
        'aac'                       { return "AAC" }
        'flac'                      { return "FLAC" }
        'opus'                      { return "Opus" }
        'vorbis'                    { return "Vorbis" }
        'mp3|mpeg audio'            { return "MP3" }
        'pcm'                       { return "PCM" }
        'subrip|srt'                { return "SRT" }
        'ass|ssa'                   { return "ASS/SSA" }
        'pgs|hdmv'                  { return "PGS" }
        'vobsub|dvd'                { return "VobSub" }
        default                     { return $Raw }
    }
}

function Get-ChannelLabel {
    param($Channels)
    $c = 0
    if (-not [int]::TryParse([string]$Channels, [ref]$c)) { return "" }
    switch ($c) {
        1 { "Mono" }
        2 { "Stereo" }
        6 { "5.1" }
        8 { "7.1" }
        default { if ($c -gt 0) { "$c ch" } else { "" } }
    }
}

# --- Minimal big-endian + MP4/ISO-BMFF box readers (for the instant in-place mp4 editor) ---
function Read-UInt32BE { param([byte[]]$b, [int]$o) ([uint32]$b[$o] -shl 24) -bor ([uint32]$b[$o+1] -shl 16) -bor ([uint32]$b[$o+2] -shl 8) -bor ([uint32]$b[$o+3]) }
function Read-UInt64BE { param([byte[]]$b, [int]$o) ([uint64](Read-UInt32BE $b $o) -shl 32) -bor [uint64](Read-UInt32BE $b ($o+4)) }

# Walk the child boxes inside an in-memory byte[] segment; returns {Type, PayloadStart, End} (relative offsets).
function Get-BoxesMem {
    param([byte[]]$b, [int]$start, [int]$end)
    $r = @(); $o = $start
    while ($o + 8 -le $end) {
        $size = [int64](Read-UInt32BE $b $o)
        $type = [System.Text.Encoding]::ASCII.GetString($b, $o + 4, 4)
        $pay  = $o + 8
        if     ($size -eq 1) { $size = [int64](Read-UInt64BE $b ($o + 8)); $pay = $o + 16 }
        elseif ($size -eq 0) { $size = $end - $o }
        if ($size -lt 8 -or $o + $size -gt $end) { break }
        $r += [PSCustomObject]@{ Type = $type; PayloadStart = $pay; End = [int]($o + $size) }
        $o = [int]($o + $size)
    }
    $r
}

# ============================================================
#  Tool discovery (auto-detect; remember locations in a config file)
# ============================================================
$scriptDir  = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$ConfigPath = Join-Path $scriptDir "media-defaults.config.json"

# Load remembered tool folders (written by a previous successful run, read as UTF-8 for Hebrew paths).
if (Test-Path -LiteralPath $ConfigPath) {
    try {
        $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $MkvToolNixDir -and $cfg.MkvToolNixDir) { $MkvToolNixDir = [string]$cfg.MkvToolNixDir }
        if (-not $FfmpegDir     -and $cfg.FfmpegDir)     { $FfmpegDir     = [string]$cfg.FfmpegDir }
    } catch { }
}

$mkvDirs = @(
    $MkvToolNixDir,
    "C:\UserProgramsFiles\mkvtoolnix",
    "C:\Program Files\MKVToolNix",
    "C:\Program Files (x86)\MKVToolNix",
    (Join-Path $env:LOCALAPPDATA "Programs\MKVToolNix")
)
$ffDirs = @(
    $FfmpegDir,
    "C:\ffmpeg\bin",
    "C:\Program Files\ffmpeg\bin",
    "C:\Program Files\ffmpeg",
    (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links")
)

$MkvMerge    = Resolve-Tool -ExeName "mkvmerge.exe"    -Override $MkvToolNixDir -SearchDirs $mkvDirs
$MkvPropEdit = Resolve-Tool -ExeName "mkvpropedit.exe" -Override $MkvToolNixDir -SearchDirs $mkvDirs
$Ffprobe     = Resolve-Tool -ExeName "ffprobe.exe"     -Override $FfmpegDir     -SearchDirs $ffDirs
$Ffmpeg      = Resolve-Tool -ExeName "ffmpeg.exe"      -Override $FfmpegDir     -SearchDirs $ffDirs

# Need at least one analyzer to be useful.
if (-not ($MkvMerge -or $Ffprobe)) {
    Write-Host "ERROR: Could not find mkvmerge or ffprobe to read media files." -ForegroundColor Red
    Write-Host "Install MKVToolNix (https://mkvtoolnix.download/) or ffmpeg (https://ffmpeg.org/)." -ForegroundColor Yellow
    Exit-Script 1
}

Write-Host ""
Write-Host "Tools detected:" -ForegroundColor Cyan
Write-Host ("  mkvmerge    : {0}" -f $(if ($MkvMerge)    { $MkvMerge }    else { "NOT FOUND" })) -ForegroundColor $(if ($MkvMerge)    { "Green" } else { "DarkYellow" })
Write-Host ("  mkvpropedit : {0}" -f $(if ($MkvPropEdit) { $MkvPropEdit } else { "NOT FOUND" })) -ForegroundColor $(if ($MkvPropEdit) { "Green" } else { "DarkYellow" })
Write-Host ("  ffprobe     : {0}" -f $(if ($Ffprobe)     { $Ffprobe }     else { "NOT FOUND (optional)" })) -ForegroundColor $(if ($Ffprobe)     { "Green" } else { "DarkGray" })
Write-Host ("  ffmpeg      : {0}" -f $(if ($Ffmpeg)      { $Ffmpeg }      else { "NOT FOUND (needed to edit mp4/mov)" })) -ForegroundColor $(if ($Ffmpeg)      { "Green" } else { "DarkGray" })

# Warn about an OLD MKVToolNix. Old mkvpropedit rewrites the .mkv header instead of a quick
# in-place flag flip - that's slower and can fragment / hurt playback on slow drives.
function Get-MkvToolNixMajor {
    param([string]$ExePath)
    if (-not $ExePath) { return $null }
    try {
        $line = (& $ExePath --version 2>$null | Select-Object -First 1)
        if ($line -match 'v(\d+)\.') { return [int]$Matches[1] }
    } catch { }
    return $null
}
$mkvVer = Get-MkvToolNixMajor $MkvPropEdit
if ($mkvVer) {
    Write-Host ("  MKVToolNix version: {0}" -f $mkvVer) -ForegroundColor DarkGray
    if ($mkvVer -lt 60) {
        Write-Host "  WARNING: this MKVToolNix is old (v$mkvVer). Old versions rewrite the .mkv header instead of a" -ForegroundColor Yellow
        Write-Host "           quick in-place flag change - slower, and can cause stutter / slow startup on slow" -ForegroundColor Yellow
        Write-Host "           drives. Update at https://mkvtoolnix.download/ for instant, clean edits." -ForegroundColor Yellow
    }
}

# If ffmpeg is missing, let the user point at it now (handy for portable/custom installs).
if (-not $Ffmpeg) {
    Write-Host ""
    Write-Host "ffmpeg not found. It's needed to EDIT mp4/mov default tracks (and gives richer info)." -ForegroundColor DarkYellow
    $ans = (Read-Host "Paste full path to ffmpeg.exe or its folder, or press Enter to skip").Trim().Trim('"').Trim("'")
    if ($ans) {
        $ffDir   = if (Test-Path -LiteralPath $ans -PathType Leaf) { Split-Path -LiteralPath $ans -Parent } else { $ans }
        $foundFf = Resolve-Tool -ExeName "ffmpeg.exe" -Override $ffDir
        if ($foundFf) {
            $Ffmpeg = $foundFf
            if (-not $Ffprobe) { $Ffprobe = Resolve-Tool -ExeName "ffprobe.exe" -Override $ffDir }
            Write-Host "  ffmpeg : $Ffmpeg" -ForegroundColor Green
            if ($Ffprobe) { Write-Host "  ffprobe: $Ffprobe" -ForegroundColor Green }
        } else {
            Write-Host "  Still couldn't find ffmpeg.exe there - continuing without it." -ForegroundColor DarkYellow
        }
    }
}

# Remember what we found so next time is instant (written as UTF-8 to preserve Hebrew paths).
# Fall back to any value we already loaded so we never overwrite a good config with blanks.
$mkvOutDir = if ($MkvMerge) { [System.IO.Path]::GetDirectoryName($MkvMerge) } elseif ($MkvToolNixDir) { $MkvToolNixDir } else { "" }
$ffOutDir  = if ($Ffmpeg)   { [System.IO.Path]::GetDirectoryName($Ffmpeg) }   elseif ($FfmpegDir)     { $FfmpegDir }     else { "" }
if ($mkvOutDir -or $ffOutDir) {
    $cfgOut = [ordered]@{ MkvToolNixDir = $mkvOutDir; FfmpegDir = $ffOutDir }
    try { ($cfgOut | ConvertTo-Json) | Out-File -LiteralPath $ConfigPath -Encoding UTF8 } catch { }
}

# ============================================================
#  Resolve the input path (file or folder)
# ============================================================
if ([string]::IsNullOrWhiteSpace($Path)) {
    Write-Host ""
    Write-Host "TIP: drag-and-drop a folder (or a single video file) onto this window," -ForegroundColor DarkCyan
    Write-Host "     then press Enter." -ForegroundColor DarkCyan
    Write-Host ""
    $Path = Read-Host "Enter full path to folder or file"
}

# Clean up the path - quotes, whitespace, and stray RTL/LTR marks from copied Hebrew paths.
# (\uXXXX escapes are handled by the .NET regex engine, keeping this script pure-ASCII.)
$Path = $Path.Trim().Trim('"').Trim("'").Trim()
$Path = ($Path -replace "[\u200E\u200F\u202A\u202B\u202C\u202D\u202E]", "").Trim()

Write-Host ""
Write-Host "Path received: $Path" -ForegroundColor DarkGray

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Host ""
    Write-Host "ERROR: Path does not exist: $Path" -ForegroundColor Red
    try {
        $parent = [System.IO.Path]::GetDirectoryName($Path)
        if ($parent -and (Test-Path -LiteralPath $parent -PathType Container)) {
            Write-Host "Parent folder exists: $parent" -ForegroundColor Yellow
            Write-Host "Items inside it:" -ForegroundColor Yellow
            Get-ChildItem -LiteralPath $parent | ForEach-Object { Write-Host "   - $($_.Name)" -ForegroundColor DarkYellow }
            Write-Host "Tip: copy a name above EXACTLY, or drag-and-drop instead." -ForegroundColor Cyan
        }
    } catch { }
    Exit-Script 1
}

# Extensions we know how to read / edit.
$SupportedExt  = @(".mkv", ".mka", ".mks", ".webm", ".mp4", ".m4v", ".mov", ".ts", ".m2ts", ".avi", ".wmv", ".mpg", ".mpeg", ".flv")
$MatroskaExt   = @(".mkv", ".mka", ".mks", ".webm")          # edited in place by mkvpropedit (instant)
$Mp4InPlaceExt = @(".mp4", ".m4v", ".mov")                   # ISO-BMFF: tkhd flag flipped in place (instant)
$RemuxExt      = @(".ts", ".m2ts")                           # not ISO-BMFF: need a lossless remux to set flags

$pathItem = Get-Item -LiteralPath $Path
if ($pathItem.PSIsContainer) {
    $gciParams = @{ LiteralPath = $Path; File = $true }
    if ($Recurse) { $gciParams["Recurse"] = $true }
    # Clean up any leftover temp files from a previously interrupted remux.
    Get-ChildItem @gciParams | Where-Object { $_.Name -like "*__setdefaults_tmp__*" } | Remove-Item -Force -ErrorAction SilentlyContinue
    $files = @(Get-ChildItem @gciParams |
        Where-Object { ($SupportedExt -contains $_.Extension.ToLower()) -and ($_.Name -notlike "*__setdefaults_tmp__*") } |
        Sort-Object Name)
} else {
    if ($SupportedExt -notcontains $pathItem.Extension.ToLower()) {
        Write-Host "ERROR: '$($pathItem.Name)' is not a supported video file." -ForegroundColor Red
        Exit-Script 1
    }
    $files = @($pathItem)
}

if ($files.Count -eq 0) {
    Write-Host "No supported video files found." -ForegroundColor Yellow
    Write-Host "Looked for: $($SupportedExt -join ', ')" -ForegroundColor DarkGray
    Exit-Script 0
}

Write-Host ""
Write-Host "Found $($files.Count) media file(s)." -ForegroundColor Green
Write-Host "Analyzing..." -ForegroundColor Cyan

# ============================================================
#  Media analysis
# ============================================================

# --- ffprobe analyzer (richest: bitrate, bit depth, HDR) ---
function Get-MediaInfo-Ffprobe {
    param([System.IO.FileInfo]$File)
    $json = & $Ffprobe -v quiet -print_format json -show_format -show_streams $File.FullName 2>$null | Out-String
    if ([string]::IsNullOrWhiteSpace($json)) { return $null }
    $data = $json | ConvertFrom-Json

    $video = @(); $audio = @(); $subs = @()
    $aIdx = 0; $sIdx = 0
    foreach ($s in $data.streams) {
        $lang = if ($s.tags.language) { $s.tags.language } else { "und" }
        $name = if ($s.tags.title) { $s.tags.title } else { "" }
        $isDefault = ($s.disposition.default -eq 1)
        switch ($s.codec_type) {
            "video" {
                if ($s.disposition.attached_pic -eq 1) { continue }  # skip cover-art images
                $bitDepth = ""
                if     ($s.pix_fmt -match '10') { $bitDepth = "10-bit" }
                elseif ($s.pix_fmt -match '12') { $bitDepth = "12-bit" }
                $hdr = ($s.color_transfer -in @("smpte2084", "arib-std-b67"))
                $video += [PSCustomObject]@{
                    Codec = Get-PrettyCodec $s.codec_name
                    Width = [int]$s.width; Height = [int]$s.height
                    BitDepth = $bitDepth; Hdr = $hdr
                }
            }
            "audio" {
                $audio += [PSCustomObject]@{
                    TypeIndex = $aIdx; Codec = Get-PrettyCodec $s.codec_name
                    Channels = Get-ChannelLabel $s.channels
                    Language = $lang; Name = $name; Default = $isDefault
                }
                $aIdx++
            }
            "subtitle" {
                $subs += [PSCustomObject]@{
                    TypeIndex = $sIdx; Codec = Get-PrettyCodec $s.codec_name
                    Channels = ""; Language = $lang; Name = $name; Default = $isDefault
                }
                $sIdx++
            }
        }
    }

    $dur  = ConvertTo-DoubleSafe $data.format.duration
    $size = ConvertTo-DoubleSafe $data.format.size
    $br   = ConvertTo-DoubleSafe $data.format.bit_rate
    return [PSCustomObject]@{ Video = $video; Audio = $audio; Subs = $subs; Duration = $dur; Size = $size; Bitrate = $br }
}

# --- mkvmerge analyzer (works without ffmpeg; reads mp4/mov/avi too) ---
function Get-MediaInfo-Mkvmerge {
    param([System.IO.FileInfo]$File)
    $json = & $MkvMerge -J $File.FullName 2>$null | Out-String
    if ([string]::IsNullOrWhiteSpace($json)) { return $null }
    $data = $json | ConvertFrom-Json

    $video = @(); $audio = @(); $subs = @()
    $aIdx = 0; $sIdx = 0
    foreach ($t in $data.tracks) {
        $p = $t.properties
        $lang = if ($p.language) { $p.language } else { "und" }
        $name = if ($p.track_name) { $p.track_name } else { "" }
        $isDefault = [bool]$p.default_track
        switch ($t.type) {
            "video" {
                $w = 0; $h = 0
                if ($p.pixel_dimensions -match '^(\d+)x(\d+)$') { $w = [int]$Matches[1]; $h = [int]$Matches[2] }
                $bitDepth = if ($p.bit_depth -and [int]$p.bit_depth -gt 8) { "$($p.bit_depth)-bit" } else { "" }
                $video += [PSCustomObject]@{
                    Codec = Get-PrettyCodec $t.codec
                    Width = $w; Height = $h; BitDepth = $bitDepth; Hdr = $false
                }
            }
            "audio" {
                $audio += [PSCustomObject]@{
                    TypeIndex = $aIdx; Codec = Get-PrettyCodec $t.codec
                    Channels = Get-ChannelLabel $p.audio_channels
                    Language = $lang; Name = $name; Default = $isDefault
                }
                $aIdx++
            }
            "subtitles" {
                $subs += [PSCustomObject]@{
                    TypeIndex = $sIdx; Codec = Get-PrettyCodec $t.codec
                    Channels = ""; Language = $lang; Name = $name; Default = $isDefault
                }
                $sIdx++
            }
        }
    }

    $durNs = ConvertTo-DoubleSafe $data.container.properties.duration   # nanoseconds
    $dur   = if ($durNs) { $durNs / 1e9 } else { $null }
    $size  = [double]$File.Length
    $br    = if ($dur -and $dur -gt 0) { ($size * 8) / $dur } else { $null }
    return [PSCustomObject]@{ Video = $video; Audio = $audio; Subs = $subs; Duration = $dur; Size = $size; Bitrate = $br }
}

# Build the one-line "basic info" summary the user asked for.
function Build-Summary {
    param($Raw)
    $parts = @()
    $v = if ($Raw.Video.Count -gt 0) { $Raw.Video[0] } else { $null }
    if ($v) {
        if ($v.Height -gt 0) {
            $res = Get-ResolutionLabel -Height $v.Height -Width $v.Width
            if ($v.Width -gt 0) { $res = "$res  [$($v.Width)x$($v.Height)]" }
            if ($res) { $parts += $res }
        }
        $vc = $v.Codec
        if ($v.BitDepth) { $vc = "$vc $($v.BitDepth)" }
        if ($v.Hdr)      { $vc = "$vc HDR" }
        $parts += $vc
    }
    if ($Raw.Bitrate  -and $Raw.Bitrate  -gt 0) { $parts += ("{0:0.0} Mbps" -f ($Raw.Bitrate / 1e6)) }
    if ($Raw.Size     -and $Raw.Size     -gt 0) { $parts += (Format-Size $Raw.Size) }
    if ($Raw.Duration -and $Raw.Duration -gt 0) { $parts += (Format-Duration $Raw.Duration) }
    return ($parts -join "  -  ")
}

function Build-AudioSummary {
    param($Raw)
    if ($Raw.Audio.Count -eq 0) { return "(no audio)" }
    $items = $Raw.Audio | ForEach-Object {
        $s = "$($_.Language) $($_.Codec)"
        if ($_.Channels) { $s = "$s $($_.Channels)" }
        if ($_.Default)  { $s = "$s*" }
        $s
    }
    return ($items -join ", ")
}

# --- Analyze every file ---
$fileInfos = @()
foreach ($f in $files) {
    $raw = $null
    if ($Ffprobe) { $raw = Get-MediaInfo-Ffprobe $f }
    if ($null -eq $raw -and $MkvMerge) { $raw = Get-MediaInfo-Mkvmerge $f }
    if ($null -eq $raw) {
        Write-Host "   ! Could not read $($f.Name) - skipping" -ForegroundColor Red
        continue
    }

    $ext = $f.Extension.ToLower()
    $editor = $null
    if ($MatroskaExt -contains $ext) {
        if ($MkvPropEdit) { $editor = "mkvpropedit" } elseif ($Ffmpeg) { $editor = "ffmpeg" }
    } elseif ($Mp4InPlaceExt -contains $ext) {
        # Flip the tkhd "enabled" flag straight in the moov header - instant, no rewrite, no tool.
        # Falls back to a lossless remux at apply time if the file's structure is unexpected.
        $editor = "mp4-inplace"
    } elseif ($RemuxExt -contains $ext) {
        if ($MkvMerge) { $editor = "mkvmerge-remux" } elseif ($Ffmpeg) { $editor = "ffmpeg" }
    }

    $fileInfos += [PSCustomObject]@{
        File         = $f
        Ext          = $ext
        Audio        = $raw.Audio
        Subs         = $raw.Subs
        Editor       = $editor
        Summary      = Build-Summary $raw
        AudioSummary = Build-AudioSummary $raw
    }
}

if ($fileInfos.Count -eq 0) {
    Write-Host "Could not read any files." -ForegroundColor Red
    Exit-Script 1
}

# ============================================================
#  Show the basic info for every file (personal request #2)
# ============================================================
Write-Host ""
Write-Sep
Write-Host "MEDIA INFO" -ForegroundColor Cyan
Write-Sep
foreach ($fi in $fileInfos) {
    $editNote = if ($fi.Editor) { "" } else { "   (default-track editing not available for this file)" }
    Write-Host ("* " + $fi.File.Name) -ForegroundColor White -NoNewline
    Write-Host $editNote -ForegroundColor DarkYellow
    if ($fi.Summary)      { Write-Host ("    $($fi.Summary)") -ForegroundColor Gray }
    if ($fi.AudioSummary) { Write-Host ("    Audio: $($fi.AudioSummary)   (* = current default)") -ForegroundColor DarkGray }
}

# ============================================================
#  Group files by audio/subtitle structure
# ============================================================
function Get-Signature {
    param($info)
    $aSig = ($info.Audio | ForEach-Object { "$($_.Language)|$($_.Codec)|$($_.Name)" }) -join " // "
    $sSig = ($info.Subs  | ForEach-Object { "$($_.Language)|$($_.Codec)|$($_.Name)" }) -join " // "
    "AUDIO[$($info.Audio.Count)]: $aSig ;; SUBS[$($info.Subs.Count)]: $sSig"
}

# @(...) forces an array: with a single group, a bare GroupInfo's .Count is its MEMBER count,
# which would falsely trigger the "different layouts" branch below.
$groups = @($fileInfos | Group-Object { Get-Signature $_ })

if ($groups.Count -gt 1) {
    Write-Host ""
    Write-Host "NOTE: files here have DIFFERENT audio/subtitle layouts." -ForegroundColor Yellow
    Write-Sep
    $idx = 1
    foreach ($g in $groups) {
        $sample = $g.Group[0]
        Write-Host ""
        Write-Host "== Group $idx ($($g.Count) file(s)) ==" -ForegroundColor Yellow
        Write-Host "Audio:" -ForegroundColor Cyan
        foreach ($a in $sample.Audio) { Write-Host ("   [a$($a.TypeIndex + 1)] lang=$($a.Language)  codec=$($a.Codec)  name='$($a.Name)'") }
        Write-Host "Subtitles:" -ForegroundColor Cyan
        if ($sample.Subs.Count -eq 0) { Write-Host "   (none)" }
        else { foreach ($s in $sample.Subs) { Write-Host ("   [s$($s.TypeIndex + 1)] lang=$($s.Language)  codec=$($s.Codec)  name='$($s.Name)'") } }
        Write-Host "Files:" -ForegroundColor DarkCyan
        foreach ($x in $g.Group) { Write-Host ("   - $($x.File.Name)") }
        $idx++
    }
    Write-Sep
    Write-Host ""
    Write-Host "Options:" -ForegroundColor White
    Write-Host "  1. Cancel - I'll fix the odd files manually first"
    Write-Host "  2. Process ONLY the largest group (skip the others)"
    Write-Host "  3. Process each group separately (ask me for each one)"
    $choice = Read-Host "Choose 1, 2, or 3"
    switch ($choice) {
        "1" { Write-Host "Cancelled." -ForegroundColor Yellow; Exit-Script 0 }
        "2" { $groupsToProcess = @($groups | Sort-Object Count -Descending | Select-Object -First 1) }
        "3" { $groupsToProcess = $groups }
        default { Write-Host "Invalid choice. Cancelled." -ForegroundColor Red; Exit-Script 0 }
    }
} else {
    $groupsToProcess = $groups
}

# ============================================================
#  Ask which tracks should be default for a group
# ============================================================
function Select-Defaults {
    param($group)
    $sample = $group.Group[0]

    Write-Host ""
    Write-Sep
    Write-Host "Configuring $($group.Count) file(s):" -ForegroundColor Green
    foreach ($x in $group.Group | Select-Object -First 3) { Write-Host "   - $($x.File.Name)" -ForegroundColor DarkGray }
    if ($group.Count -gt 3) { Write-Host "   ... and $($group.Count - 3) more" -ForegroundColor DarkGray }
    Write-Sep

    # --- AUDIO ---
    $audioIdx = -1
    if ($sample.Audio.Count -eq 0) {
        Write-Host ""
        Write-Host "(No audio tracks in these files)" -ForegroundColor DarkGray
    } else {
        Write-Host ""
        Write-Host "AUDIO TRACKS:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $sample.Audio.Count; $i++) {
            $a = $sample.Audio[$i]
            $langDisplay = $a.Language
            $note = ""
            if ($a.Language -eq "und" -or [string]::IsNullOrWhiteSpace($a.Language)) {
                $note = "  <-- LANGUAGE NOT TAGGED, check name!"; $langDisplay = "und (unknown)"
            }
            $defMark = if ($a.Default) { " [currently default]" } else { "" }
            Write-Host ("  {0}. lang={1}  codec={2}  {3}  name='{4}'{5}{6}" -f ($i + 1), $langDisplay, $a.Codec, $a.Channels, $a.Name, $defMark, $note) -ForegroundColor White
        }
        Write-Host ""
        $audioChoice = Read-Host "Which audio track should be DEFAULT? (1-$($sample.Audio.Count))"
        $parsed = 0
        if (-not [int]::TryParse($audioChoice, [ref]$parsed)) {
            Write-Host "Invalid choice." -ForegroundColor Red; return $null
        }
        $audioIdx = $parsed - 1
        if ($audioIdx -lt 0 -or $audioIdx -ge $sample.Audio.Count) {
            Write-Host "Invalid choice." -ForegroundColor Red; return $null
        }
    }

    # --- SUBTITLES ---
    $subIdx = -1
    if ($sample.Subs.Count -gt 0) {
        Write-Host ""
        Write-Host "SUBTITLE TRACKS:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $sample.Subs.Count; $i++) {
            $s = $sample.Subs[$i]
            $langDisplay = $s.Language
            $note = ""
            if ($s.Language -eq "und" -or [string]::IsNullOrWhiteSpace($s.Language)) {
                $note = "  <-- LANGUAGE NOT TAGGED, check name!"; $langDisplay = "und (unknown)"
            }
            $defMark = if ($s.Default) { " [currently default]" } else { "" }
            Write-Host ("  {0}. lang={1}  codec={2}  name='{3}'{4}{5}" -f ($i + 1), $langDisplay, $s.Codec, $s.Name, $defMark, $note) -ForegroundColor White
        }
        Write-Host "  0. NO default subtitles (don't show subs automatically)" -ForegroundColor Gray
        Write-Host ""
        $subChoice = Read-Host "Which subtitle should be DEFAULT? (0 for none, 1-$($sample.Subs.Count))"
        $parsed = 0
        if (-not [int]::TryParse($subChoice, [ref]$parsed)) {
            Write-Host "Invalid choice." -ForegroundColor Red; return $null
        }
        $subIdx = $parsed - 1
        if ($subIdx -lt -1 -or $subIdx -ge $sample.Subs.Count) {
            Write-Host "Invalid choice." -ForegroundColor Red; return $null
        }
    } else {
        Write-Host ""
        Write-Host "(No subtitle tracks in these files)" -ForegroundColor DarkGray
    }

    return [PSCustomObject]@{ AudioIndex = $audioIdx; SubIndex = $subIdx }
}

# ============================================================
#  Apply: Matroska via mkvpropedit (in place, instant)
# ============================================================
function Set-Defaults-Mkvpropedit {
    param($FileInfo, [int]$AudioIndex, [int]$SubIndex)
    if (-not $MkvPropEdit) { return $false }

    $ppArgs = @($FileInfo.File.FullName)
    for ($i = 0; $i -lt $FileInfo.Audio.Count; $i++) {
        $ppArgs += "--edit"; $ppArgs += "track:a$($i + 1)"
        $ppArgs += "--set";  $ppArgs += "flag-enabled=1"
        $ppArgs += "--set";  $ppArgs += "flag-default=$([int]($i -eq $AudioIndex))"
    }
    for ($i = 0; $i -lt $FileInfo.Subs.Count; $i++) {
        $ppArgs += "--edit"; $ppArgs += "track:s$($i + 1)"
        $ppArgs += "--set";  $ppArgs += "flag-enabled=1"
        $ppArgs += "--set";  $ppArgs += "flag-default=$([int]($i -eq $SubIndex))"
    }
    & $MkvPropEdit @ppArgs | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# ============================================================
#  Apply: MP4/M4V/MOV -> flip the tkhd "enabled" flag in place (INSTANT, no rewrite)
#  In an ISO-BMFF file the default-audio choice is just the per-track "enabled" bit
#  (bit 0 of the tkhd flags) living in the small moov header. We overwrite that single
#  byte per track - the multi-GB media data is never touched, so it's instant on any drive.
#  Strict safety: if the parsed track layout doesn't match what analysis reported, we bail
#  and let the caller fall back to a lossless remux - never guess and risk corruption.
# ============================================================
function Set-Defaults-Mp4InPlace {
    param($FileInfo, [int]$AudioIndex, [int]$SubIndex)
    $path        = $FileInfo.File.FullName
    $expectAudio = $FileInfo.Audio.Count
    $expectSubs  = $FileInfo.Subs.Count
    $subHandlers = @("subt", "sbtl", "text", "clcp", "tx3g")

    $fs = $null
    try {
        $fs = [System.IO.File]::Open($path, "Open", "ReadWrite")
        $len = $fs.Length
        $hdr = New-Object byte[] 16
        $pos = [int64]0
        $moovPay = [int64](-1); $moovEnd = [int64](-1)

        # Walk top-level boxes (reading only headers; mdat is skipped, never loaded) to find moov.
        while ($pos + 8 -le $len) {
            $fs.Position = $pos
            if ($fs.Read($hdr, 0, 8) -lt 8) { break }
            $size = [int64](Read-UInt32BE $hdr 0)
            $type = [System.Text.Encoding]::ASCII.GetString($hdr, 4, 4)
            $pay  = $pos + 8
            if     ($size -eq 1) { $fs.Position = $pos + 8; $fs.Read($hdr, 0, 8) | Out-Null; $size = [int64](Read-UInt64BE $hdr 0); $pay = $pos + 16 }
            elseif ($size -eq 0) { $size = $len - $pos }
            if ($size -lt 8) { break }
            if ($type -eq "moov") { $moovPay = $pay; $moovEnd = $pos + $size; break }
            $pos += $size
        }
        if ($moovPay -lt 0) { return $false }   # not an ISO-BMFF file we recognise

        $mlen = [int]($moovEnd - $moovPay)
        $moov = New-Object byte[] $mlen
        $fs.Position = $moovPay
        $rd = 0; while ($rd -lt $mlen) { $n = $fs.Read($moov, $rd, $mlen - $rd); if ($n -le 0) { break }; $rd += $n }

        # For each trak: locate the tkhd flags byte and the handler type (soun / subtitle / vide).
        $audio = @(); $subs = @()
        foreach ($trak in (Get-BoxesMem $moov 0 $mlen | Where-Object { $_.Type -eq "trak" })) {
            $kids = Get-BoxesMem $moov $trak.PayloadStart $trak.End
            $tkhd = $kids | Where-Object { $_.Type -eq "tkhd" } | Select-Object -First 1
            $mdia = $kids | Where-Object { $_.Type -eq "mdia" } | Select-Object -First 1
            if (-not $tkhd -or -not $mdia) { continue }
            $hdlr = Get-BoxesMem $moov $mdia.PayloadStart $mdia.End | Where-Object { $_.Type -eq "hdlr" } | Select-Object -First 1
            if (-not $hdlr) { continue }
            $h = [System.Text.Encoding]::ASCII.GetString($moov, $hdlr.PayloadStart + 8, 4)
            $entry = [PSCustomObject]@{ Abs = $moovPay + $tkhd.PayloadStart + 3; Cur = $moov[$tkhd.PayloadStart + 3] }
            if     ($h -eq "soun")           { $audio += $entry }
            elseif ($subHandlers -contains $h) { $subs += $entry }
        }

        # Safety net: only edit if our parse agrees with the earlier analysis.
        if ($audio.Count -ne $expectAudio) { return $false }
        if ($expectSubs -gt 0 -and $subs.Count -ne $expectSubs) { return $false }

        $lastWrite = (Get-Item -LiteralPath $path).LastWriteTime
        # Set the "enabled" bit (0x01) on the chosen audio track, clear it on the rest. Touch only bit 0.
        for ($i = 0; $i -lt $audio.Count; $i++) {
            $nb = [byte](($audio[$i].Cur -band 0xFE) -bor [int]($i -eq $AudioIndex))
            $fs.Position = $audio[$i].Abs; $fs.WriteByte($nb)
        }
        if ($expectSubs -gt 0) {
            for ($i = 0; $i -lt $subs.Count; $i++) {
                $nb = [byte](($subs[$i].Cur -band 0xFE) -bor [int]($i -eq $SubIndex))
                $fs.Position = $subs[$i].Abs; $fs.WriteByte($nb)
            }
        }
        $fs.Flush(); $fs.Dispose(); $fs = $null
        try { (Get-Item -LiteralPath $path).LastWriteTime = $lastWrite } catch { }
        return $true
    } catch {
        return $false
    } finally {
        if ($fs) { $fs.Dispose() }
    }
}

# ============================================================
#  Apply: TS/M2TS (or fallback) -> fresh .mkv via mkvmerge (lossless remux, copy speed)
#  Produces a clean Matroska so the flags are set correctly AND every future
#  change is instant (mkvpropedit). The original file is replaced.
# ============================================================
function Set-Defaults-MkvmergeRemux {
    param($FileInfo, [int]$AudioIndex, [int]$SubIndex)
    if (-not $MkvMerge) { return $false }

    $src  = $FileInfo.File.FullName
    $dir  = [System.IO.Path]::GetDirectoryName($src)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($src)
    $dst  = Join-Path $dir ("$base.mkv")
    $tmp  = Join-Path $dir ("$base.__setdefaults_tmp__.mkv")

    # Don't silently overwrite a different, existing .mkv that shares the base name.
    if ((Test-Path -LiteralPath $dst) -and ($dst -ne $src)) {
        Write-Host "     SKIP: '$base.mkv' already exists next to it." -ForegroundColor Yellow
        return $false
    }

    # Use mkvmerge's own track IDs (per type, in file order) to set the flags during the mux.
    $j = & $MkvMerge -J $src 2>$null | Out-String | ConvertFrom-Json
    if ($null -eq $j) { return $false }
    $audIds = @($j.tracks | Where-Object { $_.type -eq "audio" }     | ForEach-Object { $_.id })
    $subIds = @($j.tracks | Where-Object { $_.type -eq "subtitles" } | ForEach-Object { $_.id })

    $mm = @("-o", $tmp)
    for ($i = 0; $i -lt $audIds.Count; $i++) {
        $mm += "--default-track-flag"; $mm += ("{0}:{1}" -f $audIds[$i], [int]($i -eq $AudioIndex))
        $mm += "--track-enabled-flag"; $mm += ("{0}:1"   -f $audIds[$i])
    }
    for ($i = 0; $i -lt $subIds.Count; $i++) {
        $mm += "--default-track-flag"; $mm += ("{0}:{1}" -f $subIds[$i], [int]($i -eq $SubIndex))
        $mm += "--track-enabled-flag"; $mm += ("{0}:1"   -f $subIds[$i])
    }
    $mm += $src

    & $MkvMerge @mm | Out-Null
    # mkvmerge exit codes: 0 = ok, 1 = warnings (file still produced), 2 = error.
    if ($LASTEXITCODE -ge 2 -or -not (Test-Path -LiteralPath $tmp)) {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        return $false
    }
    try {
        $lastWrite = (Get-Item -LiteralPath $src).LastWriteTime
        Move-Item -LiteralPath $tmp -Destination $dst -Force
        (Get-Item -LiteralPath $dst).LastWriteTime = $lastWrite
        if ($dst -ne $src) { Remove-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue }  # drop the old .mp4
        return $true
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        return $false
    }
}

# ============================================================
#  Apply: MP4/MOV/TS via ffmpeg (in-place remux, no re-encode) - fallback when mkvmerge is absent
# ============================================================
function Set-Defaults-Ffmpeg {
    param($FileInfo, [int]$AudioIndex, [int]$SubIndex)
    if (-not $Ffmpeg) { return $false }

    $src  = $FileInfo.File.FullName
    $dir  = [System.IO.Path]::GetDirectoryName($src)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($src)
    $ext  = [System.IO.Path]::GetExtension($src)
    $tmp  = Join-Path $dir ("$base.__setdefaults_tmp__$ext")

    # -nostdin: don't let ffmpeg eat the console input the script's prompts use.
    # -stats:   show a live progress line so a big remux doesn't look frozen.
    # No -movflags +faststart: it forces a second full pass over the file (doubles the I/O)
    #   and reorganizes the container - skip it to stay fast and minimal-touch.
    $ff = @("-y", "-nostdin", "-hide_banner", "-loglevel", "error", "-stats", "-i", $src,
            "-map", "0", "-c", "copy", "-map_metadata", "0", "-map_chapters", "0")
    for ($i = 0; $i -lt $FileInfo.Audio.Count; $i++) {
        $ff += "-disposition:a:$i"; $ff += $(if ($i -eq $AudioIndex) { "default" } else { "0" })
    }
    for ($i = 0; $i -lt $FileInfo.Subs.Count; $i++) {
        $ff += "-disposition:s:$i"; $ff += $(if ($i -eq $SubIndex) { "default" } else { "0" })
    }
    $ff += $tmp

    & $Ffmpeg @ff
    if ($LASTEXITCODE -ne 0) {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        return $false
    }
    try {
        $lastWrite = (Get-Item -LiteralPath $src).LastWriteTime
        Move-Item -LiteralPath $tmp -Destination $src -Force
        (Get-Item -LiteralPath $src).LastWriteTime = $lastWrite
        return $true
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        return $false
    }
}

# ============================================================
#  Process each selected group
# ============================================================
$totalFixed   = 0
$totalSkipped = 0
foreach ($g in $groupsToProcess) {
    $sel = Select-Defaults $g
    if ($null -eq $sel) { Write-Host "Skipping this group." -ForegroundColor Yellow; continue }

    Write-Host ""
    Write-Host "Applying changes..." -ForegroundColor Green
    # .mkv and .mp4/.mov edit a single header flag in place (instant). Only .ts/.m2ts (or a rare
    # fallback) need a lossless remux - explain that one so a slower file doesn't look wrong.
    if (@($g.Group | Where-Object { $_.Editor -eq "mkvmerge-remux" -or $_.Editor -eq "ffmpeg" }).Count -gt 0) {
        Write-Host "  Note: .ts/.m2ts (and any fallback) are remuxed losslessly into a fresh .mkv - copy speed," -ForegroundColor DarkGray
        Write-Host "        no re-encoding; the original is replaced. (.mkv and .mp4/.mov are edited instantly.)" -ForegroundColor DarkGray
    }
    foreach ($fi in $g.Group) {
        if (-not $fi.Editor) {
            $why = if ($RemuxExt -contains $fi.Ext) { "needs mkvmerge or ffmpeg" } else { "$($fi.Ext) editing not supported" }
            Write-Host "  - SKIP $($fi.File.Name)  ($why)" -ForegroundColor DarkYellow
            $totalSkipped++
            continue
        }

        $label = switch ($fi.Editor) {
            "mp4-inplace"    { " (flag set in place - instant)" }
            "mkvmerge-remux" { " -> .mkv (lossless, $(Format-Size $fi.File.Length))" }
            "ffmpeg"         { " (lossless rewrite, $(Format-Size $fi.File.Length))" }
            default          { "" }
        }
        Write-Host "  -> $($fi.File.Name)$label" -ForegroundColor White

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $ok = $false
        if ($fi.Editor -eq "mkvpropedit") {
            $ok = Set-Defaults-Mkvpropedit -FileInfo $fi -AudioIndex $sel.AudioIndex -SubIndex $sel.SubIndex
        } elseif ($fi.Editor -eq "mp4-inplace") {
            $ok = Set-Defaults-Mp4InPlace -FileInfo $fi -AudioIndex $sel.AudioIndex -SubIndex $sel.SubIndex
            if (-not $ok) {
                Write-Host "     in-place edit not possible here; falling back to a lossless remux..." -ForegroundColor DarkYellow
                if     ($MkvMerge) { $ok = Set-Defaults-MkvmergeRemux -FileInfo $fi -AudioIndex $sel.AudioIndex -SubIndex $sel.SubIndex }
                elseif ($Ffmpeg)   { $ok = Set-Defaults-Ffmpeg        -FileInfo $fi -AudioIndex $sel.AudioIndex -SubIndex $sel.SubIndex }
            }
        } elseif ($fi.Editor -eq "mkvmerge-remux") {
            $ok = Set-Defaults-MkvmergeRemux -FileInfo $fi -AudioIndex $sel.AudioIndex -SubIndex $sel.SubIndex
        } else {
            $ok = Set-Defaults-Ffmpeg -FileInfo $fi -AudioIndex $sel.AudioIndex -SubIndex $sel.SubIndex
        }
        $sw.Stop()

        if ($ok) {
            $totalFixed++
            if ($fi.Editor -eq "mkvmerge-remux" -or $fi.Editor -eq "ffmpeg") { Write-Host ("     done in {0:0}s" -f $sw.Elapsed.TotalSeconds) -ForegroundColor DarkGray }
        }
        else { Write-Host "     WARNING: failed to update this file." -ForegroundColor Yellow; $totalSkipped++ }
    }
}

# ============================================================
#  Summary
# ============================================================
Write-Host ""
Write-Sep
Write-Host "Done. Modified $totalFixed file(s)." -ForegroundColor Green
if ($totalSkipped -gt 0) { Write-Host "Skipped $totalSkipped file(s)." -ForegroundColor Yellow }
if (-not $Ffmpeg) {
    Write-Host ""
    Write-Host "To edit mp4/mov default tracks, install ffmpeg:" -ForegroundColor DarkCyan
    Write-Host "    winget install Gyan.FFmpeg      (or  https://ffmpeg.org/download.html )" -ForegroundColor DarkCyan
    Write-Host "Then re-run this script - it will find ffmpeg automatically." -ForegroundColor DarkCyan
}
Write-Sep
Exit-Script 0
