local DataStorage = require("datastorage")
local MyClipping = require("clip")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
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
    is_doc_only = false,
}

function MyBibliotheca:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/mybibliotheca.lua")
    self.config = self.settings:readSetting("mybibliotheca") or {}
    self.parser = MyClipping:new{ ui = self.ui, settings = {} }
    self.ui.menu:registerToMainMenu(self)
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
                text = _("Send this book's highlights"),
                enabled_func = function() return self.ui.document ~= nil end,
                callback = function() self:syncCurrentBook() end,
            },
        },
    }
end

function MyBibliotheca:configure()
    local dialog
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
                        self:saveSettings()
                        UIManager:close(dialog)
                        UIManager:show(InfoMessage:new{
                            text = _("Settings saved. The password is not stored; its KOReader sync key is saved on this device."),
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function MyBibliotheca:syncCurrentBook()
    if not self.config.username or not self.config.userkey then
        UIManager:show(InfoMessage:new{ text = _("Configure your KOReader sync credentials first.") })
        return
    end
    NetworkMgr:runWhenOnline(function()
        self.ui.annotation:updatePageNumbers(true)
        local clipping_groups = self.parser:parseCurrentDoc()
        local booknotes
        for _, candidate in pairs(clipping_groups or {}) do
            booknotes = candidate
            break
        end
        if not booknotes then
            UIManager:show(InfoMessage:new{ text = _("No highlights or notes in this book.") })
            return
        end
        local annotations = {}
        for _, chapter in ipairs(booknotes) do
            for _, entry in ipairs(chapter) do
                local text = entry.text or ""
                local note = entry.note or ""
                if text:match("%S") or note:match("%S") then
                    local stable_key = table.concat({ tostring(entry.page or entry.location or ""), tostring(entry.time or ""), text }, "\n")
                    table.insert(annotations, {
                        id = md5(stable_key),
                        text = text,
                        note = note,
                        location = tostring(entry.page or entry.location or ""),
                        highlighted_at = entry.time and os.date("!%Y-%m-%dT%H:%M:%SZ", entry.time) or nil,
                    })
                end
            end
        end
        if #annotations == 0 then
            UIManager:show(InfoMessage:new{ text = _("No highlights or notes in this book.") })
            return
        end
        local document_id = self.ui.doc_settings:readSetting("partial_md5_checksum") or util.partialMD5(self.ui.document.file)
        if not document_id then
            UIManager:show(InfoMessage:new{ text = _("Could not identify this document for syncing.") })
            return
        end
        local author = (booknotes.author or ""):gsub("\n", ", ")
        local uploaded = 0
        local failure
        for offset = 1, #annotations, 10 do
            local batch = {}
            for index = offset, math.min(offset + 9, #annotations) do
                table.insert(batch, annotations[index])
            end
            local encoded, encode_error = rapidjson.encode({
                document_id = document_id,
                title = booknotes.title or self.ui.doc_props.display_title or "Untitled",
                author = author,
                annotations = batch,
            })
            if not encoded then
                failure = encode_error or "JSON encoding failed"
                break
            end
            local response = {}
            socketutil:set_timeout(10, 30)
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
                sink = ltn12.sink.table(response),
            })
            socketutil:reset_timeout()
            if code ~= 200 and code ~= 201 then
                if code == 401 then
                    failure = _("Unauthorized. Check the sync username and password in Configure connection.")
                else
                    failure = status or code or "network error"
                end
                break
            end
            uploaded = uploaded + #batch
        end
        if failure then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Synced %d of %d items. Sync stopped: %s"), uploaded, #annotations, failure),
            })
        else
            UIManager:show(InfoMessage:new{ text = string.format(_("Synced %d highlights and notes."), uploaded) })
        end
    end)
end

function MyBibliotheca:saveSettings()
    self.settings:saveSetting("mybibliotheca", self.config)
    self.settings:flush()
end

return MyBibliotheca
