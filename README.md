# AI species tagger (proof of concept)

Reads a Canon CR3, crops the embedded full-size JPEG around the in-focus AF point,
asks Claude to identify the species, and writes the result to an XMP sidecar.

## Setup (Windows)

1. Install Python 3.12 from python.org or `winget install Python.Python.3.12`.
2. In this folder:
   ```
   python -m venv .venv
   .venv\Scripts\activate
   pip install -r requirements.txt
   ```
3. Pick how the AI is called:
   - **Claude subscription (no API key):** add `--backend claude-cli` to every run. The tool
     runs Claude Code (`claude -p`) under your signed-in Claude plan and counts toward its
     usage limits. It uses `claude` from PATH, otherwise the copy bundled with the VS Code
     extension, or the path you give with `--claude-path`.
   - **API key** (the default backend, faster for big batches), from console.anthropic.com:
   ```
   setx ANTHROPIC_API_KEY "sk-ant-..."
   ```
   Then open a new terminal so the variable is picked up.

ExifTool is **not** required: the CR3 is parsed directly in `cr3.py`.

## Run

```
python species_tagger.py 1J2A3101.CR3 --no-ai    # check the crop first, no API call
python species_tagger.py 1J2A3101.CR3 --backend claude-cli   # using your Claude subscription
python species_tagger.py 1J2A3101.CR3            # identify via API key + write 1J2A3101.xmp
python species_tagger.py D:\Photos\Birds         # every CR3 in a folder
```

Add `--location "Costa Rica"` (or something more specific) whenever you know where you shot.
It goes to the model together with the capture date from the file, and is saved in the sidecar
as `aitag:Location`. It makes a big difference with look-alikes: on `1J2A2741.CR3`, without a
location the answer was Golden-fronted Woodpecker at 0.72; with it, Hoffmann's Woodpecker at 0.92.

Options: `--crop-scale 0.5` sets the crop size as a fraction of the short edge.
`--dry-run` calls the AI but writes no sidecar. `--out DIR` sets where crops and JSON go.

## Output

| File | What |
|---|---|
| `output/<name>_crop.jpg` | full-resolution crop around the focus point |
| `output/<name>_af.jpg` | small full frame: AF box in red, crop in yellow |
| `output/<name>.json` | the raw AI result |
| `<name>.xmp` (beside the CR3) | keywords + species fields |

The sidecar gets:
- `dc:subject` keywords: common name and scientific name
- `lr:hierarchicalSubject`: `Species|<common name>`
- `aitag:*`: common/scientific name, rank, confidence, notes, alternatives, model, time

If a sidecar already exists (for example from Lightroom), the fields are merged in and the
original is copied once to `<name>.xmp.bak`. The CR3 itself is never modified.
In Lightroom Classic, use **Metadata > Read Metadata from Files** to pick up the keywords.

## How the focus point is found

Canon stores AF data in maker-note tag `0x0026` (AFInfo2) inside the CR3's `CMT3` box:
the size and position of each AF area relative to the frame centre, plus bitmasks of the
points that were in focus and the points that were selected. The tool takes the in-focus points
(or the selected ones if none achieved focus) and centres a square crop on them. With no AF data,
it falls back to the centre.

On the R5, a positive Y position means up. This was checked on `1J2A3101.CR3`: the in-focus
Eye Detection AF point lands on the dove's eye. Other Canon bodies may differ.

The crop and a downscaled full frame both go to Claude. The crop gives detail and the full frame
shows the whole animal, which matters when AF was on the eye.

## Known limits

- Only the R5 sample has been checked. Mirrored EXIF orientations (2, 4, 5, 7) are ignored.
- GPS isn't read from the file yet; the two sample files have none. Use `--location` instead.
