local M = {}

M.stats = {
    name = "SAM",
    hp = 5,
    attackDice = 0,
    defenseDice = 1,
    moveRange = 2,
    attackRange = 0,
    viewRange = 3,
    damage = 0,
    maxAmmo = 0,
    maxDie = 4,
    -- Air defense radius: reduces enemy air superiority in range
    airDefenseRadius = 2,
}

M.methods = {}

function M.methods:drawIcon(pixelX, pixelY, hexSideLength, game)
    -- Draw a missile/triangle icon for SAM
    local size = hexSideLength * 0.4
    love.graphics.setColor(1, 0.8, 0)
    love.graphics.polygon("fill", 
        pixelX, pixelY - size * 0.6,
        pixelX - size * 0.5, pixelY + size * 0.4,
        pixelX + size * 0.5, pixelY + size * 0.4
    )
    love.graphics.setColor(0, 0, 0)
    love.graphics.polygon("line",
        pixelX, pixelY - size * 0.6,
        pixelX - size * 0.5, pixelY + size * 0.4,
        pixelX + size * 0.5, pixelY + size * 0.4
    )
    -- Draw radius ring and air superiority symbols using game helper function
    if game and self.col and self.col > 0 and self.row and self.row > 0 then
        local radius = self.stats.airDefenseRadius or 2
        local lineColor = {1, 1, 0}  -- Yellow for SAM radius
        game:drawAirDefenseRadius(self.col, self.row, radius, self.team, lineColor, 2)
    end
    
end

-- SAM has no attack capability
function M.methods:hasAmmo()
    return false  -- SAM cannot attack
end

function M.methods:useAmmo()
    -- SAM doesn't use ammo
end

-- Draw SAM with air defense radius visualization
function M.methods:drawRadius(pixelX, pixelY, game)
    -- Draw the piece icon
    --self:drawIcon(pixelX, pixelY, hexSideLength)
    
    -- Draw radius ring and air superiority symbols using game helper function
    if game and self.col and self.col > 0 and self.row and self.row > 0 then
        local radius = self.stats.airDefenseRadius or 2
        local lineColor = {1, 1, 0}  -- Yellow for SAM radius
        game:drawAirDefenseRadius(self.col, self.row, radius, self.team, lineColor, 2)
    end
end
return M