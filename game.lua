-- Core game logic and state management

local Game = {}
Game.__index = Game


local Camera = require("camera")
local Piece = require("piece")
local Base = require("base")
local Resource = require("resource")
local ActionMenu = require("action_menu")
local FogOfWar = require("fog_of_war")
local Network = require("network")

function Game.new()
    local self = setmetatable({}, Game)
    
    -- Game state
    self.state = "placing"  -- "placing", "playing", "gameOver"
    self.currentTurn = 1    -- Team 1 or 2
    self.turnCount = 0
    
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
    self.mapHeight = 32
    self.map = HexMap.new(self.mapWidth, self.mapHeight, self.hexSideLength)
    self.map:initializeGrid()
    self:generateMapTerrain()
    
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
    
    -- Bases (structures)
    self.bases = {}
    self:initializeBases()
    
    -- Resources
    self.resources = {}
    self:generateResources()
    
    -- Resource currency (for building units/bases)
    self.teamResources = {[1] = 0, [2] = 0}  -- Resources owned by each team
    -- Oil resource (separate currency used for late-game units)
    self.teamOil = {[1] = 0, [2] = 0}

    -- Province/Region control data (disabled for now)
    self.provinces = nil
    self.regions = nil
    self.numProvinceCols = 2
    self.numProvinceRows = 2
    
    -- Fog of War system
    self.fogOfWar = FogOfWar.new(self.map, 2, self)
    
    -- Initialize starting areas as explored and visible for each team
    for team = 1, 2 do
        local area = self.teamStartingAreas[team]
        if area then
            for row = area.rowStart, area.rowEnd do
                for col = 1, self.mapWidth do
                    self.fogOfWar:setTileVisible(team, col, row, true)
                end
            end
        end
    end
    
    -- Input handling
    if self.selectedPiece then
        self.selectedPiece:deselect(self)
    end
    self.isDragging = false
    self.dragStartX = 0
    self.dragStartY = 0
    
    -- Action menu UI (reusable for bases, pieces, resources, etc.)
    self.actionMenu = nil  -- ActionMenu instance
    self.actionMenuContext = nil  -- Context object (base, piece, etc.) that opened the menu
    -- Hotseat pass control
    self.passPending = false
    self.pendingNextTeam = nil
    -- Hotseat/network/dev flags
    self.hotseatEnabled = true
    self.devMode = false
    -- Per-player ready flags for simultaneous placement
    self.playerReady = {[1] = false, [2] = false}
    
    return self
end

function Game:generateMapTerrain()
    -- Use region-stitch generator to create tileable strategic regions
    local success, _ = pcall(function() self.map:generateTerrain("region_stitch") end)
    if not success then
        -- Fallback to balanced if region_stitch unavailable
        print("Region-stitch terrain generator failed, falling back to balanced generator.")
        self.map:generateTerrain("balanced")
    end
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
    self:addBase("ammoDepot", 1, nil, nil)
    self:addBase("supplyDepot", 1, nil, nil)
    -- Add one airbase per player (unplaced at start)
    self:addBase("airbase", 1, nil, nil)
    
    -- Create bases for team 2: HQ, Ammo Depot, Supply Depot
    self:addBase("hq", 2, nil, nil)
    self:addBase("ammoDepot", 2, nil, nil)
    self:addBase("supplyDepot", 2, nil, nil)
    self:addBase("airbase", 2, nil, nil)
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

--     -- Build reverse map: provinceId -> list of tiles
--     local provinceTiles = {}
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
-- function Game:calculateExternalEdges(tiles)
--     local tileSet = {}
--     if not tiles then return {} end
--     if #tiles > 0 then
--         for _, t in ipairs(tiles) do
--             tileSet[t.col .. "," .. t.row] = true
--         end
--     else
--         -- assume table keyed style
--         for k, v in pairs(tiles) do
--             if v then tileSet[k] = true end
--         end
--     end

--     local edges = {}
--     for key, _ in pairs(tileSet) do
--         local comma = string.find(key, ",")
--         if not comma then goto continue_tile end
--         local col = tonumber(string.sub(key, 1, comma - 1))
--         local row = tonumber(string.sub(key, comma + 1))
--         local tile = self.map:getTile(col, row)
--         if not tile or not tile.points then goto continue_tile end

--         local offsets = self:getHexNeighborOffsets(col)
--         for i = 1, 6 do
--             local off = offsets[i]
--             local ncol = col + off[1]
--             local nrow = row + off[2]
--             local nkey = ncol .. "," .. nrow
--             if not tileSet[nkey] then
--                 -- Neighbor missing: pick the edge whose midpoint faces the neighbor center
--                 local cx, cy = self.map:gridToPixels(col, row)
--                 local ncx, ncy = self.map:gridToPixels(ncol, nrow)
--                 local vx, vy = ncx - cx, ncy - cy
--                 local vdist = math.sqrt(vx * vx + vy * vy)
--                 local vnx, vny = 0, 0
--                 if vdist > 0 then vnx, vny = vx / vdist, vy / vdist end

--                 local bestJ, bestDot = 1, -999
--                 -- Find edge midpoint most aligned with neighbor direction
--                 for j = 1, 6 do
--                     local p1j = (j - 1) * 2 + 1
--                     local p2j = (j % 6) * 2 + 1
--                     local ax = tile.points[p1j]
--                     local ay = tile.points[p1j + 1]
--                     local bx = tile.points[p2j]
--                     local by = tile.points[p2j + 1]
--                     local mx = (ax + bx) * 0.5
--                     local my = (ay + by) * 0.5
--                     local ex, ey = mx - cx, my - cy
--                     local ed = math.sqrt(ex * ex + ey * ey)
--                     if ed > 0 and vdist > 0 then
--                         local enx, eny = ex / ed, ey / ed
--                         local dot = enx * vnx + eny * vny
--                         if dot > bestDot then
--                             bestDot = dot
--                             bestJ = j
--                         end
--                     elseif vdist == 0 then
--                         bestJ = i
--                         break
--                     end
--                 end

--                 local p1i = (bestJ - 1) * 2 + 1
--                 local p2i = (bestJ % 6) * 2 + 1
--                 local ax = tile.points[p1i]
--                 local ay = tile.points[p1i + 1]
--                 local bx = tile.points[p2i]
--                 local by = tile.points[p2i + 1]

--                 -- Midpoint and inward normal
--                 local mx = (ax + bx) * 0.5
--                 local my = (ay + by) * 0.5
--                 local dx = cx - mx
--                 local dy = cy - my
--                 local distn = math.sqrt(dx * dx + dy * dy)
--                 local nx, ny = 0, 0
--                 if distn > 0 then nx, ny = dx / distn, dy / distn end

--                 -- Slightly smaller inset so borders sit closer to hex edges
--                 local inset = math.min(6, (self.hexSideLength or 32) * 0.12)
--                 local ox = nx * inset
--                 local oy = ny * inset

--                 local x1 = ax + ox
--                 local y1 = ay + oy
--                 local x2 = bx + ox
--                 local y2 = by + oy
--                 table.insert(edges, {x1, y1, x2, y2})
--             end
--         end
--         ::continue_tile::
--     end

--     return edges
-- end

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
        end
    end
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

    -- First, create resources marked by the map generator (tile.resourceType)
    local centerCol = math.floor(self.mapWidth / 2)
    local centerRow = math.floor(self.mapHeight / 2)
    local oilRadius = math.max(1, math.floor(math.min(self.mapWidth, self.mapHeight) * 0.35))
    for col = 1, self.mapWidth do
        for row = 1, self.mapHeight do
            local tile = self.map:getTile(col, row)
            if tile and tile.resourceType and tile.isLand and not self:getResourceAt(col, row) and not inStartingArea(col, row) then
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

    -- Generate a few additional generic resource tiles scattered across the map
    local numResources = 3  -- Number of extra generic resources to place
    for i = 1, numResources do
        local attempts = 0
        local placed = false
        while not placed and attempts < 100 do
            attempts = attempts + 1
            local col = math.random(5, self.mapWidth - 5)  -- Avoid edges
            local row = math.random(5, self.mapHeight - 5)
            local tile = self.map:getTile(col, row)
            if tile and tile.isLand then
                if not self:getPieceAt(col, row) and not self:getBaseAt(col, row) and not self:getResourceAt(col, row) and not inStartingArea(col, row) then
                    local resource = Resource.new("generic", self.map, col, row)
                    table.insert(self.resources, resource)
                    placed = true
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

    -- Place oil for upper half
    local tries = 0
    while countOilInHalf(true) < minOilPerSide and tries < 400 do
        tries = tries + 1
        local angle = math.random() * math.pi * 2
        local dist = math.random(0, oilRadius)
        local col = centerCol + math.floor(math.cos(angle) * dist + 0.5)
        local row = centerRow - math.abs(math.floor(math.sin(angle) * dist + 0.5)) - 1
        local tile = self.map:getTile(col, row)
        if tile and tile.isLand and not inStartingArea(col, row) and not self:getResourceAt(col, row) then
            local resource = Resource.new("oil", self.map, col, row)
            table.insert(self.resources, resource)
        end
    end

    -- Place oil for lower half
    tries = 0
    while countOilInHalf(false) < minOilPerSide and tries < 400 do
        tries = tries + 1
        local angle = math.random() * math.pi * 2
        local dist = math.random(0, oilRadius)
        local col = centerCol + math.floor(math.cos(angle) * dist + 0.5)
        local row = centerRow + math.abs(math.floor(math.sin(angle) * dist + 0.5)) + 1
        local tile = self.map:getTile(col, row)
        if tile and tile.isLand and not inStartingArea(col, row) and not self:getResourceAt(col, row) then
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
    table.insert(self.pieces, piece)
    -- If added with coordinates (mid-game build), mark so host will broadcast at end-turn
    if piece.col and piece.row and piece.col > 0 and piece.row > 0 then
        piece.justPlaced = true
        pcall(function() print(string.format("[game] addPiece local -> type=%s team=%s col=%s row=%s", tostring(pieceType), tostring(team), tostring(col), tostring(row))) end)
    end
end

function Game:update(dt)
    -- Update game logic here
    if self.state == "playing" then
        -- Update pieces, animations, etc.
        
        -- Calculate air superiority map once per update (cached) to avoid repeated expensive recalcs
        self.airSuperiorityMap = self:calculateAirSuperiorityMap()

        -- Update fog of war visibility for all teams (visibility logic will query cached air superiority)
        for team = 1, 2 do
            self.fogOfWar:updateVisibility(team, self.pieces, self.bases, self.teamStartingCorners)
        end
        -- network messages are polled by main.lua and forwarded to Game:handleNetworkMessage
    elseif self.state == "placing" then
        -- Update fog of war for the team that's placing (or local team if networked)
        local viewTeam = self.localTeam or self.placementTeam
        self.fogOfWar:updateVisibility(viewTeam, self.pieces, self.bases, self.teamStartingCorners)
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
                self:applyRemoteMove({fromCol = fromCol, fromRow = fromRow, toCol = toCol, toRow = toRow})
                -- Broadcast authoritative commit
                self:sendCommit({type = "move", fromCol = fromCol, fromRow = fromRow, toCol = toCol, toRow = toRow})
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
            amsg.damage = tonumber(amsg.damage) or 0
            amsg.fromCol = tonumber(amsg.fromCol)
            amsg.fromRow = tonumber(amsg.fromRow)
            amsg.toCol = tonumber(amsg.toCol)
            amsg.toRow = tonumber(amsg.toRow)
            -- Apply attack on host (reuse attack commit handling below by calling it directly)
            -- We'll apply same logic as commit
            local attacker = self:getPieceAt(amsg.fromCol, amsg.fromRow)
            local target = self:getPieceAt(amsg.toCol, amsg.toRow)
            if attacker and attacker.useAmmo then attacker:useAmmo() end
            if target then
                local wasKilled = target:takeDamage(amsg.damage)
                if wasKilled then
                    for i, p in ipairs(self.pieces) do
                        if p == target then table.remove(self.pieces, i); break end
                    end
                    if amsg.moved and attacker then attacker:setPosition(amsg.toCol, amsg.toRow); self:triggerMineAt(amsg.toCol, amsg.toRow, attacker) end
                end
            else
                if amsg.moved and attacker then attacker:setPosition(amsg.toCol, amsg.toRow); self:triggerMineAt(amsg.toCol, amsg.toRow, attacker) end
            end
            -- Broadcast commit
            self:sendCommit({type = "attack", fromCol = amsg.fromCol, fromRow = amsg.fromRow, toCol = amsg.toCol, toRow = amsg.toRow, damage = amsg.damage, moved = amsg.moved})
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
    elseif msg.type == "placeBaseRequest" then
        if self.isHost then
            local team = tonumber(msg.team)
            local col = tonumber(msg.col)
            local row = tonumber(msg.row)
            local baseType = msg.baseType
            if team and col and row then
                local placed = false
                for _, base in ipairs(self.bases) do
                    if base.team == team and (not base.col or base.col == 0) and (not base.row or base.row == 0) then
                        base:setPosition(col, row)
                        self.basesPlaced = (self.basesPlaced or 0) + 1
                        placed = true
                        break
                    end
                end
                if not placed then
                    local newBase = Base.new(baseType or "hq", team, self.map, col, row)
                    table.insert(self.bases, newBase)
                    self.basesPlaced = (self.basesPlaced or 0) + 1
                end
                -- Broadcast commit
                self:sendCommit({type = "placeBase", team = team, col = col, row = row, baseType = baseType})
            end
        end
    elseif msg.type == "buildUnitRequest" then
        if self.isHost then
            local team = tonumber(msg.team)
            local col = tonumber(msg.col)
            local row = tonumber(msg.row)
            local unitType = msg.unitType
            if team and col and row and unitType then
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
        local damage = tonumber(msg.damage) or 0
        local moved = msg.moved and true or false
        local attacker = self:getPieceAt(fromCol, fromRow)
        local target = self:getPieceAt(toCol, toRow)
        -- Mirror ammo consumption on attacker if present
        if attacker and attacker.useAmmo then
            attacker:useAmmo()
        end
        if target then
            local wasKilled = target:takeDamage(damage)
            if wasKilled then
                for i, p in ipairs(self.pieces) do
                    if p == target then
                        table.remove(self.pieces, i)
                        break
                    end
                end
                -- If attacker moved into the target tile, move it and trigger mines
                if moved and attacker then
                    attacker:setPosition(toCol, toRow)
                    self:triggerMineAt(toCol, toRow, attacker)
                end
            end
        else
            -- If target not found, but moved flag set, still try to move attacker
            if moved and attacker then
                attacker:setPosition(toCol, toRow)
                self:triggerMineAt(toCol, toRow, attacker)
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
    elseif msg.type == "placeBase" then
        -- Remote placed a base during placement phase: mirror it
        local team = tonumber(msg.team)
        local col = tonumber(msg.col)
        local row = tonumber(msg.row)
        local baseType = msg.baseType
        if team and col and row then
            local placed = false
            for _, base in ipairs(self.bases) do
                if base.team == team and (not base.col or base.col == 0) and (not base.row or base.row == 0) then
                    pcall(function() print(string.format("[game] recv.placeBase -> team=%s col=%s row=%s baseType=%s (filled existing slot)", tostring(team), tostring(col), tostring(row), tostring(baseType))) end)
                    if self.fogOfWar then
                        pcall(function() print("[game] recv.placeBase visibility before: t1=" .. tostring(self.fogOfWar:isTileVisible(1, col, row)) .. " t2=" .. tostring(self.fogOfWar:isTileVisible(2, col, row))) end)
                    end
                    base:setPosition(col, row)
                    self.basesPlaced = (self.basesPlaced or 0) + 1
                    -- Update fog visibility so the new base is registered for vision
                    if self.fogOfWar then
                        self.fogOfWar:updateVisibility(1, self.pieces, self.bases, self.teamStartingCorners)
                        self.fogOfWar:updateVisibility(2, self.pieces, self.bases, self.teamStartingCorners)
                        pcall(function() print("[game] recv.placeBase visibility after: t1=" .. tostring(self.fogOfWar:isTileVisible(1, col, row)) .. " t2=" .. tostring(self.fogOfWar:isTileVisible(2, col, row))) end)
                    end
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
                    placed = true
                    break
                end
            end
            if not placed then
                -- No placeholder base existed on this client: create a new Base instance to mirror the host
                pcall(function() print(string.format("[game] recv.placeBase -> creating new base instance team=%s col=%s row=%s baseType=%s", tostring(team), tostring(col), tostring(row), tostring(baseType))) end)
                local newBase = Base.new(baseType, team, self.map, col, row)
                table.insert(self.bases, newBase)
                self.basesPlaced = (self.basesPlaced or 0) + 1
                if self.fogOfWar then
                    self.fogOfWar:updateVisibility(1, self.pieces, self.bases, self.teamStartingCorners)
                    self.fogOfWar:updateVisibility(2, self.pieces, self.bases, self.teamStartingCorners)
                    pcall(function() print("[game] recv.placeBase visibility after (created): t1=" .. tostring(self.fogOfWar:isTileVisible(1, col, row)) .. " t2=" .. tostring(self.fogOfWar:isTileVisible(2, col, row))) end)
                end
                -- If there is a builder at this tile, clear its building state
                local builder2 = self:getPieceAt(col, row)
                if builder2 and builder2.isBuilding then
                    builder2.isBuilding = false
                    builder2.buildingType = nil
                    builder2.buildingTurnsRemaining = 0
                    builder2.buildingTeam = nil
                    builder2.buildingResourceTarget = nil
                    builder2.hasMoved = false
                end
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
                        Network.send({type = "startPlay"})
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
    -- Trigger mines if any
    self:triggerMineAt(toCol, toRow, piece)
    -- If this piece was selected locally, deselect it now that the move is applied
    if self.selectedPiece and self.selectedPiece == piece then
        piece:deselect(self)
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
    love.graphics.push()
    love.graphics.applyTransform(self.camera:getTransform())
    
    -- Draw map
    self.map:draw(0, 0)

    -- Determine viewer team (localTeam when networked) for visuals and fog
    local viewTeam = self.localTeam or self.currentTurn

    -- -- Draw province fills and region labels
    -- self:drawProvinceBoundaries()
    
    -- Draw starting areas during placement phase (use localTeam view when networked)
    if self.state == "placing" then
        local viewTeam = self.localTeam or self.placementTeam
        self:drawStartingAreas(viewTeam)
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
                self:drawBaseRadius(base, pixelX, pixelY, viewTeam)
                base:draw(pixelX, pixelY, self.hexSideLength)
            end
        end
    end

    
    
    -- Draw resources
    for _, resource in ipairs(self.resources) do
        local pixelX, pixelY = self.map:gridToPixels(resource.col, resource.row)
        resource:draw(pixelX, pixelY, self.hexSideLength)
    end

    -- Draw mines (only draw if revealed to the current player's team)
    if self.mines then
        for _, mine in ipairs(self.mines) do
            if mine.col and mine.row then
                local shouldDraw = false
                if mine.revealedTo and mine.revealedTo[self.currentTurn] then
                    shouldDraw = true
                end
                if shouldDraw then
                    local mx, my = self.map:gridToPixels(mine.col, mine.row)
                    love.graphics.setColor(0.1, 0.1, 0.1)
                    love.graphics.circle("fill", mx, my, self.hexSideLength * 0.15)
                    love.graphics.setColor(0, 0, 0)
                    love.graphics.circle("line", mx, my, self.hexSideLength * 0.15)
                end
            end
        end
    end
    
    -- (Visibility updated in Game:update; avoid heavy update here)

    -- Draw air superiority markers on tiles ("=", "^", "˅") for tiles with AS
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

                local symbol = nil
                -- tie and both present
                if playerAS > 0 and playerAS == enemyAS then
                    symbol = "="
                elseif playerAS > enemyAS and enemyAS > 0 then
                    symbol = "^"
                elseif enemyAS > playerAS and enemyAS > 0 then
                    symbol = "v"
                end

                if symbol then
                    local tile = self.map:getTile(col, row)
                    if tile and tile.points then
                        local px, py = self.map:gridToPixels(col, row)
                        -- Choose color: team color for favorable/tie, enemy color for losing
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
            if drawPiece then
                local pixelX, pixelY = self.map:gridToPixels(piece.col, piece.row)
                piece:draw(pixelX, pixelY, self.hexSideLength)
            end
        end
    end
    
    -- Draw valid moves if a piece is selected
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
    -- end
    
    -- Draw action menu on top of pieces and overlays
    if self.actionMenu then
        self:drawActionMenu()
    end

    -- Draw airstrike targeting UI (crosshair + highlight) if active (rendered above pieces)
    if self.airstrikeTargeting then
        local mx, my = love.mouse.getPosition()
        local worldX, worldY = self.camera:screenToWorld(mx, my)
        local tcol, trow = self.map:pixelsToGrid(worldX, worldY)

        -- Highlight tile under cursor
        local tile = self.map:getTile(tcol, trow)
        if tile then
            local can = self:canAirstrike(self.airstrikeTargeting.team, tcol, trow)
            if can then
                love.graphics.setColor(0, 1, 0, 0.4)
            else
                love.graphics.setColor(1, 0, 0, 0.4)
            end
            love.graphics.polygon("fill", tile.points)
        end

        -- Draw crosshair at mouse (in world coords)
        love.graphics.setColor(1, 1, 1)
        local size = 16
        love.graphics.setLineWidth(2)
        love.graphics.line(worldX - size, worldY, worldX + size, worldY)
        love.graphics.line(worldX, worldY - size, worldX, worldY + size)
        love.graphics.setLineWidth(1)
    end

    -- Draw fog of war for the viewer's team (after all game elements)
    if self.state == "playing" then
        -- Use viewer team so local player sees their own visibility regardless of whose turn it is
        local viewTeam = self.localTeam or self.currentTurn
        self.fogOfWar:draw(viewTeam, self.camera, 0, 0)
    elseif self.state == "placing" then
        -- During placement, show fog for the local player (or placementTeam if not networked)
        local viewTeam = self.localTeam or self.placementTeam
        self.fogOfWar:draw(viewTeam, self.camera, 0, 0)
    end
    
    love.graphics.pop()
    
    -- Draw UI (always on screen)
    self:drawUI()
end



function Game:drawValidMoves()
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
    -- Draw starting area indicators for both teams (top and bottom strips)
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

    -- Choose color based on team
    local fillR, fillG, fillB, fillA = 1, 0, 0, 0.15
    local lineR, lineG, lineB, lineA = 1, 0, 0, 0.4
    if base.team == 2 then
        fillR, fillG, fillB, fillA = 0, 0, 1, 0.15
        lineR, lineG, lineB, lineA = 0, 0, 1, 0.4
    end

    -- Draw each hex in range (only passable terrain)
    love.graphics.setColor(fillR, fillG, fillB, fillA)
    for _, hex in ipairs(visited) do
        local tile = self.map:getTile(hex.col, hex.row)
        if tile then
            local points = tile.points
            love.graphics.polygon("fill", points)
        end
    end

    -- Draw outline for hexes in range
    love.graphics.setColor(lineR, lineG, lineB, lineA)
    for _, hex in ipairs(visited) do
        local tile = self.map:getTile(hex.col, hex.row)
        if tile then
            local points = tile.points
            love.graphics.polygon("line", points)
        end
    end
end

function Game:drawUI()
    love.graphics.setColor(1, 1, 1)
    love.graphics.setFont(love.graphics.newFont(14))
    
    if self.state == "placing" then
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
            love.graphics.print("Place your bases (HQ, Ammo, Supply, Airbase) on your starting area.", 10, 74)
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
        local basesInfo = string.format("Bases: HQ: %d | Ammo: %d | Supply: %d", hqCount, ammoDepotCount, supplyDepotCount)
        love.graphics.setFont(love.graphics.newFont(12))
        love.graphics.print(basesInfo, 10, 70)
        
        -- Show building engineers for current team
        local yOffset = 90
        love.graphics.setFont(love.graphics.newFont(11))
        for _, piece in ipairs(self.pieces) do
            if piece.team == self.currentTurn and piece.isBuilding and piece.buildingTurnsRemaining then
                local buildingName = piece.buildingType == "resource_mine" and "Resource Mine" or
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
                local buildingName = self.selectedPiece.buildingType == "resource_mine" and "Resource Mine" or
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
            -- If host and both ready, start the game
            if self.isHost and self.playerReady[1] and self.playerReady[2] then
                self.state = "playing"
                self.turnCount = 1
                self.currentTurn = 1
                for _, p in ipairs(self.pieces) do p:resetMove() end
                pcall(function()
                    if Network and Network.send and Network.isConnected and Network.isConnected() then
                        Network.send({type = "startPlay"})
                    end
                end)
            end
            return
        end
    end
    local worldX, worldY = self.camera:screenToWorld(x, y)
    local col, row = self.map:pixelsToGrid(worldX, worldY)
    -- Block input while waiting for hotseat pass
    if self.passPending then
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
    
    if self.state == "placing" then
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
                    -- This local team has finished pieces: allow placing bases for them
                    self:placeBase(col, row, teamArg)
                else
                    self:placePiece(col, row, teamArg)
                end
            else
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

                -- Apply strike to any piece at that tile
                local targetPiece = self:getPieceAt(col, row)
                local strikeDamage = 6
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
                -- If clicking on already selected piece with menu open, close menu and deselect
                if piece == self.selectedPiece and self.actionMenu then
                    self.actionMenu = nil
                    self.actionMenuContext = nil
                    self.actionMenuContextType = nil
                    piece:deselect(self)
                    return
                end
                
                -- If clicking on already selected piece, open action menu (default actions like Sweep)
                if piece == self.selectedPiece then
                    self:openActionMenu(piece, "piece")
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
            
            -- Otherwise, try to select a piece (in case piece team check failed)
            if self.actionMenu then
                self.actionMenu = nil
                self.actionMenuContext = nil
                self.actionMenuContextType = nil
            end
            self:selectPiece(col, row)
        elseif button == 2 then  -- Right click
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

    else
        if self.selectedPiece then
            self.selectedPiece:deselect(self)
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

function Game:triggerMineAt(col, row, mover)
    local mine = self:getMineAt(col, row)
    if not mine then return false end
    if mine.team == mover.team then return false end

    -- Apply damage to mover (half damage if mine was revealed to mover's team)
    local dmg = mine.damage or 5
    if mine.revealedTo and mine.revealedTo[mover.team] then
        dmg = math.max(1, math.floor(dmg / 2))
    end
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
                mine.revealedTo[piece.team] = true
            end
        end
        ::continue::
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
    
    -- Open menu for this base
    self:openActionMenu(base, "base")
end

-- Generic function to open action menu for any object
-- context: the object (base, piece, resource, etc.)
-- contextType: "base", "piece", "resource", etc.
function Game:openActionMenu(context, contextType)
    -- Generate action options based on context type and object
    local options = self:getActionOptions(context, contextType)
    
    if #options == 0 then
        -- No options available, don't show menu
        return
    end
    
    -- Get pixel position of the context object
    local pixelX, pixelY
    if contextType == "base" then
        pixelX, pixelY = self.map:gridToPixels(context.col, context.row)
    elseif contextType == "piece" then
        pixelX, pixelY = self.map:gridToPixels(context.col, context.row)
    elseif contextType == "resource" then
        pixelX, pixelY = self.map:gridToPixels(context.col, context.row)
    else
        return  -- Unknown context type
    end
    
    -- Create ActionMenu instance
    self.actionMenu = ActionMenu.new(pixelX, pixelY, options, self.hexSideLength)
    self.actionMenuContext = context
    self.actionMenuContextType = contextType
end

-- Get action options for a given context object
-- This is where you define what actions are available for each object type
function Game:getActionOptions(context, contextType)
    local options = {}
    
    if contextType == "base" then
        if context.type == "hq" then
            local team = context.team
            local unitCount = self:getUnitCount(team)
            local unitCapacity = self:getUnitCapacity(team)
            local atCapacity = (unitCapacity > 0) and (unitCount >= unitCapacity) or false

            -- HQ can build infantry
            table.insert(options, {
                id = "build_infantry",
                name = "Build Infantry",
                cost = 2,  -- Cost in resources
                icon = "infantry",  -- For future use
                disabled = atCapacity
            })
            -- Sniper
            table.insert(options, {
                id = "build_sniper",
                name = "Build Sniper",
                cost = 4,
                icon = "sniper",
                disabled = atCapacity
            })
            -- Tank
            table.insert(options, {
                id = "build_tank",
                name = "Build Tank",
                cost = 6,
                icon = "tank",
                disabled = atCapacity
            })
            -- Engineer
            table.insert(options, {
                id = "build_engineer",
                name = "Build Engineer",
                cost = 3,
                icon = "engineer",
                disabled = atCapacity
            })
        end
        -- Add deconstruct option to all bases
        table.insert(options, {
            id = "deconstruct",
            name = "Deconstruct",
            cost = 0,  -- Free
            icon = "X",
            isDeconstruct = true  -- Flag for red coloring
        })
        -- Airbase: offer an airstrike targeting mode when there exists at least one eligible enemy target
        if context.type == "airbase" and context.col and context.col > 0 then
            local tiles = self:getTilesWithinRadius(context.col, context.row, context:getRadius())
            local hasEligible = false
            for _, tile in ipairs(tiles) do
                local piece = self:getPieceAt(tile.col, tile.row)
                if piece and piece.team ~= context.team then
                    if self:canAirstrike(context.team, tile.col, tile.row) then
                        hasEligible = true
                        break
                    end
                end
            end
            if hasEligible then
                table.insert(options, {
                    id = "airstrike_target",
                    name = "Airstrike (Target)",
                    icon = "airstrike",
                    cost = 2,
                })
            end
        end
        -- Add more base types here as needed
    elseif contextType == "piece" then
        -- Engineer can build structures
        if context.stats.canBuild and not context.isBuilding then
            -- Check if engineer is on a resource tile or if tile already has a base
            local onResourceTile = self:getResourceAt(context.col, context.row) ~= nil
            local hasBase = self:getBaseAt(context.col, context.row) ~= nil
            
            table.insert(options, {
                id = "build_hq",
                name = "Build HQ",
                cost = 10,
                buildTurns = 4,  -- Takes 4 turns to build
                icon = "hq",
                disabled = onResourceTile or hasBase  -- Can't build bases on resource tiles or occupied tiles
            })
            table.insert(options, {
                id = "build_ammo_depot",
                name = "Build Ammo Depot",
                cost = 5,
                buildTurns = 2,  -- Takes 2 turns to build
                icon = "ammo_depot",
                disabled = onResourceTile or hasBase  -- Can't build bases on resource tiles or occupied tiles
            })
            table.insert(options, {
                id = "build_supply_depot",
                name = "Build Supply Depot",
                cost = 5,
                buildTurns = 2,  -- Takes 2 turns to build
                icon = "supply_depot",
                disabled = onResourceTile or hasBase  -- Can't build bases on resource tiles or occupied tiles
            })
            table.insert(options, {
                id = "build_resource_mine",
                name = "Build Resource Mine",
                cost = 3,
                buildTurns = 3,  -- Takes 3 turns to build
                icon = "resource_mine",
                disabled = hasBase  -- Can't build mine if tile has a base
            })
            table.insert(options, {
                id = "build_airbase",
                name = "Build Airbase",
                cost = 8,
                buildTurns = 4,
                icon = "airbase",
                disabled = onResourceTile or hasBase
            })
            -- Place a land mine (engineer-specific)
            table.insert(options, {
                id = "place_mine",
                name = "Place Mine",
                cost = 2,
                icon = "mine",
                disabled = self:getMineAt(context.col, context.row) ~= nil
            })
        end
        -- Sweep for mines (default unit action; consumes turn)
        do
            local disabled = (context.hasMoved or context.isBuilding)
            table.insert(options, {
                id = "sweep_mines",
                name = "Sweep For Mines",
                cost = 0,
                icon = "sweep",
                shortcut = "S",
                disabled = disabled
            })
        end

        -- Disarm option(s) for any revealed mines adjacent to this piece
        do
            local startTile = self.map:getTile(context.col, context.row)
            if startTile then
                local neighbors = self.map:getNeighbors(startTile, 1)
                for _, n in ipairs(neighbors) do
                    local mine = self:getMineAt(n.col, n.row)
                    -- Only show disarm for mines that are revealed to this team and belong to an enemy
                    if mine and mine.revealedTo and mine.revealedTo[context.team] and mine.team ~= context.team then
                        table.insert(options, {
                            id = "disarm_mine",
                            name = "Disarm Mine",
                            icon = "disarm",
                            shortcut = "D",
                            targetMine = mine,
                            disabled = (context.hasMoved or context.isBuilding)
                        })
                    end
                end
            end
        end
    elseif contextType == "resource" then
        -- Add resource actions here (e.g., harvest, upgrade, etc.)
    end
    
    return options
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
    if not self.actionMenu or not self.actionMenuContext then return end
    
    local context = self.actionMenuContext
    local contextType = self.actionMenuContextType
    
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
        -- Build a tank near the base
        -- Tanks require oil in addition to generic resources
        local oilCost = 1
        if self.teamOil[team] and self.teamOil[team] >= oilCost then
            self.teamOil[team] = self.teamOil[team] - oilCost
            self:buildUnitNearBase(context, "tank", team, option.cost)
        else
            -- Not enough oil: do nothing (could show message)
            return
        end
    elseif option.id == "build_engineer" and contextType == "base" then
        -- Build an engineer near the base
        self:buildUnitNearBase(context, "engineer", team, option.cost)
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
        -- Engineer builds a resource mine
        self:buildResourceMineNearPiece(context, team, option.cost, option.buildTurns)
    elseif option.id == "place_mine" and contextType == "piece" then
        -- Engineer places a land mine
        if context.placeMine then
            context:placeMine(self)
        end
    elseif option.id == "sweep_mines" and contextType == "piece" then
        -- Sweep action: reveal mines within piece's view range for this team
        if context then
            self:sweepForMines(context)
            -- consume turn for this piece
            context.hasMoved = true
        end
    elseif option.id == "disarm_mine" and contextType == "piece" then
        -- Disarm a revealed neighboring mine (option carries the targetMine)
        if option.targetMine then
            self:disarmMine(context, option.targetMine)
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
    elseif option.id == "airstrike_target" and contextType == "base" then
        -- Enter airstrike targeting mode: deduct cost now, allow player to choose tile
        if not context or context.type ~= "airbase" then return end
        local cost = option.cost or 0
        if self.teamResources[team] < cost then return end

        -- Deduct cost and enter targeting state (left-click cancel refunds)
        self.teamResources[team] = self.teamResources[team] - cost
        self.airstrikeTargeting = {
            base = context,
            team = team,
            cost = cost,
        }
        -- Close any action menu while targeting
        self.actionMenu = nil
        self.actionMenuContext = nil
        self.actionMenuContextType = nil
        return
    end
    -- Add more action handlers here as needed
    
    -- Close menu after action
    self.actionMenu = nil
    self.actionMenuContext = nil
    self.actionMenuContextType = nil
end

function Game:buildUnitNearBase(base, unitType, team, cost)
    -- Check unit capacity for this team
    local unitCount = self:getUnitCount(team)
    local unitCapacity = self:getUnitCapacity(team)
    if unitCapacity > 0 and unitCount >= unitCapacity then
        -- At capacity; cannot build more units
        return
    end

    -- Deduct cost
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
                -- If networked client, request host to build unit
                if Network and Network.isConnected and Network.isConnected() and not self.isHost and not self._applyingRemote then
                    pcall(function()
                        Network.send({type = "buildUnitRequest", baseCol = base.col, baseRow = base.row, unitType = unitType, team = team, col = neighbor.col, row = neighbor.row, cost = cost})
                    end)
                    return
                end
                -- Place unit here (host or local)
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
    
    if not self.selectedPiece then return end
    
    -- If piece has already moved this turn or is currently building, don't show any moves
    -- Make sure to handle pieces without building properties (old pieces)
    local isBuilding = self.selectedPiece.isBuilding or false
    if self.selectedPiece.hasMoved or isBuilding then
        return
    end
    
    local moveRange = self.selectedPiece:getMovementRange()
    local attackRange = self.selectedPiece:getAttackRange()
    
    -- Get all neighbors within move range (enemy pieces block movement)
    local visited = {}
    self:getHexesWithinRange(self.selectedPiece.col, self.selectedPiece.row, moveRange, visited, self.selectedPiece.team)
    
    for _, hex in ipairs(visited) do
        if hex.col ~= self.selectedPiece.col or hex.row ~= self.selectedPiece.row then
            local tile = self.map:getTile(hex.col, hex.row)
            if tile and tile.isLand and not self:getPieceAt(hex.col, hex.row) then
                -- Only allow moving to tiles visible to this piece's team
                if self.fogOfWar and self.fogOfWar:isTileVisible(self.selectedPiece.team, hex.col, hex.row) then
                    table.insert(self.validMoves, hex)
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
                local piece = self:getPieceAt(hex.col, hex.row)
                if piece and piece.team ~= self.selectedPiece.team then
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
    
    -- Use BFS to explore hexes, but only through passable terrain
    local queue = {{hex = startHex, distance = 0}}
    local visitedSet = {}
    visitedSet[col .. "," .. row] = true
    
    while #queue > 0 do
        local current = table.remove(queue, 1)
        local currentHex = current.hex
        local currentDistance = current.distance
        
        -- Add to visited if it's not the starting hex and within range
        if currentDistance > 0 and currentDistance <= range then
            local key = currentHex.col .. "," .. currentHex.row
            if not visited[key] then
                visited[key] = currentHex
                table.insert(visited, currentHex)
            end
        end
        
        -- Stop if we've reached the maximum range
        if currentDistance >= range then
            goto continue
        end
        
        -- Get immediate neighbors (range 1)
        local neighbors = self.map:getNeighbors(currentHex, 1)
        
        for _, neighbor in ipairs(neighbors) do
            local neighborKey = neighbor.col .. "," .. neighbor.row

            -- Only explore if not visited and terrain is passable (land)
            if not visitedSet[neighborKey] then
                local neighborTile = self.map:getTile(neighbor.col, neighbor.row)
                if neighborTile and neighborTile.isLand then
                    -- Check if tile is occupied by enemy piece (blocks movement past it)
                    local pieceOnTile = self:getPieceAt(neighbor.col, neighbor.row)
                    local isEnemyOccupied = pieceOnTile and pieceOnTile.team ~= team

                    -- Mark as seen so we don't process it again
                    visitedSet[neighborKey] = true
                    local nextDistance = currentDistance + 1

                    -- If within range, include the tile. If enemy-occupied, include it but don't enqueue for further exploration.
                    if nextDistance <= range then
                        local key = neighborTile.col .. "," .. neighborTile.row
                        if not visited[key] then
                            visited[key] = neighborTile
                            table.insert(visited, neighborTile)
                        end
                    end

                    if not isEnemyOccupied and nextDistance < range then
                        -- Terrain is passable and not blocked by enemy, enqueue to explore further
                        table.insert(queue, {
                            hex = neighborTile,
                            distance = nextDistance
                        })
                    end
                end
            end
        end
        ::continue::
    end
end

-- Get all tiles within a radius regardless of passability (used for airbase influence)
function Game:getTilesWithinRadius(col, row, radius)
    local tiles = {}
    if radius <= 0 then return tiles end
    local startHex = self.map:getTile(col, row)
    if not startHex then return tiles end

    local queue = {{col = col, row = row, distance = 0}}
    local visitedSet = {}
    visitedSet[col .. "," .. row] = true

    while #queue > 0 do
        local current = table.remove(queue, 1)
        if current.distance > 0 and current.distance <= radius then
            local hex = self.map:getTile(current.col, current.row)
            if hex then
                table.insert(tiles, hex)
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
                    table.insert(queue, { col = n.col, row = n.row, distance = current.distance + 1 })
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

-- Can `team` perform an airstrike against target tile? Requires teamAS > enemyAS and teamAS > 0
function Game:canAirstrike(team, targetCol, targetRow)
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
        -- If networked client, send request to host instead of applying locally
        if Network and Network.isConnected and Network.isConnected() and not self.isHost and not self._applyingRemote then
            pcall(function()
                Network.send({type = "moveRequest", fromCol = oldCol, fromRow = oldRow, toCol = col, toRow = row, team = self.localTeam})
            end)
            return
        end

        self.selectedPiece:setPosition(col, row)
        -- Check for mines triggered by moving into this tile
        self:triggerMineAt(col, row, self.selectedPiece)
        self:calculateValidMoves()
        -- Send network update (mirror) if connected and this is a local action
        if Network and Network.isConnected and Network.isConnected() and not self._applyingRemote then
            if self.isHost then
                pcall(function() print(string.format("[game] host commit move %d,%d -> %d,%d", oldCol, oldRow, col, row)) end)
                self:sendCommit({type = "move", fromCol = oldCol, fromRow = oldRow, toCol = col, toRow = row})
            end
        end
        -- Deselect the piece after moving so it isn't left selected when the turn ends
        if self.selectedPiece then
            self.selectedPiece:deselect(self)
        end
    elseif isValidAttack and targetPiece then
        -- If networked client, send request to host and don't apply locally
        if Network and Network.isConnected and Network.isConnected() and not self.isHost and not self._applyingRemote then
            local damage = self.selectedPiece:getDamage()
            local movedInto = false -- host will determine moved flag
            pcall(function()
                Network.send({type = "attackRequest", fromCol = oldCol, fromRow = oldRow, toCol = col, toRow = row, damage = damage, moved = movedInto, team = self.localTeam})
            end)
            return
        end

        -- Check if piece has ammo
        if not self.selectedPiece:hasAmmo() then
            return  -- Can't attack without ammo
        end

        -- Use ammo and attack (host or local)
        self.selectedPiece:useAmmo()
        local damage = self.selectedPiece:getDamage()
        local wasKilled = targetPiece:takeDamage(damage)

        if wasKilled then
            -- Remove dead piece
            for i, piece in ipairs(self.pieces) do
                if piece == targetPiece then
                    table.remove(self.pieces, i)
                    break
                end
            end
            -- Only move to the enemy tile if we killed them and attack was adjacent
            if self:isWithinRange(self.selectedPiece.col, self.selectedPiece.row, col, row, 1) then
                self.selectedPiece:setPosition(col, row)
                -- Check for mines when attacker moves into the tile after killing
                self:triggerMineAt(col, row, self.selectedPiece)
            end
        end
        -- Send network update for attack (include whether attacker moved into target)
        if Network and Network.isConnected and Network.isConnected() and not self._applyingRemote then
            -- If this is a networked client, send request and do not apply local attack effects
            if not self.isHost then
                local movedInto = (wasKilled and self:isWithinRange(self.selectedPiece.col, self.selectedPiece.row, col, row, 1))
                pcall(function()
                    Network.send({type = "attackRequest", fromCol = oldCol, fromRow = oldRow, toCol = col, toRow = row, damage = damage, moved = movedInto, team = self.localTeam})
                end)
                -- Client should wait for authoritative commit; stop here
                return
            else
                local movedInto = (wasKilled and self:isWithinRange(self.selectedPiece.col, self.selectedPiece.row, col, row, 1))
                pcall(function()
                    self:sendCommit({type = "attack", fromCol = oldCol, fromRow = oldRow, toCol = col, toRow = row, damage = damage, moved = movedInto})
                end)
            end
        end
        -- If enemy survived, attacker stays in place (no movement)
        -- Mark piece as moved since it attacked
        self.selectedPiece.hasMoved = true
        self:calculateValidMoves()
        -- Deselect the attacker after resolving the attack
        if self.selectedPiece then
            self.selectedPiece:deselect(self)
        end
    end
end

function Game:keypressed(key)
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
    end
end

function Game:mousemoved(x, y, dx, dy)
    if self.passPending then return end
    -- Handle camera panning with middle mouse or space
    if love.mouse.isDown(3) then  -- Middle mouse
        self.camera:pan(dx, dy)
    end
end

function Game:wheelmoved(x, y)
    if y > 0 then
        self.camera:zoomIn(0.1)
    else
        self.camera:zoomOut(0.1)
    end
end

function Game:endTurn()
    -- Can't end turn during placement phase
    if self.state == "placing" then
        return
    end
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
    if self.selectedPiece then
        self.selectedPiece:deselect(self)
    end

    -- If host, broadcast any bases that were just completed/placed during this turn so peers register them
    if self.isHost and Network and Network.isConnected and Network.isConnected() then
        for _, b in ipairs(self.bases) do
            if b.justPlaced then
                pcall(function()
                    Network.send({type = "placeBase", team = b.team, col = b.col, row = b.row, baseType = b.type})
                end)
                b.justPlaced = nil
            end
        end
        -- Broadcast any newly created units (pieces) that were built this turn
        for _, p in ipairs(self.pieces) do
            if p.justPlaced then
                pcall(function()
                    Network.send({type = "placePiece", team = p.team, col = p.col, row = p.row, unitType = p.type})
                end)
                p.justPlaced = nil
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
        -- Notify remote peer of end-turn (if connected and this is a local action)
        if Network and Network.isConnected and Network.isConnected() and not self._applyingRemote then
            pcall(function()
                Network.send({type = "endTurn", nextTeam = nextTeam, teamResources1 = self.teamResources[1], teamResources2 = self.teamResources[2], teamOil1 = self.teamOil[1], teamOil2 = self.teamOil[2]})
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
    local area = self.teamStartingAreas[team]
    if not area then return false end
    
    -- Check if row is within starting area depth
    return row >= area.rowStart and row <= area.rowEnd
end

function Game:placePiece(col, row, team)
    -- Check if tile is valid (must be land and not occupied)
    local tile = self.map:getTile(col, row)
    if not tile or not tile.isLand then
        return  -- Can't place on water or invalid tile
    end
    
    local teamToPlace = team or self.placementTeam
    -- Check if position is within the team's starting area
    if not self:isInStartingArea(col, row, teamToPlace) then
        return  -- Can't place outside starting area
    end
    
    -- Check if tile is already occupied
    if self:getPieceAt(col, row) then
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
                        Network.send({type = "placementPhase", phase = "bases"})
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
    -- Check if position is within the team's starting area
    if not self:isInStartingArea(col, row, teamToPlace) then
        return  -- Can't place outside starting area
    end
    pcall(function() print(string.format("[game] placeBase attempt team=%s col=%s row=%s placementPhase=%s", tostring(teamToPlace), tostring(col), tostring(row), tostring(self.placementPhase))) end)
    
    -- Check if tile is already occupied by piece or base
    if self:getPieceAt(col, row) or self:getBaseAt(col, row) then
        return  -- Tile already has something
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
            -- Place this base (host or local play)
            base:setPosition(col, row)
            self.basesPlaced = self.basesPlaced + 1
            pcall(function() print(string.format("[game] placed base %s for team=%s at %d,%d", tostring(base.type), tostring(teamToPlace), col, row)) end)
            -- If host, broadcast commit
            if Network and Network.isConnected and Network.isConnected() and self.isHost and not self._applyingRemote then
                self:sendCommit({type = "placeBase", team = teamToPlace, col = col, row = row, baseType = base.type})
            end
                    -- Update fog visibility immediately so presence/vision of the base is recognized
                    if self.fogOfWar then
                        self.fogOfWar:updateVisibility(1, self.pieces, self.bases, self.teamStartingCorners)
                        self.fogOfWar:updateVisibility(2, self.pieces, self.bases, self.teamStartingCorners)
                    end
            
            -- Check if both teams have finished placing bases; if so, start the game
            local team1Bases = 0
            local team2Bases = 0
            for _, b in ipairs(self.bases) do
                if b.team == 1 and b.col > 0 and b.row > 0 then team1Bases = team1Bases + 1 end
                if b.team == 2 and b.col > 0 and b.row > 0 then team2Bases = team2Bases + 1 end
            end
            if team1Bases >= self.basesPerTeam and team2Bases >= self.basesPerTeam then
                -- Both teams have placed bases: move to ready phase, require both players to ready-up
                self.placementPhase = "ready"
                pcall(function() print("[game] both teams finished bases — entering ready phase") end)
                -- Notify peer
                if Network and Network.isConnected and Network.isConnected() and not self._applyingRemote then
                    pcall(function()
                        Network.send({type = "placementPhase", phase = "ready"})
                    end)
                end
                -- Do not start the game until both players press Ready (host will send startPlay)
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

return Game
