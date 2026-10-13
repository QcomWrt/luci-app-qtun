return function(s, mode_selector) 

    local cbi = require("luci.cbi")
    local Value = cbi.Value
    local ListValue = cbi.ListValue

    local fs = require "nixio.fs"
    local json = require "luci.jsonc"

    local base_dir = "/etc/qtun/config/q-ssh"

    -- Daftar 6 Mode Inject
    local modes = {
        "direct",
        "direct_payload",
        "ssh_proxy",
        "ssh_proxy_payload",
        "ssl_sni",
        "ssl_payload"
    }

    -- 1. LOAD SEMUA FILE JSON PER MODE KE DALAM TABLE 'configs'
    local configs = {}
    for _, m_name in ipairs(modes) do
        local p = base_dir .. "/" .. m_name .. ".json"
        if fs.access(p) then
            configs[m_name] = json.parse(fs.readfile(p)) or {}
        else
            configs[m_name] = {}
        end
    end

    -- Tentukan mode default yang tampil pertama kali (fallback ke ssl_payload)
    local current_inject_mode = "ssl_payload"
    for _, m_name in ipairs(modes) do
        if fs.access(base_dir .. "/" .. m_name .. ".json") then
            current_inject_mode = m_name
            break
        end
    end

    ----------------------------------------------------------
    -- 2. DROPDOWN INJECT MODE
    ----------------------------------------------------------
    local inject_mode = s:option(ListValue, "qssh_inject_mode", "Inject Mode")
    inject_mode:value("direct", "Direct")
    inject_mode:value("direct_payload", "Payload")
    inject_mode:value("ssh_proxy", "Proxy")
    inject_mode:value("ssh_proxy_payload", "Proxy + Payload")
    inject_mode:value("ssl_sni", "SSL / SNI")
    inject_mode:value("ssl_payload", "SSL + Payload (WebSocket)")
    inject_mode.default = current_inject_mode
    inject_mode:depends("mode_selector", "q-ssh")
    inject_mode.write = function() end

    ----------------------------------------------------------
    -- 3. FIELD FORM PER-MODE (SETIAP MODE MEMBACA JSON SENDIRI)
    ----------------------------------------------------------
    for _, m_name in ipairs(modes) do
        local cfg = configs[m_name] or {}
        cfg.ssh = cfg.ssh or {}
        cfg.concurrency = cfg.concurrency or {}
        cfg.proxy = cfg.proxy or {}
        cfg.payload = cfg.payload or {}
        cfg.transport = cfg.transport or {}

        local dep = { mode_selector = "q-ssh", qssh_inject_mode = m_name }

        -- Akun SSH & Workers
        local host = s:option(Value, "qssh_host_" .. m_name, "SSH Host / IP")
        host.default = cfg.ssh.host or ""
        host:depends(dep)
        host.write = function() end

        local port = s:option(Value, "qssh_port_" .. m_name, "SSH Port")
        port.datatype = "port"
        port.default = cfg.ssh.port or "22"
        port:depends(dep)
        port.write = function() end

        local user = s:option(Value, "qssh_user_" .. m_name, "SSH Username")
        user.default = cfg.ssh.username or ""
        user:depends(dep)
        user.write = function() end

        local pass = s:option(Value, "qssh_pass_" .. m_name, "SSH Password")
        pass.password = true
        pass.default = cfg.ssh.password or ""
        pass:depends(dep)
        pass.write = function() end

        local workers = s:option(Value, "workers_" .. m_name, "Workers")
        workers.datatype = "uinteger"
        workers.default = cfg.concurrency.workers or "2"
        workers:depends(dep)
        workers.write = function() end

        -- Field Proxy (Mode: ssh_proxy, ssh_proxy_payload, ssl_sni, ssl_payload)
        if m_name == "ssh_proxy" or m_name == "ssh_proxy_payload" or m_name == "ssl_sni" or m_name == "ssl_payload" then
            local p_label = "Proxy Host"
            local default_p_port = "80"

            -- Jika mode berbasis SSL/SNI, atur default port ke 443
            if m_name == "ssl_sni" or m_name == "ssl_payload" then
                p_label = "Proxy Host (Opsional)"
                default_p_port = "443"
            end

            local proxy_host = s:option(Value, "proxy_host_" .. m_name, p_label)
            proxy_host.default = cfg.proxy.host or ""
            proxy_host:depends(dep)
            proxy_host.write = function() end

            local proxy_port = s:option(Value, "proxy_port_" .. m_name, "Proxy Port")
            proxy_port.datatype = "port"
            proxy_port.default = cfg.proxy.port or default_p_port
            proxy_port:depends(dep)
            proxy_port.write = function() end
        end

        -- Field SNI (Mode: ssl_sni, ssl_payload)
        if m_name == "ssl_sni" or m_name == "ssl_payload" then
            local sni = s:option(Value, "sni_bug_" .. m_name, "SNI / Bug Host")
            sni.default = cfg.transport.sni or ""
            sni:depends(dep)
            sni.write = function() end
        end

        -- Field Payload & Expect (Mode: direct_payload, ssh_proxy_payload, ssl_payload)
        if m_name == "direct_payload" or m_name == "ssh_proxy_payload" or m_name == "ssl_payload" then
            local payload = s:option(Value, "payload_" .. m_name, "Payload Request")
            payload.template = "cbi/tvalue"
            payload.rows = 6
            payload.default = cfg.payload.request or ""
            payload:depends(dep)
            payload.write = function() end

            local expect = s:option(Value, "expect_" .. m_name, "Expect Status")
            expect.default = table.concat(cfg.payload.expect or {"200", "101"}, ",")
            expect:depends(dep)
            expect.write = function() end
        end
    end

    ----------------------------------------------------------
    -- 4. SAVE HOOK (PENYIMPANAN KE FILE JSON MODE MASING-MASING)
    ----------------------------------------------------------
    local old_parse = s.parse

    function s.parse(self, ...)
        local current_mode = mode_selector:formvalue("main")
        
        if current_mode == "q-ssh" then
            local selected_inject = inject_mode:formvalue("main") or "ssl_payload"

            -- Ambil data form spesifik mode yang sedang aktif
            local host_opt = s.fields["qssh_host_" .. selected_inject]
            local port_opt = s.fields["qssh_port_" .. selected_inject]
            local user_opt = s.fields["qssh_user_" .. selected_inject]
            local pass_opt = s.fields["qssh_pass_" .. selected_inject]
            local workers_opt = s.fields["workers_" .. selected_inject]

            local proxy_host_opt = s.fields["proxy_host_" .. selected_inject]
            local proxy_port_opt = s.fields["proxy_port_" .. selected_inject]
            local sni_opt = s.fields["sni_bug_" .. selected_inject]
            local payload_opt = s.fields["payload_" .. selected_inject]
            local expect_opt = s.fields["expect_" .. selected_inject]

            local val_host = host_opt and host_opt:formvalue("main") or ""
            local val_port = port_opt and tonumber(port_opt:formvalue("main")) or 22
            local val_user = user_opt and user_opt:formvalue("main") or ""
            local val_pass = pass_opt and pass_opt:formvalue("main") or ""
            local val_workers = workers_opt and tonumber(workers_opt:formvalue("main")) or 2

            -- Tentukan default fallback port berdasarkan mode
            local fallback_proxy_port = 80
            if selected_inject == "ssl_sni" or selected_inject == "ssl_payload" then
                fallback_proxy_port = 443
            end

            local val_proxy_host = proxy_host_opt and proxy_host_opt:formvalue("main") or ""
            local val_proxy_port = proxy_port_opt and tonumber(proxy_port_opt:formvalue("main")) or fallback_proxy_port
            local val_sni = sni_opt and sni_opt:formvalue("main") or ""
            local val_payload = payload_opt and payload_opt:formvalue("main") or ""
            local val_expect = expect_opt and expect_opt:formvalue("main") or "200,101"

            -- Flag Boolean
            local is_tls = (selected_inject == "ssl_sni" or selected_inject == "ssl_payload")
            local is_payload = (selected_inject == "direct_payload" or selected_inject == "ssh_proxy_payload" or selected_inject == "ssl_payload")

            local is_proxy = false
            if selected_inject == "ssh_proxy" or selected_inject == "ssh_proxy_payload" then
                is_proxy = true
            elseif (selected_inject == "ssl_sni" or selected_inject == "ssl_payload") and val_proxy_host ~= "" then
                is_proxy = true
            end

            -- Format Expect Array
            local expect_tbl = {}
            for v in val_expect:gmatch("[^,%s]+") do
                expect_tbl[#expect_tbl+1] = '"' .. v .. '"'
            end
            local expect_json = "[" .. table.concat(expect_tbl, ", ") .. "]"

            local json_data = string.format([[
{
  "inject_mode": %q,
  "listen": {
    "host": "127.0.0.1",
    "port": 1080
  },
  "concurrency": {
    "enable": true,
    "workers": %d,
    "start_port": 1080
  },
  "ssh": {
    "host": %q,
    "port": %d,
    "username": %q,
    "password": %q
  },
  "network": {
    "type": "tcp"
  },
  "transport": {
    "tls": %s,
    "host": "",
    "path": "/",
    "sni": %q
  },
  "proxy": {
    "enable": %s,
    "host": %q,
    "port": %d
  },
  "payload": {
    "enable": %s,
    "request": %s,
    "expect": %s
  }
}
]],
                selected_inject,
                val_workers,
                val_host,
                val_port,
                val_user,
                val_pass,
                is_tls and "true" or "false",
                val_sni,
                is_proxy and "true" or "false",
                val_proxy_host,
                val_proxy_port,
                is_payload and "true" or "false",
                string.format("%q", val_payload),
                expect_json
            )

            json_data = json_data:gsub("\\/", "/")

            fs.mkdirr(base_dir)

            -- Simpan murni ke file JSON mode yang sedang aktif
            local target_mode_json = base_dir .. "/" .. selected_inject .. ".json"
            fs.writefile(target_mode_json, json_data)
        end

        old_parse(self, ...)
    end

end