-- Love2D Hex War Game - Main Entry Point
-- A chess-like strategy game on a hex grid

function love.load()
    -- Show console window on Windows
    if love.system.getOS() == "Windows" then
        io.stdout:setvbuf("no")
    end
    
    print("=== Hex War Game Started ===")
    print("Loading modules...")
    
    -- Set window properties
    love.window.setMode(1200, 800)
    love.window.setTitle("Hex War Game")
    
    -- Load required modules
    print("Loading map_generator...")
    HexMap = require("map_generator")
    print("Loading game...")
    Game = require("game")
    
    -- Initialize app state (show start menu)
    appState = "menu" -- menu | playing
    menuButtons = {}
    local w = love.graphics.getWidth()
    local h = love.graphics.getHeight()
    local bw, bh = 220, 48
    local cx = math.floor((w - bw) / 2)
    local startY = math.floor(h / 2 - bh * 2)
    -- persist layout so other handlers can reference sizes/positions
    menuLayout = {bw = bw, bh = bh, cx = cx, startY = startY}
    menuButtons[1] = {label = "Host Game", x = menuLayout.cx, y = menuLayout.startY, w = menuLayout.bw, h = menuLayout.bh, id = "host"}
    menuButtons[2] = {label = "Join Game", x = menuLayout.cx, y = menuLayout.startY + menuLayout.bh + 12, w = menuLayout.bw, h = menuLayout.bh, id = "join"}
    menuButtons[3] = {label = "Dev Mode (single player)", x = menuLayout.cx, y = menuLayout.startY + (menuLayout.bh + 12) * 2, w = menuLayout.bw, h = menuLayout.bh, id = "dev"}
    gameInstance = nil
    print("Main menu ready")
end

-- Lobby state for host flow
lobbyState = nil
joinState = nil

local function processNetworkMessages(msgs)
    if not msgs or #msgs == 0 then return end
    for _, msg in ipairs(msgs) do
        if not msg.type then goto continue end
        pcall(function() print("[main] network message ->", msg.type, msg.name or msg.hostName) end)
        if appState == "lobby" and lobbyState then
            -- If we are host and receive a join, populate guest slot
            if msg.type == "join" then
                lobbyState.guestName = msg.name or "Guest"
                -- mark connected if socket accepted
                if Network and Network.hasAcceptedClient and Network.hasAcceptedClient() then
                    lobbyState.guestConnected = true
                end
                -- reply with acknowledgment including host name
                if Network and Network.isConnected and Network.isConnected() then
                    Network.send({type = "joinAck", hostName = lobbyState.hostName or "Host"})
                end
            elseif msg.type == "joinAck" then
                -- client receives ack with host name
                lobbyState.hostName = msg.hostName or lobbyState.hostName
            elseif msg.type == "start" then
                -- Host told us to start the game (client/guest path)
                if not gameInstance then
                    gameInstance = Game.new()
                    
                    gameInstance.hotseatEnabled = true
                    gameInstance.devMode = false
                    gameInstance.hostName = msg.hostName or (lobbyState and lobbyState.hostName) or "Host"
                    gameInstance.guestName = msg.guestName or (lobbyState and lobbyState.guestName) or "Guest"
                    -- Guest controls the opposite team by default
                    gameInstance.localTeam = msg.hostTeam and (3 - msg.hostTeam) or 2
                    gameInstance.isHost = false
                    gameInstance.turnCount = 1
                    gameInstance.currentTurn = 1
                    for _, p in ipairs(gameInstance.pieces) do p:resetMove() end
                    appState = "playing"
                end
            end
            -- if the accepted-client flag flips, update guestConnected
            if Network and Network.hasAcceptedClient then
                lobbyState.guestConnected = Network.hasAcceptedClient()
            end
        else
            -- If client is in joinState or menu, handle ack to populate lobby
            if msg.type == "joinAck" and joinState then
                -- move to lobby view as guest
                lobbyState = {
                    hostName = msg.hostName or "Host",
                    guestName = joinState.guestName or "Guest",
                    focus = nil,
                    buttons = {
                        start = {label = "Start Game", x = menuLayout.cx, y = menuLayout.startY + (menuLayout.bh + 12) * 3 + 10, w = menuLayout.bw/2 - 8, h = menuLayout.bh, id = "start"},
                        close = {label = "Close Lobby", x = menuLayout.cx + menuLayout.bw/2 + 8, y = menuLayout.startY + (menuLayout.bh + 12) * 3 + 10, w = menuLayout.bw/2 - 8, h = menuLayout.bh, id = "close"},
                    },
                    x = menuLayout.cx,
                    y = menuLayout.startY,
                    w = menuLayout.bw,
                    h = menuLayout.bh
                }
                appState = "lobby"
                joinState = nil
            end
        end
        -- Forward network messages to the active game instance if present
        if gameInstance and gameInstance.handleNetworkMessage then
            pcall(function() gameInstance:handleNetworkMessage(msg) end)
        end
        ::continue::
    end
end

function love.update(dt)
    if appState == "playing" and gameInstance then
        gameInstance:update(dt)
    end
    -- Poll network messages periodically when server/client may be active
    if Network and Network.poll then
        local msgs = Network.poll()
        processNetworkMessages(msgs)
    end
end

function love.draw()
    if appState == "menu" then
        -- Draw simple menu
        love.graphics.clear(0.08, 0.08, 0.12)
        love.graphics.setColor(1, 1, 1)
        love.graphics.setFont(love.graphics.newFont(28))
        local title = "Hex War - Start"
        local tw = love.graphics.getFont():getWidth(title)
        love.graphics.print(title, (love.graphics.getWidth() - tw) / 2, 80)
        love.graphics.setFont(love.graphics.newFont(14))
        for _, b in ipairs(menuButtons) do
            love.graphics.setColor(0.2, 0.2, 0.25)
            love.graphics.rectangle("fill", b.x, b.y, b.w, b.h, 6, 6)
            love.graphics.setColor(1, 1, 1)
            local lw = love.graphics.getFont():getWidth(b.label)
            love.graphics.print(b.label, b.x + (b.w - lw) / 2, b.y + (b.h - 16) / 2)
        end
        -- If join dialog active, render it on top
        if joinState then
            local jx = menuLayout.cx
            local jy = menuLayout.startY + (menuLayout.bh + 12) * 3 + 24
            love.graphics.setColor(0.95, 0.95, 0.95)
            love.graphics.rectangle("fill", jx, jy, menuLayout.bw, menuLayout.bh * 2 + 12)
            -- IP input
            love.graphics.setColor(0,0,0)
            love.graphics.print("Host IP:", jx + 8, jy + 6)
            love.graphics.setColor(1,1,1)
            local ipBoxX = jx + 80
            local ipBoxY = jy
            local ipBoxW = menuLayout.bw - 88
            local ipBoxH = menuLayout.bh
            love.graphics.setColor(0.95, 0.95, 0.95)
            love.graphics.rectangle("fill", ipBoxX, ipBoxY, ipBoxW, ipBoxH)
            if joinState.focus == "ip" then
                love.graphics.setColor(1, 0.9, 0.2)
                love.graphics.rectangle("line", ipBoxX, ipBoxY, ipBoxW, ipBoxH)
            end
            love.graphics.setColor(0,0,0)
            love.graphics.print(joinState.ip or "", ipBoxX + 4, ipBoxY + 6)
            -- Name input
            love.graphics.setColor(1,1,1)
            love.graphics.print("Your name:", jx + 8, jy + 6 + menuLayout.bh + 6)
            local nameBoxX = jx + 80
            local nameBoxY = jy + menuLayout.bh + 6
            local nameBoxW = menuLayout.bw - 88
            local nameBoxH = menuLayout.bh
            love.graphics.setColor(0.95, 0.95, 0.95)
            love.graphics.rectangle("fill", nameBoxX, nameBoxY, nameBoxW, nameBoxH)
            if joinState.focus == "name" then
                love.graphics.setColor(1, 0.9, 0.2)
                love.graphics.rectangle("line", nameBoxX, nameBoxY, nameBoxW, nameBoxH)
            end
            love.graphics.setColor(0,0,0)
            love.graphics.print(joinState.guestName or "Guest", nameBoxX + 4, nameBoxY + 6)
            -- buttons
            love.graphics.setColor(0.2,0.2,0.25)
            love.graphics.rectangle("fill", jx, jy + (menuLayout.bh + 12) * 2, menuLayout.bw/2 - 8, menuLayout.bh, 6,6)
            love.graphics.rectangle("fill", jx + menuLayout.bw/2 + 8, jy + (menuLayout.bh + 12) * 2, menuLayout.bw/2 - 8, menuLayout.bh,6,6)
            love.graphics.setColor(1,1,1)
            love.graphics.print("Connect", jx + 12, jy + (menuLayout.bh + 12) * 2 + 8)
            love.graphics.print("Cancel", jx + menuLayout.bw/2 + 20, jy + (menuLayout.bh + 12) * 2 + 8)
        end
    elseif appState == "lobby" and lobbyState then
        -- Draw lobby UI
        love.graphics.clear(0.06, 0.06, 0.08)
        love.graphics.setColor(1,1,1)
        love.graphics.setFont(love.graphics.newFont(22))
        love.graphics.print("Lobby - Host", lobbyState.x, lobbyState.y - 60)
        love.graphics.setFont(love.graphics.newFont(14))

        -- Host name field
        local hx = lobbyState.x
        local hy = lobbyState.y
        love.graphics.print("Host:", hx, hy)
        love.graphics.setColor(0.95, 0.95, 0.95)
        love.graphics.rectangle("fill", hx + 60, hy, lobbyState.w - 60, lobbyState.h)
        love.graphics.setColor(0,0,0)
        love.graphics.print(lobbyState.hostName, hx + 66, hy + 6)
        -- Show host IP and port for remote players (right-aligned to avoid overlap)
        love.graphics.setColor(1,1,1)
        love.graphics.setFont(love.graphics.newFont(11))
        local hip = lobbyState.hostIP or "127.0.0.1"
        local hport = lobbyState.hostPort or 22122
        love.graphics.print("Host IP: " .. hip .. ":" .. tostring(hport), hx + math.max(0, lobbyState.w - 180), hy + 120)
        love.graphics.setFont(love.graphics.newFont(14))

        -- Guest name field
        local gy = hy + lobbyState.h + 12
        love.graphics.setColor(1,1,1)
        love.graphics.print("Guest:", hx, gy)
        love.graphics.setColor(0.95, 0.95, 0.95)
        love.graphics.rectangle("fill", hx + 60, gy, lobbyState.w - 60, lobbyState.h)
        love.graphics.setColor(0,0,0)
        local guestText = lobbyState.guestName ~= "" and lobbyState.guestName or "(waiting)"
        love.graphics.print(guestText, hx + 66, gy + 6)

        -- Buttons (Start disabled until guestConnected)
        for _, b in pairs(lobbyState.buttons) do
            if b.id == "start" and not lobbyState.guestConnected then
                love.graphics.setColor(0.35, 0.35, 0.35)
            else
                love.graphics.setColor(0.2, 0.2, 0.25)
            end
            love.graphics.rectangle("fill", b.x, b.y, b.w, b.h, 6, 6)
            if b.id == "start" and not lobbyState.guestConnected then
                love.graphics.setColor(0.7, 0.7, 0.7)
            else
                love.graphics.setColor(1,1,1)
            end
            local lw = love.graphics.getFont():getWidth(b.label)
            love.graphics.print(b.label, b.x + (b.w - lw)/2, b.y + (b.h - 16)/2)
        end

        -- Focus hint
        love.graphics.setColor(1,1,1)
        love.graphics.setFont(love.graphics.newFont(11))
        love.graphics.print("Click a field to edit. Host can start when guest connected.", hx, lobbyState.y + (lobbyState.h + 12) * 2 + 60)

    elseif appState == "playing" and gameInstance then
        gameInstance:draw()
    end
end

function love.mousepressed(x, y, button)
    if appState == "menu" then
        for _, b in ipairs(menuButtons) do
            if x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then
                if b.id == "dev" then
                    -- Start dev mode: single player, no hotseat/network
                    print("Starting Dev Mode")
                    gameInstance = Game.new()
                    gameInstance.devMode = true
                    --gameInstance.disableFog = true
                    gameInstance.hotseatEnabled = false
                    -- In dev mode, default control to team 1 but allow switching in-game
                    gameInstance.localTeam = 1
                    gameInstance.passPending = false
                    gameInstance.pendingNextTeam = nil
                    -- Keep default placement phase so you can place troops in Dev Mode
                    -- (Game.new initializes state = "placing")
                    appState = "playing"
                elseif b.id == "host" then
                    print("Host selected — opening lobby")
                    Network = require("network")
                    Network.startServer()
                    -- Create lobby UI state
                    lobbyState = {
                        hostName = "Host",
                        guestName = "",
                        focus = "host", -- "host" or "guest" or nil
                        guestConnected = false,
                        hostIP = Network.getLocalAddress and Network.getLocalAddress() or "127.0.0.1",
                        hostPort = Network.serverPort or 22122,
                        buttons = {
                            start = {label = "Start Game", x = menuLayout.cx, y = menuLayout.startY + (menuLayout.bh + 12) * 3 + 10, w = menuLayout.bw/2 - 8, h = menuLayout.bh, id = "start"},
                            close = {label = "Close Lobby", x = menuLayout.cx + menuLayout.bw/2 + 8, y = menuLayout.startY + (menuLayout.bh + 12) * 3 + 10, w = menuLayout.bw/2 - 8, h = menuLayout.bh, id = "close"},
                        },
                        x = menuLayout.cx,
                        y = menuLayout.startY,
                        w = menuLayout.bw,
                        h = menuLayout.bh
                    }
                    appState = "lobby"
                elseif b.id == "join" then
                    -- Open join dialog (accept ip or ip:port)
                    joinState = { ip = "127.0.0.1:22122", guestName = "Guest", focus = "ip" }
                    return
                end
                break
            end
        end
    end
    -- Join dialog input handling
    if appState == "menu" and joinState then
        local jx = menuLayout.cx
        local jy = menuLayout.startY + (menuLayout.bh + 12) * 3 + 24
        local fw = menuLayout.bw
        local btnY = jy + (menuLayout.bh + 12) * 2
        -- Connect button bounds
        local connectX1, connectX2 = jx, jx + fw/2 - 8
        local cancelX1, cancelX2 = jx + fw/2 + 8, jx + fw
        if x >= connectX1 and x <= connectX2 and y >= btnY and y <= btnY + menuLayout.bh then
            Network = require("network")
            if Network.connect(joinState.ip) then
                Network.send({type = "join", name = joinState.guestName})
                lobbyState = {
                    hostName = "(connecting)",
                    guestName = joinState.guestName,
                    focus = nil,
                    buttons = {
                        start = {label = "Start Game", x = menuLayout.cx, y = menuLayout.startY + (menuLayout.bh + 12) * 3 + 10, w = menuLayout.bw/2 - 8, h = menuLayout.bh, id = "start"},
                        close = {label = "Close Lobby", x = menuLayout.cx + menuLayout.bw/2 + 8, y = menuLayout.startY + (menuLayout.bh + 12) * 3 + 10, w = menuLayout.bw/2 - 8, h = menuLayout.bh, id = "close"},
                    },
                    x = menuLayout.cx,
                    y = menuLayout.startY,
                    w = menuLayout.bw,
                    h = menuLayout.bh
                }
                appState = "lobby"
                joinState = nil
            end
            return
        end
        -- Cancel button
        if x >= cancelX1 and x <= cancelX2 and y >= btnY and y <= btnY + menuLayout.bh then
            joinState = nil
            return
        end
        -- Click into ip or name fields
        if x >= jx + 80 and x <= jx + fw and y >= jy and y <= jy + menuLayout.bh then
            joinState.focus = "ip"
            return
        end
        if x >= jx + 80 and x <= jx + fw and y >= jy + menuLayout.bh + 6 and y <= jy + (menuLayout.bh + 6) * 2 then
            joinState.focus = "name"
            return
        end
    end
    if appState == "lobby" and lobbyState then
        -- Check clicks on host/guest fields
        local hx = lobbyState.x
        local hy = lobbyState.y
        local fw = lobbyState.w - 60
        if x >= hx + 60 and x <= hx + 60 + fw and y >= hy and y <= hy + lobbyState.h then
            lobbyState.focus = "host"
            return
        end
        local gy = hy + lobbyState.h + 12
        if x >= hx + 60 and x <= hx + 60 + fw and y >= gy and y <= gy + lobbyState.h then
            lobbyState.focus = "guest"
            return
        end
        -- Buttons
        for id, b in pairs(lobbyState.buttons) do
            if x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then
                if b.id == "start" then
                    if not lobbyState.guestConnected then
                        -- ignore start if no guest connected
                        print("Host: cannot start, no guest connected")
                        return
                    end
                    -- Start the game: create Game instance and begin playing
                    gameInstance = Game.new()
                    gameInstance.hotseatEnabled = true
                    gameInstance.devMode = false
                    gameInstance.hostName = lobbyState.hostName
                    gameInstance.guestName = lobbyState.guestName
                    gameInstance.localTeam = 1
                    gameInstance.isHost = true
                    -- keep the placement phase (Game.new defaults to "placing") so host can place troops
                    gameInstance.turnCount = 1
                    gameInstance.currentTurn = 1
                    for _, p in ipairs(gameInstance.pieces) do p:resetMove() end
                    appState = "playing"
                    -- notify connected guest to start the game and enter placement
                    if Network and Network.send and Network.isConnected and Network.isConnected() then
                        Network.send({type = "start", hostName = lobbyState.hostName or "Host", guestName = lobbyState.guestName or "Guest", hostTeam = 1})
                    end
                elseif b.id == "close" then
                    -- Close lobby and disconnect server
                    Network = require("network")
                    Network.disconnect()
                    lobbyState = nil
                    appState = "menu"
                end
                return
            end
        end
        return
    end
    if appState == "playing" and gameInstance then
        gameInstance:mousepressed(x, y, button)
    end
end

function love.keypressed(key)
    if appState == "lobby" and lobbyState then
        if key == "backspace" then
            local f = lobbyState.focus
            if f and lobbyState[f] then
                lobbyState[f] = lobbyState[f]:sub(1, -2)
            end
        elseif key == "return" then
            if lobbyState.focus == "host" then lobbyState.focus = "guest" else lobbyState.focus = nil end
        end
        return
    end

    if appState == "menu" and joinState then
        if key == "backspace" then
            local f = joinState.focus
            if f == "ip" then joinState.ip = (joinState.ip or ""):sub(1, -2)
            elseif f == "name" then joinState.guestName = (joinState.guestName or ""):sub(1, -2) end
        elseif key == "return" then
            -- attempt connect when pressing enter in join dialog
            if joinState and joinState.ip then
                Network = require("network")
                if Network.connect(joinState.ip) then
                    Network.send({type = "join", name = joinState.guestName})
                    lobbyState = {
                        hostName = "(connecting)",
                        guestName = joinState.guestName,
                        focus = nil,
                        buttons = {
                            start = {label = "Start Game", x = menuLayout.cx, y = menuLayout.startY + (menuLayout.bh + 12) * 3 + 10, w = menuLayout.bw/2 - 8, h = menuLayout.bh, id = "start"},
                            close = {label = "Close Lobby", x = menuLayout.cx + menuLayout.bw/2 + 8, y = menuLayout.startY + (menuLayout.bh + 12) * 3 + 10, w = menuLayout.bw/2 - 8, h = menuLayout.bh, id = "close"},
                        },
                        x = menuLayout.cx,
                        y = menuLayout.startY,
                        w = menuLayout.bw,
                        h = menuLayout.bh
                    }
                    appState = "lobby"
                    joinState = nil
                end
            end
        end
        return
    end

    if appState == "playing" and gameInstance then
        gameInstance:keypressed(key)
    end
end

function love.textinput(t)
    if appState == "lobby" and lobbyState and lobbyState.focus then
        local f = lobbyState.focus
        lobbyState[f] = (lobbyState[f] or "") .. t
    end
    if appState == "menu" and joinState and joinState.focus then
        if joinState.focus == "ip" then
            joinState.ip = (joinState.ip or "") .. t
        elseif joinState.focus == "name" then
            joinState.guestName = (joinState.guestName or "") .. t
        end
    end
end

function love.mousemoved(x, y, dx, dy)
    if appState == "playing" and gameInstance then
        gameInstance:mousemoved(x, y, dx, dy)
    end
end

function love.wheelmoved(x, y)
    if appState == "playing" and gameInstance then
        gameInstance:wheelmoved(x, y)
    end
end
