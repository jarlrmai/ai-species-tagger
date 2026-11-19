"""Write species data to an XMP sidecar (IMG_0001.CR3 -> IMG_0001.xmp).

- No sidecar yet: a new one is created.
- Sidecar exists (e.g. from Lightroom): our fields are merged in, everything else is kept,
  and the original is copied once to IMG_0001.xmp.bak.

Fields written:
  dc:subject               keywords: common name, scientific name (Lightroom/Bridge keywords)
  lr:hierarchicalSubject   "Species|<common name>"
  aitag:*                  full result in a private namespace (the URI is a placeholder)
"""

from __future__ import annotations

import re
import shutil
import xml.etree.ElementTree as ET
from pathlib import Path

NS = {
    "x": "adobe:ns:meta/",
    "rdf": "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
    "dc": "http://purl.org/dc/elements/1.1/",
    "lr": "http://ns.adobe.com/lightroom/1.0/",
    # Private namespace for this tool. example.com is reserved, so this URI is never fetched.
    "aitag": "http://ns.example.com/ai-species-tagger/1.0/",
}
XPACKET_BEGIN = '<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>\n'
XPACKET_END = '\n<?xpacket end="w"?>\n'


def _q(prefix: str, name: str) -> str:
    return f"{{{NS[prefix]}}}{name}"


def sidecar_path(raw_path: Path) -> Path:
    return raw_path.with_suffix(".xmp")


def _register_namespaces(xml_text: str) -> None:
    """Keep the existing file's prefixes (crs:, exif:, ...) instead of ns0:, ns1:."""
    for prefix, uri in re.findall(r'xmlns:([A-Za-z_][\w.-]*)="([^"]+)"', xml_text):
        ET.register_namespace(prefix, uri)
    for prefix, uri in NS.items():
        ET.register_namespace(prefix, uri)


def _new_tree() -> ET.Element:
    root = ET.Element(_q("x", "xmpmeta"))
    rdf = ET.SubElement(root, _q("rdf", "RDF"))
    ET.SubElement(rdf, _q("rdf", "Description"), {_q("rdf", "about"): ""})
    return root


def _add_to_bag(desc: ET.Element, prop: str, values: list[str]) -> None:
    el = desc.find(prop)
    if el is None:
        el = ET.SubElement(desc, prop)
    bag = el.find(_q("rdf", "Bag"))
    if bag is None:
        bag = ET.SubElement(el, _q("rdf", "Bag"))
    existing = {li.text for li in bag.findall(_q("rdf", "li"))}
    for v in values:
        if v and v not in existing:
            ET.SubElement(bag, _q("rdf", "li")).text = v
            existing.add(v)


def _set_private_fields(desc: ET.Element, fields: dict[str, str]) -> None:
    uri = "{" + NS["aitag"] + "}"
    for attr in [a for a in desc.attrib if a.startswith(uri)]:
        del desc.attrib[attr]
    for child in [c for c in desc if c.tag.startswith(uri)]:
        desc.remove(child)
    for name, value in fields.items():
        if value not in (None, ""):
            ET.SubElement(desc, _q("aitag", name)).text = str(value)


def write_species(raw_path: Path, result: dict, extra: dict[str, str]) -> Path:
    """Write the species result for raw_path to its sidecar. Returns the sidecar path."""
    path = sidecar_path(raw_path)
    if path.exists():
        text = path.read_text(encoding="utf-8-sig")
        _register_namespaces(text)
        # ElementTree drops the <?xpacket?> wrappers; we add them back on write.
        root = ET.fromstring(text[text.index("<x:xmpmeta"):text.rindex("</x:xmpmeta>") + len("</x:xmpmeta>")]
                             if "<x:xmpmeta" in text else text)
        backup = path.with_name(path.name + ".bak")
        if not backup.exists():
            shutil.copy2(path, backup)
    else:
        _register_namespaces("")
        root = _new_tree()

    desc = root.find(f"{_q('rdf', 'RDF')}/{_q('rdf', 'Description')}")
    if desc is None:
        raise ValueError(f"{path} has no rdf:Description; not touching it")

    common = result.get("common_name") or ""
    scientific = result.get("scientific_name") or ""
    _add_to_bag(desc, _q("dc", "subject"), [common, scientific])
    if common:
        _add_to_bag(desc, _q("lr", "hierarchicalSubject"), [f"Species|{common}"])

    _set_private_fields(desc, {
        "CommonName": common,
        "ScientificName": scientific,
        "TaxonRank": result.get("rank"),
        "Confidence": f"{float(result.get('confidence', 0)):.2f}",
        "Notes": result.get("notes"),
        "Alternatives": "; ".join(
            f"{a.get('common_name')} ({a.get('scientific_name')})" for a in result.get("alternatives", [])
        ),
        **extra,
    })

    ET.indent(root, space=" ")
    body = ET.tostring(root, encoding="unicode")
    path.write_text(XPACKET_BEGIN + body + XPACKET_END, encoding="utf-8")
    return path
