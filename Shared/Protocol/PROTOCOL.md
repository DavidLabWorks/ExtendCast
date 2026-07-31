# ExtendCast Wire Protocol

All platform applications remain compatible through the same discovery names
and wire framing.

## Discovery

- TCP service: `_bettercast._tcp`
- UDP service: `_bettercast._udp`

These identifiers are retained for protocol compatibility even though the
applications are branded ExtendCast.

## Ports

- TCP video/audio stream: `51820`
- UDP chunked stream: `51821`

## TCP framing

Each message starts with a four-byte big-endian body length, followed by a
one-byte payload type and the payload:

```text
[length: UInt32] [type: UInt8] [payload]
```

- `0x01`: H.264 video
- `0x02`: AAC-LC audio
- `0x03`: UTF-8 JSON sender identity

The H.264 video payload has one fixed 25-byte header followed by AVCC-framed
NAL units:

```text
[streamId: UInt64 BE]
[sequence: UInt64 BE]
[ptsNanoseconds: UInt64 BE]
[flags: UInt8]
[naluLength: UInt32 BE] [nalu] ...
```

Flag bit `0x01` marks an IDR keyframe. A new encoder instance must use a new,
non-zero `streamId` and start its sequence at zero.

`ptsNanoseconds` is a monotonic, stream-relative capture timeline. Its first
frame starts at zero; it is not a wall-clock timestamp and receivers must not
compare it directly with their own clock. A receiver anchors the first frame
of each `streamId` to its local monotonic clock, then uses elapsed time within
that stream to estimate playback delay. Senders must re-anchor capture-clock
discontinuities so timestamps never move backward inside one stream.

Receivers prioritize interactive latency over replaying stale frames. When the
presentation timeline falls more than 500 milliseconds behind, a receiver may
discard complete packets up to the newest IDR frame, reset its decoder, and
resume from that IDR. If no newer IDR is buffered, it discards the complete
stale packets, requests a fresh IDR, and drops subsequent P-frames until that
IDR arrives. It must not resume from an arbitrary P-frame.

## Sender identity

Every TCP media connection must begin with one identity message before any
video or audio:

```json
{
  "protocolVersion": 1,
  "deviceId": "stable-device-uuid",
  "deviceName": "Studio Mac mini"
}
```

`deviceId` remains stable across reconnects. A receiver binds one media session
and one Receiving window to that ID. If the same device reconnects over another
network interface, the new connection replaces the old connection without
creating another window or changing its fullscreen state.

A TCP client that disconnects without sending a valid identity message is a
reachability probe and must not create, close, resize, or focus a Receiving
window.
