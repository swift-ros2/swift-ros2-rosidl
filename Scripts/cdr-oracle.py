#!/usr/bin/env python3
"""Round-trip Swift-encoded CDR samples through rclpy and require identical bytes.

Usage: cdr-oracle.py <corpus-dir>
The corpus holds <pkg>/<msg|srv|action>/<Name>.cdr files written by an oracle corpus
executable. Each file is deserialized with rclpy and serialized again; the result must equal
the Swift bytes except in padding. CDR leaves the content of padding unspecified, and rclpy
(Fast-CDR) leaves it uninitialized, so a byte may differ only where Swift wrote a zero pad, and
the encodings may differ in length only by the trailing padding that brings one of them to a
4-byte boundary or that the encapsulation options declare. Data bytes never differ: rclpy
re-encodes the values it decoded from the Swift bytes, so a layout bug shows up as Swift data
landing in rclpy padding (a non-zero byte that differs) or as a length mismatch.
"""
import sys
from pathlib import Path

from rclpy.serialization import deserialize_message, serialize_message
from rosidl_runtime_py.utilities import get_action, get_message, get_service

PARTS = {"srv": ("Request", "Response"), "action": ("Goal", "Result", "Feedback")}


def resolve(pkg, kind, name):
    if kind == "msg":
        return get_message(f"{pkg}/msg/{name}")
    for part in PARTS[kind]:
        if name.endswith("_" + part):
            base = name[: -len(part) - 1]
            if kind == "srv":
                return getattr(get_service(f"{pkg}/srv/{base}"), part)
            return getattr(get_action(f"{pkg}/action/{base}"), part)
    raise ValueError(f"unrecognised sample {pkg}/{kind}/{name}")


def normalize(data):
    """Drop the encapsulation padding count and the padding bytes it declares."""
    if len(data) < 4:
        return data
    padding = data[3] & 0x03
    body = data[4 : len(data) - padding] if padding else data[4:]
    return data[:2] + b"\x00\x00" + body


def mismatch(swift_bytes, ros_bytes):
    """Return why the two encodings differ outside padding, or None when they agree."""
    swift, ros = normalize(swift_bytes), normalize(ros_bytes)
    short, long_ = (swift, ros) if len(swift) <= len(ros) else (ros, swift)
    tail = long_[len(short) :]
    if tail and (len(tail) >= 4 or len(long_) % 4 != 0 or (long_ is swift and any(tail))):
        return f"length {len(swift_bytes)} (swift) vs {len(ros_bytes)} (rclpy)"
    data = [i for i in range(len(short)) if swift[i] != ros[i] and swift[i] != 0]
    if data:
        return f"bytes differ at offsets {data[:16]}"
    return None


def main(root):
    files = sorted(Path(root).rglob("*.cdr"))
    failures = 0
    for path in files:
        pkg, kind, name = path.parent.parent.name, path.parent.name, path.stem
        swift_bytes = path.read_bytes()
        try:
            ros_bytes = serialize_message(deserialize_message(swift_bytes, resolve(pkg, kind, name)))
        except Exception as exc:  # noqa: BLE001 - report every failure, keep going
            print(f"FAIL {pkg}/{kind}/{name}: {exc}")
            failures += 1
            continue
        reason = mismatch(swift_bytes, ros_bytes)
        if reason:
            print(f"FAIL {pkg}/{kind}/{name}: {reason}\n  swift {swift_bytes.hex()}\n  rclpy {ros_bytes.hex()}")
            failures += 1
    print(f"{len(files) - failures}/{len(files)} samples round-tripped through rclpy")
    return 1 if failures or not files else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
