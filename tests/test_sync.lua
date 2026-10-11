-- Run from the plugin directory: lua tests/test_sync.lua
-- KOReader interfaces are stubbed; no network requests or device files are used.
local function class()
    local c = {}
    function c:extend(o) return setmetatable(o, { __index = self }) end
    function c:new(o) return setmetatable(o or {}, { __index = self }) end
    return c
end
local function settings(values)
    return {
        values = values or {}, flushes = 0,
        readSetting = function(self, k) return self.values[k] end,
        saveSetting = function(self, k, v) self.values[k] = v end,
        flush = function(self) self.flushes = self.flushes + 1 end,
    }
end
local network = { connected = true, manual_calls = 0 }
function network:isConnected() return self.connected end
function network:runWhenOnline(cb) self.manual_calls = self.manual_calls + 1; cb() end
local manager = { messages = {} }
function manager:show(widget) self.messages[#self.messages + 1] = widget end
function manager:close() end
local timeouts = { resets = 0 }
function timeouts:set_timeout(a, b) self.current = { a, b } end
function timeouts:reset_timeout() self.resets = self.resets + 1 end
local transport = { requests = {}, fail_at = nil, throws = false }
local encoded_payload
function transport.request(req)
    if transport.throws then error('transport exception') end
    assert(req.sink ~= nil)
    local entries = {}
    for i, entry in ipairs(encoded_payload.annotations) do entries[i] = entry end
    transport.requests[#transport.requests + 1] = { entries = entries, req = req, timeout = timeouts.current }
    if #transport.requests == transport.fail_at then return 1, 401, {}, 'Unauthorized' end
    return 1, 201, {}, 'Created'
end
-- Fixed-size fake hash for change detection; the real plugin uses KOReader's MD5.
local function hash(s)
    local h = 0
    for i = 1, #s do h = (h * 31 + s:byte(i)) % 2147483647 end
    return string.format('%032x', h)
end
local parser = class()
function parser:getTitleAuthor() return 'Book', 'Author' end
function parser:getText(s) return (s or ''):match('^%s*(.-)%s*$') end
function parser:getTime(s) return tonumber(s) end
function parser:doesHighlightMatch(item) return item.drawer ~= nil end
local dialog = class()
function dialog:addWidget(w) self.checkbox = w end
function dialog:getFields() return self.values end
function dialog:onShowKeyboard() end
local global_settings = settings()
local settings_path
local stubs = {
    datastorage = { getSettingsDir = function() return '/unused' end },
    ['ui/widget/checkbutton'] = class(),
    ['ui/widget/infomessage'] = class(),
    luasettings = { open = function(_, path) settings_path = path; return global_settings end },
    ['ui/widget/multiinputdialog'] = dialog,
    ['ui/network/manager'] = network,
    ['ui/uimanager'] = manager,
    ['ui/widget/container/widgetcontainer'] = class(),
    logger = { warn = function() end, dbg = function() end },
    ['socket.http'] = transport,
    ltn12 = { source = { string = function(s) return s end }, sink = { null = function() return function() return 1 end end } },
    ['ffi/sha2'] = { md5 = hash },
    rapidjson = { encode = function(payload) encoded_payload = payload; return '{}' end },
    socket = { skip = function(n, ...) local a = {...}; return table.unpack(a, n + 1) end },
    socketutil = timeouts,
    util = { partialMD5 = function() return 'document' end },
    gettext = function(s) return s end,
    clip = parser,
}
for name, module in pairs(stubs) do package.preload[name] = function() return module end end
local Plugin = dofile('main.lua')
local function fresh(count)
    transport.requests, transport.fail_at, transport.throws = {}, nil, false
    manager.messages, network.connected, network.manual_calls = {}, true, 0
    local annotations = {}
    for i = 1, count do
        annotations[i] = { drawer = 'lighten', text = ' highlight ' .. i .. ' ', note = '', pageno = i, datetime = '1000' }
    end
    local p = Plugin:new{
        config = { endpoint_url = 'https://example.org/notes', username = 'user', userkey = 'key', auto_push = true },
        settings = settings(),
        ui = {
            document = { file = '/book.epub' }, doc_settings = settings(), doc_props = {},
            annotation = { annotations = annotations, updatePageNumbers = function() end },
            menu = { registerToMainMenu = function() end },
            registerPostReaderReadyCallback = function(self, cb) self.ready = cb end,
        },
    }
    return p
end
local p = fresh(23)
p:onCloseDocument()
assert(#transport.requests == 3)
assert(#transport.requests[1].entries == 10 and #transport.requests[3].entries == 3)
assert(transport.requests[1].entries[1].id == hash('1\n1000\nhighlight 1'))
assert(transport.requests[1].req.headers['X-Auth-Key'] == 'key')
assert(transport.requests[1].timeout[2] == 5)
assert(network.manual_calls == 0 and #manager.messages == 0)
assert(p.ui.doc_settings:readSetting('mybibliotheca_pending') == false)
local old_digest = p.ui.doc_settings:readSetting('mybibliotheca_synced')
p:onCloseDocument()
assert(#transport.requests == 3, 'unchanged close must skip upload')
p.ui.annotation.annotations[1].note = 'new note'
p:onAnnotationsModified()
p:onNetworkConnected()
assert(#transport.requests == 6, 'edits must upload even just after a successful sync')
assert(p.ui.doc_settings:readSetting('mybibliotheca_synced') ~= old_digest)
p:onAnnotationsModified() -- e.g. a style change with unchanged upload content
p:onCloseDocument()
assert(#transport.requests == 6, 'unchanged content must skip HTTP')

p = fresh(1)
network.connected = false
p:onAnnotationsModified()
p:onCloseDocument()
assert(#transport.requests == 0 and network.manual_calls == 0)
assert(p.ui.doc_settings:readSetting('mybibliotheca_pending'))
-- Simulate reopening the book with its existing sidecar.
local reopened = fresh(1)
reopened.ui.doc_settings = p.ui.doc_settings
reopened:autoPush()
assert(#transport.requests == 1 and not reopened.ui.doc_settings:readSetting('mybibliotheca_pending'))

p = fresh(12)
transport.fail_at = 2
p:autoPush()
assert(#transport.requests == 2)
assert(p.ui.doc_settings:readSetting('mybibliotheca_pending'))
assert(p.ui.doc_settings:readSetting('mybibliotheca_synced') == nil)
p:onNetworkConnected()
assert(#transport.requests == 2, 'failed auto pushes must respect cooldown')
p.last_auto_attempt = os.time() - 301
transport.fail_at = nil
p:onCloseDocument()
assert(#transport.requests == 4 and not p.ui.doc_settings:readSetting('mybibliotheca_pending'))

p = fresh(1)
transport.throws = true
local resets = timeouts.resets
p:autoPush()
assert(not p.syncing and timeouts.resets > resets)
assert(p.ui.doc_settings:readSetting('mybibliotheca_pending'))
assert(p.ui.doc_settings.flushes > 0)

p = fresh(1)
p.config.auto_push = false
p:autoPush()
assert(#transport.requests == 0)
p:syncCurrentBook()
assert(#transport.requests == 1 and network.manual_calls == 1 and #manager.messages == 1)
assert(transport.requests[1].timeout[2] == 30)
-- Delayed manual callbacks must not export a different document.
local run = network.runWhenOnline
local deferred
network.runWhenOnline = function(_, cb) deferred = cb end
p:syncCurrentBook()
p.ui.document = { file = '/another.epub' }
deferred()
assert(#transport.requests == 1)
network.runWhenOnline = run

p = fresh(0)
p:autoPush()
assert(#transport.requests == 0 and not p.ui.doc_settings:readSetting('mybibliotheca_pending'))
p = fresh(1)
p.ui.annotation.annotations[1].drawer = nil
p:autoPush()
assert(#transport.requests == 0, 'plain bookmarks are not highlights')
p = fresh(1)
p.ui.document = nil
p:autoPush()
p:syncCurrentBook()
assert(#transport.requests == 0)

-- Setup offers the opt-in checkbox and persists it with valid credentials.
p = fresh(1)
p.config.auto_push = nil
p:configure()
local setup = manager.messages[#manager.messages]
assert(setup.checkbox.checked == false)
setup.checkbox.checked = true
setup.values = { 'https://example.org/notes/', 'user', 'long-password' }
setup.buttons[1][2].callback()
assert(p.config.auto_push and p.config.endpoint_url == 'https://example.org/notes')
assert(p.config.userkey == hash('long-password'))
assert(p.ui.doc_settings:readSetting('mybibliotheca_pending'))
local menu = {}
p:addToMainMenu(menu)
assert(menu.mybibliotheca.sub_item_table[2].checked_func())
menu.mybibliotheca.sub_item_table[2].callback()
assert(not p.config.auto_push)

-- Existing installations retain credentials and have auto-push disabled by default.
p = fresh(1)
global_settings.values.mybibliotheca = { username = 'existing', userkey = 'existing-key' }
p:init()
assert(p.config.username == 'existing' and p.config.auto_push == nil)
p.ui.ready()
assert(#transport.requests == 0)
-- Upgrade and sync must preserve credentials, unknown settings, and reader data.
local function copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for k, v in pairs(value) do result[k] = copy(v) end
    return result
end
local function equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    for k, v in pairs(a) do if not equal(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
p = fresh(12)
local saved_config = {
    endpoint_url = 'https://existing.example/notes', username = 'existing-user',
    userkey = 'existing-key', future_option = { enabled = true },
}
global_settings.values = {
    mybibliotheca = copy(saved_config), unrelated = { value = 'keep me' },
}
local original_settings = copy(global_settings.values)
local original_annotations = copy(p.ui.annotation.annotations)
local original_book_data = {
    annotations = copy(original_annotations), bookmarks = { { page = 7 } },
    percent_finished = 0.42, last_xpointer = '/body/chapter[3]',
    custom_metadata = { label = 'keep this too' },
}
p.ui.doc_settings.values = copy(original_book_data)
p:init()
assert(settings_path == '/unused/mybibliotheca.lua', 'upgrade must reuse the existing settings file')
assert(equal(global_settings.values, original_settings), 'initialization must not rewrite existing settings')
assert(equal(p.ui.doc_settings.values, original_book_data), 'initialization must not rewrite book data')
p:configure()
setup = manager.messages[#manager.messages]
assert(setup.fields[1].text == saved_config.endpoint_url and setup.fields[2].text == saved_config.username)
setup.values = { saved_config.endpoint_url, saved_config.username, '' }
setup.checkbox.checked = true
setup.buttons[1][2].callback()
local expected_config = copy(saved_config)
expected_config.auto_push = true
assert(equal(p.config, expected_config), 'blank password must preserve the existing sync key and unknown options')
assert(equal(global_settings.values.unrelated, original_settings.unrelated))

local function assert_book_preserved()
    for k, v in pairs(original_book_data) do
        assert(equal(p.ui.doc_settings.values[k], v), 'book data changed: ' .. k)
    end
    assert(equal(p.ui.annotation.annotations, original_annotations), 'sync must not alter highlight text or notes')
    for k in pairs(p.ui.doc_settings.values) do
        assert(original_book_data[k] ~= nil or k == 'mybibliotheca_pending' or k == 'mybibliotheca_synced',
            'sync wrote an unexpected book setting: ' .. k)
    end
end
network.connected = false
p:onAnnotationsModified()
p:onCloseDocument()
assert_book_preserved()
network.connected = true
transport.fail_at = 2
p:autoPush()
assert_book_preserved()
assert(p.ui.doc_settings:readSetting('mybibliotheca_pending'))
transport.fail_at = nil
p:syncCurrentBook()
assert_book_preserved()
assert(not p.ui.doc_settings:readSetting('mybibliotheca_pending'))

-- Invalid setup and Cancel must leave saved settings and credentials intact.
local before_invalid = copy(global_settings.values)
p:configure()
setup = manager.messages[#manager.messages]
setup.values = { 'http://invalid/notes', 'changed-user', '' }
setup.checkbox.checked = false
setup.buttons[1][2].callback()
assert(equal(global_settings.values, before_invalid))
assert(equal(p.config, expected_config))
setup.buttons[1][1].callback()
assert(equal(global_settings.values, before_invalid))

-- Reload the persisted settings as a subsequent update/restart would.
local restarted = fresh(1)
restarted:init()
assert(equal(restarted.config, expected_config), 'restart must retain saved auto-push and connection settings')
assert(equal(global_settings.values.unrelated, original_settings.unrelated))
print('All highlight sync tests passed')
