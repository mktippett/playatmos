# PlayAtmos

A small native macOS player for MKV files with Dolby Atmos. It renders E-AC-3 JOC
(Dolby Digital Plus Atmos) objects to whatever speaker layout the Core Audio output
device has, e.g. 7.1.4 speakers driven directly by an audio interface (no AVR or HDMI
passthrough). No offline conversion: the MKV is remuxed on the fly,
segment by segment, as playback needs it.

**Status:** early prototype. Developed and tested on one Apple Silicon Mac running
macOS 26 with a 12-channel 7.1.4 output device.

```
./build.sh                 # -> build/PlayAtmos.app  (+ test tools in build/)
open build/PlayAtmos.app   # ⌘O, drag a file onto the window, or "Open With" in Finder
```

Requirements: Command Line Tools (clang) and Homebrew `ffmpeg` (the app links
`/opt/homebrew/lib/libav*.dylib`, so it is not self-contained).

Controls: AVKit's standard controls (scrubber, play/pause, full-screen button),
plus Space = play/pause, ← / → = skip 10 s, ⌃⌘F = full screen. The **Audio Output** menu
picks a device. The default is to follow the system output. The **Subtitles** menu lists
the file's subtitle tracks and any sidecar files.

## Why it is built this way

Findings from probing macOS 26.7 (`probe/` has the throwaway programs):

| Path | Result on E-AC-3 JOC |
|---|---|
| AudioToolbox `AudioConverter`/codec `ec-3` | 5.1 bed only. The decoder offers at most 8 ch LPCM. No `ec+3` (JOC) decoder is registered. |
| `AVAssetReader` → 7.1.4 LPCM | 5.1 bed only (heights silent). |
| `AVSampleBufferAudioRenderer` | 5.1 bed only. Rejects `ec+3` format descriptions (`fmt?`). |
| **`AVPlayer`** (MP4 or HLS) | **Objects rendered.** Control: the same audio re-encoded as plain 5.1 E-AC-3 leaves Lrs/Rrs and all four tops silent. |

So only AVPlayer reaches Apple's Atmos renderer, and AVPlayer can't open MKV. The
player therefore presents the MKV to AVPlayer as an HLS VOD stream of
fragmented-MP4 segments, served from `127.0.0.1`:

```
MKV ─libavformat demux─▶ Segmenter ─fMP4 segments (stream copy)─▶ HLSServer (localhost HTTP)
                                                                     │
                     7.1.4 device ◀─ Apple Atmos renderer ◀─ AVPlayer ┘
```

- **Segment boundaries** come from the MKV Cues (keyframe index), grouped into
  segments of about 6 s, so `#EXTINF` durations are exact and seeking anywhere is instant.
  For each request the segmenter seeks, collects that segment's packets, and writes
  `moof`+`mdat` itself (≈5 ms per segment). The init segment (`moov`) comes from
  libavformat's mp4 muxer, which builds `avcC`/`hvcC`/`dec3`.
- **dec3 JOC fix.** For E-AC-3 with a 7.1 bed (dependent substream), libavformat
  omits the JOC extension from `dec3`. ffmpeg's own `-c copy` to MP4 has the same
  problem. AVPlayer then plays the bed only, and height objects fold into the fronts.
  PlayAtmos appends the extension. The complexity index (object count) is not exposed by
  libavformat, so it is set to 16 (heuristic; verified to work).
- **hev1 fix.** HEVC with in-band parameter sets (`hev1`) gets a full `hvcC`,
  because AVFoundation needs one.
- **Audio track choice:** E-AC-3 JOC always wins. Otherwise lossless (TrueHD, DTS-HD MA,
  FLAC, PCM) > E-AC-3 > AC-3 > AAC.
- **Non-Apple codecs** (TrueHD, DTS, FLAC, PCM, Opus …) are decoded by libavcodec and
  re-encoded per segment to ALAC (bit-exact, sample-accurate across segment boundaries).
  These are bed-only (see below).

## Subtitles

Subtitles are drawn by the app over the video, not passed to AVPlayer, so the
audio/video path that Atmos depends on is untouched. (AVPlayer-based players usually
convert text subtitles to WebVTT inside the HLS stream and burn image subtitles into the
video; standalone players such as mpv and VLC draw their own, as PlayAtmos does.)

- A second, independent FFmpeg reader reads only the selected subtitle stream, from 15 s
  before to 30 s after the playhead, and re-seeks when you jump.
- Text: SubRip, ASS/SSA, WebVTT, mov_text, shown as plain text (white, dark outline,
  scaled to the picture). ASS styling and positioning are not reproduced.
- Images: PGS (Blu-ray), VobSub (DVD), DVB, drawn at their encoded position.
- Sidecar files next to the video with the same base name (`Movie.srt`, `Movie.en.srt`,
  `.ass`, `.ssa`, `.vtt`) appear as extra tracks.
- Off by default, except that a track flagged *forced* (foreign-dialogue lines) is turned
  on automatically.

## What has been verified (programmatically)

Each test played through the real pipeline (`build/atmostest`) to a 12-channel
[Loopback](https://rogueamoeba.com/loopback/) virtual device configured as 7.1.4,
at 3% volume. The harness captured the device's pass-through input and measured
per-channel RMS:

- A 7.1.4 channel-check clip (E-AC-3 JOC, 5.1 bed): every step lands on exactly one of
  the 12 outputs, with >80 dB separation from the rest: L, C, R, Rs, Rrs, Lrs, Ls,
  top-rear-L, top-front-L, top-front-R, top-rear-R, LFE.
- A channel-test MKV with both TrueHD Atmos and E-AC-3 JOC (7.1 bed) tracks: the E-AC-3
  track is chosen and all 12 channels come out discretely, including the four tops.
  Without the dec3 fix, the top-front-left signal plays from L.
- Two streaming-release DD+ Atmos films (5.1 bed): in one, the top channels carry program
  sound (≈ −61 dB vs −59 dB front bed). In the other, the rears are active but there was no
  overhead sound in the scenes sampled (the same when played as a plain MP4, so it's the mix).
- Seeking to arbitrary points (50 min, 75 min …): playback starts in ≈0.3 s, then runs
  in real time with no stalls over 30 s runs across segment boundaries.
- Video frames decode at the source rate (H.264 1080p, HEVC incl. `hev1`). A/V offsets are
  identical in generated segments vs the MKV.
- TrueHD 5.1 → ALAC: bit-exact vs a direct decode, no boundary discontinuities, correct
  speaker mapping (per-channel tones). DTS-HD MA 192 kHz: ≈0.33 s per 6 s segment.
- The app itself opens a file and logs `Atmos recognised by AVPlayer` (AVPlayer reports
  the `ec+3` format list). The window subtitle shows the same.
- Subtitles: SubRip cue times match `ffmpeg`'s extraction to the millisecond, including
  after large forward and backward jumps. A video frame stamped at 10.010 s is on screen
  at player time 10.013–10.017 s, so cues follow the picture. Sidecar `.srt` (UTF-8,
  italics stripped) and a PGS sample from FFmpeg's test suite decode and draw correctly.
  In the app, a forced track is auto-selected and its line appears at the right time.

## Testing on your own system

1. **Speaker placement by ear.** Play a 7.1.4 channel-check clip and confirm each physical
   speaker in turn. The automated tests check device channels, not what is wired downstream.
2. **Output device choice.** Apple renders to the device's speaker configuration. Open
   Audio MIDI Setup → *Configure Speakers…* and set the device (or aggregate device) to 7.1.4.
   A device whose channels report *unknown* labels won't get correct placement.
3. **Lip sync.** Virtual devices and multiple USB interfaces add latency that AVPlayer can
   only compensate as far as the devices report it.
4. **Automated check.** `build/atmostest play <file> <seekSec> <seconds> [volume] [deviceUID]`
   captures a Loopback-style device's pass-through. The built-in default UID is specific to
   the development machine, so pass your own (list UIDs with `system_profiler SPAudioDataType`
   or Audio MIDI Setup).

## Limitations

- **TrueHD Atmos objects are not rendered.** No Apple or libavcodec decoder handles them.
  If the MKV also has an E-AC-3 JOC track, that track is used (real Atmos). Otherwise the
  TrueHD bed plays losslessly. The open-source route to TrueHD objects would be
  [truehdd](https://forum.doom9.org/archive/index.php/t-186454.html) (decoder → Dolby
  Atmos Master Format) plus [Cavern](https://cavern.sbence.hu/cavern/downloads.php)
  (renderer). Both are separate Rust/.NET projects, not real-time libraries for a
  native player.
- Bed-only fallback is 5.1. ALAC's 8-channel layout is "7.1 wide" (front Lc/Rc), so 7.1
  rears are folded into the side surrounds. FLAC in HLS played silent in testing.
- DTS:X objects are not rendered (DTS core / MA decoded as a bed).
- No audio track menu (the best audio track is chosen automatically).
- Subtitles: ASS styling isn't rendered (plain text only; libass would be needed), and
  sidecar subtitle files must be UTF-8.
- Video: H.264, HEVC, AV1 (AV1 needs hardware support). Others are refused. Dolby
  Vision profile 5 is not handled specially.
- MKVs without Cues fall back to a fixed 6 s grid with approximate `#EXTINF`.

## Layout

- `src/Segmenter.[hm]`: demux, track choice, segment index, init/media segment writer, ALAC fallback
- `src/HLSServer.[hm]`: minimal keep-alive HTTP server on 127.0.0.1
- `src/Subtitles.[hm]`: subtitle reader/decoder and the overlay view
- `src/main.m`: AppKit app (AVPlayerView, menus, drag and drop, output device and subtitle menus).
  Test hooks: `PLAYATMOS_VOLUME`, `PLAYATMOS_SEEK=<sec>`, `PLAYATMOS_SNAPSHOT=<png>`
  (renders the subtitle overlay 3 s after start)
- `tools/atmostest.m`: `dump` segments to disk, or `play` through AVPlayer and capture
  per-channel RMS (`CAP_SERIES=1` for a 1 s time series). Pass your device UID as the
  6th argument.
- `tools/subtest.m`: list subtitle tracks, print active cues at given times, optionally
  render the overlay to a PNG
- `tools/capture.m`: capture-only meter for testing the app itself
  (`open --env PLAYATMOS_VOLUME=0.03 -a build/PlayAtmos.app file.mkv`, then `build/capture 8`)
- `probe/`: the investigation programs behind the table above

The code is Objective-C built with plain clang (no Xcode project). Most of it works
directly with FFmpeg's C API, which is simplest from C/Objective-C.

## License

GPL-3.0 (see `LICENSE`). The app links against FFmpeg's libraries; Homebrew's FFmpeg build
includes GPL components.
