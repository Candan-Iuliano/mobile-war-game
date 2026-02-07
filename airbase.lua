local M = {}

M.stats = {
    name = "Airbase",
    radius = 5,    -- Wide influence radius for air superiority
    suppliesAmmo = false,
    suppliesSupply = false,
}

M.methods = {}

-- Get action options for airbase (airstrike targeting)
function M.methods:getActionOptions(game)
    local options = {}
    
    -- Add deconstruct option (from Base)
    table.insert(options, {
        id = "deconstruct",
        name = "Deconstruct",
        cost = 0,
        icon = "X",
        isDeconstruct = true
    })
    
    -- Always allow entering airstrike targeting from an airbase.
    -- Validation (air superiority, not targeting own units) occurs when committing the strike.
    table.insert(options, {
        id = "airstrike_target",
        name = "Airstrike (Target)",
        cost = 2,
        oilCost = 3,
        icon = "airstrike"
    })
    
    return options
end

-- Draw airbase with radius ring and air superiority symbols
-- Draw airbase with radius ring and air superiority symbols
function M.methods:draw(pixelX, pixelY, hexSideLength, game)
    local r, g, b = self:getColor()

    -- Prepare draw cache (mirrors Base:draw cache used previously)
    local size = hexSideLength * 0.9
    if not self._drawCache or self._drawCache.size ~= hexSideLength then
        self._drawCache = { size = hexSideLength }
        local icoRadius = size * 0.36

        -- wing offsets for airbase (left and right wings)
        local wingL = { -size * 0.58, 0, -size * 0.12, -size * 0.12, -size * 0.12, size * 0.12 }
        local wingR = { size * 0.58, 0, size * 0.12, -size * 0.12, size * 0.12, size * 0.12 }
        self._drawCache.wingL = wingL
        self._drawCache.wingR = wingR
    end

    -- Draw the airbase at the given pixel position
    love.graphics.push()
    love.graphics.translate(pixelX, pixelY)
    love.graphics.setColor(r, g, b)
    love.graphics.circle("fill", 0, 0, size * 0.36)
    love.graphics.setColor(0, 0, 0)
    love.graphics.setLineWidth(1)
    love.graphics.circle("line", 0, 0, size * 0.36)
    love.graphics.setLineWidth(1)

    -- Wings
    love.graphics.setColor(r, g, b)
    love.graphics.polygon("fill", self._drawCache.wingL)
    love.graphics.polygon("fill", self._drawCache.wingR)
    love.graphics.setColor(0, 0, 0)
    love.graphics.polygon("line", self._drawCache.wingL)
    love.graphics.polygon("line", self._drawCache.wingR)
    love.graphics.pop()
    love.graphics.setColor(1, 1, 1, 1)

    -- Draw radius ring and air superiority symbols using game helper function
    if game and self.col and self.col > 0 and self.row and self.row > 0 then
        local lineColor = {r, g, b}
        game:drawAirDefenseRadius(self.col, self.row, self:getRadius(), self.team, lineColor, 4)
    end
end

return M
