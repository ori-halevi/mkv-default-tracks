# mkv-default-tracks

A small interactive PowerShell tool for setting the default audio and subtitle tracks across all video files in a folder — useful for cleaning up TV-show seasons where the wrong track plays by default (e.g., Russian audio plays automatically when you'd rather hear English). It now also handles **MP4 / MOV** files and shows **basic media info** (resolution, codec, bitrate, …) for every file.

> **Heads up:** this is a personal tool I built to scratch my own itch. It's public because — why not. Use it, fork it, ignore it. No promises, no support, no roadmap. 🙂

## What it does

For every video file in a folder (or a single file), it:

* shows **basic info per file** — resolution (e.g. `1080p`), video codec (H.264 / H.265…), bitrate, file size, duration, and an audio-track summary;
* lets you pick which **audio track** should play by default;
* lets you pick which **subtitle track** should show by default (or none at all).

It groups files by track layout first, so if a folder mixes structures (e.g. 25 episodes with 2 audio tracks and 1 episode with 3), it tells you about the mismatch before changing anything.

No re-encoding ever happens, and nothing is rewritten unless it truly has to be:

* **Matroska** (`.mkv .mka .mks .webm`) — `mkvpropedit` flips the flag **in place**: instant.
* **MP4 / MOV** (`.mp4 .m4v .mov`) — in an MP4 the "default audio" is just one bit (the track's *enabled* flag) inside the small file header, so the script flips that bit **directly in place**. **Instant, nothing is rewritten** (the multi-GB media data is never touched), the file stays `.mp4`, and it's just as fast on a slow drive as on an SSD. *(If a file's structure is ever unexpected, it automatically falls back to the lossless remux below — never guesses.)*
* **MPEG-TS** (`.ts .m2ts`) — these have no such header, so they're **remuxed losslessly into a fresh `.mkv` with `mkvmerge`** (copy speed, `-c copy`, no re-encode); the original is replaced after the `.mkv` is written successfully.
* **Other containers** (`.avi .wmv .mpg …`) — info is shown, but default-track editing isn't supported for them.

## Supported actions by format

| Container                   | Show info | Set default tracks | How                                |
|-----------------------------|:---------:|:------------------:|------------------------------------|
| `.mkv .mka .mks .webm`      |    ✅     |         ✅         | `mkvpropedit`, in place — instant   |
| `.mp4 .m4v .mov`            |    ✅     |         ✅         | flag flipped in place — instant     |
| `.ts .m2ts`                 |    ✅     |         ✅         | `mkvmerge` lossless remux → `.mkv`  |
| `.avi .wmv .mpg .mpeg .flv` |    ✅     |         —          | —                                  |

## Requirements

* **Windows** + **PowerShell** (built in).
* [**MKVToolNix**](https://mkvtoolnix.download/) — provides `mkvmerge` (reads/remuxes everything, incl. MP4) and `mkvpropedit` (edits Matroska in place). **A recent version is strongly recommended** — old versions (e.g. v30) rewrite the `.mkv` header instead of a quick in-place flag change, which is slower and can hurt playback on slow drives. The script warns you if yours is old.
* [**ffmpeg**](https://ffmpeg.org/) — **optional**: `ffprobe` gives richer info (bitrate, HDR, bit depth), and `ffmpeg` is the fallback editor for MP4 if `mkvmerge` is missing. Install with `winget install Gyan.FFmpeg`.

With MKVToolNix alone you can read **and** edit everything (MP4 included). ffmpeg just adds richer info and an alternate MP4 path.

### Tool locations are auto-detected

The script looks for the tools on your `PATH` and in the common install folders automatically. Whatever it finds is remembered in a local `media-defaults.config.json` next to the script, so subsequent runs are instant. If ffmpeg isn't found, the script offers to let you paste its path once (handy for portable builds) and remembers it.

You can also point it explicitly:

```powershell
.\Set-MkvDefaults.ps1 -MkvToolNixDir "C:\Program Files\MKVToolNix" -FfmpegDir "C:\ffmpeg\bin"
```

## How to use

1. Put `Set-MkvDefaults.ps1` and `Run-MkvDefaults.bat` in the same folder.
2. Run it one of two ways:
   * **Drag-and-drop** a season folder — or a single video file — onto `Run-MkvDefaults.bat` (easiest, especially with non-English paths).
   * **Double-click** `Run-MkvDefaults.bat` and type/paste the path when prompted.
3. The script prints each file's info, then lists the audio and subtitle tracks. Type the number you want as default. For subtitles, enter `0` for "no default subtitle".
4. Done. The choice is applied to every file in the group.

Extra options:

```powershell
.\Set-MkvDefaults.ps1 -Path "D:\Shows\Some Season" -Recurse   # also scan sub-folders
```

## Notes

* Language tags on existing tracks are left alone — only the default/enabled flags change.
* Tracks without a language tag are flagged (`<-- LANGUAGE NOT TAGGED, check name!`) so you can identify them by name.
* `media-defaults.config.json` holds machine-specific tool paths and is git-ignored.

## License

Do whatever you want with it.
