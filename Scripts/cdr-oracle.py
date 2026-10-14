#!/usr/bin/env python3
"""Round-trip Swift-encoded CDR samples through rclpy and require byte agreement outside padding.

Usage: cdr-oracle.py <corpus-dir>
The corpus holds <pkg>/<msg|srv|action>/<Name>.cdr files written by an oracle corpus
executable. Each file is deserialized with rclpy and serialized again; the result must equal
the Swift bytes except in padding. CDR leaves the content of padding unspecified, and rclpy
(Fast-CDR) leaves it uninitialized, so a byte may differ only where Swift wrote a zero pad AND
the offset is an alignment-padding position of Swift's own encoding. Those positions are
derived from the CDR alignment rules applied to the decoded message (see `padding_offsets`),
so a zero data byte that rclpy writes differently is still a failure. The encodings may differ
in length only by the trailing padding that brings one of them to a 4-byte boundary or that
the encapsulation options declare. Data bytes never differ: rclpy re-encodes the values it
decoded from the Swift bytes, so a layout bug shows up as Swift data landing in rclpy padding
(a non-zero byte that differs) or as a length mismatch.
"""
import re
import sys
from pathlib import Path

from rclpy.serialization import deserialize_message, serialize_message
from rosidl_runtime_py.utilities import get_action, get_message, get_service

PARTS = {"srv": ("Request", "Response"), "action": ("Goal", "Result", "Feedback")}

# Size, and so alignment, of the primitive field types in rosidl's Python type strings.
PRIMITIVE_SIZES = {
    "boolean": 1,
    "octet": 1,
    "char": 1,
    "int8": 1,
    "uint8": 1,
    "int16": 2,
    "uint16": 2,
    "int32": 4,
    "uint32": 4,
    "int64": 8,
    "uint64": 8,
    "float": 4,
    "double": 8,
}


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


class Layout:
    """Walks a decoded message through the XCDR1 alignment rules, recording padding offsets.

    Offsets are positions in the full encoding, so they include the 4-byte encapsulation header
    that precedes the stream the alignment is relative to.
    """

    HEADER = 4

    def __init__(self):
        self.pos = 0
        self.padding = set()

    def align(self, size):
        while self.pos % size:
            self.padding.add(self.pos + self.HEADER)
            self.pos += 1

    def primitives(self, size, count):
        if count:
            self.align(size)
            self.pos += size * count

    def string(self, value):
        self.align(4)
        self.pos += 4 + len(value.encode("utf-8")) + 1

    def sequence_header(self):
        self.align(4)
        self.pos += 4

    def items(self, element, values):
        if element in PRIMITIVE_SIZES:
            self.primitives(PRIMITIVE_SIZES[element], len(values))
        else:
            for value in values:
                self.value(element, value)

    def struct(self, value):
        """Walk a nested message. rosidl gives an empty structure one uint8 member,
        `structure_needs_at_least_one_member`, which rclpy does not list as a field."""
        fields = value.get_fields_and_field_types()
        if not fields:
            self.primitives(1, 1)
            return
        for name, nested_type in fields.items():
            self.value(nested_type, getattr(value, name))

    def value(self, field_type, value):
        sequence = re.fullmatch(r"sequence<(.+?)(?:,\s*\d+)?>", field_type)
        bounded = re.fullmatch(r"(.+)\[<=\d+\]", field_type)
        array = re.fullmatch(r"(.+)\[\d+\]", field_type)
        if sequence or bounded:
            self.sequence_header()
            self.items((sequence or bounded).group(1), value)
        elif array:
            self.items(array.group(1), value)
        elif re.fullmatch(r"string(<=\d+)?", field_type):
            self.string(value)
        elif field_type in PRIMITIVE_SIZES:
            self.primitives(PRIMITIVE_SIZES[field_type], 1)
        elif "/" in field_type:
            self.struct(value)
        else:
            raise ValueError(f"cannot derive padding for field type '{field_type}'")


def padding_offsets(msg):
    """Offsets of the alignment-padding bytes in the CDR encoding of `msg`."""
    layout = Layout()
    layout.struct(msg)
    return layout.padding


def normalize(data):
    """Drop the encapsulation padding count and the padding bytes it declares."""
    if len(data) < 4:
        return data
    padding = data[3] & 0x03
    body = data[4 : len(data) - padding] if padding else data[4:]
    return data[:2] + b"\x00\x00" + body


def mismatch(swift_bytes, ros_bytes, padding):
    """Return why the two encodings differ outside padding, or None when they agree.

    `padding` holds the alignment-padding offsets of the Swift encoding; a byte may differ only
    there, and only where Swift wrote zero.
    """
    swift, ros = normalize(swift_bytes), normalize(ros_bytes)
    short, long_ = (swift, ros) if len(swift) <= len(ros) else (ros, swift)
    tail = long_[len(short) :]
    if tail and (len(tail) >= 4 or len(long_) % 4 != 0 or (long_ is swift and any(tail))):
        return f"length {len(swift_bytes)} (swift) vs {len(ros_bytes)} (rclpy)"
    data = [i for i in range(len(short)) if swift[i] != ros[i] and not (swift[i] == 0 and i in padding)]
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
            decoded = deserialize_message(swift_bytes, resolve(pkg, kind, name))
            ros_bytes = serialize_message(decoded)
            padding = padding_offsets(decoded)
        except Exception as exc:  # noqa: BLE001 - report every failure, keep going
            print(f"FAIL {pkg}/{kind}/{name}: {exc}")
            failures += 1
            continue
        reason = mismatch(swift_bytes, ros_bytes, padding)
        if reason:
            print(f"FAIL {pkg}/{kind}/{name}: {reason}\n  swift {swift_bytes.hex()}\n  rclpy {ros_bytes.hex()}")
            failures += 1
    print(f"{len(files) - failures}/{len(files)} samples round-tripped through rclpy")
    return 1 if failures or not files else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
