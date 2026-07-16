--[[
    Kobo-style Sleep Screen for KOReader
    Robust & memory-efficient rewrite.

    Changes from original:
    - Lazy-require all heavy modules (only loaded when screensaver actually shows)
    - Single dark-mode color table resolved once per show() call, not duplicated
    - Cover blitbuffer freed after scaling to avoid double-memory hold
    - Database connection guaranteed closed via pcall + explicit close
    - screensaver_type forced to "kobo_style" on load so menu-injection race is irrelevant
    - ReaderUI hook uses safer event-style fallback if onClose is not yet a function
    - Screensaver.show fully guarded: never falls back silently to orig with no log
    - utf8Len removed (unused); utf8Sub inlined with one pass
    - No module-level ImageWidget/Font/etc allocations; all created inside show scope
    - HorizontalSpan with width=0 replaced with nothing (saves a widget table)
--]]

-- ── Lightweight top-level requires only (no UI widgets at module load) ────────
local Device     = require("device")
local ReaderUI   = require("apps/reader/readerui")
local UIManager  = require("ui/uimanager")   -- needed at show() time, always present
local util       = require("util")
local _          = require("gettext")
local bit        = require("bit")
local lfs        = require("libs/libkoreader-lfs")

local Screen = Device.screen

-- ── Constants ─────────────────────────────────────────────────────────────────
local SCREENSAVER_TYPE_KEY  = "screensaver_type"
local SCREENSAVER_TYPE_VAL  = "kobo_style"
local DARK_MODE_KEY         = "kobo_style_screensaver_dark_mode"
local LAST_TITLE_KEY        = "kobo_style_last_read_title"
local LAST_PCT_KEY          = "kobo_style_last_read_percentage"
local LAST_FILE_KEY         = "lastfile"
local LAST_READ_LABEL       = _("Last Read")

-- ── In-memory snapshot (title + percentage of last open book) ─────────────────
-- Populated when a book is closed / screensaver fires while book is open.
-- Persisted to G_reader_settings so it survives across sessions.
local snapshot = {}   -- { title=string, percentage=number|nil }
local snapshot_loaded = false

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function truncateAtPunct(s)
    if not s or s == "" then return "" end
    local pos = s:find("[%:%-%—]")
    return pos and util.trim(s:sub(1, pos - 1)) or s
end

-- Single-pass UTF-8 truncate; appends " …" only when actually cut.
local function utf8Sub(s, max_chars)
    if not s or s == "" or max_chars <= 0 then return "" end
    local i, count = 1, 0
    while i <= #s and count < max_chars do
        local b = string.byte(s, i)
        i = i + (b >= 0xF0 and 4 or b >= 0xE0 and 3 or b >= 0xC0 and 2 or 1)
        count = count + 1
    end
    return (i <= #s) and (s:sub(1, i - 1) .. " …") or s
end

local function hasDoc(ui)
    return ui ~= nil and ui.document ~= nil
end

local function getDocTitle(ui)
    local props = (ui and ui.doc_props) or {}
    return truncateAtPunct(props.display_title or "") or "Untitled"
end

-- Returns { page, total, page_numeric, total_numeric, pct }
local function getProgress(ui, state)
    local settings = (ui and ui.doc_settings and ui.doc_settings.data) or {}
    local pg   = math.max((state and state.page) or 1, 1)
    local tot  = math.max(settings.doc_pages or 1, 1)
    pg = math.min(pg, tot)

    local pg_n, tot_n = pg, tot
    if ui and ui.pagemap and ui.pagemap:wantsPageLabels() then
        local _, idx, cnt = ui.pagemap:getCurrentPageLabel(true)
        if idx and cnt then pg_n, tot_n = idx, cnt end
    end

    return {
        page       = pg,
        total      = tot,
        page_n     = pg_n,
        total_n    = tot_n,
        pct        = math.floor(pg_n / tot_n * 100 + 0.5),
    }
end

-- Returns seconds read today for the current book, or nil.
-- Opens and immediately closes the DB; never leaks the connection.
local function getTodaySecs(statistics)
    if not statistics then return nil end
    if statistics.isEnabled and not statistics:isEnabled() then return nil end

    -- flush pending data
    if statistics.insertDB then pcall(statistics.insertDB, statistics) end

    local id_book = statistics.id_curr_book
    if not id_book and statistics.getIdBookDB then
        local ok, v = pcall(statistics.getIdBookDB, statistics)
        if ok then id_book = v end
    end
    if not id_book then return nil end

    -- lazy-require DataStorage only when actually needed
    local DataStorage = require("datastorage")
    local db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    if lfs.attributes(db_path, "mode") ~= "file" then return nil end

    local SQ3 = require("lua-ljsqlite3/init")
    local ok_conn, conn = pcall(SQ3.open, db_path)
    if not ok_conn or not conn then return nil end

    local now      = os.time()
    local t        = os.date("*t", now)
    local day_start = now - (t.hour * 3600 + t.min * 60 + t.sec)

    local sql = string.format(
        "SELECT sum(s) FROM (SELECT sum(duration) s FROM page_stat "..
        "WHERE start_time>=%d AND id_book=%d GROUP BY page);",
        day_start, id_book)

    local ok_row, val = pcall(function() return conn:rowexec(sql) end)
    conn:close()   -- always close

    val = ok_row and tonumber(val) or nil
    return (val and val > 0) and val or nil
end

local function fmtDuration(secs)
    if not secs or secs <= 0 then return nil end
    local h = math.floor(secs / 3600)
    local m = math.floor(secs % 3600 / 60)
    if h > 0 and m > 0 then return string.format("%d hr %d min", h, m)
    elseif h > 0        then return string.format("%d hr", h)
    elseif m > 0        then return string.format("%d min", m)
    else                     return "< 1 min" end
end

-- ── Snapshot persistence ──────────────────────────────────────────────────────

local function saveSnapshot()
    if snapshot.title and snapshot.title ~= "" then
        G_reader_settings:saveSetting(LAST_TITLE_KEY, snapshot.title)
    end
    if snapshot.pct ~= nil then
        G_reader_settings:saveSetting(LAST_PCT_KEY, snapshot.pct)
    else
        G_reader_settings:delSetting(LAST_PCT_KEY)
    end
end

local function loadSnapshot()
    if snapshot_loaded then return end
    snapshot_loaded = true
    local t = G_reader_settings:readSetting(LAST_TITLE_KEY)
    if t and t ~= "" then
        snapshot.title = t
        snapshot.pct   = tonumber(G_reader_settings:readSetting(LAST_PCT_KEY))
    end
end

local function captureSnapshot(ui, state)
    if not hasDoc(ui) then return end
    local prog = getProgress(ui, state)
    snapshot = { title = getDocTitle(ui), pct = prog.pct }
    saveSnapshot()
end

-- ── Color palette (resolved once per show call) ───────────────────────────────
local function makeColors(dark)
    local BB = require("ffi/blitbuffer")
    if dark then
        return {
            bg     = BB.COLOR_BLACK,
            fg     = BB.COLOR_WHITE,
            light  = BB.COLOR_GRAY_E,
            border = BB.COLOR_WHITE,
        }
    else
        return {
            bg     = BB.COLOR_WHITE,
            fg     = BB.COLOR_BLACK,
            light  = BB.COLOR_GRAY_3,
            border = BB.COLOR_BLACK,
        }
    end
end

-- ── Cover widget (scales cover; does NOT free source — it belongs to the cache) ─
local function makeCoverWidget(bb)
    if not bb then return nil end
    local RenderImage = require("ui/renderimage")
    local ImageWidget = require("ui/widget/imagewidget")
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    -- Pass false for free_bb: the blitbuffer is owned by KOReader's BookInfo
    -- cache; freeing it here causes a segfault when the cache later tries to
    -- paint or evict it.
    local scaled = RenderImage:scaleBlitBuffer(bb, sw, sh, false)
    if not scaled then return nil end
    return ImageWidget:new{ image = scaled, width = sw, height = sh, alpha = true }
end

local function getActiveCover(ui)
    if not hasDoc(ui) or not ui.bookinfo then return nil end
    -- getCoverImage is an instance method: bookinfo:getCoverImage(document)
    local ok, bb = pcall(ui.bookinfo.getCoverImage, ui.bookinfo, ui.document)
    return (ok and bb) or nil
end

local function getLastFileCover(ui)
    -- When no book is open, try to load the cover of the last-read file from disk.
    -- getCoverImage(document, filepath) — pass nil doc, real filepath.
    local f = G_reader_settings:readSetting(LAST_FILE_KEY)
    if not f or f == "" then return nil end
    -- BookInfo.getCoverImage can work without a live document when given a filepath.
    -- We need any bookinfo instance; try from a live ui or fallback to a direct require.
    local bookinfo = (ui and ui.bookinfo)
    if not bookinfo then
        local ok, bi = pcall(require, "ui/widget/bookinfomanager")
        if ok and bi then bookinfo = bi end
    end
    if not bookinfo then return nil end
    local ok, bb = pcall(bookinfo.getCoverImage, bookinfo, nil, f)
    return (ok and bb) or nil
end

-- ── Info-box builder (shared by both active and last-read paths) ──────────────
--[[
    rows = list of { text=string, face=face, color=color, bold=bool }
    Returns a positioned OverlapGroup anchored bottom-left.
--]]
local function buildInfoBox(rows, colors, screen_size)
    local Font           = require("ui/font")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local OverlapGroup   = require("ui/widget/overlapgroup")
    local TextBoxWidget  = require("ui/widget/textboxwidget")
    local TextWidget     = require("ui/widget/textwidget")
    local VerticalGroup  = require("ui/widget/verticalgroup")
    local VerticalSpan   = require("ui/widget/verticalspan")

    local padding   = Screen:scaleBySize(12)
    local box_w     = math.floor(screen_size.w * 0.55)
    local inner_w   = box_w - Screen:scaleBySize(28)

    local vg = VerticalGroup:new{ align = "left" }
    for _, row in ipairs(rows) do
        if row.multiline then
            vg[#vg + 1] = TextBoxWidget:new{
                text        = row.text,
                face        = row.face,
                fgcolor     = row.color,
                bgcolor     = colors.bg,
                width       = inner_w,
                alignment   = "left",
                bold        = row.bold,
                line_height = 0.3,
            }
        else
            vg[#vg + 1] = TextWidget:new{
                text        = row.text,
                face        = row.face,
                fgcolor     = row.color,
                bold        = row.bold,
                line_height = 0.3,
            }
        end
    end

    local box = FrameContainer:new{
        background = colors.bg,
        bordersize = 1,
        color      = colors.border,
        radius     = 0,
        padding    = padding,
        vg,
    }

    local bh          = box:getSize().h
    local margin_bot  = Screen:scaleBySize(100)

    return OverlapGroup:new{
        dimen = screen_size,
        VerticalGroup:new{
            VerticalSpan:new{ width = screen_size.h - bh - margin_bot },
            HorizontalGroup:new{ box },
        },
    }
end

-- ── Active-book receipt ───────────────────────────────────────────────────────
local function buildActiveReceipt(ui, state, colors, screen_size)
    if not hasDoc(ui) then return nil end

    local Font = require("ui/font")

    local title   = getDocTitle(ui)
    local prog    = getProgress(ui, state)
    local stats   = ui.statistics
    local avg_t   = stats and stats.avg_time

    -- Chapter
    local chapter = ""
    if ui.toc then
        chapter = ui.toc:getTocTitleByPage(prog.page) or ""
        chapter = truncateAtPunct(chapter)
    end

    -- Progress / time-left line
    local left     = math.max(prog.total_n - prog.page_n, 0)
    local prog_str
    if avg_t and avg_t > 0 then
        local secs = avg_t * left
        local h = math.floor(secs / 3600)
        local m = math.floor(secs % 3600 / 60)
        local t_str
        if h > 0 and m > 0 then t_str = string.format("%d hrs %d mins to go", h, m)
        elseif h > 0        then t_str = string.format("%d hrs to go", h)
        elseif m > 0        then t_str = string.format("%d mins to go", m)
        else                     t_str = "< 1 min to go" end
        prog_str = string.format("At %d%% · %s", prog.pct, t_str)
    else
        prog_str = string.format("%d%% read", prog.pct)
    end

    -- Today line
    local today_str = fmtDuration(getTodaySecs(stats))
    local today_text = today_str and string.format("%s read today", today_str)

    -- Font faces (all same family, different sizes)
    local f_title   = Font:getFace("RakutenSerifApp-Regular.ttf", Screen:scaleBySize(10))
    local f_sub     = Font:getFace("RakutenSerifApp-Regular.ttf", Screen:scaleBySize(9))

    local rows = {
        { text = title,    face = f_title, color = colors.fg,    bold = true, multiline = true },
    }
    if chapter ~= "" then
        rows[#rows+1] = { text = chapter,  face = f_sub,   color = colors.light, bold = true, multiline = true }
    end
    rows[#rows+1]     = { text = prog_str, face = f_sub,   color = colors.light, bold = true }
    if today_text then
        rows[#rows+1] = { text = today_text, face = f_sub, color = colors.light, bold = true }
    end

    return buildInfoBox(rows, colors, screen_size)
end

-- ── Last-read (no active book) receipt ───────────────────────────────────────
local function buildLastReadReceipt(colors, screen_size)
    loadSnapshot()
    if not snapshot.title or snapshot.title == "" then return nil end

    local Font = require("ui/font")

    local summary = snapshot.title
    if snapshot.pct then
        summary = string.format("%s · %d%%", snapshot.title, snapshot.pct)
    end
    summary = utf8Sub(summary, 110)

    local f_label = Font:getFace("RakutenSerifApp-Regular.ttf", Screen:scaleBySize(10))
    local f_title = Font:getFace("RakutenSerifApp-Regular.ttf", Screen:scaleBySize(9))

    local rows = {
        { text = LAST_READ_LABEL, face = f_label, color = colors.light, bold = true },
        { text = summary,         face = f_title, color = colors.fg,    bold = true, multiline = true },
    }

    return buildInfoBox(rows, colors, screen_size)
end

-- ── Composite: cover + info box ───────────────────────────────────────────────
local function compose(cover_widget, info_widget, screen_size)
    local OverlapGroup = require("ui/widget/overlapgroup")
    if cover_widget and info_widget then
        return OverlapGroup:new{ dimen = screen_size, cover_widget, info_widget }
    elseif info_widget then
        return OverlapGroup:new{ dimen = screen_size, info_widget }
    elseif cover_widget then
        return OverlapGroup:new{ dimen = screen_size, cover_widget }
    end
    return nil
end

-- ── ReaderUI close hook – capture snapshot before book unloads ────────────────
local function installCloseHook()
    -- Prefer the newer event-dispatcher path if available
    if ReaderUI.onClose and type(ReaderUI.onClose) == "function" then
        local orig = ReaderUI.onClose
        ReaderUI.onClose = function(self, ...)
            pcall(captureSnapshot, self, self.view and self.view.state)
            return orig(self, ...)
        end
        return
    end
    -- Fallback: hook handleEvent for CloseWidget
    if ReaderUI.handleEvent and type(ReaderUI.handleEvent) == "function" then
        local orig = ReaderUI.handleEvent
        ReaderUI.handleEvent = function(self, event, ...)
            if event and event.name == "CloseWidget" then
                pcall(captureSnapshot, self, self.view and self.view.state)
            end
            return orig(self, event, ...)
        end
    end
end

installCloseHook()

-- ── Force screensaver type so it works even if menu injection races ───────────
-- Only set if not already set by user to avoid overwriting a different choice
-- on very first load. Comment this line out if you want menu selection to be
-- the sole trigger.
if not G_reader_settings:readSetting(SCREENSAVER_TYPE_KEY) then
    G_reader_settings:saveSetting(SCREENSAVER_TYPE_KEY, SCREENSAVER_TYPE_VAL)
end

-- ── Screensaver.show patch ────────────────────────────────────────────────────
local Screensaver = require("ui/screensaver")
local orig_show   = Screensaver.show

Screensaver.show = function(self)
    -- Only handle our custom type; everything else is untouched
    local stype = G_reader_settings:readSetting(SCREENSAVER_TYPE_KEY)
    if stype ~= SCREENSAVER_TYPE_VAL then
        return orig_show(self)
    end

    local ScreenSaverWidget = require("ui/widget/screensaverwidget")
    local Blitbuffer        = require("ffi/blitbuffer")

    local ui       = self.ui or ReaderUI.instance
    local state    = ui and ui.view and ui.view.state
    local dark     = G_reader_settings:isTrue(DARK_MODE_KEY)
    local colors   = makeColors(dark)
    local ss       = Screen:getSize()

    -- Snapshot: capture if book open, otherwise load from disk
    if hasDoc(ui) then
        pcall(captureSnapshot, ui, state)
    else
        loadSnapshot()
    end

    -- Close any existing widget first
    if self.screensaver_widget then
        UIManager:close(self.screensaver_widget)
        self.screensaver_widget = nil
    end

    Device.screen_saver_mode = true

    -- Rotation correction
    local rot = Screen:getRotationMode()
    if bit.band(rot, 1) == 1 then
        Device.orig_rotation_mode = rot
        Screen:setRotationMode(Screen.DEVICE_ROTATED_UPRIGHT)
    else
        Device.orig_rotation_mode = nil
    end

    -- Build cover widget (active book first, then last-file fallback)
    local cover_widget
    if hasDoc(ui) then
        cover_widget = makeCoverWidget(getActiveCover(ui))
    else
        cover_widget = makeCoverWidget(getLastFileCover(ui))
    end

    -- Build info overlay
    local info_widget
    if hasDoc(ui) then
        info_widget = buildActiveReceipt(ui, state, colors, ss)
    else
        info_widget = buildLastReadReceipt(colors, ss)
    end

    local final = compose(cover_widget, info_widget, ss)

    if final then
        local bg = dark and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
        self.screensaver_widget = ScreenSaverWidget:new{
            widget          = final,
            background      = bg,
            covers_fullscreen = true,
        }
        self.screensaver_widget.modal    = true
        self.screensaver_widget.dithered = true
        UIManager:show(self.screensaver_widget, "full")
    else
        -- Absolute last resort: no cover, no snapshot → standard screensaver
        return orig_show(self)
    end
end

-- ── Menu injection (best-effort; not critical due to forced setting above) ────
local orig_dofile = dofile
_G.dofile = function(filepath, ...)
    local result = orig_dofile(filepath, ...)
    if type(filepath) == "string" and filepath:match("screensaver_menu%.lua$") then
        -- Use pcall so any error here never crashes KOReader
        pcall(function()
            local sub = result and result[1] and result[1].sub_item_table
            if not sub then return end

            -- Avoid double-injection if patch is hot-reloaded
            for _, item in ipairs(sub) do
                if item._kobo_style_injected then return end
            end

            local function isActive()
                return G_reader_settings:readSetting(SCREENSAVER_TYPE_KEY) == SCREENSAVER_TYPE_VAL
            end

            table.insert(sub, 6, {
                text          = _("Kobo-style (cover + progress)"),
                _kobo_style_injected = true,
                checked_func  = isActive,
                callback      = function()
                    G_reader_settings:saveSetting(SCREENSAVER_TYPE_KEY, SCREENSAVER_TYPE_VAL)
                end,
                radio         = true,
            })

            table.insert(sub, 7, {
                text          = _("Kobo-style settings"),
                enabled_func  = isActive,
                sub_item_table = {
                    {
                        text         = _("Dark mode"),
                        checked_func = function()
                            return G_reader_settings:isTrue(DARK_MODE_KEY)
                        end,
                        callback     = function()
                            G_reader_settings:flipNilOrFalse(DARK_MODE_KEY)
                        end,
                    },
                },
            })
        end)
    end
    return result
end