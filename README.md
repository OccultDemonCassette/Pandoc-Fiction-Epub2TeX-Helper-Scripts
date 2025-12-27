# pandoc-fiction-setup

A small, opinionated Pandoc “pipeline” for converting **fiction EPUBs** into **Memoir-class LaTeX** that already looks close to a publishable novel layout.

This setup is designed for EPUBs that:
- contain **in-book “Table of Contents”** pages (navigation lists) you *don’t* want in the body, and/or
- use **“faux headings”** (styled paragraphs) instead of real HTML headings for Books/Chapters/Sections.

It produces LaTeX with a consistent memoir-based preamble and tries to infer:

**part → foreword chapter → main chapters → sections (if present)**

---

## What’s included

| File | Purpose |
|---|---|
| `novel.yaml` | Pandoc **defaults file** (wires everything together). |
| `fiction-template.tex` | Pandoc **LaTeX template** (Memoir class + styling + environments). |
| `epub-fiction-fix.lua` | Pandoc **Lua filter** (structure inference + cleanup). |

---

## What it does

### Output styling (Template)
`fiction-template.tex`:
- Uses the `memoir` class
- Applies a centered large `\chapterstyle{bigcenter}`
- Styles `\part` pages as clean “Book title” pages
- Adds frontmatter: `\frontmatter`, `\maketitle`, `\tableofcontents`, `\mainmatter`
- Provides helper environments:
  - `\scenebreak`
  - `tabletcurse`, `objecttext`, `inscription`, etc.

### Structure inference & cleanup (Lua filter)
`epub-fiction-fix.lua` tries to:
- **Remove** in-book EPUB navigation / ToC lists (the linky lists that otherwise become `enumerate` + `\hyperref[...]` blocks).
- Convert common EPUB patterns into real division headers:
  - Book/part title pages → `Header(1)` → `\part{...}`
  - Chapter markers like `1. TITLE`, `CHAPTER IV: TITLE` → `Header(2)` → `\chapter{...}`
  - Section markers like `1 FLUTIC` → `Header(3)` → `\section{...}`
- Convert scene breaks like `***`, `* * *`, `⁂` into `\scenebreak`
- Convert “inscription:” blocks into a `tabletcurse` environment
- Drop images by default (covers/ornaments). *(You can change this if you want images.)*

---

## Requirements

### Pandoc
- Pandoc **3.x** with Lua enabled.
- Verify with:

```bat
pandoc --version
```

You should see something like:
- `Features: +lua`
- A `User data directory: ...` line

### LaTeX (for compiling the `.tex`)
If you plan to compile to PDF, you’ll need:
- A TeX distribution: **MiKTeX** or **TeX Live**
- `memoir` class installed (it’s common and usually included)
- XeLaTeX recommended (this setup is XeLaTeX-friendly)

> Note: This setup focuses on producing clean **.tex**. Compiling to PDF is optional.

---

## Installation (Windows)

Pandoc has a “user data directory” where it finds defaults/templates/filters automatically.

Check yours:

```bat
pandoc --version
```

Example:

```
User data directory: C:\Users\{YOUR_USERNAME_HERE}\AppData\Roaming\pandoc
```

### Option A (Recommended): Install globally in the Pandoc user data directory

Create these folders if they don’t exist:

- `%APPDATA%\pandoc\defaults\`
- `%APPDATA%\pandoc\templates\`
- `%APPDATA%\pandoc\filters\`

Copy files to:

- `%APPDATA%\pandoc\defaults\novel.yaml`
- `%APPDATA%\pandoc\templates\fiction-template.tex`
- `%APPDATA%\pandoc\filters\epub-fiction-fix.lua`

### Option B: Portable / per-project install

Put all three files in your project folder (next to your EPUB), and run with an explicit defaults path, e.g.:

```bat
pandoc "Book.epub" -d ".\novel.yaml" -o "Book.tex"
```

If you use this mode, ensure `novel.yaml` references the filter using a path that resolves from your working directory (e.g., `epub-fiction-fix.lua` in the same folder).

---

## Usage

### Basic: EPUB → TeX

If installed globally as `novel.yaml` in `%APPDATA%\pandoc\defaults\`:

```bat
pandoc "Input_File.epub" -d novel -o "Output.tex"
```

(You can also use `-d novel.yaml`; both commonly work, depending on Pandoc version/config.)

### Output folder with extracted media

`novel.yaml` uses:

```yaml
extract-media: ./images
```

So you’ll typically get:

```
Output.tex
images/...
```

### Compile the TeX (optional)

From the same folder:

```bat
xelatex "Output.tex"
xelatex "Output.tex"
```

(Run twice for ToC/hyperlinks to settle.)

---

## Configuration knobs

### Table of Contents depth (`tocdepth`)
The template supports a metadata variable `tocdepth` that maps to LaTeX’s `\setcounter{tocdepth}{...}`.

Common values:

- `-1` → parts only
- `0`  → parts + chapters (recommended for novels)
- `1`  → include sections
- `2`  → include subsections

#### Set it permanently in `novel.yaml`
Uncomment/edit:

```yaml
# metadata:
#   tocdepth: 0
```

Becomes:

```yaml
metadata:
  tocdepth: 0
```

#### Or override on the command line
(Does not require editing `novel.yaml`.)

```bat
pandoc "Book.epub" -d novel -M tocdepth=1 -o "Book.tex"
```

---

## What “formatted like this” means (compatibility)

This setup works best when the EPUB has patterns like:

- Book titles as a short standalone line, often followed by a horizontal rule
- Chapters as lines like `1. TITLE` or `CHAPTER IV: TITLE`
- Subsections as numeric+caps lines like `1 FLUTIC`
- In-book ToCs represented as nested link lists (Pandoc turns them into `\hyperref` lists)

If an EPUB uses *real* HTML headings (`<h1>`, `<h2>`) consistently, Pandoc may already do a good job—this filter should still help with ToC removal and cleanup, but you might not need as much inference.

---

## Troubleshooting

### “Aeson exception: Unknown option lua-filter”
Defaults files use:

```yaml
filters:
  - epub-fiction-fix.lua
```

Not `lua-filter:`.

### Pandoc can’t find the Lua filter
Quick test (absolute path):

```bat
pandoc "Book.epub" --lua-filter "%APPDATA%\pandoc\filters\epub-fiction-fix.lua" -o test.tex
```

If that works but `-d novel` doesn’t, the filter path in `novel.yaml` is wrong (or you placed the filter outside the user data directory).

### The output still contains a big hyperlink ToC list in the body
That’s almost always the EPUB’s internal nav page. The filter removes common patterns, but some publishers format nav pages differently.

Fix: share a short excerpt (20–60 lines) of the “linky list” section; it’s usually a small pattern tweak.

### Chapters/parts are wrong
EPUBs vary wildly. If a “Book” doesn’t become a `\part`, or a chapter isn’t detected, it typically means the EPUB uses a different pattern.

Fix: share a snippet around where it should have been detected (before/after the heading). The Lua filter is designed to be extended with extra patterns.

### You want images kept
The Lua filter currently drops images by walking blocks and removing `Image` elements. If you want images:
- Remove (or comment out) the `Image = function(_) return {} end` part in the Lua filter.

---

## Customizing your “house style”

Most of your visual preferences live in `fiction-template.tex`:
- margins
- fonts
- chapter/part styling
- environments like `tabletcurse` / `objecttext`
- spacing rules

Most of the “EPUB cleanup” logic lives in `epub-fiction-fix.lua`:
- what counts as a `\part` / `\chapter` / `\section`
- what gets removed (in-book ToCs, ornament text)
- how inscriptions or scene breaks are handled

`novel.yaml` should stay relatively small; it’s just the glue.

---

## Suggested workflow

1) Run Pandoc to produce `.tex`
2) Skim:
   - ToC looks right?
   - Parts/Chapters correct?
   - Scene breaks / inscriptions reasonable?
3) If the structure is wrong, tweak the Lua filter (usually small).
4) If the look is wrong, tweak the template.

---

## License / notes
This is a personal conversion pipeline. Feel free to modify the files for your library of EPUBs—there’s no single “one size fits all” for EPUB structure.
