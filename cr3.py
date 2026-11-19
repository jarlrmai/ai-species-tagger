"""Minimal Canon CR3 reader: full-size embedded JPEG, orientation and AF points.

CR3 is an ISO-BMFF container. What we need lives in:
  moov/uuid(85c0b687-...)/CMT1  TIFF IFD0 (Orientation, Make, Model)
  moov/uuid(85c0b687-...)/CMT3  TIFF of Canon maker notes (AFInfo2 = tag 0x0026)
  moov/trak[0]                 full-size JPEG (one sample; offset in co64/stco, size in stsz)

Only standard-library code: no ExifTool or LibRaw needed.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass
from pathlib import Path

CANON_UUID = bytes.fromhex("85c0b687820f11e08111f4ce462b6a48")
CONTAINERS = {b"moov", b"trak", b"mdia", b"minf", b"stbl"}


@dataclass
class AFPoint:
    x: int  # centre, pixels from the left of the AF image
    y: int  # centre, pixels from the top of the AF image
    w: int
    h: int
    in_focus: bool
    selected: bool


@dataclass
class AFInfo:
    area_mode: int
    image_width: int  # AFImageWidth: the coordinate space the points use
    image_height: int
    points: list[AFPoint]

    def focus_points(self) -> list[AFPoint]:
        """Points that achieved focus, else the selected points, else nothing."""
        return [p for p in self.points if p.in_focus] or [p for p in self.points if p.selected]


@dataclass
class CR3Data:
    jpeg: bytes
    orientation: int  # EXIF orientation, 1 = normal
    make: str | None
    model: str | None
    af: AFInfo | None
    date_taken: str | None = None  # EXIF DateTimeOriginal, "YYYY:MM:DD HH:MM:SS"


def _boxes(data: bytes, start: int, end: int):
    """Yield (type, payload_start, box_end) for each box in data[start:end]."""
    pos = start
    while pos + 8 <= end:
        size, btype = struct.unpack_from(">I4s", data, pos)
        header = 8
        if size == 1:
            size = struct.unpack_from(">Q", data, pos + 8)[0]
            header = 16
        elif size == 0:
            size = end - pos
        if size < header:
            break
        yield btype, pos + header, pos + size
        pos += size


def _find_moov(f) -> bytes:
    """Read top-level boxes until moov; return its payload (moov is small, the image data is not)."""
    f.seek(0)
    while True:
        head = f.read(8)
        if len(head) < 8:
            raise ValueError("No moov box: not a CR3 file?")
        size, btype = struct.unpack(">I4s", head)
        header = 8
        if size == 1:
            size = struct.unpack(">Q", f.read(8))[0]
            header = 16
        if btype == b"moov":
            return f.read(size - header)
        if size == 0:
            raise ValueError("No moov box: not a CR3 file?")
        f.seek(size - header, 1)


# ---------------------------------------------------------------- TIFF helpers

def _tiff_ifd0(tiff: bytes) -> tuple[str, dict[int, tuple[int, int, int]]]:
    """Return (endian, {tag: (type, count, value_or_offset_pos)}) for IFD0 of a TIFF blob."""
    endian = "<" if tiff[:2] == b"II" else ">"
    ifd = struct.unpack_from(endian + "I", tiff, 4)[0]
    count = struct.unpack_from(endian + "H", tiff, ifd)[0]
    entries = {}
    for i in range(count):
        e = ifd + 2 + 12 * i
        tag, typ, n = struct.unpack_from(endian + "HHI", tiff, e)
        entries[tag] = (typ, n, e + 8)
    return endian, entries


_TYPE_SIZE = {1: 1, 2: 1, 3: 2, 4: 4, 7: 1, 8: 2, 9: 4}


def _tiff_value_bytes(tiff: bytes, endian: str, entry: tuple[int, int, int]) -> bytes:
    typ, n, pos = entry
    length = _TYPE_SIZE.get(typ, 1) * n
    if length > 4:
        pos = struct.unpack_from(endian + "I", tiff, pos)[0]
    return tiff[pos:pos + length]


def _tiff_string(tiff, endian, entries, tag) -> str | None:
    if tag not in entries:
        return None
    return _tiff_value_bytes(tiff, endian, entries[tag]).split(b"\0")[0].decode("ascii", "replace").strip()


# ---------------------------------------------------------------- AFInfo2

def _parse_afinfo2(tiff: bytes) -> AFInfo | None:
    endian, entries = _tiff_ifd0(tiff)
    if 0x0026 not in entries:
        return None
    raw = _tiff_value_bytes(tiff, endian, entries[0x0026])
    v = struct.unpack(f"{endian}{len(raw) // 2}h", raw)
    # Layout (int16): size, AFAreaMode, NumAFPoints, ValidAFPoints, CanonImageWidth,
    # CanonImageHeight, AFImageWidth, AFImageHeight, then per-point arrays of n:
    # widths, heights, x positions, y positions, then in-focus and selected bitmasks.
    area_mode, n, valid = v[1], v[2], v[3]
    af_w, af_h = v[6], v[7]
    if n <= 0 or af_w <= 0 or af_h <= 0:
        return None
    words = (n + 15) // 16
    base = 8
    widths = v[base:base + n]
    heights = v[base + n:base + 2 * n]
    xs = v[base + 2 * n:base + 3 * n]
    ys = v[base + 3 * n:base + 4 * n]
    focus_bits = [w & 0xFFFF for w in v[base + 4 * n:base + 4 * n + words]]
    sel_bits = [w & 0xFFFF for w in v[base + 4 * n + words:base + 4 * n + 2 * words]]

    def bit(bits, i):
        return bool(i // 16 < len(bits) and bits[i // 16] >> (i % 16) & 1)

    points = []
    for i in range(min(valid, n)):
        if widths[i] <= 0 or heights[i] <= 0:
            continue
        # Positions are relative to the image centre. On the R5, +Y is UP
        # (verified against an Eye Detection AF frame), so flip it for pixel rows.
        points.append(AFPoint(
            x=af_w // 2 + xs[i],
            y=af_h // 2 - ys[i],
            w=widths[i],
            h=heights[i],
            in_focus=bit(focus_bits, i),
            selected=bit(sel_bits, i),
        ))
    return AFInfo(area_mode=area_mode, image_width=af_w, image_height=af_h, points=points)


# ---------------------------------------------------------------- public API

def read_cr3(path: str | Path) -> CR3Data:
    with open(path, "rb") as f:
        moov = _find_moov(f)

        cmt: dict[bytes, bytes] = {}
        tracks: list[tuple[int, int]] = []  # (offset, size) of each trak's first sample

        def walk(start, end):
            for btype, p0, p1 in _boxes(moov, start, end):
                if btype == b"uuid" and moov[p0:p0 + 16] == CANON_UUID:
                    for ctype, c0, c1 in _boxes(moov, p0 + 16, p1):
                        if ctype.startswith(b"CMT"):
                            cmt[ctype] = moov[c0:c1]
                elif btype == b"trak":
                    info = {}
                    _walk_trak(p0, p1, info)
                    if "offset" in info and "size" in info:
                        tracks.append((info["offset"], info["size"]))
                elif btype in CONTAINERS:
                    walk(p0, p1)

        def _walk_trak(start, end, info):
            for btype, p0, p1 in _boxes(moov, start, end):
                if btype in CONTAINERS:
                    _walk_trak(p0, p1, info)
                elif btype == b"stsz":
                    sample_size, count = struct.unpack_from(">II", moov, p0 + 4)
                    info["size"] = sample_size or struct.unpack_from(">I", moov, p0 + 12)[0]
                elif btype == b"co64":
                    info["offset"] = struct.unpack_from(">Q", moov, p0 + 8)[0]
                elif btype == b"stco":
                    info["offset"] = struct.unpack_from(">I", moov, p0 + 8)[0]

        walk(0, len(moov))

        if not tracks:
            raise ValueError("No image tracks found in CR3")
        offset, size = tracks[0]  # track 1 = full-size JPEG
        f.seek(offset)
        jpeg = f.read(size)
        if jpeg[:2] != b"\xff\xd8":
            raise ValueError("Track 1 is not a JPEG; unexpected CR3 layout")

    orientation, make, model = 1, None, None
    if b"CMT1" in cmt:
        t = cmt[b"CMT1"]
        endian, entries = _tiff_ifd0(t)
        if 0x0112 in entries:
            orientation = struct.unpack(endian + "H", _tiff_value_bytes(t, endian, entries[0x0112]))[0]
        make = _tiff_string(t, endian, entries, 0x010F)
        model = _tiff_string(t, endian, entries, 0x0110)

    date_taken = None
    if b"CMT2" in cmt:  # EXIF IFD
        t = cmt[b"CMT2"]
        endian, entries = _tiff_ifd0(t)
        date_taken = _tiff_string(t, endian, entries, 0x9003)

    af = _parse_afinfo2(cmt[b"CMT3"]) if b"CMT3" in cmt else None
    return CR3Data(jpeg=jpeg, orientation=orientation, make=make, model=model, af=af,
                   date_taken=date_taken)
