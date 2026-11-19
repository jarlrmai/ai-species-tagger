"""AI species tagger (proof of concept).

For each Canon CR3:
  1. pull the full-size embedded JPEG and the AF points out of the raw
  2. crop around the in-focus AF point(s)
  3. ask Claude to identify the species
  4. write the result to an XMP sidecar next to the raw

Usage:
  python species_tagger.py 1J2A3101.CR3
  python species_tagger.py D:\\Photos\\2026-01-26 --out output
  python species_tagger.py 1J2A3101.CR3 --no-ai      # crop only, no API call, no sidecar
"""

from __future__ import annotations

import argparse
import base64
import io
import json
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image, ImageDraw

import cr3
import xmp_sidecar

MODEL = "claude-opus-5-5"
MAX_API_EDGE = 1568  # longest edge sent to the API; larger images are downscaled server-side anyway

SYSTEM_PROMPT = """You are an expert field naturalist identifying wildlife in photographs.

You get two images of the same photo: first a crop around the camera's focus point \
(usually the subject's eye or head, at full resolution), then the whole frame downscaled \
for context. Identify the main subject to the most specific taxon the evidence supports.

Rules:
- Use the current accepted English common name and scientific name (for birds, follow the \
IOC World Bird List).
- If you can't separate two similar species from what is visible, give the lowest rank you are \
sure of (e.g. genus) and list the candidates in alternatives.
- confidence is your probability (0 to 1) that the named taxon is correct.
- notes: one or two sentences naming the field marks you used.
- If there is no animal or plant subject, set is_wildlife to false and leave names empty.
- If a location or date is given, use range and season to separate look-alike species. \
Treat the location as reliable, but don't let it outweigh clear field marks: vagrants happen, \
and you should say so in notes if you think this is one."""


def context_line(location: str | None, date_taken: str | None) -> str:
    """'Photo taken in Costa Rica on 2026-01-26.' or '' when nothing is known."""
    parts = []
    if location:
        parts.append(f"in {location}")
    if date_taken:
        parts.append(f"on {date_taken[:10].replace(':', '-')}")
    return f"Photo taken {' '.join(parts)}." if parts else ""

RESULT_SCHEMA = {
    "type": "object",
    "properties": {
        "is_wildlife": {"type": "boolean"},
        "common_name": {"type": "string"},
        "scientific_name": {"type": "string"},
        "rank": {"type": "string", "enum": ["subspecies", "species", "genus", "family", "order", "unknown"]},
        "confidence": {"type": "number"},
        "notes": {"type": "string"},
        "alternatives": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "common_name": {"type": "string"},
                    "scientific_name": {"type": "string"},
                },
                "required": ["common_name", "scientific_name"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["is_wildlife", "common_name", "scientific_name", "rank", "confidence", "notes", "alternatives"],
    "additionalProperties": False,
}

# EXIF orientation -> Pillow transpose (applied after cropping, since AF coords are in sensor space)
ORIENTATION_OPS = {
    3: Image.Transpose.ROTATE_180,
    6: Image.Transpose.ROTATE_270,  # camera rotated 90 CW -> rotate image 90 CW
    8: Image.Transpose.ROTATE_90,
}


# ---------------------------------------------------------------- cropping

def focus_box(data: cr3.CR3Data, img_w: int, img_h: int):
    """Bounding box (l, t, r, b) of the in-focus AF points in JPEG pixels, or None."""
    if not data.af:
        return None
    pts = data.af.focus_points()
    if not pts:
        return None
    sx, sy = img_w / data.af.image_width, img_h / data.af.image_height
    left = min((p.x - p.w / 2) * sx for p in pts)
    top = min((p.y - p.h / 2) * sy for p in pts)
    right = max((p.x + p.w / 2) * sx for p in pts)
    bottom = max((p.y + p.h / 2) * sy for p in pts)
    return left, top, right, bottom


def crop_rect(box, img_w: int, img_h: int, scale: float):
    """Square crop centred on the focus box, `scale` x the short edge, clamped to the frame."""
    if box is None:
        cx, cy, box_side = img_w / 2, img_h / 2, 0
    else:
        cx, cy = (box[0] + box[2]) / 2, (box[1] + box[3]) / 2
        box_side = max(box[2] - box[0], box[3] - box[1])
    side = min(max(scale * min(img_w, img_h), 3 * box_side), min(img_w, img_h))
    left = min(max(cx - side / 2, 0), img_w - side)
    top = min(max(cy - side / 2, 0), img_h - side)
    return int(left), int(top), int(left + side), int(top + side)


def orient(img: Image.Image, orientation: int) -> Image.Image:
    op = ORIENTATION_OPS.get(orientation)
    return img.transpose(op) if op else img


def to_api_jpeg(img: Image.Image) -> str:
    img = img.copy()
    img.thumbnail((MAX_API_EDGE, MAX_API_EDGE), Image.Resampling.LANCZOS)
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=90)
    return base64.standard_b64encode(buf.getvalue()).decode("ascii")


def save_overlay(img: Image.Image, box, rect, orientation: int, path: Path) -> None:
    """Downscaled full frame with the AF box (red) and the crop (yellow) drawn on it."""
    small = img.copy()
    small.thumbnail((1600, 1600))
    s = small.width / img.width
    d = ImageDraw.Draw(small)
    d.rectangle([v * s for v in rect], outline="yellow", width=3)
    if box:
        d.rectangle([v * s for v in box], outline="red", width=3)
    orient(small, orientation).save(path, quality=85)


# ---------------------------------------------------------------- Claude

def find_claude_cli(explicit: str | None) -> str:
    """claude on PATH, else the newest copy bundled with the VS Code extension."""
    if explicit:
        return explicit
    found = shutil.which("claude")
    if found:
        return found
    bundled = sorted(
        Path.home().glob(".vscode/extensions/anthropic.claude-code-*/resources/native-binary/claude*.exe"),
        key=lambda p: p.stat().st_mtime,
    )
    if bundled:
        return str(bundled[-1])
    raise FileNotFoundError("Can't find the claude CLI; pass --claude-path")


def identify_cli(claude: str, crop_path: Path, frame_path: Path, model: str, context: str = ""):
    """Identify via Claude Code in print mode, billed to the signed-in Claude subscription."""
    prompt = (
        f"{SYSTEM_PROMPT}\n\n"
        f"Image 1, the crop around the focus point: {crop_path.name}\n"
        f"Image 2, the whole frame: {frame_path.name}\n"
        + (f"{context}\n" if context else "") +
        "Read both images with the Read tool, then identify the subject. "
        "Return only the structured result."
    )
    cmd = [
        claude, "-p",
        "--model", model,
        "--output-format", "json",
        "--json-schema", json.dumps(RESULT_SCHEMA),
        "--tools", "Read",
        "--allowedTools", "Read",
        "--no-session-persistence",
    ]
    # Run inside the output folder so the Read tool is confined to the two images' folder.
    proc = subprocess.run(cmd, input=prompt, capture_output=True, text=True, encoding="utf-8",
                          cwd=crop_path.parent, timeout=600)
    if proc.returncode != 0:
        raise RuntimeError(f"claude exited {proc.returncode}: {(proc.stderr or proc.stdout).strip()[:500]}")
    out = json.loads(proc.stdout)
    if out.get("is_error"):
        raise RuntimeError(f"claude reported an error: {out.get('result')}")
    result = out.get("structured_output")
    if result is None:
        result = json.loads(out["result"])
    served_by = ",".join(out.get("modelUsage", {}).keys()) or model
    return result, f"claude-cli:{served_by}"


def identify(client, crop_b64: str, frame_b64: str, model: str, context: str = ""):
    response = client.beta.messages.create(
        model=model,
        max_tokens=16000,
        # If a safety classifier declines, the API retries on a fallback model in the same call.
        betas=["server-side-fallback-2026-07-01"],
        fallbacks="default",
        output_config={
            "effort": "medium",
            "format": {"type": "json_schema", "schema": RESULT_SCHEMA},
        },
        system=SYSTEM_PROMPT,
        messages=[{
            "role": "user",
            "content": [
                {"type": "text", "text": "Image 1: crop around the focus point."},
                {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": crop_b64}},
                {"type": "text", "text": "Image 2: the whole frame."},
                {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": frame_b64}},
                {"type": "text", "text": f"{context}\nIdentify the subject.".strip()},
            ],
        }],
    )
    if response.stop_reason == "refusal":
        raise RuntimeError("The model declined to answer this image")
    if response.stop_reason == "max_tokens":
        raise RuntimeError("Response was cut off (max_tokens)")
    text = next(b.text for b in response.content if b.type == "text")
    return json.loads(text), response.model


# ---------------------------------------------------------------- main

def process(path: Path, out_dir: Path, args, client) -> None:
    print(f"\n== {path.name}")
    data = cr3.read_cr3(path)
    img = Image.open(io.BytesIO(data.jpeg))
    img.load()
    print(f"   {data.make} {data.model}, JPEG {img.width}x{img.height}, orientation {data.orientation}")

    box = focus_box(data, img.width, img.height)
    if box:
        pts = data.af.focus_points()
        print(f"   AF: {len(pts)} point(s), box {[int(v) for v in box]}")
    else:
        print("   AF: no in-focus point recorded; cropping the centre")
    rect = crop_rect(box, img.width, img.height, args.crop_scale)

    crop = orient(img.crop(rect), data.orientation)
    crop_path = out_dir / f"{path.stem}_crop.jpg"
    crop.save(crop_path, quality=92)
    save_overlay(img, box, rect, data.orientation, out_dir / f"{path.stem}_af.jpg")
    print(f"   crop {crop.width}x{crop.height} -> {crop_path}")

    if args.no_ai:
        return

    frame = orient(img, data.orientation)
    context = context_line(args.location, data.date_taken)
    if context:
        print(f"   context: {context}")
    if args.backend == "claude-cli":
        frame_path = out_dir / f"{path.stem}_frame.jpg"
        small = frame.copy()
        small.thumbnail((MAX_API_EDGE, MAX_API_EDGE), Image.Resampling.LANCZOS)
        small.save(frame_path, quality=90)
        result, served_by = identify_cli(client, crop_path.resolve(), frame_path.resolve(),
                                         args.model or "opus", context)
    else:
        result, served_by = identify(client, to_api_jpeg(crop), to_api_jpeg(frame),
                                     args.model or MODEL, context)
    (out_dir / f"{path.stem}.json").write_text(json.dumps(result, indent=2), encoding="utf-8")

    if not result.get("is_wildlife"):
        print("   no wildlife subject found; sidecar not written")
        return
    print(f"   {result['common_name']} ({result['scientific_name']}), "
          f"{result['rank']}, confidence {result['confidence']:.2f}")
    print(f"   {result['notes']}")

    if args.dry_run:
        return
    sidecar = xmp_sidecar.write_species(path, result, {
        "Model": served_by,
        "TaggedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "FocusSource": "af-point" if box else "centre",
        "Location": args.location,
    })
    print(f"   wrote {sidecar}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="+", type=Path, help="CR3 files or folders")
    ap.add_argument("--out", type=Path, default=Path("output"), help="folder for crops and JSON (default: output)")
    ap.add_argument("--crop-scale", type=float, default=0.5,
                    help="crop side as a fraction of the image's short edge (default 0.5)")
    ap.add_argument("--backend", choices=["api", "claude-cli"], default="api",
                    help="api: Anthropic API key (default). claude-cli: Claude Code, billed to your subscription")
    ap.add_argument("--model", default=None,
                    help=f"model id (default {MODEL} for api, 'opus' for claude-cli)")
    ap.add_argument("--location",
                    help='where the photos were taken, e.g. "Costa Rica" or "Costa Rica, Guanacaste"; '
                         "helps separate look-alike species")
    ap.add_argument("--claude-path", help="path to the claude executable (claude-cli backend)")
    ap.add_argument("--no-ai", action="store_true", help="only extract and crop")
    ap.add_argument("--dry-run", action="store_true", help="call the AI but don't write sidecars")
    args = ap.parse_args()

    files = []
    for p in args.paths:
        files += sorted(p.glob("*.[cC][rR]3")) if p.is_dir() else [p]
    if not files:
        print("No CR3 files found.")
        return 1
    args.out.mkdir(parents=True, exist_ok=True)

    client = None  # anthropic.Anthropic for the api backend, the claude path for claude-cli
    if not args.no_ai:
        if args.backend == "claude-cli":
            client = find_claude_cli(args.claude_path)
            print(f"Using Claude Code CLI: {client}")
        else:
            import anthropic
            client = anthropic.Anthropic()

    failures = 0
    for f in files:
        try:
            process(f, args.out, args, client)
        except Exception as e:  # keep going through a folder; report each failure
            failures += 1
            print(f"   FAILED: {type(e).__name__}: {e}")
            if client is not None and type(e).__name__ == "AuthenticationError":
                print("   Set ANTHROPIC_API_KEY (or run `ant auth login`) and try again.")
                break
    print(f"\nDone: {len(files) - failures} ok, {failures} failed.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
