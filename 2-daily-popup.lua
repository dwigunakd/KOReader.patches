--[[
Reading Stats Table - Daily reading history table
Shows: Date | Time | Pages | Avg Pace | Progress%
Displays statistics from the past N days with popup-style layout
Version: 1.5 (Fixed - Uses same query method as statistics plugin)
Based on: 2-reading-stats-popup.lua
]]--

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Math = require("optmath")
local SQ3 = require("lua-ljsqlite3/init")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local util = require("util")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local gettext = require("gettext")
local ReaderUI = require("apps/reader/readerui")

local PATCH_L10N = {
    en = {
        ["DATE"] = "DATE",
        ["TIME"] = "TIME",
        ["PAGES"] = "PAGES",
        ["PACE"] = "PACE",
        ["PROGRESS"] = "PROGRESS",
        ["Days Read"] = "Days Reading",
        ["reading in this session"] = "reading in this session",
    },
    vi = {
        ["DATE"] = "NGÀY",
        ["TIME"] = "THỜI GIAN",
        ["PAGES"] = "TRANG",
        ["PACE"] = "NHỊP ĐỘ",
        ["PROGRESS"] = "TIẾN ĐỘ",
        ["Days Read"] = "Ngày Đọc",
        ["reading in this session"] = "đọc trong phiên này",
    },
}

local function l10nLookup(msg)
    local lang = "en"
    if G_reader_settings and G_reader_settings.readSetting then
        lang = G_reader_settings:readSetting("language") or "en"
    end
    local lang_base = lang:match("^([a-z]+)") or lang
    local map = PATCH_L10N[lang] or PATCH_L10N[lang_base] or PATCH_L10N.en or {}
    return map[msg]
end

local function _(msg)
    return l10nLookup(msg) or gettext(msg)
end

local stats_db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"

local ROWS_PER_PAGE = 3
local _current_page = 1  -- module-level: persists across close/reopen cycles

local function truncateTitle(title, max_chars)
    if not title then return "" end
    if #title > max_chars then
        return title:sub(1, max_chars - 3) .. "..."
    end
    return title
end

local function formatDate(iso_date)
    -- Convert YYYY-MM-DD to DD/MM/YY
    local year, month, day = iso_date:match("(%d+)-(%d+)-(%d+)")
    if year then
        local yy = year:sub(-2)
        return string.format("%s/%s/%s", day, month, yy)
    end
    return iso_date
end

local function formatSeconds(seconds)
    if not seconds or seconds <= 0 then
        return "0m 0s"
    end
    
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs = math.floor(seconds % 60)
    
    if hours > 0 then
        -- Format: 2h 20m 10s
        return string.format("%dh %dm %ds", hours, minutes, secs)
    else
        -- Format: 0m 32s or 1m 20s
        return string.format("%dm %ds", minutes, secs)
    end
end

local function formatPace(seconds_per_page)
    if not seconds_per_page or seconds_per_page <= 0 then
        return "-"
    end
    
    local hours = math.floor(seconds_per_page / 3600)
    local remaining_seconds = seconds_per_page % 3600
    local minutes = math.floor(remaining_seconds / 60)
    local secs = math.floor(remaining_seconds % 60)
    
    if hours > 0 then
        return string.format("%dh %dm %ds", hours, minutes, secs)
    elseif minutes > 0 then
        return string.format("%dm %ds", minutes, secs)
    else
        return string.format("%ds", secs)
    end
end

-- Same query method as statistics.koplugin uses
local function getReadingStatsForDays(book_id, days)
    if not book_id or not days or days <= 0 then return {} end
    
    local conn = SQ3.open(stats_db_path)
    if not conn then return {} end
    
    local sql = string.format([[
        SELECT 
            date(ps.start_time, 'unixepoch', 'localtime') AS dates,
            count(DISTINCT ps.page) AS pages,
            sum(ps.duration) AS durations,
            (SELECT (page * 1.0 / total_pages)
             FROM page_stat_data ps2
             WHERE ps2.id_book = ps.id_book
               AND date(ps2.start_time, 'unixepoch', 'localtime') = date(ps.start_time, 'unixepoch', 'localtime')
             ORDER BY ps2.start_time DESC
             LIMIT 1) AS total_percentage
        FROM page_stat_data ps
        WHERE ps.id_book = %d
            AND date(ps.start_time, 'unixepoch', 'localtime') >= date('now', '-' || %d || ' days')
        GROUP BY date(ps.start_time, 'unixepoch', 'localtime')
        ORDER BY dates DESC;
    ]], book_id, days)
    
    local results = conn:exec(sql)
    conn:close()
    
    local stats = {}
    if results and results.dates then
        for i = 1, #results.dates do
            table.insert(stats, {
                date = results.dates[i],
                pages = tonumber(results.pages[i]) or 0,
                duration = tonumber(results.durations[i]) or 0,
                progress = tonumber(results.total_percentage[i]) or 0,
            })
        end
    end
    
    return stats
end

-- EXACT SAME METHOD AS statistics.koplugin getCurrentBookStats()
-- This is the key - query from page_stat VIEW, not page_stat_data directly
local function getCurrentSessionDuration(book_id, start_current_period)
    if not book_id or not start_current_period then return 0 end

    local conn = SQ3.open(stats_db_path)
    if not conn then return 0 end

    -- Use page_stat VIEW like the statistics plugin does
    local sql_stmt = [[
        SELECT count(*),
               sum(sum_duration)
        FROM   (
                    SELECT sum(duration)    AS sum_duration
                    FROM   page_stat
                    WHERE  start_time >= %d
                    GROUP  BY id_book, page
               );
    ]]
    local current_pages, current_duration = conn:rowexec(string.format(sql_stmt, start_current_period))
    conn:close()

    if current_duration == nil then
        current_duration = 0
    end

    return tonumber(current_duration) or 0
end

local function getBookTitle(ui)
    if not ui then return "" end
    
    local book_title = ui.doc_props and ui.doc_props.display_title or ""
    
    local colon_pos = book_title:find(":")
    if colon_pos then
        book_title = book_title:sub(1, colon_pos - 1)
    end
    
    return book_title
end

local function getTotalDaysRead(book_id)
    if not book_id then return 0 end
    
    local conn = SQ3.open(stats_db_path)
    if not conn then return 0 end
    
    local sql = string.format([[
        SELECT count(DISTINCT date(ps.start_time, 'unixepoch', 'localtime'))
        FROM page_stat_data ps
        WHERE ps.id_book = %d;
    ]], book_id)
    
    local result = conn:rowexec(sql)
    conn:close()
    
    return tonumber(result) or 0
end

local function fixedCol(widget, width)
    return LeftContainer:new{
        dimen = Geom:new{ w = width, h = widget:getSize().h },
        widget,
    }
end

local function buildColumnSeparator(column_gap, height)
    local v_padding = Size.padding.small
    return HorizontalGroup:new{
        HorizontalSpan:new{ width = column_gap },
        VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ height = v_padding },
            LineWidget:new{
                dimen = Geom:new{ w = Size.line.thin, h = height - 2 * v_padding },
                background = Blitbuffer.COLOR_LIGHT_GRAY,
            },
            VerticalSpan:new{ height = v_padding },
        },
        HorizontalSpan:new{ width = column_gap },
    }
end

local function buildRowSeparator(width)
    return LineWidget:new{
        dimen = Geom:new{ w = width, h = Size.line.thin },
        background = Blitbuffer.COLOR_LIGHT_GRAY,
    }
end

local function buildLayout(screen_w, padding_h, column_gap)
    local col_width = math.floor((screen_w - 2 * padding_h - 8 * column_gap) / 5)
    return {
        full_width = screen_w,
        padding_h = padding_h,
        column_gap = column_gap,
        col_width = col_width,
    }
end

local function buildTableHeader(fonts, layout)
    local headers = { _("DATE"), _("TIME"), _("PAGES"), _("PACE"), _("PROGRESS") }
    local header_row = HorizontalGroup:new{ align = "center" }
    
    for i, header_text in ipairs(headers) do
        local header_widget = TextWidget:new{ text = header_text, face = fonts.header }
        table.insert(header_row, fixedCol(header_widget, layout.col_width))
        if i < #headers then
            table.insert(header_row, buildColumnSeparator(layout.column_gap, 28))
        end
    end
    
    return FrameContainer:new{
        background = Blitbuffer.COLOR_GRAY_E,
        bordersize = 0,
        padding_top = Size.padding.default,
        padding_bottom = Size.padding.default,
        padding_left = layout.padding_h,
        padding_right = layout.padding_h,
        header_row,
    }
end

local function buildTableRows(stats_data, fonts, layout)
    local rows = VerticalGroup:new{ align = "left" }
    
    for idx, day_stat in ipairs(stats_data) do
        local pace_seconds_per_page = day_stat.pages > 0 and (day_stat.duration / day_stat.pages) or 0
        
        local date_widget = TextWidget:new{ text = formatDate(day_stat.date), face = fonts.cell }
        local time_widget = TextWidget:new{ text = formatSeconds(day_stat.duration), face = fonts.cell }
        local pages_widget = TextWidget:new{ text = tostring(day_stat.pages), face = fonts.cell }
        local pace_widget = TextWidget:new{ text = formatPace(pace_seconds_per_page), face = fonts.cell }
        local progress_pct = string.format("%.1f%%", day_stat.progress * 100)
        local progress_widget = TextWidget:new{ text = progress_pct, face = fonts.cell }
        
        local row = HorizontalGroup:new{
            align = "center",
            fixedCol(date_widget, layout.col_width),
            buildColumnSeparator(layout.column_gap, 24),
            fixedCol(time_widget, layout.col_width),
            buildColumnSeparator(layout.column_gap, 24),
            fixedCol(pages_widget, layout.col_width),
            buildColumnSeparator(layout.column_gap, 24),
            fixedCol(pace_widget, layout.col_width),
            buildColumnSeparator(layout.column_gap, 24),
            fixedCol(progress_widget, layout.col_width),
        }
        
        table.insert(rows, row)
        if idx < #stats_data then
            table.insert(rows, VerticalSpan:new{ height = Size.padding.small })
            table.insert(rows, buildRowSeparator(layout.full_width - 2 * layout.padding_h))
            table.insert(rows, VerticalSpan:new{ height = Size.padding.small })
        end
    end
    
    return rows
end

local function buildPaginationBar(fonts, layout, current_page, total_pages)
    local bar_h  = Screen:scaleBySize(48)
    local full_w = layout.full_width

    local can_prev = current_page > 1
    local can_next = current_page < total_pages

    -- 5 equal zones: «  ‹  1/2  ›  »
    local zone_w = math.floor(full_w / 5)
    -- Give the middle label zone any leftover pixels from rounding
    local lbl_w  = full_w - zone_w * 4

    local function makeZone(label, enabled, w)
        return CenterContainer:new{
            dimen = Geom:new{ w = w, h = bar_h },
            TextWidget:new{
                text = label,
                face = enabled and fonts.cell or fonts.header,
            },
        }
    end

    local function makeSep()
        return LineWidget:new{
            dimen = Geom:new{ w = Size.line.thin, h = Screen:scaleBySize(28) },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        }
    end

    local page_lbl = TextWidget:new{
        text = string.format("%d / %d", current_page, total_pages),
        face = fonts.cell,
    }
    local lbl_zone = CenterContainer:new{
        dimen = Geom:new{ w = lbl_w, h = bar_h },
        page_lbl,
    }

    local z_first = makeZone("«", can_prev, zone_w)
    local z_prev  = makeZone("‹", can_prev, zone_w)
    local z_next  = makeZone("›", can_next, zone_w)
    local z_last  = makeZone("»", can_next, zone_w)

    local bar = HorizontalGroup:new{ align = "center",
        z_first, makeSep(),
        z_prev,  makeSep(),
        lbl_zone, makeSep(),
        z_next,  makeSep(),
        z_last,
    }

    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding    = 0,
        bar,
    }

    -- Pre-calculated X ranges for each zone (no widget.dimen needed)
    local x0 = 0
    local x1 = zone_w          -- «  ends here
    local x2 = zone_w * 2      -- ‹  ends here
    local x3 = zone_w * 2 + lbl_w  -- label ends here
    local x4 = x3 + zone_w     -- ›  ends here
    -- »  ends at full_w

    local hits = {
        { enabled = can_prev, target = 1,                  x_min = x0, x_max = x1 },
        { enabled = can_prev, target = current_page - 1,   x_min = x1, x_max = x2 },
        { enabled = can_next, target = current_page + 1,   x_min = x3, x_max = x4 },
        { enabled = can_next, target = total_pages,         x_min = x4, x_max = full_w },
    }

    return frame, hits
end

Dispatcher:registerAction("reading_stats_table", {
    category = "none",
    event = "ShowReadingStatsTable",
    title = "Reading history",
    reader = true,
})

local ReadingStatsTable = InputContainer:extend{
    modal = true,
    ui = nil,
}

function ReadingStatsTable:init()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    
    self.screen_w = screen_w
    self.screen_h = screen_h
    
    self.fonts = {
        header  = Font:getFace("RakutenSerifApp-Bold.ttf", 18),
        cell    = Font:getFace("RakutenSerifApp-Bold.ttf", 20),
        title   = Font:getFace("RakutenSerifApp-Bold.ttf", 24),
        session = Font:getFace("RakutenSerifApp-Bold.ttf", 18),
    }
    
    self.layout = buildLayout(screen_w, Size.padding.large, Screen:scaleBySize(10))
    self.dimen = Geom:new{ w = screen_w, h = screen_h }
    
    self.stats_plugin = self.ui and self.ui.statistics
    
    self:buildContent()
    
    if Device:isTouchDevice() then
        self.ges_events.TapClose = {
            GestureRange:new{
                ges = "tap",
                range = self.dimen,
            }
        }
    end
    if Device:hasKeys() then
        self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end
end

function ReadingStatsTable:buildContent()
    -- 1. Flush finished pages to DB
    if self.stats_plugin then
        self.stats_plugin:insertDB()
    end
    
    local book_id = self.stats_plugin and self.stats_plugin.id_curr_book
    local all_stats = getReadingStatsForDays(book_id, 365)
    local book_title = truncateTitle(getBookTitle(self.ui), 30)
    local days_read = getTotalDaysRead(book_id)

    -- Pagination
    local total_rows  = #all_stats
    local total_pages = math.max(1, math.ceil(total_rows / ROWS_PER_PAGE))
    if _current_page > total_pages then _current_page = total_pages end
    if _current_page < 1 then _current_page = 1 end

    local page_start = (_current_page - 1) * ROWS_PER_PAGE + 1
    local page_end   = math.min(page_start + ROWS_PER_PAGE - 1, total_rows)
    local stats_data = {}
    for i = page_start, page_end do
        table.insert(stats_data, all_stats[i])
    end

    local title_text = string.format("%s - %d %s", book_title, days_read, _("Days Reading"))
    local title = TextWidget:new{ text = title_text, face = self.fonts.title }

    -- 2. Get duration from database (finished pages)
    local session_duration = getCurrentSessionDuration(
        book_id,
        self.stats_plugin and self.stats_plugin.start_current_period
    )

    -- 3. ADD THE LIVE SECONDS (The missing part)
    -- If we are currently on a page, calculate how long we've been here
    if self.stats_plugin and self.stats_plugin.page_start_time then
        local live_seconds = os.time() - self.stats_plugin.page_start_time
        if live_seconds > 0 then
            session_duration = session_duration + live_seconds
        end
    end

    local session_text = string.format("%s %s", formatSeconds(session_duration), _("reading in this session"))
    local session_widget = TextWidget:new{ text = session_text, face = self.fonts.session }

    local header = buildTableHeader(self.fonts, self.layout)
    local rows = buildTableRows(stats_data, self.fonts, self.layout)

    local pagination_frame, hits = buildPaginationBar(
        self.fonts, self.layout, _current_page, total_pages)
    self._pagination_hits = hits
    
    local title_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding_top = Size.padding.large,
        padding_bottom = Size.padding.small,
        padding_left = self.layout.padding_h,
        padding_right = self.layout.padding_h,
        title,
    }
    local session_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding_top = 0,
        padding_bottom = Size.padding.default,
        padding_left = self.layout.padding_h,
        padding_right = self.layout.padding_h,
        session_widget,
    }
    local rows_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding_top = Size.padding.default,
        padding_bottom = Size.padding.default,
        padding_left = self.layout.padding_h,
        padding_right = self.layout.padding_h,
        rows,
    }
    local sep_line = LineWidget:new{
        dimen = Geom:new{ w = self.layout.full_width, h = Size.line.thin },
        background = Blitbuffer.COLOR_LIGHT_GRAY,
    }

    -- Y position of the pagination bar = sum of all heights above it
    self._pagination_bar_y = title_frame:getSize().h
                           + session_frame:getSize().h
                           + header:getSize().h
                           + rows_frame:getSize().h
                           + sep_line:getSize().h

    local bottom_line = LineWidget:new{
        dimen = Geom:new{ w = self.layout.full_width, h = Size.line.medium },
        background = Blitbuffer.COLOR_BLACK,
    }

    -- Bottom edge of popup = everything including the pagination bar and bottom line
    self._popup_bottom_y = self._pagination_bar_y
                         + pagination_frame:getSize().h
                         + bottom_line:getSize().h

    local table_content = VerticalGroup:new{
        align = "left",
        title_frame,
        session_frame,
        header,
        rows_frame,
        sep_line,
        pagination_frame,
        bottom_line,
    }
    
    self.popup_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        radius = 0,
        padding = 0,
        width = self.screen_w,
        table_content,
    }

    self[1] = self.popup_frame
end

function ReadingStatsTable:onShow()
    UIManager:setDirty(self, function()
        return "full", self.dimen
    end)
    return true
end

function ReadingStatsTable:onTapClose(arg, ges_ev)
    if ges_ev and ges_ev.pos then
        local tx = ges_ev.pos.x
        local ty = ges_ev.pos.y
        local bar_y      = self._pagination_bar_y or 0
        local popup_bot  = self._popup_bottom_y   or 0

        -- Tap is inside the popup (above the bottom edge)
        if ty <= popup_bot then
            -- Tap is in the pagination bar row
            if ty >= bar_y and self._pagination_hits then
                for _, hit in ipairs(self._pagination_hits) do
                    if hit.enabled and tx >= hit.x_min and tx <= hit.x_max then
                        local ui_ref = self.ui
                        local target = hit.target
                        UIManager:close(self)
                        -- Defer reopen so this tap event is fully consumed first,
                        -- preventing it from immediately closing the new popup.
                        UIManager:scheduleIn(0, function()
                            _current_page = target
                            local new_popup = ReadingStatsTable:new{ ui = ui_ref }
                            UIManager:show(new_popup)
                        end)
                        return true
                    end
                end
                -- Tapped bar area but disabled zone — swallow only
                return true
            end
            -- Tapped inside popup content (table rows etc.) — swallow, don't close
            return true
        end
    end
    -- Tapped outside popup — close
    UIManager:close(self)
    return true
end

function ReadingStatsTable:onAnyKeyPressed()
    UIManager:close(self)
    return true
end

function ReadingStatsTable:onCloseWidget()
    UIManager:setDirty(nil, "full")
end

function ReaderUI.onShowReadingStatsTable(this)
    _current_page = 1
    local popup = ReadingStatsTable:new{
        ui = this,
    }
    UIManager:show(popup)
    return true
end

return ReadingStatsTable