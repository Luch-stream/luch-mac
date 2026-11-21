# Luch — macOS sender

A second sender for the Luch protocol: the same receiver, the same UDP format, a different platform
underneath. It speaks v0 exactly as [PROTOCOL.md](https://github.com/Toxblh/luch-android/blob/main/PROTOCOL.md)
describes, so no change is needed on the TV side.

| Part | What it uses |
|---|---|
| Capture | ScreenCaptureKit: display, NV12 video range, cursor drawn in; the size follows the client |
| Audio | ScreenCaptureKit system audio → libopus, 48 kHz stereo, CBR 128 kbit/s, 20 ms frames |
| Video | VideoToolbox H.264 or HEVC, real time, no B-frames, IDR on request, Annex-B with SPS/PPS before every IDR |
| Discovery | DNS-SD (Bonjour); every socket is pinned to the interface the receiver was announced on |
| Control | Unix socket + JSON, the stand-in for the Linux sender's D-Bus API |

## Requirements

- macOS 14 or newer
- Swift 5.9+ (Xcode command line tools)
- libopus: `brew install opus`

## Build and run

```sh
swift build -c release
./Tools/make-app.sh          # builds Luch.app next to the package
open .build/Luch.app
```

macOS asks for **Screen Recording** and **Local Network** access on first use. The Screen Recording
grant is tied to the code signature, so an ad-hoc build needs a fresh grant after every rebuild. Pass a
stable identity to keep it:

```sh
SIGN_ID="<your code-signing identity>" ./Tools/make-app.sh
```

`swift test` runs 27 tests: header layout, shard reassembly, OpusHead, Opus frame cutting, AVCC→Annex-B,
the keepalive bounds, the codec weights and the quality presets.

## The codec

The receiver's `welcome` says which decoders it has, how fast each one measured, which size it accepts
and how its screen is shaped. The sender grades the codecs both can do and picks the best trade-off:

- **HEVC** for its bitrate at the same quality (a quarter less than H.264), **H.264** for reach;
- a codec the receiver names as its fastest gets a small time credit — not a flat bonus, so at equal
  decode times HEVC still wins on bitrate;
- a decode time **measured in a real session** outranks the receiver's own benchmark (that one drains
  into an `ImageReader` and reports the decoder core, not the path to the screen), and it is remembered
  per receiver and per codec;
- the decoder's own maximum size is the last word.

`luch caps "<receiver>"` prints the grading and the plan:

```
weights: preferms=3.0,bytes=25.0,compat=15.0,ms=2.0,base=20.0,hd60=5.0,nohd60=-25.0,lowlat=5.0
  HEVC   65.0  (5.0 ms measured)  bytes+25.0 ms+30.0 1080p60+5.0 lowlat+5.0
  H.264  42.0  (11.5 ms bench)    compat+15.0 ms+17.0 1080p60+5.0 lowlat+5.0
plan: HEVC 1662x1080@60 audio=true
```

## Size and quality

Two independent knobs:

- **Size** — whose geometry wins: `source` (the Mac's own aspect), `client` (the client's screen, the
  desktop cropped), `fit` (the Mac's aspect inside the client's pixels) or `average` (half-way). On a
  20:9 phone `fit` keeps the whole desktop, without stretching and without cutting it.
- **Quality** — a preset: `auto` (exactly what the client reports), `720p`, `1080p`, `2K`, `4K`. The
  preset picks the height, the size mode picks the aspect; a decoder that cannot do 1080p60 caps the
  stream at 30 fps, and one that cannot do 4K clamps the size proportionally.

## The client's state

`welcome.hw.device` and the per-second `stats` carry the client's battery, charging state, thermal
status and thermal headroom (`PowerManager.getThermalHeadroom`: 1.0 cool, below 0.3 throttling soon).
The sender **shows** them and never lowers the quality behind the user's back: the menu line says
`🔋 on battery` or `🌡0.62` / `🔥0.21`, and the presets above 720p get a `drains the battery faster`
note while the client runs on its own battery. The receiver reports these on change only, never by
polling.

## Use

Menu bar: pick a receiver → **Mirror Screen**. While streaming the menu shows the estimated latency
(capture + encode + one-way network + the receiver's decode), host time, RTT, the decoder's own number,
the receiver's battery and thermal headroom.

Submenus: **Warm picture** (a slider: pulls the blue chroma down and the red up in the NV12 plane before
the encoder, weighted by luma so dark UI stays neutral — for night viewing, applied live), **Quality**
(`auto/720p/1080p/2K/4K`), **Size** (`source/fit/average/client`), **Codec** (`auto/H.264/HEVC`),
**Bitrate**, **Display**, and the login item.

Without the app:

```sh
.build/debug/luchctl list
.build/debug/luchctl mirror "XGIMI MoGo 4 Laser"
.build/debug/luchctl mirror "S24+" --codec hevc --preset 1080p --size-mode fit
.build/debug/luchctl warmth 0.35      # 0...1, applied live
.build/debug/luchctl stats
.build/debug/luchctl stop
```

`luch` is the engine without the app, useful for testing and for receivers found by address:

```sh
.build/debug/luch list
.build/debug/luch caps "XGIMI MoGo 4 Laser"      # graders, plan, receiver state
.build/debug/luch hw                            # what this Mac's encoders can do
.build/debug/luch mirror "XGIMI MoGo 4 Laser" --preset 720p --size-mode source --warm 0.3
.build/debug/luch mirror --synthetic --ip 127.0.0.1   # no capture permission needed
```

`luchctl` talks to `Luch.app` over `~/Library/Application Support/Luch/control.sock`; if the app is not
running it says so instead of opening a second session.

## Test without a TV

`Tools/fakerecv.py` is the receiver's `testsend.py` in reverse: it answers hello/welcome and start/ready,
reassembles the shards, checks the header, Annex-B framing and the SPS/PPS-before-IDR rule, writes the
elementary stream and asks ffmpeg whether it decodes.

```sh
python3 Tools/fakerecv.py --seconds 20 --out .tmp/capture.h264 &
.build/debug/luch mirror --synthetic --ip 127.0.0.1 --seconds 8
```

## What works

- display mirroring with the cursor, H.264 and HEVC, a size that follows the client;
- codec choice by weighted grading, remembering what a real session measured;
- system audio (Opus, 20 ms frames), `OpusHead` before every IDR;
- VPN-safe: the control channel and both media sockets are bound to the interface the receiver was
  found on, never to the default route;
- keepalive: repeats the last access unit when the screen is still — P-frames at 2 fps, an IDR more
  slowly — so the receiver's 15 s silence timeout never fires (ScreenCaptureKit is change-driven and
  delivers ~1 fps on a still desktop);
- menu bar with receiver list, live latency, warmth, quality, size, codec, bitrate, display and login item;
- the client's battery, charging, thermal state and headroom, shown but never acted on silently;
- `luchctl` over a Unix socket.

## Not yet

- window capture (`SCContentFilter(desktopIndependentWindow:)`), planned next;
- virtual display / extend mode — no public API, would need `CGVirtualDisplay`;
- input back-channel (touch, keyboard) — reserved in PROTOCOL.md §6, not implemented on either side.

## Numbers

Apple M4 Max → Samsung S24+ over Wi-Fi, HEVC 1662×1080@60: capture + encode + send **2–5 ms**,
56–58 fps, RTT 7–10 ms, the receiver decodes in **5–11 ms**. H.264 on the same phone decodes in
**75–85 ms** live — its own benchmark says 12.7 ms, because the benchmark measures the decoder core
rather than the path to the screen. That is why the sender prefers HEVC here and why a measured decode
time outranks the benchmark.

The display adds up to a frame period on top, and is not counted: a 60 Hz panel adds about 8 ms on
average.

## Notes

- 5 ms Opus frames crackle on Android: the receiver's `AudioTrack` buffer is about four frames (20 ms),
  so Wi-Fi jitter cuts them up. 20 ms frames (50 packets per second) measured best; `--frame-ms` switches
  it at runtime.
- VideoToolbox does not always attach `kCMSampleAttachmentKey_NotSync`, so the IDR flag is taken from
  the bitstream (NAL type 5), and the parameter sets it puts in the format description are stamped in
  front of every IDR — the receiver configures its decoder without `csd-0`.
- The warm filter walks the chroma plane once per frame: well under a millisecond at 1080p, no Core
  Image and no extra buffer.
