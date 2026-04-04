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

local function buildPaginationBar(fonts, layout, current_page, total_pages, on_first, on_prev, on_next, on_last)

    local function makeBtn(label, enabled, handler)
        local face = enabled and fonts.cell or fonts.header
        local txt = TextWidget:new{
            text = label,
            face = face,
        }
        local btn = FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = 0,
            padding_top    = Screen:scaleBySize(4),
            padding_bottom = Screen:scaleBySize(4),
            padding_left   = Screen:scaleBySize(6),
            padding_right  = Screen:scaleBySize(6),
            txt,
        }
        if enabled and handler then
            btn.handler = handler
        end
        return btn
    end

    local page_label = TextWidget:new{
        text = string.format("%d / %d", current_page, total_pages),
        face = fonts.cell,
    }

    local bar = HorizontalGroup:new{ align = "center" }
    -- Push the bar to the right with a flexible left span
    local bar_inner = HorizontalGroup:new{ align = "center" }

    local first_btn = makeBtn("«", current_page > 1, on_first)
    local prev_btn  = makeBtn("‹", current_page > 1, on_prev)
    local next_btn  = makeBtn("›", current_page < total_pages, on_next)
    local last_btn  = makeBtn("»", current_page < total_pages, on_last)

    table.insert(bar_inner, first_btn)
    table.insert(bar_inner, HorizontalSpan:new{ width = Screen:scaleBySize(6) })
    table.insert(bar_inner, prev_btn)
    table.insert(bar_inner, HorizontalSpan:new{ width = Screen:scaleBySize(10) })
    table.insert(bar_inner, page_label)
    table.insert(bar_inner, HorizontalSpan:new{ width = Screen:scaleBySize(10) })
    table.insert(bar_inner, next_btn)
    table.insert(bar_inner, HorizontalSpan:new{ width = Screen:scaleBySize(6) })
    table.insert(bar_inner, last_btn)

    -- Right-aligned: fill remaining space on the left
    local btn_total_w = first_btn:getSize().w + prev_btn:getSize().w
                      + next_btn:getSize().w + last_btn:getSize().w
    local bar_inner_w = btn_total_w + Screen:scaleBySize(6 + 10 + 10 + 6) + page_label:getSize().w
    local left_fill = layout.full_width - 2 * layout.padding_h - bar_inner_w
    if left_fill < 0 then left_fill = 0 end

    table.insert(bar, HorizontalSpan:new{ width = left_fill })
    table.insert(bar, bar_inner)

    local pagination_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding_top    = Size.padding.default,
        padding_bottom = Size.padding.default,
        padding_left   = layout.padding_h,
        padding_right  = layout.padding_h,
        bar,
    }

    -- Collect tappable buttons and their handlers for gesture dispatch
    local tap_targets = {
        { widget = first_btn, handler = on_first, enabled = current_page > 1 },
        { widget = prev_btn,  handler = on_prev,  enabled = current_page > 1 },
        { widget = next_btn,  handler = on_next,  enabled = current_page < total_pages },
        { widget = last_btn,  handler = on_last,  enabled = current_page < total_pages },
    }

    return pagination_frame, tap_targets
end

Dispatcher:registerAction("reading_stats_table", {
    category = "none",
    event = "ShowReadingStatsTable",
    title = "Reading history",
    reader = true,
})

local ROWS_PER_PAGE = 7

local ReadingStatsTable = InputContainer:extend{
    modal = true,
    ui = nil,
    current_page = 1,
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
    -- Ensure the single persistent outer container exists once
    if not self._outer_group then
        self._outer_group = VerticalGroup:new{}
        self[1] = self._outer_group
    end
    
    local book_id = self.stats_plugin and self.stats_plugin.id_curr_book
    local all_stats = getReadingStatsForDays(book_id, 365)
    local book_title = truncateTitle(getBookTitle(self.ui), 30)
    local days_read = getTotalDaysRead(book_id)
    
    -- Pagination calculations
    local total_rows  = #all_stats
    local total_pages = math.max(1, math.ceil(total_rows / ROWS_PER_PAGE))
    if self.current_page > total_pages then self.current_page = total_pages end
    if self.current_page < 1 then self.current_page = 1 end

    local page_start = (self.current_page - 1) * ROWS_PER_PAGE + 1
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
    
    -- ... rest of the function (header, rows, layout) stays the same

    local header = buildTableHeader(self.fonts, self.layout)
    local rows = buildTableRows(stats_data, self.fonts, self.layout)

    -- Build pagination bar
    local self_ref = self
    local pagination_frame, tap_targets = buildPaginationBar(
        self.fonts, self.layout,
        self.current_page, total_pages,
        function() self_ref.current_page = 1;           self_ref:buildContent(); UIManager:setDirty(self_ref, "ui") end,
        function() self_ref.current_page = self_ref.current_page - 1; self_ref:buildContent(); UIManager:setDirty(self_ref, "ui") end,
        function() self_ref.current_page = self_ref.current_page + 1; self_ref:buildContent(); UIManager:setDirty(self_ref, "ui") end,
        function() self_ref.current_page = total_pages; self_ref:buildContent(); UIManager:setDirty(self_ref, "ui") end
    )
    self._pagination_tap_targets = tap_targets
    
    local table_content = VerticalGroup:new{
        align = "left",
        FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = 0,
            padding_top = Size.padding.large,
            padding_bottom = Size.padding.small,
            padding_left = self.layout.padding_h,
            padding_right = self.layout.padding_h,
            title,
        },
        FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = 0,
            padding_top = 0,
            padding_bottom = Size.padding.default,
            padding_left = self.layout.padding_h,
            padding_right = self.layout.padding_h,
            session_widget,
        },
        header,
        FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = 0,
            padding_top = Size.padding.default,
            padding_bottom = Size.padding.default,
            padding_left = self.layout.padding_h,
            padding_right = self.layout.padding_h,
            rows,
        },
        LineWidget:new{
            dimen = Geom:new{ w = self.layout.full_width, h = Size.line.thin },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        },
        pagination_frame,
        LineWidget:new{
            dimen = Geom:new{ w = self.layout.full_width, h = Size.line.medium },
            background = Blitbuffer.COLOR_BLACK,
        },
    }
    
    self.popup_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        radius = 0,
        padding = 0,
        width = self.screen_w,
        table_content,
    }

    -- Replace the single child of the persistent outer group in place.
    -- This avoids ever touching self[1] again, which prevents duplicate rendering.
    self._outer_group[1] = self.popup_frame
end

function ReadingStatsTable:onShow()
    -- Reset to page 1 and rebuild with fresh data every time shown
    self.current_page = 1
    self:buildContent()
    
    UIManager:setDirty(self, function()
        return "full", self.dimen
    end)
    return true
end

function ReadingStatsTable:onTapClose(arg, ges_ev)
    -- Check if tap lands on a pagination button
    if self._pagination_tap_targets and ges_ev then
        local tap_x = ges_ev.pos and ges_ev.pos.x
        local tap_y = ges_ev.pos and ges_ev.pos.y
        if tap_x and tap_y then
            for _, target in ipairs(self._pagination_tap_targets) do
                if target.enabled and target.widget and target.widget.dimen then
                    local d = target.widget.dimen
                    if tap_x >= d.x and tap_x <= d.x + d.w and
                       tap_y >= d.y and tap_y <= d.y + d.h then
                        target.handler()
                        return true
                    end
                end
            end
        end
    end
    UIManager:close(self)
    return true
end

function ReadingStatsTable:onAnyKeyPressed()
    UIManager:close(self)
    return true
end

function ReadingStatsTable:onCloseWidget()
    self._outer_group = nil
    UIManager:setDirty(nil, "full")
end

function ReaderUI.onShowReadingStatsTable(this)
    local popup = ReadingStatsTable:new{
        ui = this,
    }
    UIManager:show(popup)
    return true
end

return ReadingStatsTable