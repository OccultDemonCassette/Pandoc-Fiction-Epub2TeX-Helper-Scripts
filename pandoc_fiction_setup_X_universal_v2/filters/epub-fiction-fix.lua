-- epub-fiction-fix.lua
--
-- Opinionated cleanup for "fiction-style" EPUBs -> LaTeX (memoir).
--
-- Goals:
--   • Strip in-book ToC / navigation junk (you generate the real ToC via template).
--   • Promote faux headings to real divisions:
--       Header(1) -> \part
--       Header(2) -> \chapter
--       Header(3) -> \section
--     (works best with --top-level-division=part).
--   • Convert asterisms ("* * *", "***", etc.) into \scenebreak.
--   • Convert inscription blocks into a memoir-friendly tabletcurse environment.
--   • Optional: convert EPUB endnote hyperlinks into *real* LaTeX footnotes:
--       metadata:
--         convert_endnotes: true
--
-- This filter is conservative by design: it avoids turning dialogue / random short
-- lines into chapters, and it ignores external URL-only paragraphs.

local stringify = pandoc.utils.stringify

-- ---------- helpers ----------
local function normalize_ws(s)
  if not s then return "" end
  local t = s
  -- NBSP and friends (UTF-8 byte sequences)
  t = t:gsub("\194\160", " ")      -- U+00A0 NO-BREAK SPACE
  t = t:gsub("\226\128\175", " ")  -- U+202F NARROW NO-BREAK SPACE
  t = t:gsub("\226\128\168", " ")  -- U+2028 LINE SEPARATOR
  t = t:gsub("\226\128\169", " ")  -- U+2029 PARAGRAPH SEPARATOR
  t = t:gsub("\226\128\139", "")   -- U+200B ZERO WIDTH SPACE
  t = t:gsub("\226\128\140", "")   -- U+200C ZERO WIDTH NON-JOINER
  t = t:gsub("\226\128\141", "")   -- U+200D ZERO WIDTH JOINER
  t = t:gsub("\239\187\191", "")   -- UTF-8 BOM
  return t
end

local function trim(s)
  s = normalize_ws(s or "")
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function squash(s)
  s = normalize_ws(s or "")
  return trim(s:gsub("%s+", " "))
end

local function lower(s)
  return (s or ""):lower()
end

local function has_letters(s)
  return (s or ""):match("%a") ~= nil
end

local function letters_count(s)
  local only = (s or ""):gsub("[^%a]", "")
  return #only
end

local function strip_double_braces(s)
  local t = squash(s)
  local inner = t:match("^%{%{(.+)%}%}$")
  if inner then return squash(inner) end
  return t
end

local function meta_bool(meta, key, default)
  local v = meta[key]
  if v == nil then return default end
  if type(v) == "boolean" then return v end
  local sv = lower(stringify(v))
  if sv == "true" or sv == "yes" or sv == "1" then return true end
  if sv == "false" or sv == "no" or sv == "0" then return false end
  return default
end

local function normalize_anchor(href)
  if not href or href == "" then return nil end
  local h = href
  h = h:gsub("^%./", "")
  h = h:gsub("^#", "")
  h = h:gsub("^#", "")
  return h
end

local function sanitize_id(id)
  local s = id or ""
  -- '#' in identifiers causes nasty escaping in older pandoc.
  s = s:gsub("#", "_")
  -- Spaces are invalid ids too.
  s = s:gsub("%s+", "_")
  return s
end

local function is_toc_title_text(s)
  local t = lower(squash(s))
  return t == "table of contents" or t == "contents"
end

local function is_notes_title_text(s)
  local t = lower(squash(s))
  return t == "notes" or t == "endnotes" or t == "glossary" or t == "notes and references"
end

local function is_scene_break_text(s)
  local t = squash(s)
  if t == "***" or t == "* * *" or t == "⁂" or t == "❦" then return true end
  if #t <= 12 and t:match("^[%*%s%._~%-–—•·⋆⁂❦]+$") then return true end
  return false
end

-- Identify file markers produced by Pandoc from split EPUBs:
-- Para [ Span ( "chapter06.xhtml" , [] , [] ) [] ]
local function file_marker_from_block(block)
  if block.t == "Div" and block.attr and block.attr.identifier and block.attr.identifier ~= "" then
    local id = block.attr.identifier
    for _, c in ipairs(block.attr.classes or {}) do
      if c == "_filemarker" then return id end
    end
    local f = id:match("^([^#]+%.x?html)$") or id:match("^([^#]+%.x?html)")
    if f then return f end
  end

  if block.t == "Para" or block.t == "Plain" then
    for _, il in ipairs(block.content) do
      if il.t == "Span" and il.identifier and il.identifier:match("%.x?html$") then
        return il.identifier
      end
    end
  end
  return nil
end

-- Drop images (covers, ornaments)
local function drop_images(block)
  return pandoc.walk_block(block, { Image = function(_) return {} end })
end


-- ---------- Calibre/EPUB normalization ----------

local function file_from_identifier(id)
  if not id or id == "" then return nil end
  return id:match("^([^#]+%.x?html)")
end

local function make_file_marker(file)
  return pandoc.Div({}, pandoc.Attr(file, {"_filemarker"}, {}))
end

local function is_pagebreak_div(div)
  if not div or div.t ~= "Div" then return false end
  local attr = div.attr or pandoc.Attr()
  for _, c in ipairs(attr.classes or {}) do
    if c == "mbp_pagebreak" or c == "pagebreak" then return true end
  end
  local id = attr.identifier or ""
  if id:match("calibre_pb_%d+") then return true end
  return false
end

-- Flatten Div-heavy Calibre EPUBs so inference can see the real paragraphs.
local function flatten_blocks(blocks)
  local out = {}

  local function walk(b)
    if not b then return end
    if b.t == "Div" then
      local attr = b.attr or pandoc.Attr()
      local fid = file_from_identifier(attr.identifier or "")
      if fid then table.insert(out, make_file_marker(fid)) end

      -- Drop Kindle/Calibre pagebreak markers entirely (they create ugly \hfill\break in LaTeX).
      if is_pagebreak_div(b) and (not b.content or #b.content == 0) then
        return
      end

      for _, cb in ipairs(b.content or {}) do
        walk(cb)
      end
      return
    end

    table.insert(out, b)
  end

  for _, b in ipairs(blocks or {}) do
    walk(b)
  end
  return out
end

-- Remove style-only Span wrappers produced by Calibre (reduces {{{ ... }}} noise).
local function unwrap_style_spans(block)
  return pandoc.walk_block(block, {
    Span = function(sp)
      local id = sp.identifier or ""
      if id ~= "" then return sp end
      local attrs = sp.attributes or {}
      for _k, _v in pairs(attrs) do
        return sp
      end
      local classes = sp.classes or {}
      if #classes == 0 then return sp.content end

      local is_style_only = true
      local has_bold = false
      local has_italic = false

      for _, c in ipairs(classes) do
        if c == "bold" then has_bold = true
        elseif c == "italic" or c == "italics" then has_italic = true
        elseif c:match("^calibre") or c == "underline" then
          -- style-only wrappers
        else
          is_style_only = false
        end
      end

      if has_bold and has_italic then
        return pandoc.Strong({ pandoc.Emph(sp.content) })
      elseif has_bold then
        return pandoc.Strong(sp.content)
      elseif has_italic then
        return pandoc.Emph(sp.content)
      elseif is_style_only then
        return sp.content
      else
        return sp
      end
    end
  })
end

local function block_is_blankish(block)
  if block.t ~= "Para" and block.t ~= "Plain" then return false end
  local t = squash(stringify(block))
  if t == "" then return true end
  if #t <= 6 and t:match("^[~%s%p]+$") then return true end
  return false
end


-- ---------- nav / ToC detection ----------

-- ---------- global knobs (set from metadata in Pandoc(doc)) ----------
local debug_fiction_filter = false
local author_line_allows_by_prefix = false

local function dbg(msg)
  if debug_fiction_filter then
    io.stderr:write('[epub-fiction-fix] ' .. tostring(msg) .. '\n')
  end
end

-- Common spelled-out ordinals used in parts/chapters
local WORD_NUM = {
  one=true, two=true, three=true, four=true, five=true, six=true, seven=true, eight=true, nine=true, ten=true,
  eleven=true, twelve=true, thirteen=true, fourteen=true, fifteen=true, sixteen=true, seventeen=true, eighteen=true, nineteen=true, twenty=true,
}

local function clean_author_line(s)
  local t = strip_double_braces(squash(s or ''))
  if author_line_allows_by_prefix then
    t = t:gsub('^[Bb][Yy]%s+', '')
  end
  return t
end
local function block_has_internal_link(block)
  local found = false
  pandoc.walk_block(block, {
    Link = function(l)
      local t = l.target or ""
      if t:match("^#")
        or t:match("^index_split_%d+%.html")
        or t:match("%.x?html")
        or t:match("filepos%d+")
      then
        found = true
      end
      return l
    end
  })
  return found
end

local function list_is_nav(block)
  if block.t ~= "BulletList" and block.t ~= "OrderedList" then return false end
  local items = block.content
  if not items or #items < 4 then return false end
  for _, item in ipairs(items) do
    if #item < 1 then return false end
    local first = item[1]
    if not (first.t == "Para" or first.t == "Plain") then return false end
    if not block_has_internal_link(first) then return false end
  end
  return true
end

local function quote_is_nav(block)
  if block.t ~= "BlockQuote" then return false end
  for _, b in ipairs(block.content) do
    if list_is_nav(b) then return true end
    if (b.t == "Para" or b.t == "Plain") and block_has_internal_link(b) then return true end
  end
  return false
end

-- Parse list-item -> first link (title + target)
local function first_link_in_blocks(blocks)
  for _, b in ipairs(blocks) do
    if b.t == "Para" or b.t == "Plain" then
      for _, il in ipairs(b.content) do
        if il.t == "Link" then
          local title = strip_double_braces(squash(stringify(il.content)))
          local target = normalize_anchor(il.target)
          return title, target
        end
      end
    end
  end
  return nil, nil
end

local function get_child_list(blocks)
  for _, b in ipairs(blocks) do
    if b.t == "BulletList" or b.t == "OrderedList" then
      return b
    end
  end
  return nil
end

-- Extract ToC structure from an in-book ToC page.
-- Supports:
--   (1) nested list ToCs
--   (2) paragraph ToCs: a run of paras each containing a single internal link
-- Returns:
--   toc_map[anchor] = { level = 2|3, title = "..." }
local function extract_toc_maps(blocks)
  local toc_start = nil
  for i, b in ipairs(blocks) do
    if (b.t == "Para" or b.t == "Plain") and is_toc_title_text(stringify(b)) then
      toc_start = i
      break
    elseif b.t == "Header" and is_toc_title_text(stringify(b.content)) then
      toc_start = i
      break
    end
  end
  if not toc_start then return {}, {} end

  local toc_map = {}
  local section_titles_by_chapter = {}
  local non_toc_streak = 0

  for i = toc_start + 1, math.min(#blocks, toc_start + 800) do
    local b = blocks[i]

    -- Stop if we hit a new file marker (content begins)
    local fm = file_marker_from_block(b)
    if fm and not fm:match("contents%.xhtml$") and not fm:match("toc%.xhtml$") then
      break
    end

    if b.t == "OrderedList" or b.t == "BulletList" then
      non_toc_streak = 0
      for _, item in ipairs(b.content or {}) do
        local title, target = first_link_in_blocks(item)
        if title and target then
          if not toc_map[target] then
            toc_map[target] = { level = 2, title = title }
          end

          local child_list = get_child_list(item)
          if child_list then
            section_titles_by_chapter[title] = {}
            local idx = 0
            for _, citem in ipairs(child_list.content or {}) do
              local ctitle, ctarget = first_link_in_blocks(citem)
              if ctitle and ctarget then
                idx = idx + 1
                toc_map[ctarget] = { level = 3, title = ctitle, prefix = tostring(idx) .. ": ", parent = title }
                table.insert(section_titles_by_chapter[title], ctitle)
              end
            end
          end
        end
      end

    elseif b.t == "Para" or b.t == "Plain" then
      local links = {}
      for _, il in ipairs(b.content) do
        if il.t == "Link" then table.insert(links, il) end
      end

      if #links == 1 then
        non_toc_streak = 0
        local l = links[1]
        local target = normalize_anchor(l.target)
        local title = strip_double_braces(squash(stringify(l.content)))
        if target and title ~= "" then
          if not toc_map[target] then
            toc_map[target] = { level = 2, title = title }
          else
            -- Duplicate target: keep the more informative one.
            local cur = toc_map[target].title or ""
            local tlo = lower(title)
            local clo = lower(cur)
            local title_is_authorline = tlo:match("^by%s") or tlo:match("%sby%s")
            local cur_is_authorline = clo:match("^by%s") or clo:match("%sby%s")
            if cur_is_authorline and not title_is_authorline then
              toc_map[target].title = title
            elseif #title > #cur and not title_is_authorline then
              toc_map[target].title = title
            end
          end
        end

      else
        local t = squash(stringify(b))
        non_toc_streak = non_toc_streak + ((#t <= 120) and 1 or 2)
        if non_toc_streak >= 8 then break end
      end

    else
      non_toc_streak = non_toc_streak + 1
      if non_toc_streak >= 8 then break end
    end
  end

  return toc_map, section_titles_by_chapter
end

-- ---------- structure inference ----------
local function looks_like_part_title(blocks, i)
  local b, n = blocks[i], blocks[i + 1]
  if not b or not n then return false end
  if not (b.t == "Para" or b.t == "Plain") then return false end
  if n.t ~= "HorizontalRule" then return false end

  local t = strip_double_braces(stringify(b))
  if #t > 80 then return false end
  if not has_letters(t) then return false end
  if is_toc_title_text(t) or is_notes_title_text(t) then return false end
  if t:match("^%s*[%-%–—]+") then return false end
  -- Reject obvious prose lines: punctuation + many lowercase words.
  if t:match("[%.%!%?%,:;]") then return false end

  local words, caps = 0, 0
  for w in t:gmatch("%S+") do
    local ww = w:gsub("[^%a]", "")
    if ww ~= "" then
      words = words + 1
      local first = ww:sub(1,1)
      if first:match("%u") then caps = caps + 1 end
    end
  end
  if words == 0 or words > 8 then return false end
  if words == 1 then return true end
  if caps < 2 then return false end
  if (caps / words) < 0.45 then return false end
  return true
end

local function looks_like_part_number_line_text(s)
  local t = lower(strip_double_braces(squash(s)))
  -- "Part 1:" / "Part One" / "PART I." / "Book Two"
  local w = t:match("^part%s+([%a]+)[%:%.-]?$" )
  if w and WORD_NUM[w] then return true end
  w = t:match("^book%s+([%a]+)[%:%.-]?$" )
  if w and WORD_NUM[w] then return true end
  return t:match("^part%s+%d+[%:%.-]?$" ) ~= nil
      or t:match("^book%s+%d+[%:%.-]?$" ) ~= nil
      or t:match("^part%s+[ivxlcdm]+[%:%.-]?$" ) ~= nil
      or t:match("^book%s+[ivxlcdm]+[%:%.-]?$" ) ~= nil
end



local function part_title_from_single_line_text(s)
  local t = strip_double_braces(squash(s))
  if t == "" or #t > 160 then return nil end
  if not has_letters(t) then return nil end
  if is_toc_title_text(t) or is_notes_title_text(t) then return nil end
  -- "Part 3: Title" / "Part One: Title" / "Book IV. Title"
  local tok, rest = t:match("^[Pp][Aa][Rr][Tt]%s+([%w]+)%s*[:%.%-]%s*(.+)$")
  if tok and rest and rest ~= "" then
    local tl = lower(tok)
    if tok:match("^%d+$") or tok:match("^[IVXLCDMivxlcdm]+$") or WORD_NUM[tl] then
      local tt = squash(rest)
      if #tt > 0 and #tt <= 120 and has_letters(tt) then return tt end
    end
  end
  tok, rest = t:match("^[Bb][Oo][Oo][Kk]%s+([%w]+)%s*[:%.%-]%s*(.+)$")
  if tok and rest and rest ~= "" then
    local tl = lower(tok)
    if tok:match("^%d+$") or tok:match("^[IVXLCDMivxlcdm]+$") or WORD_NUM[tl] then
      local tt = squash(rest)
      if #tt > 0 and #tt <= 120 and has_letters(tt) then return tt end
    end
  end
  return nil
end
local function looks_like_part_number_then_title(blocks, i)
  local b, n = blocks[i], blocks[i + 1]
  if not b or not n then return false end
  if not (b.t == "Para" or b.t == "Plain") then return false end
  if not (n.t == "Para" or n.t == "Plain") then return false end

  local t1 = strip_double_braces(squash(stringify(b)))
  local t2 = strip_double_braces(squash(stringify(n)))

  if not looks_like_part_number_line_text(t1) then return false end
  if t2 == "" or #t2 > 120 then return false end
  if not has_letters(t2) then return false end
  if is_toc_title_text(t2) or is_notes_title_text(t2) then return false end
  return true
end

-- "Book Title" immediately followed by Foreword/Preface/Introduction/...

local function looks_like_part_before_preface(blocks, i)
  local b, n = blocks[i], blocks[i + 1]
  if not b or not n then return false end
  if not (b.t == "Para" or b.t == "Plain") then return false end
  if not (n.t == "Para" or n.t == "Plain") then return false end

  local t1 = strip_double_braces(squash(stringify(b)))
  local t2 = strip_double_braces(squash(stringify(n)))
  if #t1 == 0 or #t1 > 80 then return false end
  if not has_letters(t1) then return false end
  if is_toc_title_text(t1) or is_notes_title_text(t1) then return false end

  local marker = lower(t2):gsub("[^%a]", "")
  return marker == "foreword" or marker == "preface" or marker == "introduction"
     or marker == "prologue" or marker == "afterword" or marker == "acknowledgements"
     or marker == "acknowledgments"
end

local function chapter_title_from_text(s, opts)
  local t = strip_double_braces(squash(s))
  if t == "" or not has_letters(t) then return nil end

  -- Reject dialogue / quoted lines
  if t:match("^[`\"'‘’“”]") then return nil end
  if t:match("[`\"'‘’“”]$") and #t < 80 then return nil end

  -- Reject definition-like lines (endnotes/glossary) like "term: definition",
  -- but allow common front/back matter headings like "Acknowledgements:".
  local def = t:match("^([%w][%w%-]+):%s*")
  if def then
    local dm = lower(def):gsub("[^%a]", "")
    if dm ~= "acknowledgements" and dm ~= "acknowledgments"
       and dm ~= "foreword" and dm ~= "preface" and dm ~= "introduction"
       and dm ~= "dedication" and dm ~= "copyright" then
      return nil
    end
  end

  local tlo = lower(t)
  if tlo == "notes" or tlo == "endnotes" then return nil end
  if tlo:match("^by%s") or tlo:match("%sby%s") then return nil end

  -- Bare numeric / Roman / word-number chapter markers (common in some EPUBs)
  if t:match("^%d+$") and #t <= 4 then return t end
  if t:match("^[IVXLCDM]+$") and #t <= 8 and t ~= "I" then return t end
  if WORD_NUM[tlo] then return t end

  -- "1. TITLE"
  local rest = t:match("^%d+%.%s*(.+)$")
  if rest and rest ~= "" then return squash(rest) end

  -- "CHAPTER IV: TITLE" or "CHAPTER IV TITLE"
  local rest2 = t:match("^[Cc][Hh][Aa][Pp][Tt][Ee][Rr]%s+[%w%.]+%s*[:%-%–]?%s*(.+)$")
  if rest2 and rest2 ~= "" then return squash(rest2) end

  -- single-word markers
  if tlo == "prologue" or tlo == "epilogue" or tlo == "afterword"
     or tlo == "foreword" or tlo == "preface" or tlo == "introduction" or tlo == "acknowledgements" or tlo == "acknowledgments" or tlo == "dedication" or tlo == "copyright" then
    return t
  end

  -- If the line ends with ":" and it looks like a known division heading, accept it.
  if t:match(":%s*$") then
    local base = squash(t:gsub(":%s*$", ""))
    local bm = lower(base):gsub("[^%a]", "")
    if bm == "acknowledgements" or bm == "acknowledgments"
       or bm == "foreword" or bm == "preface" or bm == "introduction"
       or bm == "dedication" or bm == "copyright"
       or bm == "prologue" or bm == "epilogue" or bm == "afterword" then
      return base
    end
    if lower(base):match("afterword") then
      return base
    end
  end

  -- Optional ALL-CAPS chapter titles (off by default; can create false positives)
  local allow_caps = opts and opts.allow_all_caps_chapters
  if allow_caps then
    -- Require MULTI-WORD all-caps (prevents DNA strings / single-name POV dividers)
    local tclean = squash(t)
    if #tclean <= 80
       and tclean == tclean:upper()
       and letters_count(tclean) >= 4
       and tclean:match("%s")
       and not tclean:match("%d") then
      if not tclean:match("[^%u%s]") then
        return tclean
      end
    end
  end

  return nil
end

local function section_title_from_text(s)
  local t = strip_double_braces(squash(s))
  if t == "" or not has_letters(t) then return nil end
  if t:match("^[`\"'‘’“”]") then return nil end

  local rest = t:match("^%d+%s+(.+)$")
  if rest and rest ~= "" then
    if rest == rest:upper() and letters_count(rest) >= 4 then
      return squash(rest)
    end
  end
  return nil
end

-- ---------- inscription/tablet blocks ----------
local function is_inscription_leadin_text(s)
  return lower(squash(s)):match("inscription%s*:") ~= nil
end

local function is_inscription_line_text(s)
  local t = strip_double_braces(squash(s))
  if t == "" then return false end
  if letters_count(t) < 6 then return false end
  if t:match("%l") then return false end
  return true
end



local function pov_title_from_text(s)
  local t = strip_double_braces(squash(s))
  if t == "" then return nil end
  if #t > 32 then return nil end
  if not has_letters(t) then return nil end
  if t:match("%l") then return nil end  -- must not contain lowercase
  if t:match("%d") then return nil end
  -- Strip trailing dashes (ASCII hyphen, en dash, em dash) or dots
  local base = t:gsub("[-–—%.]+$", "")
  base = squash(base)
  if base == "" then return nil end
  -- Avoid long single-token strings (e.g., DNA sequences): require <=2 words and at least one vowel
  local words = {}
  for w in base:gmatch("%S+") do table.insert(words, w) end
  if #words > 2 then return nil end
  if #words == 1 and #words[1] > 12 then return nil end
  if not lower(base):match("[aeiou]") then return nil end
  return base
end
-- ---------- anthology / titlepage heuristics ----------
local function normalize_key(s)
  local t = lower(strip_double_braces(squash(s or "")))
  t = t:gsub("[^%a%d]+", "")
  return t
end

local function looks_like_author_name(s)
  local t = strip_double_braces(squash(s or ""))
  if t == "" then return false end
  if #t > 60 then return false end
  if t:match("%d") then return false end
  local tl = lower(t)
  if tl:match("edited%s+by") then return false end
  if tl:match("%sby%s") then return false end
  if tl:match("^by%s") then
    if author_line_allows_by_prefix then
      t = t:gsub("^[Bb][Yy]%s+", "")
      tl = lower(t)
    else
      return false
    end
  end
  if not t:match("%s") then return false end
  local words = 0
  for _ in t:gmatch("%S+") do words = words + 1 end
  if words > 7 then return false end
  if letters_count(t) < 4 then return false end
  -- Allow letters, spaces, and common name punctuation.
  if t:gsub("[%a%.'’%-%s%&]", "") ~= "" then return false end
  return true
end

local function strong_only_text_from_block(b)
  if not b or not (b.t == "Para" or b.t == "Plain") then return nil end
  local parts = {}
  local saw = false
  for _, il in ipairs(b.content or {}) do
    if il.t == "Space" or il.t == "SoftBreak" or il.t == "LineBreak" then
      table.insert(parts, " ")
    elseif il.t == "Strong" then
      local s = strip_double_braces(squash(stringify(il.content)))
      if s ~= "" then
        saw = true
        table.insert(parts, s)
      end
    else
      return nil
    end
  end
  if not saw then return nil end
  local t = squash(table.concat(parts, " "))
  if t == "" then return nil end
  return t
end

local function looks_like_titlepage_heading(s, doc_title_norm)
  local t = strip_double_braces(squash(s or ""))
  if t == "" then return false end
  local nk = normalize_key(t)
  if doc_title_norm and doc_title_norm ~= "" and nk == doc_title_norm then return true end
  local tl = lower(t)
  if tl:match("^edited%s+by") then return true end
  if tl:match("^an%s+imprint%s+of") then return true end
  if tl:match("^original%s+speculative") then return true end
  return false
end

local function looks_like_explicit_part_header(s)
  local t = strip_double_braces(squash(s or ""))
  if t == "" then return false end
  if part_title_from_single_line_text(t) then return true end
  if looks_like_part_number_line_text(t) then return true end
  return false
end

local function infer_header1_role(blocks, opts)
  local h1, h2 = 0, 0
  local h1_partlike = 0
  local h1_chapterlike = 0
  local h2_authorlike, h2_chapterlike = 0, 0

  for _, b in ipairs(blocks or {}) do
    if b.t == "Header" then
      local title = strip_double_braces(squash(stringify(b.content)))
      if b.level == 1 then
        h1 = h1 + 1
        if looks_like_explicit_part_header(title) then h1_partlike = h1_partlike + 1 end
        -- If H1 itself looks like a chapter heading (e.g., CHAPTER 1, PROLOGUE, numeric, ALL CAPS), treat H1 as chapter-level.
        if chapter_title_from_text(title, { allow_all_caps_chapters = true }) then
          h1_chapterlike = h1_chapterlike + 1
        elseif title:match("^%s*%d+%s*$") then
          h1_chapterlike = h1_chapterlike + 1
        elseif title:match("^%s*[IVXLCDM]+%s*$") and #strip_double_braces(squash(title)) <= 8 then
          h1_chapterlike = h1_chapterlike + 1
        elseif title == title:upper() and title:match("%s") and letters_count(title) >= 4 and #title <= 90 then
          h1_chapterlike = h1_chapterlike + 1
        end
      elseif b.level == 2 then
        h2 = h2 + 1
        if looks_like_author_name(title) then h2_authorlike = h2_authorlike + 1 end
        if chapter_title_from_text(title, { allow_all_caps_chapters = true }) then
          h2_chapterlike = h2_chapterlike + 1
        elseif title == title:upper() and title:match("%s") and letters_count(title) >= 4 and #title <= 90 then
          h2_chapterlike = h2_chapterlike + 1
        end
      end
    end
  end

  if h1 == 0 then return "part" end
  if h1_partlike >= 1 then return "part" end
  if h1_partlike == 0 and h1_chapterlike >= 2 then return "chapter" end
  if h2_chapterlike >= 2 then return "part" end
  if h1 >= 4 and h2 == 0 then return "chapter" end
  if h1 >= 3 and h2 >= 2 and h2_authorlike >= math.max(2, h2_chapterlike + 1) then
    return "chapter"
  end
  if h1 >= 4 and h2 >= 4 and (h2_authorlike / h2) > 0.6 and h2_chapterlike == 0 then
    return "chapter"
  end
  return "part"
end

local function make_header(level, title, attr)
  return pandoc.Header(level, pandoc.Inlines{pandoc.Str(title)}, attr or pandoc.Attr())
end

-- ---------- endnote conversion ----------
local function extract_first_link(inlines)
  for idx, il in ipairs(inlines) do
    if il.t == "Link" then return il, idx end
    if il.t == "Emph" or il.t == "Strong" or il.t == "Span" then
      if #il.content == 1 and il.content[1].t == "Link" then
        return il.content[1], idx
      end
    end
  end
  return nil, nil
end

local function is_note_definition_block(block, current_file)
  if block.t ~= "Para" and block.t ~= "Plain" then return false end
  local l = extract_first_link(block.content)
  if not l then return false end

  local idn = normalize_anchor(l.identifier) or ""
  local key = idn
  if idn:match("^fn%d+$") and current_file then
    key = current_file .. "#" .. idn
  end
  if not key:match("#fn%d+$") and not key:match("^fn%d+$") then return false end

  -- must have colon
  for _, il in ipairs(block.content) do
    if il.t == "Str" and il.text == ":" then return true end
  end
  return false
end

local function build_endnote_map(blocks)
  local note_map = {}
  local current_file = nil

  for _, b in ipairs(blocks) do
    local fm = file_marker_from_block(b)
    if fm then current_file = fm end

    if drop_marketing and backmatter_started and (b.t == "Para" or b.t == "Plain") then
      if looks_like_marketing_start_text(stringify(b)) then
        break
      end
    end


    if b.t == "Para" or b.t == "Plain" then
      local l = extract_first_link(b.content)
      if l then
        local idn = normalize_anchor(l.identifier)
        if idn then
          local key = idn
          if idn:match("^fn%d+$") and current_file then
            key = current_file .. "#" .. idn
          end
          if key:match("#fn%d+$") or key:match("^fn%d+$") then
            local has_colon = false
            for _, il in ipairs(b.content) do
              if il.t == "Str" and il.text == ":" then has_colon = true; break end
            end
            if has_colon then
              local after, seen = {}, false
              for _, il in ipairs(b.content) do
                if not seen then
                  if il.t == "Str" and il.text == ":" then seen = true end
                else
                  table.insert(after, il)
                end
              end
              while #after > 0 and after[1].t == "Space" do table.remove(after, 1) end
              if #after > 0 then
                note_map[normalize_anchor(key)] = { pandoc.Para(after) }
              end
            end
          end
        end
      end
    end
  end

  return note_map
end

local function link_to_endnote(inline, note_map, current_file)
  if inline.t ~= "Link" then return inline end
  local tn = normalize_anchor(inline.target)
  if not tn then return inline end

  local key = tn
  if tn:match("^fn%d+$") and current_file then
    key = current_file .. "#" .. tn
  end
  key = normalize_anchor(key)

  local note = note_map[key]
  if not note then return inline end

  local out = {}
  for _, c in ipairs(inline.content) do table.insert(out, c) end
  table.insert(out, pandoc.Note(note))
  return out
end

-- ---------- main ----------
function Pandoc(doc)
  local blocks = flatten_blocks(doc.blocks)
  debug_fiction_filter = meta_bool(doc.meta, "debug_fiction_filter", false)
  author_line_allows_by_prefix = meta_bool(doc.meta, "author_line_allows_by_prefix", false)
  dbg("debug_fiction_filter=" .. tostring(debug_fiction_filter) .. ", author_line_allows_by_prefix=" .. tostring(author_line_allows_by_prefix))

  local convert_endnotes = meta_bool(doc.meta, "convert_endnotes", false)
  local drop_marketing = meta_bool(doc.meta, "drop_marketing", true)
  local drop_frontmatter_marketing = meta_bool(doc.meta, "drop_frontmatter_marketing", true)
  local drop_copyright_blocks = meta_bool(doc.meta, "drop_copyright_blocks", true)
  local drop_other_books_lists = meta_bool(doc.meta, "drop_other_books_lists", true)
  local drop_about_author = meta_bool(doc.meta, "drop_about_author", true)
  local allow_all_caps_chapters = meta_bool(doc.meta, "allow_all_caps_chapters", false)
  local promote_pov_sections = meta_bool(doc.meta, "promote_pov_sections", true)

  local doc_title_norm = ""
  if doc.meta and doc.meta.title then doc_title_norm = normalize_key(stringify(doc.meta.title)) end
  local header_h1_role = "auto"
  if doc.meta and doc.meta.header_h1_role then header_h1_role = lower(stringify(doc.meta.header_h1_role)) end
  local header1_role = infer_header1_role(blocks, { allow_all_caps_chapters = allow_all_caps_chapters })
  if header_h1_role == "part" or header_h1_role == "chapter" then header1_role = header_h1_role end



  local toc_map, toc_sections_by_chapter = extract_toc_maps(blocks)

  local endnote_map = {}
  if convert_endnotes then
    endnote_map = build_endnote_map(blocks)
  end

  local out = {}
  local i = 1
  local skipping_toc_page = false
  local current_chapter = nil
  local current_file = nil
  local mainmatter_started = false
  local just_started_chapter = false

  local function is_frontmatter_chapter(title)
    local m = lower((title or "")):gsub("[^%a]", "")
    return m == "foreword"
        or m == "preface"
        or m == "introduction"
        or m == "acknowledgements"
        or m == "acknowledgments"
        or m == "dedication"
        or m == "copyright"
        or m == "abouttheauthor"
        or m == "about"
  end

local function is_backmatter_chapter(title)
  local m = lower((title or "")):gsub("[^%a]", "")
  return m == "epilogue"
      or m == "notes"
      or m == "endnotes"
      or m:match("afterword") ~= nil
end

local function looks_like_marketing_start_text(s)
  local t = lower(strip_double_braces(squash(s or "")))
  if t == "" then return false end
  return t:match("^also by") ~= nil
      or t:match("^the latest novel") ~= nil
      or t:match("^more from") ~= nil
      or t:match("^about the author") ~= nil
      or t:match("^other books") ~= nil
      or t:match("^an unusual novella") ~= nil
end

  local function looks_like_other_books_heading(s)
    local t = lower(strip_double_braces(squash(s or "")))
    if t == "" then return false end
    return t:match("^also by") ~= nil
        or t:match("^other books") ~= nil
        or t:match("^more from") ~= nil
        or t:match("^books by") ~= nil
        or t:match("^from the author") ~= nil
        or t:match("^a note from") ~= nil
  end

  local function looks_like_about_author_heading(s)
    local t = lower(strip_double_braces(squash(s or "")))
    if t == "" then return false end
    return t:match("^about the author") ~= nil
        or t:match("^about%s+the%s+authors") ~= nil
  end

  local function looks_like_copyrightish_text(s)
    local t = lower(strip_double_braces(squash(s or "")))
    if t == "" then return false end
    if t:match("isbn") then return true end
    if t:match("all rights reserved") then return true end
    if t:match("copyright") then return true end
    if t:match("library of congress") then return true end
    if t:match("cataloging") and t:match("publication") then return true end
    if t:match("printed in") then return true end
    if t:match("first published") then return true end
    if t:match("edition") and t:match("%d%d%d%d") then return true end
    return false
  end

  local skipping_frontmatter = false
  local frontmatter_skip_guard = 0

  local function frontmatter_structural_start(block, idx)
    if block.t == "Header" then
      local title = strip_double_braces(squash(stringify(block.content)))
      if is_toc_title_text(title) then return false end
      if looks_like_other_books_heading(title) or looks_like_about_author_heading(title) then return false end
      if looks_like_titlepage_heading(title, doc_title_norm) then return false end
      return true
    end
    if block.t == "Para" or block.t == "Plain" then
      local t = strip_double_braces(squash(stringify(block)))
      if chapter_title_from_text(t, { allow_all_caps_chapters = true }) then return true end
      if part_title_from_single_line_text(t) then return true end
      if looks_like_part_number_then_title(blocks, idx) then return true end
      if looks_like_part_title(blocks, idx) then return true end
    end
    return false
  end

  local function ensure_mainmatter()
    if not mainmatter_started then
      table.insert(out, pandoc.RawBlock("latex", "\\mainmatter"))
      dbg("inserted \\mainmatter")
      mainmatter_started = true
    end
  end

  local backmatter_started = false
  local function ensure_backmatter()
    ensure_mainmatter()
    if not backmatter_started then
      table.insert(out, pandoc.RawBlock("latex", "\\backmatter"))
      dbg("inserted \\backmatter")
      backmatter_started = true
    end
  end

  while i <= #blocks do
    local b = drop_images(blocks[i])
    b = unwrap_style_spans(b)

    local fm = file_marker_from_block(b)
    if fm then current_file = fm end

    if drop_marketing and backmatter_started and (b.t == "Para" or b.t == "Plain") then
      if looks_like_marketing_start_text(stringify(b)) then
        break
      end

    -- Optional frontmatter junk pruning (copyright / other-books lists / about-author)
    if not mainmatter_started then
      if skipping_frontmatter then
        frontmatter_skip_guard = frontmatter_skip_guard + 1
        if frontmatter_skip_guard > 600 then
          skipping_frontmatter = false
        end
        if skipping_frontmatter and not frontmatter_structural_start(b, i) then
          i = i + 1
          goto continue
        else
          skipping_frontmatter = false
        end
      end

      if (b.t == "Para" or b.t == "Plain") then
        local bt = strip_double_braces(squash(stringify(b)))
        if drop_copyright_blocks and looks_like_copyrightish_text(bt) then
          dbg("drop frontmatter copyrightish: " .. bt:sub(1, 80))
          i = i + 1
          goto continue
        end
        if drop_other_books_lists and looks_like_other_books_heading(bt) then
          dbg("skip frontmatter other-books block: " .. bt:sub(1, 80))
          skipping_frontmatter = true
          frontmatter_skip_guard = 0
          i = i + 1
          goto continue
        end
        if drop_about_author and looks_like_about_author_heading(bt) then
          dbg("skip frontmatter about-author block: " .. bt:sub(1, 80))
          skipping_frontmatter = true
          frontmatter_skip_guard = 0
          i = i + 1
          goto continue
        end
        if drop_frontmatter_marketing and looks_like_marketing_start_text(bt) then
          dbg("skip frontmatter marketing block: " .. bt:sub(1, 80))
          skipping_frontmatter = true
          frontmatter_skip_guard = 0
          i = i + 1
          goto continue
        end
      elseif b.t == "Header" then
        local ht = strip_double_braces(squash(stringify(b.content)))
        if drop_other_books_lists and looks_like_other_books_heading(ht) then
          dbg("skip frontmatter other-books header: " .. ht:sub(1, 80))
          skipping_frontmatter = true
          frontmatter_skip_guard = 0
          i = i + 1
          goto continue
        end
        if drop_about_author and looks_like_about_author_heading(ht) then
          dbg("skip frontmatter about-author header: " .. ht:sub(1, 80))
          skipping_frontmatter = true
          frontmatter_skip_guard = 0
          i = i + 1
          goto continue
        end
      end
    end
    end


    -- Track "chapter start" so we can treat immediate author lines as sections in anthologies.
    if just_started_chapter then
      if b.t ~= "Header" and (b.t == "Para" or b.t == "Plain" or b.t == "BlockQuote") then
        local bt0 = strip_double_braces(squash(stringify(b)))
        if bt0 ~= "" and has_letters(bt0) and not is_scene_break_text(bt0) and not strong_only_text_from_block(b) then
          just_started_chapter = false
        end
      end
    end


    -- Internal file marker blocks: used for endnote disambiguation; never emit.
    if b.t == "Div" and b.attr and b.attr.classes then
      for _, c in ipairs(b.attr.classes) do
        if c == "_filemarker" then
          i = i + 1
          goto continue
        end
      end
    end

    -- Strip nav junk
    if list_is_nav(b) or quote_is_nav(b) then
      i = i + 1
      goto continue
    end

    -- Start skipping in-book ToC
    if (b.t == "Para" or b.t == "Plain") and is_toc_title_text(stringify(b)) then
      skipping_toc_page = true
      i = i + 1
      goto continue
    end
    if b.t == "Header" and is_toc_title_text(stringify(b.content)) then
      skipping_toc_page = true
      i = i + 1
      goto continue
    end

    if skipping_toc_page then
      local fm2 = file_marker_from_block(b)
      if fm2 and not fm2:match("contents%.xhtml$") and not fm2:match("toc%.xhtml$") then
        skipping_toc_page = false
        -- fall through
      else
        if b.t == "OrderedList" or b.t == "BulletList" or b.t == "BlockQuote" then
          i = i + 1; goto continue
        end
        if (b.t == "Para" or b.t == "Plain") then
          if block_has_internal_link(b) or #squash(stringify(b)) <= 120 then
            i = i + 1; goto continue
          end
        end
      end
    end

    -- Remap real EPUB headers into fiction divisions (\part/\chapter/\section).
    -- This fixes anthologies where story titles are H1 and author names are H2.
    if b.t == "Header" then
      local title = strip_double_braces(squash(stringify(b.content)))
      local lvl = b.level or 1

      -- Drop obvious titlepage/credit headings early (we rely on the template title/author).
      if not mainmatter_started and looks_like_titlepage_heading(title, doc_title_norm) then
        i = i + 1
        goto continue
      end

      -- H2-style part markers: "Part One" (H2) followed by the part title (H2).
      if lvl == 2 and looks_like_part_number_line_text(title) then
        local k = i + 1
        while k <= #blocks and block_is_blankish(unwrap_style_spans(drop_images(blocks[k]))) do
          k = k + 1
        end
        local nb = (k <= #blocks) and unwrap_style_spans(drop_images(blocks[k])) or nil
        if nb and nb.t == "Header" and nb.level == 2 then
          local title2 = strip_double_braces(squash(stringify(nb.content)))
          if title2 ~= "" and has_letters(title2) and not looks_like_author_name(title2) and not is_toc_title_text(title2) then
            ensure_mainmatter()
            dbg("promote H2 Part marker -> \\part: " .. title2)
            table.insert(out, make_header(1, title2, b.attr))
            current_chapter = nil
            just_started_chapter = false
            i = k + 1
            goto continue
          end
        end
      end

      -- Convert single-line "Part N: Title" headers into real parts (supports "Part One:").
      do
        local pt = part_title_from_single_line_text(title)
        if pt then
          title = pt
          lvl = 1
        end
      end

      -- If the book's H1s are really chapters (common in anthologies), demote them.
      if lvl == 1 and header1_role == "chapter" and not looks_like_explicit_part_header(title) then
        lvl = 2
      elseif lvl == 2 and header1_role == "chapter" then
        lvl = 3
      end

      -- In anthology mode, author headings sometimes appear as "by NAME"; clean them up when they become sections.
      if lvl == 3 then
        local cleaned = clean_author_line(title)
        if cleaned ~= title and looks_like_author_name(cleaned) then
          dbg("strip 'by' prefix in author section: " .. title .. " -> " .. cleaned)
          title = cleaned
        end

      end

      -- Promote "Part One" / "Book Two" markers to real parts.
      if lvl == 2 and looks_like_part_number_line_text(title) then
        ensure_mainmatter()
        dbg("promote Part marker -> \\part: " .. title)
        lvl = 1
      end


      -- Anthology/story-title pattern: if we just started a chapter and immediately see an author heading,
      -- treat it as a section under the current story instead of a new chapter.
      if lvl == 2 and just_started_chapter then
        local cleaned = clean_author_line(title)
        if looks_like_author_name(cleaned) then
          dbg("author header under story -> section: " .. title .. " -> " .. cleaned)
          title = cleaned
          lvl = 3
        end
      end
      -- Start main/back matter appropriately.
      if lvl <= 2 then
        if is_backmatter_chapter(title) then
          ensure_backmatter()
        elseif not is_frontmatter_chapter(title) then
          ensure_mainmatter()
        end
      end

      if lvl == 1 then
        current_chapter = nil
        just_started_chapter = false
      elseif lvl == 2 then
        current_chapter = title
        just_started_chapter = true
      end

      b.level = lvl
      b.content = pandoc.Inlines{pandoc.Str(title)}
      table.insert(out, b)
      i = i + 1
      goto continue
    end


    -- Horizontal rules in EPUBs are frequently used as scene breaks; normalize to \scenebreak.
    if b.t == "HorizontalRule" then
      if #out == 0 or not (out[#out].t == "RawBlock" and out[#out].text and out[#out].text:match("\\scenebreak")) then
        table.insert(out, pandoc.RawBlock("latex", "\\scenebreak"))
      end
      i = i + 1
      goto continue
    end
    -- Scene breaks that arrive wrapped in blockquotes (common in Calibre/KF8 EPUBs)
    if b.t == "BlockQuote" then
      local qt = squash(stringify(b))
      if is_scene_break_text(qt) then
        table.insert(out, pandoc.RawBlock("latex", "\\scenebreak"))
        i = i + 1
        goto continue
      end
      if qt == "" or qt:match("^~+$") then
        i = i + 1
        goto continue
      end
    end

    -- Scene breaks
    if (b.t == "Para" or b.t == "Plain") and is_scene_break_text(stringify(b)) then
      table.insert(out, pandoc.RawBlock("latex", "\\scenebreak"))
      i = i + 1
      goto continue
    end

    -- Drop blank/nbsp-only paragraphs
    if block_is_blankish(b) then
      i = i + 1
      goto continue
    end

    -- Inscription/tablet blocks
    if (b.t == "Para" or b.t == "Plain") and is_inscription_leadin_text(stringify(b)) then
      table.insert(out, b)
      local j = i + 1
      local lines = {}

      while j <= #blocks do
        local nb = blocks[j]
        if nb.t == "Para" or nb.t == "Plain" then
          local t = squash(stringify(nb))
          if is_scene_break_text(t) then
            table.insert(lines, ""); j = j + 1
          elseif is_inscription_line_text(t) then
            table.insert(lines, strip_double_braces(t)); j = j + 1
          else
            break
          end
        else
          break
        end
      end

      if #lines > 0 then
        local body = {"\\begin{tabletcurse}", ""}
        for _, ln in ipairs(lines) do
          if ln == "" then
            table.insert(body, "")
          else
            table.insert(body, "  " .. ln)
            table.insert(body, "")
          end
        end
        table.insert(body, "\\end{tabletcurse}")
        table.insert(out, pandoc.RawBlock("latex", table.concat(body, "\n")))
      end

      i = j
      goto continue
    end

    -- Remove endnote sections when converting
    if convert_endnotes and (b.t == "Para" or b.t == "Plain") then
      local bt = strip_double_braces(squash(stringify(b)))
      if is_notes_title_text(bt) then
        local nb = blocks[i + 1]
        if nb and is_note_definition_block(nb, current_file) then
          i = i + 1; goto continue
        end
      end
      if is_note_definition_block(b, current_file) then
        i = i + 1; goto continue
      end
    end

        -- PART inference ("Part 3: Title" on a single line)
    if not current_chapter and (b.t == "Para" or b.t == "Plain") then
      local pt = part_title_from_single_line_text(stringify(b))
      if pt then
        ensure_mainmatter()
        table.insert(out, make_header(1, pt, b.attr))
        current_chapter = nil
        i = i + 1
        goto continue
      end
    end

    -- PART inference ("Part 1:" / "Book 2:" on its own line, then a title line)
    if not current_chapter and looks_like_part_number_then_title(blocks, i) then
      ensure_mainmatter()
      local title = strip_double_braces(stringify(blocks[i + 1]))
      table.insert(out, make_header(1, title, b.attr))
      current_chapter = nil
      i = i + 2
      goto continue
    end

-- PART inference (title + horizontal rule)
    if not current_chapter and looks_like_part_title(blocks, i) then
      local title = strip_double_braces(stringify(b))
      ensure_mainmatter()
      table.insert(out, make_header(1, title, b.attr))
      current_chapter = nil
      i = i + 2 -- skip HorizontalRule
      goto continue
    end

    -- PART inference (title before Foreword/Preface/Introduction/etc.)
    if not current_chapter and looks_like_part_before_preface(blocks, i) then
      local title = strip_double_braces(stringify(b))
      ensure_mainmatter()
      table.insert(out, make_header(1, title, b.attr))
      current_chapter = nil
      i = i + 1
      goto continue
    end

    -- Promote link-only paragraph headings (common EPUB pattern):
    -- Para [ pagebreak Span? , Link(id=chapter01.xhtml#cha_1, target=#contents...) ]
    if b.t == "Para" or b.t == "Plain" then
      local pb_spans, links, nontrivial = {}, {}, 0
      for _, il in ipairs(b.content) do
        if il.t == "Span" and il.classes and (#il.classes > 0) and il.classes[1] == "pagebreak" then
          table.insert(pb_spans, il)
        elseif il.t == "Link" then
          table.insert(links, il); nontrivial = nontrivial + 1
        elseif il.t == "Space" then
          -- ignore
        else
          nontrivial = nontrivial + 1
        end
      end

      if #links == 1 and nontrivial == 1 then
        local l = links[1]
        local tgt = l.target or ""
        local raw_id = normalize_anchor(l.identifier)

        -- Reject URL-only lines and any link without a stable id
        if raw_id and raw_id ~= "" and not tgt:match("^https?://") and not tgt:match("^mailto:") then
          local idn = sanitize_id(raw_id)
          local title = strip_double_braces(squash(stringify(l.content)))

          -- Avoid promoting empty/author-line links
          local tlo = lower(title)
          if title ~= "" and has_letters(title) and not (tlo:match("^by%s") or tlo:match("%sby%s")) then
            local lvl = 2
            local entry = toc_map[normalize_anchor(l.target)] or toc_map[normalize_anchor(l.identifier)]
            if entry and entry.level then lvl = entry.level end

            if #pb_spans > 0 then table.insert(out, pandoc.Para(pb_spans)) end
            if lvl <= 2 and not is_frontmatter_chapter(title) then ensure_mainmatter() end
            table.insert(out, make_header(lvl, title, pandoc.Attr(idn, {}, {})))
            if lvl == 2 then current_chapter = title end
            i = i + 1
            goto continue
          end
        end
      end
    end

    -- Promote ToC-mapped anchors (when Pandoc emits anchor-only paras)
    if (b.t == "Para" or b.t == "Plain") and b.attr and b.attr.identifier and b.attr.identifier ~= "" then
      local id = normalize_anchor(b.attr.identifier)
      local entry = toc_map[id]
      if entry then
        local title = strip_double_braces(stringify(b))
        if title == "" and entry.title and entry.title ~= "" then
          title = entry.title
        end
        if entry.level == 3 and entry.prefix and not title:match("^%d") then
          title = entry.prefix .. title
        end
        if entry.level == 2 then current_chapter = title end
        if entry.level <= 2 and not is_frontmatter_chapter(title) then ensure_mainmatter() end
        table.insert(out, make_header(entry.level, title, pandoc.Attr(sanitize_id(b.attr.identifier), b.attr.classes, b.attr.attributes)))
        i = i + 1
        goto continue
      end
    end

    -- SECTION inference from numeric ALLCAPS headings
    if (b.t == "Para" or b.t == "Plain") then
      local st = section_title_from_text(stringify(b))
      if st then
        table.insert(out, make_header(3, st, b.attr))
        i = i + 1
        goto continue
      end
    end

    -- SECTION inference using ToC child titles (list-style ToC)
    if current_chapter and toc_sections_by_chapter[current_chapter] and (b.t == "Para" or b.t == "Plain") then
      local bt = strip_double_braces(squash(stringify(b)))
      if bt ~= "" then
        for idx, ct in ipairs(toc_sections_by_chapter[current_chapter]) do
          if bt == ct then
            local title = bt
            if not title:match("^%d") then title = tostring(idx) .. ": " .. title end
            table.insert(out, make_header(3, title, b.attr))
            i = i + 1
            goto continue
          end
        end
      end
    end

    -- Strong-only faux headings (common in anthologies where titles/authors are just bold lines).
    if (b.t == "Para" or b.t == "Plain") then
      local st = strong_only_text_from_block(b)
      if st then
        local t = strip_double_braces(squash(st))

        -- If a bold-only line immediately after a chapter title looks like an author name, treat it as a section.
        if just_started_chapter then
          local cleaned = clean_author_line(t)
          if looks_like_author_name(cleaned) and not lower(t):match("^edited%s+by") then
            dbg("bold author under story -> section: " .. t .. " -> " .. cleaned)
            table.insert(out, make_header(3, cleaned, b.attr))
            i = i + 1
            goto continue
          end
        end

        -- Drop obvious titlepage/credit headings early.
        if not mainmatter_started and looks_like_titlepage_heading(t, doc_title_norm) then
          i = i + 1
          goto continue
        end

        -- Bold title + bold author pair => \chapter{Title} then \section{Author}
        local j = i + 1
        while j <= #blocks do
          local bj = drop_images(blocks[j])
          bj = unwrap_style_spans(bj)
          if block_is_blankish(bj) then
            j = j + 1
          else
            break
          end
        end
        local nb = (j <= #blocks) and unwrap_style_spans(drop_images(blocks[j])) or nil
        local st2 = strong_only_text_from_block(nb)
        if st2 then
          local author_raw = strip_double_braces(squash(st2))
          local author = clean_author_line(author_raw)

          -- Guard: avoid misclassifying random bold pairs as title/author; require narrative-ish content next.
          local narrative_ok = true
          local k2 = j + 1
          while k2 <= #blocks do
            local bk = unwrap_style_spans(drop_images(blocks[k2]))
            if block_is_blankish(bk) then
              k2 = k2 + 1
            else
              local st_k = strong_only_text_from_block(bk)
              if st_k then narrative_ok = false end
              if bk.t == "Para" or bk.t == "Plain" or bk.t == "BlockQuote" then
                local tx = strip_double_braces(squash(stringify(bk)))
                if tx ~= "" and (tx:match("%l") or #tx > 24) then
                  narrative_ok = narrative_ok and true
                end
              end
              break
            end
          end

          if narrative_ok and looks_like_author_name(author) and not lower(t):match("^edited%s+by") then
            if is_backmatter_chapter(t) then
              ensure_backmatter()
            elseif not is_frontmatter_chapter(t) then
              ensure_mainmatter()
            end

            table.insert(out, make_header(2, t, b.attr))
            current_chapter = t
            just_started_chapter = true
            table.insert(out, make_header(3, author, nb.attr))
            i = j + 1
            goto continue
          end
        end

        -- Single bold heading: treat known front/back headings as chapters.
        if is_backmatter_chapter(t) then ensure_backmatter() end
        if is_frontmatter_chapter(t) or is_backmatter_chapter(t) then
          if not is_frontmatter_chapter(t) then ensure_mainmatter() end
          table.insert(out, make_header(2, t, b.attr))
          current_chapter = t
          just_started_chapter = true
          i = i + 1
          goto continue
        end

        -- If it looks like a chapter title and is bold-only, allow it (even if ALL CAPS).
        local ct2 = chapter_title_from_text(t, { allow_all_caps_chapters = true })
        if ct2 and ct2 ~= "" then
          current_chapter = ct2
          if is_backmatter_chapter(ct2) then
            ensure_backmatter()
          elseif not is_frontmatter_chapter(ct2) then
            ensure_mainmatter()
          end
          table.insert(out, make_header(2, ct2, b.attr))
          just_started_chapter = true
          i = i + 1
          goto continue
        end
      end
    end

    -- Optional POV/scene section markers (e.g., "HENRY—")
    if promote_pov_sections and current_chapter and (b.t == "Para" or b.t == "Plain") then
      local pv = pov_title_from_text(stringify(b))
      if pv then
        table.insert(out, make_header(3, pv, b.attr))
        i = i + 1
        goto continue
      end
    end

    -- Conservative CHAPTER inference
    if (b.t == "Para" or b.t == "Plain") then
      local ct = chapter_title_from_text(stringify(b), { allow_all_caps_chapters = allow_all_caps_chapters })
      if ct and ct ~= "" then
        current_chapter = ct
        if is_backmatter_chapter(ct) then
          ensure_backmatter()
        elseif not is_frontmatter_chapter(ct) then
          ensure_mainmatter()
        end
        table.insert(out, make_header(2, ct, b.attr))
        i = i + 1
        goto continue
      end
    end

    -- Convert endnote links to real footnotes
    if convert_endnotes then
      b = pandoc.walk_block(b, {
        Link = function(l) return link_to_endnote(l, endnote_map, current_file) end
      })
    end

    table.insert(out, b)
    i = i + 1

    ::continue::
  end

  if not mainmatter_started then
    table.insert(out, 1, pandoc.RawBlock("latex", "\\mainmatter"))
  end

  doc.blocks = out
  return doc
end
