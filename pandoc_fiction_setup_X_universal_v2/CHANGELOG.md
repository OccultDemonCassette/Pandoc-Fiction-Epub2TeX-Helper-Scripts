# Changelog

All notable changes to this fiction conversion pipeline will be documented in this file.

This changelog follows the spirit of **Keep a Changelog** (but is lightweight and practical).

---

## [v2] - 2025-12-27

### Added
- **Debug mode**: `debug_fiction_filter` metadata knob; logs filter decisions to stderr.
- **Frontmatter pruning knobs**:
  - `drop_frontmatter_marketing`
  - `drop_copyright_blocks`
  - `drop_other_books_lists`
  - `drop_about_author`
- **Anthology byline support**: `author_line_allows_by_prefix` (e.g., “by NAME” → section author name).
- **Header role override**: `header_h1_role: auto|part|chapter` (rare manual override).

### Improved
- Better **anthology structure inference** (story title → chapter; author byline → section).
- More conservative **false heading** rejection (ornaments, nav junk).
- **Scene break normalization** (asterisms and many EPUB `<hr/>` patterns map to `\scenebreak`).
- More robust handling of common front/back matter headings (preface/foreword/acknowledgements/etc.).

---

## [v1] - 2025-12 (initial “universal” line)

### Added
- Memoir-based `fiction-template.tex` with `\scenebreak` and `tabletcurse`.
- `novel.yaml` defaults wiring for one-command conversion (`pandoc -d novel`).
- Lua filter:
  - in-book ToC/nav removal
  - part/chapter/section inference
  - POV marker → section promotion (opt-in)
  - optional endnotes → footnotes conversion (`convert_endnotes`)
  - backmatter marketing cutoff (`drop_marketing`)
  - tighter chapter inference to prevent garbage headings

