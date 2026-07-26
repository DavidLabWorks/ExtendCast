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
