# Receiver changes that go with this sender

The macOS sender works with an unmodified receiver, but a few things on the client side make it
noticeably better, and one of them is required for a smooth codec switch. They live here as a patch
against `luch-android` so they can be picked up (or dropped) independently of this repository.

Apply it in a clean `luch-android` checkout:

```sh
git -C luch-android apply /path/to/receiver/luch-android-receiver.patch
cd luch-android/android && ./gradlew assembleRelease
```

The patch was exported from the tree it was developed against; if upstream has moved since, `git apply
-3` or a manual merge will be needed.

## What is in it

### Device state (`DeviceState.java`, new)

Battery level, charge counter, charging, thermal status, thermal headroom, power-save mode and screen
state, cached from system callbacks — a sticky battery broadcast, screen on/off, power-save and thermal
listeners — and reported **only when they change**, never polled:

- `welcome.hw.device`: a snapshot (`battery`, `charge_mah`, `charging`, `thermal`, `power_save`,
  `interactive`, `headroom`);
- in the per-second `stats`: the same fields, appended only on change, with a 100 mAh hysteresis on the
  battery (3 percentage points when the device has no charge counter) and an immediate message when the
  cable goes in or out.

`headroom` (`PowerManager.getThermalHeadroom`, API 30+) falls before the thermal status does, so a
sender can warn before the device throttles.

### Overlay (`MirrorActivity`, `MirrorSession`)

The debug overlay (toggled by OK/Info/Menu) now shows the stream's fps, codec and size, the rendering
surface and its refresh rate, the battery, the charge in mAh, the thermal status and headroom, next to
the numbers it already had.

A separate, always-visible `🔥` badge appears in the top-right corner when headroom drops below 0.3 —
the icon only, with a localized content description (`values/strings.xml`, `values-ru/strings.xml`).

### Session lifecycle

- `MirrorSession.start` makes the new session current **before** ending the old one, and `end()` no
  longer closes the screen when a newer session has taken over;
- `MirrorActivity` is launched with `SINGLE_TOP | CLEAR_TOP`, keeps a reference to *its* session, and
  re-attaches the surface on `onNewIntent`; `onStop` only stops the session it was showing.

Together these fix a codec switch leaving the client at a black screen for seconds: the new decoder now
starts within ~114 ms of the switch instead of ~5 s.

### Geometry

- the video is letterboxed instead of stretched (`FitSurfaceView` keeps the stream's aspect ratio);
- `hw.display` reports `type` (`tv`/`phone`/`tablet`), `current` (mode with rotation applied),
  `rotation`, `refresh` and the supported `modes`, so a sender can pick a size and rate that suit the
  client's screen;
- the window asks for the panel's highest refresh rate (and the exact display mode id).

### Decoder

- `max-num-reorder-frames = 0` is tried with the other low-latency keys (dropped automatically if the
  decoder rejects it).

### Benchmark preference

`bench.prefer` is no longer the fastest decoder but the best trade-off: a compression-efficiency credit
(AV1 30, HEVC 25, VP9 20, H.264 0) minus 2 points per millisecond of measured decode time, with the
score and the formula included in the answer. A sender that cannot encode `prefer` falls back to its
own judgement.

### Protocol

`PROTOCOL.md` documents the new `hw.device` fields, the change-only `stats` fields and the weighted
`prefer`. `versionCode` is bumped so the benchmark cache is rebuilt.
