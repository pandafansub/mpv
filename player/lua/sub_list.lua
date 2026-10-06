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

-- Side panel listing all lines of the current subtitle track as plain text.
-- Clicking a line seeks to it. Toggled by tapping Alt twice.

local options = require "mp.options"

local opts = {
    -- Maximum time in seconds between the two Alt taps.
    double_tap_time = 0.4,
    -- Panel width as a fraction of the window width.
    width = 0.32,
    -- Shrink the video to the left of the panel instead of covering it.
    shrink_video = true,
    font_size = 20,
    font = "",
    background_color = "#141414",
    background_alpha = 0.92,
    text_color = "#FFFFFF",
    time_color = "#8A8A8A",
    current_color = "#2A6FDB",
    hover_color = "#3A3A3A",
    border_color = "#4FA3FF",
    -- Seconds after scrolling by hand before the list follows playback again.
    follow_delay = 4,
}
options.read_options(opts, "sub_list")

local overlay = mp.create_osd_overlay("ass-events")
overlay.z = 900
local measure_overlay = mp.create_osd_overlay("ass-events")
measure_overlay.hidden = true
measure_overlay.compute_bounds = true

local panel = nil        -- state while the panel is shown
local last_alt_tap = 0

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

local function format_time(t)
    t = math.max(0, math.floor(t))
    local h, m, s = math.floor(t / 3600), math.floor(t / 60) % 60, t % 60
    if h > 0 then
        return string.format("%d:%02d:%02d", h, m, s)
    end
    return string.format("%d:%02d", m, s)
end

local function rect(x0, y0, x1, y1, color, alpha)
    return string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\blur0\\1c&H%s&" ..
                         "\\1a&H%s&\\p1}m %g %g l %g %g l %g %g l %g %g{\\p0}",
                         color_to_ass(color), alpha_to_ass(alpha or 1),
                         x0, y0, x1, y0, x1, y1, x0, y1)
end

local function font_name()
    return opts.font ~= "" and opts.font or mp.get_property("osd-font", "sans-serif")
end

-- Width of a character at font size 100, measured once per character.
-- Summing these ignores kerning, which is fine for wrapping.
local char_widths = {}
local function char_width(c)
    local cw = char_widths[c]
    if not cw then
        measure_overlay.res_x, measure_overlay.res_y = 10000, 10000
        local base = "{\\an7\\pos(0,0)\\bord0\\shad0\\fn" .. font_name() .. "\\fs100}"
        measure_overlay.data = base .. "|" .. ass_escape(c) .. "|"
        local r1 = measure_overlay:update()
        measure_overlay.data = base .. "||"
        local r2 = measure_overlay:update()
        cw = (r1 and r1.x1 and r2 and r2.x1) and
             (r1.x1 - r1.x0) - (r2.x1 - r2.x0) or 50
        char_widths[c] = cw
    end
    return cw
end

-- Exact width of s as rendered by libass.
local function measure(s, fs)
    measure_overlay.res_x, measure_overlay.res_y = 10000, 10000
    local base = "{\\an7\\pos(0,0)\\bord0\\shad0\\fn" .. font_name() ..
                 "\\fs" .. fs .. "}"
    measure_overlay.data = base .. "|" .. ass_escape(s) .. "|"
    local r1 = measure_overlay:update()
    measure_overlay.data = base .. "||"
    local r2 = measure_overlay:update()
    if not (r1 and r1.x1 and r2 and r2.x1) then
        return 0
    end
    return (r1.x1 - r1.x0) - (r2.x1 - r2.x0)
end

-- Width of s. Summing character widths is quick but ignores kerning and
-- hinting, so text close to the limit is measured exactly.
local function text_width(s, fs, limit)
    local w = 0
    for c in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        w = w + char_width(c)
    end
    w = w * fs / 100
    if limit and w > limit * 0.85 then
        w = measure(s, fs)
    end
    return w
end

-- Splits text into lines no wider than max_w.
local function wrap(text, fs, max_w)
    local lines, cur = {}, ""
    for word in text:gmatch("%S+") do
        local try = cur == "" and word or cur .. " " .. word
        if cur ~= "" and text_width(try, fs, max_w) > max_w then
            lines[#lines + 1] = cur
            cur = word
        else
            cur = try
        end
    end
    lines[#lines + 1] = cur
    return lines
end

-- All lines of the primary subtitle track, as {start, stop, text} with tags
-- removed and line breaks turned into spaces.
local function load_lines()
    local lines = {}
    for _, l in ipairs(mp.get_property_native("sub-lines", {})) do
        local text = l.text:gsub("%s*\n%s*", " "):gsub("^%s+", ""):gsub("%s+$", "")
        if text ~= "" then
            lines[#lines + 1] = {start = l.start, stop = l["end"], text = text}
        end
    end
    return lines
end

local function sub_delay()
    return mp.get_property_native("sub-delay", 0)
end

-- Index of the line being shown at the current playback position.
local function current_index()
    local t = mp.get_property_native("time-pos")
    if not t then
        return nil
    end
    t = t - sub_delay()
    local found
    for i, l in ipairs(panel.lines) do
        if l.start > t then
            break
        end
        if not l.stop or t < l.stop then
            found = i
        end
    end
    return found
end

local function layout()
    local dim = mp.get_property_native("osd-dimensions")
    if not dim or dim.w <= 0 then
        return false
    end
    local w, h = dim.w, dim.h
    local scale = h / 720
    local x0 = w - math.max(math.min(w * opts.width, w * 0.6), 260 * scale)
    if panel.w ~= w or panel.h ~= h or panel.x0 ~= x0 then
        panel.wrapped = {}   -- sizes changed, wrap again
    end
    panel.w, panel.h, panel.x0, panel.x1 = w, h, x0, w
    panel.fs = opts.font_size * scale
    panel.line_h = panel.fs * 1.3
    panel.pad = panel.fs * 0.7
    panel.vpad = panel.fs * 0.35
    panel.time_w = panel.fs * 3.6
    panel.header_h = panel.fs * 2.4
    panel.list_y = panel.header_h
    panel.list_h = h - panel.list_y
    return true
end

-- Wrapped text and height of line i.
local function row(i)
    local r = panel.wrapped[i]
    if not r then
        local l = panel.lines[i]
        local max_w = panel.x1 - panel.x0 - panel.pad * 2 - panel.time_w
        local text = wrap(l.text, panel.fs, max_w)
        r = {text = text, h = #text * panel.line_h + panel.vpad * 2}
        panel.wrapped[i] = r
    end
    return r
end

-- Largest first line that still fills the list.
local function max_first()
    local used, i = 0, #panel.lines
    while i >= 1 do
        used = used + row(i).h
        if used > panel.list_h then
            return i + 1
        end
        i = i - 1
    end
    return 1
end

local function clamp_scroll()
    panel.first = math.max(1, math.min(max_first(), panel.first))
end

-- Scroll so that line i is about a third from the top.
local function scroll_to(i)
    local used = 0
    local first = i
    while first > 1 and used + row(first - 1).h < panel.list_h / 3 do
        first = first - 1
        used = used + row(first).h
    end
    panel.first = first
end

local function render()
    if not panel or not layout() then
        return
    end
    clamp_scroll()
    local x0, x1, fs, pad = panel.x0, panel.x1, panel.fs, panel.pad
    local style = "\\fn" .. font_name() .. "\\bord0\\shad0\\blur0\\q2"
    local out = {
        rect(x0, 0, x1, panel.h, opts.background_color, opts.background_alpha),
        rect(x0, 0, x0 + math.max(1, fs * 0.08), panel.h, opts.border_color),
    }

    local title = #panel.lines > 0 and
        string.format("Diálogos (%d)", #panel.lines) or "Nenhum diálogo"
    out[#out + 1] = string.format("{\\an4\\pos(%g,%g)%s\\fs%g\\b1\\1c&H%s&}%s",
        x0 + pad, panel.header_h / 2, style, fs * 1.05,
        color_to_ass(opts.text_color), ass_escape(title))
    out[#out + 1] = string.format("{\\an6\\pos(%g,%g)%s\\fs%g\\1c&H%s&}%s",
        x1 - pad, panel.header_h / 2, style, fs * 0.75,
        color_to_ass(opts.time_color), ass_escape("Alt Alt / Esc: fechar"))
    if #panel.lines == 0 then
        out[#out + 1] = string.format("{\\an7\\pos(%g,%g)%s\\fs%g\\1c&H%s&}%s",
            x0 + pad, panel.list_y + pad, style, fs * 0.85,
            color_to_ass(opts.time_color),
            ass_escape("Esta legenda não tem texto."))
    end

    local clip = string.format("\\clip(%g,%g,%g,%g)", x0, panel.list_y, x1, panel.h)
    panel.visible = {}
    local y = panel.list_y
    local i = panel.first
    while panel.lines[i] and y < panel.h do
        local l, r = panel.lines[i], row(i)
        local y1 = y + r.h
        panel.visible[#panel.visible + 1] = {i = i, y0 = y, y1 = y1}
        if i == panel.current then
            out[#out + 1] = rect(x0 + 1, y, x1, y1, opts.current_color, 0.85)
        elseif i == panel.hover then
            out[#out + 1] = rect(x0 + 1, y, x1, y1, opts.hover_color, 0.9)
        end
        local ty = y + panel.vpad + panel.line_h / 2
        out[#out + 1] = string.format("{\\an4\\pos(%g,%g)%s%s\\fs%g\\1c&H%s&}%s",
            x0 + pad, ty, style, clip, fs * 0.8,
            color_to_ass(i == panel.current and opts.text_color or opts.time_color),
            format_time(l.start + sub_delay()))
        for n, text in ipairs(r.text) do
            out[#out + 1] = string.format("{\\an4\\pos(%g,%g)%s%s\\fs%g\\1c&H%s&}%s",
                x0 + pad + panel.time_w, ty + (n - 1) * panel.line_h, style,
                clip, fs, color_to_ass(opts.text_color), ass_escape(text))
        end
        y = y1
        i = i + 1
    end

    -- Scrollbar, by line index.
    local last = max_first()
    if last > 1 then
        local bar_h = math.max(fs, panel.list_h * (#panel.visible / #panel.lines))
        local bar_y = panel.list_y + (panel.list_h - bar_h) * (panel.first - 1) / (last - 1)
        out[#out + 1] = rect(x1 - fs * 0.25, bar_y, x1, bar_y + bar_h,
                             opts.time_color, 0.7)
    end

    overlay.res_x, overlay.res_y = panel.w, panel.h
    overlay.data = table.concat(out, "\n")
    overlay:update()
    mp.set_mouse_area(panel.x0, 0, panel.x1, panel.h, "sub_list_panel")
end

-- Keeps the current line in view while playing, unless the user scrolled.
local function follow_current()
    local cur = current_index()
    if cur == panel.current then
        return false
    end
    panel.current = cur
    if cur and mp.get_time() - panel.scrolled_at > opts.follow_delay then
        local v = panel.visible or {}
        local shown = false
        for n, row_pos in ipairs(v) do
            -- The last row may be cut off at the bottom.
            if row_pos.i == cur and (n < #v or row_pos.y1 <= panel.h) then
                shown = true
            end
        end
        if not shown then
            scroll_to(cur)
        end
    end
    return true
end

local function row_at_mouse()
    local m = mp.get_property_native("mouse-pos")
    if not m or not panel.visible or m.x < panel.x0 then
        return nil
    end
    for _, r in ipairs(panel.visible) do
        if m.y >= r.y0 and m.y < r.y1 then
            return r.i
        end
    end
    return nil
end

local function scroll(n)
    panel.first = panel.first + n
    panel.scrolled_at = mp.get_time()
    render()
    panel.hover = row_at_mouse()
    render()
end

local function click()
    local i = row_at_mouse()
    if not i then
        return
    end
    -- A little past the start, so the line is surely displayed.
    local t = panel.lines[i].start + sub_delay() + 0.01
    mp.commandv("seek", tostring(t), "absolute+exact")
    panel.current = i
    render()
end

local close_panel

local function on_mouse_pos()
    if panel then
        local hover = row_at_mouse()
        if hover ~= panel.hover then
            panel.hover = hover
            render()
        end
    end
end

local function on_time()
    if panel and follow_current() then
        render()
    end
end

local function open_panel()
    panel = {lines = load_lines(), first = 1, scrolled_at = 0, wrapped = {}}
    if not layout() then
        panel = nil
        return
    end
    if opts.shrink_video then
        panel.old_margin = mp.get_property_native("video-margin-ratio-right")
        mp.set_property_native("video-margin-ratio-right",
                               (panel.x1 - panel.x0) / panel.w)
    end
    panel.current = current_index()
    if panel.current then
        scroll_to(panel.current)
    end

    -- Mouse input over the panel goes to it only (no fullscreen toggling on
    -- double-click, no window dragging); everywhere else works as usual.
    mp.set_key_bindings({
        {"MBTN_LEFT", click},
        {"MBTN_LEFT_DBL", function() end},
        {"MBTN_RIGHT", function() end},
        {"WHEEL_UP", function() scroll(-2) end},
        {"WHEEL_DOWN", function() scroll(2) end},
    }, "sub_list_panel", "force")
    mp.enable_key_bindings("sub_list_panel", "allow-hide-cursor")
    mp.add_forced_key_binding("ESC", "_sub_list_close", function() close_panel() end)

    mp.observe_property("mouse-pos", "native", on_mouse_pos)
    mp.observe_property("time-pos", "native", on_time)
    render()
end

close_panel = function()
    if not panel then
        return
    end
    mp.disable_key_bindings("sub_list_panel")
    mp.remove_key_binding("_sub_list_close")
    mp.unobserve_property(on_mouse_pos)
    mp.unobserve_property(on_time)
    if panel.old_margin then
        mp.set_property_native("video-margin-ratio-right", panel.old_margin)
    end
    overlay:remove()
    panel = nil
end

local function toggle()
    if panel then
        close_panel()
    else
        open_panel()
    end
end

mp.add_key_binding(nil, "toggle", toggle)

-- Alt tapped twice (ALT_TAP is a press and release of Alt on its own).
mp.add_key_binding("ALT_TAP", "alt-tap", function()
    local now = mp.get_time()
    if now - last_alt_tap <= opts.double_tap_time then
        last_alt_tap = 0
        toggle()
    else
        last_alt_tap = now
    end
end)

-- Keep the list up to date with track changes and edits.
local function reload()
    if panel then
        panel.lines = load_lines()
        panel.wrapped = {}
        panel.current = nil
        follow_current()
        render()
    end
end
mp.observe_property("current-tracks/sub/id", "native", reload)
mp.observe_property("sub-text", "native", function()
    -- Edits change the text of the current line; deleting it changes the
    -- number of lines.
    if not panel then
        return
    end
    local fresh = load_lines()
    local cur = panel.current and panel.lines[panel.current]
    if #fresh ~= #panel.lines or
       (cur and fresh[panel.current] and fresh[panel.current].text ~= cur.text)
    then
        panel.lines = fresh
        panel.wrapped = {}
        panel.current = nil
        follow_current()
        render()
    end
end)
mp.observe_property("osd-dimensions", "native", function() render() end)
mp.register_event("file-loaded", reload)
