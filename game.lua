
-- ...existing code...
-- Apply a single replay action (move, attack, recruit)



local Replay = require("replay")
local Game = {}
Game.__index = Game


local Camera = require("camera")
local Piece = require("piece")
local Base = require("base")
local Resource = require("resource")
local ActionMenu = require("action_menu")
local FogOfWar = require("fog_of_war")
local Network = require("network")
local NewMenu = require("new_menu")

function Game.new()
    local self = setmetatable({}, Game)
    
    -- Game state
    self.state = "zone_draft"  -- "zone_draft", "placing", "playing", "gameOver"
    self.currentTurn = 1    -- Team 1 or 2
    self.turnCount = 0
    
    -- Zone draft phase
    self.zoneDraftTeam = 1  -- Which team is currently drafting (1 or 2)
    self.teamZoneSelected = {}  -- tracks which team has selected a zone: {[1] = true/false, [2] = true/false}
    self.teamInPlacement = {}  -- tracks which teams are in placement: {[1] = true/false, [2] = true/false}
    
    -- Placement phase
    self.piecesPerTeam = 4  -- Number of pieces per team (3 infantry + 1 engineer)
    self.piecesToPlace = self.piecesPerTeam * 2  -- Total pieces (4 for each team)
    self.piecesPlaced = 0
    self.basesPerTeam = 4  -- HQ, Ammo Depot, Supply Depot, Airbase
    self.basesToPlace = self.basesPerTeam * 2  -- Total bases (3 for each team)
    self.basesPlaced = 0
    self.placementTeam = 1  -- Which team is currently placing (starts with team 1)
    self.placementPhase = "pieces"  -- "pieces" or "bases"
    
    -- Map setup
    self.hexSideLength = 32
    self.mapWidth = 32
    self.mapHeight = 28
    
    self.map = HexMap.new(self.mapWidth, self.mapHeight, self.hexSideLength)
    self.map:initializeGrid(true)  -- true = circular grid mode
    self.mapGeneratorUsed = nil  -- Track which generator was used ("radial", "region_stitch", etc.)

    -- Replay system: encapsulated in Replay module
    self.replay = Replay.new()
    self:generateMapTerrain()

    -- Start-sector selection (radial sectors) for dynamic starts (only for radial maps)
    self.startSectors = nil         -- populated by generateStartSectors
    self.tileToSector = nil         -- mapping col,row -> sector index
    self.selectedStartSector = {}   -- selections per team id
    self.freePlacement = false      -- Set to true with F1 during placement dev mode
    self.revealedCandidates = {}    -- revealed candidate lists per team during draft
    -- Generate default sectors only for radial maps (circular playable area with perimeter zones)
    if self.mapGeneratorUsed == "radial" then
        pcall(function() self:generateStartSectors(8) end)
        -- Prepare initial reveals for both teams (reveal 3 candidates each)
        self:prepareRevealForTeam(1, 3)
        self:prepareRevealForTeam(2, 3)  -- team 2 gets their own set of 3 zones
    end
    
    -- Starting areas for teams (top and bottom rows, 5 rows deep)
    self.startingAreaDepth = 5
    self.teamStartingAreas = {
        [1] = {rowStart = 1, rowEnd = 5},   -- Team 1: top 5 rows
        [2] = {rowStart = self.mapHeight - 4, rowEnd = self.mapHeight}  -- Team 2: bottom 5 rows
    }
    
    -- Camera
    self.camera = Camera.new(self.mapWidth * 20, self.mapHeight * 20, 1)
    
    -- Pieces (units)
    self.pieces = {}
    self:initializePieces()
    -- Mines placed on the map
    self.mines = {}
    -- Defenses (tile improvements built by engineers)
    -- defenses[col][row] = { team = team_id }
    self.defenses = {}
    
    -- Bases (structures)
    self.bases = {}
    self:initializeBases()
    -- UI: actions button state for selected context (shows bottom Actions button)
    self.actionsButtonVisible = false
    self.actionsButtonContext = nil
    self.actionsButtonContextType = nil
    
    -- Resources
    self.resources = {}
    self:generateResources()
    
    -- Resource currency (for building units/bases)
    self.teamResources = {[1] = 100, [2] = 100}  -- Resources owned by each team
    -- Oil resource (separate currency used for late-game units)
    self.teamOil = {[1] = 100, [2] = 100}

    -- Province/Region control data (disabled for now)
    self.provinces = nil
    self.regions = nil
    self.numProvinceCols = 2
    self.numProvinceRows = 2
    
    -- Fog of War system
    self.fogOfWar = FogOfWar.new(self.map, 2, self)
    -- Combat animations (dice roll displays)
    self.combatAnimations = {} -- { {x,y,rollsA,rollsD,ttl} }
    
    -- Initialize fog visibility based on current state
    self:updateFogVisibility()
    
    -- Input handling
    if self.selectedPiece then
        self.selectedPiece:deselect(self)
    end
    self.isDragging = false
    self.dragStartX = 0
    self.dragStartY = 0
    
    -- Waypoint mode for multi-step moves
    self.waypointMode = false  -- Are we setting waypoints?
    self.waypointModePiece = nil  -- The piece we're setting waypoints for
    self.tempWaypoints = {}  -- Temporary waypoints being set
    
    -- Action menu UI (reusable for bases, pieces, resources, etc.)
    self.actionMenu = nil  -- ActionMenu instance
    self.actionMenuContext = nil  -- Context object (base, piece, etc.) that opened the menu
    -- Hotseat pass control
    self.passPending = false
    self.pendingNextTeam = nil
    -- Hotseat/network/dev flags
    self.hotseatEnabled = true
    self.devMode = false
    -- Dev placement menu removed (dev menu cleaned up)
    -- Dev placement menu state (uses reusable `new_menu`)
    self.devPlacementMenuOpen = false
    self.devPlacementSelected = nil -- { kind = "unit"|"base", name = "infantry" }
    -- Per-player ready flags for simultaneous placement
    self.playerReady = {[1] = false, [2] = false}

    --local centerCol, centerRow, cx, cy, _ = self:computeMapCenterAndRadius()
    
    return self
end


-- Dice roll helpers and combat resolution
function Game:rollDice(n, maxFace)
    local rolls = {}
    n = n or 1
    maxFace = maxFace or 6
    if n <= 0 then return rolls end
    for i = 1, n do rolls[i] = math.random(1, maxFace) end
    table.sort(rolls, function(a,b) return a > b end)
    return rolls
end

-- Compare sorted descending dice arrays like Risk; return damageToTarget, damageToAttacker
function Game:computeDiceOutcome(attackerDice, defenderDice)
    local dmgToTarget = 0
    local dmgToAttacker = 0
    local na = #attackerDice
    local nd = #defenderDice
    -- If one side has zero dice (e.g., defender out of range), derive damage as the sum of attacker's rolls
    if na > 0 and nd == 0 then
        for i = 1, na do
            dmgToTarget = dmgToTarget + attackerDice[i]
        end
        return dmgToTarget, dmgToAttacker
    end
    if nd > 0 and na == 0 then
        for i = 1, nd do
            dmgToAttacker = dmgToAttacker + defenderDice[i]
        end
        return dmgToTarget, dmgToAttacker
    end

    local pairs = math.min(na, nd)
    for i = 1, pairs do
        local a = attackerDice[i]
        local d = defenderDice[i]
        if a > d then
            dmgToTarget = dmgToTarget + math.abs(a - d)
        elseif d > a then
            dmgToAttacker = dmgToAttacker + math.abs(d - a)
        end
    end
    return dmgToTarget, dmgToAttacker
end

-- Compute morale bonus for a piece: veteran + adjacent commander buffs
function Game:computeMorale(piece)
    if not piece then return 0 end
    local morale = 0
    if piece.veteran then morale = morale + 1 end
    return morale
end


-- Count adjacent commanders belonging to the same team as `piece`
function Game:countAdjacentCommanders(piece)
    if not piece or not piece.col or not piece.row or not piece.team then return 0 end
    local hex = self.map:getTile(piece.col, piece.row)
    if not hex then return 0 end
    local cnt = 0
    local neighbors = self.map:getNeighbors(hex, 1)
    for _, n in ipairs(neighbors) do
        local p = self:getPieceAt(n.col, n.row)
        if p and p.team == piece.team and p.type == "commander" then
            cnt = cnt + 1
        end
    end
    return cnt
end

function Game:spawnCombatAnimation(x, y, rollsA, rollsD, attackerTeam, defenderTeam)
    local anim = {x = x, y = y, rollsA = rollsA or {}, rollsD = rollsD or {}, ttl = 0.9, attackerTeam = attackerTeam, defenderTeam = defenderTeam}
    table.insert(self.combatAnimations, anim)
    return anim
end

function Game:spawnMineExplosion(x, y, damage, col, row)
    local explosion = {x = x, y = y, damage = damage, col = col, row = row, ttl = 0.6, scale = 1.0}
    if not self.explosions then self.explosions = {} end
    table.insert(self.explosions, explosion)
    return explosion
end

function Game:spawnDamageText(x, y, damage, damageType)
    -- Reusable method for displaying fading damage/effect text
    -- damageType: "mine", "airstrike", "attack", etc.
    if not self.damageTexts then self.damageTexts = {} end
    
    local label = damageType == "mine" and "Mine!" or damageType == "airstrike" and "Airstrike!" or "Hit!"
    local text = {
        x = x, 
        y = y, 
        damage = damage, 
        label = label,
        damageType = damageType,
        ttl = 1.2,  -- Fades out over 1.2 seconds
        offsetY = 0  -- Will float upward
    }
    table.insert(self.damageTexts, text)
    return text
end

function Game:updateCombatAnimations(dt)
    for i = #self.combatAnimations, 1, -1 do
        local a = self.combatAnimations[i]
        a.ttl = a.ttl - dt
        if a.ttl <= 0 then table.remove(self.combatAnimations, i) end
    end
    
    -- Update mine explosion animations
    if self.explosions then
        for i = #self.explosions, 1, -1 do
            local e = self.explosions[i]
            e.ttl = e.ttl - dt
            e.scale = e.scale + (dt * 1.5)  -- Grow the explosion
            if e.ttl <= 0 then table.remove(self.explosions, i) end
        end
    end
    
    -- Update damage text animations
    if self.damageTexts then
        for i = #self.damageTexts, 1, -1 do
            local t = self.damageTexts[i]
            t.ttl = t.ttl - dt
            t.offsetY = t.offsetY - (dt * 30)  -- Float upward
            if t.ttl <= 0 then table.remove(self.damageTexts, i) end
        end
    end
end
-- Update piece movement animations and trigger effects/trap checks as they move
function Game:updatePieceAnimations(dt)
    for _, piece in ipairs(self.pieces) do
        
        if piece.isAnimating then
        
            -- Track the tile before update
            local prevCol, prevRow = piece.col, piece.row
            
            -- Update animation
            local isComplete = piece:updateAnimation(dt)
            
            -- Check if piece has entered a new tile and trigger effects
            if piece.col ~= prevCol or piece.row ~= prevRow then
                -- Only trigger mines during live gameplay state (not during replays which have their own action system)
                if self.state == "playing" then
                    print("[MINE] Animation: piece at (" .. piece.col .. "," .. piece.row .. "), checking mines")
                    self:triggerMineAt(piece.col, piece.row, piece)
                end
                
                -- Destroy defense if enemy enters tile
                local defense = self:getDefenseAt(piece.col, piece.row)
                if defense and defense.team ~= piece.team then
                    self:removeDefense(piece.col, piece.row)
                    self:log(piece.type .. " from team " .. piece.team .. " destroyed a defense at (" .. piece.col .. ", " .. piece.row .. ")")
                end
            end
            
            -- Animation finished, recalculate valid moves
            if isComplete then
                piece.isAnimating = false
                piece.animationPath = {}
                -- Recalculate valid moves after animation completes
                self:calculateValidMoves()
            end
        end
    end
end

function Game:drawCombatAnimations()
    for _, a in ipairs(self.combatAnimations) do
        local x, y = a.x, a.y
        -- draw attacker rolls above, defender below; color by team
        love.graphics.setFont(love.graphics.newFont(12))
        -- attacker box (background colored by team) and white text
        local aTeam = a.attackerTeam
        local abr, abg, abb = 0.45, 0.45, 0.45
        if aTeam == 1 then abr, abg, abb = 1, 0.15, 0.15
        elseif aTeam == 2 then abr, abg, abb = 0.15, 0.25, 0.85 end
        love.graphics.setColor(abr, abg, abb, 0.95)
        love.graphics.rectangle("fill", x-28, y-30, 56, 24, 4, 4)
        love.graphics.setColor(1,1,1,1)
        love.graphics.printf(table.concat(a.rollsA, ","), x-28, y-28, 56, "center")

        -- defender box (background colored by team) and white text
        local dTeam = a.defenderTeam
        local dbr, dbg, dbb = 0.45, 0.45, 0.45
        if dTeam == 1 then dbr, dbg, dbb = 1, 0.15, 0.15
        elseif dTeam == 2 then dbr, dbg, dbb = 0.15, 0.25, 0.85 end
        love.graphics.setColor(dbr, dbg, dbb, 0.95)
        love.graphics.rectangle("fill", x-28, y+6, 56, 24, 4, 4)
        love.graphics.setColor(1,1,1,1)
        love.graphics.printf(table.concat(a.rollsD, ","), x-28, y+8, 56, "center")
    end
    love.graphics.setColor(1,1,1,1)
end

function Game:drawExplosions()
    if not self.explosions then return end
    for _, e in ipairs(self.explosions) do
        -- Draw expanding red/orange explosion circle
        local alpha = e.ttl / 0.6  -- Fade out as ttl decreases
        love.graphics.setColor(1, 0.5, 0.1, alpha * 0.7)  -- Orange with decreasing alpha
        love.graphics.circle("fill", e.x, e.y, 20 * e.scale)
        
        -- Draw bright center
        love.graphics.setColor(1, 1, 0, alpha * 0.9)
        love.graphics.circle("fill", e.x, e.y, 8 * e.scale)
    end
    love.graphics.setColor(1,1,1,1)
end

function Game:drawDamageText()
    if not self.damageTexts then return end
    love.graphics.setFont(love.graphics.newFont(14))
    for _, t in ipairs(self.damageTexts) do
        local alpha = t.ttl / 1.2  -- Fade out as ttl decreases
        local y = t.y + t.offsetY
        
        -- Determine color based on damage type
        local r, g, b = 1, 0.3, 0.3  -- Red by default (mine)
        if t.damageType == "airstrike" then
            r, g, b = 0.8, 0.6, 1  -- Purple for airstrikes
        end
        
        -- Draw label (e.g., "Mine!")
        love.graphics.setColor(r, g, b, alpha)
        love.graphics.printf(t.label, t.x - 30, y - 15, 60, "center")
        
        -- Draw damage number below label
        love.graphics.setColor(1, 1, 0, alpha * 0.9)
        love.graphics.printf("-" .. t.damage, t.x - 30, y + 5, 60, "center")
    end
    love.graphics.setColor(1,1,1,1)
end

function Game:generateMapTerrain()
    -- Prefer radial generator for circular maps; fall back gracefully
    local success, _ = pcall(function() self.map:generateTerrain("radial") end)
    if success then
        self.mapGeneratorUsed = "radial"
        return
    end
    print("Radial generator failed or unavailable, trying region_stitch then balanced.")
    local ok2, _ = pcall(function() self.map:generateTerrain("region_stitch") end)
    if ok2 then
        self.mapGeneratorUsed = "region_stitch"
        return
    end
    print("Region-stitch generator failed, falling back to balanced generator.")
    self.map:generateTerrain("balanced")
    self.mapGeneratorUsed = "balanced"
end

function Game:initializePieces()
    -- Create 3 infantry for team 1 to be placed (not positioned yet)
    for i = 1, 3 do
        self:addPiece("infantry", 1, nil, nil)  -- col and row will be set during placement
    end
    -- Create 1 engineer for team 1
    self:addPiece("engineer", 1, nil, nil)
    
    -- Create 3 infantry for team 2 to be placed (not positioned yet)
    for i = 1, 3 do
        self:addPiece("infantry", 2, nil, nil)  -- col and row will be set during placement
    end
    -- Create 1 engineer for team 2
    self:addPiece("engineer", 2, nil, nil)
end

function Game:initializeBases()
    -- Create bases for team 1: HQ, Ammo Depot, Supply Depot
    self:addBase("hq", 1, nil, nil)
    -- self:addBase("ammoDepot", 1, nil, nil)
    -- self:addBase("supplyDepot", 1, nil, nil)
    -- -- Add one airbase per player (unplaced at start)
    -- self:addBase("airbase", 1, nil, nil)
    
    -- Create bases for team 2: HQ, Ammo Depot, Supply Depot
    self:addBase("hq", 2, nil, nil)
    -- self:addBase("ammoDepot", 2, nil, nil)
    -- self:addBase("supplyDepot", 2, nil, nil)
    -- self:addBase("airbase", 2, nil, nil)
end

-- function Game:initializeProvinces()
--     -- Partition the map into provinces limited to the middle area (exclude starting areas)
--     -- For this map, create a 2x2 province grid in the central band, and group provinces into 2 regions (columns)
--     local pc = self.numProvinceCols or 2
--     local pr = self.numProvinceRows or 2

--     -- Determine middle band rows (exclude starting areas)
--     local startRow = (self.startingAreaDepth or 5) + 1
--     local endRow = self.mapHeight - (self.startingAreaDepth or 5)
--     local bandHeight = math.max(1, endRow - startRow + 1)

--     local provinceWidth = math.max(1, math.floor(self.mapWidth / pc))
--     local provinceHeight = math.max(1, math.floor(bandHeight / pr))

--     self.provinces = {}
--     self.regions = {}

--     local provinceId = 1
--     for px = 1, pc do
--         local colStart = (px - 1) * provinceWidth + 1
--         local colEnd = (px == pc) and self.mapWidth or (px * provinceWidth)
--         for py = 1, pr do
--             local rowStart = startRow + (py - 1) * provinceHeight
--             local rowEnd = (py == pr) and endRow or (startRow + py * provinceHeight - 1)

--             -- store province tiles (only in middle band)
--             local tiles = {}
--             for col = colStart, colEnd do
--                 for row = rowStart, rowEnd do
--                     tiles[#tiles + 1] = {col = col, row = row}
--                     self.provinces[col .. "," .. row] = provinceId
--                 end
--             end

--             -- region id = px (group provinces by column)
--             local regionId = px
--             self.regions[regionId] = self.regions[regionId] or {}
--             table.insert(self.regions[regionId], provinceId)

--             provinceId = provinceId + 1
--         end
--     end
-- end

-- function Game:drawProvinceBoundaries()
--     if not self.provinces then return end

--     for col = 1, self.mapWidth do
--         for row = 1, self.mapHeight do
--             local pid = self.provinces[col .. "," .. row]
--             if pid then
--                 provinceTiles[pid] = provinceTiles[pid] or {}
--                 table.insert(provinceTiles[pid], {col = col, row = row})
--             end
--         end
--     end

--     -- Draw each province as a subtle fill and light outline
--     for pid, tiles in pairs(provinceTiles) do
--         -- choose a color based on province id to alternate hues
--         local hue = (pid % 2 == 0) and 0.85 or 0.9
--         love.graphics.setColor(0.8 * hue, 0.75 * hue, 0.6 * hue, 0.06)
--         for _, t in ipairs(tiles) do
--             local tile = self.map:getTile(t.col, t.row)
--             if tile and tile.points and tile.isLand then
--                 love.graphics.polygon("fill", tile.points)
--             end
--         end
--     end

--     -- Draw province external borders (black when unowned, team color when owned)
--     for pid, tiles in pairs(provinceTiles) do
--         local owner = self:getProvinceOwner(pid)
--         local colorR, colorG, colorB = 0, 0, 0
--         if owner == 1 then colorR, colorG, colorB = 1, 0, 0
--         elseif owner == 2 then colorR, colorG, colorB = 0, 0, 1
--         end
--         local edges = self:calculateExternalEdges(tiles)
--         love.graphics.setLineWidth(2)
--         love.graphics.setColor(colorR, colorG, colorB, 1)
--         for _, e in ipairs(edges) do
--             love.graphics.line(e[1], e[2], e[3], e[4])
--         end
--         love.graphics.setLineWidth(1)
--     end

--     -- Draw region labels and ownership
--     local regionOwners = self:calculateRegionControl()
--     love.graphics.setFont(love.graphics.newFont(12))
--     for regionId, provinceList in pairs(self.regions) do
--         -- compute average pixel position for region label
--         local sumX, sumY, count = 0, 0, 0
--         for _, provinceId in ipairs(provinceList) do
--             -- pick first tile in provinceTiles[provinceId] if exists
--             local tiles = provinceTiles[provinceId]
--             if tiles and #tiles > 0 then
--                 for _, t in ipairs(tiles) do
--                     local px, py = self.map:gridToPixels(t.col, t.row)
--                     sumX = sumX + px
--                     sumY = sumY + py
--                     count = count + 1
--                 end
--             end
--         end
--         if count > 0 then
--             local cx = sumX / count
--             local cy = sumY / count
--             local owner = regionOwners[regionId]
--             if owner == 1 then
--                 love.graphics.setColor(1, 0, 0, 0.9)
--             elseif owner == 2 then
--                 love.graphics.setColor(0, 0, 1, 0.9)
--             else
--                 love.graphics.setColor(0.9, 0.9, 0.9, 0.9)
--             end
--             love.graphics.printf("Region " .. tostring(regionId), cx - 40, cy - 8, 80, "center")

--             -- Draw external region border (thicker) and color by region owner
--             local regionEdges = self:calculateRegionExternalEdges(regionId)
--             local rR, rG, rB = 0, 0, 0
--             if owner == 1 then rR, rG, rB = 1, 0, 0
--             elseif owner == 2 then rR, rG, rB = 0, 0, 1
--             end
--             love.graphics.setLineWidth(4)
--             love.graphics.setColor(rR, rG, rB, 1)
--             for _, e in ipairs(regionEdges) do
--                 love.graphics.line(e[1], e[2], e[3], e[4])
--             end
--             love.graphics.setLineWidth(1)
--         end
--     end

--     love.graphics.setColor(1,1,1,1)
-- end

-- -- Return neighbor offsets for a given column parity (matches HexMap:getNeighbors ordering)
-- function Game:getHexNeighborOffsets(col)
--     local odd = (col % 2 ~= 0)
--     if not odd then
--         return {
--             {1, 0}, {1, 1}, {0, 1}, {-1, 0}, {-1, 1}, {0, -1}
--         }
--     else
--         return {
--             {1, -1}, {1, 0}, {0, 1}, {-1, -1}, {-1, 0}, {0, -1}
--         }
--     end
-- end









-- Return neighbor offsets for a given column parity (matches HexMap:getNeighbors ordering)
function Game:getHexNeighborOffsets(col)
    local odd = (col % 2 ~= 0)
    if not odd then
        return {
            {1, 0}, {1, 1}, {0, 1}, {-1, 0}, {-1, 1}, {0, -1}
        }
    else
        return {
            {1, -1}, {1, 0}, {0, 1}, {-1, -1}, {-1, 0}, {0, -1}
        }
    end
end


-- Generic external edge calculator for a set of tiles.
-- `tiles` is an array of {col=row, row=row} or a table keyed by "col,row" -> true
-- Returns array of edges: { {x1,y1,x2,y2}, ... }
function Game:calculateExternalEdges(tiles)
    local tileSet = {}
    if not tiles then return {} end
    if #tiles > 0 then
        for _, t in ipairs(tiles) do
            tileSet[t.col .. "," .. t.row] = true
        end
    else
        -- assume table keyed style
        for k, v in pairs(tiles) do
            if v then tileSet[k] = true end
        end
    end

    local edges = {}
    for key, _ in pairs(tileSet) do
        local comma = string.find(key, ",")
        if not comma then goto continue_tile end
        local col = tonumber(string.sub(key, 1, comma - 1))
        local row = tonumber(string.sub(key, comma + 1))
        local tile = self.map:getTile(col, row)
        if not tile or not tile.points then goto continue_tile end

        local offsets = self:getHexNeighborOffsets(col)
        for i = 1, 6 do
            local off = offsets[i]
            local ncol = col + off[1]
            local nrow = row + off[2]
            local nkey = ncol .. "," .. nrow
            if not tileSet[nkey] then
                -- Neighbor missing: pick the edge whose midpoint faces the neighbor center
                local cx, cy = self.map:gridToPixels(col, row)
                local ncx, ncy = self.map:gridToPixels(ncol, nrow)
                local vx, vy = ncx - cx, ncy - cy
                local vdist = math.sqrt(vx * vx + vy * vy)
                local vnx, vny = 0, 0
                if vdist > 0 then vnx, vny = vx / vdist, vy / vdist end

                local bestJ, bestDot = 1, -999
                -- Find edge midpoint most aligned with neighbor direction
                for j = 1, 6 do
                    local p1j = (j - 1) * 2 + 1
                    local p2j = (j % 6) * 2 + 1
                    local ax = tile.points[p1j]
                    local ay = tile.points[p1j + 1]
                    local bx = tile.points[p2j]
                    local by = tile.points[p2j + 1]
                    local mx = (ax + bx) * 0.5
                    local my = (ay + by) * 0.5
                    local ex, ey = mx - cx, my - cy
                    local ed = math.sqrt(ex * ex + ey * ey)
                    if ed > 0 and vdist > 0 then
                        local enx, eny = ex / ed, ey / ed
                        local dot = enx * vnx + eny * vny
                        if dot > bestDot then
                            bestDot = dot
                            bestJ = j
                        end
                    elseif vdist == 0 then
                        bestJ = i
                        break
                    end
                end

                local p1i = (bestJ - 1) * 2 + 1
                local p2i = (bestJ % 6) * 2 + 1
                local ax = tile.points[p1i]
                local ay = tile.points[p1i + 1]
                local bx = tile.points[p2i]
                local by = tile.points[p2i + 1]

                -- Midpoint and inward normal
                local mx = (ax + bx) * 0.5
                local my = (ay + by) * 0.5
                local dx = cx - mx
                local dy = cy - my
                local distn = math.sqrt(dx * dx + dy * dy)
                local nx, ny = 0, 0
                if distn > 0 then nx, ny = dx / distn, dy / distn end

                -- Minimal inset to push lines closer to hex edges
                local inset = math.min(2, (self.hexSideLength or 32) * 0.03)
                local ox = nx * inset
                local oy = ny * inset

                local x1 = ax + ox
                local y1 = ay + oy
                local x2 = bx + ox
                local y2 = by + oy
                table.insert(edges, {x1, y1, x2, y2})
            end
        end
        ::continue_tile::
    end

    return edges
end

-- Return external edges for tiles within a radius from a center (useful for airbase outer ring drawing)
function Game:getRingEdges(centerCol, centerRow, radius)
    if not centerCol or not centerRow or not radius or radius <= 0 then return {} end
    local tiles = self:getTilesWithinRadius(centerCol, centerRow, radius)
    if not tiles or #tiles == 0 then return {} end
    return self:calculateExternalEdges(tiles)
end

-- -- Determine owner of a province (returns team number or nil). A team owns a province if it has one or more HQs in that province and no HQs of other teams.
-- function Game:getProvinceOwner(provinceId)
--     local owner = nil
--     for _, base in ipairs(self.bases) do
--         if base.type == "hq" and base.col and base.row and base.col > 0 then
--             local pid = self.provinces[base.col .. "," .. base.row]
--             if pid == provinceId then
--                 if not owner then owner = base.team
--                 elseif owner ~= base.team then return nil end
--             end
--         end
--     end
--     return owner
-- end

-- -- Calculate external edges for a region (regionId)
-- function Game:calculateRegionExternalEdges(regionId)
--     local provinceList = self.regions[regionId]
--     if not provinceList then return {} end
--     local tiles = {}
--     for _, pid in ipairs(provinceList) do
--         for k, v in pairs(self.provinces) do
--             if v == pid then
--                 local comma = string.find(k, ",")
--                 if comma then
--                     local col = tonumber(string.sub(k, 1, comma - 1))
--                     local row = tonumber(string.sub(k, comma + 1))
--                     table.insert(tiles, {col = col, row = row})
--                 end
--             end
--         end
--     end
--     return self:calculateExternalEdges(tiles)
-- end

-- -- Determine ownership of regions: returns table regionId -> ownerTeam or nil
-- function Game:calculateRegionControl()
--     -- If regions aren't initialized, return empty ownership map
--     if not self.regions then return {} end
--     local owners = {}
--     for regionId, provinceList in pairs(self.regions) do
--         -- region is controlled by a team if that team has an HQ in every province of this region
--         local regionOwner = nil
--         local allProvincesHaveHQ = true
--         local requiredTeam = nil
--         for _, provinceId in ipairs(provinceList) do
--             -- find any HQ in this province
--             local foundHQ = false
--             local foundTeam = nil
--             for _, base in ipairs(self.bases) do
--                 if base.type == "hq" and base.col and base.row and base.col > 0 then
--                     local pid = self.provinces[base.col .. "," .. base.row]
--                     if pid == provinceId then
--                         foundHQ = true
--                         foundTeam = base.team
--                         break
--                     end
--                 end
--             end
--             if not foundHQ then
--                 allProvincesHaveHQ = false
--                 break
--             end
--             if not requiredTeam then
--                 requiredTeam = foundTeam
--             elseif requiredTeam ~= foundTeam then
--                 -- Different teams in different provinces -> no single owner
--                 allProvincesHaveHQ = false
--                 break
--             end
--         end
--         if allProvincesHaveHQ and requiredTeam then
--             owners[regionId] = requiredTeam
--         end
--     end
--     return owners
-- end

function Game:addBase(baseType, team, col, row)
    local base = Base.new(baseType, team, self.map, col, row)
    table.insert(self.bases, base)
    pcall(function() print(string.format("[game] addBase local -> type=%s team=%s col=%s row=%s", tostring(baseType), tostring(team), tostring(col), tostring(row))) end)
    -- If this base was placed with coordinates, mark it so host will broadcast at end-turn
    if base.col and base.row and base.col > 0 and base.row > 0 then
        base.justPlaced = true
        -- Update fog visibility immediately so the new base's effects are recognized locally
        if self.fogOfWar then
            pcall(function() print("[game] addBase visibility before: t1=" .. tostring(self.fogOfWar:isTileVisible(1, base.col, base.row)) .. " t2=" .. tostring(self.fogOfWar:isTileVisible(2, base.col, base.row))) end)
            self.fogOfWar:updateVisibility(1, self.pieces, self.bases, self.teamStartingCorners)
            self.fogOfWar:updateVisibility(2, self.pieces, self.bases, self.teamStartingCorners)
            pcall(function() print("[game] addBase visibility after: t1=" .. tostring(self.fogOfWar:isTileVisible(1, base.col, base.row)) .. " t2=" .. tostring(self.fogOfWar:isTileVisible(2, base.col, base.row))) end)
            -- Cache tiles within this base's radius to avoid repeated BFS calls during fog updates
            if self.getTilesWithinRadius then
                base._tilesInRadius = self:getTilesWithinRadius(base.col, base.row, base:getRadius())
            end
            -- Recompute air superiority because a base (possibly an airbase) was placed
            self.airSuperiorityMap = self:calculateAirSuperiorityMap()
        end
    end
end

-- Apply a place-base action locally (used by host request handler and commit handler)
-- Returns the placed Base instance (existing filled slot or newly created)
function Game:applyPlaceBase(team, col, row, baseType)
    if not team or not col or not row then return nil end
    local placedBase = nil
    for _, base in ipairs(self.bases) do
        if base.team == team and (not base.col or base.col == 0) and (not base.row or base.row == 0) then
            base:setPosition(col, row)
            self.basesPlaced = (self.basesPlaced or 0) + 1
            pcall(function() print(string.format("[game] applyPlaceBase -> filled existing slot team=%s col=%s row=%s baseType=%s", tostring(team), tostring(col), tostring(row), tostring(baseType))) end)
            placedBase = base
            break
        end
    end
    if not placedBase then
        local newBase = Base.new(baseType or "hq", team, self.map, col, row)
        table.insert(self.bases, newBase)
        self.basesPlaced = (self.basesPlaced or 0) + 1
        pcall(function() print(string.format("[game] applyPlaceBase -> created new base team=%s col=%s row=%s baseType=%s", tostring(team), tostring(col), tostring(row), tostring(baseType))) end)
        placedBase = newBase
    end
    -- Update fog visibility so the new base's effects are recognized locally (skip during placement to avoid cheating)
    if self.fogOfWar and self.state ~= "placing" then
        -- Cache tiles within this placed base's radius to avoid repeated BFS calls
        if placedBase and placedBase.col and placedBase.col > 0 and self.getTilesWithinRadius then
            placedBase._tilesInRadius = self:getTilesWithinRadius(placedBase.col, placedBase.row, placedBase:getRadius())
        end
        -- Recompute air superiority because a base (possibly an airbase) was placed
        self.airSuperiorityMap = self:calculateAirSuperiorityMap()
        -- Now update fog using the fresh air superiority map and caches
        self.fogOfWar:updateVisibility(1, self.pieces, self.bases, self.teamStartingCorners)
        self.fogOfWar:updateVisibility(2, self.pieces, self.bases, self.teamStartingCorners)
    end
    return placedBase
end

function Game:generateResources()
    -- Helper: avoid starting areas (full-width top/bottom strips)
    local function inStartingArea(col, row)
        if not self.teamStartingAreas then return false end
        for team, area in pairs(self.teamStartingAreas) do
            if area and area.rowStart and area.rowEnd then
                if row >= area.rowStart and row <= area.rowEnd then
                    return true
                end
            end
        end
        return false
    end

    -- Helper: check if tile is a valid resource location (land only, no water/forest/hills/mountains)
    local function isValidResourceTile(tile)
        if not tile then return false end
        -- Only allow flat land tiles; exclude water, forest, hills, mountains
        return tile.isLand and not tile.isWater and not tile.isForest and not tile.isHill and not tile.isMountain
    end

    -- Helper: check if resource is too close to existing resources (minimum distance)
    local minResourceDistance = 5  -- Minimum hex distance between resources
    local function isTooCloseToResources(col, row)
        for _, resource in ipairs(self.resources) do
            local dx = col - resource.col
            local dy = row - resource.row
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist < minResourceDistance then
                return true
            end
        end
        return false
    end

    -- Compute map center (in grid and pixel coords) and map radius (pixels)
    function Game:computeMapCenterAndRadius()
        local centerCol = math.ceil(self.mapWidth / 2)
        local centerRow = math.ceil(self.mapHeight / 2)
        local cx, cy = self.map:gridToPixels(centerCol, centerRow)
        local maxDist = 0
        for col = 1, self.mapWidth do
            for row = 1, self.mapHeight do
                local tile = self.map:getTile(col, row)
                if tile then
                    local px, py = self.map:gridToPixels(col, row)
                    local dx = px - cx
                    local dy = py - cy
                    local d = math.sqrt(dx * dx + dy * dy)
                    if d > maxDist then maxDist = d end
                end
            end
        end
        return centerCol, centerRow, cx, cy, maxDist
    end

    -- First, create resources marked by the map generator (tile.resourceType)
    local centerCol = math.floor(self.mapWidth / 2)
    local centerRow = math.floor(self.mapHeight / 2)
    local oilRadius = math.max(1, math.floor(math.min(self.mapWidth, self.mapHeight) * 0.35))
    for col = 1, self.mapWidth do
        for row = 1, self.mapHeight do
            local tile = self.map:getTile(col, row)
            if tile and tile.resourceType and isValidResourceTile(tile) and not self:getResourceAt(col, row) and not inStartingArea(col, row) and not isTooCloseToResources(col, row) then
                local rtype = tile.resourceType or "generic"
                -- Only place oil if it's reasonably close to the map center
                if rtype == "oil" then
                    local dx = col - centerCol
                    local dy = row - centerRow
                    local dist = math.sqrt(dx * dx + dy * dy)
                    if dist <= oilRadius then
                        local resource = Resource.new(rtype, self.map, col, row)
                        table.insert(self.resources, resource)
                    else
                        -- convert to generic if too far from center
                        local resource = Resource.new("generic", self.map, col, row)
                        table.insert(self.resources, resource)
                    end
                else
                    local resource = Resource.new(rtype, self.map, col, row)
                    table.insert(self.resources, resource)
                end
            end
        end
    end

    -- Generate a few additional generic metal tiles scattered across the map
    -- Place enough so at least one is found by turn 3 (spread across map for even distribution)
    local numMetals = 8  -- Increased from 3 to ensure better distribution
    local mapArea = self.mapWidth * self.mapHeight
    local targetDensity = numMetals / mapArea  -- Target spawn density
    
    -- Use helper to get map center and radius
    local mapCenterCol, mapCenterRow, centerPx, centerPy, mapRadiusPx = self:computeMapCenterAndRadius()
    local minDistFromEdge = 4 * (self.map.sideLength or 50)  -- 4 tiles from edge in pixels
    local maxSpawnRadiusPx = mapRadiusPx - minDistFromEdge
   
    for i = 1, numMetals do
        local attempts = 0
        local placed = false
        while not placed and attempts < 100 do
            attempts = attempts + 1
            local col = math.random(5, self.mapWidth - 5)  -- Avoid edges
            local row = math.random(5, self.mapHeight - 5)
            local tile = self.map:getTile(col, row)
            if tile and isValidResourceTile(tile) then
                   -- Check distance from map center to ensure 4+ tiles from edge
                   local px, py = self.map:gridToPixels(col, row)
                   local dx = px - centerPx
                   local dy = py - centerPy
                   local distFromCenter = math.sqrt(dx * dx + dy * dy)
                   if distFromCenter <= maxSpawnRadiusPx then
                if not self:getPieceAt(col, row) and not self:getBaseAt(col, row) and not self:getResourceAt(col, row) and not inStartingArea(col, row) and not isTooCloseToResources(col, row) then
                    local resource = Resource.new("generic", self.map, col, row)
                    table.insert(self.resources, resource)
                    placed = true
                end
                   end
            end
        end
    end

    -- Ensure at least one oil deposit per side (top/bottom) near the map center, avoiding starting areas
    local minOilPerSide = 1
    local oilRadius = math.max(1, math.floor(math.min(self.mapWidth, self.mapHeight) * 0.25))
    local centerRow = math.floor(self.mapHeight / 2)

    local function countOilInHalf(upper)
        local cnt = 0
        for _, r in ipairs(self.resources) do
            if r.type == "oil" then
                if upper and r.row < centerRow then cnt = cnt + 1 end
                if not upper and r.row >= centerRow then cnt = cnt + 1 end
            end
        end
        return cnt
    end

    -- Place oil for upper half (relax distance constraint for guaranteed oil spawns)
    local tries = 0
    while countOilInHalf(true) < minOilPerSide and tries < 1000 do
        tries = tries + 1
        local angle = math.random() * math.pi * 2
        local dist = math.random(0, oilRadius)
        local col = centerCol + math.floor(math.cos(angle) * dist + 0.5)
        local row = centerRow - math.abs(math.floor(math.sin(angle) * dist + 0.5)) - 1
        local tile = self.map:getTile(col, row)
        if tile and isValidResourceTile(tile) and not inStartingArea(col, row) and not self:getResourceAt(col, row) then
            local resource = Resource.new("oil", self.map, col, row)
            table.insert(self.resources, resource)
        end
    end

    -- Place oil for lower half (relax distance constraint for guaranteed oil spawns)
    tries = 0
    while countOilInHalf(false) < minOilPerSide and tries < 1000 do
        tries = tries + 1
        local angle = math.random() * math.pi * 2
        local dist = math.random(0, oilRadius)
        local col = centerCol + math.floor(math.cos(angle) * dist + 0.5)
        local row = centerRow + math.abs(math.floor(math.sin(angle) * dist + 0.5)) + 1
        local tile = self.map:getTile(col, row)
        if tile and isValidResourceTile(tile) and not inStartingArea(col, row) and not self:getResourceAt(col, row) then
            local resource = Resource.new("oil", self.map, col, row)
            table.insert(self.resources, resource)
        end
    end
end

function Game:getResourceAt(col, row)
    for _, resource in ipairs(self.resources) do
        if resource.col == col and resource.row == row then
            return resource
        end
    end
    return nil
end

function Game:addPiece(pieceType, team, col, row)
    local piece = Piece.new(pieceType, team, self.map, col, row)
    piece.recruited = true  -- New pieces start as having moved to prevent move+attack on the turn they're built
    table.insert(self.pieces, piece)
    -- If added with coordinates (mid-game build), mark so host will broadcast at end-turn
    if piece.col and piece.row and piece.col > 0 and piece.row > 0 then
        piece.justPlaced = true
        pcall(function() print(string.format("[game] addPiece local -> type=%s team=%s col=%s row=%s", tostring(pieceType), tostring(team), tostring(col), tostring(row))) end)
    end
end

-- Reveal a piece to a specific team (core mechanic, works in single-player)
function Game:revealPieceToTeam(piece, team)
    if not piece or not team then return end
    piece.revealedTo = piece.revealedTo or {}
    piece.revealedTo[team] = true
    piece.hiddenInForest = false
end

function Game:applyReplayAction(action)
    if not action then 
        print("[REPLAY] applyReplayAction: action is nil")
        return 
    end
    print("[REPLAY] applyReplayAction: action.action = " .. tostring(action.action))
    if action.action == "move" then
        print("[REPLAY] Processing MOVE action")
        -- Find the piece and animate its movement along the recorded path
        local piece = self:getPieceAt(action.fromCol, action.fromRow)
        print("[REPLAY] Looking for piece at (" .. tostring(action.fromCol) .. "," .. tostring(action.fromRow) .. "), found: " .. tostring(piece ~= nil))
        if piece then
            print("[REPLAY] piece.team=" .. tostring(piece.team) .. " action.team=" .. tostring(action.team) .. " match=" .. tostring(piece.team == action.team))
            print("[REPLAY] piece.type=" .. tostring(piece.type) .. " action.pieceType=" .. tostring(action.pieceType) .. " match=" .. tostring(piece.type == action.pieceType))
            print("[REPLAY] action.path=" .. tostring(action.path) .. " length=" .. tostring(action.path and #action.path or 0))
        end
        if piece and piece.team == action.team and piece.type == action.pieceType and action.path and #action.path > 0 then
            print("[REPLAY] Starting animated move: " .. piece.type .. " from (" .. action.fromCol .. "," .. action.fromRow .. ") to (" .. action.toCol .. "," .. action.toRow .. ")")
            -- Determine which portion of the path is visible to the local viewer.
            local viewTeam = self.localTeam or (3 - action.team)
            local fullPath = action.path
            local visibleCount = 0
            if self.fogOfWar then
                for i, step in ipairs(fullPath) do
                    if self.fogOfWar:isTileVisible(viewTeam, step.col, step.row) then
                        visibleCount = i
                    else
                        break
                    end
                end
            else
                visibleCount = #fullPath
            end

            if visibleCount > 0 then
                local visPath = {}
                for i = 1, visibleCount do table.insert(visPath, fullPath[i]) end
                -- If there is an invisible remainder, schedule it to be applied after the visible animation completes
                if visibleCount < #fullPath then
                    local final = fullPath[#fullPath]
                    self._replayPendingFinal = self._replayPendingFinal or {}
                    self._replayPendingFinal[piece] = { col = final.col, row = final.row }
                end
                piece:startAnimatedMovement(visPath)
                self._replayWaitForPiece = piece
                print("[REPLAY] _replayWaitForPiece set to: " .. piece.type .. " (visible steps=" .. tostring(visibleCount) .. ")")
            else
                -- No visible steps: directly apply final position without animation
                local final = fullPath[#fullPath]
                print("[REPLAY] Move entirely out of view; placing piece at final (" .. tostring(final.col) .. "," .. tostring(final.row) .. ")")
                piece:setPosition(final.col, final.row)
                piece.hasMoved = true
            end
        elseif piece then
            print("[REPLAY] Move conditions failed - path check: path=" .. tostring(action.path) .. " length=" .. tostring(action.path and #action.path or 0))
            print("[REPLAY] Setting position directly from (" .. action.fromCol .. "," .. action.fromRow .. ") to (" .. action.toCol .. "," .. action.toRow .. ")")
            piece:setPosition(action.toCol, action.toRow)
            piece.hasMoved = true
        end
    elseif action.action == "attack" then
        print("[REPLAY] Processing ATTACK action")
        -- Animate attack: find attacker and target, set pending attack with recorded damage
        local attacker = self:getPieceAt(action.fromCol, action.fromRow)
        local target = self:getPieceAt(action.toCol, action.toRow)
        print("[REPLAY] Attack: attacker at (" .. tostring(action.fromCol) .. "," .. tostring(action.fromRow) .. ") found=" .. tostring(attacker ~= nil))
        print("[REPLAY] Attack: target at (" .. tostring(action.toCol) .. "," .. tostring(action.toRow) .. ") found=" .. tostring(target ~= nil))
        if attacker then
            print("[REPLAY] Attack: attacker type=" .. tostring(attacker.type) .. " team=" .. tostring(attacker.team) .. " matches=" .. tostring(attacker.team == action.team and attacker.type == action.pieceType))
        end
        if attacker and target and attacker.team == action.team and attacker.type == action.pieceType and target.team == action.targetTeam and target.type == action.targetType then
            print("[REPLAY] Setting _replayAttackPending with damageToTarget=" .. tostring(action.damageToTarget or 0) .. " damageToAttacker=" .. tostring(action.damageToAttacker or 0))
            -- Spawn combat animation with recorded dice rolls
            if action.rollsA and action.rollsD then
                local ax, ay = self.map:gridToPixels(action.fromCol, action.fromRow)
                local bx, by = self.map:gridToPixels(action.toCol, action.toRow)
                local mx, my = (ax + bx) / 2, (ay + by) / 2
                self:spawnCombatAnimation(mx, my, action.rollsA, action.rollsD, attacker.team, target.team)
            end
            -- Apply the recorded damage after a delay so the animation can play
            self._replayAttackPending = {attacker=attacker, target=target, damageToTarget=action.damageToTarget or 0, damageToAttacker=action.damageToAttacker or 0, timer=0.3}
        else
            print("[REPLAY] Attack validation failed: attacker match=" .. tostring(attacker and attacker.team == action.team and attacker.type == action.pieceType) .. " target match=" .. tostring(target and target.team == action.targetTeam and target.type == action.targetType))
        end
    elseif action.action == "recruit" then
        -- Add a new piece of the given type at the location
        self:addPiece(action.pieceType, action.team, action.col, action.row)
    elseif action.action == "mineTrigger" then
        -- DISABLED: Replay mine trigger handling for testing live gameplay only
        print("[DEBUG MINE] [REPLAY] DISABLED mineTrigger replay action at (" .. action.col .. "," .. action.row .. ")")
        -- Replay mine trigger: spawn explosion animation, show damage text, and remove mine
        
        print("[DEBUG MINE] [REPLAY] Processing MINE TRIGGER action at (" .. action.col .. "," .. action.row .. "), moverTeam=" .. tostring(action.moverTeam))
        local px, py = self.map:gridToPixels(action.col, action.row)
        self:spawnMineExplosion(px, py, action.damage, action.col, action.row)
        self:spawnDamageText(px, py, action.damage, "mine")
        
        -- Find the mover at the mine location (piece has moved there during movement action)
        local mover = self:getPieceAt(action.col, action.row)
        print("[DEBUG MINE] [REPLAY] Found mover at (" .. action.col .. "," .. action.row .. "): " .. tostring(mover and (mover.type .. " team " .. mover.team) or "nil"))
        
        -- If piece isn't at mine location yet, try to find by mover team+type
        if not mover and action.moverTeam and action.moverType then
            for _, piece in ipairs(self.pieces) do
                if piece.team == action.moverTeam and piece.type == action.moverType and piece.col == action.col and piece.row == action.row then
                    mover = piece
                    break
                end
            end
            print("[DEBUG MINE] [REPLAY] Found mover by team+type: " .. tostring(mover and (mover.type .. " team " .. mover.team) or "nil"))
        end
        
        -- Apply damage to the mover
        if mover then
            print("[DEBUG MINE] [REPLAY] Applying " .. action.damage .. " damage to " .. mover.type .. " (team " .. mover.team .. ")")
            mover:takeDamage(action.damage)
        else
            print("[DEBUG MINE] [REPLAY] NO MOVER FOUND to apply damage!")
        end
        
        -- Remove the mine from the board
        local mine = self:getMineAt(action.col, action.row)
        print("[DEBUG MINE] [REPLAY] Attempting to remove mine at (" .. action.col .. "," .. action.row .. "): " .. tostring(mine and "found" or "not found"))
        if mine then
            self:removeMine(mine)
        end
        
    elseif action.action == "airstrike" then
        -- Replay airstrike: spawn animation, show damage text, and apply damage to target
        print("[REPLAY] Processing AIRSTRIKE action at (" .. action.col .. "," .. action.row .. ")")
        local px, py = self.map:gridToPixels(action.col, action.row)
        self:spawnMineExplosion(px, py, action.damage, action.col, action.row)
        self:spawnDamageText(px, py, action.damage, "airstrike")
        
        -- Find the target piece - prioritize by position, fallback to team+type
        local target = nil
        if action.targetCol and action.targetRow then
            target = self:getPieceAt(action.targetCol, action.targetRow)
        end
        if not target and action.targetTeam and action.targetType then
            for _, piece in ipairs(self.pieces) do
                if piece.team == action.targetTeam and piece.type == action.targetType then
                    target = piece
                    break
                end
            end
        end
        
        -- Set pending airstrike to apply damage after animation plays
        if target then
            self._replayAirstrikePending = {target = target, damage = action.damage, timer = 0.3}
        end
    end
end
-- Core game logic and state management

function Game:update(dt)
    -- Update game logic here
    if self.state == "replay" and self.replay and self.replay.replayActive then
        -- print("[REPLAY UPDATE] In replay state, replayActive = " .. tostring(self.replay.replayActive))

        -- If overlay is active, count down and wait (do not start animations)
        if self._replayOverlay then
            if self._replayOverlayTimer then
                self._replayOverlayTimer = self._replayOverlayTimer - dt
                if self._replayOverlayTimer <= 0 then
                    self._replayOverlay = false
                    self._replayOverlayTimer = nil
                    print("[REPLAY] Overlay auto-dismissed, starting replay")
                end
            end
            return
        end

        -- Always update animations during replay
        self:updatePieceAnimations(dt)

        -- Update fog-of-war visibility each frame during replay so visibility follows moving units.
        if self.fogOfWar then
            self.fogOfWar:updateVisibility(1, self.pieces, self.bases, self.teamStartingCorners)
            self.fogOfWar:updateVisibility(2, self.pieces, self.bases, self.teamStartingCorners)
            -- If a tile becomes visible again during replay, ensure enemy pieces on it are revealed so they render.
            local viewTeam = self.localTeam or self.currentTurn
            for _, piece in ipairs(self.pieces) do
                if piece and piece.col and piece.row and piece.team ~= viewTeam then
                    if self.fogOfWar:isTileVisible(viewTeam, piece.col, piece.row) then
                        piece.revealedTo = piece.revealedTo or {}
                        piece.revealedTo[viewTeam] = true
                        piece.hiddenInForest = false
                    end
                end
            end
        end
        
        -- If waiting for a piece to finish animating, don't process next action
        if self._replayWaitForPiece and self._replayWaitForPiece.isAnimating then
            return
        elseif self._replayWaitForPiece then
            -- Animation finished, apply any pending final teleport (if moving out of visibility)
            if self._replayPendingFinal and self._replayPendingFinal[self._replayWaitForPiece] then
                local pos = self._replayPendingFinal[self._replayWaitForPiece]
                if pos then
                    print("[REPLAY] Applying pending final position for piece " .. tostring(self._replayWaitForPiece.type) .. " -> (" .. tostring(pos.col) .. "," .. tostring(pos.row) .. ")")
                    self._replayWaitForPiece:setPosition(pos.col, pos.row)
                    self._replayWaitForPiece.hasMoved = true
                end
                self._replayPendingFinal[self._replayWaitForPiece] = nil
            end
            -- Animation finished, clear it
            self._replayWaitForPiece = nil
        end
        
        -- If waiting for attack animation, wait for timer
        if self._replayAttackPending then
            self._replayAttackPending.timer = self._replayAttackPending.timer - dt
            if self._replayAttackPending.timer <= 0 then
                local attacker = self._replayAttackPending.attacker
                local target = self._replayAttackPending.target
                local damageToTarget = self._replayAttackPending.damageToTarget or 0
                local damageToAttacker = self._replayAttackPending.damageToAttacker or 0
                
                print("[REPLAY ATTACK] Applying attack: attacker=" .. tostring(attacker and attacker.type) .. " target=" .. tostring(target and target.type) .. " dmgToTarget=" .. tostring(damageToTarget) .. " dmgToAttacker=" .. tostring(damageToAttacker))
                
                -- Apply damage to target
                if target and damageToTarget > 0 then
                    print("[REPLAY ATTACK] Applying " .. tostring(damageToTarget) .. " damage to target " .. tostring(target.type))
                    local wasKilled = target:takeDamage(damageToTarget)
                    if wasKilled then
                        print("[REPLAY ATTACK] Target killed!")
                        for i, p in ipairs(self.pieces) do if p == target then table.remove(self.pieces, i); break end end
                    end
                end
                
                -- Apply damage to attacker
                if attacker and damageToAttacker > 0 then
                    print("[REPLAY ATTACK] Applying " .. tostring(damageToAttacker) .. " damage to attacker " .. tostring(attacker.type))
                    local wasKilled = attacker:takeDamage(damageToAttacker)
                    if wasKilled then
                        print("[REPLAY ATTACK] Attacker killed!")
                        for i, p in ipairs(self.pieces) do if p == attacker then table.remove(self.pieces, i); break end end
                    end
                end
                
                self._replayAttackPending = nil
                
                -- If this was the last action, finish the replay now
                if self.replay.replayIndex and self.replay.currentReplay and self.replay.replayIndex > #self.replay.currentReplay then
                    print("[REPLAY ATTACK] Attack was last action, finishing replay")
                    self.replay:finishReplay()
                    self.state = "playing"
                end
            else
                return
            end
        end
        
        -- If waiting for airstrike animation, wait for timer
        if self._replayAirstrikePending then
            self._replayAirstrikePending.timer = self._replayAirstrikePending.timer - dt
            if self._replayAirstrikePending.timer <= 0 then
                local target = self._replayAirstrikePending.target
                local damage = self._replayAirstrikePending.damage or 0
                
                print("[REPLAY AIRSTRIKE] Applying airstrike: target=" .. tostring(target and target.type) .. " damage=" .. tostring(damage))
                
                -- Apply damage to target
                if target and damage > 0 then
                    print("[REPLAY AIRSTRIKE] Applying " .. tostring(damage) .. " damage to target " .. tostring(target.type))
                    local wasKilled = target:takeDamage(damage)
                    if wasKilled then
                        print("[REPLAY AIRSTRIKE] Target killed!")
                        for i, p in ipairs(self.pieces) do if p == target then table.remove(self.pieces, i); break end end
                    end
                end
                
                self._replayAirstrikePending = nil
                
                -- If this was the last action, finish the replay now
                if self.replay.replayIndex and self.replay.currentReplay and self.replay.replayIndex > #self.replay.currentReplay then
                    print("[REPLAY AIRSTRIKE] Airstrike was last action, finishing replay")
                    self.replay:finishReplay()
                    self.state = "playing"
                end
            else
                return
            end
        end
        print("[REPLAY UPDATE] About to call stepReplay")
        -- Don't advance replay if we have pending animations
        if not self._replayAttackPending and not self._replayAirstrikePending then
            self.replay:stepReplay(function(action) 
                print("[REPLAY CALLBACK] Callback invoked with action: " .. tostring(action and action.action or "nil"))
                self:applyReplayAction(action) 
            end)
        end
        
        -- Finish replay if all actions are done and no attack/airstrike is pending
        if self.replay.replayActive and self.replay.replayIndex and self.replay.currentReplay and self.replay.replayIndex > #self.replay.currentReplay and not self._replayAttackPending and not self._replayAirstrikePending then
            print("[REPLAY] All actions completed, finishing replay")
            self.replay:finishReplay()
        end
        -- If replay just finished, switch back to playing state
        if not self.replay.replayActive then
            self.state = "playing"
        end
        return
    end
    if self.state == "playing" then
        -- Update piece animations and handle effects as they move
        self:updatePieceAnimations(dt)
        
        -- Update pieces, animations, etc.
        
        -- Air superiority is expensive; compute once per turn instead of every frame

        -- Update fog of war visibility for all teams (visibility logic will query cached air superiority)
        for team = 1, 2 do
            self.fogOfWar:updateVisibility(team, self.pieces, self.bases, self.teamStartingCorners)
        end
        
        -- Clear waypoints if an enemy is in view range
        self:clearWaypointsOnEnemyContact()
        
        -- Update combat animations
        self:updateCombatAnimations(dt)
        -- network messages are polled by main.lua and forwarded to Game:handleNetworkMessage
    elseif self.state == "placing" then
        -- During placement phase we avoid updating fog every frame to keep visibility stable
        -- (visibility will be refreshed after placement concludes)
        self:updateCombatAnimations(dt)
    end
end

function Game:handleNetworkMessage(msg)
    if not msg or not msg.type then return end
    self._applyingRemote = true
    if msg.type == "move" then
        self:applyRemoteMove(msg)
    elseif msg.type == "moveRequest" then
        -- Host receives move request and applies it authoritatively
        if self.isHost then
            local fromCol = tonumber(msg.fromCol)
            local fromRow = tonumber(msg.fromRow)
            local toCol = tonumber(msg.toCol)
            local toRow = tonumber(msg.toRow)
            if fromCol and fromRow and toCol and toRow then
                -- Validate move costs using piece hook and deduct on host
                local mover = self:getPieceAt(fromCol, fromRow)
                if mover and mover.getMoveCost then
                    local costs = mover:getMoveCost(fromCol, fromRow, toCol, toRow) or {}
                    -- Check affordability
                    for k, v in pairs(costs) do
                        if k == "oil" then
                            if (self.teamOil[mover.team] or 0) < v then
                                pcall(function() print(string.format("[game] host rejecting moveRequest: insufficient %s for team=%s", tostring(k), tostring(mover.team))) end)
                                goto skip_move_request
                            end
                        else
                            -- other resources could be supported here
                        end
                    end
                    -- Deduct costs
                    for k, v in pairs(costs) do
                        if k == "oil" then
                            self.teamOil[mover.team] = (self.teamOil[mover.team] or 0) - v
                        end
                    end
                end

                -- Apply move now that costs are validated/deducted
                self:applyRemoteMove({fromCol = fromCol, fromRow = fromRow, toCol = toCol, toRow = toRow})
                -- After applying move on host, check for mine trigger at destination and handle it (host authoritative)
                local mover2 = self:getPieceAt(toCol, toRow)
                if mover2 then
                    -- Broadcast authoritative commit for the move first so clients apply the move
                    -- and then apply any mine-trigger effects that follow.
                    self:sendCommit({type = "move", fromCol = fromCol, fromRow = fromRow, toCol = toCol, toRow = toRow})
                    -- Now host checks for mine trigger at destination and handle it (host authoritative)
                    self:triggerMineAt(toCol, toRow, mover2)
                end
                ::skip_move_request::
            end
        end
    elseif msg.type == "startBuildingRequest" then
        -- Client requested a build; host records building state and broadcasts commit
        if self.isHost then
            local col = tonumber(msg.col)
            local row = tonumber(msg.row)
            local buildingType = msg.buildingType
            local team = tonumber(msg.team)
            local buildTurns = tonumber(msg.buildTurns)
            if col and row and buildingType and team then
                local piece = self:getPieceAt(col, row)
                if piece then
                    piece.isBuilding = true
                    piece.buildingType = buildingType
                    piece.buildingTurnsRemaining = buildTurns or piece.buildingTurnsRemaining
                    piece.buildingTeam = team
                    pcall(function() print(string.format("[game] host applied startBuilding at %d,%d type=%s team=%s turns=%s", col, row, tostring(buildingType), tostring(team), tostring(buildTurns))) end)
                end
                -- Broadcast commit to clients so they can update local UI/state
                self:sendCommit({type = "startBuilding", col = col, row = row, buildingType = buildingType, team = team, buildTurns = buildTurns})
            end
        end
    elseif msg.type == "attackRequest" then
        if self.isHost then
            local amsg = msg
            amsg.fromCol = tonumber(amsg.fromCol)
            amsg.fromRow = tonumber(amsg.fromRow)
            amsg.toCol = tonumber(amsg.toCol)
            amsg.toRow = tonumber(amsg.toRow)
            local attacker = self:getPieceAt(amsg.fromCol, amsg.fromRow)
            local target = self:getPieceAt(amsg.toCol, amsg.toRow)
            if attacker and attacker.useAmmo then attacker:useAmmo() end

            -- Perform dice resolution on host
            local aDice = (attacker and attacker.getAttackDice and attacker:getAttackDice()) or 1
            local dDice = (target and target.getDefenseDice and target:getDefenseDice()) or 1
            -- Option B: defender only rolls if attacker is within defender's attack range
            if target and target.getAttackRange and attacker then
                local defRange = target:getAttackRange() or 1
                if not self:isWithinRange(target.col, target.row, attacker.col, attacker.row, defRange) then
                    dDice = 0
                end
            end
            -- Apply morale bonuses (each morale point = +1 die)
            local moraleA = self:computeMorale(attacker) or 0
            local moraleD = self:computeMorale(target) or 0
            aDice = (aDice or 0) + (moraleA or 0)
            dDice = (dDice or 0) + (moraleD or 0)
            local maxA = (attacker and attacker.getDieMax and attacker:getDieMax()) or 6
            local maxD = (target and target.getDieMax and target:getDieMax()) or 6
            -- Commander adjacency increases the max die face by +1 per adjacent commander
            local cmdA = self:countAdjacentCommanders(attacker) or 0
            local cmdD = self:countAdjacentCommanders(target) or 0
            maxA = maxA + (cmdA or 0)
            maxD = maxD + (cmdD or 0)
            -- Check for defensive buffs: tile defenses and hills both penalize attacker max die
            local defenseHere = self:getDefenseAt(amsg.toCol, amsg.toRow)
            local defenseCount = 0
            if defenseHere and target and defenseHere.team == target.team then
                defenseCount = defenseCount + 1
            end
            local targetTile = self.map and self.map:getTile(amsg.toCol, amsg.toRow)
            if targetTile and targetTile.isHill then
                defenseCount = defenseCount + 1
            end
            if defenseCount > 0 then
                maxA = math.max(1, maxA - defenseCount)
            end
            pcall(function()
                print(string.format("[DBG attack host PRE] aDice=%s moraleA=%s cmdA=%s maxA=%s  dDice=%s moraleD=%s cmdD=%s maxD=%s defense=%s defEff=%s target.col=%s target.row=%s attack.col=%s attack.row=%s", tostring(aDice), tostring(moraleA), tostring(cmdA), tostring(maxA), tostring(dDice), tostring(moraleD), tostring(cmdD), tostring(maxD), tostring(defenseHere ~= nil), tostring(defenseEffect), tostring(target and target.col), tostring(target and target.row), tostring(amsg.toCol), tostring(amsg.toRow)))
            end)
            local rollsA = self:rollDice(aDice, maxA)
            local rollsD = self:rollDice(dDice, maxD)
            local damageToTarget, damageToAttacker = self:computeDiceOutcome(rollsA, rollsD)
            pcall(function()
                print(string.format("[DBG attack host POST] rollsA=%s rollsD=%s dmgToTarget=%s dmgToAttacker=%s", tostring(table.concat(rollsA,",")), tostring(table.concat(rollsD,",")), tostring(damageToTarget), tostring(damageToAttacker)))
            end)

            -- Reveal attacker if hidden (authoritative)
            if attacker and attacker.hiddenInForest then
                local revealTeam = nil
                if target and target.team then
                    revealTeam = target.team
                else
                    revealTeam = (attacker.team and (3 - attacker.team)) or nil
                end
                if revealTeam then
                    self:revealPieceToTeam(attacker, revealTeam)
                    if Network and Network.isConnected and Network.isConnected() then
                        pcall(function()
                            print(string.format("[game] host sending revealForest (attack) -> team=%s col=%s row=%s unitTeam=%s", tostring(revealTeam), tostring(attacker.col), tostring(attacker.row), tostring(attacker.team)))
                            self:sendCommit({type = "revealForest", col = attacker.col, row = attacker.row, team = revealTeam, unitTeam = attacker.team})
                        end)
                    end
                end
            end

            -- Apply damage on host
            local moved = false
            if target and damageToTarget > 0 then
                local wasKilled = target:takeDamage(damageToTarget)
                if wasKilled then
                    -- Increment attacker's kill count and apply veteran status if threshold reached
                    if attacker then
                        attacker.kills = (attacker.kills or 0) + 1
                        if attacker.kills >= 3 then attacker.veteran = true end
                    end
                    -- Remove the killed piece
                    for i, p in ipairs(self.pieces) do if p == target then table.remove(self.pieces, i); break end end
                    -- If killed and adjacent, consider movement into tile
                    if attacker and self:isWithinRange(attacker.col, attacker.row, amsg.toCol, amsg.toRow, 1) then
                        moved = true
                    end
                end
            end
            if attacker and damageToAttacker > 0 then
                local wasKilledA = attacker:takeDamage(damageToAttacker)
                if wasKilledA then
                    for i, p in ipairs(self.pieces) do if p == attacker then table.remove(self.pieces, i); break end end
                end
            end

            -- If moving into the tile is a tank movement and host enforces oil, check/deduct
            if moved and attacker and attacker.type == "tank" then
                local team = attacker.team
                local oilCost = 1
                if (self.teamOil[team] or 0) < oilCost then
                    moved = false
                    pcall(function() print(string.format("[game] host canceling moved flag for attack: insufficient oil team=%s", tostring(team))) end)
                else
                    self.teamOil[team] = (self.teamOil[team] or 0) - oilCost
                end
            end

            if moved and attacker then attacker:setPosition(amsg.toCol, amsg.toRow) end

            -- Broadcast commit with dice rolls, damage and veteran/kill state so clients can animate and apply results
            self:sendCommit({
                type = "attack",
                fromCol = amsg.fromCol,
                fromRow = amsg.fromRow,
                toCol = amsg.toCol,
                toRow = amsg.toRow,
                attackerRolls = rollsA,
                defenderRolls = rollsD,
                damageToTarget = damageToTarget,
                damageToAttacker = damageToAttacker,
                moved = moved,
                attackerTeam = attacker and attacker.team or nil,
                defenderTeam = target and target.team or nil,
                attackerKills = attacker and (attacker.kills or 0) or 0,
                attackerVeteran = attacker and (attacker.veteran and 1 or 0) or 0,
                defenderKills = target and (target.kills or 0) or 0,
                defenderVeteran = target and (target.veteran and 1 or 0) or 0,
            })

            -- After broadcasting, host should authoritative trigger any mine effects caused by movement
            if moved and attacker then self:triggerMineAt(amsg.toCol, amsg.toRow, attacker) end
        end
    elseif msg.type == "setVeteranRequest" then
        -- Host applies veteran request and broadcasts commit
        if self.isHost then
            local col = tonumber(msg.col)
            local row = tonumber(msg.row)
            local team = tonumber(msg.team)
            local veteranFlag = (msg.veteran == 1 or msg.veteran == true)
            if col and row then
                local piece = self:getPieceAt(col, row)
                if piece and piece.team == team then
                    piece.veteran = veteranFlag
                    if veteranFlag then piece.kills = math.max(3, piece.kills or 3) else piece.kills = 0 end
                    -- Broadcast commit so clients apply the change
                    self:sendCommit({type = "setVeteran", col = col, row = row, team = team, kills = piece.kills or 0, veteran = piece.veteran and 1 or 0})
                end
            end
        end
    elseif msg.type == "placePieceRequest" then
        if self.isHost then
            local team = tonumber(msg.team)
            local col = tonumber(msg.col)
            local row = tonumber(msg.row)
            local unitType = msg.unitType
            if team and col and row then
                -- Try to fill existing unplaced piece
                local filled = false
                for _, piece in ipairs(self.pieces) do
                    if piece.team == team and (not piece.col or piece.col == 0) and (not piece.row or piece.row == 0) then
                        piece:setPosition(col, row)
                        self.piecesPlaced = (self.piecesPlaced or 0) + 1
                        filled = true
                        break
                    end
                end
                if not filled then
                    -- create new piece
                    self:addPiece(unitType or "infantry", team, col, row)
                end
                -- Broadcast commit
                self:sendCommit({type = "placePiece", team = team, col = col, row = row, unitType = unitType})
            end
        end
    elseif msg.type == "placeMineRequest" then
        -- Host should create the mine and broadcast to peers
        if self.isHost then
            local col = tonumber(msg.col)
            local row = tonumber(msg.row)
            local team = tonumber(msg.team)
            pcall(function() print(string.format("[game] recv.placeMineRequest -> team=%s col=%s row=%s", tostring(team), tostring(col), tostring(row))) end)
            if col and row and team then
                -- Only place on land and if no mine exists
                local tile = self.map and self.map:getTile(col, row)
                if tile and tile.isLand and not self:getMineAt(col, row) then
                    local mine = {col = col, row = row, owner = nil, team = team, damage = 5, placedTurn = self.turnCount}
                    mine.revealedTo = mine.revealedTo or {}
                    mine.revealedTo[team] = true
                    -- Attach owner piece if present
                    local ownerPiece = self:getPieceAt(col, row)
                    if ownerPiece and ownerPiece.team == team then
                        mine.owner = ownerPiece
                        ownerPiece.placedMines = ownerPiece.placedMines or {}
                        table.insert(ownerPiece.placedMines, mine)
                    end
                    self:addMine(mine)
                    -- Broadcast commit so all peers create the mine locally
                    pcall(function()
                        print(string.format("[game] host sending placeMine -> team=%s col=%s row=%s", tostring(team), tostring(col), tostring(row)))
                        self:sendCommit({type = "placeMine", col = col, row = row, team = team, damage = mine.damage})
                    end)
                end
            end
        end
    elseif msg.type == "sweepMinesRequest" then
        -- Host should perform sweep and broadcast reveals to peers
        if self.isHost then
            local col = tonumber(msg.col)
            local row = tonumber(msg.row)
            local team = tonumber(msg.team)
            if col and row and team then
                local piece = self:getPieceAt(col, row)
                if piece and piece.team == team then
                    -- Prefer using the piece-based sweep which marks reveals and broadcasts when host
                    self:sweepForMines(piece)
                else
                    -- Fallback: coordinate-based sweep (use provided range or 1)
                    local range = 1
                    if msg.range then range = tonumber(msg.range) or range end

                    local previouslyRevealed = {}
                    for _, m in ipairs(self.mines or {}) do
                        previouslyRevealed[m] = (m.revealedTo and m.revealedTo[team]) and true or false
                    end

                    for _, m in ipairs(self.mines or {}) do
                        if m.col and m.row and m.team ~= team then
                            if self:isWithinRange(col, row, m.col, m.row, range) then
                                m.revealedTo = m.revealedTo or {}
                                m.revealedTo[team] = true
                            end
                        end
                    end

                    for _, m in ipairs(self.mines or {}) do
                        if (m.revealedTo and m.revealedTo[team]) and not previouslyRevealed[m] then
                            pcall(function()
                                self:sendCommit({type = "revealMine", col = m.col, row = m.row, team = team, mineTeam = m.team})
                            end)
                        end
                    end
                end
            end
        end
    elseif msg.type == "disarmMineRequest" then
        -- Host should validate disarm request, disarm the mine and broadcast removal
        if self.isHost then
            local col = tonumber(msg.col)
            local row = tonumber(msg.row)
            local team = tonumber(msg.team)
            if col and row and team then
                local mine = self:getMineAt(col, row)
                if mine and mine.revealedTo and mine.revealedTo[team] and mine.team ~= team then
                    -- Find an adjacent piece of the requesting team that can disarm (engineer)
                    local tile = self.map and self.map:getTile(col, row)
                    local adj = {}
                    if tile and self.map.getNeighbors then
                        adj = self.map:getNeighbors(tile, 1) or {}
                    end
                    local disarmer = nil
                    for _, n in ipairs(adj) do
                        local p = self:getPieceAt(n.col, n.row)
                        if p and p.team == team and p.stats and p.stats.canBuild then
                            disarmer = p
                            break
                        end
                    end
                    if disarmer then
                        -- Perform disarm (will remove mine and reward engineer)
                        self:disarmMine(disarmer, mine)
                        -- Broadcast removal to peers
                        pcall(function()
                            self:sendCommit({type = "removeMine", col = col, row = row})
                        end)
                    end
                end
            end
        end
        elseif msg.type == "placeBaseRequest" then
            if self.isHost then
                local team = tonumber(msg.team)
                local col = tonumber(msg.col)
                local row = tonumber(msg.row)
                local baseType = msg.baseType
                if team and col and row then
                    -- Apply placement locally on host and broadcast commit
                    self:applyPlaceBase(team, col, row, baseType)
                    self:sendCommit({type = "placeBase", team = team, col = col, row = row, baseType = baseType})
                end
            end
    elseif msg.type == "revealMine" then
        local col = tonumber(msg.col)
        local row = tonumber(msg.row)
        local team = tonumber(msg.team)
        if col and row and team then
            local mine = self:getMineAt(col, row)
            local mineOwnerTeam = nil
            if msg.mineTeam then mineOwnerTeam = tonumber(msg.mineTeam) end
            if mine then
                mine.revealedTo = mine.revealedTo or {}
                mine.revealedTo[team] = true
                pcall(function()
                    print(string.format("[game] recv.revealMine -> revealedTo=%s col=%s row=%s (mineTeam=%s)", tostring(team), tostring(col), tostring(row), tostring(mine.team)))
                end)
            else
                -- If client doesn't have the mine yet (missed placeMine), create a placeholder so reveal is visible
                pcall(function()
                    print(string.format("[game] recv.revealMine: no local mine, creating placeholder revealedTo=%s col=%s row=%s mineTeam=%s", tostring(team), tostring(col), tostring(row), tostring(mineOwnerTeam)))
                end)
                local placeholder = {col = col, row = row, owner = nil, team = mineOwnerTeam, damage = 5, placedTurn = self.turnCount}
                placeholder.revealedTo = {}
                placeholder.revealedTo[team] = true
                self:addMine(placeholder)
            end
        end
    elseif msg.type == "revealForest" then
        local col = tonumber(msg.col)
        local row = tonumber(msg.row)
        local team = tonumber(msg.team)
        if col and row and team then
            local piece = self:getPieceAt(col, row)
            if piece then
                piece.revealedTo = piece.revealedTo or {}
                piece.revealedTo[team] = true
                piece.hiddenInForest = false
                pcall(function() print(string.format("[game] recv.revealForest -> team=%s col=%s row=%s unitTeam=%s", tostring(team), tostring(col), tostring(row), tostring(piece.team))) end)
            else
                pcall(function() print(string.format("[game] recv.revealForest: no piece at %s,%s to reveal for team=%s", tostring(col), tostring(row), tostring(team))) end)
            end
        end
    elseif msg.type == "removeMine" then
        local col = tonumber(msg.col)
        local row = tonumber(msg.row)
        if col and row then
            local mine = self:getMineAt(col, row)
            if mine then self:removeMine(mine) end
        end
    elseif msg.type == "airstrikeRequest" then
        if self.isHost then
            local col = tonumber(msg.col)
            local row = tonumber(msg.row)
            local team = tonumber(msg.team)
            local damage = tonumber(msg.damage) or 6
            if col and row and team then
                -- verify can airstrike
                if self:canAirstrike(team, col, row) then
                    -- apply strike
                    local targetPiece = self:getPieceAt(col, row)
                    if targetPiece then
                        local wasKilled = targetPiece:takeDamage(damage)
                        if wasKilled then
                            for i, p in ipairs(self.pieces) do
                                if p == targetPiece then
                                    table.remove(self.pieces, i)
                                    break
                                end
                            end
                        end
                    end
                    -- broadcast commit
                    self:sendCommit({type = "airstrike", col = col, row = row, team = team, damage = damage})
                end
            end
        end
    elseif msg.type == "airstrike" then
        local col = tonumber(msg.col)
        local row = tonumber(msg.row)
        local damage = tonumber(msg.damage) or 6
        if col and row then
            -- Spawn airstrike animation
            local px, py = self.map:gridToPixels(col, row)
            self:spawnMineExplosion(px, py, damage, col, row)
            self:spawnDamageText(px, py, damage, "airstrike")
            
            local targetPiece = self:getPieceAt(col, row)
            if targetPiece then
                local wasKilled = targetPiece:takeDamage(damage)
                if wasKilled then
                    for i, p in ipairs(self.pieces) do
                        if p == targetPiece then
                            table.remove(self.pieces, i)
                            break
                        end
                    end
                end
            end
        end
    elseif msg.type == "mineTriggered" then
        local col = tonumber(msg.col)
        local row = tonumber(msg.row)
        local damage = tonumber(msg.damage) or 0
        local moverCol = tonumber(msg.moverCol)
        local moverRow = tonumber(msg.moverRow)
        local moverTeam = tonumber(msg.moverTeam)
        if col and row and moverCol and moverRow and moverTeam then
            -- Find the piece that stepped on the mine (must be at mover position and be the correct team)
            local piece = nil
            for _, p in ipairs(self.pieces) do
                if p.col == moverCol and p.row == moverRow and p.team == moverTeam then
                    piece = p
                    break
                end
            end
            if piece then
                local wasKilled = piece:takeDamage(damage)
                if wasKilled then
                    for i, p in ipairs(self.pieces) do
                        if p == piece then
                            table.remove(self.pieces, i)
                            break
                        end
                    end
                end
                -- Record the mine trigger in the replay on non-host clients (host already recorded it in triggerMineAt)
                if not self.isHost then
                    local action = {action = "mineTrigger", col = col, row = row, moverCol = moverCol, moverRow = moverRow, moverTeam = moverTeam, moverType = piece.type, damage = damage}
                    self.replay:recordAction(action)
                end
            end
            -- Ensure mine removed locally
            local mine = self:getMineAt(col, row)
            if mine then self:removeMine(mine) end
        end
    elseif msg.type == "buildUnitRequest" then
        if self.isHost then
            local team = tonumber(msg.team)
            local col = tonumber(msg.col)
            local row = tonumber(msg.row)
            local unitType = msg.unitType
            local baseCol = tonumber(msg.baseCol)
            local baseRow = tonumber(msg.baseRow)
            local cost = tonumber(msg.cost) or 0
            if team and col and row and unitType and baseCol and baseRow then
                -- Validate base ownership and target tile
                local base = self:getBaseAt(baseCol, baseRow)
                if not base or base.team ~= team then return end
                local tile = self.map and self.map:getTile(col, row)
                if not tile or not tile.isLand then return end
                if self:getPieceAt(col, row) or self:getBaseAt(col, row) or self:getResourceAt(col, row) then return end
                -- Ensure target is within reasonable range of base (2 tiles)
                if not self:isWithinRange(baseCol, baseRow, col, row, 2) then return end

                -- Oil requirement for tanks
                local oilCost = (unitType == "tank") and 1 or 0
                if (self.teamResources[team] or 0) < cost then return end
                if (self.teamOil[team] or 0) < oilCost then return end

                -- Deduct resources and oil, then create unit
                self.teamResources[team] = self.teamResources[team] - cost
                if oilCost > 0 then self.teamOil[team] = self.teamOil[team] - oilCost end

                self:addPiece(unitType, team, col, row)
                -- Broadcast commit as placePiece
                self:sendCommit({type = "placePiece", team = team, col = col, row = row, unitType = unitType})
            end
        end
    elseif msg.type == "move" then
        self:applyRemoteMove(msg)
    elseif msg.type == "attack" then
        -- Remote performed an attack: apply ammo use, damage, removals and possible move-on-kill
        local fromCol = tonumber(msg.fromCol)
        local fromRow = tonumber(msg.fromRow)
        local toCol = tonumber(msg.toCol)
        local toRow = tonumber(msg.toRow)
        local attackerRolls = msg.attackerRolls or {}
        local defenderRolls = msg.defenderRolls or {}
        local damageToTarget = tonumber(msg.damageToTarget) or 0
        local damageToAttacker = tonumber(msg.damageToAttacker) or 0
        local moved = msg.moved and true or false
        local attacker = self:getPieceAt(fromCol, fromRow)
        local target = self:getPieceAt(toCol, toRow)
        -- Mirror ammo consumption on attacker if present
        if attacker and attacker.useAmmo then attacker:useAmmo() end

        -- Apply authoritative kill/veteran state from host so clients stay in sync
        if msg.attackerKills then
            local ak = tonumber(msg.attackerKills) or msg.attackerKills
            if attacker and ak then attacker.kills = ak end
        end
    elseif msg.type == "setVeteran" then
        -- Commit from host to set veteran state on a piece
        local col = tonumber(msg.col)
        local row = tonumber(msg.row)
        local team = tonumber(msg.team)
        local kills = tonumber(msg.kills) or 0
        local veteranFlag = (msg.veteran == 1 or msg.veteran == true)
        if col and row then
            local piece = self:getPieceAt(col, row)
            if piece then
                piece.kills = kills
                piece.veteran = veteranFlag
            end
        end
        if msg.attackerVeteran then
            if attacker then attacker.veteran = (msg.attackerVeteran == 1 or msg.attackerVeteran == true) end
        end
        if msg.defenderKills then
            local dk = tonumber(msg.defenderKills) or msg.defenderKills
            if target and dk then target.kills = dk end
        end
        if msg.defenderVeteran then
            if target then target.veteran = (msg.defenderVeteran == 1 or msg.defenderVeteran == true) end
        end

        -- Spawn animation (midpoint) if rolls provided
        local ax, ay = self.map:gridToPixels(fromCol, fromRow)
        local bx, by = self.map:gridToPixels(toCol, toRow)
        local mx, my = (ax + bx) / 2, (ay + by) / 2
        if #attackerRolls > 0 or #defenderRolls > 0 then
            local aTeam = tonumber(msg.attackerTeam) or nil
            local dTeam = tonumber(msg.defenderTeam) or nil
            self:spawnCombatAnimation(mx, my, attackerRolls, defenderRolls, aTeam, dTeam)
        end

        -- Apply damage to target
        if target and damageToTarget > 0 then
            local wasKilled = target:takeDamage(damageToTarget)
            if wasKilled then
                for i, p in ipairs(self.pieces) do if p == target then table.remove(self.pieces, i); break end end
            end
            if wasKilled and moved and attacker then
                attacker:setPosition(toCol, toRow)
            end
        else
            if moved and attacker then attacker:setPosition(toCol, toRow) end
        end

        -- Apply damage to attacker (if still present)
        if attacker and damageToAttacker > 0 then
            local wasKilledA = attacker:takeDamage(damageToAttacker)
            if wasKilledA then
                for i, p in ipairs(self.pieces) do if p == attacker then table.remove(self.pieces, i); break end end
            end
        end
    elseif msg.type == "placePiece" then
        -- Remote placed a piece during placement phase: mirror it
        local team = tonumber(msg.team)
        local col = tonumber(msg.col)
        local row = tonumber(msg.row)
        local unitType = msg.unitType
        if team and col and row then
            -- Find first unplaced piece for that team and set position
            for _, piece in ipairs(self.pieces) do
                if piece.team == team and (not piece.col or piece.col == 0) and (not piece.row or piece.row == 0) then
                    piece:setPosition(col, row)
                    self.piecesPlaced = (self.piecesPlaced or 0) + 1
                    break
                end
            end
            -- If no unplaced piece was available, this is a mid-game build: create the piece
            local found = self:getPieceAt(col, row)
            if not found and unitType then
                self:addPiece(unitType, team, col, row)
            else
                -- If we found a piece at this tile, and it was building this unit, clear its building state
                if found and found.isBuilding then
                    found.isBuilding = false
                    found.buildingType = nil
                    found.buildingTurnsRemaining = 0
                    found.buildingTeam = nil
                    found.buildingResourceTarget = nil
                    found.hasMoved = false
                end
            end
        end
    elseif msg.type == "placeMine" then
        -- Host/peer broadcast: create mine if missing
        local col = tonumber(msg.col)
        local row = tonumber(msg.row)
        local team = tonumber(msg.team)
        local damage = tonumber(msg.damage) or 5
        if col and row and team then
            if not self:getMineAt(col, row) then
                local mine = {col = col, row = row, owner = nil, team = team, damage = damage, placedTurn = self.turnCount}
                mine.revealedTo = mine.revealedTo or {}
                mine.revealedTo[team] = true
                self:addMine(mine)
                pcall(function() print(string.format("[game] recv.placeMine -> team=%s col=%s row=%s", tostring(team), tostring(col), tostring(row))) end)
            end
        end
    elseif msg.type == "placeBase" then
        -- Remote placed a base during placement phase: mirror it
        local team = tonumber(msg.team)
        local col = tonumber(msg.col)
        local row = tonumber(msg.row)
        local baseType = msg.baseType
        if team and col and row then
            local placed = self:applyPlaceBase(team, col, row, baseType)
            -- If there is a piece at this tile that was building the base, clear its building state
            local builder = self:getPieceAt(col, row)
            if builder and builder.isBuilding then
                builder.isBuilding = false
                builder.buildingType = nil
                builder.buildingTurnsRemaining = 0
                builder.buildingTeam = nil
                builder.buildingResourceTarget = nil
                builder.hasMoved = false
            end
        end
    elseif msg.type == "startBuilding" then
        -- Host broadcasted startBuilding commit: apply building state on client
        local col = tonumber(msg.col)
        local row = tonumber(msg.row)
        local buildingType = msg.buildingType
        local team = tonumber(msg.team)
        local buildTurns = tonumber(msg.buildTurns)
        if col and row and buildingType and team then
            local piece = self:getPieceAt(col, row)
            if piece then
                piece.isBuilding = true
                piece.buildingType = buildingType
                piece.buildingTurnsRemaining = buildTurns or piece.buildingTurnsRemaining
                piece.buildingTeam = team
                pcall(function() print(string.format("[game] applied commit startBuilding at %d,%d type=%s team=%s turns=%s", col, row, tostring(buildingType), tostring(team), tostring(buildTurns))) end)
            else
                pcall(function() print(string.format("[game] commit startBuilding: no piece at %d,%d", col, row)) end)
            end
        end
    elseif msg.type == "placeDefense" then
        -- Host broadcasted placeDefense commit: create defensive structure on client
        local col = tonumber(msg.col)
        local row = tonumber(msg.row)
        local team = tonumber(msg.team)
        if col and row and team then
            if not self:getDefenseAt(col, row) then
                self:addDefense(col, row, team)
                pcall(function() print(string.format("[game] applied commit placeDefense at %d,%d team=%s", col, row, tostring(team))) end)
            end
        end
    elseif msg.type == "placementPhase" then
        if msg.phase == "bases" then
            pcall(function() print("[game] remote requested entering base placement phase") end)
            self.placementPhase = "bases"
        elseif msg.phase == "ready" then
            pcall(function() print("[game] remote requested entering ready phase") end)
            self.placementPhase = "ready"
        end
    elseif msg.type == "endTurn" then
        -- apply end turn from remote: set current turn to the provided nextTeam
        if msg.nextTeam then
            self.currentTurn = msg.nextTeam
            -- If authoritative resource totals provided, apply them to keep clients in sync
            if msg.teamResources1 then self.teamResources[1] = tonumber(msg.teamResources1) or self.teamResources[1] end
            if msg.teamResources2 then self.teamResources[2] = tonumber(msg.teamResources2) or self.teamResources[2] end
            if msg.teamOil1 then self.teamOil[1] = tonumber(msg.teamOil1) or self.teamOil[1] end
            if msg.teamOil2 then self.teamOil[2] = tonumber(msg.teamOil2) or self.teamOil[2] end
            if self.currentTurn == 1 then
                self.turnCount = self.turnCount + 1
            end
            for _, p in ipairs(self.pieces) do
                if p.team == self.currentTurn then p:resetMove() end
            end
        else
            -- fallback: call endTurn if no nextTeam provided
            self:endTurn()
        end
    elseif msg.type == "ready" then
        if msg.team and (msg.team == 1 or msg.team == 2) then
            self.playerReady[msg.team] = not not msg.ready
            -- If host and both ready, start the game
            if self.isHost and self.playerReady[1] and self.playerReady[2] then
                self.state = "playing"
                self.turnCount = 1
                self.currentTurn = 1
                for _, p in ipairs(self.pieces) do p:resetMove() end
                pcall(function()
                    if Network and Network.send and Network.isConnected and Network.isConnected() then
                        self:sendCommit({type = "startPlay"})
                    end
                end)
            end
        end
    elseif msg.type == "endTurnRequest" then
    
        -- A client asked the host to end their turn. Only the host should process this.
        if self.isHost then
            -- Temporarily clear _applyingRemote so endTurn will send the resulting endTurn message
            local prev = self._applyingRemote
            self._applyingRemote = false
            self:endTurn()
            self._applyingRemote = prev
        end
    elseif msg.type == "startPlay" then
        -- Host told us both players are ready and game should start
        if self.state == "placing" then
            self.state = "playing"
            self.turnCount = 1
            self.currentTurn = 1
            for _, p in ipairs(self.pieces) do p:resetMove() end
            -- Compute air superiority at start of play
            self.airSuperiorityMap = self:calculateAirSuperiorityMap()
            if self.fogOfWar then
                self.fogOfWar:updateVisibility(1, self.pieces, self.bases, self.teamStartingCorners)
                self.fogOfWar:updateVisibility(2, self.pieces, self.bases, self.teamStartingCorners)
            end
        end
    end
    self._applyingRemote = false
end

function Game:applyRemoteMove(msg)
    if not msg then return end
    local fromCol = tonumber(msg.fromCol)
    local fromRow = tonumber(msg.fromRow)
    local toCol = tonumber(msg.toCol)
    local toRow = tonumber(msg.toRow)
    if not fromCol or not fromRow or not toCol or not toRow then return end
    local piece = self:getPieceAt(fromCol, fromRow)
    if not piece then return end
    -- Move without validating team/turn (mirroring remote)
    piece:setPosition(toCol, toRow)
    -- Invoke piece hook for any post-move behavior (host-only side-effects handled inside hook)
    if piece.onMove then
        pcall(function() piece:onMove(self, fromCol, fromRow, toCol, toRow) end)
    end
    -- Trigger mines during live gameplay state only
    if self.state == "playing" then
        self:triggerMineAt(toCol, toRow, piece)
    end
    -- Recalculate valid moves/attacks if this piece is currently selected so UI remains correct
    if self.selectedPiece and self.selectedPiece == piece then
        self:calculateValidMoves()
        -- Only deselect if this is NOT the local player's piece. Keep selection for local team so
        -- players can immediately perform a follow-up attack after a move.
        if not (self.localTeam and piece.team == self.localTeam) then
            piece:deselect(self)
        end
    end
end

-- Helper to send authoritative commit messages (host uses this after applying a request)
function Game:sendCommit(msg)
    if not Network or not Network.send or not Network.isConnected or not Network.isConnected() then return end
    pcall(function()
        -- Temporarily allow sending while inside remote-apply context
        local prev = self._applyingRemote
        self._applyingRemote = false
        Network.send(msg)
        self._applyingRemote = prev
    end)
end

function Game:draw()
    -- Only show the initial replay overlay while the overlay flag is active.
    -- This ensures animations and updates do not run while the overlay is visible.
    if self.state == "replay" and self.replay and self.replay.replayActive and self._replayOverlay then
        love.graphics.setColor(0,0,0,0.6)
        love.graphics.rectangle("fill", 0, 0, love.graphics.getWidth(), love.graphics.getHeight())
        love.graphics.setColor(1,1,1,1)
        love.graphics.printf("Enemy Turn Replay... (Press Space to Skip)", 0, love.graphics.getHeight()/2-20, love.graphics.getWidth(), "center")
        return
    end
    love.graphics.push()
    love.graphics.applyTransform(self.camera:getTransform())
    
    -- Draw map
    self.map:draw(0, 0)

    -- Determine viewer team (localTeam when networked) for visuals and fog
    local viewTeam = self.localTeam or self.currentTurn

    -- -- Draw province fills and region labels
    -- self:drawProvinceBoundaries()
    
    -- Draw starting areas during placement phase (use localTeam view when networked)
    if self.state == "placing" or self.devMode then
        local viewTeam = self.localTeam or self.placementTeam
        self:drawStartingAreas(viewTeam)
    end
    
    -- Draw mountains through fog during placing phase for visibility (not zone_draft)
    if self.state == "placing" then
        local viewTeam = self.localTeam or self.placementTeam
        for col = 1, self.map.cols do
            for row = 1, self.map.rows do
                local tile = self.map:getTile(col, row)
                if tile and tile.terrain == "mountain" then
                    local pixelX, pixelY = self.map:gridToPixels(col, row)
                    -- Draw mountain indicator (small dark square in center)
                    love.graphics.setColor(0.4, 0.4, 0.5, 0.8)
                    love.graphics.circle("fill", pixelX, pixelY, 4)
                    love.graphics.setColor(1, 1, 1, 1)
                end
            end
        end
    end
    
    -- Draw grid coordinates for debugging
    --self:drawGridCoordinates()
    
    -- Draw bases (only draw placed bases)
    for _, base in ipairs(self.bases) do
        if base.col > 0 and base.row > 0 then  -- Only draw if placed
            local drawBase = true
            if self.fogOfWar then
                if base.team ~= viewTeam and not self.fogOfWar:isTileVisible(viewTeam, base.col, base.row) then
                    drawBase = false
                end
            end
            if drawBase then
                local pixelX, pixelY = self.map:gridToPixels(base.col, base.row)
                -- Draw influence radius first so base symbol is rendered on top
                if base.type == "airbase" and base.draw then
                    -- Airbase draw method handles its own radius visualization
                    base:draw(pixelX, pixelY, self.hexSideLength, self)
                else
                    self:drawBaseRadius(base, pixelX, pixelY, viewTeam)
                    base:draw(pixelX, pixelY, self.hexSideLength)
                end
                -- Draw selection ring if selected
                if base == self.actionsButtonContext and self.actionsButtonContextType == "base" then
                    love.graphics.setColor(1, 1, 0, 1) -- Yellow ring
                    love.graphics.setLineWidth(3)
                    love.graphics.circle("line", pixelX, pixelY, self.hexSideLength * 0.8, 16)
                    love.graphics.setLineWidth(1)
                    love.graphics.setColor(1, 1, 1, 1)
                end
            end
        end
    end

    
    
    -- Draw resources
    for _, resource in ipairs(self.resources) do
        local pixelX, pixelY = self.map:gridToPixels(resource.col, resource.row)
        resource:draw(pixelX, pixelY, self.hexSideLength)
    end

    -- Draw mines (show if revealed to viewer or owned by viewer). Color by team and render above resources.
    if self.mines then
        local viewer = viewTeam or (self.localTeam or self.currentTurn)
        for _, mine in ipairs(self.mines) do
            if mine.col and mine.row then
                local revealed = mine.revealedTo and mine.revealedTo[viewer]
                local owned = (mine.team == viewer)
                if revealed or owned then
                    local mx, my = self.map:gridToPixels(mine.col, mine.row)
                    -- team color: team 1 = red, team 2 = blue, fallback gray
                    local r, g, b = 0.5, 0.5, 0.5
                    if mine.team == 1 then r, g, b = 0.85, 0.15, 0.15
                    elseif mine.team == 2 then r, g, b = 0.15, 0.25, 0.85 end
                    love.graphics.setColor(r, g, b)
                    love.graphics.circle("fill", mx, my, self.hexSideLength * 0.17)
                    love.graphics.setColor(math.max(0, r - 0.4), math.max(0, g - 0.4), math.max(0, b - 0.4))
                    love.graphics.circle("line", mx, my, self.hexSideLength * 0.17)
                    love.graphics.setColor(1, 1, 1, 1)
                end
            end
        end
    end
    
    -- Draw defensive structures on tiles
    if self.defenses then
        local viewer = viewTeam or (self.localTeam or self.currentTurn)
        for col, row_data in pairs(self.defenses) do
            for row, defense in pairs(row_data) do
                if defense and defense.col and defense.row then
                    local dx, dy = self.map:gridToPixels(defense.col, defense.row)
                    -- Team colors
                    local r, g, b = 0.5, 0.5, 0.5
                    if defense.team == 1 then r, g, b = 0.85, 0.15, 0.15
                    elseif defense.team == 2 then r, g, b = 0.15, 0.25, 0.85 end
                    
                    -- Draw hollow (outline-only) hex at double previous size
                    local hexSize = self.hexSideLength * 0.8

                    -- Save graphics state we will modify and restore after drawing
                    local pr, pg, pb, pa = love.graphics.getColor()
                    local prevLine = love.graphics.getLineWidth()

                    -- Team-colored dashed outline (no fill)
                    love.graphics.setColor(r, g, b, 1)
                    love.graphics.setLineWidth(3)
                    local dashLength = math.max(6, math.floor(self.hexSideLength * 0.08))
                    local gapLength = math.max(4, math.floor(self.hexSideLength * 0.06))

                    for i = 0, 5 do
                        local angle1 = (i * math.pi / 3) - math.pi / 2
                        local angle2 = ((i + 1) * math.pi / 3) - math.pi / 2
                        local x1 = dx + hexSize * math.cos(angle1)
                        local y1 = dy + hexSize * math.sin(angle1)
                        local x2 = dx + hexSize * math.cos(angle2)
                        local y2 = dy + hexSize * math.sin(angle2)

                        -- Calculate segment length and draw dashes in team color
                        local segLen = math.sqrt((x2-x1)^2 + (y2-y1)^2)
                        if segLen > 0 then
                            local dx_seg = (x2 - x1) / segLen
                            local dy_seg = (y2 - y1) / segLen
                            local t = 0
                            while t < segLen do
                                local dashEnd = math.min(t + dashLength, segLen)
                                local sx = x1 + dx_seg * t
                                local sy = y1 + dy_seg * t
                                local ex = x1 + dx_seg * dashEnd
                                local ey = y1 + dy_seg * dashEnd
                                love.graphics.line(sx, sy, ex, ey)
                                t = dashEnd + gapLength
                            end
                        end
                    end

                    -- Restore previous graphics state
                    love.graphics.setLineWidth(prevLine)
                    love.graphics.setColor(pr, pg, pb, pa)
                end
            end
        end
    end
    
    -- (Visibility updated in Game:update; avoid heavy update here)

    -- Draw air superiority numbers on tiles (show both teams' values, including zeros)
    local asMap = self.airSuperiorityMap or self:calculateAirSuperiorityMap()
    for key, vals in pairs(asMap) do
        local comma = string.find(key, ",")
        if comma then
            local col = tonumber(string.sub(key, 1, comma - 1))
            local row = tonumber(string.sub(key, comma + 1))
            if col and row then
                -- Respect fog of war: only show markers if tile is visible to the viewer team
                if self.fogOfWar and not self.fogOfWar:isTileVisible(viewTeam, col, row) then
                    goto continue_as
                end

                local t1 = vals[1] or 0
                local t2 = vals[2] or 0
                local playerAS = (viewTeam == 1) and t1 or t2
                local enemyAS = (viewTeam == 1) and t2 or t1
                -- Symbolic air superiority markers only (no numeric overlay)
                -- Show symbol when the viewing team has superiority even if enemy has 0
                local symbol = nil
                if playerAS > 0 and playerAS == enemyAS then
                    symbol = "="
                elseif playerAS > enemyAS then
                    symbol = "^"
                elseif enemyAS > playerAS then
                    symbol = "v"
                end
                if symbol then
                    local tile = self.map:getTile(col, row)
                    if tile and tile.points then
                        local px, py = self.map:gridToPixels(col, row)
                        if symbol == "v" then
                            love.graphics.setColor(1, 0, 0)
                        else
                            if viewTeam == 1 then love.graphics.setColor(1, 0, 0) else love.graphics.setColor(0, 0, 1) end
                        end
                        love.graphics.setFont(love.graphics.newFont(14))
                        local w = love.graphics.getFont():getWidth(symbol)
                        local h = love.graphics.getFont():getHeight()
                        love.graphics.print(symbol, px - w/2, py - h/2)
                    end
                end
            end
        end
        ::continue_as::
    end
    
    -- Draw pieces (only draw placed pieces). Respect fog of war for the viewer team.
    for _, piece in ipairs(self.pieces) do
        if piece.col > 0 and piece.row > 0 then  -- Only draw if placed
            local drawPiece = true
            if self.fogOfWar then
                -- Only draw enemy pieces if the tile is visible to the viewer team
                if piece.team ~= viewTeam and not self.fogOfWar:isTileVisible(viewTeam, piece.col, piece.row) then
                    drawPiece = false
                end
            end
            -- If piece is hidden in forest, only reveal to owner or teams that have revealed it
            if piece.hiddenInForest and piece.team ~= viewTeam then
                if not (piece.revealedTo and piece.revealedTo[viewTeam]) then
                    drawPiece = false
                end
            end
            if drawPiece then
                -- Use interpolated position during animation
                local drawCol, drawRow = piece:getAnimationPosition()
                local pixelX, pixelY = self.map:gridToPixels(drawCol, drawRow)
                -- Pass game object to draw method so special units (like SAM) can render effects
                piece:draw(pixelX, pixelY, self.hexSideLength)
                if piece.type == "sam" then
                    piece:drawIcon(pixelX, pixelY, self.hexSideLength, self)
                end
            end
        end
    end
    
    -- Draw valid moves if a piece is selected
    -- Draw combat animations (dice rolls) on top of pieces
    self:drawCombatAnimations()
    self:drawExplosions()
    self:drawDamageText()
    if self.selectedPiece then
        self:drawValidMoves()
    end
    
    -- Draw valid placement tiles during placement phase
    if self.state == "placing" then
        self:drawValidPlacementTiles()
    end
    
    -- Debug: Draw line of sight visualization for selected piece
    -- if self.selectedPiece and self.selectedPiece.col > 0 and self.selectedPiece.row > 0 then
    --     local sourceHex = self.map:getTile(self.selectedPiece.col, self.selectedPiece.row)
    --     if sourceHex then
    --         local visionRange = self.selectedPiece:getMovementRange() or 3
    --         self.map:drawLineOfSightDebug(sourceHex, visionRange, 0, 0)
    --     end
    -- Draw existing waypoint paths for all pieces (only for current team)
    for _, piece in ipairs(self.pieces) do
        -- Only show waypoints for pieces belonging to the current turn (not visible to enemy)
        if piece.team == self.currentTurn and piece.waypoints and #piece.waypoints > 0 then
            -- Get the final destination (last waypoint)
            local finalWp = piece.waypoints[#piece.waypoints]
            
                -- Get the full quickest path (minimize movement turns) from current position to final destination
            local fullPath = self:findQuickestPath(piece.col, piece.row, finalWp.col, finalWp.row, piece.team, piece.stats.moveRange)
            
            if fullPath and #fullPath > 0 then
                -- Prepend current position to draw the complete path
                local completePath = {{col = piece.col, row = piece.row}}
                for _, pathTile in ipairs(fullPath) do
                    table.insert(completePath, pathTile)
                end
                
                -- Team-colored paths
                local teamColor
                if piece.team == 1 then
                    teamColor = {1, 0.3, 0.3, 0.4}  -- Red for team 1
                else
                    teamColor = {0.3, 0.3, 1, 0.4}  -- Blue for team 2
                end
                
                -- Draw line through all hex centers in the complete path
                self:drawPathLine(completePath, teamColor, 3)
                
                -- Draw circle at the final waypoint target
                local px, py = self.map:gridToPixels(finalWp.col, finalWp.row)
                love.graphics.setColor(teamColor[1], teamColor[2], teamColor[3], 1)
                love.graphics.circle("line", px, py, self.hexSideLength * 0.4)
                love.graphics.setColor(1,1,1,1)
            end
        end
    end
    
    -- Draw action menu on top of pieces and overlays
    if self.actionMenu then
        self:drawActionMenu()
    end

    -- During placement, show fog for the local player (or placementTeam if not networked)
    local viewTeam = self.localTeam or self.placementTeam
    self.fogOfWar:draw(viewTeam, self.camera, 0, 0)

    -- Draw airstrike targeting crosshair (world-space; drawn under UI)
    if self.airstrikeTargeting then
        local mx, my = love.mouse.getPosition()
        local wx, wy = self.camera:screenToWorld(mx, my)
        local tcol, trow = self.map:pixelsToGrid(wx, wy)
        if tcol and trow then
            local px, py = self.map:gridToPixels(tcol, trow)
            local allowed = false
            pcall(function() allowed = self:canAirstrike(self.airstrikeTargeting.team, tcol, trow) end)
            if allowed then
                love.graphics.setColor(0, 1, 0, 0.9)
            else
                love.graphics.setColor(1, 0, 0, 0.9)
            end
            local radius = self.hexSideLength * 0.6
            love.graphics.setLineWidth(2)
            love.graphics.circle("line", px, py, radius)
            love.graphics.line(px - radius, py, px + radius, py)
            love.graphics.line(px, py - radius, px, py + radius)
            love.graphics.setLineWidth(1)
            love.graphics.setColor(1,1,1,1)
        end
    end

    love.graphics.pop()
    
    -- Draw UI (always on screen)
    self:drawUI()
    -- Draw global dev placement UI when applicable
    self:drawDevPlacementUI()
end


-- Draw dev placement button/menu globally for dev single-player (buttons with backgrounds)
function Game:drawDevPlacementUI()
    if not self.devMode then return end
    local offline = not (Network and Network.isConnected and Network.isConnected and Network.isConnected())
    if not offline then return end

    local btnW, btnH = 120, 28
    local bx = love.graphics.getWidth() - btnW - 16
    local by = 16 + 40
    love.graphics.setColor(0.1, 0.1, 0.1, 0.9)
    love.graphics.rectangle("fill", bx, by, btnW, btnH, 6, 6)
    love.graphics.setColor(1,1,1,1)
    love.graphics.printf("Dev Placement", bx, by + 6, btnW, "center")

    if self.devPlacementMenuOpen then
        local options, bW, bH, pad = self:getDevPlacementOptions()
        local menuX = bx - bW - 8
        local menuY = by

        -- Draw backdrop to block clicks through the menu
        local totalH = #options * (bH + pad) - pad
        love.graphics.setColor(0.06, 0.06, 0.06, 0.95)
        love.graphics.rectangle("fill", menuX - 6, menuY - 6, bW + 12, totalH + 12, 6, 6)

        local menu = NewMenu.new(menuX, menuY, options, {buttonWidth = bW, buttonHeight = bH, padding = pad})
        menu:draw()
    end
end


-- Return options for the dev placement menu so drawing and input share the same layout
function Game:getDevPlacementOptions()
    local buttonWidth = 100
    local buttonHeight = 24
    local padding = 4
    local options = {}
    local units = {"infantry", "engineer", "sniper", "tank", "commander", "sam"}
    for _, unit in ipairs(units) do
        table.insert(options, {
            label = unit,
            onClick = function()
                self.devPlacementSelected = { kind = "unit", name = unit }
            end
        })
    end
    local bases = {"hq", "ammoDepot", "supplyDepot", "airbase"}
    for _, base in ipairs(bases) do
        table.insert(options, {
            label = base,
            onClick = function()
                self.devPlacementSelected = { kind = "base", name = base }
            end
        })
    end
    table.insert(options, {
        label = "defense",
        onClick = function()
            self.devPlacementSelected = { kind = "defense" }
        end
    })
    table.insert(options, {
        label = "Toggle Veteran",
        onClick = function()
            local sel = self.selectedPiece
            if sel then
                local toggleTo = not sel.veteran
                sel.veteran = toggleTo
                if toggleTo then sel.kills = math.max(3, sel.kills or 3) else sel.kills = 0 end
                if self.isHost and Network and Network.isConnected and Network.isConnected() and not self._applyingRemote then
                    self:sendCommit({type = "setVeteran", col = sel.col, row = sel.row, team = sel.team, kills = sel.kills or 0, veteran = sel.veteran and 1 or 0})
                elseif Network and Network.isConnected and Network.isConnected() and not self.isHost and not self._applyingRemote then
                    pcall(function() Network.send({type = "setVeteranRequest", col = sel.col, row = sel.row, team = sel.team, veteran = sel.veteran and 1 or 0}) end)
                end
            end
        end
    })
    return options, buttonWidth, buttonHeight, padding
end

-- Draw dev placement button/menu globally for dev single-player
-- Dev placement menu removed



function Game:drawValidMoves()
    -- Only draw if we have valid moves/attacks calculated
    if not self.validMoves or not self.validAttacks then return end
    
    -- Draw valid movement tiles
    love.graphics.setColor(0, 1, 0, 0.3)
    for _, move in ipairs(self.validMoves) do
        local tile = self.map:getTile(move.col, move.row)
        if tile then
            local points = tile.points
            love.graphics.polygon("fill", points)
        end
    end
    
    -- Draw valid attack tiles
    love.graphics.setColor(1, 0, 0, 0.3)
    for _, attack in ipairs(self.validAttacks) do
        local tile = self.map:getTile(attack.col, attack.row)
        if tile then
            local points = tile.points
            love.graphics.polygon("fill", points)
        end
    end
end

-- Helper method to draw a path line through hex centers
function Game:drawPathLine(pathTiles, teamColor, lineWidth)
    if not pathTiles or #pathTiles == 0 then return end
    
    love.graphics.setLineWidth(lineWidth or 3)
    love.graphics.setColor(teamColor[1], teamColor[2], teamColor[3], teamColor[4] or 0.4)
    
    for i = 1, #pathTiles - 1 do
        local p1x, p1y = self.map:gridToPixels(pathTiles[i].col, pathTiles[i].row)
        local p2x, p2y = self.map:gridToPixels(pathTiles[i+1].col, pathTiles[i+1].row)
        love.graphics.line(p1x, p1y, p2x, p2y)
    end
    
    love.graphics.setLineWidth(1)
end

function Game:drawValidPlacementTiles()
    -- Highlight valid placement tiles for the local team or current placementTeam
    local team = self.localTeam or self.placementTeam
    love.graphics.setColor(0, 1, 0, 0.2)
    for col = 1, self.map.cols do
        for row = 1, self.map.rows do
            if self:isInStartingArea(col, row, team) then
                local tile = self.map:getTile(col, row)
                if tile and tile.isLand and not self:getPieceAt(col, row) and not self:getBaseAt(col, row) and not self:getResourceAt(col, row) then
                    local points = tile.points
                    love.graphics.polygon("fill", points)
                end
            end
        end
    end
end

function Game:drawStartingAreas(viewTeam)
    -- If sector picking is enabled, draw sectors instead of rectangular strips
    if self.startSectors and #self.startSectors > 0 and (self.selectedStartSector and (not self.selectedStartSector[1] or not self.selectedStartSector[2])) then
        self:drawStartSectors(viewTeam)
        return
    end

    -- Only draw old rectangular zones for non-radial maps during placement phase
    if self.state ~= "placing" or self.mapGeneratorUsed == "radial" then
        return
    end

    -- Fallback: Draw starting area indicators for both teams (top and bottom strips)
    for team, area in pairs(self.teamStartingAreas) do
        -- Determine color based on team and whether it's the current placement team
        local isCurrentTeam = false
        if viewTeam then
            isCurrentTeam = (team == viewTeam)
        else
            isCurrentTeam = (team == self.placementTeam)
        end
        local alpha = isCurrentTeam and 0.3 or 0.15
        local r, g, b = team == 1 and 1 or 0, 0, team == 1 and 0 or 1  -- Red for team 1, Blue for team 2
        
        -- Draw fill for starting area
        love.graphics.setColor(r, g, b, alpha)
        for col = 1, self.mapWidth do
            for row = area.rowStart, area.rowEnd do
                local tile = self.map:getTile(col, row)
                if tile and tile.isLand and tile.points then
                    love.graphics.polygon("fill", tile.points)
                end
            end
        end
        
        -- Draw outline for the view team's starting area
        if isCurrentTeam then
            love.graphics.setColor(r, g, b, 0.6)
            for col = 1, self.mapWidth do
                for row = area.rowStart, area.rowEnd do
                    local tile = self.map:getTile(col, row)
                    if tile and tile.isLand and tile.points then
                        love.graphics.polygon("line", tile.points)
                    end
                end
            end
        end
    end
end

function Game:drawBaseRadius(base, pixelX, pixelY, viewTeam)
    -- Skip drawing radius for HQ, Ammo Depot, Supply Depot
    -- Airbase handles its own radius drawing in its draw method
    if base.type == "hq" or base.type == "ammoDepot" or base.type == "supplyDepot" or base.type == "airbase" then
        return
    end

    -- Draw hexagons within the base's influence radius, respecting terrain
    local radius = base:getRadius()

    -- Use getHexesWithinRange which respects terrain passability
    -- Pass base's team so enemy pieces don't block the visualization
    local visited = {}
    self:getHexesWithinRange(base.col, base.row, radius, visited, base.team)

    -- Only show radius for bases belonging to the viewer's team
    local viewer = viewTeam or (self.localTeam or self.currentTurn)
    if base.team ~= viewer then
        return
    end

    -- Fill the tiles with a faint team-colored overlay
    local r, g, b = 0.8, 0.8, 0.8
    if base.getColor then r, g, b = base:getColor() end
    love.graphics.setColor(r, g, b, 0.12)
    for _, hex in ipairs(visited) do
        local tile = self.map:getTile(hex.col, hex.row)
        if tile and tile.points then
            love.graphics.polygon("fill", tile.points)
        end
    end

    -- Draw outline for hexes in range
    love.graphics.setColor(r, g, b, 0.4)
    for _, hex in ipairs(visited) do
        local tile = self.map:getTile(hex.col, hex.row)
        if tile and tile.points then
            love.graphics.polygon("line", tile.points)
        end
    end
    love.graphics.setColor(1,1,1,1)
end

function Game:drawUI()
    love.graphics.setColor(1, 1, 1)
    love.graphics.setFont(love.graphics.newFont(14))
    
    if self.state == "zone_draft" then
        -- Zone draft phase UI
        love.graphics.setFont(love.graphics.newFont(18))
        love.graphics.setColor(1, 1, 1)
        love.graphics.print("Zone Draft Phase", 10, 10)
        
        love.graphics.setFont(love.graphics.newFont(14))
        local draftTeam = self.zoneDraftTeam
        local teamName = (draftTeam == 1) and "Red" or "Blue"
        local teamColor = (draftTeam == 1) and {1, 0.2, 0.2} or {0.2, 0.4, 1}
        
        love.graphics.setColor(teamColor[1], teamColor[2], teamColor[3])
        love.graphics.print(string.format("Team %s: Select a starting zone", teamName), 10, 40)
        
        love.graphics.setFont(love.graphics.newFont(11))
        love.graphics.setColor(1, 1, 1)
        love.graphics.print("Click on a highlighted zone to select it.", 10, 65)
        
        -- Show which team has already selected
        for team = 1, 2 do
            if self.teamZoneSelected[team] then
                local tname = (team == 1) and "Red" or "Blue"
                local tsectorId = self.selectedStartSector[team]
                love.graphics.setColor((team == 1) and {1, 0.2, 0.2} or {0.2, 0.4, 1})
                love.graphics.print(string.format("Team %s selected zone %d", tname, tsectorId or 0), 10, 85 + (team * 18))
            end
        end
    elseif self.state == "placing" then
        -- Placement phase UI (simultaneous)
        local team1Placed, team2Placed = 0, 0
        for _, piece in ipairs(self.pieces) do
            if piece.team == 1 and piece.col > 0 and piece.row > 0 then team1Placed = team1Placed + 1 end
            if piece.team == 2 and piece.col > 0 and piece.row > 0 then team2Placed = team2Placed + 1 end
        end
        local rem1 = math.max(0, self.piecesPerTeam - team1Placed)
        local rem2 = math.max(0, self.piecesPerTeam - team2Placed)
        love.graphics.print("Placement Phase - Simultaneous", 10, 10)
        if self.placementPhase == "pieces" then
            love.graphics.print(string.format("Team Red remaining: %d  |  Ready: %s", rem1, tostring(self.playerReady[1])), 10, 32)
            love.graphics.print(string.format("Team Blue remaining: %d  |  Ready: %s", rem2, tostring(self.playerReady[2])), 10, 52)
            love.graphics.setFont(love.graphics.newFont(10))
            love.graphics.print("Place your pieces on your starting area. Click the Ready button when done.", 10, 74)
            -- Dev-mode control hint
            if self.devMode then
                local ctrl = "Both"
                if self.localTeam == 1 then ctrl = "Red" elseif self.localTeam == 2 then ctrl = "Blue" end
                love.graphics.setFont(love.graphics.newFont(10))
                love.graphics.print(string.format("Dev Control: %s  (Tab to toggle placement team; 1/2 to lock team; 0 for both)", ctrl), 10, 92)
                -- Dev placement hint (button moved to top-right for dev single-player)
            end
        else
            -- Base placement phase
            local team1Bases, team2Bases = 0, 0
            for _, b in ipairs(self.bases) do
                if b.team == 1 and b.col > 0 and b.row > 0 then team1Bases = team1Bases + 1 end
                if b.team == 2 and b.col > 0 and b.row > 0 then team2Bases = team2Bases + 1 end
            end
            local brem1 = math.max(0, self.basesPerTeam - team1Bases)
            local brem2 = math.max(0, self.basesPerTeam - team2Bases)
            love.graphics.print(string.format("Team Red bases remaining: %d", brem1), 10, 32)
            love.graphics.print(string.format("Team Blue bases remaining: %d", brem2), 10, 52)
            love.graphics.setFont(love.graphics.newFont(10))
            -- If we placed into a slot, cache tiles for airbase radius
            if placedBase and placedBase.type == "airbase" and self.getTilesWithinRadius then
                placedBase._tilesInRadius = self:getTilesWithinRadius(placedBase.col, placedBase.row, placedBase:getRadius())
            end
            love.graphics.print("Place your bases (HQ, Ammo, Supply, Airbase) on your starting area.", 10, 74)
            if self.devMode then
                local ctrl = "Both"
                if self.localTeam == 1 then ctrl = "Red" elseif self.localTeam == 2 then ctrl = "Blue" end
                love.graphics.setFont(love.graphics.newFont(10))
                love.graphics.print(string.format("Dev Control: %s  (Tab to toggle placement team; 1/2 to lock team; 0 for both)", ctrl), 10, 92)
            end
        end

        -- Draw Ready button for local player
        local btnW, btnH = 120, 32
        local bx = love.graphics.getWidth() - btnW - 16
        local by = 16
        local lt = self.localTeam or 0
        if lt >= 1 and lt <= 2 then
            if self.playerReady[lt] then
                love.graphics.setColor(0.2, 0.6, 0.2)
                love.graphics.rectangle("fill", bx, by, btnW, btnH, 6, 6)
                love.graphics.setColor(1,1,1)
                love.graphics.print("Ready (Unset)", bx + 12, by + 8)
            else
                love.graphics.setColor(0.2, 0.2, 0.25)
                love.graphics.rectangle("fill", bx, by, btnW, btnH, 6, 6)
                love.graphics.setColor(1,1,1)
                love.graphics.print("Ready", bx + 36, by + 8)
            end
        end
    else
        -- Normal gameplay UI
        local teamColor = self.currentTurn == 1 and "Red" or "Blue"
        love.graphics.print("Team: " .. teamColor .. " | Turn: " .. self.turnCount, 10, 10)
        love.graphics.print("Resources: " .. (self.teamResources[self.currentTurn] or 0) .. "  Oil: " .. (self.teamOil[self.currentTurn] or 0), 10, 30)
        -- Show unit count / capacity for current team
        local unitCount = self:getUnitCount(self.currentTurn)
        local unitCapacity = self:getUnitCapacity(self.currentTurn)
        local capacityText = unitCapacity > 0 and string.format("Units: %d / %d", unitCount, unitCapacity) or string.format("Units: %d", unitCount)
        love.graphics.print(capacityText, 10, 50)
        
        -- Count bases for current team
        local hqCount = 0
        local ammoDepotCount = 0
        local supplyDepotCount = 0
        for _, base in ipairs(self.bases) do
            if base.team == self.currentTurn and base.col > 0 and base.row > 0 then
                if base.type == "hq" then
                    hqCount = hqCount + 1
                elseif base.type == "ammoDepot" then
                    ammoDepotCount = ammoDepotCount + 1
                elseif base.type == "supplyDepot" then
                    supplyDepotCount = supplyDepotCount + 1
                end
            end
        end
        -- Draw bottom Actions button when a selection/context is available
            if self.actionsButtonVisible then
                local btnW, btnH = 140, 36
                local bx = love.graphics.getWidth() - btnW - 16
                local by = love.graphics.getHeight() - btnH - 12
                local disabled = true
                if self.actionsButtonContext then
                    local opts = self:getActionOptions(self.actionsButtonContext, self.actionsButtonContextType)
                    if opts and #opts > 0 then disabled = false end
                end
                if disabled then
                    love.graphics.setColor(0.45, 0.45, 0.45, 0.95)
                else
                    love.graphics.setColor(0.18, 0.18, 0.22, 0.95)
                end
                love.graphics.rectangle("fill", bx, by, btnW, btnH, 8, 8)
                love.graphics.setColor(1,1,1,1)
                local label = disabled and "Actions (none)" or "Actions"
                love.graphics.setFont(love.graphics.newFont(14))
                love.graphics.printf(label, bx, by + 8, btnW, "center")

                -- Draw actions panel via reusable menu when open
                if self.actionsPanelOpen and self.actionsPanelOptions and #self.actionsPanelOptions > 0 then
                    local opts = self.actionsPanelOptions
                    -- Set affordability and labels
                    local team = self.actionsButtonContext and self.actionsButtonContext.team or self.currentTurn
                    for _, opt in ipairs(opts) do
                        opt.label = opt.name
                        -- Check resource affordability
                        if not opt.disabled and opt.cost and opt.cost > 0 then
                            if (self.teamResources[team] or 0) < opt.cost then
                                opt.disabled = true
                            end
                        end
                        -- Check oil affordability
                        if not opt.disabled and opt.oilCost and opt.oilCost > 0 then
                            if (self.teamOil[team] or 0) < opt.oilCost then
                                opt.disabled = true
                            end
                        end
                        -- Build display label with costs
                        local costParts = {}
                        if opt.cost and opt.cost > 0 then
                            table.insert(costParts, opt.cost .. (opt.costType == "oil" and "O" or "R"))
                        end
                        if opt.oilCost and opt.oilCost > 0 then
                            table.insert(costParts, opt.oilCost .. "O")
                        end
                        if #costParts > 0 then
                            opt.displayLabel = opt.label .. " (" .. table.concat(costParts, " + ") .. ")"
                        else
                            opt.displayLabel = opt.label
                        end
                        opt.onClick = function() self:executeAction(opt) end
                    end
                    -- Calculate max button width
                    local maxWidth = 0
                    local font = love.graphics.getFont()
                    for _, opt in ipairs(opts) do
                        local w = font:getWidth(opt.displayLabel)
                        if w > maxWidth then maxWidth = w end
                    end
                    local buttonWidth = math.max(120, maxWidth + 20)  -- padding for text
                    local panelW = buttonWidth
                    local panelX = bx - panelW - 8
                    local numOpts = #opts
                    local buttonH = 24
                    local padding = 4
                    local panelH = numOpts * (buttonH + padding) - padding  -- approximate
                    local panelY = by - panelH - 8
                    local menu = NewMenu.new(panelX, panelY, opts, {buttonWidth = buttonWidth, buttonHeight = buttonH, padding = padding})
                    menu:draw()
                    self.actionsPanelMenu = menu
                else
                    self.actionsPanelMenu = nil
                end
            end
        local basesInfo = string.format("Bases: HQ: %d | Ammo: %d | Supply: %d", hqCount, ammoDepotCount, supplyDepotCount)
        love.graphics.setFont(love.graphics.newFont(12))
        love.graphics.print(basesInfo, 10, 70)
        
        -- Show building engineers for current team
        local yOffset = 90
        love.graphics.setFont(love.graphics.newFont(11))
        for _, piece in ipairs(self.pieces) do
            if piece.team == self.currentTurn and piece.isBuilding and piece.buildingTurnsRemaining then
                local buildingName = piece.buildingType == "resource_mine" and "Metal Mine" or
                                   piece.buildingType == "ammoDepot" and "Ammo Depot" or
                                   piece.buildingType == "supplyDepot" and "Supply Depot" or
                                   piece.buildingType == "airbase" and "Airbase" or
                                   "Structure"
                local buildText = string.format("Engineer building: %s (%d turns)", buildingName, piece.buildingTurnsRemaining)
                love.graphics.print(buildText, 10, yOffset)
                yOffset = yOffset + 15
            end
        end
        
        love.graphics.setFont(love.graphics.newFont(14))
        
        -- Draw selected piece info
        if self.selectedPiece then
            local info = string.format("Selected: %s (HP: %d/%d)", 
                self.selectedPiece.stats.name, 
                self.selectedPiece.hp, 
                self.selectedPiece.maxHp)
            love.graphics.print(info, 10, yOffset)
            yOffset = yOffset + 20
            
            -- Show building status if building
            if self.selectedPiece.isBuilding then
                local buildingName = self.selectedPiece.buildingType == "resource_mine" and "Metal Mine" or
                                   self.selectedPiece.buildingType == "ammoDepot" and "Ammo Depot" or
                                   self.selectedPiece.buildingType == "supplyDepot" and "Supply Depot" or
                                   self.selectedPiece.buildingType == "airbase" and "Airbase" or
                                   "Structure"
                local buildInfo = string.format("Building: %s (%d turns left)",
                    buildingName,
                    self.selectedPiece.buildingTurnsRemaining or 0)
                love.graphics.print(buildInfo, 10, yOffset)
                yOffset = yOffset + 20
                love.graphics.setFont(love.graphics.newFont(10))
                local controlsY = yOffset
                love.graphics.print("Click to select piece | Right-click to move | E: End Turn | R: Reset", 10, controlsY)
            else
                -- Show ammo and supply
                local ammoInfo = string.format("Ammo: %d/%d | Supply: %d/%d", 
                    self.selectedPiece.ammo,
                    self.selectedPiece.maxAmmo,
                    self.selectedPiece.supply,
                    self.selectedPiece.maxSupply)
                love.graphics.print(ammoInfo, 10, yOffset)
                yOffset = yOffset + 20
                
                -- Draw controls
                love.graphics.setFont(love.graphics.newFont(10))
                local controlsY = yOffset
                love.graphics.print("Click to select piece | Right-click to move | E: End Turn | R: Reset", 10, controlsY)
            end
        else
            -- Draw controls
            love.graphics.setFont(love.graphics.newFont(10))
            local controlsY = yOffset
            love.graphics.print("Click to select piece | Right-click to move | E: End Turn | R: Reset", 10, controlsY)
        end
    
        -- Hotseat pass overlay (blocks input until accepted)
        if self.passPending then
            local w = love.graphics.getWidth()
            local h = love.graphics.getHeight()
            love.graphics.setColor(0, 0, 0, 0.6)
            love.graphics.rectangle("fill", 0, 0, w, h)
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.setFont(love.graphics.newFont(20))
            local nextTeam = self.pendingNextTeam or (self.currentTurn == 1 and 2 or 1)
            local teamName = nextTeam == 1 and "Red" or "Blue"
            local msg = "Pass to " .. teamName .. " — Press Enter or Space to continue"
            local tw = love.graphics.getFont():getWidth(msg)
            love.graphics.print(msg, math.floor((w - tw) / 2), math.floor(h / 2 - 10))
        end
    end
end

function Game:mousepressed(x, y, button)
    -- Check shift key for waypoint mode
    local shift = love.keyboard.isDown("lshift") or love.keyboard.isDown("rshift")
    
    -- Check ready button click in screen coordinates first (UI sits above camera)
    if self.state == "placing" and self.localTeam then
        local btnW, btnH = 120, 32
        local bx = love.graphics.getWidth() - btnW - 16
        local by = 16
        if x >= bx and x <= bx + btnW and y >= by and y <= by + btnH then
            -- Toggle ready for local team
            local t = self.localTeam
            self.playerReady[t] = not self.playerReady[t]
            pcall(function()
                if Network and Network.send and Network.isConnected and Network.isConnected() then
                    Network.send({type = "ready", team = t, ready = self.playerReady[t]})
                end
            end)
            -- If host or offline (single-player/dev) and both ready, start the game
            local offline = not (Network and Network.isConnected and Network.isConnected and Network.isConnected())
            if (self.isHost or offline) and self.playerReady[1] and self.playerReady[2] then
                self.state = "playing"
                self.turnCount = 1
                self.currentTurn = 1
                for _, p in ipairs(self.pieces) do p:resetMove() end
                pcall(function()
                    if Network and Network.send and Network.isConnected and Network.isConnected() then
                        self:sendCommit({type = "startPlay"})
                    end
                end)
            end
            return
        end
    end
    -- Dev placement button click (visible when devMode) - buttons with backgrounds
    if self.devMode then
        local btnW, btnH = 120, 28
        local bx = love.graphics.getWidth() - btnW - 16
        local by = 16 + 40
        if x >= bx and x <= bx + btnW and y >= by and y <= by + btnH then
            self.devPlacementMenuOpen = not self.devPlacementMenuOpen
            return  -- Consume this click, do NOT process map placement
        end
        if self.devPlacementMenuOpen then
            local options, bW, bH, pad = self:getDevPlacementOptions()
            local menuX = bx - bW - 8
            local menuY = by
            local menu = NewMenu.new(menuX, menuY, options, {buttonWidth = bW, buttonHeight = bH, padding = pad})
            if menu:handleClick(x, y) then
                return  -- Consume menu item click
            end

            -- Consume clicks anywhere in the menu backdrop so clicks don't fall through to the map
            local totalH = #options * (bH + pad) - pad
            if x >= menuX and x <= menuX + bW and y >= menuY and y <= menuY + totalH then
                return  -- Consume click in menu area
            end
        end
    end

    -- Check bottom Actions button click (screen coordinates) before converting to world coords
    if self.actionsButtonVisible then
        local btnW, btnH = 140, 36
        local bx = love.graphics.getWidth() - btnW - 16
        local by = love.graphics.getHeight() - btnH - 12
        if x >= bx and x <= bx + btnW and y >= by and y <= by + btnH then
            -- Toggle/handle actions panel via button
            if self.actionsPanelOpen then
                self.actionsPanelOpen = false
                self.actionsPanelOptions = nil
            else
                if self.actionsButtonContext then
                    local opts = self:getActionOptions(self.actionsButtonContext, self.actionsButtonContextType)
                    self.actionsPanelOptions = opts
                    self.actionsPanelOpen = true
                end
            end
            return
        end

        -- If actions panel open, check for clicks via NewMenu instance
        if self.actionsPanelOpen and self.actionsPanelMenu then
            if self.actionsPanelMenu:handleClick(x, y) then
                return
            end
        end
    end
    local worldX, worldY = self.camera:screenToWorld(x, y)
    local col, row = self.map:pixelsToGrid(worldX, worldY)
    -- Block input while waiting for hotseat pass
    if self.passPending then
        return
    end
    -- Dev placement quick placement (if an item selected from dev menu)
    if self.devPlacementSelected and button == 1 then
        local sel = self.devPlacementSelected
        local teamArg = self.localTeam or self.placementTeam or self.currentTurn
        local tile = self.map and self.map:getTile(col, row)
        if tile and tile.isLand then
            if sel.kind == "unit" then
                if not self:getPieceAt(col, row) and not self:getBaseAt(col, row) and not self:getResourceAt(col, row) then
                    self:addPiece(sel.name, teamArg, col, row)
                    if self.isHost and Network and Network.isConnected and Network.isConnected() then
                        pcall(function() self:sendCommit({type = "placePiece", team = teamArg, col = col, row = row, unitType = sel.name}) end)
                    end
                    if self.fogOfWar then
                        self.fogOfWar:updateVisibility(teamArg, self.pieces, self.bases, self.teamStartingCorners)
                    end
                    self.devPlacementSelected = nil
                    self.devPlacementMenuOpen = false
                end
            elseif sel.kind == "base" then
                if not self:getBaseAt(col, row) and not self:getResourceAt(col, row) then
                    self:applyPlaceBase(teamArg, col, row, sel.name)
                    if self.isHost and Network and Network.isConnected and Network.isConnected() then
                        pcall(function() self:sendCommit({type = "placeBase", team = teamArg, col = col, row = row, baseType = sel.name}) end)
                    end
                    if self.fogOfWar then
                        self.fogOfWar:updateVisibility(teamArg, self.pieces, self.bases, self.teamStartingCorners)
                    end
                    self.devPlacementSelected = nil
                    self.devPlacementMenuOpen = false
                end
            elseif sel.kind == "defense" then
                if not self:getDefenseAt(col, row) then
                    self:addDefense(col, row, teamArg)
                    if self.isHost and Network and Network.isConnected and Network.isConnected() then
                        pcall(function() self:sendCommit({type = "placeDefense", team = teamArg, col = col, row = row}) end)
                    end
                    self.devPlacementSelected = nil
                    self.devPlacementMenuOpen = false
                end
            end
        end
        return
    end
    -- If this instance represents a networked player, only allow input for that player's team
    if self.localTeam then
        if self.state == "playing" then
            if self.currentTurn ~= self.localTeam then
                pcall(function() print(string.format("[game] input blocked: playing currentTurn=%s localTeam=%s", tostring(self.currentTurn), tostring(self.localTeam))) end)
                return
            end
        end
        -- During placement, `localTeam` is allowed to place simultaneously (no block)
    end
    -- Dev quick-placement removed

    if self.state == "zone_draft" then
        -- Zone draft phase: select starting zone
        if button == 1 then  -- Left click
            local key = tostring(col) .. "," .. tostring(row)
            local sIdx = nil
            if self.tileToSector then sIdx = self.tileToSector[key] end
            if sIdx then
                -- Check if this zone is in the current drafting team's revealed candidates
                local draftTeam = self.zoneDraftTeam
                local isRevealed = false
                if self.revealedCandidates and self.revealedCandidates[draftTeam] then
                    for _, rid in ipairs(self.revealedCandidates[draftTeam]) do
                        if rid == sIdx then isRevealed = true; break end
                    end
                end
                
                if isRevealed then
                    -- Team selects this zone
                    self.selectedStartSector[draftTeam] = sIdx
                    self.teamZoneSelected[draftTeam] = true
                    pcall(function() print(string.format("[zone_draft] team %s selected start sector %s", tostring(draftTeam), tostring(sIdx))) end)
                    
                    -- Mark sector as chosen
                    if self.startSectors[sIdx] then
                        self.startSectors[sIdx].chosen = true
                    end
                    
                    -- Move this team to placement phase
                    self.teamInPlacement[draftTeam] = true
                    
                    -- Move to next team in draft, or end draft if both selected
                    if draftTeam == 1 then
                        -- Team 1 just picked; now regenerate team 2's options excluding adjacent zones
                        self.zoneDraftTeam = 2
                        self:prepareRevealForTeam(2, 3)  -- This now respects team 1's chosen zone
                        self:updateFogVisibility()  -- Update fog for team 2 to see their zones
                    else
                        -- Both teams have selected; all players now in placement
                        self.state = "placing"
                        -- Clear explored tiles from zone_draft phase so hidden zones appear unknown
                        if self.fogOfWar then
                            self.fogOfWar:clearExplored(1)
                            self.fogOfWar:clearExplored(2)
                        end
                        -- Update fog to show only their chosen zones
                        self:updateFogVisibility()
                    end
                    return
                end
            end
        end
    elseif self.state == "placing" then
        -- Placement phase: place pieces or bases on click
        if button == 1 then  -- Left click
            local teamArg = nil
            if self.localTeam then teamArg = self.localTeam end
            -- Allow local players to place their bases as soon as they've placed all pieces
            local function teamHasPlacedAllPieces(t)
                local cnt = 0
                for _, p in ipairs(self.pieces) do
                    if p.team == t and p.col and p.col > 0 and p.row and p.row > 0 then cnt = cnt + 1 end
                end
                return cnt >= (self.piecesPerTeam or 0)
            end

            if self.placementPhase == "pieces" then
                if teamArg and teamHasPlacedAllPieces(teamArg) then
                    -- This local team has finished pieces: allow placing bases AND replacing pieces
                    self:placePiece(col, row, teamArg)
                    self:placeBase(col, row, teamArg)
                else
                    self:placePiece(col, row, teamArg)
                end
            else
                -- Base placement phase: allow both piece and base replacement
                self:placePiece(col, row, teamArg)
                self:placeBase(col, row, teamArg)
            end
        end
    else
        -- Normal gameplay
        -- If airstrike targeting is active, intercept clicks
        if self.airstrikeTargeting then
            if button == 1 then -- Left click cancels and refunds cost
                local at = self.airstrikeTargeting
                self.teamResources[at.team] = (self.teamResources[at.team] or 0) + (at.cost or 0)
                self.teamOil[at.team] = (self.teamOil[at.team] or 0) + (at.oilCost or 0)
                self.airstrikeTargeting = nil
                return
            elseif button == 2 then -- Right click commits the strike
                local at = self.airstrikeTargeting
                local base = at.base
                -- Verify we still have superiority on that tile
                if not self:canAirstrike(at.team, col, row) then
                    -- Not allowed, do nothing
                    self.airstrikeTargeting = nil
                    return
                end

                -- If networked client, send request to host and wait for authoritative commit
                if Network and Network.isConnected and Network.isConnected() and not self.isHost and not self._applyingRemote then
                    pcall(function()
                        Network.send({type = "airstrikeRequest", col = col, row = row, team = at.team, baseCol = base.col, baseRow = base.row, cost = at.cost})
                    end)
                    self.airstrikeTargeting = nil
                    return
                end

                -- Host or local apply: Apply strike to any piece at that tile
                local targetPiece = self:getPieceAt(col, row)
                local strikeDamage = 6
                
                -- Spawn airstrike animation and damage text
                local px, py = self.map:gridToPixels(col, row)
                self:spawnMineExplosion(px, py, strikeDamage, col, row)  -- Reuse explosion for visual
                self:spawnDamageText(px, py, strikeDamage, "airstrike")
                
                -- Record airstrike for replay (only if visible to enemy)
                local enemyTeam = (at.team == 1) and 2 or 1
                if not self.fogOfWar or self.fogOfWar:isTileVisible(enemyTeam, col, row) then
                    local action = {action = "airstrike", col = col, row = row, team = at.team, damage = strikeDamage, targetCol = targetPiece and targetPiece.col or col, targetRow = targetPiece and targetPiece.row or row, targetTeam = targetPiece and targetPiece.team or nil, targetType = targetPiece and targetPiece.type or nil}
                    self.replay:recordAction(action)
                end
                
                if targetPiece then
                    local wasKilled = targetPiece:takeDamage(strikeDamage)
                    if wasKilled then
                        for i, p in ipairs(self.pieces) do
                            if p == targetPiece then
                                table.remove(self.pieces, i)
                                break
                            end
                        end
                    end
                end
                -- If host, broadcast commit
                if self.isHost and Network and Network.isConnected and Network.isConnected() and not self._applyingRemote then
                    pcall(function()
                        self:sendCommit({type = "airstrike", col = col, row = row, team = at.team, damage = strikeDamage})
                    end)
                end
                self.airstrikeTargeting = nil
                return
            end
        end

        if button == 1 then  -- Left click
            -- Check if clicking on action menu first
            if self.actionMenu and self:handleActionMenuClick(worldX, worldY) then
                return  -- Action menu handled the click
            end
            
            -- Determine viewer team for visibility checks
            local viewTeam = self.localTeam or self.currentTurn
            -- Check if clicking on a piece first (pieces have priority over bases)
            local piece = self:getVisiblePieceAt(col, row, viewTeam)
            local base = self:getVisibleBaseAt(col, row, viewTeam)
            
            -- If there's a piece, handle piece selection logic
            if piece and piece.team == self.currentTurn and piece.col > 0 and piece.row > 0 then
                -- Shift-click behaves the same as normal click (select piece with valid moves)
                
                -- If clicking on already selected piece with menu open, close menu and deselect
                if piece == self.selectedPiece and self.actionMenu then
                    self.actionMenu = nil
                    self.actionMenuContext = nil
                    self.actionMenuContextType = nil
                    piece:deselect(self)
                    return
                end
                
                -- If clicking on already selected piece, show bottom Actions button instead of hex menu
                if piece == self.selectedPiece then
                    self.actionsButtonVisible = true
                    self.actionsButtonContext = piece
                    self.actionsButtonContextType = "piece"
                    return
                end
                
                -- Otherwise, select this piece
                if self.actionMenu then
                    self.actionMenu = nil
                    self.actionMenuContext = nil
                    self.actionMenuContextType = nil
                end
                self:selectPiece(col, row)
                return
            end
            
            -- If no piece but there's a base, handle base selection
            if base and base.team == self.currentTurn and base.col > 0 and base.row > 0 then
                self:selectBase(base)
                return
            end
            
            -- If clicking on empty tile, deselect any selected base or piece
            if not piece and not base then
                self.actionsButtonVisible = false
                self.actionsButtonContext = nil
                self.actionsButtonContextType = nil
                if self.actionsPanelOpen then
                    self.actionsPanelOpen = false
                    self.actionsPanelOptions = nil
                end
            end
            
            -- Otherwise, try to select a piece (in case piece team check failed)
            if self.actionMenu then
                self.actionMenu = nil
                self.actionMenuContext = nil
                self.actionMenuContextType = nil
            end
            self:selectPiece(col, row)
        elseif button == 2 then  -- Right click
            -- If shift is held and a piece is selected, set waypoint to clicked location
            if shift and self.selectedPiece then
                local piece = self.selectedPiece
                local viewTeam = self.localTeam or self.currentTurn
                -- Only allow waypoints on visible/explored tiles
                if self.fogOfWar and not self.fogOfWar:isTileVisible(viewTeam, col, row) then
                    return  -- Can't set waypoint on unexplored tile
                end
                
                -- Don't allow waypoint on a tile occupied by another piece
                local occupier = self:getPieceAt(col, row)
                if occupier and occupier ~= piece then
                    return  -- Can't set waypoint on occupied tile
                end
                
                -- Calculate full quickest path from piece current position to the clicked tile
                local fullPath = self:findQuickestPath(piece.col, piece.row, col, row, piece.team, piece.stats.moveRange)
                
                if fullPath and #fullPath > 0 then
                    -- Break path into movement-sized segments, checking for friendly collisions
                    local moveRange = piece.stats.moveRange or 1
                    local segments = self:breakPathIntoSegments(fullPath, moveRange, piece)
                    
                    piece.waypoints = segments
                    piece.currentWaypointIndex = 1
                end
                return
            end
            
            -- Normal right-click move
            if self.selectedPiece then
                self:movePiece(col, row)
            end
            -- Right click closes action menu
            if self.actionMenu then
                self.actionMenu = nil
                self.actionMenuContext = nil
                self.actionMenuContextType = nil
            end
        end
    end
end

function Game:selectPiece(col, row)
    -- Don't allow selection during placement phase
    if self.state == "placing" then
        return
    end
    
    -- Determine viewer team for visibility checks
    local viewTeam = self.localTeam or self.currentTurn

    -- Find piece at this location that is visible to the viewer
    local piece = self:getVisiblePieceAt(col, row, viewTeam)
    
    -- If clicking on the already selected piece, deselect it
    if piece and piece == self.selectedPiece then
        piece:deselect(self)
        self.actionsButtonVisible = false
        self.actionsButtonContext = nil
        self.actionsButtonContextType = nil
        return
    end
    
    -- Deselect previous piece properly using its deselect method
    if self.selectedPiece then
        self.selectedPiece:deselect(self)
    end
    
    if piece and piece.team == self.currentTurn then

        piece.selected = true
        self.selectedPiece = piece
        self:calculateValidMoves()
        -- Show bottom Actions button for selected piece
        self.actionsButtonVisible = true
        self.actionsButtonContext = piece
        self.actionsButtonContextType = "piece"

    else
        if self.selectedPiece then
            self.selectedPiece:deselect(self)
            self.actionsButtonVisible = false
            self.actionsButtonContext = nil
            self.actionsButtonContextType = nil
        end
    end
end


function Game:getVisiblePieceAt(col, row, viewTeam)
    -- Return the piece at the location only if it's visible to the specified viewer team
    for _, piece in ipairs(self.pieces) do
        if piece.col == col and piece.row == row then
            -- If fog system exists and piece belongs to enemy, require tile visibility
            if self.fogOfWar and piece.team ~= viewTeam then
                if not self.fogOfWar:isTileVisible(viewTeam, col, row) then
                    return nil
                end
            end
            -- If piece is hidden in forest, only reveal to owner or teams that have revealed it
            if piece.hiddenInForest and piece.team ~= viewTeam then
                if not (piece.revealedTo and piece.revealedTo[viewTeam]) then
                    return nil
                end
            end
            return piece
        end
    end
    return nil
end

function Game:getPieceAt(col, row)
    for _, piece in ipairs(self.pieces) do
        if piece.col == col and piece.row == row then
            return piece
        end
    end
    return nil
end

function Game:getBaseAt(col, row)
    for _, base in ipairs(self.bases) do
        if base.col == col and base.row == row then
            return base
        end
    end
    return nil
end

function Game:getVisibleBaseAt(col, row, viewTeam)
    for _, base in ipairs(self.bases) do
        if base.col == col and base.row == row then
            if self.fogOfWar and base.team ~= viewTeam then
                if not self.fogOfWar:isTileVisible(viewTeam, col, row) then
                    return nil
                end
            end
            return base
        end
    end
    return nil
end

-- Mines helpers
function Game:addMine(mine)
    self.mines = self.mines or {}
    table.insert(self.mines, mine)
    print("[MINE] Added mine: Team " .. mine.team .. " at (" .. mine.col .. "," .. mine.row .. ")")
end

function Game:getMineAt(col, row)
    if not self.mines then return nil end
    for _, mine in ipairs(self.mines) do
        if mine.col == col and mine.row == row then
            return mine
        end
    end
    return nil
end

function Game:removeMine(mine)
    if not mine then return end
    -- remove from global list
    for i, m in ipairs(self.mines or {}) do
        if m == mine then
            table.remove(self.mines, i)
            break
        end
    end
    -- remove from owner's list
    if mine.owner and mine.owner.placedMines then
        for i, m in ipairs(mine.owner.placedMines) do
            if m == mine then
                table.remove(mine.owner.placedMines, i)
                break
            end
        end
    end
end

function Game:getDefenseAt(col, row)
    if not self.defenses then return nil end
    if not self.defenses[col] then return nil end
    return self.defenses[col][row]
end

function Game:addDefense(col, row, team)
    if not self.defenses then self.defenses = {} end
    if not self.defenses[col] then
        self.defenses[col] = {}
    end
    self.defenses[col][row] = { team = team, col = col, row = row }
end

function Game:removeDefense(col, row)
    if not self.defenses then return end
    if not self.defenses[col] then return end
    self.defenses[col][row] = nil
end

function Game:triggerMineAt(col, row, mover)
    local mine = self:getMineAt(col, row)
    if not mine then 
        print("[MINE] No mine at (" .. col .. "," .. row .. ") for " .. mover.type .. " team " .. mover.team)
        return false 
    end
    print("[MINE] Found mine at (" .. col .. "," .. row .. "): team=" .. mine.team .. ", mover team=" .. mover.team)
    if mine.team == mover.team then 
        print("[MINE] Mine is same team, skipping")
        return false 
    end

    print("[MINE] TRIGGERING mine at (" .. col .. "," .. row .. ") by team " .. mover.team)

    -- Spawn mine explosion animation
    local px, py = self.map:gridToPixels(col, row)
    local dmg = mine.damage or 5
    if mine.revealedTo and mine.revealedTo[mover.team] then
        dmg = math.max(1, math.floor(dmg / 2))
    end
    self:spawnMineExplosion(px, py, dmg, col, row)
    self:spawnDamageText(px, py, dmg, "mine")

    -- Record the mine trigger for replay
    local action = {action = "mineTrigger", col = col, row = row, moverCol = mover.col, moverRow = mover.row, moverTeam = mover.team, moverType = mover.type, damage = dmg}
    self.replay:recordAction(action)

    -- Apply damage to mover
    local wasKilled = mover:takeDamage(dmg)

    -- Remove mine
    self:removeMine(mine)

    -- If mover died, remove from pieces list
    if wasKilled then
        for i, p in ipairs(self.pieces) do
            if p == mover then
                table.remove(self.pieces, i)
                break
            end
        end
    end

    return true
end


-- Reveal mines within a piece's view range for that piece's team
function Game:sweepForMines(piece)
    if not piece or not piece.col or not piece.row then return end
    local range = piece.getViewRange and piece:getViewRange() or 1
    for _, mine in ipairs(self.mines or {}) do
        if mine.col and mine.row then
            -- Don't reveal your own team's mines when sweeping
            if mine.team == piece.team then
                goto continue
            end
                if self:isWithinRange(piece.col, piece.row, mine.col, mine.row, range) then
                mine.revealedTo = mine.revealedTo or {}
                local already = mine.revealedTo[piece.team]
                mine.revealedTo[piece.team] = true
                if not already and self.isHost and Network and Network.isConnected and Network.isConnected() then
                    pcall(function()
                        print(string.format("[game] host sending revealMine -> team=%s col=%s row=%s", tostring(piece.team), tostring(mine.col), tostring(mine.row)))
                        self:sendCommit({type = "revealMine", col = mine.col, row = mine.row, team = piece.team, mineTeam = mine.team})
                    end)
                end
            end
        end
        ::continue::
    end
    -- Also reveal hidden forest units within range (treat like mines)
    for _, target in ipairs(self.pieces or {}) do
        if target.col and target.row and target.team and target.team ~= piece.team and target.hiddenInForest then
            if self:isWithinRange(piece.col, piece.row, target.col, target.row, range) then
                target.revealedTo = target.revealedTo or {}
                local already = target.revealedTo[piece.team]
                target.revealedTo[piece.team] = true
                target.hiddenInForest = false
                if not already and self.isHost and Network and Network.isConnected and Network.isConnected() then
                    pcall(function()
                        print(string.format("[game] host sending revealForest -> team=%s col=%s row=%s unitTeam=%s", tostring(piece.team), tostring(target.col), tostring(target.row), tostring(target.team)))
                        self:sendCommit({type = "revealForest", col = target.col, row = target.row, team = piece.team, unitTeam = target.team})
                    end)
                end
            end
        end
    end
end


-- Disarm a revealed mine adjacent to the piece; engineers get +1 resource
function Game:disarmMine(piece, mine)
    if not piece or not mine then return end
    if not mine.revealedTo or not mine.revealedTo[piece.team] then
        return -- can't disarm an unrevealed mine
    end

    -- Remove the mine from game
    self:removeMine(mine)

    -- Reward engineer with 1 resource
    if piece.stats and piece.stats.canBuild then
        self.teamResources[piece.team] = (self.teamResources[piece.team] or 0) + 1
    end
    -- If host, broadcast removal so peers mirror the disarm
    if self.isHost and Network and Network.isConnected and Network.isConnected() then
        pcall(function()
            self:sendCommit({type = "removeMine", col = mine.col, row = mine.row})
        end)
    end
end

function Game:getUnitCount(team)
    local count = 0
    for _, piece in ipairs(self.pieces) do
        if piece.team == team and piece.col and piece.col > 0 and piece.row and piece.row > 0 then
            count = count + 1
        end
    end
    return count
end

function Game:getUnitCapacity(team)
    local capacity = 0
    for _, base in ipairs(self.bases) do
        if base.team == team and base.col and base.col > 0 and base.row and base.row > 0 then
            if base.stats and base.stats.unitCapacity then
                capacity = capacity + base.stats.unitCapacity
            else
                -- default per-HQ capacity if stat missing (only count HQs)
                if base.type == "hq" then
                    capacity = capacity + 1
                end
            end
        end
    end
    return capacity
end

function Game:selectBase(base)
    -- Deselect piece if one is selected
    if self.selectedPiece then
        self.selectedPiece:deselect(self)
    end
    
    -- If clicking the same base and menu is already open, close menu
    if self.actionMenu and self.actionMenuContext == base then
        self.actionMenu = nil
        self.actionMenuContext = nil
        self.actionMenuContextType = nil
        return
    end
    
    -- Show bottom Actions button for this base (user opens menu from button)
    self.actionsButtonVisible = true
    self.actionsButtonContext = base
    self.actionsButtonContextType = "base"
end

-- Generic function to open action menu for any object
-- context: the object (base, piece, resource, etc.)
-- contextType: "base", "piece", "resource", etc.
function Game:openActionMenu(context, contextType, overrideX, overrideY)
    -- Generate action options based on context type and object
    local options = self:getActionOptions(context, contextType)
    
    if #options == 0 then
        -- No options available, don't show menu
        return
    end
    
    -- Get pixel position of the context object (allow override to anchor menu at screen coords)
    local pixelX, pixelY
    if overrideX and overrideY then
        pixelX, pixelY = overrideX, overrideY
    else
        if contextType == "base" then
            pixelX, pixelY = self.map:gridToPixels(context.col, context.row)
        elseif contextType == "piece" then
            pixelX, pixelY = self.map:gridToPixels(context.col, context.row)
        elseif contextType == "resource" then
            pixelX, pixelY = self.map:gridToPixels(context.col, context.row)
        else
            return  -- Unknown context type
        end
    end
    
    -- Create ActionMenu instance
    self.actionMenu = ActionMenu.new(pixelX, pixelY, options, self.hexSideLength)
    self.actionMenuContext = context
    self.actionMenuContextType = contextType
end

-- Get action options for a given context object
-- This is where you define what actions are available for each object type
function Game:getActionOptions(context, contextType)
    if contextType == "base" then
        return context:getActionOptions(self)
    elseif contextType == "piece" then
        return context:getActionOptions(self)
    elseif contextType == "resource" then
        -- Add resource actions here (e.g., harvest, upgrade, etc.)
        return {}
    end
    return {}
end

function Game:drawActionMenu()
    if not self.actionMenu then return end
    
    -- Create callback to check if option is affordable and enabled
    local canAffordCallback = function(option)
        -- Deconstruct is always shown as red (special case)
        if option.isDeconstruct then return "deconstruct" end
        
        -- Check if option is disabled
        if option.disabled then return false end
        
        if not option.cost then return true end
        
        local team
        if self.actionMenuContextType == "base" then
            team = self.actionMenuContext.team
        elseif self.actionMenuContextType == "piece" then
            team = self.actionMenuContext.team
        else
            team = self.currentTurn
        end
        
        return self.teamResources[team] >= option.cost
    end
    
    self.actionMenu:draw(canAffordCallback)
end

function Game:handleActionMenuClick(worldX, worldY)
    if not self.actionMenu then return false end
    
    local option, index = self.actionMenu:handleClick(worldX, worldY)
    if option then
        self:executeAction(option)
        return true
    end
    
    return false
end

function Game:executeAction(option)
    -- Allow execution from either the legacy `actionMenu` context or the new bottom actions panel
    local context = self.actionMenuContext or self.actionsButtonContext
    local contextType = self.actionMenuContextType or self.actionsButtonContextType
    if not context or not contextType then return end
    
    -- Check if option is disabled
    if option.disabled then
        return  -- Can't execute disabled actions
    end
    
    -- Get team from context
    local team = context.team or self.currentTurn
    
    -- Check if player can afford this action
    if option.cost and self.teamResources[team] < option.cost then
        return  -- Can't afford
    end
    
    -- Execute action based on option ID
    if option.id == "build_infantry" and contextType == "base" then
        -- Build an infantry near the base
        self:buildUnitNearBase(context, "infantry", team, option.cost)
    elseif option.id == "build_sniper" and contextType == "base" then
        -- Build a sniper near the base
        self:buildUnitNearBase(context, "sniper", team, option.cost)
    elseif option.id == "build_tank" and contextType == "base" then
        -- Build a tank near the base (oil requirement enforced server-side)
        self:buildUnitNearBase(context, "tank", team, option.cost)
    elseif option.id == "build_sam" and contextType == "base" then
        -- Build a SAM unit near the base (oil requirement enforced server-side)
        self:buildUnitNearBase(context, "sam", team, option.cost)
    elseif option.id == "build_engineer" and contextType == "base" then
        -- Build an engineer near the base
        self:buildUnitNearBase(context, "engineer", team, option.cost)
    elseif option.id == "recruit_commander" and contextType == "base" then
        -- Recruit a commander near this HQ (enforce one-per-HQ safely)
        local baseHex = self.map:getTile(context.col, context.row)
        local hasCommander = false
        if baseHex then
            local p = self:getPieceAt(context.col, context.row)
            if p and p.type == "commander" and p.team == context.team then hasCommander = true end
            local neigh = self.map:getNeighbors(baseHex, 1)
            for _, n in ipairs(neigh) do
                if not hasCommander then
                    local pp = self:getPieceAt(n.col, n.row)
                    if pp and pp.type == "commander" and pp.team == context.team then hasCommander = true end
                end
            end
        end
        if not hasCommander then
            self:buildUnitNearBase(context, "commander", team, option.cost)
        end
    elseif option.id == "build_hq" and contextType == "piece" then
        -- Engineer builds an HQ
        self:buildStructureNearPiece(context, "hq", team, option.cost, option.buildTurns)
    elseif option.id == "build_airbase" and contextType == "piece" then
        -- Engineer builds an Airbase
        self:buildStructureNearPiece(context, "airbase", team, option.cost, option.buildTurns)
    elseif option.id == "build_ammo_depot" and contextType == "piece" then
        -- Engineer builds an ammo depot
        self:buildStructureNearPiece(context, "ammoDepot", team, option.cost, option.buildTurns)
    elseif option.id == "build_supply_depot" and contextType == "piece" then
        -- Engineer builds a supply depot
        self:buildStructureNearPiece(context, "supplyDepot", team, option.cost, option.buildTurns)
    elseif option.id == "build_resource_mine" and contextType == "piece" then
        -- Engineer builds a metal mine
        self:buildResourceMineNearPiece(context, team, option.cost, option.buildTurns)
    elseif option.id == "place_mine" and contextType == "piece" then
        -- Engineer places a land mine
        if context.placeMine then
            context:placeMine(self)
        end
    elseif option.id == "build_defense" and contextType == "piece" then
        -- Engineer builds a defensive structure
        local existingDefense = self:getDefenseAt(context.col, context.row)
        if not existingDefense then
            self:addDefense(context.col, context.row, team)
            self.teamResources[team] = (self.teamResources[team] or 0) - (option.cost or 0)
            context.hasMoved = true  -- Building uses up movement
        end
    elseif option.id == "sweep_mines" and contextType == "piece" then
        -- Sweep action: reveal mines within piece's view range for this team
        if context then
            -- If networked client, request host to perform sweep (host will broadcast reveals)
            if Network and Network.isConnected and Network.isConnected() and not self.isHost and not self._applyingRemote then
                pcall(function()
                    Network.send({type = "sweepMinesRequest", col = context.col, row = context.row, team = context.team})
                end)
            else
                self:sweepForMines(context)
                -- If host, broadcast any new reveals to peers
                if self.isHost and Network and Network.isConnected and Network.isConnected() then
                    for _, mine in ipairs(self.mines or {}) do
                        if mine.revealedTo and mine.revealedTo[context.team] then
                            -- notify clients this mine is revealed to context.team
                            pcall(function()
                                self:sendCommit({type = "revealMine", col = mine.col, row = mine.row, team = context.team, mineTeam = mine.team})
                            end)
                        end
                    end
                end
            end
            -- consume turn for this piece
            context.hasMoved = true
        end
    elseif option.id == "disarm_mine" and contextType == "piece" then
        -- Disarm a revealed neighboring mine (option carries the targetMine)
        if option.targetMine then
            -- If networked client, request host to disarm (host will remove and broadcast)
            if Network and Network.isConnected and Network.isConnected() and not self.isHost and not self._applyingRemote then
                pcall(function()
                    Network.send({type = "disarmMineRequest", col = option.targetMine.col, row = option.targetMine.row, team = context.team})
                end)
            else
                self:disarmMine(context, option.targetMine)
                -- If host, broadcast removal to peers
                if self.isHost and Network and Network.isConnected and Network.isConnected() then
                    pcall(function()
                        self:sendCommit({type = "removeMine", col = option.targetMine.col, row = option.targetMine.row})
                    end)
                end
            end
            context.hasMoved = true
        end
    elseif option.id == "deconstruct" and contextType == "base" then
        -- Deconstruct the base (remove it from the game)
        for i, base in ipairs(self.bases) do
            if base == context then
                table.remove(self.bases, i)
                break
            end
        end
    elseif option.id == "toggle_veteran" and contextType == "piece" then
        -- Dev toggle: if networked, send request to host; otherwise toggle locally and broadcast if host
        local toggleTo = not context.veteran
        if Network and Network.isConnected and Network.isConnected() and not self.isHost and not self._applyingRemote then
            pcall(function()
                Network.send({type = "setVeteranRequest", col = context.col, row = context.row, team = context.team, veteran = toggleTo and 1 or 0})
            end)
        else
            -- Host or local single-player: apply directly
            context.veteran = toggleTo
            if toggleTo then context.kills = math.max(3, context.kills or 3) else context.kills = 0 end
            if self.isHost and Network and Network.isConnected and Network.isConnected() and not self._applyingRemote then
                self:sendCommit({type = "setVeteran", col = context.col, row = context.row, team = context.team, kills = context.kills or 0, veteran = context.veteran and 1 or 0})
            end
        end
    elseif option.id == "airstrike_target" and contextType == "base" then
        -- Enter airstrike targeting mode: deduct cost now, allow player to choose tile
        if not context or context.type ~= "airbase" then return end
        local cost = option.cost or 0
        local oilCost = option.oilCost or 0
        if self.teamResources[team] < cost or self.teamOil[team] < oilCost then return end

        -- Deduct cost and enter targeting state (left-click cancel refunds)
        self.teamResources[team] = self.teamResources[team] - cost
        self.teamOil[team] = self.teamOil[team] - oilCost
        self.airstrikeTargeting = {
            base = context,
            team = team,
            cost = cost,
            oilCost = oilCost,
        }
        -- Close any action menu while targeting
        self.actionMenu = nil
        self.actionMenuContext = nil
        self.actionMenuContextType = nil
        return
    end
    -- Add more action handlers here as needed
    
    -- Close any open menus/panels after action
    self.actionMenu = nil
    self.actionMenuContext = nil
    self.actionMenuContextType = nil
    self.actionsPanelOpen = false
    self.actionsPanelOptions = nil
end

function Game:buildUnitNearBase(base, unitType, team, cost)
    -- Check unit capacity for this team
    local unitCount = self:getUnitCount(team)
    local unitCapacity = self:getUnitCapacity(team)
    if unitCapacity > 0 and unitCount >= unitCapacity then
        -- At capacity; cannot build more units
        return
    end

    -- Oil requirement for tanks and SAM: if building locally on host, ensure oil is available and deduct it.
    local oilCost = ((unitType == "tank") and 1 or 0) + ((unitType == "sam") and 1 or 0)
    if self.isHost and oilCost > 0 then
        if (self.teamOil[team] or 0) < oilCost then
            return
        end
        self.teamOil[team] = self.teamOil[team] - oilCost
    end

    -- Deduct cost (generic resources)
    self.teamResources[team] = self.teamResources[team] - cost
    
    -- Find an adjacent empty land tile to place the unit
    local baseHex = self.map:getTile(base.col, base.row)
    if not baseHex then return end
    
    local neighbors = self.map:getNeighbors(baseHex, 1)
    for _, neighbor in ipairs(neighbors) do
        local tile = self.map:getTile(neighbor.col, neighbor.row)
        if tile and tile.isLand then
            -- Check if tile is empty
            if not self:getPieceAt(neighbor.col, neighbor.row) and 
               not self:getBaseAt(neighbor.col, neighbor.row) and
               not self:getResourceAt(neighbor.col, neighbor.row) then
                -- Record recruit for replay if visible to enemy
                local viewerTeam = (team == 1) and 2 or 1
                if self.fogOfWar and self.fogOfWar:isTileVisible(viewerTeam, neighbor.col, neighbor.row) then
                    self.replay:recordAction({
                        action = "recruit",
                        pieceType = unitType,
                        team = team,
                        col = neighbor.col, row = neighbor.row
                    })
                end
                -- If networked client, validate locally (enforce oil/resource) then request host to build unit (do NOT deduct locally)
                local oilCost = ((unitType == "tank") and 1 or 0) + ((unitType == "sam") and 1 or 0)
                if Network and Network.isConnected and Network.isConnected() and not self.isHost and not self._applyingRemote then
                    -- Client-side enforcement: require both generic resources and oil available before sending request
                    if (self.teamResources[team] or 0) < cost then return end
                    if (self.teamOil[team] or 0) < oilCost then return end
                    pcall(function()
                        Network.send({type = "buildUnitRequest", baseCol = base.col, baseRow = base.row, unitType = unitType, team = team, col = neighbor.col, row = neighbor.row, cost = cost})
                    end)
                    return
                end
                -- Place unit here (host or local)
                -- If host building, deduct oilCost here (host authoritative)
                if self.isHost and oilCost > 0 then
                    if (self.teamOil[team] or 0) < oilCost then return end
                    self.teamOil[team] = self.teamOil[team] - oilCost
                end
                self:addPiece(unitType, team, neighbor.col, neighbor.row)
                -- Host will broadcast at end-turn or can commit immediately
                if self.isHost and Network and Network.isConnected and Network.isConnected() and not self._applyingRemote then
                    self:sendCommit({type = "placePiece", team = team, col = neighbor.col, row = neighbor.row, unitType = unitType})
                end
                return
            end
        end
    end
    
    -- If no adjacent tile found, try within 2 tiles
    local extendedNeighbors = self.map:getNeighbors(baseHex, 2)
    for _, neighbor in ipairs(extendedNeighbors) do
        local tile = self.map:getTile(neighbor.col, neighbor.row)
        if tile and tile.isLand then
            if not self:getPieceAt(neighbor.col, neighbor.row) and 
               not self:getBaseAt(neighbor.col, neighbor.row) and
               not self:getResourceAt(neighbor.col, neighbor.row) then
                self:addPiece(unitType, team, neighbor.col, neighbor.row)
                return
            end
        end
    end
end

function Game:buildStructureNearPiece(piece, structureType, team, cost, buildTurns)
    -- Delegate to piece if it implements buildStructure
    if piece and piece.buildStructure then
        local ok, res = pcall(function()
            return piece:buildStructure(self, structureType, team, cost, buildTurns)
        end)
        if not ok or not res then
            -- Ensure cost refunded if build failed unexpectedly
            self.teamResources[team] = (self.teamResources[team] or 0) + (cost or 0)
            print("[DEBUG] buildStructure failed for piece (type=", tostring(piece.type), ") result=", tostring(res), " ok=", tostring(ok))
            return false
        end
        return true
    end

    -- Fallback: original behavior
    self.teamResources[team] = self.teamResources[team] - cost
    local tile = self.map:getTile(piece.col, piece.row)
    if tile and tile.isLand and not self:getBaseAt(piece.col, piece.row) then
        if piece.startBuilding then
            piece:startBuilding(structureType, team, buildTurns, nil, self)
            return
        end
        -- No startBuilding on piece: refund cost
        self.teamResources[team] = self.teamResources[team] + cost
        return
    end
    self.teamResources[team] = self.teamResources[team] + cost
 end

function Game:buildResourceMineNearPiece(piece, team, cost, buildTurns)
    -- Delegate to piece if it implements buildResourceMine
    if piece and piece.buildResourceMine then
        return piece:buildResourceMine(self, team, cost, buildTurns)
    end

    -- Fallback: original behavior
    local existingResource = self:getResourceAt(piece.col, piece.row)
    if not existingResource then
        return
    end
    if existingResource.hasMine then
        return
    end
    self.teamResources[team] = self.teamResources[team] - cost
    if piece.startBuilding then
        piece:startBuilding("resource_mine", team, buildTurns, existingResource, self)
    else
        -- No startBuilding on piece: refund
        self.teamResources[team] = self.teamResources[team] + cost
    end
end

function Game:calculateValidMoves()
    self.validMoves = {}
    self.validAttacks = {}
    
    if not self.selectedPiece or self.selectedPiece.recruited == true then return end
    
    -- If piece is currently building, don't show any moves or attacks
    local isBuilding = self.selectedPiece.isBuilding or false
    if isBuilding then return end

    -- If the piece has already moved this turn, do not populate `validMoves` (can't move again),
    -- but still compute `validAttacks` so a unit may move then attack.
    local hasMovedAlready = self.selectedPiece.hasMoved or false
    
    local moveRange = self.selectedPiece:getMovementRange()
    local attackRange = self.selectedPiece:getAttackRange()
    
    -- Get all neighbors within move range (enemy pieces block movement)
    if not hasMovedAlready then
        local visited = {}
        self:getHexesWithinRange(self.selectedPiece.col, self.selectedPiece.row, moveRange, visited, self.selectedPiece.team)
        -- Build a quick lookup set for tiles reachable by movement range
        local allowedSet = {}
        for _, h in ipairs(visited) do allowedSet[h.col .. "," .. h.row] = true end

        for _, hex in ipairs(visited) do
            if hex.col ~= self.selectedPiece.col or hex.row ~= self.selectedPiece.row then
                local tile = self.map:getTile(hex.col, hex.row)
                if tile and tile.isLand and not self:getPieceAt(hex.col, hex.row) then
                    -- Only allow moving to tiles visible to this piece's team AND which have
                    -- a continuous path of visible tiles back to the piece
                    if self.fogOfWar then
                        if self.fogOfWar:isTileVisible(self.selectedPiece.team, hex.col, hex.row) then
                            if self:hasVisiblePath(self.selectedPiece.col, self.selectedPiece.row, hex.col, hex.row, self.selectedPiece.team, allowedSet) then
                                table.insert(self.validMoves, hex)
                            end
                        end
                    else
                        -- No fog system: allow based on connectivity only
                        if self:hasVisiblePath(self.selectedPiece.col, self.selectedPiece.row, hex.col, hex.row, self.selectedPiece.team, allowedSet) then
                            table.insert(self.validMoves, hex)
                        end
                    end
                end
            end
        end
    end
    
    -- Get hexes in attack range (same as move range)
    -- Only show attacks if piece has ammo
    if self.selectedPiece:hasAmmo() then
        local attackHexes = {}
        self:getHexesWithinRange(self.selectedPiece.col, self.selectedPiece.row, attackRange, attackHexes, self.selectedPiece.team)
        
        for _, hex in ipairs(attackHexes) do
            if hex.col ~= self.selectedPiece.col or hex.row ~= self.selectedPiece.row then
                -- Use visibility-aware lookup so hidden forest units aren't targetable
                local target = self:getVisiblePieceAt(hex.col, hex.row, self.selectedPiece.team)
                if target and target.team ~= self.selectedPiece.team then
                    table.insert(self.validAttacks, hex)
                end
            end
        end
    end
end

function Game:getHexesWithinRange(col, row, range, visited, team)
    visited = visited or {}
    team = team or self.currentTurn  -- Default to current turn's team
    
    if range <= 0 then return end
    
    -- Get the hex tile for this position
    local startHex = self.map:getTile(col, row)
    if not startHex then return end
    
    -- Use Dijkstra-like exploration to respect terrain movement costs (terrainCost)
    local frontier = {{hex = startHex, distance = 0}}
    local best = {}
    best[startHex.col .. "," .. startHex.row] = 0

    while #frontier > 0 do
        -- Pop the entry with smallest distance
        table.sort(frontier, function(a,b) return a.distance < b.distance end)
        local current = table.remove(frontier, 1)
        local currentHex = current.hex
        local currentDistance = current.distance

        -- If currentDistance exceeds range, stop exploring
        if currentDistance > range then break end

        -- Add to visited if it's not the starting hex and within range
        if currentDistance > 0 and currentDistance <= range then
            local key = currentHex.col .. "," .. currentHex.row
            if not visited[key] then
                visited[key] = currentHex
                currentHex.distance = currentDistance
                table.insert(visited, currentHex)
            end
        end

        -- Explore neighbors
        local neighbors = self.map:getNeighbors(currentHex, 1)
        for _, neighbor in ipairs(neighbors) do
            local neighborTile = self.map:getTile(neighbor.col, neighbor.row)
            if not neighborTile then goto neighbor_continue end
            if not neighborTile.isLand then goto neighbor_continue end

            -- Movement cost entering neighbor
            local cost = neighborTile.terrainCost or 1

            -- Check occupancy: enemy pieces block passing beyond that tile
            local pieceOnTile = self:getPieceAt(neighbor.col, neighbor.row)
            local isEnemyOccupied = pieceOnTile and pieceOnTile.team ~= team

            local newDist = currentDistance + cost
            local nkey = neighbor.col .. "," .. neighbor.row
            if newDist <= range then
                -- If we've found a better distance to neighbor, update and add to frontier
                if not best[nkey] or newDist < best[nkey] then
                    best[nkey] = newDist
                    table.insert(frontier, {hex = neighborTile, distance = newDist})
                end
            end

            -- If tile is enemy-occupied, do not expand further beyond it
            if isEnemyOccupied then
                goto neighbor_continue
            end

            ::neighbor_continue::
        end
    end
end


-- Return true if there exists a path from (startCol,startRow) to (targetCol,targetRow)
-- traveling only through tiles that are passable (land), optionally limited to tiles in allowedSet,
-- and (when fogOfWar is present) only through tiles visible to `team`.
function Game:hasVisiblePath(startCol, startRow, targetCol, targetRow, team, allowedSet)
    if not startCol or not startRow or not targetCol or not targetRow then return false end
    if startCol == targetCol and startRow == targetRow then return true end
    local startHex = self.map:getTile(startCol, startRow)
    local targetHex = self.map:getTile(targetCol, targetRow)
    if not startHex or not targetHex then return false end

    local q = {{col = startCol, row = startRow}}
    local seen = {}
    seen[startCol .. "," .. startRow] = true

    while #q > 0 do
        local cur = table.remove(q, 1)
        local hex = self.map:getTile(cur.col, cur.row)
        if not hex then goto continue end
        local neighbors = self.map:getNeighbors(hex, 1)
        for _, n in ipairs(neighbors) do
            local key = n.col .. "," .. n.row
            if not seen[key] then
                seen[key] = true
                -- Respect allowedSet if provided (limit to movement-range reachable tiles)
                if allowedSet and not allowedSet[key] then goto neighbor_continue end
                local ntile = self.map:getTile(n.col, n.row)
                if not ntile or not ntile.isLand then goto neighbor_continue end
                -- Exclude blocking tiles: enemy-occupied, bases, resources
                local occ = self:getPieceAt(n.col, n.row)
                if occ and occ.team ~= team then goto neighbor_continue end
                -- Allow moving onto a base tile if it is the intended target; otherwise treat bases as blocking
                if self:getBaseAt(n.col, n.row) and not (n.col == targetCol and n.row == targetRow) then goto neighbor_continue end
                -- Allow moving onto a resource tile if it is the intended target (so units can occupy resources to build/defend mines)
                if self:getResourceAt(n.col, n.row) and not (n.col == targetCol and n.row == targetRow) then goto neighbor_continue end
                -- If fog is enabled, tile must be visible to team to be part of continuous trail
                if self.fogOfWar and not self.fogOfWar:isTileVisible(team, n.col, n.row) then goto neighbor_continue end
                -- Tile is passable for the visible path
                table.insert(q, {col = n.col, row = n.row})
                if n.col == targetCol and n.row == targetRow then
                    return true
                end
                ::neighbor_continue::
            end
        end
        ::continue::
    end
    return false
end

-- Get all tiles within a radius regardless of passability (used for airbase influence)
function Game:getTilesWithinRadius(col, row, radius)
    local tiles = {}
    if radius <= 0 then return tiles end
    local startHex = self.map:getTile(col, row)
    if not startHex then return tiles end

    -- Use index-based queue to avoid O(n) table.remove at index 1
    local queue = {}
    local qhead = 1
    queue[#queue+1] = {col = col, row = row, distance = 0}
    local visitedSet = {}
    visitedSet[col .. "," .. row] = true

    while qhead <= #queue do
        local current = queue[qhead]
        qhead = qhead + 1
        if current.distance <= radius then
            local hex = self.map:getTile(current.col, current.row)
            if hex then
                tiles[#tiles+1] = hex
            end
        end

        if current.distance >= radius then
            goto continue
        end

        local currentHex = self.map:getTile(current.col, current.row)
        if currentHex then
            local neighbors = self.map:getNeighbors(currentHex, 1)
            for _, n in ipairs(neighbors) do
                local key = n.col .. "," .. n.row
                if not visitedSet[key] then
                    visitedSet[key] = true
                    queue[#queue+1] = { col = n.col, row = n.row, distance = current.distance + 1 }
                end
            end
        end
        ::continue::
    end

    return tiles
end

-- Calculate air superiority map: returns table keyed by "col,row" -> { [1]=points1, [2]=points2 }
function Game:calculateAirSuperiorityMap()
    local map = {}
    -- Airbases provide air superiority
    for _, base in ipairs(self.bases) do
        if base.type == "airbase" and base.col and base.col > 0 and base.row and base.row > 0 then
            local tiles = self:getTilesWithinRadius(base.col, base.row, base:getRadius())
            for _, tile in ipairs(tiles) do
                local key = tile.col .. "," .. tile.row
                if not map[key] then map[key] = { [1] = 0, [2] = 0 } end
                map[key][base.team] = map[key][base.team] + 1
            end
        end
    end
    -- SAM units provide anti-air defense (reduce enemy air superiority)
    for _, piece in ipairs(self.pieces) do
        if piece.type == "sam" and piece.col and piece.col > 0 and piece.row and piece.row > 0 then
            local radius = piece.stats.airDefenseRadius or 2
            local tiles = self:getTilesWithinRadius(piece.col, piece.row, radius)
            for _, tile in ipairs(tiles) do
                local key = tile.col .. "," .. tile.row
                if not map[key] then map[key] = { [1] = 0, [2] = 0 } end
                map[key][piece.team] = map[key][piece.team] + 1
            end
        end
    end
    return map
end

-- Convenience: get air superiority points for a tile (returns t1, t2)
function Game:getAirSuperiorityAt(col, row)
    local map = self.airSuperiorityMap or self:calculateAirSuperiorityMap()
    local key = col .. "," .. row
    local entry = map[key]
    if not entry then return 0, 0 end
    return entry[1] or 0, entry[2] or 0
end

-- Can `team` perform an airstrike against target tile? Requires teamAS > enemyAS and teamAS > 0, and not targeting own pieces/bases
function Game:canAirstrike(team, targetCol, targetRow)
    -- Check for own pieces or bases at the target tile
    local piece = self:getPieceAt(targetCol, targetRow)
    if piece and piece.team == team then return false end
    local base = self:getBaseAt(targetCol, targetRow)
    if base and base.team == team then return false end

    local t1, t2 = self:getAirSuperiorityAt(targetCol, targetRow)
    local teamAS = t1
    local enemyAS = t2
    if team == 2 then teamAS, enemyAS = t2, t1 end
    return teamAS > 0 and teamAS > enemyAS
end

function Game:isWithinRange(startCol, startRow, targetCol, targetRow, range)
    -- Use BFS to check if target is within range, respecting impassable terrain
    local visited = {}
    local queue = {{col = startCol, row = startRow, distance = 0}}
    visited[startCol .. "," .. startRow] = true
    
    while #queue > 0 do
        local current = table.remove(queue, 1)
        
        -- Check if we found the target
        if current.col == targetCol and current.row == targetRow then
            return current.distance <= range
        end
        
        -- Don't explore further if we've exceeded range
        if current.distance >= range then
            goto continue
        end
        
        -- Get neighbors
        local currentHex = self.map:getTile(current.col, current.row)
        if currentHex then
            local neighbors = self.map:getNeighbors(currentHex, 1)
            for _, neighbor in ipairs(neighbors) do
                local key = neighbor.col .. "," .. neighbor.row
                if not visited[key] then
                    -- Only explore through passable terrain (land)
                    local neighborTile = self.map:getTile(neighbor.col, neighbor.row)
                    if neighborTile and neighborTile.isLand then
                        visited[key] = true
                        table.insert(queue, {col = neighbor.col, row = neighbor.row, distance = current.distance + 1})
                    end
                    -- If terrain is not passable (water), don't explore past it
                end
            end
        end
        ::continue::
    end
    
    return false
end

function Game:resupplyPieceFromBases(piece)
    -- Check all friendly bases to see if piece is within range
    for _, base in ipairs(self.bases) do
        if base.team == piece.team and base.col > 0 and base.row > 0 then
            if self:isWithinRange(base.col, base.row, piece.col, piece.row, base:getRadius()) then
                -- Piece is within range, resupply based on base type
                if base:suppliesAmmo() then
                    piece.ammo = piece.maxAmmo
                end
                if base:suppliesSupply() then
                    piece.supply = piece.maxSupply
                end
            end
        end
    end
end

function Game:generateResourceIncome(team)
    local income = 0
    
    -- Count HQs owned by this team (each HQ generates 1 resource)
    for _, base in ipairs(self.bases) do
        if base.team == team and base.type == "hq" and base.col > 0 and base.row > 0 then
            income = income + 1
        end
    end
    
    -- Count resource tiles with mines owned by this team
    for _, resource in ipairs(self.resources) do
        if resource.owner == team and resource.hasMine then
            if resource.type == "oil" then
                -- Oil produces oil resource (separate currency)
                self.teamOil[team] = self.teamOil[team] + 1
            else
                -- Mined resources produce 2 generic resources
                income = income + 2
            end
        end
    end
    
    -- Add income to team's resources
    self.teamResources[team] = self.teamResources[team] + income

    -- -- Region control bonuses: +1 resource per controlled region
    -- local regionOwners = self:calculateRegionControl()
    -- for regionId, owner in pairs(regionOwners) do
    --     if owner == team then
    --         self.teamResources[team] = self.teamResources[team] + 1
    --     end
    -- end
end

function Game:movePiece(col, row)
    if not self.selectedPiece then return end
    local oldCol = self.selectedPiece.col
    local oldRow = self.selectedPiece.row
    
    -- Check if move is valid
    local isValidMove = false
    for _, move in ipairs(self.validMoves) do
        if move.col == col and move.row == row then
            isValidMove = true
            break
        end
    end
    
    -- Check if attack is valid
    local isValidAttack = false
    local targetPiece = nil
    for _, attack in ipairs(self.validAttacks) do
        if attack.col == col and attack.row == row then
            isValidAttack = true
            targetPiece = self:getPieceAt(col, row)
            break
        end
    end
    
    if isValidMove then
        -- Record move for replay if visible to enemy
        local viewerTeam = (self.currentTurn == 1) and 2 or 1
        if self.fogOfWar and self.fogOfWar:isTileVisible(viewerTeam, col, row) then
            -- Find the path used for animation
            local path = self:findQuickestPath(oldCol, oldRow, col, row, self.selectedPiece and self.selectedPiece.team, (self.selectedPiece and self.selectedPiece.stats.moveRange) or 1)
            self.replay:recordAction({
                action = "move",
                pieceType = self.selectedPiece.type,
                team = self.selectedPiece.team,
                fromCol = oldCol, fromRow = oldRow, toCol = col, toRow = row,
                path = path
            })
        end
        -- If networked client, send request to host instead of applying locally
        -- Tank movement requires oil: client-side check to avoid sending invalid request
        if self.selectedPiece and self.selectedPiece.type == "tank" then
            local team = self.selectedPiece.team
            if (self.teamOil[team] or 0) < 1 then
                pcall(function() print(string.format("[game] move blocked: insufficient oil for tank team=%s", tostring(team))) end)
                return
            end
        end
        if Network and Network.isConnected and Network.isConnected() and not self.isHost and not self._applyingRemote then
            pcall(function()
                Network.send({type = "moveRequest", fromCol = oldCol, fromRow = oldRow, toCol = col, toRow = row, team = self.localTeam})
            end)
            return
        end

        -- If host performing the move locally, deduct tank oil cost here
        if self.isHost and self.selectedPiece and self.selectedPiece.type == "tank" then
            local team = self.selectedPiece.team
            if (self.teamOil[team] or 0) < 1 then
                pcall(function() print(string.format("[game] host move blocked: insufficient oil for tank team=%s", tostring(team))) end)
                return
            end
            self.teamOil[team] = (self.teamOil[team] or 0) - 1
        end

        -- Find quickest path (minimize movement turns) from current position to target
        local path = self:findQuickestPath(oldCol, oldRow, col, row, self.selectedPiece and self.selectedPiece.team, (self.selectedPiece and self.selectedPiece.stats.moveRange) or 1)
        
        -- Mark as moved immediately (prevents further moves)
        self.selectedPiece.hasMoved = true
        
        -- Start animated movement along the path
        if path and #path > 0 then
            self.selectedPiece:startAnimatedMovement(path)
        else
            -- If no path found, do direct movement (shouldn't happen for valid moves)
            self.selectedPiece:setPosition(col, row)
        end
        
        -- Clear any waypoints when piece is moved manually
        self.selectedPiece.waypoints = {}
        self.selectedPiece.currentWaypointIndex = 0
        
        -- Send network update (mirror) if connected and this is a local action
        if Network and Network.isConnected and Network.isConnected() and not self._applyingRemote then
            if self.isHost then
                pcall(function() print(string.format("[game] host commit move %d,%d -> %d,%d", oldCol, oldRow, col, row)) end)
                -- Broadcast move commit before triggering any mines so clients will move their piece first
                self:sendCommit({type = "move", fromCol = oldCol, fromRow = oldRow, toCol = col, toRow = row})
            end
        end

        -- Note: Mine triggers and defense destruction now happen in updatePieceAnimations() as piece moves
        -- Recalculate valid moves/attacks after animation completes
        -- For now, we'll recalculate when animation finishes
    elseif isValidAttack and targetPiece then
        -- If networked client, send request to host and don't apply locally
        -- If networked client, send request to host and don't apply locally
        if Network and Network.isConnected and Network.isConnected() and not self.isHost and not self._applyingRemote then
            pcall(function()
                Network.send({type = "attackRequest", fromCol = oldCol, fromRow = oldRow, toCol = col, toRow = row, team = self.localTeam})
            end)
            return
        end

        -- Check if piece has ammo
        if not self.selectedPiece:hasAmmo() then
            return  -- Can't attack without ammo
        end

        -- Use ammo
        self.selectedPiece:useAmmo()

        -- Determine dice counts (use piece hooks when available)
        local aDice = (self.selectedPiece.getAttackDice and self.selectedPiece:getAttackDice()) or 1
        local dDice = (targetPiece.getDefenseDice and targetPiece:getDefenseDice()) or 1
        -- Option B: defender only rolls if attacker is within defender's attack range
        if targetPiece and targetPiece.getAttackRange and self.selectedPiece then
            local defRange = targetPiece:getAttackRange() or 1
            if not self:isWithinRange(targetPiece.col, targetPiece.row, oldCol, oldRow, defRange) then
                dDice = 0
            end
        end
        -- Apply morale bonuses (each morale point = +1 die)
        local moraleA = self:computeMorale(self.selectedPiece) or 0
        local moraleD = self:computeMorale(targetPiece) or 0
        aDice = (aDice or 0) + (moraleA or 0)
        dDice = (dDice or 0) + (moraleD or 0)
        -- Roll dice with per-unit max faces
        local maxA = (self.selectedPiece and self.selectedPiece.getDieMax and self.selectedPiece:getDieMax()) or 6
        local maxD = (targetPiece and targetPiece.getDieMax and targetPiece:getDieMax()) or 6
        -- Commander adjacency increases the max die face by +1 per adjacent commander
        local cmdA = self:countAdjacentCommanders(self.selectedPiece) or 0
        local cmdD = self:countAdjacentCommanders(targetPiece) or 0
        maxA = maxA + (cmdA or 0)
        maxD = maxD + (cmdD or 0)
        
        -- Check if defender is on a defensive structure (gives -1 to attacker max die)
        local defense = self:getDefenseAt(col, row)
        local defenseEffect = 0
        if defense and defense.team == targetPiece.team then
            defenseEffect = -1
            maxA = math.max(1, maxA + defenseEffect)  -- Defense penalizes attacker's die, ensure minimum of 1
        end

        pcall(function()
            print(string.format("[DBG attack local PRE] aDice=%s moraleA=%s cmdA=%s maxA=%s  dDice=%s moraleD=%s cmdD=%s maxD=%s defense=%s defEff=%s target.col=%s target.row=%s attack.col=%s attack.row=%s", tostring(aDice), tostring(moraleA), tostring(cmdA), tostring(maxA), tostring(dDice), tostring(moraleD), tostring(cmdD), tostring(maxD), tostring(defense ~= nil), tostring(defenseEffect), tostring(targetPiece.col), tostring(targetPiece.row), tostring(col), tostring(row)))
        end)
        local rollsA = self:rollDice(aDice, maxA)
        local rollsD = self:rollDice(dDice, maxD)
        -- Compute damage from dice comparisons
        local damageToTarget, damageToAttacker = self:computeDiceOutcome(rollsA, rollsD)
        pcall(function()
            print(string.format("[DBG attack local POST] rollsA=%s rollsD=%s dmgToTarget=%s dmgToAttacker=%s", tostring(table.concat(rollsA,",")), tostring(table.concat(rollsD,",")), tostring(damageToTarget), tostring(damageToAttacker)))
        end)

        -- Record attack for replay if visible to enemy (now with actual computed damage)
        local viewerTeam = (self.currentTurn == 1) and 2 or 1
        -- Always record attacks for replay (visibility check may prevent recordings)
        if true then -- self.fogOfWar and (self.fogOfWar:isTileVisible(viewerTeam, col, row) or self.fogOfWar:isTileVisible(viewerTeam, oldCol, oldRow)) then
            self.replay:recordAction({
                action = "attack",
                pieceType = self.selectedPiece.type,
                team = self.selectedPiece.team,
                fromCol = oldCol, fromRow = oldRow, toCol = col, toRow = row,
                targetType = targetPiece.type,
                targetTeam = targetPiece.team,
                damageToTarget = damageToTarget,
                damageToAttacker = damageToAttacker,
                targetHp = targetPiece.hp,
                attackerHp = self.selectedPiece.hp,
                rollsA = rollsA,
                rollsD = rollsD
            })
        end

        -- Reveal attacker if hidden (local single-player or host handles reveal broadcast elsewhere)
        if self.selectedPiece and self.selectedPiece.hiddenInForest then
            local revealTeam = nil
            if targetPiece and targetPiece.team then
                revealTeam = targetPiece.team
            else
                revealTeam = (self.selectedPiece.team and (3 - self.selectedPiece.team)) or nil
            end
            if revealTeam then
                self:revealPieceToTeam(self.selectedPiece, revealTeam)
                if self.isHost and Network and Network.isConnected and Network.isConnected() then
                    pcall(function()
                        self:sendCommit({type = "revealForest", col = self.selectedPiece.col, row = self.selectedPiece.row, team = revealTeam, unitTeam = self.selectedPiece.team})
                    end)
                end
            end
        end

        -- Spawn combat animation at midpoint
        local ax, ay = self.map:gridToPixels(oldCol, oldRow)
        local bx, by = self.map:gridToPixels(col, row)
        local mx, my = (ax + bx) / 2, (ay + by) / 2
        self:spawnCombatAnimation(mx, my, rollsA, rollsD, self.selectedPiece and self.selectedPiece.team or nil, targetPiece and targetPiece.team or nil)

        -- Apply damage results locally now (host authoritative for networked games)
        if damageToTarget > 0 and targetPiece then
            local wasKilled = targetPiece:takeDamage(damageToTarget)
            if wasKilled then
                for i, p in ipairs(self.pieces) do if p == targetPiece then table.remove(self.pieces, i); break end end
            end
        end
        if damageToAttacker > 0 and self.selectedPiece then
            local wasKilledA = self.selectedPiece:takeDamage(damageToAttacker)
            if wasKilledA then
                for i, p in ipairs(self.pieces) do if p == self.selectedPiece then table.remove(self.pieces, i); break end end
                self.selectedPiece = nil
            end
        end

        -- Determine movedInto: attacker moves in on kill if adjacent
        local movedInto = false
        if targetPiece and targetPiece.col and targetPiece.row then
            local killed = (damageToTarget > 0 and not self:getPieceAt(col, row)) or (targetPiece and targetPiece.col and targetPiece.row and not self:getPieceAt(col, row))
            -- simpler: if target was removed and adjacent from old position
            if self:isWithinRange(oldCol, oldRow, col, row, 1) and (damageToTarget > 0) and not self:getPieceAt(col, row) then
                movedInto = true
            end
        end

        -- Handle movement into target tile (tank oil cost applies for host)
        if movedInto and self.selectedPiece then
            if self.selectedPiece.type == "tank" then
                local team = self.selectedPiece.team
                if self.isHost then
                    if (self.teamOil[team] or 0) >= 1 then
                        self.teamOil[team] = (self.teamOil[team] or 0) - 1
                        self.selectedPiece:setPosition(col, row)
                    else
                        pcall(function() print(string.format("[game] host attack movement blocked: insufficient oil for tank team=%s", tostring(team))) end)
                    end
                else
                    -- single-player or non-host: deduct if available
                    if (self.teamOil[team] or 0) >= 1 then
                        self.teamOil[team] = (self.teamOil[team] or 0) - 1
                        self.selectedPiece:setPosition(col, row)
                    end
                end
            else
                self.selectedPiece:setPosition(col, row)
            end
        end

        -- If host, broadcast attack commit with roll details so clients can animate and apply same results
        if self.isHost and Network and Network.isConnected and Network.isConnected() then
            pcall(function()
                    self:sendCommit({type = "attack", fromCol = oldCol, fromRow = oldRow, toCol = col, toRow = row, attackerRolls = rollsA, defenderRolls = rollsD, damageToTarget = damageToTarget, damageToAttacker = damageToAttacker, moved = movedInto, attackerTeam = self.selectedPiece and self.selectedPiece.team or nil, defenderTeam = targetPiece and targetPiece.team or nil})
            end)

        end
        -- After broadcasting, trigger mines if moved into tile
        if movedInto and self.selectedPiece then self:triggerMineAt(col, row, self.selectedPiece) end
        -- Mark piece as moved since it attacked (if still alive)
        if self.selectedPiece then self.selectedPiece.hasMoved = true end
        self:calculateValidMoves()
        if self.selectedPiece then self.selectedPiece:deselect(self) end
    end
end

function Game:keypressed(key)
    -- Replay skip logic
    if self.state == "replay" and self.replay and self.replay.replayActive then
        -- If overlay is active, dismiss it on Space; otherwise Space requests replay skip
        if key == "space" then
            if self._replayOverlay then
                self._replayOverlay = false
                self._replayOverlayTimer = nil
                print("[REPLAY] Overlay dismissed by user")
            else
                self.replay.replaySkipRequested = true
            end
        end
        return
    end
    -- Accept hotseat pass if pending
    if self.passPending then
        if key == "return" or key == "space" then
            self:confirmPass()
        end
        return
    end
    if key == "e" then
        -- Only allow ending the turn if this instance represents the active team
        if self.localTeam and self.currentTurn ~= self.localTeam then
            pcall(function() print(string.format("[game] endTurn blocked: currentTurn=%s localTeam=%s", tostring(self.currentTurn), tostring(self.localTeam))) end)
            return
        end
        self:endTurn()
    elseif key == "r" then
        self:resetGame()
    elseif key == "w" then
        self.camera:pan(0, 20)  -- Move up
    elseif key == "s" then
        self.camera:pan(0, -20)  -- Move down
    elseif key == "a" then
        self.camera:pan(20, 0)  -- Move left
    elseif key == "d" then
        self.camera:pan(-20, 0)  -- Move right
    elseif key == "f1" then
        -- Toggle developer mode: allows fast placement and relaxed checks for testing
        self.devMode = not self.devMode
        pcall(function() print(string.format("[game] devMode -> %s", tostring(self.devMode))) end)
    end

    -- Developer controls: switch which team you're controlling in devMode
    if self.devMode then
        -- During placement, Tab switches the active placement team (1 <-> 2)
        if key == "tab" then
            if self.state == "placing" then
                self.placementTeam = (self.placementTeam == 1) and 2 or 1
                pcall(function() print(string.format("[game] placementTeam -> %s", tostring(self.placementTeam))) end)
            else
                -- During zone_draft or placement, Tab switches the active team
                if self.state == "zone_draft" then
                    self.zoneDraftTeam = (self.zoneDraftTeam == 1) and 2 or 1
                    self:updateFogVisibility()
                    pcall(function() print(string.format("[game] zoneDraftTeam -> %s", tostring(self.zoneDraftTeam))) end)
                end
            end
            return
        end

        -- Directly set control to team 1 or 2 with keys '1' and '2'; '0' clears local control
        if key == "1" then
            self.localTeam = 1
            pcall(function() print("[game] localTeam -> 1") end)
            return
        elseif key == "2" then
            self.localTeam = 2
            pcall(function() print("[game] localTeam -> 2") end)
            return
        elseif key == "0" then
            self.localTeam = nil
            pcall(function() print("[game] localTeam cleared -> simultaneous placement") end)
            return
        elseif key == "f2" then
            -- Toggle free placement during dev mode placement phase (F2, not F1)
            if self.state == "placing" then
                self.freePlacement = not self.freePlacement
                pcall(function() print(string.format("[game] freePlacement -> %s", tostring(self.freePlacement))) end)
            end
            return
        end
    end
end

function Game:mousemoved(x, y, dx, dy)
    if self.passPending then return end
    -- Handle camera panning with middle mouse or space
    if love.mouse.isDown(3) then  -- Middle mouse
        self.camera:pan(dx, dy)
    end
end

-- Clear waypoints if an enemy is in view range of the unit
function Game:clearWaypointsOnEnemyContact()
    for _, piece in ipairs(self.pieces) do
        if piece.waypoints and #piece.waypoints > 0 then
            local viewRange = piece:getViewRange() or piece.stats.viewRange or 1
            -- Check if any enemy piece is within view range
            for _, otherPiece in ipairs(self.pieces) do
                if otherPiece.team ~= piece.team then
                    local dx = otherPiece.col - piece.col
                    local dy = otherPiece.row - piece.row
                    -- Simple distance check
                    local dist = math.sqrt(dx*dx + dy*dy)
                    if dist <= viewRange then
                        -- Enemy in view range; clear waypoints
                        piece.waypoints = {}
                        piece.currentWaypointIndex = 0
                        break
                    end
                end
            end
        end
    end
end

-- Pathfind one step toward target, respecting terrain
-- Returns path {col, row} list or nil if no path
function Game:pathToward(startCol, startRow, targetCol, targetRow)
    -- Simple BFS to find shortest path
    local visited = {}
    local queue = {{col = startCol, row = startRow, path = {{col = startCol, row = startRow}}}}
    visited[startCol .. "," .. startRow] = true
    
    while #queue > 0 do
        local current = table.remove(queue, 1)
        if current.col == targetCol and current.row == targetRow then
            return current.path
        end
        
        -- Explore neighbors
        local tile = self.map:getTile(current.col, current.row)
        if tile then
            local neighbors = self.map:getNeighbors(tile, 1)
            for _, neighbor in ipairs(neighbors) do
                local nkey = neighbor.col .. "," .. neighbor.row
                if not visited[nkey] then
                    visited[nkey] = true
                    local nTile = self.map:getTile(neighbor.col, neighbor.row)
                    if nTile and nTile.isLand then
                        local newPath = {}
                        for _, p in ipairs(current.path) do
                            table.insert(newPath, p)
                        end
                        table.insert(newPath, {col = neighbor.col, row = neighbor.row})
                        table.insert(queue, {col = neighbor.col, row = neighbor.row, path = newPath})
                    end
                end
            end
        end
    end
    return nil
end

function Game:wheelmoved(x, y)
    if y > 0 then
        self.camera:zoomIn(0.1)
    else
        self.camera:zoomOut(0.1)
    end
end

-- Process waypoint moves for a team at the start of their turn
function Game:processWaypointMoves(team)
    for _, piece in ipairs(self.pieces) do
        if piece.team == team and piece.waypoints and #piece.waypoints > 0 and not piece.hasMoved and not piece.isAnimating then
            local currentWpIdx = piece.currentWaypointIndex
            if currentWpIdx >= 1 and currentWpIdx <= #piece.waypoints then
                local targetWp = piece.waypoints[currentWpIdx]
                
                -- Check if the target waypoint is occupied by a friendly piece at this moment
                -- (another piece may have moved there during this turn phase)
                local occupier = self:getPieceAt(targetWp.col, targetWp.row)
                if occupier and occupier.team == piece.team and occupier ~= piece then
                    -- Can't reach this waypoint, it's blocked by a friendly piece
                    -- Skip to next waypoint instead of being stuck
                    piece.currentWaypointIndex = currentWpIdx + 1
                    if piece.currentWaypointIndex > #piece.waypoints then
                        piece.waypoints = {}
                        piece.currentWaypointIndex = 0
                    end
                    return
                end
                
                -- Move toward the target waypoint
                local path = self:findQuickestPath(piece.col, piece.row, targetWp.col, targetWp.row, piece.team, piece.stats.moveRange)
                if path and #path > 0 then
                    -- Move moveRange steps at once (or fewer if path is shorter)
                    local moveRange = piece.stats.moveRange or 1
                    local stepsToMove = math.min(moveRange, #path)
                    
                    -- Extract the sub-path to animate
                    local animationPath = {}
                    for i = 1, stepsToMove do
                        table.insert(animationPath, path[i])
                    end
                    
                    -- Start animation
                    piece:startAnimatedMovement(animationPath)
                    piece.hasMoved = true
                    
                    -- Check if reached waypoint; advance to next if so
                    local finalStep = animationPath[#animationPath]
                    if finalStep.col == targetWp.col and finalStep.row == targetWp.row then
                        piece.currentWaypointIndex = currentWpIdx + 1
                        if piece.currentWaypointIndex > #piece.waypoints then
                            -- Reached the last waypoint; clear waypoints
                            piece.waypoints = {}
                            piece.currentWaypointIndex = 0
                        end
                    end
                end
            end
        end
    end
end

-- Pathfind one step toward target, respecting terrain
-- Returns path {col, row} list or nil if no path
-- Find the shortest path using BFS
-- Returns list of {col, row} steps from start to target
-- Allows passing through friendly pieces when `movingTeam` is provided.
-- Still disallows ending on an occupied tile (unless it's the target and handled elsewhere).
function Game:findShortestPath(startCol, startRow, targetCol, targetRow, movingTeam)
    local visited = {}
    local queue = {{col = startCol, row = startRow, path = {}}}
    visited[startCol .. "," .. startRow] = true
    
    while #queue > 0 do
        local current = table.remove(queue, 1)
        local currentPath = current.path
        
        if current.col == targetCol and current.row == targetRow then
            return currentPath
        end
        
        local tile = self.map:getTile(current.col, current.row)
        if tile then
            local neighbors = self.map:getNeighbors(tile, 1)
            for _, neighbor in ipairs(neighbors) do
                local nkey = neighbor.col .. "," .. neighbor.row
                if not visited[nkey] then
                    visited[nkey] = true
                    local nTile = self.map:getTile(neighbor.col, neighbor.row)
                    if nTile and nTile.isLand then
                        -- Check if tile is occupied by another piece
                        -- Allow passing through friendly pieces (if movingTeam is provided)
                        -- Only allow path through the target destination
                        local occupiedByOther = false
                        if not (neighbor.col == targetCol and neighbor.row == targetRow) then
                            local occupier = self:getPieceAt(neighbor.col, neighbor.row)
                            if occupier then
                                if movingTeam and occupier.team == movingTeam then
                                    -- friendly piece: allow pass-through
                                    occupiedByOther = false
                                else
                                    occupiedByOther = true
                                end
                            end
                        end

                        if not occupiedByOther then
                            local newPath = {}
                            for _, p in ipairs(currentPath) do
                                table.insert(newPath, p)
                            end
                            table.insert(newPath, {col = neighbor.col, row = neighbor.row})
                            table.insert(queue, {col = neighbor.col, row = neighbor.row, path = newPath})
                        end
                    end
                end
            end
        end
    end
    return {}
end

-- Find the quickest path minimizing number of movement segments (turns).
-- Steps per segment = moveRange. Hills force segment end when entered.
-- movingTeam allows passing through friendly pieces.
function Game:findQuickestPath(startCol, startRow, targetCol, targetRow, movingTeam, moveRange)
    moveRange = moveRange or 1
    -- Priority queue implemented as simple list sorted by (turns, pathLength)
    local function makeKey(c, r, s)
        return tostring(c) .. "," .. tostring(r) .. "," .. tostring(s)
    end

    local startState = {col = startCol, row = startRow, stepsLeft = moveRange, turns = 0, path = {}}
    local open = {startState}
    local best = {} -- best[key] = minimal turns seen for that state
    best[makeKey(startCol, startRow, moveRange)] = 0

    local function popBest()
        if #open == 0 then return nil end
        -- table.sort(open, function(a,b)
        --     if a.turns ~= b.turns then return a.turns < b.turns end
        --     return #a.path < #b.path
        -- end)
        table.sort(open, function(a, b)
            if a.turns ~= b.turns then
                return a.turns < b.turns
            end
            -- prefer states that used MORE steps in the current turn
            return a.stepsLeft > b.stepsLeft
        end)
        return table.remove(open, 1)
    end

    while true do
        local cur = popBest()
        if not cur then break end
        if cur.col == targetCol and cur.row == targetRow then
            return cur.path
        end

        local tile = self.map:getTile(cur.col, cur.row)
        if not tile then goto continue end
        local neighbors = self.map:getNeighbors(tile, 1)
        for _, neighbor in ipairs(neighbors) do
            local ncol, nrow = neighbor.col, neighbor.row
            local nTile = self.map:getTile(ncol, nrow)
            if not nTile or not nTile.isLand then goto next_neighbor end

            -- Get occupiers at this neighbor tile
            local occupierPiece = self:getPieceAt(ncol, nrow)
            
            -- Block only enemy/neutral pieces - allow friendly pieces to be passed through
            -- The waypoint breaking logic will handle avoiding landing on friendlies
            if occupierPiece and movingTeam and occupierPiece.team ~= movingTeam then
                -- Occupied by enemy or neutral piece - cannot pass through
                goto next_neighbor
            end

            -- Determine if we need to start a new segment for this step
            local startedNewSegment = false
            local newTurns = cur.turns
            local newStepsLeft = cur.stepsLeft

            if newStepsLeft <= 0 then
                newTurns = newTurns + 1
                startedNewSegment = true
                newStepsLeft = moveRange - 1
            else
                newStepsLeft = newStepsLeft - 1
            end

            -- If entering a hill, movement ends: force stepsLeft to 0 and increment turns if we didn't already start one for this move
            if nTile.isHill then
                if not startedNewSegment then
                    newTurns = newTurns + 1
                end
                newStepsLeft = 0
            end

            local key = makeKey(ncol, nrow, newStepsLeft)
            if not best[key] or newTurns < best[key] then
                best[key] = newTurns
                local newPath = {}
                for _, v in ipairs(cur.path) do table.insert(newPath, v) end
                table.insert(newPath, {col = ncol, row = nrow})
                table.insert(open, {col = ncol, row = nrow, stepsLeft = newStepsLeft, turns = newTurns, path = newPath})
            end
            ::next_neighbor::
        end
        ::continue::
    end
    return {}
end
-- Predict where pieces will be at the end of the current turn
-- This helps avoid setting waypoints that would collide with friendly pieces
-- Returns a set of {col, row} positions occupied by friendly pieces after movement
function Game:getPredictedFriendlyOccupancy(movingPiece)
    local occupiedTiles = {}
    
    -- Check current positions of all friendly pieces except the moving one
    for _, piece in ipairs(self.pieces) do
        if piece.team == movingPiece.team and piece ~= movingPiece then
            -- If piece is already moved this turn, it won't move again
            -- If piece is not yet moved and has waypoints, predict its final position after move
            if piece.hasMoved then
                -- Piece has moved, mark current position
                table.insert(occupiedTiles, {col = piece.col, row = piece.row})
            else
                -- Piece hasn't moved yet
                if piece.waypoints and #piece.waypoints > 0 then
                    -- Has waypoints, will move - check where it will end up
                    local wpIndex = piece.currentWaypointIndex or 1
                    if wpIndex > 0 and wpIndex <= #piece.waypoints then
                        local currentWp = piece.waypoints[wpIndex]
                        -- This piece will try to reach its current waypoint
                        table.insert(occupiedTiles, {col = currentWp.col, row = currentWp.row})
                    end
                else
                    -- No waypoints, stays in place
                    table.insert(occupiedTiles, {col = piece.col, row = piece.row})
                end
            end
        end
    end
    
    return occupiedTiles
end

-- Helper function to check if a tile is occupied by a friendly piece (predicted)
-- Bases are NOT considered blocking
function Game:isTileOccupiedByFriendlyPiece(col, row, movingPiece, predictedOccupancy)
    for _, occupied in ipairs(predictedOccupancy) do
        if occupied.col == col and occupied.row == row then
            return true
        end
    end
    return false
end

-- Break a full path into movement-sized segments (waypoints)
-- segmentSize should be the piece's moveRange
-- Returns waypoints at multiples of segmentSize, plus the final waypoint
-- Dynamically adjusts segment size to avoid friendly piece collisions
function Game:breakPathIntoSegments(fullPath, segmentSize, movingPiece)
    local segments = {}
    
    if not fullPath or #fullPath == 0 then return segments end
    
    -- Get predicted friendly occupancy for the end of turn
    local predictedOccupancy = self:getPredictedFriendlyOccupancy(movingPiece)
    
    -- Also add current positions of all friendly pieces that might be in the way
    for _, piece in ipairs(self.pieces) do
        if piece.team == movingPiece.team and piece ~= movingPiece then
            local alreadyInList = false
            for _, occ in ipairs(predictedOccupancy) do
                if occ.col == piece.col and occ.row == piece.row then
                    alreadyInList = true
                    break
                end
            end
            if not alreadyInList then
                table.insert(predictedOccupancy, {col = piece.col, row = piece.row})
            end
        end
    end
    
    local currentIndex = 1
    
    while currentIndex <= #fullPath do
        local maxReach = math.min(currentIndex + segmentSize - 1, #fullPath)
        local safeEndpoint = nil
        
        -- Find the furthest safe point we can reach in this segment
        -- Work backwards from maxReach to ensure we get the longest valid movement
        for checkIndex = maxReach, currentIndex, -1 do
            local tile = fullPath[checkIndex]
            local t = nil
            if tile and tile.col and tile.row then
                t = self.map:getTile(tile.col, tile.row)
            end
            
            -- Check if this tile is safe (no friendly piece collision)
            local isSafe = not self:isTileOccupiedByFriendlyPiece(tile.col, tile.row, movingPiece, predictedOccupancy)
            local isHill = t and t.isHill
            
            -- Valid endpoints: safe tile, or if it's the target destination (allow it)
            if isSafe then
                safeEndpoint = checkIndex
                break
            elseif isHill and checkIndex > currentIndex then
                -- Hill forces end at previous tile
                safeEndpoint = checkIndex - 1
                break
            end
        end
        
        if safeEndpoint then
            table.insert(segments, fullPath[safeEndpoint])
            currentIndex = safeEndpoint + 1
        else
            -- No safe endpoint found in this segment, skip to next tile and try again
            currentIndex = currentIndex + 1
        end
    end
    
    return segments
end

function Game:endTurn()
    -- Can't end turn during placement phase
    if self.state == "placing" then
        return
    end
    
    -- Process waypoint moves for the team that's about to end their turn
    self:processWaypointMoves(self.currentTurn)

    -- Store replay actions for this turn (for the enemy to view next turn)
    local teamThatEnded = self.currentTurn
    local enemyTeam = (teamThatEnded == 1) and 2 or 1
    self.replay:storeTurnReplay(enemyTeam, teamThatEnded)

    pcall(function()
        print("[DEBUG] Stored replay for team " .. tostring(enemyTeam) .. ": " .. tostring(#self.replay.turnReplays[enemyTeam]) .. " actions.")
        for i, act in ipairs(self.replay.turnReplays[enemyTeam]) do
            print("[DEBUG] Replay action " .. i .. ": " .. (act.action or "nil"))
        end
    end)
    
    -- If connected and not the host, request the host to end the turn instead
    if Network and Network.isConnected and Network.isConnected() and not self.isHost and not self._applyingRemote then
        pcall(function()
            if Network and Network.send then Network.send({type = "endTurnRequest"}) end
        end)
        return
    end
    
    -- Apply supply consumption and attrition only for the team that just ended their turn
    local teamThatEnded = self.currentTurn
    for _, piece in ipairs(self.pieces) do
        if piece.team == teamThatEnded then
            -- Process building progress
            if piece.isBuilding and piece.buildingTurnsRemaining then
                piece.buildingTurnsRemaining = piece.buildingTurnsRemaining - 1
                
                -- Check if building is complete (0 or less turns remaining)
                if piece.buildingTurnsRemaining <= 0 then
                    -- Place the completed structure
                    if piece.buildingType == "resource_mine" then
                        -- Mark the resource as having a mine and owned by the team
                        if piece.buildingResourceTarget then
                            piece.buildingResourceTarget.hasMine = true
                            piece.buildingResourceTarget:capture(piece.buildingTeam)
                        end
                    else
                        -- It's a base structure (HQ, Ammo Depot, Supply Depot)
                        -- Add base and ensure network peers are informed (host authoritative)
                        self:addBase(piece.buildingType, piece.buildingTeam, piece.col, piece.row)
                        -- Hosted games will broadcast placed bases at end-turn; mark this base as justPlaced
                        -- (we added the base via addBase, which sets `justPlaced`)
                        -- Refresh fog so vision from this new base is applied immediately
                        if self.fogOfWar then
                            self.fogOfWar:updateVisibility(1, self.pieces, self.bases, self.teamStartingCorners)
                            self.fogOfWar:updateVisibility(2, self.pieces, self.bases, self.teamStartingCorners)
                        end
                    end
                    
                    -- Clear building state completely
                    piece.isBuilding = false
                    piece.buildingType = nil
                    piece.buildingTurnsRemaining = 0
                    piece.buildingTeam = nil
                    piece.buildingResourceTarget = nil
                    piece.hasMoved = false  -- Reset hasMoved so engineer can act on their next turn
                end
            end
            
            piece:consumeSupply()  -- Reduce supply by 1 turn first
            piece:applyAttrition()  -- Take damage if out of supply
            
            -- Then check if piece is within range of any friendly base for resupply
            -- This resupplies them to full for the next turn
            self:resupplyPieceFromBases(piece)
        end
        
        -- Remove dead pieces (from attrition or other damage) for all teams
        if piece.hp <= 0 then
            for i, p in ipairs(self.pieces) do
                if p == piece then
                    table.remove(self.pieces, i)
                    break
                end
            end
        end
    end
    
    -- Generate resources from captured resource tiles
    self:generateResourceIncome(teamThatEnded)
    
    if self.selectedPiece then
        self.selectedPiece:deselect(self)
    end

    -- If host, broadcast any bases that were just completed/placed during this turn so peers register them
    if self.isHost and Network and Network.isConnected and Network.isConnected() then
        for _, b in ipairs(self.bases) do
            if b.justPlaced then
                pcall(function()
                    self:sendCommit({type = "placeBase", team = b.team, col = b.col, row = b.row, baseType = b.type})
                end)
                b.justPlaced = nil
            end
        end
        -- Broadcast any newly created units (pieces) that were built this turn
        for _, p in ipairs(self.pieces) do
            if p.justPlaced then
                pcall(function()
                    self:sendCommit({type = "placePiece", team = p.team, col = p.col, row = p.row, unitType = p.type})
                end)
                p.justPlaced = nil
            end
        end
    end

    -- Capture-on-hold: if the team that just ended its turn has an exclusive piece on an enemy base tile,
    -- mark the base as pending capture so the enemy has one full turn to contest it.
    do
        local team = teamThatEnded
        for _, b in ipairs(self.bases) do
            if b.col and b.row and b.col > 0 and b.row > 0 then
                if b.team and b.team ~= team then
                    local capturerPresent = false
                    local ownerPresent = false
                    for _, p in ipairs(self.pieces) do
                        if p.col == b.col and p.row == b.row then
                            if p.team == team then capturerPresent = true end
                            if p.team == b.team then ownerPresent = true end
                        end
                    end
                    if capturerPresent and not ownerPresent then
                        -- Mark pending capture by this team; will be resolved when that team next becomes active
                        b.capturePending = team
                        b.capturePendingSince = self.turnCount
                        pcall(function() print(string.format("[game] base at %d,%d pending capture by team %d (was %d)", b.col, b.row, team, b.team)) end)
                    else
                        -- If conditions not met, clear any pending flag
                        if b.capturePending then
                            b.capturePending = nil
                            b.capturePendingSince = nil
                        end
                    end
                end
            end
        end
    end
    
    -- Networked games should switch immediately and inform peer; hotseat behavior only when not networked
    if self.hotseatEnabled and (not Network or not Network.isConnected or not Network.isConnected()) then
        -- Start hotseat pass: prompt players to pass the device before switching
        self.passPending = true
        self.pendingNextTeam = self.currentTurn == 1 and 2 or 1
    else
        -- Immediate turn switch for networked or dev mode
        local nextTeam = self.currentTurn == 1 and 2 or 1
        self.currentTurn = nextTeam
        if self.currentTurn == 1 then
            self.turnCount = self.turnCount + 1
        end
        for _, piece in ipairs(self.pieces) do
            if piece.team == self.currentTurn then
                piece:resetMove()
            end
        end

        -- Sync mines from OPPONENT'S previous turn before we start OUR turn
        -- This ensures we see enemy mines before our pieces can trigger them
        local opponentTeam = self.currentTurn == 1 and 2 or 1
        if self.replay.preTurnSnapshots and self.replay.preTurnSnapshots[opponentTeam] then
            local snap = self.replay.preTurnSnapshots[opponentTeam]
            if snap.mines then
                for _, mineData in ipairs(snap.mines) do
                    if not self:getMineAt(mineData.col, mineData.row) then
                        local mine = {
                            col = mineData.col,
                            row = mineData.row,
                            team = mineData.team,
                            damage = mineData.damage or 5,
                            revealedTo = mineData.revealedTo and table.shallow_copy(mineData.revealedTo) or nil
                        }
                        self:addMine(mine)
                    end
                end
            end
        end

        -- Always switch localTeam to match currentTurn BEFORE starting replay so the view is correct
        self.localTeam = self.currentTurn

        -- Save board snapshot at the START of this team's turn (BEFORE they move)
        -- This snapshot is used to restore the board when replaying the enemy's actions
        self.replay:saveBoardSnapshotForTeam(self.currentTurn, self.pieces, self.mines)

        -- Start replay for the new team if there are actions to show
        self.replay:beginReplay(self.currentTurn)
        pcall(function()
            print("[REPLAY DEBUG] beginReplay called for team " .. tostring(self.currentTurn))
            print("[REPLAY DEBUG] replayActive = " .. tostring(self.replay.replayActive))
            print("[REPLAY DEBUG] currentReplay length = " .. tostring(self.replay.currentReplay and #self.replay.currentReplay or 0))
        end)
        -- Start replay if there are actions to show
        if self.replay.replayActive then
            -- Restore board state snapshot for replay (snapshot paired with stored replay for this team)
            local snap = self.replay:getBoardSnapshot(self.currentTurn)
            if snap then
                print("[REPLAY] Snapshot has " .. tostring(#snap) .. " pieces")
                for i, pdata in ipairs(snap) do
                    print("[REPLAY] Snapshot piece " .. i .. ": type=" .. tostring(pdata.type) .. " team=" .. tostring(pdata.team) .. " at (" .. tostring(pdata.col) .. "," .. tostring(pdata.row) .. ")")
                end
                -- Rebuild piece list from snapshot, reusing existing piece objects where possible
                local newPieces = {}
                -- Create a mutable list of candidates from current pieces to match against
                local candidates = {}
                for _, p in ipairs(self.pieces) do table.insert(candidates, p) end

                for _, pdata in ipairs(snap) do
                    -- Prefer a candidate at the same position first
                    local foundIdx = nil
                    for i, c in ipairs(candidates) do
                        if c.col == pdata.col and c.row == pdata.row and c.team == pdata.team and c.type == pdata.type then
                            foundIdx = i
                            break
                        end
                    end
                    -- If not found, try any candidate matching team+type
                    if not foundIdx then
                        for i, c in ipairs(candidates) do
                            if c.team == pdata.team and c.type == pdata.type then
                                foundIdx = i
                                break
                            end
                        end
                    end

                    if foundIdx then
                        local existing = table.remove(candidates, foundIdx)
                        existing.col = pdata.col
                        existing.row = pdata.row
                        existing.hexTile = self.map:getTile(pdata.col, pdata.row)
                        existing.hp = pdata.hp
                        existing.veteran = pdata.veteran
                        existing.hiddenInForest = pdata.hiddenInForest
                        if pdata.revealedTo then existing.revealedTo = table.shallow_copy(pdata.revealedTo) end
                        table.insert(newPieces, existing)
                    else
                        local piece = Piece.new(pdata.type, pdata.team, self.map, pdata.col, pdata.row)
                        piece.hp = pdata.hp
                        piece.veteran = pdata.veteran
                        piece.hiddenInForest = pdata.hiddenInForest
                        if pdata.revealedTo then piece.revealedTo = table.shallow_copy(pdata.revealedTo) end
                        table.insert(newPieces, piece)
                    end
                end

                -- Replace the current pieces list with the rebuilt one (drop unmatched old pieces)
                self.pieces = newPieces
                print("[REPLAY] Applied snapshot; total pieces now " .. tostring(#self.pieces))
                
                -- Restore mines from snapshot
                if snap.mines then
                    -- self.mines = {}
                    for _, mineData in ipairs(snap.mines) do
                        local mine = {
                            col = mineData.col,
                            row = mineData.row,
                            team = mineData.team,
                            damage = mineData.damage or 5,
                            revealedTo = mineData.revealedTo and table.shallow_copy(mineData.revealedTo) or nil
                        }
                        table.insert(self.mines, mine)
                    end
                    print("[REPLAY] Applied snapshot; restored " .. tostring(#self.mines) .. " mines")
                end
            end
            self.state = "replay"
            -- Show overlay first; actual replay animations start after overlay dismissed
            self._replayOverlay = true
            self._replayOverlayTimer = 1.5 -- seconds before auto-start; user can press Space to dismiss sooner
            pcall(function() print("[REPLAY DEBUG] STATE SET TO REPLAY (overlay active)") end)
        else
            self.state = "playing"
            pcall(function() print("[REPLAY DEBUG] STATE SET TO PLAYING (no replay actions)") end)
        end

        -- Recompute air superiority at the start of the new turn (once-per-turn)
        self.airSuperiorityMap = self:calculateAirSuperiorityMap()
        if self.fogOfWar then
            self.fogOfWar:updateVisibility(1, self.pieces, self.bases, self.teamStartingCorners)
            self.fogOfWar:updateVisibility(2, self.pieces, self.bases, self.teamStartingCorners)
        end
        -- Resolve any pending base captures for the team that just became active
        for _, b in ipairs(self.bases) do
            if b.capturePending and b.capturePending == self.currentTurn then
                -- Check if capturer still exclusively occupies the base tile
                local capturerPresent = false
                local ownerPresent = false
                for _, p in ipairs(self.pieces) do
                    if p.col == b.col and p.row == b.row then
                        if p.team == self.currentTurn then capturerPresent = true end
                        if p.team == b.team then ownerPresent = true end
                    end
                end
                if capturerPresent and not ownerPresent then
                    pcall(function() print(string.format("[game] base at %d,%d capture finalized: team %d (was %d)", b.col, b.row, self.currentTurn, b.team)) end)
                    b.team = self.currentTurn
                    b.capturePending = nil
                    b.capturePendingSince = nil
                    -- Update fog visibility and air superiority to reflect new base ownership
                    if self.fogOfWar then
                        self.fogOfWar:updateVisibility(1, self.pieces, self.bases, self.teamStartingCorners)
                        self.fogOfWar:updateVisibility(2, self.pieces, self.bases, self.teamStartingCorners)
                    end
                    self.airSuperiorityMap = self:calculateAirSuperiorityMap()
                    -- Broadcast as placeBase commit for peers
                    if self.isHost and Network and Network.isConnected and Network.isConnected() and not self._applyingRemote then
                        pcall(function()
                            self:sendCommit({type = "placeBase", team = b.team, col = b.col, row = b.row, baseType = b.type})
                        end)
                    end
                else
                    -- Cancel pending if contested or capturer gone
                    b.capturePending = nil
                    b.capturePendingSince = nil
                end
            end
        end
        -- Notify remote peer of end-turn (if connected and this is a local action)
        if Network and Network.isConnected and Network.isConnected() and not self._applyingRemote then
            pcall(function()
                self:sendCommit({type = "endTurn", nextTeam = nextTeam, teamResources1 = self.teamResources[1], teamResources2 = self.teamResources[2], teamOil1 = self.teamOil[1], teamOil2 = self.teamOil[2]})
            end)
        end
    end
end

function Game:confirmPass()
    if not self.passPending then return end

    -- Perform the actual turn switch now that players have passed the device
    self.currentTurn = self.pendingNextTeam or (self.currentTurn == 1 and 2 or 1)
    if self.currentTurn == 1 then
        self.turnCount = self.turnCount + 1
    end

    -- Reset move status for ALL pieces of the current team at the START of their turn
    for _, piece in ipairs(self.pieces) do
        if piece.team == self.currentTurn then
            piece:resetMove()
        end
    end

    -- Clear pending state
    self.passPending = false
    self.pendingNextTeam = nil
    if self.selectedPiece then
        self.selectedPiece:deselect(self)
    end
end

function Game:isInStartingArea(col, row, team)
    -- Check if position is within the team's starting area (top or bottom 5 rows)
    -- If a start sector has been selected for this team, restrict to that sector
    if self.selectedStartSector and self.selectedStartSector[team] then
        local sIdx = self.selectedStartSector[team]
        if self.tileToSector then
            local key = tostring(col) .. "," .. tostring(row)
            return self.tileToSector[key] == sIdx
        end
    end
    -- Fallback to legacy rectangular starting areas
    local area = self.teamStartingAreas[team]
    if not area then return false end
    return row >= area.rowStart and row <= area.rowEnd
end

-- Update fog of war visibility based on game state
function Game:updateFogVisibility()
    if not self.fogOfWar or not self.startSectors then return end
    
    if self.state == "zone_draft" then
        -- During zone draft, show only the current drafting team's 3 revealed zones
        local draftTeam = self.zoneDraftTeam
        for team = 1, 2 do
            -- Hide everything by default
            for col = 1, self.mapWidth do
                for row = 1, self.mapHeight do
                    self.fogOfWar:setTileVisible(team, col, row, false)
                end
            end
            
            -- For the drafting team, reveal their 3 candidate zones
            if team == draftTeam and self.revealedCandidates and self.revealedCandidates[draftTeam] then
                for _, sectorId in ipairs(self.revealedCandidates[draftTeam]) do
                    local sector = self.startSectors[sectorId]
                    if sector then
                        for _, t in ipairs(sector.tiles) do
                            self.fogOfWar:setTileVisible(team, t.col, t.row, true)
                        end
                    end
                end
            end
        end
    elseif self.state == "placing" then
        self:updatePlacementPhaseVisibility()
    end
end

-- Update fog of war visibility for placement phase (only selected zone visible)
function Game:updatePlacementPhaseVisibility()
    if self.state ~= "placing" or not self.startSectors then return end
    
    -- For each team, set visibility only for their selected zone (if in placement)
    for team = 1, 2 do
        -- First, disable all visibility
        for col = 1, self.mapWidth do
            for row = 1, self.mapHeight do
                self.fogOfWar:setTileVisible(team, col, row, false)
            end
        end
        
        -- Then, enable visibility only in their selected zone
        if self.selectedStartSector and self.selectedStartSector[team] then
            local sectorId = self.selectedStartSector[team]
            local sector = self.startSectors[sectorId]
            if sector then
                for _, t in ipairs(sector.tiles) do
                    self.fogOfWar:setTileVisible(team, t.col, t.row, true)
                end
            end
        end
    end
end

-- When a piece/base is placed, fog is already set via updatePlacementPhaseVisibility
-- No need for revealPlacementZone anymore since we control it via selectedStartSector
function Game:revealPlacementZone(col, row, team)
    -- No-op: visibility is now managed by updatePlacementPhaseVisibility
    -- based on selectedStartSector
end

-- Generate perimeter start sectors: N even zones around edge, proportional to map size
function Game:generateStartSectors(n)
    n = n or 8
    self.startSectors = {}
    self.tileToSector = {}

    -- Find map center
    local centerCol = math.ceil(self.mapWidth / 2)
    local centerRow = math.ceil(self.mapHeight / 2)
    local cx, cy = self.map:gridToPixels(centerCol, centerRow)

    -- Collect all tiles (land and mountains) and compute the actual radius
    local landTiles = {}
    local maxDist = 0
    for col = 1, self.mapWidth do
        for row = 1, self.mapHeight do
            local tile = self.map:getTile(col, row)
            if tile then  -- Include all tiles, not just land
                local px, py = self.map:gridToPixels(col, row)
                local dx = px - cx
                local dy = py - cy
                local dist = math.sqrt(dx * dx + dy * dy)
                table.insert(landTiles, {col = col, row = row, dist = dist})
                if dist > maxDist then maxDist = dist end
            end
        end
    end

    if #landTiles == 0 then return end

    -- Ring depth: proportional to map size (e.g., ~20% of radius from edge to center)
    -- This ensures zones are ~8 tiles deep at any map size
    local ringDepth = maxDist * 0.32
    local ringInnerRadius = maxDist - ringDepth

    -- Initialize N sectors (perimeter zones)
    for i = 1, n do
        self.startSectors[i] = {tiles = {}, centroidX = 0, centroidY = 0, count = 0, id = i, chosen = false}
    end

    -- Assign land tiles to sectors based on angle (only tiles in perimeter ring)
    for _, tdata in ipairs(landTiles) do
        if tdata.dist >= ringInnerRadius then  -- Within outer ring
            local px, py = self.map:gridToPixels(tdata.col, tdata.row)
            local ang = math.atan2(py - cy, px - cx)  -- -pi..pi
            local sectorIdx = math.floor(((ang + math.pi) / (2 * math.pi)) * n) + 1
            if sectorIdx < 1 then sectorIdx = 1 end
            if sectorIdx > n then sectorIdx = n end
            
            local s = self.startSectors[sectorIdx]
            table.insert(s.tiles, {col = tdata.col, row = tdata.row})
            s.centroidX = s.centroidX + px
            s.centroidY = s.centroidY + py
            s.count = s.count + 1
            self.tileToSector[tostring(tdata.col) .. "," .. tostring(tdata.row)] = sectorIdx
        end
    end

    -- Finalize centroids
    for i = 1, n do
        local s = self.startSectors[i]
        if s.count > 0 then
            s.centroidX = s.centroidX / s.count
            s.centroidY = s.centroidY / s.count
        else
            s.centroidX, s.centroidY = cx, cy
        end
    end

    return self.startSectors
end

-- Draw start-sector overlays when sector picking is active; otherwise existing behavior draws rectangular strips
function Game:drawStartSectors(viewTeam)
    if not self.startSectors then return end
    local n = #self.startSectors
    
    -- During zone_draft, only show zones for the current drafting team
    local showAllZones = (self.state ~= "zone_draft")
    
    for i, s in ipairs(self.startSectors) do
        local r, g, b = 0.5, 0.5, 0.5
        local alpha = 0.15
        local lineAlpha = 0.4
        
        -- During zone_draft, hide non-relevant zones
        if self.state == "zone_draft" then
            local draftTeam = self.zoneDraftTeam
            -- If team 1 already picked, only show team 1's selected zone; team 2 sees their revealed candidates
            if self.selectedStartSector and self.selectedStartSector[1] and draftTeam == 2 then
                -- Show only the current team's revealed candidates
                local isRevealed = false
                if self.revealedCandidates and self.revealedCandidates[draftTeam] then
                    for _, rid in ipairs(self.revealedCandidates[draftTeam]) do
                        if rid == i then isRevealed = true; break end
                    end
                end
                if not isRevealed then goto skip_zone end
                r, g, b = 1.0, 0.95, 0.6
                alpha = 0.40
                lineAlpha = 0.95
            elseif draftTeam == 1 and self.selectedStartSector and self.selectedStartSector[1] then
                -- Team 1 already picked, don't show any more zones to team 1
                goto skip_zone
            else
                -- Normal draft phase: show revealed candidates for drafting team
                local isRevealed = false
                if self.revealedCandidates and self.revealedCandidates[draftTeam] then
                    for _, rid in ipairs(self.revealedCandidates[draftTeam]) do
                        if rid == i then isRevealed = true; break end
                    end
                end
                
                if not isRevealed then
                    -- Skip drawing this zone
                    goto skip_zone
                end
                
                -- This zone is revealed for the drafting team: highlight it
                r, g, b = 1.0, 0.95, 0.6
                alpha = 0.40
                lineAlpha = 0.95
            end
        else
            -- During placement, only show the viewing team's selected zone
            if self.state == "placing" then
                -- Only draw this sector if it belongs to the viewing team
                if self.selectedStartSector and self.selectedStartSector[viewTeam] == i then
                    if viewTeam == 1 then r, g, b = 1, 0.2, 0.2
                    elseif viewTeam == 2 then r, g, b = 0.2, 0.4, 1 end
                    alpha = 0.50
                    lineAlpha = 1.0
                else
                    goto skip_zone
                end
            else
                -- Other states: show selected zones in team colors
                for team, sel in pairs(self.selectedStartSector or {}) do
                    if sel == i then
                        if team == 1 then r, g, b = 1, 0.2, 0.2
                        elseif team == 2 then r, g, b = 0.2, 0.4, 1 end
                        alpha = 0.50
                        lineAlpha = 1.0
                    end
                end
            end
        end

        love.graphics.setColor(r, g, b, alpha)
        for _, t in ipairs(s.tiles) do
            local tile = self.map:getTile(t.col, t.row)
            if tile and tile.points then love.graphics.polygon("fill", tile.points) end
        end

        -- draw outline and label at centroid
        love.graphics.setColor(r, g, b, lineAlpha)
        love.graphics.setLineWidth(2)
        for _, t in ipairs(s.tiles) do
            local tile = self.map:getTile(t.col, t.row)
            if tile and tile.points then love.graphics.polygon("line", tile.points) end
        end
        love.graphics.setLineWidth(1)
        
        -- Draw purple border at the outer edge of zone tiles (only for radial maps)
        if self.mapGeneratorUsed == "radial" then
            -- Get the external edges of this zone's tiles
            local edges = self:calculateExternalEdges(s.tiles)
            
            -- Draw the border in purple
            love.graphics.setColor(0.8, 0.2, 1.0, 0.9)  -- Purple, high visibility
            love.graphics.setLineWidth(3)
            
            for _, e in ipairs(edges) do
                love.graphics.line(e[1], e[2], e[3], e[4])
            end
            love.graphics.setLineWidth(1)
        end
        
        if s.centroidX and s.centroidY then
            love.graphics.setFont(love.graphics.newFont(16))
            love.graphics.setColor(1,1,1,1.0)
            love.graphics.printf(tostring(i), s.centroidX - 10, s.centroidY - 10, 20, "center")
        end
        
        ::skip_zone::
    end
    love.graphics.setColor(1,1,1,1)
end

function Game:placePiece(col, row, team)
    -- Check if tile is valid (must be land and not occupied)
    local tile = self.map:getTile(col, row)
    if not tile or not tile.isLand then
        return  -- Can't place on water or invalid tile
    end
    
    local teamToPlace = team or self.placementTeam
    -- Check if position is within the team's starting area (unless freePlacement is enabled)
    if not self.freePlacement then
        if not self:isInStartingArea(col, row, teamToPlace) then
            return  -- Can't place outside starting area
        end
    end
    
    -- Check if tile is already occupied
    local occupier = self:getPieceAt(col, row)
    if occupier then
        -- If in placement phase and clicking your own placed piece, remove it and return it to unplaced pool
        if self.state == "placing" and occupier.team == teamToPlace then
            occupier.col = 0
            occupier.row = 0
            occupier.hexTile = nil
            self.piecesPlaced = math.max(0, (self.piecesPlaced or 0) - 1)
            -- Do not update fog during placement; leave visibility as-is
            pcall(function() print(string.format("[game] removed placed piece of team %s at (%d,%d)", tostring(occupier.team), col, row)) end)
            return
        end
        return  -- Tile already has a piece
    end
    
    -- Find the first unplaced piece for the requested team
    for _, piece in ipairs(self.pieces) do
        if piece.team == teamToPlace and piece.col == 0 and piece.row == 0 then
            -- If networked client, request placement from host
            if Network and Network.isConnected and Network.isConnected() and not self.isHost and not self._applyingRemote then
                pcall(function()
                    Network.send({type = "placePieceRequest", team = teamToPlace, col = col, row = row, unitType = piece.type})
                end)
                return
            end
            -- Place this piece (host or local play)
            piece:setPosition(col, row)
            self.piecesPlaced = self.piecesPlaced + 1
            
            -- Reveal placement zone for this team (permanent visibility in that sector)
            self:revealPlacementZone(col, row, teamToPlace)
            
            -- Skip refreshing fog visibility during placement phase (keep cached visibility)
            if self.fogOfWar and self.state ~= "placing" then
                self.fogOfWar:updateVisibility(teamToPlace, self.pieces, self.bases, self.teamStartingCorners)
                self.fogOfWar:updateVisibility((teamToPlace == 1) and 2 or 1, self.pieces, self.bases, self.teamStartingCorners)
            end
            -- If host, broadcast commit
            if Network and Network.isConnected and Network.isConnected() and self.isHost and not self._applyingRemote then
                self:sendCommit({type = "placePiece", team = teamToPlace, col = col, row = row, unitType = piece.type})
            end
            
            -- Check if both teams have finished placing pieces; if so, move to bases phase
            local team1Placed = 0
            local team2Placed = 0
            for _, p in ipairs(self.pieces) do
                if p.team == 1 and p.col > 0 and p.row > 0 then team1Placed = team1Placed + 1 end
                if p.team == 2 and p.col > 0 and p.row > 0 then team2Placed = team2Placed + 1 end
            end
            if team1Placed >= self.piecesPerTeam and team2Placed >= self.piecesPerTeam then
                self.placementPhase = "bases"
                pcall(function() print("[game] both teams finished pieces — entering base placement phase") end)
                if Network and Network.isConnected and Network.isConnected() and not self._applyingRemote then
                    pcall(function()
                        self:sendCommit({type = "placementPhase", phase = "bases"})
                    end)
                end
            end
            return
        end
    end
end

function Game:placeBase(col, row, team)
    -- Check if tile is valid (must be land and not occupied)
    local tile = self.map:getTile(col, row)
    if not tile or not tile.isLand then
        return  -- Can't place on water or invalid tile
    end
    
    -- Determine which team is placing (allow optional team arg)
    local teamToPlace = team or self.placementTeam
    -- Check if position is within the team's starting area (unless freePlacement is enabled)
    if not self.freePlacement then
        if not self:isInStartingArea(col, row, teamToPlace) then
            return  -- Can't place outside starting area
        end
    end
    pcall(function() print(string.format("[game] placeBase attempt team=%s col=%s row=%s placementPhase=%s", tostring(teamToPlace), tostring(col), tostring(row), tostring(self.placementPhase))) end)
    
    -- Check if tile already contains a base: if in placement phase and it's your own base, remove it
    local occupier = self:getBaseAt(col, row)
    if occupier then
        -- If in placement phase and clicking your own placed base, remove it and return it to unplaced pool
        if self.state == "placing" and occupier.team == teamToPlace then
            occupier.col = 0
            occupier.row = 0
            occupier.hexTile = nil
            self.basesPlaced = math.max(0, (self.basesPlaced or 0) - 1)
            -- Do not update fog during placement; leave visibility as-is
            pcall(function() print(string.format("[game] removed placed base of team %s at (%d,%d)", tostring(occupier.team), col, row)) end)
            return
        end
        return  -- Tile already has something
    end
    
    -- Check if tile already occupied by piece
    if self:getPieceAt(col, row) then
        return  -- Tile already has a piece
    end
    
    -- Find the first unplaced base for the requested team
    for _, base in ipairs(self.bases) do
        if base.team == teamToPlace and base.col == 0 and base.row == 0 then
            -- If networked client, request base placement from host
            if Network and Network.isConnected and Network.isConnected() and not self.isHost and not self._applyingRemote then
                pcall(function()
                    Network.send({type = "placeBaseRequest", team = teamToPlace, col = col, row = row, baseType = base.type})
                end)
                return
            end

            -- Local placement (host or single-player): delegate to helper
            self:applyPlaceBase(teamToPlace, col, row, base.type)
            
            -- Reveal placement zone for this team (permanent visibility in that sector)
            self:revealPlacementZone(col, row, teamToPlace)

            -- Skip refreshing fog visibility during placement phase (keep cached visibility)
            if self.fogOfWar and self.state ~= "placing" then
                self.fogOfWar:updateVisibility(teamToPlace, self.pieces, self.bases, self.teamStartingCorners)
                self.fogOfWar:updateVisibility((teamToPlace == 1) and 2 or 1, self.pieces, self.bases, self.teamStartingCorners)
            end

            -- If host, broadcast commit
            if Network and Network.isConnected and Network.isConnected() and self.isHost and not self._applyingRemote then
                self:sendCommit({type = "placeBase", team = teamToPlace, col = col, row = row, baseType = base.type})
            end

            -- Check if both teams have finished placing bases; if so, move to ready phase
            local team1Bases = 0
            local team2Bases = 0
            for _, b in ipairs(self.bases) do
                if b.team == 1 and b.col > 0 and b.row > 0 then team1Bases = team1Bases + 1 end
                if b.team == 2 and b.col > 0 and b.row > 0 then team2Bases = team2Bases + 1 end
            end
            if team1Bases >= self.basesPerTeam and team2Bases >= self.basesPerTeam then
                self.placementPhase = "ready"
                pcall(function() print("[game] both teams finished bases — entering ready phase") end)
                if Network and Network.isConnected and Network.isConnected() and not self._applyingRemote then
                    pcall(function()
                        self:sendCommit({type = "placementPhase", phase = "ready"})
                    end)
                end
            end
            return
        end
    end
end





function Game:resetGame()
    self.pieces = {}
    self.bases = {}
    self.resources = {}
    self.teamResources = {[1] = 0, [2] = 0}
    self.currentTurn = 1
    self.turnCount = 0
    self.state = "placing"
    self.piecesPlaced = 0
    self.basesPlaced = 0
    self.placementTeam = 1
    self.placementPhase = "pieces"
    if self.selectedPiece then
        self.selectedPiece:deselect(self)
    end
    self.actionMenu = nil
    self.actionMenuContext = nil
    self.actionMenuContextType = nil
    self:initializePieces()
    self:initializeBases()
    self:generateResources()
end

-- Helper function to draw air defense radius ring and air superiority symbols
-- Used by both airbase and SAM units
function Game:drawAirDefenseRadius(col, row, radius, team, lineColor, lineWidth)
    lineWidth = lineWidth or 2
    
    -- Draw the outer ring
    local edges = self:getRingEdges(col, row, radius)
    if edges and #edges > 0 then
        love.graphics.setColor(lineColor[1], lineColor[2], lineColor[3], 0.7)
        love.graphics.setLineWidth(lineWidth)
        for _, e in ipairs(edges) do
            love.graphics.line(e[1], e[2], e[3], e[4])
        end
        love.graphics.setLineWidth(1)
        love.graphics.setColor(1, 1, 1, 1)
    end
    
    -- Draw air superiority symbols on tiles within radius
    local tiles = self:getTilesWithinRadius(col, row, radius)
    if tiles then
        for _, tile in ipairs(tiles) do
            local t1, t2 = self:getAirSuperiorityAt(tile.col, tile.row)
            local playerAS = (team == 1) and t1 or t2
            local enemyAS = (team == 1) and t2 or t1
            
            local symbol = nil
            if playerAS > 0 and playerAS == enemyAS then
                symbol = "="
            elseif playerAS > enemyAS then
                symbol = "^"
            elseif enemyAS > playerAS then
                symbol = "v"
            end
            
            if symbol then
                local px, py = self.map:gridToPixels(tile.col, tile.row)
                if symbol == "v" then
                    love.graphics.setColor(1, 0, 0)
                else
                    if team == 1 then love.graphics.setColor(1, 0, 0) else love.graphics.setColor(0, 0, 1) end
                end
                love.graphics.setFont(love.graphics.newFont(12))
                local w = love.graphics.getFont():getWidth(symbol)
                local h = love.graphics.getFont():getHeight()
                love.graphics.print(symbol, px - w/2, py - h/2)
            end
        end
    end
end

-- Prepare N candidate start sectors for a team, picking random zones (not pre-assigned)
function Game:prepareRevealForTeam(team, n)
    if not self.startSectors or #self.startSectors == 0 then return end
    self.revealedCandidates = self.revealedCandidates or {}
    
    -- Collect available (not yet chosen) sector ids
    local available = {}
    for sid, s in ipairs(self.startSectors) do
        if not s.chosen then table.insert(available, sid) end
    end
    
    if #available == 0 then return end

    -- Build set of sectors adjacent to any already-chosen sector
    local adjacentChosen = {}
    for sid, s in ipairs(self.startSectors) do
        if s.chosen then
            for _, t in ipairs(s.tiles) do
                local tile = self.map:getTile(t.col, t.row)
                if tile then
                    local neigh = self.map:getNeighbors(tile, 1)
                    for _, nk in ipairs(neigh) do
                        local key = tostring(nk.col) .. "," .. tostring(nk.row)
                        local osid = self.tileToSector[key]
                        if osid then adjacentChosen[osid] = true end
                    end
                end
            end
        end
    end

    -- Filter to exclude adjacent-to-chosen sectors (enforce at least 1 zone gap)
    local filtered = {}
    for _, sid in ipairs(available) do
        if not adjacentChosen[sid] then table.insert(filtered, sid) end
    end
    
    -- Fallback: if not enough non-adjacent, use all available
    if #filtered < n then filtered = available end

    -- Pick n random unique sectors from filtered
    local picks = {}
    local pool = {unpack(filtered)}
    -- Use team-based offset to ensure different results for each team
    math.randomseed(os.time() + team * 1000)
    for i = 1, math.min(n, #pool) do
        local idx = math.random(#pool)
        table.insert(picks, pool[idx])
        table.remove(pool, idx)
    end

    self.revealedCandidates[team] = picks
end

return Game
