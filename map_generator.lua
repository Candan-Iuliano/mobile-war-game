-- Bare essentials hex grid map generator
-- Generates a hex grid with terrain (land/water) and decorations (trees, rocks, etc.)

local HexMap = {}
HexMap.__index = HexMap

-- Hex tile object representing a single hexagon
local HexTile = {}
HexTile.__index = HexTile

function HexTile.new(col, row, pixelX, pixelY, hexSideLength)
    local self = setmetatable({}, HexTile)
    self.hexSideLength = hexSideLength or 48
    self.hexHeight = math.sqrt(3) * self.hexSideLength
    self.hexWidth = 2 * self.hexSideLength
    
    self.col = col
    self.row = row
    self.pixelX = pixelX
    self.pixelY = pixelY
    
    -- Terrain properties
    self.isLand = false          -- false = water, true = land
    
    -- Calculate hex points for rendering
    self.points = {}
    for i = 0, 5 do
        local angle = math.pi / 3 * i
        table.insert(self.points, pixelX + self.hexSideLength * math.cos(angle))
        table.insert(self.points, pixelY + self.hexSideLength * math.sin(angle))
    end
    
    return self
end

-- Create a new hex map
function HexMap.new(cols, rows, hexSideLength)
    local self = setmetatable({}, HexMap)
    
    self.cols = cols or 100
    self.rows = rows or 100
    self.hexSideLength = hexSideLength or 48
    
    -- Hex spacing calculations
    self.hexTile = HexTile.new(0, 0, 0, 0, self.hexSideLength)
    self.horizontalSpacing = self.hexTile.hexWidth * 0.75
    self.verticalSpacing = self.hexTile.hexHeight
    
    self.grid = {}
    self.mapWidth = self.cols * self.horizontalSpacing
    self.mapHeight = self.rows * self.verticalSpacing
    
    return self
end

-- Initialize the grid with hex tiles
function HexMap:initializeGrid()
    for col = 1, self.cols do
        self.grid[col] = {}
        for row = 1, self.rows do
            -- Calculate pixel position
            local x = col * self.horizontalSpacing
            local y = row * self.verticalSpacing
            
            -- Stagger every other row for hex alignment
            if col % 2 == 0 then
                y = y + self.hexTile.hexHeight / 2
            end
            
            -- Create hex tile
            local hexTile = HexTile.new(col, row, x, y, self.hexSideLength)
            self.grid[col][row] = hexTile
        end
    end
end

-- Generate terrain using a generator profile
-- Can accept either a string (built-in methods) or a module/object
-- If module: expects a generate(map) method
function HexMap:generateTerrain(generatorOrMethod)
    generatorOrMethod = generatorOrMethod or "scattered"
    
    local generator
    
    -- Check if it's a string (built-in method)
    if type(generatorOrMethod) == "string" then
        generator = self:getBuiltInGenerator(generatorOrMethod)
    else
        -- Assume it's a module/object with a generate method
        generator = generatorOrMethod
    end
    
    -- Validate generator has required methods
    if not generator or type(generator.generate) ~= "function" then
        error("Generator must have a 'generate(map)' method")
    end

    
    -- Call the generator's generate method, passing the map
    generator:generate(self)
    

end

-- Get a built-in generator by name
function HexMap:getBuiltInGenerator(methodName)
    local generators = {
        scattered = require("mapGenerators.scatteredIslands"),
        archipelago = require("mapGenerators.archipelago"),
        continental = require("mapGenerators.continental"),
        ocean = require("mapGenerators.ocean"),
    }
    
    if not generators[methodName] then
        error("Unknown terrain generation method: " .. methodName)
    end
    
    return generators[methodName]
end




function HexMap:getNeighbors(startHex, range)
    local neighbors = {} -- Table to store valid neighbors
    local visited = {} -- Table to track visited tiles
    local queue = {} -- Queue for BFS
    local currentRange = 0 -- Current depth of BFS

    -- Initialize the queue with the starting tile
    table.insert(queue, {hex = startHex, range = 0})
    visited[startHex.col .. "," .. startHex.row] = true

    -- Perform BFS iteratively
    while #queue > 0 do
        local current = table.remove(queue, 1)
        local currentHex = current.hex
        local currentRange = current.range
        currentHex.distance = currentRange
        -- Add the current hex to neighbors if it's within range (excluding the start hex if range > 0)
        if currentRange > 0 then
            table.insert(neighbors, currentHex)
        end

        -- Stop if we've reached the desired range
        if currentRange >= range then
            goto continue
        end

        -- Determine if this is an odd or even column
        local isOddCol = currentHex.col % 2

        -- Define direction differences for odd-q grid
        local oddq_direction_differences = {
            -- Even columns
            {
                {1, 0}, {1, 1}, {0, 1},
                {-1, 0}, {-1, 1}, {0, -1}
            },
            -- Odd columns
            {
                {1, -1}, {1, 0}, {0, 1},
                {-1, -1}, {-1, 0}, {0, -1}
            }
        }

        -- Choose the correct set of offsets based on whether the column is odd or even
        local neighborOffsets = isOddCol == 0 and oddq_direction_differences[1] or oddq_direction_differences[2]

        -- Explore all neighboring tiles
        for _, offset in ipairs(neighborOffsets) do
            local dx, dy = offset[1], offset[2]
            local neighborCol = currentHex.col + dx
            local neighborRow = currentHex.row + dy


            local neighborKey = neighborCol .. "," .. neighborRow
            
            -- If the neighbor hasn't been visited, add it to the queue
            if not visited[neighborKey] then
                visited[neighborKey] = true
                table.insert(queue, {
                    hex = self.grid[neighborCol][neighborRow],
                    range = currentRange + 1
                })
            end
        end
        ::continue::
    end

    return neighbors
end


-- Get a tile by grid coordinates
function HexMap:getTile(col, row)
    if col >= 1 and col <= self.cols and row >= 1 and row <= self.rows then
        return self.grid[col][row]
    end
    return nil
end

-- Function to convert grid coordinates to pixel coordinates
function HexMap:gridToPixels(col, row)
   
    local x = col * self.horizontalSpacing
    local y = row * self.verticalSpacing

    -- Apply stagger for even columns
    if (col) % 2 == 0 then
        y = y + self.hexTile.hexHeight / 2
    end

    return x, y


end


function HexMap:pixelsToGrid(mouseX, mouseY)
    col = math.floor((mouseX / self.horizontalSpacing) + 0.5) 
    row = math.floor(((mouseY + ((col % 2 == 0) and 0 or self.hexTile.hexHeight / 2)) / self.verticalSpacing)) 
    return col, row
end

-- Draw the map
function HexMap:draw(offsetX, offsetY)
    offsetX = offsetX or 0
    offsetY = offsetY or 0
    
    for col = 1, self.cols do
        for row = 1, self.rows do
            local tile = self.grid[col][row]
            self:drawTile(tile, offsetX, offsetY)
        end
    end
end

-- Draw a single hex tile
function HexMap:drawTile(tile, offsetX, offsetY)
    offsetX = offsetX or 0
    offsetY = offsetY or 0
    
    -- Determine color based on terrain
    if tile.isIce then
        love.graphics.setColor(0.8, 0.95, 1)  -- Light blue for ice
    elseif tile.isLand then
        if tile.decorationType == "trees" or tile.decorationType == "forest" then
            love.graphics.setColor(0.2, 0.6, 0.2)  -- Green for forest
        elseif tile.decorationType == "rocks" then
            love.graphics.setColor(0.6, 0.6, 0.6)  -- Gray for rocks
        else
            love.graphics.setColor(0.8, 0.7, 0.5)  -- Tan for bare land
        end
    else
        love.graphics.setColor(0.2, 0.5, 0.8)  -- Blue for water
    end
    
    -- Draw hexagon
    local points = tile.points
    local scaledPoints = {}
    for i = 1, #points, 2 do
        table.insert(scaledPoints, points[i] + offsetX)
        table.insert(scaledPoints, points[i + 1] + offsetY)
    end
    
    love.graphics.polygon("fill", scaledPoints)
    
    -- Draw outline
    love.graphics.setColor(0.3, 0.3, 0.3)
    love.graphics.polygon("line", scaledPoints)
end

-- Get map info for debugging
function HexMap:getStats()
    local landCount = 0
    local waterCount = 0
    local iceCount = 0
    
    for col = 1, self.cols do
        for row = 1, self.rows do
            local tile = self.grid[col][row]
            if tile.isIce then
                iceCount = iceCount + 1
            elseif tile.isLand then
                landCount = landCount + 1
            else
                waterCount = waterCount + 1
            end
        end
    end
    
    return {
        landTiles = landCount,
        waterTiles = waterCount,
        iceTiles = iceCount,
        totalTiles = self.cols * self.rows,
        landPercentage = (landCount / (self.cols * self.rows)) * 100,
    }
end

return HexMap

-- Usage example:
-- local HexMap = require("hexMapGenerator")
-- local map = HexMap.new(100, 100, 48)  -- cols, rows, hex size
-- map:initializeGrid()
-- 
-- Using built-in terrain generation methods:
-- map:generateTerrain("scattered")    -- Random scattered islands
-- map:generateTerrain("archipelago")  -- Clustered island groups
-- map:generateTerrain("continental")  -- Large landmasses with water channels
-- map:generateTerrain("ocean")        -- Mostly water with few islands
--
-- Using a custom generator module:
-- local customGen = require("mapGenerators.myCustomGenerator")
-- map:generateTerrain(customGen)
--
-- map:draw(offsetX, offsetY)
--
-- Creating a custom generator module:
-- Your generator module should return an object with a generate(map) method:
--   local MyGenerator = {}
--   function MyGenerator:generate(map)
--       -- Modify map.grid to set terrain
--       -- Access tiles with: map.grid[col][row]
--       -- Set: tile.isLand (true/false), tile.decorationType
--   end
--   return MyGenerator
