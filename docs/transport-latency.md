# Transport freshness and latency tracing

Tablet Bridge treats the Mac-to-tablet path as a freshness-first monitor
pipeline. The current production path keeps the existing HEVC/H.264 stream
format for older clients and enables extra trace fields only after the Android
client advertises support.

## Mac sender boundary

The host admits no more than three encoded frames and 8 MiB of frame payload
inside the `NWConnection` send window. Admission happens before a frame task is
placed on the frame queue. When the estimate says the window is full,
ScreenCaptureKit capture opportunities are skipped before VideoToolbox encode.

If an already encoded frame encounters a hard admission or send failure, the
host enters a sync-frame gate and requests a fresh IDR. It never intentionally
continues an HEVC/H.264 dependency chain after dropping an encoded P-frame.

Runtime host logs report:

- in-flight frame count and bytes;
- pre-encode and send-admission drops;
- capture→encode, capture→send-enqueue, and capture→send-completion percentiles;
- `NWConnection.send` completion latency percentiles (p50/p95/p99/max).

The log line is emitted through unified logging. The compatibility
`/tmp/tabletbridge.log` file is written by a bounded asynchronous writer, so the
touch/control path does not open or write a file per packet.

## Cross-device frame trace

New Android clients advertise frame-trace support before the existing metadata
capability. The host then sends a trace frame containing:

```text
[type 14][encoded size: 4 BE][flags: 1][frame id: 8 BE]
[host capture uptime: 8 BE][encoded bytes]
```

The dedicated control channel adds an acknowledged clock-sync capability. The
host returns the four NTP-style timestamps needed for an Android-side offset
estimate: Android send, Mac receive, Mac send, Android receive. High-RTT and
offset outliers are rejected by a bounded rolling estimator. New clients also
advertise the same capability on the video socket; if the optional control
socket closes during startup, the host acknowledges that fallback and returns
the extended pong there without changing the legacy stream format.

Android translates host capture uptime into its own monotonic domain and keeps
codec PTS separate, so decoder latency remains input-queue→output while the
trace reports capture→receive, receive→queue, queue→output, output→render, and
capture→visible. Android logs a bounded p50/p95/p99/max visible-latency window.

Legacy clients continue to receive the existing type-6 metadata or type-0
frame format. Extended pongs are enabled only after the client sees the
corresponding one-byte capability acknowledgement, on either socket.

## Touch hot path

Parsed control touch events now go directly to a serial user-interactive Mac
input queue. Gesture state, long-press scheduling, momentum scrolling, and
`CGEvent` posting stay ordered there; only settings/permission status updates
hop to the main actor. Accessibility state and virtual-display bounds are
cached outside the per-event path, and diagnostics use unified logging plus the
bounded asynchronous writer.

The runtime diagnostic samples the parser→input-queue and parser→CGEvent path
while preserving input order. Android retains its persistent ordered touch
executor and the control channel remains separate from bulk video.

## Cadence and quality controls

Adaptive capture treats direct touch, drag, scroll, and mouse movement over the
captured virtual display as a stable 60-FPS wake window. Mouse movement on the
Mac's other displays is ignored. It does not promote every pointer sample to
120 FPS; 120-FPS capture is reserved for Gaming Boost or screen content that
passes the high-cadence probe. This avoids a visible 120→30→120 cadence
sawtooth during ordinary tablet interaction.

When idle-sleep is enabled, the host retains the latest captured pixel buffer
before the idle-frame gate. A new client therefore receives a forced keyframe
even if the desktop has not changed while capture was paused; a static desktop
must not leave the tablet black until the next mouse movement.

The validated 10-bit/Main10 experiment is automatically capped at 60 FPS on
this target. Its 120-FPS request did not produce a usable HEVC stream, while
10-bit at 60 FPS stayed live with bounded latency; 8-bit/Main remains the
120-FPS path.

The bounded encoder presets are the production quality control. A saved
`SideScreen_exp_bitrate` value is an intentional experiment override and takes
precedence over both the Mac bitrate slider and the quality picker. Delete that
override before judging UI quality changes:

```bash
defaults delete dev.tabletbridge.host SideScreen_exp_bitrate
```

The live trace should be judged separately from picture quality: host
`capture→send` measures transport admission, while Android
`capture→visible` includes decode and presentation.

The VideoToolbox session selects hardware low-latency rate control and speed
priority for the interactive path. This keeps encoder admission bounded during
60-FPS motion; the trace, not the configured bitrate alone, is the acceptance
check.

## Validation

Run the local macOS and Android tests, then verify the installed bundles on the
target Mac/tablet. The acceptance boundary is live evidence: a connected
session should show bounded host in-flight counters, clock-sync samples, trace
frame IDs, and no sustained decoder input-buffer timeout cascade under normal
USB motion.
