-- Camera/Viewport system for panning and zooming the hex grid

local Camera = {}
Camera.__index = Camera

function Camera.new(x, y, zoom)
    local self = setmetatable({}, Camera)
    self.x = x or 0
    self.y = y or 0
    self.zoom = zoom or 1
    self.minZoom = 0.5
    self.maxZoom = 3
    return self
end

function Camera:pan(dx, dy)
    self.x = self.x - dx / self.zoom
    self.y = self.y - dy / self.zoom
end

function Camera:zoomIn(amount)
    self.zoom = math.min(self.zoom + amount, self.maxZoom)
end

function Camera:zoomOut(amount)
    self.zoom = math.max(self.zoom - amount, self.minZoom)
end

function Camera:getTransform()
    local transform = love.math.newTransform()
    transform:translate(love.graphics.getWidth() / 2, love.graphics.getHeight() / 2)
    transform:scale(self.zoom)
    transform:translate(-self.x, -self.y)
    return transform
end

function Camera:screenToWorld(screenX, screenY)
    -- Convert screen coordinates to world coordinates
    local centerX = love.graphics.getWidth() / 2
    local centerY = love.graphics.getHeight() / 2
    
    local worldX = self.x + (screenX - centerX) / self.zoom
    local worldY = self.y + (screenY - centerY) / self.zoom
    
    return worldX, worldY
end

return Camera
