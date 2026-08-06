#!/usr/bin/env python3
"""Regression check: raw AAC-LC (BetterCast wire format) needs ASC for FFmpeg.

Windows AudioDecoder historically opened AAC with no extradata, so
avcodec_send_packet failed on every packet and playback was silent.

Requires: pip install av
"""

from __future__ import annotations

import array
import math
import sys

try:
    import av
except ImportError:
    print("SKIP: PyAV (av) not installed")
    sys.exit(0)


def make_tone_frame(sample_rate: int = 48000, seconds: float = 0.25):
    n = int(sample_rate * seconds)
    left = array.array(
        "f",
        (0.2 * math.sin(2 * math.pi * 440 * i / sample_rate) for i in range(n)),
    )
    right = array.array(
        "f",
        (0.2 * math.sin(2 * math.pi * 554 * i / sample_rate) for i in range(n)),
    )
    frame = av.AudioFrame(format="fltp", layout="stereo", samples=n)
    frame.sample_rate = sample_rate
    frame.planes[0].update(left.tobytes())
    frame.planes[1].update(right.tobytes())
    return frame


def encode_raw_aac(frame) -> tuple[list[bytes], bytes]:
    codec = av.CodecContext.create("aac", "w")
    codec.sample_rate = frame.sample_rate
    codec.layout = "stereo"
    codec.format = "fltp"
    codec.bit_rate = 128_000
    codec.open()
    packets = [bytes(p) for p in codec.encode(frame)]
    packets += [bytes(p) for p in codec.encode(None)]
    extradata = bytes(codec.extradata) if codec.extradata else b""
    return packets, extradata


def decode_count(packets: list[bytes], extradata: bytes | None) -> int:
    dec = av.CodecContext.create("aac", "r")
    if extradata is not None:
        dec.extradata = extradata
    dec.open()
    frames = 0
    for data in packets:
        if len(data) < 10:
            continue
        try:
            frames += len(dec.decode(av.Packet(data)))
        except Exception:
            pass
    try:
        frames += len(list(dec.decode(None)))
    except Exception:
        pass
    return frames


def main() -> int:
    packets, encoder_asc = encode_raw_aac(make_tone_frame())
    # Same ASC Windows AudioDecoder now installs for 48 kHz stereo AAC-LC.
    windows_asc = bytes([0x11, 0x90])

    without = decode_count(packets, None)
    with_asc = decode_count(packets, windows_asc)

    print(f"packets={len(packets)} encoder_asc={encoder_asc.hex()}")
    print(f"NO_ASC frames={without}")
    print(f"ASC_11_90 frames={with_asc}")

    if without != 0:
        print("UNEXPECTED: raw AAC decoded without ASC (environment-specific?)")
        return 1
    if with_asc == 0:
        print("FAIL: ASC 0x11 0x90 did not decode raw AAC-LC 48k stereo")
        return 1

    print("OK: ASC required; Windows AudioDecoder ASC fix is valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
