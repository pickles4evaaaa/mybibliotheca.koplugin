local DataStorage = require("datastorage")
local CheckButton = require("ui/widget/checkbutton")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local http = require("socket.http")
local ltn12 = require("ltn12")
local md5 = require("ffi/sha2").md5
local rapidjson = require("rapidjson")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")
local _ = require("gettext")

local MyBibliotheca = WidgetContainer:extend{
    name = "mybibliotheca",
    version = "2.0.1",
    is_doc_only = false,
}

function MyBibliotheca:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/mybibliotheca.lua")
    self.config = self.settings:readSetting("mybibliotheca") or {}
    self.ui.menu:registerToMainMenu(self)
    if self.ui.document then
        self.ui:registerPostReaderReadyCallback(function() self:scheduleAutoPush(1, true) end)
    end
end

function MyBibliotheca:addToMainMenu(menu_items)
    menu_items.mybibliotheca = {
        text = _("MyBibliotheca"),
        sub_item_table = {
            {
                text = _("Configure connection"),
                keep_menu_open = true,
                callback = function() self:configure() end,
            },
            {
                text = _("Auto-push highlights"),
                help_text = _("Send after highlight edits and on sleep/wake, like progress sync. Sleep/wake uses KOReader's Wi-Fi settings; reading-time uploads use an existing connection."),
                checked_func = function() return self.config.auto_push == true end,
                callback = function()
                    self.config.auto_push = not self.config.auto_push
                    self:saveSettings()
                    if self.config.auto_push then
                        self:markPending()
                        self:scheduleAutoPush(1, true)
                    else
                        self:cancelAutoPush()
                    end
                end,
            },
            {
                text = _("Send this book's highlights"),
                enabled_func = function() return self.ui.document ~= nil end,
                callback = function() self:syncCurrentBook() end,
            },
        },
    }
end

function MyBibliotheca:configure()
    local dialog
    local auto_push
    dialog = MultiInputDialog:new{
        title = _("MyBibliotheca highlights settings"),
        fields = {
            { text = self.config.endpoint_url or "https://mybibliotheca.org/notes", hint = _("Notes endpoint URL") },
            { text = self.config.username or "", hint = _("KOReader sync username") },
            { text = "", hint = _("KOReader sync password"), text_type = "password" },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local values = dialog:getFields()
                        local password = values[3] or ""
                        local endpoint_url = (values[1] or ""):gsub("/$", "")
                        local username = values[2] or ""
                        if not endpoint_url:match("^https://") or not endpoint_url:match("/notes$") or username == "" or
                            (password == "" and (not self.config.userkey or username ~= self.config.username)) or
                            (password ~= "" and #password < 12) then
                            UIManager:show(InfoMessage:new{
                                text = _("Enter the HTTPS endpoint ending in /notes, your KOReader sync username, and a sync password of at least 12 characters."),
                            })
                            return
                        end
                        self.config.endpoint_url = endpoint_url
                        self.config.username = username
                        if password ~= "" then
                            self.config.userkey = md5(password)
                        end
                        self.config.auto_push = auto_push.checked == true
                        self:saveSettings()
                        if self.config.auto_push then
                            self:markPending()
                            self:scheduleAutoPush(1, true)
                        else
                            self:cancelAutoPush()
                        end
                        UIManager:close(dialog)
                        UIManager:show(InfoMessage:new{
                            text = _("Settings saved. The password is not stored; its KOReader sync key is saved on this device."),
                        })
                    end,
                },
            },
        },
    }
    auto_push = CheckButton:new{
        text = _("Auto-push highlights (like progress sync)"),
        checked = self.config.auto_push == true,
        parent = dialog,
    }
    dialog:addWidget(auto_push)
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Pending state belongs to the book sidecar, so no annotation queue is kept in RAM.
function MyBibliotheca:markPending()
    if self.ui.document and self.ui.doc_settings then
        self.ui.doc_settings:saveSetting("mybibliotheca_pending", true)
    end
end

function MyBibliotheca:onAnnotationsModified()
    self:markPending()
    self:scheduleAutoPush(10, false)
end

function MyBibliotheca:onNetworkConnected()
    if self.suspended then
        -- Progress sync may be the component restoring Wi-Fi for the sleep push.
        self:autoPush(false)
        return
    end
    -- Let the connection finish settling, as progress sync does.
    self:scheduleAutoPush(0.5, false)
end

function MyBibliotheca:onNetworkDisconnecting()
    self:cancelAutoPush()
    self:autoPush(false)
end

function MyBibliotheca:onSuspend()
    self.suspended = true
    self:cancelAutoPush()
    self:autoPush(true)
end

function MyBibliotheca:onResume()
    self.suspended = false
    self:scheduleAutoPush(1, true)
end

function MyBibliotheca:onCloseDocument()
    self:cancelAutoPush()
    self:autoPush(false)
    self.closed = true
end

function MyBibliotheca:onCloseWidget()
    self.closed = true
    self:cancelAutoPush()
end

function MyBibliotheca:cancelAutoPush()
    if self.auto_push_task then UIManager:unschedule(self.auto_push_task) end
    self.auto_push_task = nil
end

function MyBibliotheca:scheduleAutoPush(delay, ensure_networking)
    if not self.config.auto_push or not self.ui.document or self.closed or self.suspended then return end
    self:cancelAutoPush()
    local document = self.ui.document
    self.auto_push_task = function()
        self.auto_push_task = nil
        if self.ui.document ~= document or self.closed or self.suspended then return end
        self:autoPush(ensure_networking)
    end
    UIManager:scheduleIn(delay, self.auto_push_task)
end

function MyBibliotheca:onPageUpdate(page)
    if not self.config.auto_push or page == nil or page == self.last_page then return end
    self.last_page = page
    -- Debounce while skimming, and give a failed/offline upload another opportunity
    -- during normal reading. Clean books never create a page-turn upload task.
    if self.ui.document and self.ui.doc_settings:readSetting("mybibliotheca_pending") then
        local delay = 10
        if self.last_auto_attempt then
            delay = math.max(delay, 30 - (os.time() - self.last_auto_attempt))
        end
        self:scheduleAutoPush(delay, false)
    end
end

function MyBibliotheca:autoPush(ensure_networking)
    if not self.config.auto_push or not self.ui.document or self.syncing
        or self.closed or not self.config.username or not self.config.userkey then return end
    local state = self.ui.doc_settings
    if not state:readSetting("mybibliotheca_pending")
        and state:readSetting("mybibliotheca_synced") then return end
    local has_highlights = false
    for _, item in ipairs(self.ui.annotation.annotations or {}) do
        if item.drawer and ((item.text or ""):match("%S") or (item.note or ""):match("%S")) then
            has_highlights = true
            break
        end
    end
    if not has_highlights then
        -- Record the empty state without activating Wi-Fi for a new/empty book.
        self:syncCurrentBook(true)
        return
    end
    if self.last_auto_attempt and os.time() - self.last_auto_attempt < 30 then return end
    if ensure_networking then
        -- Reuse a connection already being established (e.g. by progress sync).
        if NetworkMgr.pending_connection or NetworkMgr.pending_connectivity_check then return end
        local document = self.ui.document
        if NetworkMgr:willRerunWhenOnline(function()
            if self.ui.document == document and not self.closed then self:autoPush(false) end
        end) then return end
    elseif not NetworkMgr:isConnected() then
        return
    end
    self:syncCurrentBook(true)
end

function MyBibliotheca:syncCurrentBook(automatic)
    if not self.ui.document or self.syncing then return end
    if not self.config.username or not self.config.userkey then
        if not automatic then
            UIManager:show(InfoMessage:new{ text = _("Configure your KOReader sync credentials first.") })
        end
        return
    end
    local document = self.ui.document
    local function sync()
        -- Manual Wi-Fi setup may finish after the original book has been closed.
        if self.ui.document ~= document or self.syncing or self.closed
            or automatic and not self.config.auto_push then return end
        self.syncing = true
        local ok, message, success = pcall(self.pushCurrentBook, self, automatic)
        socketutil:reset_timeout()
        self.syncing = false
        if not ok then
            self:markPending()
            self.ui.doc_settings:flush()
            message = _("Highlight sync failed. Changes remain pending; try again later.")
            logger.warn("MyBibliotheca: highlight sync failed")
        end
        if automatic then
            self.last_auto_attempt = not (ok and success) and os.time() or nil
            if message then logger.dbg("MyBibliotheca:", message) end
        elseif message then
            UIManager:show(InfoMessage:new{ text = message })
        end
    end
    if automatic then sync() else NetworkMgr:runWhenOnline(sync) end
end

function MyBibliotheca:pushCurrentBook(automatic)
    -- Reuse KOReader's exporter normalization without copying its whole clipping tree.
    self.parser = self.parser or require("clip"):new{ ui = self.ui, settings = {} }
    self.ui.annotation:updatePageNumbers(true)
    local document_id = self.ui.doc_settings:readSetting("partial_md5_checksum")
        or util.partialMD5(self.ui.document.file)
    if not document_id then
        self:markPending()
        return _("Could not identify this document for syncing.")
    end
    local title, author = self.parser:getTitleAuthor(self.ui.document.file, self.ui.doc_props)
    title = title or self.ui.doc_props.display_title or "Untitled"
    author = (author or ""):gsub("\n", ", ")
    local items = self.ui.annotation.annotations or {}
    local function convert(item)
        if not self.parser:doesHighlightMatch(item) then return end
        local text = self.parser:getText(item.text)
        local note = self.parser:getText(item.note)
        if not text:match("%S") and not note:match("%S") then return end
        local page = item.pageref or item.pageno or ""
        local time = self.parser:getTime(item.datetime)
        local stable_key = table.concat({ tostring(page), tostring(time or ""), text }, "\n")
        return {
            id = md5(stable_key),
            text = text,
            note = note,
            location = tostring(page),
            highlighted_at = time and os.date("!%Y-%m-%dT%H:%M:%SZ", time) or nil,
        }
    end
    -- One fixed-size digest per book, including the destination and notes/edits.
    local digest = md5(table.concat({ self.config.endpoint_url, self.config.username,
        self.config.userkey, document_id, title, author }, "\n"))
    local total = 0
    for _, item in ipairs(items) do
        local entry = convert(item)
        if entry then
            digest = md5(digest .. entry.id .. md5(entry.note) .. (entry.highlighted_at or ""))
            total = total + 1
        end
    end
    if total == 0 or automatic and self.ui.doc_settings:readSetting("mybibliotheca_synced") == digest then
        self.ui.doc_settings:saveSetting("mybibliotheca_pending", false)
        self.ui.doc_settings:saveSetting("mybibliotheca_synced", digest)
        self.ui.doc_settings:flush()
        if not automatic then return _("No highlights or notes in this book."), true end
        return nil, true
    end
    self:markPending()
    local uploaded = 0
    local batch = {}
    local function sendBatch()
        local encoded, encode_error = rapidjson.encode({
            document_id = document_id, title = title, author = author, annotations = batch,
        })
        if not encoded then return encode_error or "JSON encoding failed" end
        if automatic then socketutil:set_timeout(3, 5) else socketutil:set_timeout(10, 30) end
        local code, _, status = socket.skip(1, http.request{
            url = self.config.endpoint_url,
            method = "POST",
            headers = {
                ["Content-Type"] = "application/json",
                ["Content-Length"] = tostring(#encoded),
                ["X-Auth-User"] = self.config.username,
                ["X-Auth-Key"] = self.config.userkey,
            },
            source = ltn12.source.string(encoded),
            sink = ltn12.sink.null(),
        })
        socketutil:reset_timeout()
        if code ~= 200 and code ~= 201 then
            if code == 401 then
                return _("Unauthorized. Check the sync username and password in Configure connection.")
            end
            return tostring(status or code or "network error")
        end
        uploaded = uploaded + #batch
        batch = {}
    end
    local failure
    for _, item in ipairs(items) do
        local entry = convert(item)
        if entry then
            batch[#batch + 1] = entry
            if #batch == 10 then
                failure = sendBatch()
                if failure then break end
            end
        end
    end
    if not failure and #batch > 0 then failure = sendBatch() end
    if failure then
        self.ui.doc_settings:flush()
        return string.format(_("Synced %d of %d items. Sync stopped: %s"), uploaded, total, failure)
    end
    self.ui.doc_settings:saveSetting("mybibliotheca_synced", digest)
    self.ui.doc_settings:saveSetting("mybibliotheca_pending", false)
    self.ui.doc_settings:flush()
    return string.format(_("Synced %d highlights and notes."), uploaded), true
end

function MyBibliotheca:saveSettings()
    self.settings:saveSetting("mybibliotheca", self.config)
    self.settings:flush()
end

return MyBibliotheca
