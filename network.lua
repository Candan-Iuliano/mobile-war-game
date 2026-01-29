-- Simple networking module using LuaSocket with a graceful fallback
local M = {}

local ok, socket = pcall(require, "socket")
M.enabled = ok and socket ~= nil
M.server = nil
M.client = nil
M.connected = false
M.inbox = {}
M._suppressOutgoing = false
M.acceptedClient = nil
M.serverPort = nil

local function serialize(tbl)
    local parts = {}
    for k, v in pairs(tbl) do
        local val = tostring(v)
        table.insert(parts, tostring(k) .. "=" .. val)
    end
    return table.concat(parts, ";")
end

local function deserialize(s)
    local t = {}
    for pair in string.gmatch(s, "([^;]+)") do
        local k, v = string.match(pair, "([^=]+)=?(.*)")
        if k then
            if v == "true" then v = true
            elseif v == "false" then v = false
            else
                local n = tonumber(v)
                if n then v = n end
            end
            t[k] = v
        end
    end
    return t
end

function M.startServer(port)
    if not M.enabled then
        print("[network] LuaSocket not available; cannot start server")
        return false
    end
    port = port or 22122
    local srv, err = socket.bind("*", port)
    if not srv then
        print("[network] server bind failed: ", err)
        return false
    end
    srv:settimeout(0)
    M.server = srv
    M.client = nil
    M.connected = false
    M.serverPort = port
    print("[network] Server listening on port " .. port)
    return true
end

function M.connect(host, port)
    if not M.enabled then
        print("[network] LuaSocket not available; cannot connect")
        return false
    end
    -- allow "host:port" in the host string
    if host and tostring(host):find(":") then
        local h, p = string.match(tostring(host), "([^:]+):?(%d*)")
        if h and h ~= "" then host = h end
        if p and tonumber(p) then port = tonumber(p) end
    end
    host = host or "127.0.0.1"
    port = port or 22122
    local c, err = socket.tcp()
    if not c then
        print("[network] socket.tcp failed: ", err)
        return false
    end
    -- Try a short blocking connect to reliably establish the TCP handshake
    c:settimeout(2)
    local ok, serr = c:connect(host, port)
    if not ok then
        -- report detailed error
        print("[network] connect error: ", serr)
        pcall(function() c:close() end)
        return false
    end
    -- Set to non-blocking for async polling
    c:settimeout(0)
    M.client = c
    M.connected = true
    print("[network] Connected to " .. host .. ":" .. tostring(port))
    return true
end

-- Return a best-effort local IP address for display (does not send packets)
function M.getLocalAddress()
    if not M.enabled then return "127.0.0.1" end
    local udp = socket.udp()
    if not udp then return "127.0.0.1" end
    -- Connect to a public DNS server (no data sent) to get outbound interface
    local ok, err = pcall(function() udp:setpeername("8.8.8.8", 80) end)
    if not ok then
        pcall(function() udp:close() end)
        return "127.0.0.1"
    end
    local ip, _ = udp:getsockname()
    pcall(function() udp:close() end)
    if ip and ip ~= "" then return ip end
    return "127.0.0.1"
end

function M.disconnect()
    -- Fully tear down client and server
    if M.client then pcall(function() M.client:close() end) end
    if M.server and M.acceptedClient then pcall(function() M.acceptedClient:close() end) end
    if M.server then pcall(function() M.server:close() end) end
    M.client = nil
    M.server = nil
    M.connected = false
    M.inbox = {}
    print("[network] Disconnected")
end

function M.closeAcceptedClient()
    if M.acceptedClient then
        pcall(function() M.acceptedClient:close() end)
        M.acceptedClient = nil
        M.connected = false
        print("[network] Accepted client disconnected; server still listening")
    end
end

function M.send(tbl)
    if not M.connected then return false end
    if M._suppressOutgoing then return false end
    local s = serialize(tbl) .. "\n"
    -- diagnostic
    pcall(function() print("[network] send -> ", s) end)
    local target = M.client
    if not target and M.acceptedClient then
        target = M.acceptedClient
    end
    pcall(function()
        local a,b = nil,nil
        pcall(function() if target then a,b = target:getpeername() end end)
        print("[network] send target peer=", tostring(a), tostring(b))
    end)
    if not target then return false end
    local ok, err = target:send(s)
    if not ok then
        print("[network] send failed: ", err)
        return false
    end
    return true
end

function M.poll()
    if not M.enabled then return {} end
    if M.server and not M.acceptedClient then
        local c = M.server:accept()
        if c then
            c:settimeout(0)
            M.acceptedClient = c
            M.connected = true
            local peer_ip, peer_port = nil, nil
            pcall(function() peer_ip, peer_port = c:getpeername() end)
            print("[network] Accepted client connection from", tostring(peer_ip), tostring(peer_port))
        end
    end

    local source = M.client or M.acceptedClient
    if not source then
        local out = M.inbox
        M.inbox = {}
        return out
    end

    while true do
        local line, err = source:receive("*l")
        if not line then
            if err == "timeout" then break end
            if err == "closed" then
                -- If the closed socket was the server's accepted client, clear it but keep server listening
                if source == M.acceptedClient then
                    M.closeAcceptedClient()
                    break
                else
                    -- client socket closed; fully disconnect
                    M.disconnect()
                    break
                end
            end
            break
        end
        pcall(function() print("[network] recv raw -> ", line) end)
        local msg = deserialize(line)
        pcall(function() print("[network] recv parsed -> ", msg.type or "(no type)") end)
        table.insert(M.inbox, msg)
    end
    local out = M.inbox
    M.inbox = {}
    return out
end

function M.isConnected()
    return M.connected
end

function M.hasAcceptedClient()
    return M.acceptedClient ~= nil
end

return M