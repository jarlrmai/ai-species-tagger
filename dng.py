"""Minimal DNG reader: largest embedded JPEG preview, orientation, date and (Canon) AF points.

DNG is a TIFF file. What we need lives in:
  IFD0 (and its SubIFDs)       images; previews have NewSubFileType bit 0 set and are JPEG
  IFD0 Orientation, Make, Model
  ExifIFD DateTimeOriginal
  IFD0 DNGPrivateData          "Adobe\\0" + "MakN" chunk: the camera's original maker notes,
                               which converters such as DxO PureRAW and Adobe DNG Converter keep.
                               For Canon these hold AFInfo2, decoded as in cr3.py.

Only the IFDs and the chosen preview are read, not the whole (often 100+ MB) file.
Standard-library code only, like cr3.py.
"""

from __future__ import annotations

import struct
from pathlib import Path

import cr3

_TYPE_SIZE = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4}

T_NEW_SUBFILE_TYPE, T_WIDTH, T_BITS, T_COMPRESSION = 254, 256, 258, 259
T_MAKE, T_MODEL, T_STRIP_OFFSETS, T_ORIENTATION, T_STRIP_BYTES = 271, 272, 273, 274, 279
T_SUB_IFDS, T_JPEG_OFFSET, T_JPEG_LENGTH = 330, 513, 514
T_EXIF_IFD, T_DATE_ORIGINAL, T_DNG_PRIVATE = 34665, 36867, 50740


class _Tiff:
    def __init__(self, f):
        self.f = f
        f.seek(0)
        head = f.read(8)
        if head[:4] not in (b"II*\0", b"MM\0*"):
            raise ValueError("Not a TIFF/DNG file")
        self.e = "<" if head[:2] == b"II" else ">"
        self.first_ifd = struct.unpack(self.e + "I", head[4:8])[0]

    def read(self, pos: int, n: int) -> bytes:
        self.f.seek(pos)
        return self.f.read(n)

    def ifd(self, off: int):
        """({tag: (type, count, value_pos)}, next_ifd_offset) for the IFD at `off`."""
        n = struct.unpack(self.e + "H", self.read(off, 2))[0]
        raw = self.read(off + 2, 12 * n + 4)
        entries = {}
        for i in range(n):
            tag, typ, count = struct.unpack_from(self.e + "HHI", raw, 12 * i)
            pos = off + 2 + 12 * i + 8
            if _TYPE_SIZE.get(typ, 1) * count > 4:
                pos = struct.unpack_from(self.e + "I", raw, 12 * i + 8)[0]
            entries[tag] = (typ, count, pos)
        return entries, struct.unpack_from(self.e + "I", raw, 12 * n)[0]

    def value_bytes(self, entry) -> bytes:
        typ, count, pos = entry
        return self.read(pos, _TYPE_SIZE.get(typ, 1) * count)

    def ints(self, entries, tag) -> list[int]:
        if tag not in entries:
            return []
        typ, count, _ = entries[tag]
        fmt = {1: "B", 3: "H", 4: "I", 7: "B", 13: "I"}.get(typ)
        if fmt is None:
            return []
        return list(struct.unpack(f"{self.e}{count}{fmt}", self.value_bytes(entries[tag])))

    def string(self, entries, tag) -> str | None:
        if tag not in entries:
            return None
        return self.value_bytes(entries[tag]).split(b"\0")[0].decode("ascii", "replace").strip()


def _all_ifds(t: _Tiff):
    """IFD0's chain and every SubIFD under it."""
    todo, seen = [t.first_ifd], set()
    while todo:
        off = todo.pop()
        if not off or off in seen:
            continue
        seen.add(off)
        entries, nxt = t.ifd(off)
        yield off, entries
        todo.append(nxt)
        todo.extend(t.ints(entries, T_SUB_IFDS))


def _jpeg_previews(t: _Tiff, ifds):
    """(width, offset, length) of each 8-bit JPEG preview stored as a single strip."""
    for _, entries in ifds:
        subfile = (t.ints(entries, T_NEW_SUBFILE_TYPE) or [0])[0]
        if not subfile & 1:  # not a reduced-resolution image: the raw data itself
            continue
        bits = t.ints(entries, T_BITS)
        if bits and bits[0] != 8:
            continue
        if (t.ints(entries, T_COMPRESSION) or [0])[0] not in (6, 7):
            continue
        offsets = t.ints(entries, T_STRIP_OFFSETS) or t.ints(entries, T_JPEG_OFFSET)
        lengths = t.ints(entries, T_STRIP_BYTES) or t.ints(entries, T_JPEG_LENGTH)
        if len(offsets) == 1 and len(lengths) == 1:
            yield (t.ints(entries, T_WIDTH) or [0])[0], offsets[0], lengths[0]


def _maker_notes_as_tiff(private: bytes) -> bytes | None:
    """The original maker notes from DNGPrivateData, as a TIFF blob cr3._parse_afinfo2 can read.

    Layout (DNG spec): "Adobe\\0", then chunks of 4-byte type + 4-byte big-endian length. A "MakN"
    chunk holds the original byte order (2 bytes), the maker notes' original file offset (4 bytes,
    big-endian) and the maker notes themselves. Their internal offsets are relative to that
    original file, so the notes go back at the same offset behind a TIFF header.
    """
    if not private.startswith(b"Adobe\0"):
        return None
    pos = 6
    while pos + 8 <= len(private):
        ctype = private[pos:pos + 4]
        length = struct.unpack_from(">I", private, pos + 4)[0]
        body = private[pos + 8:pos + 8 + length]
        if ctype == b"MakN" and len(body) > 6:
            order = body[:2]
            orig = struct.unpack_from(">I", body, 2)[0]
            notes = body[6:]
            if order not in (b"II", b"MM") or orig < 8:
                return None
            e = "<" if order == b"II" else ">"
            buf = bytearray(orig + len(notes))
            buf[0:2] = order
            struct.pack_into(e + "HI", buf, 2, 42, orig)
            buf[orig:] = notes
            return bytes(buf)
        pos += 8 + length
    return None


def read_dng(path: str | Path) -> cr3.CR3Data:
    with open(path, "rb") as f:
        t = _Tiff(f)
        ifds = list(_all_ifds(t))
        ifd0 = ifds[0][1]

        previews = sorted(_jpeg_previews(t, ifds), reverse=True)
        jpeg = None
        for _, offset, length in previews:
            data = t.read(offset, length)
            if data[:2] == b"\xff\xd8":
                jpeg = data
                break
        if jpeg is None:
            raise ValueError("No JPEG preview in this DNG; re-export it with a full-size preview")

        orientation = (t.ints(ifd0, T_ORIENTATION) or [1])[0]
        make, model = t.string(ifd0, T_MAKE), t.string(ifd0, T_MODEL)

        date_taken = None
        exif = t.ints(ifd0, T_EXIF_IFD)
        if exif:
            date_taken = t.string(t.ifd(exif[0])[0], T_DATE_ORIGINAL)

        af = None
        if T_DNG_PRIVATE in ifd0 and (make or "").lower().startswith("canon"):
            notes = _maker_notes_as_tiff(t.value_bytes(ifd0[T_DNG_PRIVATE]))
            if notes:
                af = cr3._parse_afinfo2(notes)

    return cr3.CR3Data(jpeg=jpeg, orientation=orientation, make=make, model=model, af=af,
                       date_taken=date_taken)
