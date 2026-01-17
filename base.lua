-- Base/Structure system for logistics

local Base = {}
Base.__index = Base

-- Base types with their properties
local BASE_TYPES = {
    hq = { name = "HQ", radius = 3, suppliesAmmo = true, suppliesSupply = true },
    ammoDepot = { name = "Ammo Depot", radius = 2, suppliesAmmo = true, suppliesSupply = false },
    supplyDepot = { name = "Supply Depot", radius = 2, suppliesAmmo = false, suppliesSupply = true },
}

function Base.new(baseType, team, gameMap, col, row)
    local self = setmetatable({}, Base)
    
    if not BASE_TYPES[baseType] then
        error("Unknown base type: " .. baseType)
    end
    
    self.gameMap = gameMap
    self.type = baseType
    self.stats = BASE_TYPES[baseType]
    self.team = team or 1  -- Team 1 or 2
    self.col = col or 0  -- 0 means not placed yet
    self.row = row or 0
    self.hexTile = nil
    if col and row then
        self.hexTile = gameMap:getTile(col, row)
    end
    
    return self
end

function Base:setPosition(col, row)
    self.col = col
    self.row = row
    self.hexTile = self.gameMap:getTile(col, row)
end

function Base:getRadius()
    return self.stats.radius
end

function Base:suppliesAmmo()
    return self.stats.suppliesAmmo
end

function Base:suppliesSupply()
    return self.stats.suppliesSupply
end

function Base:getColor()
    if self.team == 1 then
        return 1, 0, 0  -- Red for team 1
    else
        return 0, 0, 1  -- Blue for team 2
    end
end

function Base:draw(pixelX, pixelY, hexSideLength)
    local size = hexSideLength * 0.6
    local r, g, b = self:getColor()
    
    -- TODO: Replace with image assets later
    -- if self.image then
    --     love.graphics.draw(self.image, pixelX, pixelY, ...)
    --     return
    -- end
    
    -- Draw different generic shapes for each base type
    if self.type == "hq" then
        -- HQ: Pentagon
        love.graphics.setColor(r, g, b)
        local points = {}
        for i = 0, 4 do
            local angle = (i * 2 * math.pi / 5) - math.pi / 2
            local radius = size * 0.5
            table.insert(points, pixelX + radius * math.cos(angle))
            table.insert(points, pixelY + radius * math.sin(angle))
        end
        love.graphics.polygon("fill", points)
        love.graphics.setColor(0, 0, 0)
        love.graphics.polygon("line", points)
        
    elseif self.type == "supplyDepot" then
        -- Ammo Depot: Hexagon
        love.graphics.setColor(r, g, b)
        local points = {}
        for i = 0, 5 do
            local angle = (i * 2 * math.pi / 6) - math.pi / 2
            local radius = size * 0.5
            table.insert(points, pixelX + radius * math.cos(angle))
            table.insert(points, pixelY + radius * math.sin(angle))
        end
        love.graphics.polygon("fill", points)
        love.graphics.setColor(0, 0, 0)
        love.graphics.polygon("line", points)
        
    elseif self.type == "ammoDepot" then
        -- Supply Depot: Triangle
        love.graphics.setColor(r, g, b)
        local points = {
            pixelX, pixelY - size * 0.5,
            pixelX - size * 0.4, pixelY + size * 0.4,
            pixelX + size * 0.4, pixelY + size * 0.4
        }
        love.graphics.polygon("fill", points)
        love.graphics.setColor(0, 0, 0)
        love.graphics.polygon("line", points)
        
    else
        -- Default: Square
        love.graphics.setColor(r, g, b)
        love.graphics.rectangle("fill", pixelX - size/2, pixelY - size/2, size, size)
        love.graphics.setColor(0, 0, 0)
        love.graphics.rectangle("line", pixelX - size/2, pixelY - size/2, size, size)
    end
end

return Base
