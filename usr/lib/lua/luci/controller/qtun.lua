module("luci.controller.qtun", package.seeall)

function index()
    local page = entry({"admin", "services", "qtun"}, alias("admin", "services", "qtun", "dashboard"), _("QTUN"), 10)
    page.dependent = true

    entry({"admin", "services", "qtun", "dashboard"}, template("qtun/dashboard"), _("Dashboard"), 1)
    entry({"admin", "services", "qtun", "config"}, cbi("qtun/config"), _("Tunnel Config"), 2)
    -- entry({"admin", "services", "qtun", "routing"}, cbi("qtun/routing"), _("Routing & Rules"), 3)
    -- entry({"admin", "services", "qtun", "advanced"}, cbi("qtun/advanced"), _("Advanced Tools"), 4)
    entry({"admin", "services", "qtun", "logs"}, template("qtun/logs"), _("Logs & Terminal"), 5)

    -- API
    entry({"admin", "services", "qtun", "status"}, call("action_status")).leaf = true
    entry({"admin", "services", "qtun", "start"}, call("action_start")).leaf = true
    entry({"admin", "services", "qtun", "stop"}, call("action_stop")).leaf = true
    entry({"admin", "services", "qtun", "restart"}, call("action_restart")).leaf = true
    entry({"admin", "services", "qtun", "set_config"}, call("action_set_config")).leaf = true

    entry({"admin", "services", "qtun", "clash_sub_save"}, call("action_clash_sub_save")).leaf = true
    entry({"admin", "services", "qtun", "clash_sub_update"}, call("action_clash_sub_update")).leaf = true
    entry({"admin", "services", "qtun", "clash_sub_list"}, call("action_clash_sub_list")).leaf = true

    entry({"admin", "services", "qtun", "clash_profile_get"}, call("action_clash_profile_get")).leaf = true
    entry({"admin", "services", "qtun", "clash_profile_save"}, call("action_clash_profile_save")).leaf = true
    entry({"admin", "services", "qtun", "clash_profile_delete"}, call("action_clash_profile_delete")).leaf = true
    -- API untuk mengambil data log via AJAX
    entry({"admin", "services", "qtun", "get_log"}, call("action_get_log"), nil).leaf = true
    -- PUBLIC IP API (NO LOGIN)
    entry({"qtun", "ipinfo"}, call("action_ipinfo")).leaf = true
end

local function file_exists(path)
    local fs = require "nixio.fs"
    return fs.access(path)
end

local function readfile(path, fallback)
    local fs = require "nixio.fs"
    return fs.readfile(path) or fallback or ""
end

local function list_clash_profiles()
    local fs = require "nixio.fs"

    local dir = "/etc/qtun/config/clash/mihomo"
    local profiles = {}

    if not fs.access(dir) then
        return profiles
    end

    for file in fs.dir(dir) do
        if file and file:match("%.ya?ml$") then
            profiles[#profiles + 1] = file
        end
    end

    table.sort(profiles)
    return profiles
end

local function first_clash_profile()
    local profiles = list_clash_profiles()
    return profiles[1] or ""
end

local function ensure_clash_section(uci)
    if not uci:get("qtun", "clash") then
        uci:section("qtun", "clash", "clash", {})
    end
end

-- STATUS (Sinkronisasi dengan Pilihan Dashboard Backend)
function action_status()
    local sys = require "luci.sys"
    local uci = require("luci.model.uci").cursor()

    local mode = uci:get("qtun", "main", "mode") or "zivpn"
    local enabled = uci:get("qtun", "main", "enabled") or "0"
    local backend = uci:get("qtun", "main", "backend") or "clash"
    local qssh_inject_mode = uci:get("qtun", "main", "qssh_inject_mode") or "ssl_payload"

    local clash_profile = uci:get("qtun", "clash", "profile") or ""
    local clash_profiles = list_clash_profiles()

    if clash_profile == "" then
        clash_profile = first_clash_profile()
    end

    local running = false

    -- =========================================================
    -- DETEKSI STATUS MENYALA UNTUK MODE Q-SSH
    -- =========================================================
    if mode == "q-ssh" then
        running = (sys.call("pgrep Q-SSH-WORKER >/dev/null") == 0) and (sys.call("pgrep q-load >/dev/null") == 0)
    elseif mode == "zivpn" then
        running = (sys.call("pgrep zivpn >/dev/null") == 0) or (sys.call("pgrep mihomo >/dev/null") == 0)
    elseif mode == "clash" then
        running = (sys.call("pgrep clash >/dev/null") == 0) or (sys.call("pgrep mihomo >/dev/null") == 0)
    elseif mode == "ssh" or mode == "ssh_ws" or mode == "ssh_ssl" then
        running = (sys.call("[ -f /etc/qtun/run/ssh_worker.pid ] && kill -0 $(cat /etc/qtun/run/ssh_worker.pid) 2>/dev/null") == 0)
    else 
        running = (sys.call("pgrep clash >/dev/null") == 0) or (sys.call("pgrep mihomo >/dev/null") == 0)
    end

    local clash_running = (sys.call("[ -f /etc/qtun/run/clash.pid ] && kill -0 $(cat /etc/qtun/run/clash.pid) 2>/dev/null") == 0)

    local log = ""

    -- =========================================================
    -- LOAD LOG LIVE UNTUK PREVIEW DASHBOARD UTAMA
    -- =========================================================
    if mode == "q-ssh" then
        log = sys.exec("tail -n 30 /etc/qtun/run/q-ssh.log 2>/dev/null")
        if log == "" then log = sys.exec("tail -n 30 /etc/qtun/run/q-load.log 2>/dev/null") end
    elseif mode == "zivpn" then
        log = sys.exec("tail -n 30 /etc/qtun/run/zivpn.log 2>/dev/null")
        if log == "" then log = sys.exec("tail -n 30 /etc/qtun/run/clash.log 2>/dev/null") end
    elseif mode == "clash" then
        log = readfile("/etc/qtun/run/clash.log", "")
    elseif mode == "ssh" or mode == "ssh_ws" or mode == "ssh_ssl" then
        log = readfile("/etc/qtun/run/ssh.log", "")
    else 
        log = sys.exec("tail -n 30 /etc/qtun/run/qtun_live.log 2>/dev/null")
    end

    local data = {
        running = running,
        clash_running = clash_running,
        mode = mode,
        backend = backend,
        qssh_inject_mode = qssh_inject_mode,
        enabled = enabled,
        clash_profile = clash_profile,
        clash_profiles = clash_profiles,
        log = log
    }

    luci.http.prepare_content("application/json")
    luci.http.write_json(data)
end

-- START
function action_start()
    local sys = require "luci.sys"
    sys.call("/etc/qtun/action/qtun.sh start >/dev/null 2>&1 &")

    luci.http.prepare_content("application/json")
    luci.http.write_json({
        success = true,
        action = "start"
    })
end

-- STOP
function action_stop()
    local sys = require "luci.sys"
    sys.call("/etc/qtun/action/qtun.sh stop >/dev/null 2>&1 &")

    luci.http.prepare_content("application/json")
    luci.http.write_json({
        success = true,
        action = "stop"
    })
end

-- RESTART
function action_restart()
    local sys = require "luci.sys"
    sys.call("/etc/qtun/action/qtun.sh restart >/dev/null 2>&1 &")

    luci.http.prepare_content("application/json")
    luci.http.write_json({
        success = true,
        action = "restart"
    })
end

-- SAVE CONFIG (Dinamis Akurat untuk Pemisahan Clash Murni & ZiVPN)
function action_set_config()
    local http = require "luci.http"
    local uci = require("luci.model.uci").cursor()

    local mode = http.formvalue("mode")
    local enabled = http.formvalue("enabled")
    local backend = http.formvalue("backend")
    local clash_profile = http.formvalue("clash_profile")
    local qssh_inject_mode = http.formvalue("qssh_inject_mode")

    if mode then
        uci:set("qtun", "main", "mode", mode)
        
        if mode == "clash" or mode == "zivpn" or mode == "q-ssh" then
            uci:delete("qtun", "main", "backend")
        else
            if backend then
                uci:set("qtun", "main", "backend", backend)
            end
        end
    end

    -- Murni simpan pilihan inject mode ke UCI /etc/config/qtun
    if qssh_inject_mode and qssh_inject_mode ~= "" then
        uci:set("qtun", "main", "qssh_inject_mode", qssh_inject_mode)
    end

    if enabled then
        uci:set("qtun", "main", "enabled", enabled)
    end

    if backend and mode ~= "clash" and mode ~= "zivpn" and mode ~= "q-ssh" then
        uci:set("qtun", "main", "backend", backend)
    end

    if clash_profile then
        ensure_clash_section(uci)
        uci:set("qtun", "clash", "profile", clash_profile)
    end

    uci:commit("qtun")

    luci.http.prepare_content("application/json")
    luci.http.write_json({
        success = true
    })
end

local function sanitize_yaml_name(name)
    name = name or ""
    name = name:gsub("[/\\]", "")
    name = name:gsub("%.%.", "")
    name = name:gsub("%s+", "_")

    if name == "" then
        name = "clash.yaml"
    end

    if not name:match("%.ya?ml$") then
        name = name .. ".yaml"
    end

    return name
end

local function filename_from_url(url)
    url = url or ""

    local clean = url:gsub("[?#].*$", "")
    local name = clean:match("([^/]+)$") or ""

    name = sanitize_yaml_name(name)

    if name == "" or name == ".yaml" then
        name = "subscription.yaml"
    end

    if not name:match("%.ya?ml$") then
        name = name .. ".yaml"
    end

    return name
end

function action_clash_sub_save()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local fs = require "nixio.fs"

    local dir = "/etc/qtun/config/clash/mihomo"
    local subdir = "/etc/qtun/config/clash/subscriptions"

    local url = http.formvalue("url") or ""
    local file = http.formvalue("file") or ""

    fs.mkdirr(dir)
    fs.mkdirr(subdir)

    if url == "" then
        http.prepare_content("application/json")
        http.write_json({
            success = false,
            message = "Subscription URL kosong"
        })
        return
    end

    if file == "" then
        file = filename_from_url(url)
    else
        file = sanitize_yaml_name(file)
    end

    local tmp = "/tmp/qtun-sub-download.yaml"
    local out = dir .. "/" .. file

    local cmd = string.format(
        "curl -L -s --max-time 30 --connect-timeout 10 -A 'clash.meta' %q -o %q",
        url,
        tmp
    )

    local rc = sys.call(cmd)

    if rc ~= 0 or not fs.access(tmp) then
        http.prepare_content("application/json")
        http.write_json({
            success = false,
            message = "Gagal download subscription"
        })
        return
    end

    local content = fs.readfile(tmp) or ""

    if content == "" then
        fs.remove(tmp)
        http.prepare_content("application/json")
        http.write_json({
            success = false,
            message = "Subscription kosong"
        })
        return
    end

    if not content:match("proxies:") and not content:match("proxy%-providers:") then
        fs.remove(tmp)
        http.prepare_content("application/json")
        http.write_json({
            success = false,
            message = "File subscription tidak terlihat seperti config Clash YAML"
        })
        return
    end

    fs.writefile(out, content)
    fs.writefile(subdir .. "/" .. file .. ".url", url)
    fs.remove(tmp)

    http.prepare_content("application/json")
    http.write_json({
        success = true,
        file = file,
        url = url
    })
end

function action_clash_sub_update()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local fs = require "nixio.fs"

    local dir = "/etc/qtun/config/clash/mihomo"
    local subdir = "/etc/qtun/config/clash/subscriptions"

    local file = sanitize_yaml_name(http.formvalue("file"))
    local urlfile = subdir .. "/" .. file .. ".url"
    local url = fs.readfile(urlfile) or ""

    url = url:gsub("%s+$", "")

    if url == "" then
        http.prepare_content("application/json")
        http.write_json({
            success = false,
            message = "Config ini bukan subscription or URL tidak ditemukan"
        })
        return
    end

    local tmp = "/tmp/qtun-sub-update.yaml"
    local out = dir .. "/" .. file

    local cmd = string.format(
        "curl -L -s --max-time 30 --connect-timeout 10 -A 'clash.meta' %q -o %q",
        url,
        tmp
    )

    local rc = sys.call(cmd)

    if rc ~= 0 or not fs.access(tmp) then
        http.prepare_content("application/json")
        http.write_json({
            success = false,
            message = "Gagal update subscription"
        })
        return
    end

    local content = fs.readfile(tmp) or ""

    if content == "" then
        fs.remove(tmp)
        http.prepare_content("application/json")
        http.write_json({
            success = false,
            message = "Subscription update kosong"
        })
        return
    end

    fs.writefile(out, content)
    fs.remove(tmp)

    http.prepare_content("application/json")
    http.write_json({
        success = true,
        file = file,
        url = url
    })
end

function action_clash_sub_list()
    local http = require "luci.http"
    local fs = require "nixio.fs"

    local subdir = "/etc/qtun/config/clash/subscriptions"
    local list = {}

    fs.mkdirr(subdir)

    for file in fs.dir(subdir) do
        if file and file:match("%.ya?ml%.url$") then
            local yaml = file:gsub("%.url$", "")
            local url = fs.readfile(subdir .. "/" .. file) or ""
            url = url:gsub("%s+$", "")

            list[#list + 1] = {
                file = yaml,
                url = url
            }
        end
    end

    table.sort(list, function(a, b)
        return a.file < b.file
    end)

    http.prepare_content("application/json")
    http.write_json({
        success = true,
        subscriptions = list
    })
end

function action_clash_profile_get()
    local http = require "luci.http"
    local fs = require "nixio.fs"

    local dir = "/etc/qtun/config/clash/mihomo"
    local file = sanitize_yaml_name(http.formvalue("file"))
    local path = dir .. "/" .. file

    fs.mkdirr(dir)

    if not fs.access(path) then
        http.prepare_content("application/json")
        http.write_json({
            success = false,
            message = "File tidak ditemukan: " .. file
        })
        return
    end

    http.prepare_content("application/json")
    http.write_json({
        success = true,
        file = file,
        content = fs.readfile(path) or ""
    })
end

function action_clash_profile_save()
    local http = require "luci.http"
    local fs = require "nixio.fs"

    local dir = "/etc/qtun/config/clash/mihomo"
    local file = sanitize_yaml_name(http.formvalue("file"))
    local content = http.formvalue("content") or ""

    fs.mkdirr(dir)

    if file == "" or file == ".yaml" then
        http.prepare_content("application/json")
        http.write_json({
            success = false,
            message = "Nama file tidak valid"
        })
        return
    end

    fs.writefile(dir .. "/" .. file, content)

    http.prepare_content("application/json")
    http.write_json({
        success = true,
        file = file
    })
end

function action_clash_profile_delete()
    local http = require "luci.http"
    local fs = require "nixio.fs"
    local uci = require("luci.model.uci").cursor()

    local dir = "/etc/qtun/config/clash/mihomo"
    local file = sanitize_yaml_name(http.formvalue("file"))
    local active = uci:get("qtun", "clash", "profile") or ""

    if file == active then
        http.prepare_content("application/json")
        http.write_json({
            success = false,
            message = "Tidak boleh delete config yang sedang aktif"
        })
        return
    end

    fs.remove(dir .. "/" .. file)

    http.prepare_content("application/json")
    http.write_json({
        success = true,
        file = file
    })
end

-- =========================================================
-- PERBAIKAN UTAMA: PETAKAN LOG Q-SSH KE VARIABEL CORE
-- Dipanggil AJAX dari log.htm untuk render isi data.core
-- =========================================================
function action_get_log()
    local fs = require "nixio.fs"
    local uci = require("luci.model.uci").cursor()

    local mode = uci:get("qtun", "main", "mode") or "zivpn"

    local core_log = "Belum ada log Core."

    if mode == "q-ssh" then
        core_log = fs.readfile("/etc/qtun/run/q-ssh.log")
            or "Belum ada log Core."
    elseif mode == "zivpn" then
        core_log = fs.readfile("/etc/qtun/run/zivpn.log")
            or "Belum ada log Core."
    elseif mode == "ssh" or mode == "ssh_ws" or mode == "ssh_ssl" then
        core_log = fs.readfile("/etc/qtun/run/ssh.log")
            or "Belum ada log Core."
    elseif mode == "clash" then
        core_log = fs.readfile("/etc/qtun/run/clash.log")
            or "Belum ada log Core."
    end

    local data = {
        process = fs.readfile("/etc/qtun/run/qtun_live.log")
            or "Belum ada log proses.",
        core = core_log, -- Akan otomatis ditangkap Javascript data.core bawaan log.htm
        clash = fs.readfile("/etc/qtun/run/clash.log")
            or "Belum ada log Clash."
    }

    luci.http.prepare_content("application/json")
    luci.http.write_json(data)
end

function action_ipinfo()
    local sys = require "luci.sys"
    local result = sys.exec("curl -s --max-time 8 http://ip-api.com/json 2>/dev/null")

    if result == nil or result == "" then
        result = '{"status":"fail","message":"Unable to fetch IP info"}'
    end

    luci.http.prepare_content("application/json")
    luci.http.write(result)
end