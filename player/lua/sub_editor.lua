--[[
This file is part of mpv.

mpv is free software; you can redistribute it and/or
modify it under the terms of the GNU Lesser General Public
License as published by the Free Software Foundation; either
version 2.1 of the License, or (at your option) any later version.

mpv is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU Lesser General Public License for more details.

You should have received a copy of the GNU Lesser General Public
License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
]]

-- In-place subtitle editor. Double-clicking a text subtitle pauses playback
-- and turns the subtitle into an editable text box. The edited text is applied
-- to the loaded subtitle track with the sub-edit command, and can be written
-- to a subtitle file with the save binding.

local msg = require "mp.msg"
local utils = require "mp.utils"
local options = require "mp.options"

local opts = {
    -- Double-clicking anywhere while a subtitle is visible opens the editor,
    -- instead of only on the (estimated) subtitle area.
    dblclick_anywhere = false,
    -- Command run on double-clicks that don't hit a subtitle.
    dblclick_fallback = "cycle fullscreen",
    -- Resume playback after confirming or cancelling an edit, if the video
    -- was playing when the editor was opened.
    resume_after_edit = false,
    -- Font size of the editor, scaled like --sub-font-size. 0 = use
    -- --sub-font-size.
    font_size = 0,
    font = "",
    padding = 14,
    background_color = "#1E1E1E",
    background_alpha = 0.15,
    border_color = "#4FA3FF",
    text_color = "#FFFFFF",
    selection_color = "#2A6FDB",
    cursor_color = "#FFD84F",
    hint_color = "#9A9A9A",
    -- Every confirmed edit is saved to "<name>.edited.<ext>": next to the
    -- external subtitle file, or next to the video for embedded tracks (which
    -- are extracted with ffmpeg first). The .edited file is loaded instead of
    -- the original the next time the video is opened.
    -- Directory for the .edited files. Empty = next to the subtitle/video.
    save_dir = "",
    -- Save into the external subtitle file itself instead of a .edited copy.
    save_in_place = false,
    ffmpeg_path = "ffmpeg",
}
options.read_options(opts, "sub_editor")

local editor = nil       -- state of the open editor, nil when closed
local edits = {}         -- confirmed edits not yet written to a file
local on_edit            -- called with the track after each confirmed edit
local delete_line        -- deletes the line being edited
local bg_overlay = mp.create_osd_overlay("ass-events")
local text_overlay = mp.create_osd_overlay("ass-events")
local measure_overlay = mp.create_osd_overlay("ass-events")
bg_overlay.z = 1000
text_overlay.z = 1001
measure_overlay.hidden = true
measure_overlay.compute_bounds = true

---------------------------------------------------------------------------
-- Helpers

local function color_to_ass(color)
    local r, g, b = color:match("^#?(%x%x)(%x%x)(%x%x)$")
    if not r then
        return "FFFFFF"
    end
    return (b .. g .. r):upper()
end

local function alpha_to_ass(a)
    return string.format("%02X", math.floor((1 - a) * 255 + 0.5))
end

local function ass_escape(str)
    return mp.command_native({"escape-ass", str})
end

local function osd_size()
    local dim = mp.get_property_native("osd-dimensions")
    if not dim or dim.w <= 0 or dim.h <= 0 then
        return nil
    end
    return dim.w, dim.h
end

local function sub_scale(h)
    local s = h / 720
    if not mp.get_property_native("sub-scale-by-window", true) then
        s = mp.get_property_native("display-hidpi-scale", 1)
    end
    return s * mp.get_property_native("sub-scale", 1)
end

local function font_size(h)
    local fs = opts.font_size > 0 and opts.font_size
               or mp.get_property_native("sub-font-size", 38)
    return fs * sub_scale(h)
end

local function font_name()
    if opts.font ~= "" then
        return opts.font
    end
    return mp.get_property("sub-font", "sans-serif")
end

-- Number of bytes of the UTF-8 sequence starting with byte b.
local function utf8_len(b)
    if b >= 0xF0 then return 4 end
    if b >= 0xE0 then return 3 end
    if b >= 0xC0 then return 2 end
    return 1
end

local function is_continuation(b)
    return b >= 0x80 and b < 0xC0
end

---------------------------------------------------------------------------
-- Subtitle events

-- Parses the sub-text/ass-full property into a list of events.
local function current_events()
    local full = mp.get_property("sub-text/ass-full", "")
    local events = {}
    for line in (full .. "\n"):gmatch("(.-)\n") do
        local fields = {}
        local rest = line:gsub("^Dialogue:%s*", "")
        for _ = 1, 9 do
            local f, r = rest:match("^([^,]*),(.*)$")
            if not f then
                break
            end
            fields[#fields + 1] = f
            rest = r
        end
        if #fields == 9 then
            events[#events + 1] = {
                index = #events,
                layer = tonumber(fields[1]) or 0,
                start = fields[2],
                stop = fields[3],
                style = fields[4],
                text = rest,
                positioned = rest:find("\\pos%(") or rest:find("\\move%(")
                             or rest:find("\\an[789]") and true or false,
            }
        end
    end
    return events
end

-- Picks the event the user most likely wants to edit: dialogue lines (no
-- explicit positioning) are preferred over typesetting.
local function preferred_event(events)
    for i, ev in ipairs(events) do
        if not ev.positioned then
            return i
        end
    end
    return 1
end

---------------------------------------------------------------------------
-- Text measurement and layout

local function measure(ass, w, h)
    measure_overlay.res_x, measure_overlay.res_y = w, h
    -- The trailing "|" keeps libass from ignoring trailing whitespace.
    local base = "{\\an7\\pos(0,0)\\bord0\\shad0\\fn" .. font_name() ..
                 "\\fs" .. editor.fs .. "}"
    measure_overlay.data = base .. ass .. "|"
    local r1 = measure_overlay:update()
    measure_overlay.data = base .. "|"
    local r2 = measure_overlay:update()
    if not r1 or not r1.x1 or not r2 or not r2.x1 then
        return 0
    end
    return (r1.x1 - r1.x0) - (r2.x1 - r2.x0)
end

-- Splits the text into visual lines at "\N" tokens. Each line records the
-- byte range [first, last) of its content (0-based cursor positions).
local function split_lines(text)
    local lines = {}
    local pos = 0
    while true do
        local s = text:find("\\N", pos + 1, true)
        if not s then
            lines[#lines + 1] = {first = pos, last = #text}
            break
        end
        lines[#lines + 1] = {first = pos, last = s - 1}
        pos = s + 1
    end
    return lines
end

local function line_of_cursor(lines, cursor)
    for i, l in ipairs(lines) do
        if cursor >= l.first and cursor <= l.last then
            return i
        end
    end
    return #lines
end

---------------------------------------------------------------------------
-- Override tags
--
-- In the visual mode (the default) "{...}" override blocks are hidden: bold,
-- italic, underline and strikeout tags are rendered as formatting, and other
-- blocks as a small "{…}" marker. The cursor never goes inside a block, and
-- deleting text keeps the blocks, so formatting doesn't leak into the rest of
-- the line. Ctrl+T shows the raw text with the tags instead.

local show_tags = false

local function visual()
    return editor ~= nil and not show_tags
end

-- Exclusive end of the "{...}" block starting at position p, or nil.
local function block_end(text, p)
    if text:byte(p + 1) ~= 123 then -- "{"
        return nil
    end
    return text:find("}", p + 2, true)
end

-- Start of the "{...}" block ending at position p, or nil.
local function block_start(text, p)
    if p <= 0 or text:byte(p) ~= 125 then -- "}"
        return nil
    end
    local s = text:sub(1, p - 1):match(".*(){")
    return s and s - 1
end

local function skip_blocks_forward(text, p)
    local e = block_end(text, p)
    while e do
        p = e
        e = block_end(text, p)
    end
    return p
end

local function skip_blocks_back(text, p)
    local s = block_start(text, p)
    while s do
        p = s
        s = block_start(text, p)
    end
    return p
end

-- Canonical cursor position in the visual mode: right after the previous
-- visible character, so typed text continues its formatting, or after the
-- blocks at the start of a line.
local function normalize(p)
    if not visual() then
        return p
    end
    local text = editor.text
    local q = skip_blocks_back(text, p)
    if q == 0 or (q >= 2 and text:sub(q - 1, q) == "\\N") then
        return skip_blocks_forward(text, q)
    end
    return q
end

-- Splits the contents of a block into the text before the first tag (e.g. a
-- comment) and the tags, without their leading backslash.
local function parse_block(content)
    local tags = {}
    for t in content:gmatch("\\([^\\]*)") do
        tags[#tags + 1] = t
    end
    return content:match("^[^\\]*"), tags
end

-- "i1" -> "i", "1" for the formatting tags \b, \i, \u and \s.
local function format_tag(t)
    return t:match("^([bius])(%d+)$")
end

local function is_on(v)
    return v ~= nil and v ~= "0"
end

-- Formatting of the style of the edited line ({b = "1", i = "0", ...}), or
-- an empty table (unknown) if the player couldn't tell.
local function style_defaults()
    local info = editor.style_info and editor.style_info[editor.style]
    local state = {}
    if info then
        state.b = info.bold and "1" or "0"
        state.i = info.italic and "1" or "0"
        state.u = info.underline and "1" or "0"
        state.s = info.strikeout and "1" or "0"
    end
    return state
end

-- Applies the tags of a block to a formatting state. \r resets to the style.
local function apply_block_state(state, tags)
    for _, t in ipairs(tags) do
        local l, v = format_tag(t)
        if l then
            state[l] = v
        elseif t:match("^r") then
            for k in pairs(state) do
                state[k] = nil
            end
            for k, dv in pairs(style_defaults()) do
                state[k] = dv
            end
        end
    end
end

-- Formatting state in effect at position p.
local function state_at(text, p)
    local state = style_defaults()
    local pos = 0
    while pos < p do
        local e = block_end(text, pos)
        if e and e <= p then
            local _, tags = parse_block(text:sub(pos + 2, e - 1))
            apply_block_state(state, tags)
            pos = e
        else
            pos = pos + 1
        end
    end
    return state
end

-- Override tags that reproduce a formatting state.
local function state_tags(state)
    local out = {}
    for l in ("bius"):gmatch(".") do
        out[#out + 1] = "\\" .. l .. (state[l] or "0")
    end
    return table.concat(out)
end

-- The "{...}" blocks within [a, b), split into the ones before the first
-- visible character and the rest.
local function blocks_in(text, a, b)
    local lead, trail = {}, {}
    local seen_visible = false
    local pos = a
    while pos < b do
        local e = block_end(text, pos)
        if e and e <= b then
            local t = seen_visible and trail or lead
            t[#t + 1] = text:sub(pos + 1, e)
            pos = e
        else
            seen_visible = true
            pos = pos + 1
        end
    end
    return table.concat(lead), table.concat(trail)
end

-- Removes the tag (a letter of "bius") from the blocks in s.
local function strip_tag(s, tag)
    return (s:gsub("{([^}]*)}", function(content)
        local prefix, tags = parse_block(content)
        local kept = {}
        for _, t in ipairs(tags) do
            if format_tag(t) ~= tag then
                kept[#kept + 1] = "\\" .. t
            end
        end
        content = prefix .. table.concat(kept)
        return content ~= "" and "{" .. content .. "}" or ""
    end))
end

-- Removes formatting tags that change nothing: ones overridden before the
-- next visible character, ones setting the state it already has, and ones
-- after the last visible character. Empty blocks are removed. cursor and
-- anchor (which must not be inside blocks) are mapped to the new text.
local function cleanup(text, cursor, anchor)
    local blocks = {}
    local visible_after = {}
    local run = 1
    local pos = 0
    while pos < #text do
        local e = block_end(text, pos)
        if e then
            local prefix, tags = parse_block(text:sub(pos + 2, e - 1))
            blocks[#blocks + 1] = {s = pos, e = e, prefix = prefix,
                                   tags = tags, run = run}
            pos = e
        else
            visible_after[run] = true
            run = run + 1
            pos = pos + 1
        end
    end

    local function overridden(bi, ti, letter)
        local run_id = blocks[bi].run
        for bj = bi, #blocks do
            local blk = blocks[bj]
            if blk.run ~= run_id then
                break
            end
            for tj = (bj == bi and ti + 1 or 1), #blk.tags do
                local t = blk.tags[tj]
                if format_tag(t) == letter or t:match("^r") then
                    return true
                end
            end
        end
        return false
    end

    -- The state starts as the style's. If that's unknown, only tags that
    -- repeat a state set by an earlier tag count as redundant.
    local state = style_defaults()
    for bi, blk in ipairs(blocks) do
        blk.keep = {}
        for ti, t in ipairs(blk.tags) do
            local l, v = format_tag(t)
            local keep = true
            if l then
                keep = visible_after[blk.run] and not overridden(bi, ti, l) and
                       state[l] ~= v
                if keep then
                    state[l] = v
                end
            elseif t:match("^r") then
                state = style_defaults()
            end
            blk.keep[ti] = keep
        end
    end

    local out = {}
    local last = 0
    local prev_idx = nil   -- index in out of the previous block, if nothing
                           -- but removed blocks is between it and blk
    for _, blk in ipairs(blocks) do
        local kept = {}
        for ti, t in ipairs(blk.tags) do
            if blk.keep[ti] then
                kept[#kept + 1] = "\\" .. t
            end
        end
        local content = blk.prefix .. table.concat(kept)
        local new = content ~= "" and "{" .. content .. "}" or ""
        local between = text:sub(last + 1, blk.s)
        blk.removed = (blk.e - blk.s) - #new
        if between ~= "" then
            prev_idx = nil
        end
        -- Merge "{\b1}{\i1}" into "{\b1\i1}".
        if prev_idx and new ~= "" and blk.prefix == "" then
            out[prev_idx] = out[prev_idx]:sub(1, -2)
            new = new:sub(2)
            blk.removed = blk.removed + 2
        end
        out[#out + 1] = between
        out[#out + 1] = new
        if new ~= "" then
            prev_idx = #out
        end
        last = blk.e
    end
    out[#out + 1] = text:sub(last + 1)

    local function map(p)
        if not p then
            return nil
        end
        local q = p
        for _, blk in ipairs(blocks) do
            if blk.e <= p then
                q = q - blk.removed
            end
        end
        return q
    end
    return table.concat(out), map(cursor), map(anchor)
end

-- ASS text that displays [a, b) of the edited text.
local function display(a, b)
    local text = editor.text
    if not visual() then
        return ass_escape(text:sub(a + 1, b))
    end
    local out = {}
    local pos = a
    while pos < b do
        local e = block_end(text, pos)
        if e and e <= b then
            local prefix, tags = parse_block(text:sub(pos + 2, e - 1))
            local fmt, other = {}, prefix ~= ""
            for _, t in ipairs(tags) do
                local l, v = format_tag(t)
                if l then
                    fmt[#fmt + 1] = "\\" .. l .. v
                elseif t:match("^r") then
                    fmt[#fmt + 1] = "\\b0\\i0\\u0\\s0"
                else
                    other = true
                end
            end
            if #fmt > 0 then
                out[#out + 1] = "{" .. table.concat(fmt) .. "}"
            end
            if other then
                out[#out + 1] = string.format("{\\1a&H90&\\fs%g}%s{\\1a&H00&\\fs%g}",
                    editor.fs * 0.6, ass_escape("{…}"), editor.fs)
            end
            pos = e
        else
            local nxt = text:find("{", pos + 2, true)
            local stop = math.min(b, nxt and nxt - 1 or b)
            out[#out + 1] = ass_escape(text:sub(pos + 1, stop))
            pos = stop
        end
    end
    return table.concat(out)
end

-- Formatting state at the start of [a, ...) as a tag block, so that a line
-- rendered as its own ASS event starts with the right formatting.
local function display_prefix(a)
    if not visual() then
        return ""
    end
    return "{" .. state_tags(state_at(editor.text, a)) .. "}"
end

---------------------------------------------------------------------------
-- Rendering

local function selection_range()
    if not editor.anchor or editor.anchor == editor.cursor then
        return nil
    end
    return math.min(editor.anchor, editor.cursor),
           math.max(editor.anchor, editor.cursor)
end

local function base_style()
    return "\\fn" .. font_name() .. "\\fs" .. editor.fs ..
           "\\bord0\\shad0\\1c&H" .. color_to_ass(opts.text_color) .. "&"
end

-- The cursor is drawn with \r, which resets the formatting; restore it after.
local function cursor_glyph()
    local cheight = editor.fs * 8
    local fmt = visual() and state_tags(state_at(editor.text, editor.cursor)) or ""
    return "{\\r\\blur0\\1a&HFF&\\3a&H00&\\3c&H" ..
           color_to_ass(opts.cursor_color) .. "&" ..
           "\\xbord1\\ybord0\\shad0\\p4\\pbo" .. math.floor(editor.fs * 1.8) ..
           "}m 0 0 l 1 0 l 1 " .. cheight .. " l 0 " .. cheight .. "{\\p0\\r" ..
           base_style() .. fmt .. "}"
end

-- Renders the text between byte positions [a, b), marking the selection and
-- the cursor.
local function render_range(a, b)
    local sel_a, sel_b = selection_range()
    local cuts = {a, b}
    for _, p in pairs({sel_a or false, sel_b or false, editor.cursor}) do
        if p and p > a and p < b then
            cuts[#cuts + 1] = p
        end
    end
    table.sort(cuts)

    local sel_style = "{\\3c&H" .. color_to_ass(opts.selection_color) ..
                      "&\\3a&H00&\\bord" .. math.max(2, editor.fs * 0.12) ..
                      "\\blur0}"
    local out = {}
    local cursor_drawn = false
    for i = 1, #cuts - 1 do
        local s, e = cuts[i], cuts[i + 1]
        if s == editor.cursor and not cursor_drawn then
            out[#out + 1] = cursor_glyph()
            cursor_drawn = true
        end
        if e > s then
            local chunk = display(s, e)
            if sel_a and s >= sel_a and e <= sel_b then
                out[#out + 1] = sel_style .. chunk .. "{\\bord0}"
            else
                out[#out + 1] = chunk
            end
        end
    end
    if editor.cursor == b and not cursor_drawn then
        out[#out + 1] = cursor_glyph()
    end
    return table.concat(out)
end

local function render()
    if not editor then
        return
    end
    local w, h = osd_size()
    if not w then
        return
    end
    editor.w, editor.h = w, h
    editor.fs = font_size(h)
    editor.line_h = editor.fs * 1.25

    local lines = split_lines(editor.text)
    editor.lines = lines

    local pad = opts.padding * sub_scale(h)
    local hint_fs = editor.fs * 0.55
    local header_h = hint_fs * 1.5

    local hint = "Enter/clique fora: salvar   Shift+Enter: \\N   Esc: cancelar   " ..
                 "Botão direito: formatar   Ctrl+T: " ..
                 (show_tags and "ocultar tags" or "mostrar tags")
    if #editor.events > 1 then
        hint = string.format("Evento %d/%d (Tab)   ", editor.event_pos,
                             #editor.events) .. hint
    end
    if editor.style ~= editor.events[editor.event_pos].style then
        hint = "Estilo: " .. editor.style .. " (novo)   " .. hint
    end

    -- Stay left of the dialogue panel, which makes room for itself with the
    -- right video margin.
    local right = w * (1 - mp.get_property_native("video-margin-ratio-right", 0))
    local limit = right - pad * 4

    -- Widest line (or the hint) determines the box width. The hint shrinks
    -- if it doesn't fit.
    local hint_w = measure("{\\fs" .. hint_fs .. "}" .. ass_escape(hint), w, h)
    if hint_w > limit then
        hint_fs = hint_fs * limit / hint_w
        hint_w = limit
    end
    local max_w = hint_w
    for _, l in ipairs(lines) do
        l.width = measure(display_prefix(l.first) .. display(l.first, l.last), w, h)
        max_w = math.max(max_w, l.width)
    end
    max_w = math.min(max_w, limit)

    local box_w = max_w + pad * 2
    local box_h = #lines * editor.line_h + pad * 2 + header_h
    local margin = mp.get_property_native("sub-margin-y", 22) * sub_scale(h)
    local cx = w / 2
    local top
    -- Cover the subtitle where it is drawn, if we know where that is.
    local r = editor.rects and editor.rects[editor.event_pos]
    if r and r.x0 then
        cx = (r.x0 + r.x1) / 2
        if (r.y0 + r.y1) / 2 < h / 2 then
            top = r.y0 - pad - header_h
        else
            top = r.y1 + pad - box_h
        end
    elseif editor.at_top then
        top = margin
    else
        top = h - margin - box_h
    end
    cx = math.max(box_w / 2, math.min(right - box_w / 2, cx))
    top = math.max(0, math.min(h - box_h, top))
    editor.cx = cx
    editor.box = {x0 = cx - box_w / 2, y0 = top, x1 = cx + box_w / 2,
                  y1 = top + box_h}
    editor.text_top = top + pad + header_h

    local bg = string.format(
        "{\\an7\\pos(0,0)\\bord%g\\shad0\\blur0\\1c&H%s&\\1a&H%s&\\3c&H%s&" ..
        "\\p1}m %d %d l %d %d l %d %d l %d %d{\\p0}",
        math.max(1, sub_scale(h) * 1.5), color_to_ass(opts.background_color),
        alpha_to_ass(1 - opts.background_alpha),
        color_to_ass(opts.border_color),
        editor.box.x0, editor.box.y0, editor.box.x1, editor.box.y0,
        editor.box.x1, editor.box.y1, editor.box.x0, editor.box.y1)
    bg_overlay.res_x, bg_overlay.res_y = w, h
    bg_overlay.data = bg
    bg_overlay:update()

    local out = {}
    out[#out + 1] = string.format(
        "{\\an8\\pos(%g,%g)\\fn%s\\fs%g\\bord0\\shad0\\1c&H%s&}%s",
        cx, top + pad * 0.5, font_name(), hint_fs,
        color_to_ass(opts.hint_color), ass_escape(hint))

    for i, l in ipairs(lines) do
        out[#out + 1] = string.format("{\\an8\\pos(%g,%g)\\q2%s}%s%s", cx,
            editor.text_top + (i - 1) * editor.line_h, base_style(),
            display_prefix(l.first), render_range(l.first, l.last))
    end
    text_overlay.res_x, text_overlay.res_y = w, h
    text_overlay.data = table.concat(out, "\n")
    text_overlay:update()
end

---------------------------------------------------------------------------
-- Cursor movement and editing

-- Previous/next character position, treating "\N" as one character.
local function raw_prev(text, pos)
    if pos <= 0 then
        return 0
    end
    if pos >= 2 and text:sub(pos - 1, pos) == "\\N" then
        return pos - 2
    end
    local p = pos - 1
    while p > 0 and is_continuation(text:byte(p + 1)) do
        p = p - 1
    end
    return p
end

local function raw_next(text, pos)
    if pos >= #text then
        return #text
    end
    if text:sub(pos + 1, pos + 2) == "\\N" then
        return pos + 2
    end
    return pos + utf8_len(text:byte(pos + 1))
end

-- Previous/next cursor position. In the visual mode tag blocks are skipped.
-- Both can return pos itself when there is nowhere to go.
local function prev_pos(pos)
    local text = editor.text
    if not visual() then
        return raw_prev(text, pos)
    end
    return normalize(raw_prev(text, skip_blocks_back(text, pos)))
end

local function next_pos(pos)
    local text = editor.text
    if not visual() then
        return raw_next(text, pos)
    end
    local p = skip_blocks_forward(text, pos)
    if p >= #text then
        return normalize(#text)
    end
    return normalize(raw_next(text, p))
end

local function is_word_char(c)
    return c:match("[%w_]") ~= nil or c:byte() >= 0x80
end

-- Whether the character before/after cursor position p is part of a word.
-- "\N" line breaks are never part of a word.
local function word_before(p)
    local text = editor.text
    if visual() then
        p = skip_blocks_back(text, p)
    end
    if p <= 0 or (p >= 2 and text:sub(p - 1, p) == "\\N") then
        return false
    end
    return is_word_char(text:sub(p, p))
end

local function word_after(p)
    local text = editor.text
    if visual() then
        p = skip_blocks_forward(text, p)
    end
    if p >= #text or text:sub(p + 1, p + 2) == "\\N" then
        return false
    end
    return is_word_char(text:sub(p + 1, p + 1))
end

-- Moves from p with step (prev_pos or next_pos) while cond(p) holds.
local function move_while(p, step, cond)
    while cond(p) do
        local q = step(p)
        if q == p then
            break
        end
        p = q
    end
    return p
end

local function prev_word(pos)
    local p = move_while(pos, prev_pos, function(q) return not word_before(q) end)
    return move_while(p, prev_pos, word_before)
end

local function next_word(pos)
    local p = move_while(pos, next_pos, function(q) return not word_after(q) end)
    return move_while(p, next_pos, word_after)
end

-- Byte range of the word around cursor position p.
local function word_bounds(p)
    return move_while(p, prev_pos, word_before), move_while(p, next_pos, word_after)
end

local function move_to(pos, extend)
    editor.select_all_on_open = nil
    if extend then
        editor.anchor = editor.anchor or editor.cursor
    else
        editor.anchor = nil
    end
    editor.cursor = normalize(pos)
    render()
end

-- After an edit in the visual mode, drop tags that became redundant.
local function tidy(always)
    if visual() or always then
        editor.text, editor.cursor, editor.anchor =
            cleanup(editor.text, editor.cursor, editor.anchor)
        editor.cursor = normalize(editor.cursor)
        if editor.anchor then
            editor.anchor = normalize(editor.anchor)
        end
    end
end

local function push_undo()
    editor.select_all_on_open = nil
    local u = editor.undo
    u[#u + 1] = {text = editor.text, cursor = editor.cursor}
    if #u > 500 then
        table.remove(u, 1)
    end
    editor.redo = {}
end

-- Replaces the selection (or inserts at the cursor) with str.
-- In the visual mode the tag blocks of the replaced range are kept: the ones
-- before its first character go before str, so it gets that formatting.
local function replace_selection(str)
    push_undo()
    local a, b = selection_range()
    a = a or editor.cursor
    b = b or editor.cursor
    local text = editor.text
    local lead, trail = "", ""
    if visual() then
        lead, trail = blocks_in(text, a, b)
    end
    editor.text = text:sub(1, a) .. lead .. str .. trail .. text:sub(b + 1)
    editor.cursor = a + #lead + #str
    editor.anchor = nil
    tidy()
    render()
end

local function delete_range(a, b)
    if a == b then
        return
    end
    push_undo()
    local text = editor.text
    local lead, trail = "", ""
    if visual() then
        lead, trail = blocks_in(text, a, b)
    end
    editor.text = text:sub(1, a) .. lead .. trail .. text:sub(b + 1)
    editor.cursor = a
    editor.anchor = nil
    tidy()
    render()
end

local function backspace(word)
    local a, b = selection_range()
    if a then
        delete_range(a, b)
    else
        local p = word and prev_word(editor.cursor) or prev_pos(editor.cursor)
        delete_range(p, editor.cursor)
    end
end

local function delete_forward(word)
    local a, b = selection_range()
    if a then
        delete_range(a, b)
    else
        local p = word and next_word(editor.cursor) or next_pos(editor.cursor)
        delete_range(editor.cursor, p)
    end
end

local function vertical_move(dir, extend)
    local lines = split_lines(editor.text)
    local i = line_of_cursor(lines, editor.cursor)
    local j = i + dir
    if j < 1 then
        return move_to(0, extend)
    elseif j > #lines then
        return move_to(#editor.text, extend)
    end
    -- Keep the column by character count.
    local col = 0
    move_while(normalize(lines[i].first), next_pos, function(q)
        if q >= editor.cursor then
            return false
        end
        col = col + 1
        return true
    end)
    local p = move_while(normalize(lines[j].first), next_pos, function(q)
        if col <= 0 or q >= lines[j].last then
            return false
        end
        col = col - 1
        return true
    end)
    move_to(p, extend)
end

local function line_home_end(to_end, extend)
    local lines = split_lines(editor.text)
    local l = lines[line_of_cursor(lines, editor.cursor)]
    move_to(to_end and l.last or l.first, extend)
end

local function undo()
    local u = table.remove(editor.undo)
    if u then
        editor.redo[#editor.redo + 1] = {text = editor.text,
                                         cursor = editor.cursor}
        editor.text, editor.cursor, editor.anchor = u.text, u.cursor, nil
        render()
    end
end

local function redo()
    local r = table.remove(editor.redo)
    if r then
        editor.undo[#editor.undo + 1] = {text = editor.text,
                                         cursor = editor.cursor}
        editor.text, editor.cursor, editor.anchor = r.text, r.cursor, nil
        render()
    end
end

local function get_clipboard()
    mp.commandv("update-clipboard", "text")
    return mp.get_property("clipboard/text", "")
end

local function copy(cut)
    local a, b = selection_range()
    if not a then
        return
    end
    mp.set_property("clipboard/text", editor.text:sub(a + 1, b))
    if cut then
        delete_range(a, b)
    end
end

local function paste()
    local text = get_clipboard()
    if text == "" then
        return
    end
    -- Real line breaks become ASS line breaks.
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n", "\\N")
    replace_selection(text)
end

---------------------------------------------------------------------------
-- Mouse

-- Byte position closest to OSD coordinates x, y.
local function pos_from_mouse(x, y)
    local lines = split_lines(editor.text)
    local i = math.floor((y - editor.text_top) / editor.line_h) + 1
    i = math.max(1, math.min(#lines, i))
    local l = lines[i]
    local prefix = display_prefix(l.first)
    local width = measure(prefix .. display(l.first, l.last), editor.w, editor.h)
    local rel = x - (editor.cx - width / 2)
    local first = normalize(l.first)
    if rel <= 0 then
        return first
    end
    local prev_p, prev_w = first, 0
    local p = first
    while p < l.last do
        local q = next_pos(p)
        if q == p then
            break
        end
        p = q
        local pw = measure(prefix .. display(l.first, p), editor.w, editor.h)
        if pw >= rel then
            return (rel - prev_w < pw - rel) and prev_p or p
        end
        prev_p, prev_w = p, pw
    end
    return normalize(l.last)
end

local function mouse_xy()
    local m = mp.get_property_native("mouse-pos")
    return m.x, m.y
end

local function in_box(x, y)
    local b = editor.box
    return b and x >= b.x0 and x <= b.x1 and y >= b.y0 and y <= b.y1
end

---------------------------------------------------------------------------
-- Formatting and context menu

-- Toggles a formatting tag (a letter of "bius") on the selection, or on the
-- word at the cursor: if all of it already has the formatting it's removed,
-- otherwise it's applied to all of it. Uses ASS tags, which are converted to
-- <b>, <i>, <u>, <s> when saving to SRT.
local function toggle_tag(tag)
    local a, b = selection_range()
    if not a then
        a, b = word_bounds(editor.cursor)
        if a == b then
            return
        end
    end
    local text = editor.text

    local state = state_at(text, a)
    local all_on, any = true, false
    local pos = a
    while pos < b do
        local e = block_end(text, pos)
        if e and e <= b then
            local _, tags = parse_block(text:sub(pos + 2, e - 1))
            apply_block_state(state, tags)
            pos = e
        else
            any = true
            all_on = all_on and is_on(state[tag])
            pos = pos + 1
        end
    end
    if not any then
        return
    end

    local target = all_on and "0" or "1"
    -- What the text after the range had before, to restore it there.
    local after = state_at(text, b)[tag] or "0"
    push_undo()
    local inner = strip_tag(text:sub(a + 1, b), tag)
    local open = "{\\" .. tag .. target .. "}"
    local close = after ~= target and "{\\" .. tag .. after .. "}" or ""
    editor.text = text:sub(1, a) .. open .. inner .. close .. text:sub(b + 1)
    editor.anchor, editor.cursor = a + #open, a + #open + #inner
    tidy(true)
    render()
end

local function toggle_show_tags()
    show_tags = not show_tags
    editor.anchor = nil
    editor.cursor = normalize(editor.cursor)
    render()
end

local menu_overlay = mp.create_osd_overlay("ass-events")
menu_overlay.z = 1002

-- Menu items are {label, hint, action}; {} is a separator. The action gets
-- the menu that was open.

local function close_menu()
    if editor then
        editor.menu = nil
    end
    menu_overlay:remove()
end

local render_menu

local function show_menu(items, x, y)
    editor.menu = {items = items, x = x, y = y, ax = x, ay = y}
    render_menu()
end

local main_menu_items

local function style_menu_items()
    local items = {
        {"‹ Voltar", "", function(m) show_menu(main_menu_items(), m.ax, m.ay) end},
        {},
    }
    for _, name in ipairs(editor.styles) do
        items[#items + 1] = {name, name == editor.style and "✓" or "",
                             function()
                                 editor.style = name
                                 render()
                             end}
    end
    return items
end

main_menu_items = function()
    local items = {
        {"Negrito", "Ctrl+B", function() toggle_tag("b") end},
        {"Itálico", "Ctrl+I", function() toggle_tag("i") end},
        {"Sublinhado", "Ctrl+U", function() toggle_tag("u") end},
        {},
        {"Recortar", "Ctrl+X", function() copy(true) end},
        {"Copiar", "Ctrl+C", function() copy(false) end},
        {"Colar", "Ctrl+V", function() paste() end},
        {},
        {show_tags and "Ocultar tags" or "Mostrar tags", "Ctrl+T",
         toggle_show_tags},
    }
    -- Styles only exist in ASS subtitles.
    if editor.styles and #editor.styles > 0 then
        items[#items + 1] = {}
        items[#items + 1] = {"Estilo  ▸", editor.style or "", function(m)
            show_menu(style_menu_items(), m.ax, m.ay)
        end}
    end
    items[#items + 1] = {}
    items[#items + 1] = {"Excluir linha", "", function(m)
        show_menu({
            {"Excluir esta linha?", ""},
            {},
            {"Sim, excluir", "", delete_line},
            {"Cancelar", "Esc", function() end},
        }, m.ax, m.ay)
    end}
    return items
end

render_menu = function()
    local m = editor.menu
    local items = m.items
    local w, h = editor.w, editor.h
    local fs = editor.fs * 0.6
    -- Shrink long menus (scripts with many styles) to fit the screen.
    local n_items, n_seps = 0, 0
    for _, it in ipairs(items) do
        if it[1] then n_items = n_items + 1 else n_seps = n_seps + 1 end
    end
    fs = math.max(8, math.min(fs, h * 0.95 / (n_items * 1.6 + n_seps * 0.6 + 0.6)))
    local pad = fs * 0.6
    local item_h, sep_h = fs * 1.6, fs * 0.6

    if not m.width then
        local label_w, key_w = 0, 0
        for _, it in ipairs(items) do
            if it[1] then
                label_w = math.max(label_w, measure("{\\fs" .. fs .. "}" ..
                                   ass_escape(it[1]), w, h))
                key_w = math.max(key_w, measure("{\\fs" .. fs .. "}" ..
                                 ass_escape(it[2]), w, h))
            end
        end
        m.label_w = label_w
        m.width = label_w + key_w + pad * 5
        m.rows = {}
        local y = pad * 0.5
        for i, it in ipairs(items) do
            local rh = it[1] and item_h or sep_h
            m.rows[i] = {y0 = y, y1 = y + rh}
            y = y + rh
        end
        m.height = y + pad * 0.5
        -- Keep the menu on screen, opening it upwards if it doesn't fit.
        if m.y + m.height > h then
            m.y = m.y - m.height
        end
        m.x = math.max(0, math.min(w - m.width, m.x))
        m.y = math.max(0, math.min(h - m.height, m.y))
    end

    local rect = "{\\an7\\pos(0,0)\\bord%g\\shad0\\blur0\\1c&H%s&\\1a&H%s&" ..
                 "\\3c&H%s&\\p1}m %g %g l %g %g l %g %g l %g %g{\\p0}"
    local out = {string.format(rect, 1, color_to_ass(opts.background_color),
        "00", color_to_ass(opts.border_color), m.x, m.y, m.x + m.width, m.y,
        m.x + m.width, m.y + m.height, m.x, m.y + m.height)}
    for i, it in ipairs(items) do
        local r = m.rows[i]
        if not it[1] then
            local sy = m.y + (r.y0 + r.y1) / 2
            out[#out + 1] = string.format(rect, 0, color_to_ass(opts.hint_color),
                "80", "000000", m.x + pad, sy, m.x + m.width - pad, sy,
                m.x + m.width - pad, sy + 1, m.x + pad, sy + 1)
        else
            if m.hover == i then
                out[#out + 1] = string.format(rect, 0,
                    color_to_ass(opts.selection_color), "00", "000000",
                    m.x + 1, m.y + r.y0, m.x + m.width - 1, m.y + r.y0,
                    m.x + m.width - 1, m.y + r.y1, m.x + 1, m.y + r.y1)
            end
            local cy = m.y + (r.y0 + r.y1) / 2
            local style = "\\fn" .. font_name() .. "\\fs" .. fs ..
                          "\\bord0\\shad0"
            -- Items without an action are labels.
            out[#out + 1] = string.format("{\\an4\\pos(%g,%g)%s\\1c&H%s&}%s",
                m.x + pad * 1.5, cy, style,
                color_to_ass(it[3] and opts.text_color or opts.hint_color),
                ass_escape(it[1]))
            out[#out + 1] = string.format("{\\an6\\pos(%g,%g)%s\\1c&H%s&}%s",
                m.x + m.width - pad * 1.5, cy, style,
                color_to_ass(opts.hint_color), ass_escape(it[2]))
        end
    end
    menu_overlay.res_x, menu_overlay.res_y = w, h
    menu_overlay.data = table.concat(out, "\n")
    menu_overlay:update()
end

local function menu_item_at(x, y)
    local m = editor.menu
    if x < m.x or x > m.x + m.width then
        return nil
    end
    for i, r in ipairs(m.rows) do
        if m.items[i][3] and y >= m.y + r.y0 and y < m.y + r.y1 then
            return i
        end
    end
    return nil
end

local function activate_menu_item(i)
    local m = editor.menu
    close_menu()
    if i and m.items[i][3] then
        m.items[i][3](m)
    end
end

local function open_menu()
    local x, y = mouse_xy()
    if not in_box(x, y) then
        return close_menu()
    end
    -- Right-clicking outside the selection selects the word there, like in
    -- word processors.
    local p = pos_from_mouse(x, y)
    local a, b = selection_range()
    if not a or p < a or p > b or editor.select_all_on_open then
        editor.anchor, editor.cursor = word_bounds(p)
        if editor.anchor == editor.cursor then
            editor.anchor = nil
        end
        render()
    end
    editor.select_all_on_open = nil
    show_menu(main_menu_items(), x, y)
end

-- Keyboard navigation in the menu. Returns true if the key was used.
local function menu_key(key)
    local m = editor.menu
    if not m then
        return false
    end
    if key == "UP" or key == "DOWN" then
        local dir = key == "UP" and -1 or 1
        local i = m.hover or (dir == 1 and 0 or #m.items + 1)
        repeat
            i = (i + dir - 1) % #m.items + 1
        until m.items[i][3]
        m.hover = i
        render_menu()
    elseif key == "ENTER" then
        activate_menu_item(m.hover)
    end
    return true
end

local function on_mouse_move()
    if editor and editor.menu then
        local hover = menu_item_at(mouse_xy())
        if hover ~= editor.menu.hover then
            editor.menu.hover = hover
            render_menu()
        end
        return
    end
    if editor and editor.dragging then
        local x, y = mouse_xy()
        local p = pos_from_mouse(x, y)
        if p ~= editor.cursor then
            editor.cursor = p
            render()
        end
    end
end

local confirm

local function on_mbtn_left(info)
    if not editor then
        return
    end
    local x, y = mouse_xy()
    -- "press" is a click without separate down/up events (e.g. from the
    -- keypress command); handle it as both.
    local down = info.event == "down" or info.event == "press"
    local up = info.event == "up" or info.event == "press"
    if editor.menu then
        if down then
            activate_menu_item(menu_item_at(x, y))
        end
        return
    end
    if down then
        -- Clicking outside the box confirms the edit, like Enter.
        if not in_box(x, y) then
            confirm()
            return
        end
        local p = pos_from_mouse(x, y)
        local shift = info.key_name and info.key_name:find("Shift") ~= nil
        move_to(p, shift)
        if not shift then
            editor.anchor = p
        end
        editor.dragging = true
    end
    if up then
        editor.dragging = false
        if editor.anchor == editor.cursor then
            editor.anchor = nil
        end
        render()
    end
end

local function select_word_at_mouse()
    local x, y = mouse_xy()
    if not in_box(x, y) then
        return
    end
    local a, b = word_bounds(pos_from_mouse(x, y))
    editor.dragging = false
    editor.select_all_on_open = nil
    editor.anchor, editor.cursor = a, b
    render()
end

---------------------------------------------------------------------------
-- Opening and closing the editor

local close_editor

local function load_event(pos)
    local ev = editor.events[pos]
    editor.event_pos = pos
    editor.original = ev.text
    editor.text = ev.text
    editor.style = ev.style
    editor.cursor = normalize(#ev.text)
    editor.anchor = 0
    -- The whole text starts selected, so typing replaces it. A right-click
    -- selects the clicked word instead of formatting everything.
    editor.select_all_on_open = true
    editor.undo, editor.redo = {}, {}
end

confirm = function()
    local ev = editor.events[editor.event_pos]
    local new_style = editor.style ~= ev.style and editor.style or nil
    if editor.text ~= ev.text or new_style then
        local _, err = mp.command_native({"sub-edit", ev.index, editor.text,
                                          "primary", new_style or ""})
        if err then
            mp.osd_message("Não foi possível editar a legenda: " ..
                           (err or "erro desconhecido"))
        else
            edits[#edits + 1] = {
                layer = ev.layer, start = ev.start, stop = ev.stop,
                old = ev.text, new = editor.text, new_style = new_style,
                track = editor.track,
            }
            local track = editor.track
            close_editor()
            on_edit(track)
            return
        end
    end
    close_editor()
end

delete_line = function()
    local ev = editor.events[editor.event_pos]
    local _, err = mp.command_native({"sub-delete", ev.index, "primary"})
    if err then
        mp.osd_message("Não foi possível excluir a linha: " .. err)
        return
    end
    edits[#edits + 1] = {
        layer = ev.layer, start = ev.start, stop = ev.stop,
        old = ev.text, new = ev.text, deleted = true, track = editor.track,
    }
    local track = editor.track
    close_editor()
    on_edit(track)
end

local function next_event()
    if #editor.events > 1 then
        load_event(editor.event_pos % #editor.events + 1)
        render()
    end
end

local bindings = {
    {"ENTER", function() if not menu_key("ENTER") then confirm() end end},
    {"KP_ENTER", function() if not menu_key("ENTER") then confirm() end end},
    {"Shift+ENTER", function() replace_selection("\\N") end},
    {"Shift+KP_ENTER", function() replace_selection("\\N") end},
    {"ESC", function()
        if editor.menu then
            close_menu()
        else
            close_editor()
        end
    end},
    {"TAB", next_event},
    {"BS", function() backspace(false) end},
    {"Ctrl+BS", function() backspace(true) end},
    {"DEL", function() delete_forward(false) end},
    {"Ctrl+DEL", function() delete_forward(true) end},
    {"LEFT", function()
        local a = selection_range()
        move_to(a or prev_pos(editor.cursor))
    end},
    {"RIGHT", function()
        local _, b = selection_range()
        move_to(b or next_pos(editor.cursor))
    end},
    {"Shift+LEFT", function() move_to(prev_pos(editor.cursor), true) end},
    {"Shift+RIGHT", function() move_to(next_pos(editor.cursor), true) end},
    {"Ctrl+LEFT", function() move_to(prev_word(editor.cursor)) end},
    {"Ctrl+RIGHT", function() move_to(next_word(editor.cursor)) end},
    {"Ctrl+Shift+LEFT", function() move_to(prev_word(editor.cursor), true) end},
    {"Ctrl+Shift+RIGHT", function() move_to(next_word(editor.cursor), true) end},
    {"UP", function() if not menu_key("UP") then vertical_move(-1) end end},
    {"DOWN", function() if not menu_key("DOWN") then vertical_move(1) end end},
    {"Shift+UP", function() vertical_move(-1, true) end},
    {"Shift+DOWN", function() vertical_move(1, true) end},
    {"HOME", function() line_home_end(false) end},
    {"END", function() line_home_end(true) end},
    {"Shift+HOME", function() line_home_end(false, true) end},
    {"Shift+END", function() line_home_end(true, true) end},
    {"Ctrl+HOME", function() move_to(0) end},
    {"Ctrl+END", function() move_to(#editor.text) end},
    {"Ctrl+Shift+HOME", function() move_to(0, true) end},
    {"Ctrl+Shift+END", function() move_to(#editor.text, true) end},
    {"Ctrl+a", function() editor.anchor = 0; move_to(#editor.text, true) end},
    {"Ctrl+c", function() copy(false) end},
    {"Ctrl+INS", function() copy(false) end},
    {"Ctrl+x", function() copy(true) end},
    {"Shift+DEL", function() copy(true) end},
    {"Ctrl+v", paste},
    {"Shift+INS", paste},
    {"Ctrl+b", function() toggle_tag("b") end},
    {"Ctrl+i", function() toggle_tag("i") end},
    {"Ctrl+u", function() toggle_tag("u") end},
    {"Ctrl+t", toggle_show_tags},
    {"Ctrl+z", undo},
    {"Ctrl+y", redo},
    {"Ctrl+Shift+z", redo},
    {"MBTN_LEFT_DBL", select_word_at_mouse},
    {"MBTN_RIGHT", open_menu},
    -- Swallow input that would otherwise reach the player.
    {"WHEEL_UP", function() end},
    {"WHEEL_DOWN", function() end},
}

local function text_input(info)
    if info.key_text and (info.event == "press" or info.event == "down"
                          or info.event == "repeat")
    then
        close_menu()
        replace_selection(info.key_text)
    end
end

local function add_bindings()
    for i, b in ipairs(bindings) do
        mp.add_forced_key_binding(b[1], "_sub_editor_" .. i, b[2],
                                  {repeatable = true})
    end
    mp.add_forced_key_binding("any_unicode", "_sub_editor_text", text_input,
                              {repeatable = true, complex = true})
    mp.add_forced_key_binding("MBTN_LEFT", "_sub_editor_mbtn_left",
                              on_mbtn_left, {complex = true})
    mp.add_forced_key_binding("Shift+MBTN_LEFT", "_sub_editor_shift_mbtn_left",
                              on_mbtn_left, {complex = true})
    mp.add_forced_key_binding("MOUSE_MOVE", "_sub_editor_mouse_move",
                              on_mouse_move)
    -- Script binding sections allow dragging the window with the left mouse
    -- button, which would take over selecting text with the mouse. An empty
    -- section covering the whole window that doesn't allow it prevents that.
    mp.set_key_bindings({}, "sub_editor_no_drag", "default")
    mp.enable_key_bindings("sub_editor_no_drag", "allow-hide-cursor")
    mp.set_mouse_area(0, 0, 1e8, 1e8, "sub_editor_no_drag")
end

local function remove_bindings()
    for i = 1, #bindings do
        mp.remove_key_binding("_sub_editor_" .. i)
    end
    for _, name in ipairs({"_sub_editor_text", "_sub_editor_mbtn_left",
                           "_sub_editor_shift_mbtn_left",
                           "_sub_editor_mouse_move"}) do
        mp.remove_key_binding(name)
    end
    mp.disable_key_bindings("sub_editor_no_drag")
end

close_editor = function()
    if not editor then
        return
    end
    remove_bindings()
    close_menu()
    bg_overlay:remove()
    text_overlay:remove()
    mp.set_property_native("sub-visibility", editor.sub_visibility)
    if opts.resume_after_edit and not editor.was_paused then
        mp.set_property_native("pause", false)
    end
    editor = nil
end

-- Screen rectangles of the visible events (same order as current_events()),
-- or nil if the player can't tell.
local function event_rects()
    local rects = mp.command_native({"sub-event-bounds"})
    if type(rects) ~= "table" then
        return nil
    end
    return rects
end

-- pos: which of the visible events to edit (default: the preferred one).
-- rects: their screen rectangles, used to place the editor over them.
local function open_editor(pos, rects, at_top)
    if editor then
        return
    end
    local events = current_events()
    if #events == 0 then
        if mp.get_property("sub-text", "") == "" and
           mp.get_property_native("current-tracks/sub/image") then
            mp.osd_message("Legendas de imagem (PGS/VobSub) não podem ser " ..
                           "editadas como texto.")
        end
        return false
    end
    editor = {
        events = events,
        was_paused = mp.get_property_native("pause"),
        sub_visibility = mp.get_property_native("sub-visibility"),
        track = mp.get_property_native("current-tracks/sub"),
        rects = rects or event_rects(),
        at_top = at_top,
    }
    -- Style formatting, so the editor shows e.g. italic styles as italic.
    -- Only ASS subtitles have styles the user chose, so only those can be
    -- changed in the menu.
    local styles = mp.command_native({"sub-styles"})
    if type(styles) == "table" then
        editor.style_info = {}
        local names = {}
        for _, st in ipairs(styles) do
            editor.style_info[st.name] = st
            names[#names + 1] = st.name
        end
        local codec = editor.track and editor.track.codec
        if codec == "ass" or codec == "ssa" then
            editor.styles = names
        end
    end
    mp.set_property_native("pause", true)
    mp.set_property_native("sub-visibility", false)
    load_event(pos and events[pos] and pos or preferred_event(events))
    add_bindings()
    render()
    return true
end

---------------------------------------------------------------------------
-- Double-click detection

-- Rough estimate of whether (x, y) is on the currently shown dialogue, for
-- when the player can't report where subtitles are drawn.
local function estimate_hit(x, y, events)
    local w, h = osd_size()
    local plain = mp.get_property("sub-text", "")
    local n_lines = select(2, plain:gsub("\n", "")) + 1
    local fs = font_size(h)
    local margin = mp.get_property_native("sub-margin-y", 22) * sub_scale(h)
    local block_h = n_lines * fs * 1.4 + fs
    -- Typesetting can be anywhere; accept any click on the video then.
    for _, ev in ipairs(events) do
        if ev.positioned then
            return true
        end
    end
    local slack_x = w * 0.2
    local longest = 0
    for l in (plain .. "\n"):gmatch("(.-)\n") do
        longest = math.max(longest, #l)
    end
    local half_w = math.min(w / 2, longest * fs * 0.35 + slack_x)
    if math.abs(x - w / 2) > half_w then
        return false
    end
    return y >= h - margin - block_h
end

-- Returns the position (in current_events()) of the event under (x, y), true
-- if some subtitle was hit but the event is unknown, or nil.
local function event_at(x, y, rects)
    local w, h = osd_size()
    if not w then
        return nil
    end
    local events = current_events()
    if #events == 0 then
        return nil
    end
    if opts.dblclick_anywhere then
        return true
    end
    if not rects then
        return estimate_hit(x, y, events) or nil
    end
    -- Some slack around the glyphs, so clicking between lines or next to a
    -- short line still counts. Prefer the smallest matching event.
    local slack = math.max(6, h * 0.012)
    local best, best_area
    for i, r in ipairs(rects) do
        if r.x0 and x >= r.x0 - slack and x <= r.x1 + slack and
           y >= r.y0 - slack and y <= r.y1 + slack
        then
            local area = (r.x1 - r.x0) * (r.y1 - r.y0)
            if not best or area < best_area then
                best, best_area = i, area
            end
        end
    end
    return best
end

mp.add_key_binding("MBTN_LEFT_DBL", "edit-on-dblclick", function()
    local x, y = mouse_xy()
    local _, h = osd_size()
    local rects = event_rects()
    local hit = event_at(x, y, rects)
    msg.verbose(string.format("double-click at %d,%d: %s", x, y,
                              rects and utils.format_json(rects) or "no bounds"))
    if hit and open_editor(type(hit) == "number" and hit or nil, rects,
                           h and y < h / 2) then
        return
    end
    if opts.dblclick_fallback ~= "" then
        mp.command(opts.dblclick_fallback)
    end
end)

mp.add_key_binding(nil, "edit", function()
    open_editor()
end)

mp.observe_property("osd-dimensions", "native", function()
    if editor then
        render()
    end
end)

-- Close without applying if the subtitle changes under the editor.
mp.register_event("seek", function()
    if editor and not editor.dragging then
        close_editor()
    end
end)
mp.register_event("end-file", function()
    close_editor()
end)

---------------------------------------------------------------------------
-- Saving edits to a file

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local data = f:read("*a")
    f:close()
    return data
end

local function write_file(path, data)
    local f, err = io.open(path, "wb")
    if not f then
        return false, err
    end
    f:write(data)
    f:close()
    return true
end

-- "0:00:01.50" -> centiseconds
local function ass_time(t)
    local h, m, s, cs = t:match("(%d+):(%d+):(%d+)[%.,](%d+)")
    if not h then
        return nil
    end
    if #cs == 3 then
        cs = math.floor(tonumber(cs) / 10)
    end
    return ((tonumber(h) * 60 + tonumber(m)) * 60 + tonumber(s)) * 100 +
           tonumber(cs)
end

local function close_times(a, b)
    return a and b and math.abs(a - b) <= 1
end

local function apply_to_ass(data, list)
    local n = 0
    local out = {}
    for line in data:gmatch("([^\n]*)\n?") do
        local prefix, layer, st, en, rest =
            line:match("^(Dialogue:%s*)([^,]*),([^,]*),([^,]*),(.*)$")
        if prefix then
            local fields, text = {}, rest
            for _ = 1, 6 do
                local f, r = text:match("^([^,]*),(.*)$")
                if not f then
                    break
                end
                fields[#fields + 1] = f
                text = r
            end
            local cr = text:sub(-1) == "\r" and "\r" or ""
            local body = cr ~= "" and text:sub(1, -2) or text
            for _, e in ipairs(list) do
                if not e.done and tonumber(layer) == e.layer and
                   close_times(ass_time(st), ass_time(e.start)) and
                   close_times(ass_time(en), ass_time(e.stop)) and
                   body == e.old
                then
                    if e.new_style then
                        fields[1] = e.new_style
                    end
                    line = prefix .. table.concat({layer, st, en}, ",") ..
                           "," .. table.concat(fields, ",") .. "," .. e.new ..
                           cr
                    if e.deleted then
                        line = nil
                    end
                    e.done = true
                    n = n + 1
                    break
                end
            end
        end
        if line then
            out[#out + 1] = line
        end
    end
    return table.concat(out, "\n"), n
end

-- Converts ASS event text (as produced by mpv's SRT converter) back to SRT.
local function ass_to_srt_text(text)
    local tags = {
        ["\\i1"] = "<i>", ["\\i0"] = "</i>", ["\\b1"] = "<b>",
        ["\\b0"] = "</b>", ["\\u1"] = "<u>", ["\\u0"] = "</u>",
        ["\\s1"] = "<s>", ["\\s0"] = "</s>",
    }
    text = text:gsub("{([^}]*)}", function(block)
        local r = {}
        for tag in block:gmatch("\\[^\\]+") do
            r[#r + 1] = tags[tag] or ""
        end
        return table.concat(r)
    end)
    return (text:gsub("\\N", "\n"):gsub("\\n", "\n"):gsub("\\h", " "))
end

local function srt_to_ass_text(text)
    local tags = {
        ["<i>"] = "{\\i1}", ["</i>"] = "{\\i0}", ["<b>"] = "{\\b1}",
        ["</b>"] = "{\\b0}", ["<u>"] = "{\\u1}", ["</u>"] = "{\\u0}",
        ["<s>"] = "{\\s1}", ["</s>"] = "{\\s0}",
    }
    text = text:gsub("<[^>]*>", function(t) return tags[t:lower()] or "" end)
    return (text:gsub("\r", ""):gsub("\n", "\\N"))
end

local function apply_to_srt(data, list)
    local n = 0
    local renumber = false
    local nl = data:find("\r\n") and "\r\n" or "\n"
    data = data:gsub("\r\n", "\n")
    local blocks = {}
    for block in (data .. "\n\n"):gmatch("(.-)\n\n+") do
        local num, st, en, text =
            block:match("^(%d+)\n([%d:,%.]+)%s*%-%->%s*([%d:,%.]+)([^\n]*\n?.*)$")
        if num then
            local timing_rest, body = text:match("^([^\n]*)\n(.*)$")
            timing_rest = timing_rest or text
            body = body or ""
            for _, e in ipairs(list) do
                if not e.done and
                   close_times(ass_time(st), ass_time(e.start)) and
                   close_times(ass_time(en), ass_time(e.stop)) and
                   srt_to_ass_text(body) == srt_to_ass_text(ass_to_srt_text(e.old))
                then
                    block = num .. "\n" .. st .. " --> " .. en .. timing_rest ..
                            "\n" .. ass_to_srt_text(e.new)
                    if e.deleted then
                        block = ""
                        renumber = true
                    end
                    e.done = true
                    n = n + 1
                    break
                end
            end
        end
        if block ~= "" then
            blocks[#blocks + 1] = block
        end
    end
    -- Keep the numbering continuous after deleting blocks.
    if renumber then
        for i, block in ipairs(blocks) do
            blocks[i] = block:gsub("^%d+", tostring(i), 1)
        end
    end
    return (table.concat(blocks, "\n\n") .. "\n"):gsub("\n", nl), n
end

local function sub_ext(track)
    return (track.codec == "ass" or track.codec == "ssa") and "ass" or "srt"
end

local function is_edited_file(path)
    return path:match("%.edited%.[^.\\/]+$") ~= nil
end

local function edited_name(path, ext, tag)
    local dir, file = utils.split_path(path)
    local base = file:gsub("%.[^.]*$", "")
    if opts.save_dir ~= "" then
        dir = mp.command_native({"expand-path", opts.save_dir})
    end
    return utils.join_path(dir, base .. (tag and "." .. tag or "") ..
                                ".edited." .. ext)
end

-- File that edits of the given track are saved to, and the file to read the
-- current contents from (nil if the track must be extracted first).
local function save_target(track)
    if track.external and track["external-filename"] then
        local src = track["external-filename"]
        local ext = (src:match("%.([^.\\/]+)$") or ""):lower()
        if opts.save_in_place or is_edited_file(src) then
            return src, ext, src
        end
        local out = edited_name(src, ext)
        return out, ext, utils.file_info(out) and out or src
    end
    -- Embedded track. Tag the name if there is more than one text track, so
    -- they don't overwrite each other.
    local n = 0
    for _, t in ipairs(mp.get_property_native("track-list", {})) do
        if t.type == "sub" and not t.external and not t.image then
            n = n + 1
        end
    end
    local tag = n > 1 and (track.lang or ("track" .. track["ff-index"])) or nil
    local ext = sub_ext(track)
    local out = edited_name(mp.get_property("path"), ext, tag)
    return out, ext, utils.file_info(out) and out or nil
end

-- Pending edits of a track, with later edits of the same event merged into
-- earlier ones.
local function pending_edits(track)
    local merged = {}
    for _, e in ipairs(edits) do
        if e.track and e.track.id == track.id then
            local found = false
            for _, m in ipairs(merged) do
                if m.layer == e.layer and m.start == e.start and
                   m.stop == e.stop and m.new == e.old then
                    m.new = e.new
                    m.new_style = e.new_style or m.new_style
                    m.deleted = e.deleted or m.deleted
                    found = true
                    break
                end
            end
            if not found then
                merged[#merged + 1] = {layer = e.layer, start = e.start,
                                       stop = e.stop, old = e.old, new = e.new,
                                       new_style = e.new_style,
                                       deleted = e.deleted}
            end
        end
    end
    return merged
end

local function write_edits(track, src, out, ext)
    local merged = pending_edits(track)
    if #merged == 0 then
        return
    end
    local data = read_file(src)
    if not data then
        mp.osd_message("Não foi possível ler " .. src, 5)
        return
    end
    local result, n
    if ext == "ass" or ext == "ssa" then
        result, n = apply_to_ass(data, merged)
    elseif ext == "srt" then
        result, n = apply_to_srt(data, merged)
    else
        mp.osd_message("Formato ." .. ext .. " não pode ser salvo " ..
                       "(só ASS e SRT). A edição vale só nesta sessão.", 5)
        return
    end
    local ok, err = write_file(out, result)
    if not ok then
        mp.osd_message("Erro ao salvar: " .. tostring(err), 5)
        return
    end
    -- Edits that were written are no longer pending.
    local remaining = {}
    for _, e in ipairs(edits) do
        local written = false
        if e.track and e.track.id == track.id then
            for _, m in ipairs(merged) do
                if m.done and e.layer == m.layer and e.start == m.start and
                   e.stop == m.stop then
                    written = true
                end
            end
        end
        if not written then
            remaining[#remaining + 1] = e
        end
    end
    edits = remaining
    local _, name = utils.split_path(out)
    if n < #merged then
        mp.osd_message(string.format("Salvo em %s, mas %d edição(ões) não " ..
                       "foram encontradas no arquivo.", name, #merged - n), 5)
    else
        mp.osd_message("Salvo em " .. name, 2)
    end
    msg.info(string.format("saved %d/%d edit(s) to %s", n, #merged, out))
end

local extracting = false
local save_again = false
local save

-- Writes the pending edits of the track to its .edited file. Embedded tracks
-- are extracted with ffmpeg in the background first.
save = function(track)
    if extracting then
        save_again = true
        return
    end
    local out, ext, src = save_target(track)
    if src then
        write_edits(track, src, out, ext)
        return
    end

    -- Prefer an ffmpeg next to mpv, then whatever is in PATH.
    local ffmpeg = opts.ffmpeg_path
    if ffmpeg == "ffmpeg" then
        local local_ffmpeg = mp.command_native({"expand-path", "~~exe_dir/ffmpeg.exe"})
        if utils.file_info(local_ffmpeg) then
            ffmpeg = local_ffmpeg
        end
    end

    extracting = true
    mp.osd_message("Extraindo legenda embutida...", 60)
    local path = mp.get_property("path")
    mp.command_native_async({
        name = "subprocess",
        args = {ffmpeg, "-y", "-loglevel", "error", "-i", path,
                "-map", "0:" .. track["ff-index"],
                "-c:s", ext == "ass" and "copy" or "srt", out},
        capture_stdout = true, capture_stderr = true, playback_only = false,
    }, function(_, r)
        extracting = false
        if not r or r.error_string == "init" then
            mp.osd_message("Não foi possível salvar: ffmpeg não encontrado. " ..
                           "Coloque o ffmpeg no PATH ou ao lado do mpv.exe " ..
                           "(ou use sub_editor-ffmpeg_path).", 8)
            return
        elseif r.status ~= 0 then
            mp.osd_message("Não foi possível extrair a legenda (ffmpeg): " ..
                           (r.stderr ~= "" and r.stderr or r.error_string), 8)
            return
        end
        write_edits(track, out, out, ext)
        if save_again then
            save_again = false
            save(track)
        end
    end)
end

on_edit = function(track)
    if track then
        save(track)
    end
end

-- Track ids are reused by the next file. An extraction that is still running
-- finishes with the edits it was started for.
mp.register_event("end-file", function()
    if not extracting then
        edits = {}
    end
end)

-- Load the .edited version of the selected subtitle, if there is one, so
-- earlier edits show up again.
mp.register_event("file-loaded", function()
    local track = mp.get_property_native("current-tracks/sub")
    if not track or track.image then
        return
    end
    if track.external and is_edited_file(track["external-filename"] or "") then
        return
    end
    local out = save_target(track)
    if out == track["external-filename"] or not utils.file_info(out) then
        return
    end
    for _, t in ipairs(mp.get_property_native("track-list", {})) do
        if t["external-filename"] == out then
            mp.set_property_native("sid", t.id)
            return
        end
    end
    local _, name = utils.split_path(out)
    mp.commandv("sub-add", out, "select", name)
    msg.info("loaded edited subtitle " .. out)
end)
