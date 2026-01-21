-- Fog of War system for hex grid games
-- Tracks visibility and exploration per team

local FogOfWar = {}
FogOfWar.__index = FogOfWar

function FogOfWar.new(map, numTeams)
    local self = setmetatable({}, FogOfWar)
    
    self.map = map
    self.numTeams = numTeams or 2
    
    -- Track visibility and exploration per team
    -- visible[team][col][row] = true if tile is currently visible
    -- explored[team][col][row] = true if tile has been explored
    self.visible = {}
    self.explored = {}
    
    for team = 1, self.numTeams do
        self.visible[team] = {}
        self.explored[team] = {}
    end
    
    return self
end

function FogOfWar:isTileVisible(team, col, row)
    if not self.visible[team] then return false end
    if not self.visible[team][col] then return false end
    return self.visible[team][col][row] == true
end

function FogOfWar:isTileExplored(team, col, row)
    if not self.explored[team] then return false end
    if not self.explored[team][col] then return false end
    return self.explored[team][col][row] == true
end

function FogOfWar:setTileVisible(team, col, row, visible)
    if not self.visible[team] then
        self.visible[team] = {}
    end
    if not self.visible[team][col] then
        self.visible[team][col] = {}
    end
    self.visible[team][col][row] = visible
    
    -- If tile becomes visible, mark it as explored
    if visible then
        self:setTileExplored(team, col, row, true)
    end
end

function FogOfWar:setTileExplored(team, col, row, explored)
    if not self.explored[team] then
        self.explored[team] = {}
    end
    if not self.explored[team][col] then
        self.explored[team][col] = {}
    end
    self.explored[team][col][row] = explored
end

function FogOfWar:revealAreaFull(team, centerCol, centerRow, radius)
    -- Reveal ALL tiles within radius from center (no line of sight checks)
    local centerHex = self.map:getTile(centerCol, centerRow)
    if not centerHex then return end
    
    -- Use BFS to find all tiles within range
    local queue = {{col = centerCol, row = centerRow, distance = 0}}
    local visitedSet = {}
    visitedSet[centerCol .. "," .. centerRow] = true
    
    while #queue > 0 do
        local current = table.remove(queue, 1)
        
        -- Reveal this tile if within radius
        if current.distance <= radius then
            self:setTileVisible(team, current.col, current.row, true)
        end
        
        -- Stop if we've reached maximum range
        if current.distance >= radius then
            goto continue
        end
        
        -- Get neighbors
        local currentHex = self.map:getTile(current.col, current.row)
        if currentHex then
            local neighbors = self.map:getNeighbors(currentHex, 1)
            for _, neighbor in ipairs(neighbors) do
                local key = neighbor.col .. "," .. neighbor.row
                if not visitedSet[key] then
                    local neighborTile = self.map:getTile(neighbor.col, neighbor.row)
                    if neighborTile then
                        visitedSet[key] = true
                        table.insert(queue, {
                            col = neighbor.col,
                            row = neighbor.row,
                            distance = current.distance + 1
                        })
                    end
                end
            end
        end
        ::continue::
    end
end

function FogOfWar:revealArea(team, centerCol, centerRow, radius, visited)
    -- Reveal all tiles within radius from center using line of sight
    visited = visited or {}
    local centerHex = self.map:getTile(centerCol, centerRow)
    if not centerHex then return end
    
    -- Use BFS to find all tiles within range, then check line of sight for each
    local queue = {{col = centerCol, row = centerRow, distance = 0}}
    local visitedSet = {}
    visitedSet[centerCol .. "," .. centerRow] = true
    
    -- First, collect all tiles within range using BFS
    local tilesInRange = {}
    while #queue > 0 do
        local current = table.remove(queue, 1)
        
        -- Add to tiles in range if within radius
        if current.distance <= radius then
            table.insert(tilesInRange, {col = current.col, row = current.row, distance = current.distance})
        end
        
        -- Stop if we've reached maximum range
        if current.distance >= radius then
            goto continue
        end
        
        -- Get neighbors
        local currentHex = self.map:getTile(current.col, current.row)
        if currentHex then
            local neighbors = self.map:getNeighbors(currentHex, 1)
            for _, neighbor in ipairs(neighbors) do
                local key = neighbor.col .. "," .. neighbor.row
                if not visitedSet[key] then
                    local neighborTile = self.map:getTile(neighbor.col, neighbor.row)
                    if neighborTile then
                        visitedSet[key] = true
                        table.insert(queue, {
                            col = neighbor.col,
                            row = neighbor.row,
                            distance = current.distance + 1
                        })
                    end
                end
            end
        end
        ::continue::
    end
    
    -- Now check line of sight for each tile and reveal if visible
    for _, tile in ipairs(tilesInRange) do
        local targetHex = self.map:getTile(tile.col, tile.row)
        if targetHex then
            -- Check if this tile has line of sight from center
            local blockingHex = {}  -- Will contain the blocking hex if line is blocked
            local hasLOS = self.map:hasFieldOfView(centerHex, targetHex, tile.distance, blockingHex)
            
            if hasLOS then
                -- Clear line of sight - reveal the target tile
                self:setTileVisible(team, tile.col, tile.row, true)
            end
            -- Note: blocking hexes are not automatically revealed
            -- They must be within range to be visible on their own
        end
    end
end

function FogOfWar:updateVisibility(team, pieces, bases, startingAreas)
    -- Clear current visibility for this team
    if self.visible[team] then
        self.visible[team] = {}
    end
    
    -- Reveal starting area for this team (full visibility, no line of sight checks)
    if startingAreas and startingAreas[team] then
        local corner = startingAreas[team]
        if corner then
            self:revealAreaFull(team, corner.col, corner.row, 5)
        end
    end
    
    -- Reveal tiles around all pieces for this team
    for _, piece in ipairs(pieces) do
        if piece.team == team and piece.col > 0 and piece.row > 0 then
            -- Pieces reveal tiles within their vision range
            local visionRange = 3  -- Default vision range
            if piece.getViewRange then
                visionRange = piece:getViewRange() or visionRange
            end
            self:revealArea(team, piece.col, piece.row, visionRange, {})
        end
    end
    
    -- Reveal tiles around all bases for this team
    for _, base in ipairs(bases) do
        if base.team == team and base.col > 0 and base.row > 0 then            
            -- Bases reveal tiles within their influence radius
            local visionRange = 2  -- Default vision range
            if base.getRadius then
                visionRange = base:getRadius() or 3
            end
            self:revealArea(team, base.col, base.row, visionRange, {})
        end
    end
end

function FogOfWar:draw(team, camera, sectionOffsetX, sectionOffsetY)
    if not self.visible[team] then return end
    
    sectionOffsetX = sectionOffsetX or 0
    sectionOffsetY = sectionOffsetY or 0
    
    -- Calculate which tiles are visible on screen for this section
    local screenWidth = love.graphics.getWidth()
    local screenHeight = love.graphics.getHeight()
    local centerX = screenWidth / 2
    local centerY = screenHeight / 2
    
    -- Convert screen bounds to world coordinates using the same logic as camera:screenToWorld
    -- The camera transform: translate to center, scale, then translate by -camera.x, -camera.y
    -- So worldX = camera.x + (screenX - centerX) / zoom
    local cameraZoom = camera.zoom or 1
    local minScreenX = camera.x + (0 - centerX) / cameraZoom
    local maxScreenX = camera.x + (screenWidth - centerX) / cameraZoom
    local minScreenY = camera.y + (0 - centerY) / cameraZoom
    local maxScreenY = camera.y + (screenHeight - centerY) / cameraZoom
    
    -- Adjust for this section's offset
    local sectionMinX = minScreenX - sectionOffsetX
    local sectionMaxX = maxScreenX - sectionOffsetX
    local sectionMinY = minScreenY - sectionOffsetY
    local sectionMaxY = maxScreenY - sectionOffsetY
    
    -- Convert to grid coordinates with some padding
    local padding = 100 -- Extra padding to ensure we don't miss tiles
    local startCol = math.max(1, math.floor((sectionMinX - padding) / self.map.horizontalSpacing))
    local endCol = math.min(self.map.cols, math.ceil((sectionMaxX + padding) / self.map.horizontalSpacing))
    local startRow = math.max(1, math.floor((sectionMinY - padding) / self.map.verticalSpacing))
    local endRow = math.min(self.map.rows, math.ceil((sectionMaxY + padding) / self.map.verticalSpacing))
    
    -- Draw unexplored fog (dark) for visible tiles only
    love.graphics.setColor(0, 0, 0, 0.8) -- Black fog for unexplored
    for row = startRow, endRow do
        for col = startCol, endCol do
            local hexTile = self.map:getTile(col, row)
            if hexTile then
                if not self:isTileVisible(team, col, row) and not self:isTileExplored(team, col, row) then
                    local points = hexTile.points
                    if points then
                        -- Apply section offset to points
                        local offsetPoints = {}
                        for i = 1, #points, 2 do
                            table.insert(offsetPoints, points[i] + sectionOffsetX)
                            table.insert(offsetPoints, points[i + 1] + sectionOffsetY)
                        end
                        love.graphics.polygon("fill", offsetPoints)
                    end
                end
            end
        end
    end
    
    -- Draw explored fog (semi-transparent grey) for visible tiles only
    love.graphics.setColor(0.2, 0.2, 0.2, 0.5) -- Grey fog for explored but not visible
    for row = startRow, endRow do
        for col = startCol, endCol do
            local hexTile = self.map:getTile(col, row)
            if hexTile then
                if not self:isTileVisible(team, col, row) and self:isTileExplored(team, col, row) then
                    local points = hexTile.points
                    if points then
                        -- Apply section offset to points
                        local offsetPoints = {}
                        for i = 1, #points, 2 do
                            table.insert(offsetPoints, points[i] + sectionOffsetX)
                            table.insert(offsetPoints, points[i + 1] + sectionOffsetY)
                        end
                        love.graphics.polygon("fill", offsetPoints)
                    end
                end
            end
        end
    end
    
    love.graphics.setColor(1, 1, 1) -- Reset color
end

return FogOfWar
