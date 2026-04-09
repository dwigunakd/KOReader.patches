local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local ReaderUI = require("apps/reader/readerui")
local RenderImage = require("ui/renderimage")
local ScreenSaverWidget = require("ui/widget/screensaverwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local lfs = require("libs/libkoreader-lfs")
local bit = require("bit")
local util = require("util")
local _ = require("gettext")

local Screen = Device.screen

local STATISTICS_DB_PATH = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
local KOBO_STYLE_DARK_MODE_SETTING = "kobo_style_screensaver_dark_mode"
local LAST_READ_LABEL = _("Last Read")
local LAST_READ_TITLE_SETTING = "kobo_style_last_read_title"
local LAST_READ_PERCENTAGE_SETTING = "kobo_style_last_read_percentage"
local LAST_FILE_SETTING = "lastfile"
local last_read_snapshot = {}

-- [All your original helper functions remain unchanged: truncateAtColon, utf8Len, utf8Sub, 
-- hasActiveDocument, getBookTodayDuration, formatDuration, getActiveDocumentCover, buildBackgroundCover]

local function truncateAtColon(title)
    if not title or title == "" then return "" end
    local cut_pos = title:find("[%:%-%—]")
    if cut_pos then
        return util.trim(title:sub(1, cut_pos - 1))
    end
    return title
end

local function utf8Len(str)
    if not str or str == "" then return 0 end
    local len = 0
    local i = 1
    while i <= #str do
        local byte = string.byte(str, i)
        if byte >= 0xF0 then i = i + 4
        elseif byte >= 0xE0 then i = i + 3
        elseif byte >= 0xC0 then i = i + 2
        else i = i + 1 end
        len = len + 1
    end
    return len
end

local function utf8Sub(str, max_chars)
    if not str or str == "" or max_chars <= 0 then return "" end
    local len = #str
    local i = 1
    local count = 0
    while i <= len and count < max_chars do
        local byte = string.byte(str, i)
        if byte >= 0xF0 then i = i + 4
        elseif byte >= 0xE0 then i = i + 3
        elseif byte >= 0xC0 then i = i + 2
        else i = i + 1 end
        count = count + 1
    end
    if i <= len then
        return str:sub(1, i - 1) .. " …"
    end
    return str
end

local function hasActiveDocument(ui)
    return ui and ui.document ~= nil
end

local function getDocumentTitle(ui)
    local doc_props = ui and ui.doc_props or {}
    return truncateAtColon(doc_props.display_title or "") or "Untitled"
end

local function getPageProgress(ui, state)
    local doc_page_no = (state and state.page) or 1
    local doc_settings = ui and ui.doc_settings and ui.doc_settings.data or {}
    local doc_page_total = doc_settings.doc_pages or 1

    if doc_page_total <= 0 then doc_page_total = 1 end
    if doc_page_no < 1 then doc_page_no = 1 end
    if doc_page_no > doc_page_total then doc_page_no = doc_page_total end

    local page_no_numeric = doc_page_no
    local page_total_numeric = doc_page_total

    if ui and ui.pagemap and ui.pagemap:wantsPageLabels() then
        local _, idx, count = ui.pagemap:getCurrentPageLabel(true)
        if idx and count then
            page_no_numeric = idx
            page_total_numeric = count
        end
    end

    local percentage = math.floor((page_no_numeric / page_total_numeric) * 100 + 0.5)
    return {
        doc_page_no = doc_page_no,
        doc_page_total = doc_page_total,
        page_no_numeric = page_no_numeric,
        page_total_numeric = page_total_numeric,
        percentage = percentage,
    }
end

local function getBookTodayDuration(statistics)
    if not statistics then return nil end
    if statistics.isEnabled and not statistics:isEnabled() then return nil end
    if statistics.insertDB then pcall(statistics.insertDB, statistics) end

    local id_book = statistics.id_curr_book
    if (not id_book) and statistics.getIdBookDB then
        local ok, book_id = pcall(statistics.getIdBookDB, statistics)
        if ok then id_book = book_id end
    end
    if not id_book then return nil end
    if not STATISTICS_DB_PATH or STATISTICS_DB_PATH == "" then return nil end

    local attrs = lfs.attributes(STATISTICS_DB_PATH, "mode")
    if attrs ~= "file" then return nil end

    local now_stamp = os.time()
    local now_t = os.date("*t", now_stamp)
    local from_begin_day = now_t.hour * 3600 + now_t.min * 60 + now_t.sec
    local start_today_time = now_stamp - from_begin_day

    local ok_conn, conn = pcall(SQ3.open, STATISTICS_DB_PATH)
    if not ok_conn or not conn then return nil end

    local sql_stmt = string.format([[SELECT sum(sum_duration)
        FROM (
            SELECT sum(duration) AS sum_duration
            FROM page_stat
            WHERE start_time >= %d AND id_book = %d
            GROUP BY page
        );
    ]], start_today_time, id_book)

    local ok_row, today_duration = pcall(function()
        return conn:rowexec(sql_stmt)
    end)
    conn:close()

    if not ok_row or today_duration == nil then return nil end
    today_duration = tonumber(today_duration)
    if not today_duration or today_duration <= 0 then return nil end
    return today_duration
end

local function formatDuration(secs)
    if not secs or secs <= 0 then return nil end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 and m > 0 then
        return string.format("%d hr %d min", h, m)
    elseif h > 0 then
        return string.format("%d hr", h)
    elseif m > 0 then
        return string.format("%d min", m)
    else
        return "< 1 min"
    end
end

local function getActiveDocumentCover(ui)
    if not ui or not ui.document or not ui.bookinfo then return nil end
    return ui.bookinfo:getCoverImage(ui.document)
end

local function buildScaledCoverWidget(cover_bb)
    if not cover_bb then return nil end
    local screen_size = Screen:getSize()
    local scaled_bb = RenderImage:scaleBlitBuffer(cover_bb, screen_size.w, screen_size.h, true)
    return ImageWidget:new{
        image = scaled_bb,
        width = screen_size.w,
        height = screen_size.h,
        alpha = true,
    }
end

local function persistLastReadSnapshot()
    if last_read_snapshot.title and last_read_snapshot.title ~= "" then
        G_reader_settings:saveSetting(LAST_READ_TITLE_SETTING, last_read_snapshot.title)
    end

    if last_read_snapshot.percentage ~= nil then
        G_reader_settings:saveSetting(LAST_READ_PERCENTAGE_SETTING, last_read_snapshot.percentage)
    else
        G_reader_settings:delSetting(LAST_READ_PERCENTAGE_SETTING)
    end
end

local function hydrateLastReadSnapshot()
    if last_read_snapshot.title then return end

    local title = G_reader_settings:readSetting(LAST_READ_TITLE_SETTING)
    local percentage = G_reader_settings:readSetting(LAST_READ_PERCENTAGE_SETTING)

    if title and title ~= "" then
        last_read_snapshot.title = title
        last_read_snapshot.percentage = tonumber(percentage)
    end
end

local function ensureLastReadCoverWidget(ui)
    if not ui or not ui.bookinfo then
        return nil
    end

    local lastfile = G_reader_settings:readSetting(LAST_FILE_SETTING)
    if not lastfile or lastfile == "" then
        return nil
    end

    local ok, cover_bb = pcall(ui.bookinfo.getCoverImage, ui.bookinfo, ui.document, lastfile)
    if ok and cover_bb then
        return buildScaledCoverWidget(cover_bb)
    end
    return nil
end

local function updateLastReadSnapshot(ui, state)
    if not hasActiveDocument(ui) then return end

    local progress = getPageProgress(ui, state)

    last_read_snapshot = {
        title = getDocumentTitle(ui),
        percentage = progress and progress.percentage or nil,
    }
    persistLastReadSnapshot()
end

local function buildBackgroundCover(ui)
    local cover_bb = getActiveDocumentCover(ui)
    return buildScaledCoverWidget(cover_bb)
end

local function buildKoboStyleReceipt(ui, state)
    if not hasActiveDocument(ui) then return nil end

    local book_title = getDocumentTitle(ui)
    local progress = getPageProgress(ui, state)
    local doc_page_no = progress.doc_page_no
    local toc = ui.toc
    local chapter_title = ""
    if toc then
        chapter_title = toc:getTocTitleByPage(doc_page_no) or ""
        local colon_pos = chapter_title:find("[%:%-%—]")
        if colon_pos then
            chapter_title = util.trim(chapter_title:sub(1, colon_pos - 1))
        end  
    end  

    local page_no_numeric = progress.page_no_numeric
    local page_total_numeric = progress.page_total_numeric
    local page_left = math.max(page_total_numeric - page_no_numeric, 0)
    local percentage = progress.percentage

    local statistics = ui.statistics
    local avg_time = statistics and statistics.avg_time

    local time_left_str = nil
    if avg_time and avg_time > 0 then
        local secs = avg_time * page_left
        local h = math.floor(secs / 3600)
        local m = math.floor((secs % 3600) / 60)
        if h > 0 and m > 0 then
            time_left_str = string.format("%d hrs %d mins to go", h, m)
        elseif h > 0 then
            time_left_str = string.format("%d hrs to go", h)
        elseif m > 0 then
            time_left_str = string.format("%d mins to go", m)
        else
            time_left_str = "< 1 min to go"
        end
    end

    local today_duration = getBookTodayDuration(statistics)
    local today_str = formatDuration(today_duration)

    local progress_text = string.format("%d%% read", percentage)
    if time_left_str then 
        progress_text = string.format("At %d%% · %s", percentage, time_left_str)
    end

    local today_text = today_str and string.format("%s read today", today_str) or nil

    local screen_size = Screen:getSize()
    local padding = Screen:scaleBySize(12)
    local font_size_title = Screen:scaleBySize(10)
    local font_size_chapter = Screen:scaleBySize(9)
    local font_size_status = Screen:scaleBySize(9)
    local box_width = math.floor(screen_size.w * 0.55)

    local dark_mode = G_reader_settings:isTrue(KOBO_STYLE_DARK_MODE_SETTING)
    local bg_color, text_color, text_color_light, border_color, border_size
    if dark_mode then
        bg_color = Blitbuffer.COLOR_BLACK
        text_color = Blitbuffer.COLOR_WHITE
        text_color_light = Blitbuffer.COLOR_GRAY_E
        border_color = Blitbuffer.COLOR_WHITE
        border_size = 1
    else
        bg_color = Blitbuffer.COLOR_WHITE
        text_color = Blitbuffer.COLOR_BLACK
        text_color_light = Blitbuffer.COLOR_GRAY_3
        border_color = Blitbuffer.COLOR_BLACK
        border_size = 1
    end

    local title_face = Font:getFace("NotoSerif-Regular.ttf", font_size_title)
    local chapter_face = Font:getFace("NotoSerif-Regular.ttf", font_size_chapter)
    local status_face = Font:getFace("NotoSerif-Regular.ttf", font_size_status)

    local elements = {}

    -- Title with tight line height
    table.insert(elements, TextBoxWidget:new{
        text = book_title,
        face = title_face,
        fgcolor = text_color,
        bgcolor = bg_color,           -- ADD THIS
        width = box_width - Screen:scaleBySize(28),
        alignment = "left",
        bold = true,
        line_height = 0.3,
    })

    -- Chapter title
    if chapter_title ~= "" then
        table.insert(elements, TextBoxWidget:new{
            text = chapter_title,
            face = chapter_face,
            fgcolor = text_color_light,
            bgcolor = bg_color,       -- ADD THIS
            width = box_width - Screen:scaleBySize(28),
            alignment = "left",
            bold = true,
            line_height = 0.3,
        })
    end

    -- === CONTROLLED SPACING BETWEEN CHAPTER AND STATUS ===

    -- Progress line
    table.insert(elements, TextWidget:new{
        text = progress_text,
        face = Font:getFace("NotoSerif-Regular.ttf", font_size_chapter),
        fgcolor = text_color_light,
        bold = true,
		line_height = 0.3,
    })

    -- Today reading time
    if today_text then 
        table.insert(elements, TextWidget:new{
            text = today_text,
            face = status_face,
            fgcolor = text_color_light,
            bold = true,
			line_height = 0.3,
        })
    end

    local box_content = VerticalGroup:new{ align = "left" }
    for _, el in ipairs(elements) do
        table.insert(box_content, el)
    end

    local info_box = FrameContainer:new{
        background = bg_color,
        bordersize = border_size,
        color = border_color,
        radius = 0,
        padding = padding,
        box_content,
    }

    local margin_left = 0
    local margin_bottom = Screen:scaleBySize(100)
    local box_height = info_box:getSize().h

    local positioned_box = OverlapGroup:new{
        dimen = screen_size,
        VerticalGroup:new{
            VerticalSpan:new{ width = screen_size.h - box_height - margin_bottom },
            HorizontalGroup:new{
                HorizontalSpan:new{ width = margin_left },
                info_box,
            },
        },
    }

    local bg_widget = buildBackgroundCover(ui)
    if bg_widget then
        return OverlapGroup:new{
            dimen = screen_size,
            bg_widget,
            positioned_box,
        }
    else
        return OverlapGroup:new{
            dimen = screen_size,
            positioned_box,
        }
    end
end

local function buildLastReadReceipt(cover_widget)
    hydrateLastReadSnapshot()

    if not last_read_snapshot.title or last_read_snapshot.title == "" then
        return nil
    end

    local screen_size = Screen:getSize()
    local padding = Screen:scaleBySize(12)
    local box_width = math.floor(screen_size.w * 0.55)

    local dark_mode = G_reader_settings:isTrue(KOBO_STYLE_DARK_MODE_SETTING)
    local bg_color, text_color, text_color_light, border_color, border_size
    if dark_mode then
        bg_color = Blitbuffer.COLOR_BLACK
        text_color = Blitbuffer.COLOR_WHITE
        text_color_light = Blitbuffer.COLOR_GRAY_E
        border_color = Blitbuffer.COLOR_WHITE
        border_size = 1
    else
        bg_color = Blitbuffer.COLOR_WHITE
        text_color = Blitbuffer.COLOR_BLACK
        text_color_light = Blitbuffer.COLOR_GRAY_3
        border_color = Blitbuffer.COLOR_BLACK
        border_size = 1
    end

    local label_face = Font:getFace("NotoSerif-Regular.ttf", Screen:scaleBySize(9))
    local title_face = Font:getFace("NotoSerif-Regular.ttf", Screen:scaleBySize(11))

    local summary_text = last_read_snapshot.title
    if last_read_snapshot.percentage then
        summary_text = string.format("%s · %d%%", last_read_snapshot.title, last_read_snapshot.percentage)
    end

    local box_content = VerticalGroup:new{
        align = "left",
        TextWidget:new{
            text = LAST_READ_LABEL,
            face = label_face,
            fgcolor = text_color_light,
            bold = true,
        },
        TextBoxWidget:new{
            text = summary_text,
            face = title_face,
            fgcolor = text_color,
            bgcolor = bg_color,
            width = box_width - Screen:scaleBySize(28),
            alignment = "left",
            bold = true,
            line_height = 0.3,
        },
    }

    local info_box = FrameContainer:new{
        background = bg_color,
        bordersize = border_size,
        color = border_color,
        radius = 0,
        padding = padding,
        box_content,
    }

    local margin_left = 0
    local margin_bottom = Screen:scaleBySize(100)
    local box_height = info_box:getSize().h

    local positioned_box = OverlapGroup:new{
        dimen = screen_size,
        VerticalGroup:new{
            VerticalSpan:new{ width = screen_size.h - box_height - margin_bottom },
            HorizontalGroup:new{
                HorizontalSpan:new{ width = margin_left },
                info_box,
            },
        },
    }

    if cover_widget then
        return OverlapGroup:new{
            dimen = screen_size,
            cover_widget,
            positioned_box,
        }
    end

    return OverlapGroup:new{
        dimen = screen_size,
        positioned_box,
    }
end

local function cacheLastReadFromUI(ui)
    if not ui then return end
    local state = ui.view and ui.view.state
    pcall(updateLastReadSnapshot, ui, state)
end

if type(ReaderUI.onCloseWidget) == "function" then
    local orig_readerui_onclosewidget = ReaderUI.onCloseWidget
    ReaderUI.onCloseWidget = function(self, ...)
        cacheLastReadFromUI(self)
        return orig_readerui_onclosewidget(self, ...)
    end
end

if type(ReaderUI.onClose) == "function" then
    local orig_readerui_onclose = ReaderUI.onClose
    ReaderUI.onClose = function(self, ...)
        cacheLastReadFromUI(self)
        return orig_readerui_onclose(self, ...)
    end
end

-- Screensaver integration (dynamic background for dark mode)
local Screensaver = require("ui/screensaver")
local orig_screensaver_show = Screensaver.show

Screensaver.show = function(self)
    if self.screensaver_type ~= "kobo_style" then
        return orig_screensaver_show(self)
    end

    local ui = self.ui or ReaderUI.instance
    local state = ui and ui.view and ui.view.state
    local fallback_cover_widget = nil

    if hasActiveDocument(ui) then
        updateLastReadSnapshot(ui, state)
    else
        hydrateLastReadSnapshot()
        fallback_cover_widget = ensureLastReadCoverWidget(ui)
    end

    if self.screensaver_widget then
        UIManager:close(self.screensaver_widget)
        self.screensaver_widget = nil
    end

    Device.screen_saver_mode = true

    local rotation_mode = Screen:getRotationMode()
    Device.orig_rotation_mode = rotation_mode
    if bit.band(rotation_mode, 1) == 1 then
        Screen:setRotationMode(Screen.DEVICE_ROTATED_UPRIGHT)
    else
        Device.orig_rotation_mode = nil
    end

    local receipt_widget = buildKoboStyleReceipt(ui, state) or buildLastReadReceipt(fallback_cover_widget)

    if receipt_widget then
        local dark_mode = G_reader_settings:isTrue(KOBO_STYLE_DARK_MODE_SETTING)
        local bg = dark_mode and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE

        self.screensaver_widget = ScreenSaverWidget:new{
            widget = receipt_widget,
            background = bg,
            covers_fullscreen = true,
        }
        self.screensaver_widget.modal = true
        self.screensaver_widget.dithered = true
        UIManager:show(self.screensaver_widget, "full")
    else
        return orig_screensaver_show(self)
    end
end

-- Menu option (unchanged)
local orig_dofile = dofile
_G.dofile = function(filepath)
    local result = orig_dofile(filepath)
    if filepath and filepath:match("screensaver_menu%.lua$") then
        if result and result[1] and result[1].sub_item_table then
            local wallpaper_submenu = result[1].sub_item_table

            local function isKoboStyleEnabled()
                return G_reader_settings:readSetting("screensaver_type") == "kobo_style"
            end

            table.insert(wallpaper_submenu, 6, {
                text = _("Kobo-style (cover + progress)"),
                checked_func = function()
                    return G_reader_settings:readSetting("screensaver_type") == "kobo_style"
                end,
                callback = function()
                    G_reader_settings:saveSetting("screensaver_type", "kobo_style")
                end,
                radio = true,
            })

            table.insert(wallpaper_submenu, 7, {
                text = _("Kobo-style settings"),
                enabled_func = isKoboStyleEnabled,
                sub_item_table = {
                    {
                        text = _("Dark mode"),
                        checked_func = function()
                            return G_reader_settings:isTrue(KOBO_STYLE_DARK_MODE_SETTING)
                        end,
                        callback = function()
                            G_reader_settings:flipNilOrFalse(KOBO_STYLE_DARK_MODE_SETTING)
                        end,
                    },
                },
            })
        end
    end
    return result
end
