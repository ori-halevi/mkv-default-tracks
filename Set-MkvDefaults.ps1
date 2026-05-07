# ============================================================
#  Set-MkvDefaults.ps1
#  Interactive tool to set default audio/subtitle tracks
#  for all MKV files in a season folder.
# ============================================================

param(
    [string]$Folder = ""
)

# --- Configuration ---
$MkvPropEdit = "C:\UserProgramsFiles\mkvtoolnix\mkvpropedit.exe"
$MkvMerge    = "C:\UserProgramsFiles\mkvtoolnix\mkvmerge.exe"

# Force UTF-8 everywhere so Hebrew/Polish/etc. display and read correctly
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
chcp 65001 > $null

# --- Helper: print a separator line ---
function Write-Sep { Write-Host ("-" * 70) -ForegroundColor DarkGray }

# --- Verify tools exist ---
if (-not (Test-Path -LiteralPath $MkvPropEdit)) {
    Write-Host "ERROR: mkvpropedit not found at $MkvPropEdit" -ForegroundColor Red
    Read-Host "Press Enter to exit"; exit 1
}
if (-not (Test-Path -LiteralPath $MkvMerge)) {
    Write-Host "ERROR: mkvmerge not found at $MkvMerge" -ForegroundColor Red
    Read-Host "Press Enter to exit"; exit 1
}

# --- Get folder from user (if not passed as argument) ---
if ([string]::IsNullOrWhiteSpace($Folder)) {
    Write-Host ""
    Write-Host "TIP: You can also drag-and-drop the folder onto this window," -ForegroundColor DarkCyan
    Write-Host "     then press Enter." -ForegroundColor DarkCyan
    Write-Host ""
    $Folder = Read-Host "Enter full path to season folder"
}

# Clean up the path - remove quotes and trim whitespace
$Folder = $Folder.Trim()
$Folder = $Folder.Trim('"').Trim("'").Trim()
# Strip RTL/LTR/embedding marks that often sneak in when copying Hebrew paths
$Folder = $Folder -replace "[\u200E\u200F\u202A\u202B\u202C\u202D\u202E]", ""
$Folder = $Folder.Trim()

Write-Host ""
Write-Host "Path received: $Folder" -ForegroundColor DarkGray

# Test the path - use -LiteralPath which handles special characters better
if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
    Write-Host ""
    Write-Host "ERROR: Folder does not exist: $Folder" -ForegroundColor Red
    Write-Host ""

    # Try to help diagnose: list parent folder contents
    try {
        $parent = Split-Path -LiteralPath $Folder -Parent
        if (Test-Path -LiteralPath $parent -PathType Container) {
            Write-Host "Parent folder DOES exist: $parent" -ForegroundColor Yellow
            Write-Host "Folders inside it:" -ForegroundColor Yellow
            Get-ChildItem -LiteralPath $parent -Directory | ForEach-Object {
                Write-Host "   - $($_.Name)" -ForegroundColor DarkYellow
            }
            Write-Host ""
            Write-Host "Tip: try copying one of the names above EXACTLY," -ForegroundColor Cyan
            Write-Host "     or drag-and-drop the folder onto this window." -ForegroundColor Cyan
        } else {
            Write-Host "Parent folder also doesn't exist: $parent" -ForegroundColor Red
        }
    } catch {
        Write-Host "Could not analyze parent folder." -ForegroundColor DarkRed
    }

    Read-Host "Press Enter to exit"; exit 1
}

# --- Find all MKV files ---
$files = Get-ChildItem -LiteralPath $Folder -Filter *.mkv -File
if ($files.Count -eq 0) {
    Write-Host "No .mkv files found in folder." -ForegroundColor Yellow
    Read-Host "Press Enter to exit"; exit 0
}

Write-Host ""
Write-Host "Found $($files.Count) MKV file(s)." -ForegroundColor Green
Write-Host "Analyzing..." -ForegroundColor Cyan
Write-Host ""

# --- Analyze each file using mkvmerge --identify (JSON output) ---
$fileInfos = @()
foreach ($f in $files) {
    try {
        $json = & $MkvMerge -J $f.FullName 2>$null | Out-String
        $info = $json | ConvertFrom-Json
    } catch {
        Write-Host "ERROR: Could not read $($f.Name)" -ForegroundColor Red
        continue
    }

    $audioTracks = @()
    $subTracks   = @()
    foreach ($t in $info.tracks) {
        $entry = [PSCustomObject]@{
            Id       = $t.id
            Type     = $t.type
            Codec    = $t.codec
            Language = if ($t.properties.language) { $t.properties.language } else { "und" }
            Name     = if ($t.properties.track_name) { $t.properties.track_name } else { "" }
            Default  = [bool]$t.properties.default_track
            Enabled  = if ($null -ne $t.properties.enabled_track) { [bool]$t.properties.enabled_track } else { $true }
        }
        if ($t.type -eq "audio")     { $audioTracks += $entry }
        elseif ($t.type -eq "subtitles") { $subTracks  += $entry }
    }

    $fileInfos += [PSCustomObject]@{
        File     = $f
        Audio    = $audioTracks
        Subs     = $subTracks
    }
}

# --- Build "signature" of each file to compare structures ---
function Get-Signature($info) {
    $aSig = ($info.Audio | ForEach-Object { "$($_.Language)|$($_.Codec)|$($_.Name)" }) -join " // "
    $sSig = ($info.Subs  | ForEach-Object { "$($_.Language)|$($_.Codec)|$($_.Name)" }) -join " // "
    "AUDIO[$($info.Audio.Count)]: $aSig ;; SUBS[$($info.Subs.Count)]: $sSig"
}

$groups = $fileInfos | Group-Object { Get-Signature $_ }

# --- If files differ, show conflicts and ask what to do ---
if ($groups.Count -gt 1) {
    Write-Host "WARNING: Files in this folder have DIFFERENT track structures!" -ForegroundColor Yellow
    Write-Sep
    $idx = 1
    foreach ($g in $groups) {
        Write-Host ""
        Write-Host "== Group $idx ($($g.Count) file(s)) ==" -ForegroundColor Yellow
        Write-Host "Audio tracks:" -ForegroundColor Cyan
        $sample = $g.Group[0]
        foreach ($a in $sample.Audio) {
            Write-Host ("   [id=$($a.Id)] lang=$($a.Language)  codec=$($a.Codec)  name='$($a.Name)'")
        }
        Write-Host "Subtitle tracks:" -ForegroundColor Cyan
        if ($sample.Subs.Count -eq 0) {
            Write-Host "   (none)"
        } else {
            foreach ($s in $sample.Subs) {
                Write-Host ("   [id=$($s.Id)] lang=$($s.Language)  codec=$($s.Codec)  name='$($s.Name)'")
            }
        }
        Write-Host "Files in this group:" -ForegroundColor DarkCyan
        foreach ($x in $g.Group) { Write-Host ("   - " + $x.File.Name) }
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
        "1" { Write-Host "Cancelled." -ForegroundColor Yellow; Read-Host "Press Enter to exit"; exit 0 }
        "2" {
            $largest = $groups | Sort-Object Count -Descending | Select-Object -First 1
            $fileInfos = $largest.Group
            $groupsToProcess = @($largest)
        }
        "3" {
            $groupsToProcess = $groups
        }
        default { Write-Host "Invalid choice. Cancelled." -ForegroundColor Red; Read-Host "Press Enter to exit"; exit 0 }
    }
} else {
    $groupsToProcess = $groups
}

# --- Function: ask user which audio/sub tracks should be default for a group ---
function Select-Defaults($group) {
    $sample = $group.Group[0]

    Write-Host ""
    Write-Sep
    Write-Host "Configuring $($group.Count) file(s):" -ForegroundColor Green
    foreach ($x in $group.Group | Select-Object -First 3) {
        Write-Host "   - $($x.File.Name)" -ForegroundColor DarkGray
    }
    if ($group.Count -gt 3) { Write-Host "   ... and $($group.Count - 3) more" -ForegroundColor DarkGray }
    Write-Sep

    # --- AUDIO ---
    Write-Host ""
    Write-Host "AUDIO TRACKS:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $sample.Audio.Count; $i++) {
        $a = $sample.Audio[$i]
        $langDisplay = $a.Language
        $note = ""
        if ($a.Language -eq "und" -or [string]::IsNullOrWhiteSpace($a.Language)) {
            $note = "  <-- LANGUAGE NOT TAGGED, check name!"
            $langDisplay = "und (unknown)"
        }
        $defMark = if ($a.Default) { " [currently default]" } else { "" }
        Write-Host ("  {0}. lang={1}  codec={2}  name='{3}'{4}{5}" -f ($i+1), $langDisplay, $a.Codec, $a.Name, $defMark, $note) -ForegroundColor White
    }
    Write-Host ""
    $audioChoice = Read-Host "Which audio track should be DEFAULT? (1-$($sample.Audio.Count))"
    $audioIdx = [int]$audioChoice - 1
    if ($audioIdx -lt 0 -or $audioIdx -ge $sample.Audio.Count) {
        Write-Host "Invalid choice." -ForegroundColor Red
        return $null
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
                $note = "  <-- LANGUAGE NOT TAGGED, check name!"
                $langDisplay = "und (unknown)"
            }
            $defMark = if ($s.Default) { " [currently default]" } else { "" }
            Write-Host ("  {0}. lang={1}  codec={2}  name='{3}'{4}{5}" -f ($i+1), $langDisplay, $s.Codec, $s.Name, $defMark, $note) -ForegroundColor White
        }
        Write-Host "  0. NO default subtitles (don't show subs automatically)" -ForegroundColor Gray
        Write-Host ""
        $subChoice = Read-Host "Which subtitle should be DEFAULT? (0 for none, 1-$($sample.Subs.Count))"
        $subIdx = [int]$subChoice - 1
        if ($subIdx -lt -1 -or $subIdx -ge $sample.Subs.Count) {
            Write-Host "Invalid choice." -ForegroundColor Red
            return $null
        }
    } else {
        Write-Host ""
        Write-Host "(No subtitle tracks in these files)" -ForegroundColor DarkGray
    }

    return [PSCustomObject]@{
        AudioIndex = $audioIdx
        SubIndex   = $subIdx
    }
}

# --- Process each group ---
$totalFixed = 0
foreach ($g in $groupsToProcess) {
    $sel = Select-Defaults $g
    if ($null -eq $sel) {
        Write-Host "Skipping this group." -ForegroundColor Yellow
        continue
    }

    Write-Host ""
    Write-Host "Applying changes..." -ForegroundColor Green

    foreach ($fi in $g.Group) {
        Write-Host "  -> $($fi.File.Name)" -ForegroundColor White

        $args = @($fi.File.FullName)

        for ($i = 0; $i -lt $fi.Audio.Count; $i++) {
            $args += "--edit"
            $args += "track:a$($i+1)"
            $args += "--set"
            $args += "flag-enabled=1"
            $isDefault = ($i -eq $sel.AudioIndex)
            $args += "--set"
            $args += "flag-default=$([int]$isDefault)"
        }

        for ($i = 0; $i -lt $fi.Subs.Count; $i++) {
            $args += "--edit"
            $args += "track:s$($i+1)"
            $args += "--set"
            $args += "flag-enabled=1"
            $isDefault = ($i -eq $sel.SubIndex)
            $args += "--set"
            $args += "flag-default=$([int]$isDefault)"
        }

        & $MkvPropEdit @args | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $totalFixed++
        } else {
            Write-Host "     WARNING: mkvpropedit returned exit code $LASTEXITCODE" -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Sep
Write-Host "Done. Modified $totalFixed file(s)." -ForegroundColor Green
Write-Sep
Read-Host "Press Enter to exit"
