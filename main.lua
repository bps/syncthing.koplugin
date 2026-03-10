--[[--
Syncthing plugin for KOReader.

Start/stop a bundled Syncthing binary and expose its web UI address so another
device on the same network can configure folders and peers.

Works on both Kindle and Kobo — platform differences (firewall, loopback
interface, CA certificates) are handled at runtime.

@module koplugin.Syncthing
--]]

local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local SYNCTHING_PORT = 8384
local SYNCTHING_REPO = "syncthing/syncthing"

local function fileExists(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

local Syncthing = WidgetContainer:extend{
    name = "syncthing",
    is_doc_only = false,
    loopback_was_down = false,
}

---------------------------------------------------------------------------
-- Paths
---------------------------------------------------------------------------

function Syncthing:pluginPath()
    return self.path
end

function Syncthing:binaryPath()
    return self:pluginPath() .. "/bin/syncthing"
end

--- Config/database directory (persists across plugin updates).
function Syncthing:homePath()
    return DataStorage:getSettingsDir() .. "/syncthing"
end

function Syncthing:logPath()
    return self:pluginPath() .. "/syncthing.log"
end

--- Return the path to a usable CA certificate bundle, or nil.
-- Kobo lacks a system CA store; we ship our own cacert.pem.
function Syncthing:caCertPath()
    local candidates = {
        self:pluginPath() .. "/cacert.pem",
        "/etc/ssl/certs/ca-certificates.crt",
        "/etc/ssl/cert.pem",
    }
    for _, path in ipairs(candidates) do
        if fileExists(path) then
            return path
        end
    end
    return nil
end

--- Shell variable prefix that sets SSL_CERT_FILE, or "".
function Syncthing:sslEnvPrefix()
    local ca = self:caCertPath()
    return ca and string.format('SSL_CERT_FILE="%s" ', ca) or ""
end

---------------------------------------------------------------------------
-- Process management
---------------------------------------------------------------------------

--- Return the PID of the running syncthing process, or nil.
function Syncthing:getPid()
    local handle = io.popen("pidof syncthing 2>/dev/null")
    if not handle then return nil end
    local output = handle:read("*a")
    handle:close()
    local pid = output and output:match("(%d+)")
    return pid and tonumber(pid)
end

function Syncthing:isRunning()
    return self:getPid() ~= nil
end

function Syncthing:hasBinary()
    return fileExists(self:binaryPath())
end

---------------------------------------------------------------------------
-- Loopback interface
--
-- Kobo's lo is down by default; we must bring it up so we can reach the
-- Syncthing REST API on 127.0.0.1.  We restore the original state on stop.
---------------------------------------------------------------------------

--- Return true if the loopback interface is up.
function Syncthing:isLoopbackUp()
    local h = io.popen("cat /sys/class/net/lo/operstate 2>/dev/null")
    if not h then return false end
    local state = h:read("*a"):gsub("%s+", "")
    h:close()
    return state == "unknown" or state == "up"
end

function Syncthing:ensureLoopbackUp()
    if not self:isLoopbackUp() then
        os.execute("ifconfig lo 127.0.0.1 up 2>/dev/null || ip link set lo up 2>/dev/null")
        self.loopback_was_down = true
    end
end

function Syncthing:restoreLoopback()
    if self.loopback_was_down then
        os.execute("ifconfig lo down 2>/dev/null || ip link set lo down 2>/dev/null")
        self.loopback_was_down = false
    end
end

---------------------------------------------------------------------------
-- Firewall (Kindle only — Kobo has no iptables)
---------------------------------------------------------------------------

function Syncthing:openFirewall()
    os.execute(string.format(
        "iptables -C INPUT -p tcp --dport %d -j ACCEPT 2>/dev/null || "
        .. "iptables -A INPUT -p tcp --dport %d -j ACCEPT 2>/dev/null",
        SYNCTHING_PORT, SYNCTHING_PORT))
end

function Syncthing:closeFirewall()
    os.execute(string.format(
        "iptables -D INPUT -p tcp --dport %d -j ACCEPT 2>/dev/null",
        SYNCTHING_PORT))
end

---------------------------------------------------------------------------
-- Start / stop
---------------------------------------------------------------------------

function Syncthing:start()
    if self:isRunning() then return true end

    local bin = self:binaryPath()
    if not self:hasBinary() then
        return false, "Syncthing binary not found at " .. bin
    end

    os.execute("mkdir -p " .. self:homePath())
    self:ensureLoopbackUp()
    self:openFirewall()

    os.execute(string.format(
        "%s%s serve --no-browser --home=%s --gui-address=0.0.0.0:%d > %s 2>&1 &",
        self:sslEnvPrefix(), bin, self:homePath(), SYNCTHING_PORT, self:logPath()))

    for _ = 1, 10 do
        os.execute("sleep 0.5")
        if self:isRunning() then return true end
    end
    return false, "Syncthing process did not start. Check " .. self:logPath()
end

function Syncthing:stop()
    local pid = self:getPid()
    if not pid then return true end

    os.execute("kill " .. pid .. " 2>/dev/null")
    for _ = 1, 10 do
        os.execute("sleep 0.5")
        if not self:isRunning() then break end
    end
    if self:isRunning() then
        os.execute("kill -9 " .. pid .. " 2>/dev/null")
    end

    self:closeFirewall()
    self:restoreLoopback()
    return true
end

---------------------------------------------------------------------------
-- HTTP helpers (for GitHub downloads — not the local API)
---------------------------------------------------------------------------

--- Fetch a URL body via wget (Kobo) or curl (Kindle).
function Syncthing:httpGet(url)
    local ssl = self:sslEnvPrefix()
    local handle = io.popen(string.format(
        '%swget -qO- "%s" 2>/dev/null || %scurl -sfL "%s" 2>/dev/null',
        ssl, url, ssl, url))
    if not handle then return nil end
    local body = handle:read("*a")
    handle:close()
    return (body and body ~= "") and body or nil
end

--- Download a URL to a local file.  Returns true on success.
function Syncthing:httpDownload(url, dest)
    local ssl = self:sslEnvPrefix()
    if os.execute(string.format('%swget -qO "%s" "%s" 2>/dev/null', ssl, dest, url)) == 0 then
        return true
    end
    if os.execute(string.format('%scurl -sfL -o "%s" "%s" 2>/dev/null', ssl, dest, url)) == 0 then
        return true
    end
    return false
end

---------------------------------------------------------------------------
-- Binary management (download from GitHub)
---------------------------------------------------------------------------

--- Detect CPU architecture.  Returns "arm" or "arm64", or nil + error.
function Syncthing:detectArch()
    local handle = io.popen("uname -m 2>/dev/null")
    if not handle then return nil, "Could not detect architecture." end
    local uname = handle:read("*l")
    handle:close()
    if not uname or uname == "" then return nil, "Could not read architecture." end

    if uname == "aarch64" or uname == "arm64" then return "arm64" end
    if uname:match("^arm") then return "arm" end
    return nil, "Unsupported architecture: " .. uname
end

function Syncthing:getLatestReleaseTag()
    local body = self:httpGet(
        "https://api.github.com/repos/" .. SYNCTHING_REPO .. "/releases/latest")
    if not body then return nil end
    return body:match('"tag_name"%s*:%s*"([^"]+)"')
end

function Syncthing:getInstalledVersion()
    if not self:hasBinary() then return nil end
    local handle = io.popen(self:binaryPath() .. " --version 2>/dev/null")
    if not handle then return "unknown" end
    local line = handle:read("*l")
    handle:close()
    if line then
        local ver = line:match("syncthing%s+(v[%d%.%-rc]+)")
        if ver then return ver end
    end
    return "unknown"
end

--- Download and install the latest Syncthing release.
-- Returns ok, message.
function Syncthing:downloadBinary(arch)
    if not arch then
        local err
        arch, err = self:detectArch()
        if not arch then return false, err end
    end

    local tag = self:getLatestReleaseTag()
    if not tag then
        return false, "Could not determine latest release.\nCheck your internet connection."
    end

    local asset = string.format("syncthing-linux-%s-%s.tar.gz", arch, tag)
    local url = string.format("https://github.com/%s/releases/download/%s/%s",
        SYNCTHING_REPO, tag, asset)

    local tmp = "/tmp/syncthing-dl"
    os.execute("rm -rf " .. tmp)
    os.execute("mkdir -p " .. tmp)

    if not self:httpDownload(url, tmp .. "/" .. asset) then
        os.execute("rm -rf " .. tmp)
        return false, "Download failed.\n\n" .. url
    end

    if os.execute(string.format('tar xzf "%s/%s" -C "%s"', tmp, asset, tmp)) ~= 0 then
        os.execute("rm -rf " .. tmp)
        return false, "Failed to extract archive."
    end

    local extracted = string.format("%s/syncthing-linux-%s-%s/syncthing", tmp, arch, tag)
    local dest = self:binaryPath()
    os.execute("mkdir -p " .. self:pluginPath() .. "/bin")

    if os.execute(string.format('mv "%s" "%s"', extracted, dest)) ~= 0 then
        os.execute("rm -rf " .. tmp)
        return false, "Failed to install binary."
    end

    os.execute("chmod +x " .. dest)
    os.execute("rm -rf " .. tmp)
    return true, string.format("Syncthing %s (%s) installed.", tag:gsub("^v", ""), arch)
end

---------------------------------------------------------------------------
-- Network helpers
---------------------------------------------------------------------------

function Syncthing:getIP()
    for _, iface in ipairs({"wlan0", "eth0", "usb0"}) do
        local handle = io.popen(
            "ip -4 addr show " .. iface .. " 2>/dev/null"
            .. " | awk '/inet /{split($2,a,\"/\"); print a[1]}'")
        if handle then
            local ip = handle:read("*l")
            handle:close()
            if ip and ip ~= "" then return ip end
        end
    end
    return nil
end

function Syncthing:guiURL()
    local ip = self:getIP()
    if ip then
        return string.format("http://%s:%d", ip, SYNCTHING_PORT)
    end
    return string.format("http://<device-ip>:%d", SYNCTHING_PORT)
end

---------------------------------------------------------------------------
-- Syncthing REST API
--
-- Uses a raw TCP socket with HTTP/1.0 to avoid:
--   • busybox wget: no --header support, hangs on chunked encoding
--   • KOReader's LuaSocket http.request: unexplained timeout on localhost
-- HTTP/1.0 guarantees Content-Length (no chunked encoding).
---------------------------------------------------------------------------

function Syncthing:apiGet(endpoint)
    local socket = require("socket")
    local api_key = self:getAPIKey()

    local tcp = socket.tcp()
    tcp:settimeout(5)
    local ok, err = tcp:connect("127.0.0.1", SYNCTHING_PORT)
    if not ok then
        logger.warn("Syncthing:apiGet: connect failed:", err)
        tcp:close()
        return nil
    end

    local req = "GET /rest/" .. endpoint .. " HTTP/1.0\r\n"
        .. "Host: 127.0.0.1\r\n"
    if api_key then
        req = req .. "X-API-Key: " .. api_key .. "\r\n"
    end
    req = req .. "\r\n"

    tcp:send(req)
    local response = tcp:receive("*a")
    tcp:close()

    if not response then return nil end
    local body = response:match("\r\n\r\n(.*)")
    if not body or body == "" then return nil end

    local json_ok, json = pcall(require, "rapidjson")
    if not json_ok then return nil end
    local parse_ok, data = pcall(json.decode, body)
    return parse_ok and data or nil
end

function Syncthing:getAPIKey()
    local f = io.open(self:homePath() .. "/config.xml", "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content:match("<apikey>([^<]+)</apikey>")
end

---------------------------------------------------------------------------
-- Sync status
---------------------------------------------------------------------------

--- Format a byte count for display (e.g. "12.3 MB").
local function formatBytes(bytes)
    if     bytes < 1024           then return string.format("%d B", bytes)
    elseif bytes < 1024^2         then return string.format("%.1f KB", bytes / 1024)
    elseif bytes < 1024^3         then return string.format("%.1f MB", bytes / 1024^2)
    else                               return string.format("%.2f GB", bytes / 1024^3)
    end
end

function Syncthing:getSyncStatus()
    if not self:isRunning() then
        return "Syncthing is not running."
    end

    local config = self:apiGet("system/config")
    if not config or not config.folders then
        return "Could not retrieve status from Syncthing API."
    end

    local lines = {}
    local all_synced = true
    for _, folder in ipairs(config.folders) do
        local st = self:apiGet("db/status?folder=" .. folder.id)
        if st then
            local need = (st.needBytes or 0) + (st.needDeletes or 0)
            if need > 0 then
                all_synced = false
                table.insert(lines, string.format("  • %s: %s remaining",
                    folder.label or folder.id, formatBytes(st.needBytes or 0)))
            end
        end
    end

    if all_synced then return "Everything is up to date." end
    table.insert(lines, 1, "Remaining to sync:")
    return table.concat(lines, "\n")
end

---------------------------------------------------------------------------
-- UI helpers
---------------------------------------------------------------------------

function Syncthing:popup(text, timeout)
    if self._popup then
        UIManager:close(self._popup)
        self._popup = nil
    end
    local popup = InfoMessage:new{ text = text }
    self._popup = popup
    UIManager:show(popup)
    UIManager:scheduleIn(timeout or 3, function()
        if self._popup == popup then
            UIManager:close(popup)
            self._popup = nil
        end
    end)
end

function Syncthing:runWithNetwork(action)
    if NetworkMgr:isOnline() then
        action()
    else
        NetworkMgr:turnOnWifiAndWaitForConnection(action)
    end
end

---------------------------------------------------------------------------
-- Menu
---------------------------------------------------------------------------

function Syncthing:init()
    self.ui.menu:registerToMainMenu(self)
end

function Syncthing:addToMainMenu(menu_items)
    menu_items.syncthing = {
        text = _("Syncthing"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return {
                -- Start / Stop toggle
                {
                    text_func = function()
                        if not self:hasBinary() then
                            return _("▶ Start Syncthing (binary not installed)")
                        elseif self:isRunning() then
                            return _("⏹ Stop Syncthing")
                        else
                            return _("▶ Start Syncthing")
                        end
                    end,
                    enabled_func = function() return self:hasBinary() end,
                    callback = function()
                        if self:isRunning() then
                            self:stop()
                            self:popup(_("Syncthing stopped."))
                        else
                            self:runWithNetwork(function()
                                self:startAndNotify()
                            end)
                        end
                    end,
                },
                -- Connection info
                {
                    text = _("Connection info"),
                    enabled_func = function() return self:isRunning() end,
                    keep_menu_open = true,
                    callback = function()
                        self:popup(
                            _("Open the Syncthing Web UI from\nanother device on the same network:\n\n")
                            .. self:guiURL(), 10)
                    end,
                },
                -- Sync status
                {
                    text = _("Sync status"),
                    enabled_func = function() return self:isRunning() end,
                    keep_menu_open = true,
                    callback = function()
                        self:popup(self:getSyncStatus(), 10)
                    end,
                },
                -- Download / Update binary
                {
                    text_func = function()
                        if self:hasBinary() then
                            local ver = self:getInstalledVersion() or "?"
                            return _("Update binary") .. "  (" .. ver .. ")"
                        else
                            return _("Download binary")
                        end
                    end,
                    callback = function()
                        self:runWithNetwork(function()
                            self:downloadAndNotify()
                        end)
                    end,
                },
            }
        end,
    }
end

function Syncthing:startAndNotify()
    local ok, err = self:start()
    if ok then
        self:popup(_("Syncthing started.\n\nWeb UI:\n") .. self:guiURL(), 8)
    else
        self:popup(_("Failed to start Syncthing:\n\n") .. (err or "unknown error"), 8)
    end
end

function Syncthing:downloadAndNotify()
    local arch = self:detectArch()
    self:popup(_("Downloading Syncthing for ") .. (arch or "arm") .. "…\n"
        .. _("This may take a minute."), 60)
    UIManager:scheduleIn(0.1, function()
        local ok, msg = self:downloadBinary(arch)
        self:popup(msg, ok and 5 or 10)
    end)
end

return Syncthing
