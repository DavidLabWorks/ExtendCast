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
