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
    local r, g, b = self:getColor()
    
    -- Draw base as a square
    local size = hexSideLength * 0.6
    love.graphics.setColor(r, g, b)
    love.graphics.rectangle("fill", pixelX - size/2, pixelY - size/2, size, size)
    
    -- Draw outline
    love.graphics.setColor(0, 0, 0)
    love.graphics.rectangle("line", pixelX - size/2, pixelY - size/2, size, size)
    
    -- Draw influence radius indicator (optional, can be toggled)
    -- This would be drawn in the game's draw function
end

return Base
