-- Resource tile system

local Resource = {}
Resource.__index = Resource

function Resource.new(resourceType, gameMap, col, row)
    local self = setmetatable({}, Resource)
    
    self.gameMap = gameMap
    self.type = resourceType or "generic"  -- Can expand to different types later
    self.col = col
    self.row = row
    self.hexTile = nil
    self.owner = nil  -- Which team owns this resource (nil = neutral)
    self.hasMine = false  -- Whether this resource has a mine built on it
    
    if col and row then
        self.hexTile = gameMap:getTile(col, row)
    end
    
    return self
end

function Resource:setPosition(col, row)
    self.col = col
    self.row = row
    self.hexTile = self.gameMap:getTile(col, row)
end

function Resource:capture(team)
    self.owner = team
end

function Resource:getColor()
    if self.owner == 1 then
        return 1, 0, 0  -- Red for team 1
    elseif self.owner == 2 then
        return 0, 0, 1  -- Blue for team 2
    else
        return 0.5, 0.5, 0.5  -- Gray for neutral
    end
end

function Resource:draw(pixelX, pixelY, hexSideLength)
    local size = hexSideLength * 0.3
    local r, g, b = self:getColor()
    
    -- TODO: Replace with image assets later
    -- if self.image then
    --     love.graphics.draw(self.image, pixelX, pixelY, ...)
    --     return
    -- end
    
    -- Draw resource as a diamond shape
    love.graphics.setColor(r, g, b)
    local points = {
        pixelX, pixelY - size,  -- Top
        pixelX + size, pixelY,   -- Right
        pixelX, pixelY + size,   -- Bottom
        pixelX - size, pixelY   -- Left
    }
    love.graphics.polygon("fill", points)
    
    -- Draw outline
    love.graphics.setColor(0, 0, 0)
    love.graphics.polygon("line", points)
end

return Resource
