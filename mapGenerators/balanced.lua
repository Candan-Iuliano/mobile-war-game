-- Balanced terrain generator for competitive maps
-- Creates semi-realistic terrain that's mirrored to ensure equal strategic value

local BalancedGenerator = {}

function BalancedGenerator:generate(map)
    -- Seed random with current time for different terrain each game
    math.randomseed(os.time())
    
    -- Create terrain using cellular automata seeded from the center
    -- Terrain is then mirrored vertically to ensure balance
    
    -- First pass: generate base terrain in upper half using noise-like pattern
    local midRow = math.ceil(map.rows / 2)
    
    -- Initialize with random seed
    for col = 1, map.cols do
        for row = 1, midRow do
            local tile = map:getTile(col, row)
            if tile then
                tile.isLand = math.random() < 0.6  -- 60% land, 40% mountain initially
            end
        end
    end
    
    -- Smooth terrain using cellular automata (multiple passes)
    for pass = 1, 3 do
        self:smoothTerrain(map, 1, midRow)
    end
    
    -- Create some strategic landmarks (clusters of mountains)
    self:createMountainClusters(map, 1, midRow, 2)
    
    -- Mirror terrain vertically for bottom half (ensures balance)
    for col = 1, map.cols do
        for row = 1, midRow do
            local sourceTile = map:getTile(col, row)
            local mirrorRow = map.rows - row + 1
            local targetTile = map:getTile(col, mirrorRow)
            
            if sourceTile and targetTile then
                targetTile.isLand = sourceTile.isLand
            end
        end
    end
end

function BalancedGenerator:smoothTerrain(map, startRow, endRow)
    -- Cellular automata smoothing: if a tile has more water neighbors, it becomes water
    -- This creates more natural-looking landmasses
    
    local tempMap = {}
    
    for col = 1, map.cols do
        tempMap[col] = {}
        for row = startRow, endRow do
            local tile = map:getTile(col, row)
            tempMap[col][row] = tile and tile.isLand or false
        end
    end
    
    -- Apply smoothing rules
    for col = 1, map.cols do
        for row = startRow, endRow do
            local tile = map:getTile(col, row)
            if tile then
                local landNeighbors = 0
                local neighbors = map:getNeighbors(tile, 1)
                
                for _, neighbor in ipairs(neighbors) do
                    if tempMap[neighbor.col] and tempMap[neighbor.col][neighbor.row] then
                        if tempMap[neighbor.col][neighbor.row] then
                            landNeighbors = landNeighbors + 1
                        end
                    end
                end
                
                -- If majority of neighbors are land, this becomes land
                -- Otherwise it becomes water/mountain
                tile.isLand = landNeighbors >= 3
            end
        end
    end
end

function BalancedGenerator:createMountainClusters(map, startRow, endRow, numClusters)
    -- Create strategic mountain clusters scattered across the map
    
    for cluster = 1, numClusters do
        -- Random cluster center
        local centerCol = math.random(5, map.cols - 5)
        local centerRow = math.random(startRow + 3, endRow - 3)
        local clusterSize = math.random(3, 6)  -- 3-6 tile radius
        
        -- Create mountain cluster centered at this point
        local centerTile = map:getTile(centerCol, centerRow)
        if centerTile then
            local tilesToProcess = {centerTile}
            local processed = {}
            local processedKey = centerCol .. "," .. centerRow
            processed[processedKey] = true
            
            for i = 1, clusterSize do
                if #tilesToProcess == 0 then break end
                
                local currentTile = table.remove(tilesToProcess, 1)
                currentTile.isLand = false  -- Make it mountain
                
                -- Add neighbors to process
                local neighbors = map:getNeighbors(currentTile, 1)
                for _, neighbor in ipairs(neighbors) do
                    local neighborKey = neighbor.col .. "," .. neighbor.row
                    if not processed[neighborKey] and math.random() < 0.7 then
                        processed[neighborKey] = true
                        table.insert(tilesToProcess, neighbor)
                    end
                end
            end
        end
    end
end

return BalancedGenerator
