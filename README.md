# mkv-default-tracks

A small interactive PowerShell script for setting default audio and subtitle tracks across all MKV files in a folder — useful for cleaning up TV-show seasons where the default tracks are wrong (e.g., Russian audio plays automatically when you'd rather hear English).

> **Heads up:** this is a personal tool I built to scratch my own itch. It's public because — why not. Use it, fork it, ignore it. No promises, no support, no roadmap. 🙂

## What it does

For every `.mkv` file in a folder, it lets you pick:

- which **audio track** should play by default
- which **subtitle track** should show by default (or none at all)

It groups files by structure first, so if a folder has files with different track layouts (e.g., 25 episodes with 2 audio tracks and 1 episode with 3), it tells you about the mismatch before doing anything destructive.

The script edits MKV metadata only — no re-encoding, no re-muxing. It runs in seconds.

## Why it exists

If you download a TV-show season and find that:

- the wrong language plays by default,
- subtitles you don't want pop up automatically,
- some tracks aren't even tagged with a language,

…you'd otherwise have to fix every file by hand in MKVToolNix GUI. This script asks you once, then applies the choice to every file in the folder.

## Requirements

- **Windows** (the launcher is a `.bat` file)
- **PowerShell** (built into Windows)
- **[MKVToolNix](https://mkvtoolnix.download/)** installed

By default the script expects MKVToolNix at:

```
C:\UserProgramsFiles\mkvtoolnix\
```

If yours is elsewhere (e.g., the standard `C:\Program Files\MKVToolNix\`), open `Set-MkvDefaults.ps1` and edit these two lines near the top:

```powershell
$MkvPropEdit = "C:\UserProgramsFiles\mkvtoolnix\mkvpropedit.exe"
$MkvMerge    = "C:\UserProgramsFiles\mkvtoolnix\mkvmerge.exe"
```

## How to use

1. Download `Set-MkvDefaults.ps1` and `Run-MkvDefaults.bat` and put them in the same folder.
2. Run it one of two ways:
   - **Drag-and-drop** a season folder onto `Run-MkvDefaults.bat` — easiest, especially with non-English paths.
   - **Double-click** `Run-MkvDefaults.bat` and type/paste the folder path when prompted.
3. The script lists each audio and subtitle track. Type the number you want as default. For subtitles you can also enter `0` to mean "no default subtitle".
4. Done. The changes are applied to every file in the folder.

If the folder contains files with different structures, the script shows the differences and asks whether you want to cancel, process only the largest group, or handle each group separately.

## Notes

- Language tags on existing tracks are left alone — the script only changes the default/enabled flags.
- Tracks without a language tag are flagged in the output (`<-- LANGUAGE NOT TAGGED, check name!`) so you can identify them by their name.
- The original `set_default_audio.bat` in this repo is the older, hardcoded version (rus + eng, fixed track order). Kept around for reference. The PowerShell version supersedes it.

## License

Do whatever you want with it.
