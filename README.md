# AI Species Tagger for Lightroom Classic

A Lightroom Classic plugin that identifies the wildlife in your photos with Claude (or Google Gemini) and tags it
in the catalogue. For each selected Canon CR3 (or DNG, e.g. from DxO PureRAW), it crops around the in-focus AF point, sends the crop
and the full frame to Claude, and adds a **Species > \<common name\>** keyword plus searchable
fields: scientific name, confidence, field-mark notes, alternatives and more.

Status: early version, Windows only. Tested end to end against a stubbed Lightroom SDK; first
runs in real Lightroom may still turn up rough edges.

## Setup (Windows)

1. Install Python 3.12 from python.org or `winget install Python.Python.3.12`.
2. In this folder:
   ```
   python -m venv .venv
   .venv\Scripts\activate
   pip install -r requirements.txt
   ```
3. Install the plugin: in Lightroom Classic, **File > Plug-in Manager > Add**, and pick
   `lightroom\SpeciesTagger.lrplugin`. Leave the plugin inside this repo: by default it finds
   `species_tagger.py` and `.venv\Scripts\python.exe` two folders up.
4. Pick how the AI is called, in the Plug-in Manager (or per run in the tag dialog):
   - **Claude subscription** (the plugin's default, no API key): runs Claude Code (`claude -p`)
     under your signed-in Claude plan and counts toward its usage limits. It uses `claude` from
     PATH, otherwise the copy bundled with the VS Code extension, or the path set in the Plug-in
     Manager.
   - **API key** (faster for big batches), from console.anthropic.com:
     ```
     setx ANTHROPIC_API_KEY "sk-ant-..."
     ```
     Then restart Lightroom so it picks up the variable.
   - **Google Gemini** (free tier available): get a key at aistudio.google.com, then
     ```
     setx GEMINI_API_KEY "..."
     ```
     and restart Lightroom. The script tries `gemini-3.6-flash`, then `gemini-3.8-flash`, then
     `gemini-3.5-flash-lite`, moving on when a model is overloaded, times out or has been retired.
     3.6 goes first because the newest models are often busy on the free tier. A model in the plugin's Model field (or
     `--model`) replaces the list. To see the models your key can use:
     `python -c "from google import genai; [print(m.name) for m in genai.Client().models.list()]"` On the free tier, Google may use what you send (crops, full frame,
     location) to improve its products, and there are per-minute and daily limits. The script
     waits and retries when it hits a per-minute limit, and stops the batch when the daily quota
     runs out.

ExifTool is **not** required: CR3s are parsed directly in `cr3.py` and DNGs in `dng.py`.

## Use

Select photos, then **Library > Plug-in Extras > Tag Species with AI...** (or the File menu,
which also works in Develop). The dialog asks for:

- **Location**, e.g. "Costa Rica, Guanacaste". Each photo's own IPTC location fields or GPS are
  used first when it has them; what you type is the fallback. Location matters a lot with
  look-alikes: on `1J2A2741.CR3`, without one the answer was Golden-fronted Woodpecker at 0.72;
  with it, Hoffmann's Woodpecker at 0.92.
- whether to **skip photos already tagged**
- the **AI backend**

Non-CR3s, virtual copies and offline files are skipped. Each photo takes about 10 to 40 seconds.
**Cancel** from the progress bar at the top left; the photo in progress finishes first and
everything done so far is kept.

## What it writes

For each photo, straight into the catalogue (no XMP sidecars):

- the keyword **Species > \<common name\>**, created if needed, with the scientific name as its
  synonym
- **Species > _check** as well, when the confidence is below the "flag below" threshold (0.7)
- plugin fields: species, scientific name, rank, confidence, confidence band
  (high/medium/low/no wildlife), notes, alternatives, location used, crop source, model and time.
  They're shown in the **AI Species** Metadata panel preset, and confidence band works in smart
  collections, e.g. "Confidence band is Low" to review the uncertain ones.

If you tag a photo again, the previous species keyword and `_check` are replaced. Keywords you
added yourself are left alone. Results are saved to the catalogue every 10 photos, and each save
is one Undo step.

Thresholds, paths, model and backend are set in **File > Plug-in Manager**.

**Logs:** `Documents\LrClassicLogs\SpeciesTagger.log` (commands run, results) and
`%TEMP%\AISpeciesTagger\python.log` (the script's output for the latest run).

## How it works

The plugin runs `species_tagger.py` once per photo with `--no-sidecar --result-json`, reads the
JSON result and writes it to the catalogue.

**Focus point.** Canon stores AF data in maker-note tag `0x0026` (AFInfo2) inside the CR3's
`CMT3` box: the size and position of each AF area relative to the frame centre, plus bitmasks of
the points that were in focus and the points that were selected. The script takes the in-focus
points (or the selected ones if none achieved focus) and centres a square crop on them. With no AF
data, it falls back to the centre.

**DNG.** The largest embedded JPEG preview is used (DxO PureRAW embeds a full-size one). DNG
converters such as DxO PureRAW and Adobe DNG Converter keep the camera's original maker notes in
the DNG's private data, so for Canon the same AF data is read from there. Checked on a DxO PureRAW
5 DNG from the R5: the AF point lands on the eye, as in the CR3. DNGs from other makes get a
centre crop.

On the R5, a positive Y position means up. This was checked on `1J2A3101.CR3`: the in-focus
Eye Detection AF point lands on the dove's eye. Other Canon bodies may differ.

The crop and a downscaled full frame both go to Claude. The crop gives detail and the full frame
shows the whole animal, which matters when AF was on the eye. The capture date from the file goes
along with the location, so range and season can separate look-alikes.

## Command-line use (without Lightroom)

`species_tagger.py` also works on its own and writes XMP sidecars instead:

```
python species_tagger.py 1J2A3101.CR3 --no-ai    # check the crop first, no AI call
python species_tagger.py 1J2A3101.CR3 --backend claude-cli   # using your Claude subscription
python species_tagger.py 1J2A3101.CR3 --backend gemini       # using GEMINI_API_KEY
python species_tagger.py 1J2A3101.CR3            # identify via API key + write 1J2A3101.xmp
python species_tagger.py D:\Photos\Birds --location "Costa Rica"   # every CR3 and DNG in a folder
```

On the command line the default backend is the Claude API key; add `--backend claude-cli` to use
your subscription, or `--backend gemini` for Google Gemini.

To compare backends on the same photos, run each with `--dry-run` and its own `--out` folder,
then compare the JSON files.

Options: `--location TEXT` where you shot. `--crop-scale 0.5` sets the crop size as a fraction of
the short edge. `--dry-run` (or `--no-sidecar`) calls the AI but writes no sidecar. `--out DIR`
sets where crops and JSON go. `--result-json FILE` writes the outcome for a single photo to one JSON
file, even when it fails (the plugin uses this). `--model`, `--claude-path` as in the plugin
settings.

| File | What |
|---|---|
| `output/<name>_crop.jpg` | full-resolution crop around the focus point |
| `output/<name>_af.jpg` | small full frame: AF box in red, crop in yellow |
| `output/<name>.json` | the raw AI result |
| `<name>.xmp` (beside the CR3) | keywords + species fields |

The sidecar gets `dc:subject` keywords (common and scientific name), `lr:hierarchicalSubject`
`Species|<common name>`, and `aitag:*` fields (names, rank, confidence, notes, alternatives,
model, time). An existing sidecar is merged into, and the original is copied once to
`<name>.xmp.bak`. The raw file itself is never modified. No sidecar is written
for a DNG: Lightroom reads a DNG's metadata from inside the file and ignores sidecars.

**Don't use sidecar mode on photos in a Lightroom catalogue; use the plugin.** Lightroom treats
its catalogue as the master copy. **Metadata > Read Metadata from Files** replaces the catalogue's
metadata with the sidecar's, which can wipe ratings, keywords and edits if the sidecar was created
by this script or is out of date. Lightroom saving metadata later overwrites the sidecar and drops
the AI keywords.

## Known limits

- CR3 and DNG only; AF points for Canon only. Only the Canon R5 has been checked. Mirrored EXIF orientations (2, 4, 5, 7) are
  ignored.
- The plugin is Windows only. Paths containing non-ASCII characters may not survive Lightroom's
  `LrTasks.execute`.
- The command-line tool doesn't read GPS from the file (the sample files have none); use
  `--location`. The plugin uses the catalogue's GPS and location fields.
