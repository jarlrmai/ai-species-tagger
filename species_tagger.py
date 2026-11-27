"""AI species tagger (proof of concept).

For each Canon CR3 or DNG (e.g. from DxO PureRAW):
  1. pull the largest embedded JPEG and the AF points out of the raw
  2. crop around the in-focus AF point(s)
  3. ask Claude (or Gemini) to identify the species
  4. write the result to an XMP sidecar next to the raw

Usage:
  python species_tagger.py 1J2A3101.CR3
  python species_tagger.py D:\\Photos\\2026-01-26 --out output
  python species_tagger.py 1J2A3101.CR3 --no-ai      # crop only, no API call, no sidecar
  python species_tagger.py 1J2A3101.CR3 --backend gemini   # Google Gemini (GEMINI_API_KEY)
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
import dng
import xmp_sidecar

# Raw formats this script reads, by extension. DNG AF points come from Canon maker notes the
# converter kept; other cameras' DNGs fall back to a centre crop.
READERS = {".cr3": cr3.read_cr3, ".dng": dng.read_dng}

MODEL = "claude-opus-5-5"
# Tried in order; a model that is overloaded (503), times out (504) or is gone (404) is skipped for
# the next. On a free-tier key in Nov 2026, 3.6 Flash answered reliably while the newest Flash
# models (3.7, 3.8) were often overloaded, so it goes first. Google may retire 3.6 before 3.8.
# No Flash-Lite fallback: 3.5 Flash-Lite called a Crimson-collared Tanager a Flame-rumped
# Tanager at 0.95, and a failed photo (re-run later) beats a confident wrong tag.
# --model replaces the list with one model.
GEMINI_MODELS = ["gemini-3.6-flash", "gemini-3.8-flash"]
GEMINI_TIMEOUT_MS = 90_000
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


def api_jpeg_bytes(img: Image.Image) -> bytes:
    img = img.copy()
    img.thumbnail((MAX_API_EDGE, MAX_API_EDGE), Image.Resampling.LANCZOS)
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=90)
    return buf.getvalue()


def to_api_jpeg(img: Image.Image) -> str:
    return base64.standard_b64encode(api_jpeg_bytes(img)).decode("ascii")


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


# ---------------------------------------------------------------- Gemini

def gemini_client():
    """Client for the Gemini API; the key comes from GEMINI_API_KEY (or GOOGLE_API_KEY)."""
    from google import genai
    from google.genai import types
    # Free-tier limits are per minute as well as per day: wait out a 429 (10 + 20 + 40 s), which
    # covers the per-minute window. Overload (503/504) isn't retried here: identify_gemini moves
    # on to the next model instead, which is much faster than waiting for a busy one.
    retry = types.HttpRetryOptions(attempts=4, initial_delay=10.0, max_delay=60.0,
                                   http_status_codes=[429])
    return genai.Client(http_options=types.HttpOptions(retry_options=retry, timeout=GEMINI_TIMEOUT_MS))


def identify_gemini(client, crop_jpeg: bytes, frame_jpeg: bytes, models: list[str], context: str = ""):
    """Try each model in turn; skip one that is overloaded, timed out or not available."""
    from google.genai import errors
    timeouts = _http_timeout_errors()
    for i, model in enumerate(models):
        try:
            return _identify_gemini_once(client, crop_jpeg, frame_jpeg, model, context)
        except (errors.APIError, *timeouts) as e:
            timed_out = isinstance(e, timeouts)
            if not (timed_out or e.code in (404, 500, 502, 503, 504)) or i == len(models) - 1:
                raise
            why = "timed out" if timed_out else f"{e.code} {e.status}"
            print(f"   {model}: {why}, trying {models[i + 1]}")


def _http_timeout_errors() -> tuple[type[Exception], ...]:
    """The client-side timeout exceptions google-genai can raise (it uses httpx or httpx2)."""
    found = []
    for name in ("httpx2", "httpx"):
        try:
            found.append(__import__(name).TimeoutException)
        except ImportError:
            pass
    return tuple(found)


def _identify_gemini_once(client, crop_jpeg: bytes, frame_jpeg: bytes, model: str, context: str):
    from google.genai import types
    response = client.models.generate_content(
        model=model,
        contents=[
            "Image 1: crop around the focus point.",
            types.Part.from_bytes(data=crop_jpeg, mime_type="image/jpeg"),
            "Image 2: the whole frame.",
            types.Part.from_bytes(data=frame_jpeg, mime_type="image/jpeg"),
            f"{context}\nIdentify the subject.".strip(),
        ],
        config=types.GenerateContentConfig(
            system_instruction=SYSTEM_PROMPT,
            response_mime_type="application/json",
            response_json_schema=RESULT_SCHEMA,
        ),
    )
    feedback = response.prompt_feedback
    if feedback and feedback.block_reason:
        raise RuntimeError(f"Gemini blocked the request: {feedback.block_reason}")
    if not response.text:
        reason = response.candidates[0].finish_reason if response.candidates else "no candidates"
        raise RuntimeError(f"Gemini returned no answer ({reason})")
    return json.loads(response.text), f"gemini:{response.model_version or model}"


# ---------------------------------------------------------------- main

def process(path: Path, out_dir: Path, args, client) -> dict:
    """Crop, identify and (unless --dry-run) write the sidecar. Returns what was found."""
    print(f"\n== {path.name}")
    reader = READERS.get(path.suffix.lower())
    if reader is None:
        raise ValueError(f"Unsupported file type {path.suffix}; supported: {', '.join(READERS)}")
    data = reader(path)
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
    found = {"focus_source": "af-point" if box else "centre", "location": args.location,
             "date_taken": data.date_taken, "result": None, "model": None, "tagged_at": None}

    crop = orient(img.crop(rect), data.orientation)
    crop_path = out_dir / f"{path.stem}_crop.jpg"
    crop.save(crop_path, quality=92)
    save_overlay(img, box, rect, data.orientation, out_dir / f"{path.stem}_af.jpg")
    print(f"   crop {crop.width}x{crop.height} -> {crop_path}")

    if args.no_ai:
        return found

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
    elif args.backend == "gemini":
        result, served_by = identify_gemini(client, api_jpeg_bytes(crop), api_jpeg_bytes(frame),
                                            [args.model] if args.model else GEMINI_MODELS, context)
    else:
        result, served_by = identify(client, to_api_jpeg(crop), to_api_jpeg(frame),
                                     args.model or MODEL, context)
    (out_dir / f"{path.stem}.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    found.update(result=result, model=served_by,
                 tagged_at=datetime.now(timezone.utc).isoformat(timespec="seconds"))

    if not result.get("is_wildlife"):
        print("   no wildlife subject found; sidecar not written")
        return found
    print(f"   {result['common_name']} ({result['scientific_name']}), "
          f"{result['rank']}, confidence {result['confidence']:.2f}")
    print(f"   {result['notes']}")

    if args.dry_run:
        return found
    if path.suffix.lower() == ".dng":
        # Lightroom reads a DNG's metadata from inside the file and ignores .xmp sidecars.
        print("   DNG: sidecar not written (Lightroom ignores sidecars for DNGs; use the plugin)")
        return found
    sidecar = xmp_sidecar.write_species(path, result, {
        "Model": served_by,
        "TaggedAt": found["tagged_at"],
        "FocusSource": found["focus_source"],
        "Location": args.location,
    })
    print(f"   wrote {sidecar}")
    return found


def write_record(path: Path | None, record: dict) -> None:
    """--result-json: one JSON object for the Lightroom plugin, which can't see stdout."""
    if path:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(record, indent=2, ensure_ascii=False), encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="+", type=Path, help="CR3/DNG files or folders")
    ap.add_argument("--out", type=Path, default=Path("output"), help="folder for crops and JSON (default: output)")
    ap.add_argument("--crop-scale", type=float, default=0.5,
                    help="crop side as a fraction of the image's short edge (default 0.5)")
    ap.add_argument("--backend", choices=["api", "claude-cli", "gemini"], default="api",
                    help="api: Anthropic API key (default). claude-cli: Claude Code, billed to your "
                         "subscription. gemini: Google Gemini API key (GEMINI_API_KEY), free tier available")
    ap.add_argument("--model", default=None,
                    help=f"model id (default {MODEL} for api, 'opus' for claude-cli, "
                         f"{', then '.join(GEMINI_MODELS)} for gemini)")
    ap.add_argument("--location",
                    help='where the photos were taken, e.g. "Costa Rica" or "Costa Rica, Guanacaste"; '
                         "helps separate look-alike species")
    ap.add_argument("--claude-path", help="path to the claude executable (claude-cli backend)")
    ap.add_argument("--no-ai", action="store_true", help="only extract and crop")
    ap.add_argument("--dry-run", "--no-sidecar", dest="dry_run", action="store_true",
                    help="call the AI but don't write sidecars")
    ap.add_argument("--result-json", type=Path,
                    help="write the outcome for a single photo to this JSON file, even on failure "
                         "(used by the Lightroom plugin)")
    args = ap.parse_args()

    # Output may be redirected to a log file, where Windows defaults to cp1252 and would fail on
    # names like "Pūkeko".
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding="utf-8", errors="replace")

    files = []
    for p in args.paths:
        files += sorted(f for f in p.iterdir() if f.suffix.lower() in READERS) if p.is_dir() else [p]
    if args.result_json and len(files) != 1:
        ap.error("--result-json takes exactly one photo")
    if not files:
        print("No CR3 or DNG files found.")
        return 1
    args.out.mkdir(parents=True, exist_ok=True)

    # anthropic.Anthropic for api, the claude path for claude-cli, genai.Client for gemini
    client = None
    try:
        if not args.no_ai:
            if args.backend == "claude-cli":
                client = find_claude_cli(args.claude_path)
                print(f"Using Claude Code CLI: {client}")
            elif args.backend == "gemini":
                client = gemini_client()
            else:
                import anthropic
                client = anthropic.Anthropic()
    except Exception as e:
        print(f"FAILED: {type(e).__name__}: {e}")
        write_record(args.result_json, {"ok": False, "path": str(files[0].resolve()),
                                        "error": f"{type(e).__name__}: {e}"})
        return 1

    failures = 0
    for f in files:
        record = {"ok": False, "path": str(f.resolve()), "error": None}
        try:
            record.update(process(f, args.out, args, client))
            record["ok"] = True
        except KeyboardInterrupt:
            record["error"] = "Interrupted"
            write_record(args.result_json, record)
            raise
        except Exception as e:  # keep going through a folder; report each failure
            failures += 1
            record["error"] = f"{type(e).__name__}: {e}"
        # Record first, print second: if stdout is broken (e.g. the log can't be written), the
        # plugin still gets the reason from the result file.
        write_record(args.result_json, record)
        if record["error"]:
            print(f"   FAILED: {record['error']}")
        if record["error"] and client is not None and record["error"].startswith("AuthenticationError"):
            print("   Set ANTHROPIC_API_KEY (or run `ant auth login`) and try again.")
            break
        if record["error"] and args.backend == "gemini" and record["error"].startswith("ClientError: 4"):
            # 400 bad key, 403 no access, 429 quota still exhausted after the retries: the rest
            # of the batch would fail the same way.
            print("   Stopping. Check GEMINI_API_KEY, or the free-tier quota (it resets daily).")
            break
    print(f"\nDone: {len(files) - failures} ok, {failures} failed.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
