local M = {}

M.stats = {
    name = "Tank",
    hp = 12,
    attackDice = 2,
    defenseDice = 2,
    moveRange = 3,
    attackRange = 1,
    viewRange = 3,
    damage = 3,
    maxAmmo = 4,
    maxDie = 6,
}

M.methods = {}

function M.methods:drawIcon(pixelX, pixelY, hexSideLength)
    love.graphics.setColor(1,1,1)
    love.graphics.rectangle("fill", pixelX - hexSideLength*0.24, pixelY - hexSideLength*0.18, hexSideLength*0.48, hexSideLength*0.36)
    love.graphics.setColor(0,0,0)
    love.graphics.rectangle("line", pixelX - hexSideLength*0.24, pixelY - hexSideLength*0.18, hexSideLength*0.48, hexSideLength*0.36)
end

-- Tank-specific behavior
M.stats.buildCosts = { oil = 1 }

function M.methods:getMoveCost(fromCol, fromRow, toCol, toRow)
    -- Tanks consume 1 oil for any move (including move-to-kill)
    if fromCol ~= toCol or fromRow ~= toRow then
        return { oil = 1 }
    end
    return {}
end

function M.methods:onMove(game, fromCol, fromRow, toCol, toRow)
    -- Host should deduct oil; but call this hook to allow type to react.
    if game and game.isHost then
        local team = self.team
        local costs = self:getMoveCost(fromCol, fromRow, toCol, toRow)
        if costs and costs.oil and costs.oil > 0 then
            game.teamOil[team] = (game.teamOil[team] or 0) - costs.oil
        end
    end
    -- Mark moved locally
    self.hasMoved = true
end

return M
