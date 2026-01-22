-- Core game logic and state management

local Game = {}
Game.__index = Game


local Camera = require("camera")
local Piece = require("piece")
local Base = require("base")
local Resource = require("resource")
local ActionMenu = require("action_menu")
local FogOfWar = require("fog_of_war")

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
    self.basesPerTeam = 3  -- HQ, Ammo Depot, Supply Depot
    self.basesToPlace = self.basesPerTeam * 2  -- Total bases (3 for each team)
    self.basesPlaced = 0
    self.placementTeam = 1  -- Which team is currently placing (starts with team 1)
    self.placementPhase = "pieces"  -- "pieces" or "bases"
    
    -- Map setup
    self.hexSideLength = 32
    self.mapWidth = 20
    self.mapHeight = 20
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

    -- Province/Region control data (initialized after map)
    self.provinces = {}  -- mapping col,row -> province id
    self.regions = {}    -- mapping region id -> list of province ids
    self.numProvinceCols = 2
    self.numProvinceRows = 2
    self:initializeProvinces()
    
    -- Fog of War system
    self.fogOfWar = FogOfWar.new(self.map, 2)
    
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
    
    return self
end

function Game:generateMapTerrain()
    -- Use balanced terrain generator for competitive play
    self.map:generateTerrain("balanced")
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

function Game:initializeProvinces()
    -- Partition the map into provinces limited to the middle area (exclude starting areas)
    -- For this map, create a 2x2 province grid in the central band, and group provinces into 2 regions (columns)
    local pc = self.numProvinceCols or 2
    local pr = self.numProvinceRows or 2

    -- Determine middle band rows (exclude starting areas)
    local startRow = (self.startingAreaDepth or 5) + 1
    local endRow = self.mapHeight - (self.startingAreaDepth or 5)
    local bandHeight = math.max(1, endRow - startRow + 1)

    local provinceWidth = math.max(1, math.floor(self.mapWidth / pc))
    local provinceHeight = math.max(1, math.floor(bandHeight / pr))

    self.provinces = {}
    self.regions = {}

    local provinceId = 1
    for px = 1, pc do
        local colStart = (px - 1) * provinceWidth + 1
        local colEnd = (px == pc) and self.mapWidth or (px * provinceWidth)
        for py = 1, pr do
            local rowStart = startRow + (py - 1) * provinceHeight
            local rowEnd = (py == pr) and endRow or (startRow + py * provinceHeight - 1)

            -- store province tiles (only in middle band)
            local tiles = {}
            for col = colStart, colEnd do
                for row = rowStart, rowEnd do
                    tiles[#tiles + 1] = {col = col, row = row}
                    self.provinces[col .. "," .. row] = provinceId
                end
            end

            -- region id = px (group provinces by column)
            local regionId = px
            self.regions[regionId] = self.regions[regionId] or {}
            table.insert(self.regions[regionId], provinceId)

            provinceId = provinceId + 1
        end
    end
end

function Game:drawProvinceBoundaries()
    if not self.provinces then return end

    -- Build reverse map: provinceId -> list of tiles
    local provinceTiles = {}
    for col = 1, self.mapWidth do
        for row = 1, self.mapHeight do
            local pid = self.provinces[col .. "," .. row]
            if pid then
                provinceTiles[pid] = provinceTiles[pid] or {}
                table.insert(provinceTiles[pid], {col = col, row = row})
            end
        end
    end

    -- Draw each province as a subtle fill and light outline
    for pid, tiles in pairs(provinceTiles) do
        -- choose a color based on province id to alternate hues
        local hue = (pid % 2 == 0) and 0.85 or 0.9
        love.graphics.setColor(0.8 * hue, 0.75 * hue, 0.6 * hue, 0.06)
        for _, t in ipairs(tiles) do
            local tile = self.map:getTile(t.col, t.row)
            if tile and tile.points and tile.isLand then
                love.graphics.polygon("fill", tile.points)
            end
        end
    end

    -- Draw province external borders (black when unowned, team color when owned)
    for pid, tiles in pairs(provinceTiles) do
        local owner = self:getProvinceOwner(pid)
        local colorR, colorG, colorB = 0, 0, 0
        if owner == 1 then colorR, colorG, colorB = 1, 0, 0
        elseif owner == 2 then colorR, colorG, colorB = 0, 0, 1
        end
        local edges = self:calculateExternalEdges(tiles)
        love.graphics.setLineWidth(2)
        love.graphics.setColor(colorR, colorG, colorB, 1)
        for _, e in ipairs(edges) do
            love.graphics.line(e[1], e[2], e[3], e[4])
        end
        love.graphics.setLineWidth(1)
    end

    -- Draw region labels and ownership
    local regionOwners = self:calculateRegionControl()
    love.graphics.setFont(love.graphics.newFont(12))
    for regionId, provinceList in pairs(self.regions) do
        -- compute average pixel position for region label
        local sumX, sumY, count = 0, 0, 0
        for _, provinceId in ipairs(provinceList) do
            -- pick first tile in provinceTiles[provinceId] if exists
            local tiles = provinceTiles[provinceId]
            if tiles and #tiles > 0 then
                for _, t in ipairs(tiles) do
                    local px, py = self.map:gridToPixels(t.col, t.row)
                    sumX = sumX + px
                    sumY = sumY + py
                    count = count + 1
                end
            end
        end
        if count > 0 then
            local cx = sumX / count
            local cy = sumY / count
            local owner = regionOwners[regionId]
            if owner == 1 then
                love.graphics.setColor(1, 0, 0, 0.9)
            elseif owner == 2 then
                love.graphics.setColor(0, 0, 1, 0.9)
            else
                love.graphics.setColor(0.9, 0.9, 0.9, 0.9)
            end
            love.graphics.printf("Region " .. tostring(regionId), cx - 40, cy - 8, 80, "center")

            -- Draw external region border (thicker) and color by region owner
            local regionEdges = self:calculateRegionExternalEdges(regionId)
            local rR, rG, rB = 0, 0, 0
            if owner == 1 then rR, rG, rB = 1, 0, 0
            elseif owner == 2 then rR, rG, rB = 0, 0, 1
            end
            love.graphics.setLineWidth(4)
            love.graphics.setColor(rR, rG, rB, 1)
            for _, e in ipairs(regionEdges) do
                love.graphics.line(e[1], e[2], e[3], e[4])
            end
            love.graphics.setLineWidth(1)
        end
    end

    love.graphics.setColor(1,1,1,1)
end

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

                -- Slightly smaller inset so borders sit closer to hex edges
                local inset = math.min(6, (self.hexSideLength or 32) * 0.12)
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

-- Determine owner of a province (returns team number or nil). A team owns a province if it has one or more HQs in that province and no HQs of other teams.
function Game:getProvinceOwner(provinceId)
    local owner = nil
    for _, base in ipairs(self.bases) do
        if base.type == "hq" and base.col and base.row and base.col > 0 then
            local pid = self.provinces[base.col .. "," .. base.row]
            if pid == provinceId then
                if not owner then owner = base.team
                elseif owner ~= base.team then return nil end
            end
        end
    end
    return owner
end

-- Calculate external edges for a region (regionId)
function Game:calculateRegionExternalEdges(regionId)
    local provinceList = self.regions[regionId]
    if not provinceList then return {} end
    local tiles = {}
    for _, pid in ipairs(provinceList) do
        for k, v in pairs(self.provinces) do
            if v == pid then
                local comma = string.find(k, ",")
                if comma then
                    local col = tonumber(string.sub(k, 1, comma - 1))
                    local row = tonumber(string.sub(k, comma + 1))
                    table.insert(tiles, {col = col, row = row})
                end
            end
        end
    end
    return self:calculateExternalEdges(tiles)
end

-- Determine ownership of regions: returns table regionId -> ownerTeam or nil
function Game:calculateRegionControl()
    local owners = {}
    for regionId, provinceList in pairs(self.regions) do
        -- region is controlled by a team if that team has an HQ in every province of this region
        local regionOwner = nil
        local allProvincesHaveHQ = true
        local requiredTeam = nil
        for _, provinceId in ipairs(provinceList) do
            -- find any HQ in this province
            local foundHQ = false
            local foundTeam = nil
            for _, base in ipairs(self.bases) do
                if base.type == "hq" and base.col and base.row and base.col > 0 then
                    local pid = self.provinces[base.col .. "," .. base.row]
                    if pid == provinceId then
                        foundHQ = true
                        foundTeam = base.team
                        break
                    end
                end
            end
            if not foundHQ then
                allProvincesHaveHQ = false
                break
            end
            if not requiredTeam then
                requiredTeam = foundTeam
            elseif requiredTeam ~= foundTeam then
                -- Different teams in different provinces -> no single owner
                allProvincesHaveHQ = false
                break
            end
        end
        if allProvincesHaveHQ and requiredTeam then
            owners[regionId] = requiredTeam
        end
    end
    return owners
end

function Game:addBase(baseType, team, col, row)
    local base = Base.new(baseType, team, self.map, col, row)
    table.insert(self.bases, base)
end

function Game:generateResources()
    -- Generate a few resource tiles scattered across the map
    local numResources = 5  -- Number of generic resources to place

    for i = 1, numResources do
        local attempts = 0
        local placed = false
        while not placed and attempts < 100 do
            attempts = attempts + 1
            local col = math.random(5, self.mapWidth - 5)  -- Avoid edges
            local row = math.random(5, self.mapHeight - 5)
            local tile = self.map:getTile(col, row)
            if tile and tile.isLand then
                if not self:getPieceAt(col, row) and not self:getBaseAt(col, row) and not self:getResourceAt(col, row) then
                    local resource = Resource.new("generic", self.map, col, row)
                    table.insert(self.resources, resource)
                    placed = true
                end
            end
        end
    end

    -- Add a couple of rich oil deposits near the map center
    local centerCol = math.floor(self.mapWidth / 2)
    local centerRow = math.floor(self.mapHeight / 2)
    local oilSpots = {{centerCol, centerRow}, {centerCol + 2, centerRow - 1}}
    for _, spot in ipairs(oilSpots) do
        local col, row = spot[1], spot[2]
        local tile = self.map:getTile(col, row)
        if tile and tile.isLand and not self:getResourceAt(col, row) then
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
end

function Game:update(dt)
    -- Update game logic here
    if self.state == "playing" then
        -- Update pieces, animations, etc.
        
        -- Update fog of war visibility for all teams
        for team = 1, 2 do
            self.fogOfWar:updateVisibility(team, self.pieces, self.bases, self.teamStartingCorners)
        end
    elseif self.state == "placing" then
        -- Update fog of war for the team that's placing
        self.fogOfWar:updateVisibility(self.placementTeam, self.pieces, self.bases, self.teamStartingCorners)
    end
end

function Game:draw()
    love.graphics.push()
    love.graphics.applyTransform(self.camera:getTransform())
    
    -- Draw map
    self.map:draw(0, 0)

    -- Draw province fills and region labels
    self:drawProvinceBoundaries()
    
    -- Draw starting areas during placement phase
    if self.state == "placing" then
        self:drawStartingAreas()
    end
    
    -- Draw grid coordinates for debugging
    --self:drawGridCoordinates()
    
    -- Draw bases (only draw placed bases)
    for _, base in ipairs(self.bases) do
        if base.col > 0 and base.row > 0 then  -- Only draw if placed
            local pixelX, pixelY = self.map:gridToPixels(base.col, base.row)
            base:draw(pixelX, pixelY, self.hexSideLength)
            
            -- Draw influence radius (optional visual indicator)
            self:drawBaseRadius(base, pixelX, pixelY)
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
    
    -- Draw air superiority markers on tiles ("=", "^", "˅") for tiles with AS
    local asMap = self:calculateAirSuperiorityMap()
    for key, vals in pairs(asMap) do
        local comma = string.find(key, ",")
        if comma then
            local col = tonumber(string.sub(key, 1, comma - 1))
            local row = tonumber(string.sub(key, comma + 1))
            if col and row then
                -- Respect fog of war: only show markers if tile is visible to current team
                if self.fogOfWar and not self.fogOfWar:isTileVisible(self.currentTurn, col, row) then
                    goto continue_as
                end

                local t1 = vals[1] or 0
                local t2 = vals[2] or 0
                local playerAS = (self.currentTurn == 1) and t1 or t2
                local enemyAS = (self.currentTurn == 1) and t2 or t1

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
                            if self.currentTurn == 1 then love.graphics.setColor(1, 0, 0) else love.graphics.setColor(0, 0, 1) end
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
    
    -- Draw pieces (only draw placed pieces)
    for _, piece in ipairs(self.pieces) do
        if piece.col > 0 and piece.row > 0 then  -- Only draw if placed
            local pixelX, pixelY = self.map:gridToPixels(piece.col, piece.row)
            piece:draw(pixelX, pixelY, self.hexSideLength)
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

    -- Draw fog of war for current player's team (after all game elements)
    if self.state == "playing" then
        self.fogOfWar:draw(self.currentTurn, self.camera, 0, 0)
    elseif self.state == "placing" then
        -- During placement, show fog for the team that's placing
        self.fogOfWar:draw(self.placementTeam, self.camera, 0, 0)
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
    -- Highlight all land tiles that are not occupied
    love.graphics.setColor(0, 1, 0, 0.2)
    for col = 1, self.map.cols do
        for row = 1, self.map.rows do
            local tile = self.map:getTile(col, row)
            if tile and tile.isLand and not self:getPieceAt(col, row) and not self:getBaseAt(col, row) and not self:getResourceAt(col, row) then
                local points = tile.points
                love.graphics.polygon("fill", points)
            end
        end
    end
end

function Game:drawStartingAreas()
    -- Draw starting area indicators for both teams (top and bottom strips)
    for team, area in pairs(self.teamStartingAreas) do
        -- Determine color based on team and whether it's the current placement team
        local isCurrentTeam = (team == self.placementTeam)
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
        
        -- Draw outline for current team's starting area
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

function Game:drawBaseRadius(base, pixelX, pixelY)
    -- Draw hexagons within the base's influence radius, respecting terrain
    local radius = base:getRadius()
    
    -- Use getHexesWithinRange which respects terrain passability
    -- Pass base's team so enemy pieces don't block the visualization
    local visited = {}
    self:getHexesWithinRange(base.col, base.row, radius, visited, base.team)
    
    -- Only show radius for bases belonging to the current player's team
    if base.team ~= self.currentTurn then
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
        -- Placement phase UI
        local teamName = self.placementTeam == 1 and "Red" or "Blue"
        local teamPiecesPlaced = 0
        for _, piece in ipairs(self.pieces) do
            if piece.team == self.placementTeam and piece.col > 0 and piece.row > 0 then
                teamPiecesPlaced = teamPiecesPlaced + 1
            end
        end
        local remaining = self.piecesPerTeam - teamPiecesPlaced
        love.graphics.print("Placement Phase - Turn 0", 10, 10)
        love.graphics.print("Team " .. teamName .. " placing", 10, 30)
        love.graphics.print("Pieces remaining: " .. remaining, 10, 50)
        love.graphics.setFont(love.graphics.newFont(10))
        love.graphics.print("Click on land tiles to place your infantry", 10, 70)
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
    end
end

function Game:mousepressed(x, y, button)
    local worldX, worldY = self.camera:screenToWorld(x, y)
    local col, row = self.map:pixelsToGrid(worldX, worldY)
    
    if self.state == "placing" then
        -- Placement phase: place pieces or bases on click
        if button == 1 then  -- Left click
            if self.placementPhase == "pieces" then
                self:placePiece(col, row)
            else
                self:placeBase(col, row)
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
            
            -- Check if clicking on a piece first (pieces have priority over bases)
            local piece = self:getPieceAt(col, row)
            local base = self:getBaseAt(col, row)
            
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
    
    -- Find piece at this location
    local piece = self:getPieceAt(col, row)
    
    -- If clicking on the already selected piece, deselect it
    if piece and piece == self.selectedPiece then
        piece:deselect(self)
        return
    end
    
    -- Deselect previous piece
    if self.selectedPiece then
        self.selectedPiece.selected = false
    end
    
    if piece and piece.team == self.currentTurn then

        piece.selected = true
        self.selectedPiece = piece
        self:calculateValidMoves()

    else
        self.selectedPiece = nil
        self.validMoves = {}
        self.validAttacks = {}
    end
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
                -- Place unit here
                self:addPiece(unitType, team, neighbor.col, neighbor.row)
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
    local map = self:calculateAirSuperiorityMap()
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

    -- Region control bonuses: +1 resource per controlled region
    local regionOwners = self:calculateRegionControl()
    for regionId, owner in pairs(regionOwners) do
        if owner == team then
            self.teamResources[team] = self.teamResources[team] + 1
        end
    end
end

function Game:movePiece(col, row)
    if not self.selectedPiece then return end
    
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
        self.selectedPiece:setPosition(col, row)
        -- Check for mines triggered by moving into this tile
        self:triggerMineAt(col, row, self.selectedPiece)
        
        self:calculateValidMoves()
    elseif isValidAttack and targetPiece then
        -- Check if piece has ammo
        if not self.selectedPiece:hasAmmo() then
            return  -- Can't attack without ammo
        end
        
        -- Use ammo and attack
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
            -- Only move to the enemy tile if we killed them
            -- Only allow the attacker to move into the target tile when the attack was adjacent (melee).
            -- Ranged attacks (distance > 1) should not result in movement into the target tile.
            if self:isWithinRange(self.selectedPiece.col, self.selectedPiece.row, col, row, 1) then
                self.selectedPiece:setPosition(col, row)
                -- Check for mines when attacker moves into the tile after killing
                self:triggerMineAt(col, row, self.selectedPiece)
            end
        end
        -- If enemy survived, attacker stays in place (no movement)
        -- Mark piece as moved since it attacked
        self.selectedPiece.hasMoved = true
        self:calculateValidMoves()
    end
end

function Game:keypressed(key)
    if key == "e" then
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
                        self:addBase(piece.buildingType, piece.buildingTeam, piece.col, piece.row)
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
    
    self.selectedPiece = nil
    self.validMoves = {}
    self.validAttacks = {}
    
    -- Switch to next team's turn
    self.currentTurn = self.currentTurn == 1 and 2 or 1
    
    -- Only increment turn counter when it goes back to team 1 (after both teams have played)
    if self.currentTurn == 1 then
        self.turnCount = self.turnCount + 1
    end
    
    -- Reset move status for ALL pieces of the current team at the START of their turn
    -- This includes engineers who just completed building
    for _, piece in ipairs(self.pieces) do
        if piece.team == self.currentTurn then
            piece:resetMove()
        end
    end
end

function Game:isInStartingArea(col, row, team)
    -- Check if position is within the team's starting area (top or bottom 5 rows)
    local area = self.teamStartingAreas[team]
    if not area then return false end
    
    -- Check if row is within starting area depth
    return row >= area.rowStart and row <= area.rowEnd
end

function Game:placePiece(col, row)
    -- Check if tile is valid (must be land and not occupied)
    local tile = self.map:getTile(col, row)
    if not tile or not tile.isLand then
        return  -- Can't place on water or invalid tile
    end
    
    -- Check if position is within the team's starting area
    if not self:isInStartingArea(col, row, self.placementTeam) then
        return  -- Can't place outside starting area
    end
    
    -- Check if tile is already occupied
    if self:getPieceAt(col, row) then
        return  -- Tile already has a piece
    end
    
    -- Find the first unplaced piece for the current placement team
    for _, piece in ipairs(self.pieces) do
        if piece.team == self.placementTeam and piece.col == 0 and piece.row == 0 then
            -- Place this piece
            piece:setPosition(col, row)
            self.piecesPlaced = self.piecesPlaced + 1
            
            -- Check if current team has finished placing
            local teamPiecesPlaced = 0
            for _, p in ipairs(self.pieces) do
                if p.team == self.placementTeam and p.col > 0 and p.row > 0 then
                    teamPiecesPlaced = teamPiecesPlaced + 1
                end
            end
            
            if teamPiecesPlaced >= self.piecesPerTeam then
                -- Current team finished placing pieces, switch to bases or next team
                if self.placementTeam == 1 then
                    -- Team 1 finished pieces, switch to bases
                    self.placementPhase = "bases"
                else
                    -- Team 2 finished pieces, switch to bases
                    self.placementPhase = "bases"
                end
            end
            return
        end
    end
end

function Game:placeBase(col, row)
    -- Check if tile is valid (must be land and not occupied)
    local tile = self.map:getTile(col, row)
    if not tile or not tile.isLand then
        return  -- Can't place on water or invalid tile
    end
    
    -- Check if position is within the team's starting area
    if not self:isInStartingArea(col, row, self.placementTeam) then
        return  -- Can't place outside starting area
    end
    
    -- Check if tile is already occupied by piece or base
    if self:getPieceAt(col, row) or self:getBaseAt(col, row) then
        return  -- Tile already has something
    end
    
    -- Find the first unplaced base for the current placement team
    for _, base in ipairs(self.bases) do
        if base.team == self.placementTeam and base.col == 0 and base.row == 0 then
            -- Place this base
            base:setPosition(col, row)
            self.basesPlaced = self.basesPlaced + 1
            
            -- Check if current team has finished placing bases
            local teamBasesPlaced = 0
            for _, b in ipairs(self.bases) do
                if b.team == self.placementTeam and b.col > 0 and b.row > 0 then
                    teamBasesPlaced = teamBasesPlaced + 1
                end
            end
            
            if teamBasesPlaced >= self.basesPerTeam then
                -- Current team finished placing bases, switch to next team
                if self.placementTeam == 1 then
                    -- Team 1 finished, switch to Team 2 pieces
                    self.placementTeam = 2
                    self.placementPhase = "pieces"
                else
                    -- Both teams finished placing, start the game
                    self.state = "playing"
                    self.turnCount = 1
                    self.currentTurn = 1  -- Team 1 goes first
                    -- Reset all pieces so they can move in the first turn
                    for _, p in ipairs(self.pieces) do
                        p:resetMove()
                    end
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
    self.selectedPiece = nil
    self.actionMenu = nil
    self.actionMenuContext = nil
    self.actionMenuContextType = nil
    self:initializePieces()
    self:initializeBases()
    self:generateResources()
end

return Game
