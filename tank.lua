local M = {}

M.stats = {
    name = "Tank",
    moveRange = 4,
    attackRange = 3,
    hp = 15,
    damage = 7,
    speed = 3,
    maxAmmo = 4,
    maxSupply = 5,
}

M.methods = {}

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
