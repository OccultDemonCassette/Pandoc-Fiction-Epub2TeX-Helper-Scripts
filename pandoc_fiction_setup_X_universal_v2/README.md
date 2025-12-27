# Pandoc EPUB → Memoir LaTeX “Fiction Pipeline”

Convert fiction EPUBs into **Memoir-class LaTeX** (XeLaTeX-friendly) that already resembles a “ready-to-typeset novel,” minimizing manual cleanup.

This bundle is designed around three files:

- `novel.yaml` — Pandoc defaults (one-command wiring)
- `fiction-template.tex` — Memoir-based template (layout, environments, XeLaTeX friendliness)
- `epub-fiction-fix.lua` — Lua filter (structure inference + cleanup)

---

## What this pipeline tries to produce

A consistent hierarchy that works across many EPUB families:

- **\part** (optional)
- **frontmatter chapters** (optional: Foreword / Preface / Introduction)
- **main chapters**
- **sections inside chapters** (for POV markers, author-byline in anthologies, etc.)

In addition, it tries to:

- remove *in-book* EPUB ToC/nav pages (you only use LaTeX `\tableofcontents`)
- prevent garbage headings such as `\chapter{�}` / ornament-only “chapters”
- convert scene breaks (`***`, `* * *`, `⁂`, many `<hr/>`) into `\scenebreak`
- convert “inscription:” blocks into a `tabletcurse` environment
- optionally convert EPUB endnotes/backlinks into real LaTeX footnotes to reduce `hyperref` churn

---

## Requirements

### Required
- **Pandoc** (recommended: 3.x).  
  Verify installation:
  ```bash
  pandoc --version
  ```
  In the output, note **User data directory** (that’s where Pandoc will look for defaults/templates/filters).

### For PDF output (optional but common)
- A TeX distribution with **XeLaTeX**:
  - Windows: MiKTeX or TeX Live
  - macOS: MacTeX
  - Linux: TeX Live

### Nice-to-have
- `latexmk` (makes compiling stable and repeatable)

---

## Installation

### Step 1 — Find Pandoc’s user data directory

Run:

```bash
pandoc --version
```

Look for a line like:

- Windows: `User data directory: C:\Users\<YOU>\AppData\Roaming\pandoc`
- Linux: `~/.local/share/pandoc`
- macOS often: `~/Library/Application Support/pandoc`  
  (Pandoc prints the authoritative path—trust that output.)

### Step 2 — Create the standard subfolders

Inside the user data directory, create:

```
pandoc/
  defaults/
  templates/
  filters/
```

### Step 3 — Copy the bundle files into place

Copy:

- `novel.yaml` → `.../pandoc/defaults/novel.yaml`
- `fiction-template.tex` → `.../pandoc/templates/fiction-template.tex`
- `epub-fiction-fix.lua` → `.../pandoc/filters/epub-fiction-fix.lua`

> Tip: You can also keep them in a project folder and call `-d path/to/novel.yaml` (see below).

---

## Quickstart

Convert an EPUB to LaTeX:

```bash
pandoc "Book.epub" -d novel -o "Book.tex"
```

That’s it. The defaults file:
- enables a LaTeX ToC (`toc: true`)
- sets `top-level-division: part`
- applies the Lua filter via `filters:`
- uses XeLaTeX if you later output directly to PDF

---

## Compiling the resulting LaTeX to PDF

### Option A — latexmk (recommended)

```bash
latexmk -xelatex Book.tex
```

### Option B — XeLaTeX directly

```bash
xelatex Book.tex
xelatex Book.tex
```

Two passes are often needed for ToC/bookmarks.

---

## Usage patterns

### 1) Keep everything self-contained in a project folder

If you don’t want to install into Pandoc’s user data directory, you can run with an explicit defaults file:

```bash
pandoc "Book.epub" -d "./novel.yaml" -o "Book.tex"
```

Make sure `novel.yaml`, `fiction-template.tex`, and `epub-fiction-fix.lua` are in the same folder *or* adjust paths inside `novel.yaml`.

### 2) Override a metadata knob on the CLI

Example: turn on debug logging:

```bash
pandoc "Book.epub" -d novel --metadata debug_fiction_filter=true -o "Book.tex"
```

Example: disable frontmatter pruning for a picky EPUB:

```bash
pandoc "Book.epub" -d novel --metadata drop_frontmatter_marketing=false -o "Book.tex"
```

### 3) Capture debug output to a log file (Windows friendly)

The debug mode prints to **stderr**. Capture it:

```bat
pandoc "Book.epub" -d novel -o "Book.tex" 2> debug.log
```

---

## Configuration knobs

All knobs live under `metadata:` in `novel.yaml`. You can edit the file or override per-run using `--metadata key=value`.

### Core structure / robustness

- `header_h1_role: auto`  
  Values: `auto | part | chapter`  
  - `auto` tries to infer whether EPUB `H1` should behave like `\part` (novel) or `\chapter` (anthology/story-title style).
  - Use `part` or `chapter` only when an EPUB confuses the heuristic.

- `allow_all_caps_chapters: false`  
  If `true`, some ALL-CAPS headings can become chapters (useful for some books).  
  If `false`, the filter is stricter to avoid “DNA string” / marketing false positives.

- `promote_pov_sections: true`  
  Converts POV markers like `HENRY—` into `\section{HENRY}` **only when already inside a chapter**.

### Endnotes → footnotes (stability)

- `convert_endnotes: true`  
  Converts EPUB endnote hyperlink systems into real Pandoc Notes → LaTeX `\footnote{...}`, and drops the endnotes section when possible.

This is strongly recommended for EPUBs that otherwise produce many `hyperref` warnings/undefined references.

### Marketing / boilerplate pruning

These exist because many EPUBs include front/back matter that you *don’t* want in a “ready-to-typeset novel” output.

- `drop_marketing: true`  
  Stops output when marketing pages begin **after backmatter has started**.

- `drop_frontmatter_marketing: true`  
  Tries to remove frontmatter marketing/other-books pages.

- `drop_copyright_blocks: true`  
  Tries to remove copyright/ISBN boilerplate blocks.

- `drop_other_books_lists: true`  
  Tries to remove “Also by… / Other books…” lists/pages.

- `drop_about_author: true`  
  Tries to remove “About the Author” frontmatter blocks.

> These are intentionally conservative. If you see legitimate content removed, turn the relevant knob off for that book.

### Anthology-specific

- `author_line_allows_by_prefix: false`  
  If `true`, author bylines like `by Gene Wolfe` are treated as author headings (and the `by` is stripped).

### Debugging / transparency

- `debug_fiction_filter: false`  
  If `true`, the Lua filter logs key decisions to stderr, e.g.:
  - inferred header role
  - when it inserts `\mainmatter` / `\backmatter`
  - when it drops detected in-book ToC/nav blocks
  - when it prunes marketing/boilerplate
  - when it promotes a block to a part/chapter/section

---

## Template notes (Memoir)

`fiction-template.tex` is memoir-based and aims to be stable and XeLaTeX-friendly.

Notable bits:
- provides `\scenebreak` (so the filter can safely emit it)
- defines `tabletcurse` for inscriptions
- uses `hyperref` + `bookmark`
- includes some conservative line-breaking settings (`\emergencystretch` etc.)

### Choosing a font
You can pass a font via Pandoc variables:

```bash
pandoc "Book.epub" -d novel -V mainfont="EB Garamond" -o "Book.tex"
```

---

## Common troubleshooting

### “Aeson exception: Unknown option lua-filter”
Pandoc defaults files do **not** support `lua-filter:`. This pipeline uses:

```yaml
filters:
  - epub-fiction-fix.lua
```

### Duplicate ToC / “Contents” pages show up in output
This is typically the EPUB’s internal nav/ToC content being converted. The Lua filter strips many common patterns; if one slips through, enable debug and inspect where it happens:

```bash
pandoc "Book.epub" -d novel --metadata debug_fiction_filter=true -o "Book.tex" 2> debug.log
```

### Lots of undefined references / hyperref warnings (endnotes)
Turn on:

```yaml
convert_endnotes: true
```

(or `--metadata convert_endnotes=true`)

### Weird chapters like single punctuation / ornament-only headings
Try:
- keep `allow_all_caps_chapters: false`
- enable debug logging to see what text was promoted

---

## Development / extending the heuristics

If you want to iterate quickly on filter rules:

1. Generate LaTeX normally.
2. If structure is wrong, re-run with debug enabled and capture stderr.
3. Adjust pattern matchers in the Lua file (most rules are intentionally “opt-in” via metadata knobs).
4. Keep a small regression set of EPUBs that represent different “families” (novels, anthologies, Calibre exports, etc.).

---

## License / usage

This is a personal pipeline bundle intended for EPUB→LaTeX conversion workflows. If you publish it publicly, include attribution and make sure your input texts are legally licensed for conversion/use.

