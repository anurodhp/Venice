# Venice

**A small video player for GNUstep, on libmpv.** Venice plays local files and network streams on the GNUstep + Window Maker desktop of the Raspberry Pi 3 port of Darwin (the sibling repository [iokit](https://github.com/anurodhp/xnu-iokit-pi3)), next to [Milan](https://github.com/anurodhp/milan), [Naples](https://github.com/anurodhp/naples) and [Rome](https://github.com/anurodhp/rome). Playback is [mpv](https://mpv.io)'s, through libmpv's render API; Venice adds the window, the controls and the drawing surface.

## What you can do

- Open a file (File > Open, ⌘O), a URL (File > Open URL, ⌘U), a path or URL given on the command line (`Venice movie.mkv`), a file dropped on the video, or Open With from Milan (Venice declares video and audio types).
- Network streams: `http://`, `https://` (mbedTLS), HLS (`.m3u8`), RTMP, UDP/RTP multicast, and anything else FFmpeg's protocols and demuxers take.
- Controls on a black strip under the video, laid out like the iOS player: the **scrubber** across the whole window (it seeks to keyframes while you drag and exactly where you let go) with the elapsed time under its left end and the time left under its right ("LIVE" for a stream without a duration); **back 10 s, play/pause, forward 10 s** in the middle; and the **volume** between Naples' two speakers (the quiet one turns it down, the loud one up, or drag the track; the quiet one shows Naples' cross when muted). They are drawn by Venice as vector shapes, not theme art or font glyphs. Overlaying them on the video would need compositing on top of the GL surface, so they sit below it.
- Keys in the video: space plays and pauses, ← → seek 5 s (30 s with Shift), ↑ ↓ change the volume by 5, `m` mutes. A click on the video plays or pauses. The Playback menu has the same actions.
- The window fits itself to each new video, scaled down to the screen.
- Subtitles embedded in the file (libass).

## How fast, on a Raspberry Pi 3

Big Buck Bunny, 720p H.264 High at 30 fps and 8 Mb/s, one pass (300 frames), on a Pi 3 B with a 1920x1080 desktop, GL renderer:

| Window | Frames dropped | Drawn per frame |
|---|---|---|
| 854x480 | 9 (3%) | 29 ms |
| 1280x720 | 30 (10%) | 29 ms |

Three things on the system decide this, and an image needs all three (iokit has them):

- **The ARM clock.** The firmware keeps the cores at 600 MHz unless asked for more, and nothing in the port asks, so `config.txt` sets `force_turbo=1` (1.2 GHz). At 600 MHz FFmpeg decodes this clip at about 30 frames/s on four cores, no headroom at all, and two thirds of the frames were dropped; at 1.2 GHz it decodes at about 60.
- **MIT-SHM.** If `xlib_vc4` reports "MIT-SHM not used: shmget failed", `/etc/sysctl.conf` was not applied (no `/usr/sbin/sysctl`) and every frame goes through the X socket (41 ms instead of 3.6 to put an 854x480 frame).
- **The GPU read-back.** Each GL frame is read back from GPU memory by the CPU; the V3D driver now does that through a really cached mapping (4.1 ms for 1280x720 instead of 37.7).

The decoder is software (FFmpeg, NEON, four threads); the GPU does colour conversion, scaling and subtitles. A window opens at most 1280 wide for a video (`VeniceMaxVideoWidth`). The sw renderer is 3-5x slower than gl at every size, which is why gl is the default.

## What you cannot do (yet)

- **No hardware video decoding.** The Pi 3's H.264 decoder is on the VideoCore VPU, reached on Linux through MMAL or V4L2 over VCHIQ; this kernel has no driver for either. FFmpeg decodes in software with its NEON code on all four cores; see the table above. HEVC and VP9 above SD will drop more.
- A progressive MP4 over HTTP needs either its index at the front (`-movflags +faststart`) or a server that answers Range requests; otherwise mpv cannot reach the index and reports "Invalid data" while it plays. Real streaming servers and HLS are fine.
- No playlists, no chapter or track menus (audio/subtitle tracks are mpv's defaults), no fullscreen, no screenshots, no external subtitle files.
- The volume is mpv's own (0–100%, per player), not the system volume in Naples' menu bar.
- `https://` does not verify certificates (FFmpeg's default `tls_verify=0`; there is no CA bundle on the image).
- Building needs a Mac and the iokit toolchain. There is no prebuilt package.

## How it works

The video is a child X window of the GNUstep window, on an X connection of Venice's own (as in Rome: gnustep-back drops Expose events for windows it did not create). An `mpv_render_context` draws into it:

- **gl** (the default): a GLX context on the child window, handed to mpv's OpenGL renderer. Colour conversion, scaling, subtitles and the OSD run as shaders: on the Pi, on the VideoCore IV's 3D block through Mesa's vc4 driver (`MESA_VC4=1` libGL; GL 2.1 is what mpv's renderer needs); elsewhere on softpipe. mpv's `fast` profile keeps the shaders cheap (bilinear scaling, no dithering). The present is the GL driver's: on the Pi the frame is read back from the GPU and put on the window by the CPU (iokit's `mesa_xlib_vc4`).
- **sw** (`-VeniceRenderer sw`, and the fallback when GL cannot start): mpv's software renderer (libswscale with NEON, `sw-fast`) draws into a 32-bit image of the window, put with MIT-SHM. Rows are 64-byte aligned so mpv takes its SIMD path.

Which one is faster on the Pi depends on the size: the GL path pays a whole-frame read-back per frame, the sw path pays swscale. Measure with `VENICE_STATS=1` (per-frame draw time on stderr).

mpv's callbacks arrive on its own threads; they write a byte to a pipe that the main run loop watches, and the events and frames are handled there (work queued on the main dispatch queue does not wake GNUstep's run loop).

Audio goes to iokit's `audiod` through `libaudiohal` (the CoreAudio HAL subset), by an mpv audio output written for it (`--ao=audiohal`, in iokit's `tools/userland_staging/mpv_darwin`). It opens libaudiohal with `dlopen`, as Naples does, so an image without audio still plays video.

## Building

You need a Mac with **Xcode 12** (the iPhoneOS SDK the port is built with) and a current Xcode for its linker, and the [iokit](https://github.com/anurodhp/xnu-iokit-pi3) repository checked out next to this one (`../iokit`, or set `IOKIT_DIR`) with its toolchain, X11, Mesa and GNUstep already built. The media stack is built there once, in this order:

```sh
cd ../iokit/tools/userland_staging
./build_mbedtls.sh && ./build_ffmpeg.sh && ./build_fribidi.sh && ./build_harfbuzz.sh \
  && ./build_libass.sh && ./build_libplacebo.sh && ./build_libmpv.sh
```

(`setup_third_party.sh` fetches the sources: FFmpeg 7.1.1, mpv 0.40.0, libplacebo 7.351, libass 0.17.4, HarfBuzz 11.2.1, fribidi 1.0.16, Mbed TLS 3.6.4, all unmodified.) Then, from this directory:

```sh
./build.sh            # cross-build; Venice.app lands in iokit's libc_build/gnustep/root
./build.sh deploy     # build, then copy Venice.app and the media dylibs to the Pi
```

`deploy` uses `DEPLOY_HOST` (default `root@10.0.0.142`). For GL on the Pi's GPU the image needs the vc4 libGL (`MESA_VC4=1 build_mesa.sh`).

## Testing

On the Pi, from an ssh session while gsdm (or a session) owns the display:

```sh
DISPLAY=:0 XAUTHORITY=/var/lib/gsdm/auth-0 VENICE_STATS=1 /Applications/Venice.app/Venice -VeniceQuitAtEnd YES clip.mp4
```

`-VeniceQuitAtEnd YES` makes Venice quit at the end of the file (exit status 1 if it cannot be played) and log the codec, the size and mpv's dropped-frame counts; `VENICE_STATS=1` adds the per-frame draw time.

`tools/venice_qemu_test.sh` in iokit boots an image under QEMU and plays a clip under Xvfb. Under QEMU, a run through audiod did not finish while one with `ao=null` did (probably audiod not draining the stream under emulation without `pwm-sim=1`; not confirmed), so the script plays with `ao=null`; audio is tested on the Pi.

## Defaults

| Default | What |
|---|---|
| `VeniceRenderer` | `gl` (default) or `sw` |
| `VeniceMPVOptions` | more mpv options, `key=value,key=value` (e.g. `vd-lavc-skiploopfilter=all` to trade quality for speed on the Pi) |
| `VeniceQuitAtEnd` | `YES` quits when the file ends (scripted tests) |
| `VeniceMaxVideoWidth` | the widest the window opens for a video (default 1280; it can still be resized) |

Environment: `VENICE_DEBUG=1` prints mpv's log, `VENICE_STATS=1` the renderer's frame times, `VENICE_NOSHM=1` makes the sw renderer use `XPutImage`.

## Layout

| | |
|---|---|
| `main.m` | application, menus, Open and Open URL |
| `VeniceWindow.m` | the window: the video view and the control strip, the player's delegate |
| `VeniceControls.m` | the icon buttons, the scrubber/volume tracks and the strip they sit on |
| `VenicePlayer.m` | the mpv handle, options, observed properties, the wakeup pipe |
| `VeniceView.m` | the view that hosts the video's child window |
| `VeniceVideoGL.c`, `VeniceVideoSW.c` | the two render surfaces |
| `VeniceX.c` | Venice's X connection |
| `icons/`, `tools/make_icon.m` | the icon and its generator |

## Licence

Venice is MIT licensed. It links libmpv (LGPL-2.1+, built without its GPL parts) and FFmpeg (LGPL-3 as built, with mbedTLS), which keep their own licences.
