local M = {}

M.stats = {
    name = "HQ",
    radius = 3,
    suppliesAmmo = true,
    suppliesSupply = true,
    unitCapacity = 10,
}

M.methods = {}

-- HQ-specific: get action options for building units and recruiting commanders
function M.methods:getActionOptions(game)
    local options = {}
    
    -- Add deconstruct option to all bases
    table.insert(options, {
        id = "deconstruct",
        name = "Deconstruct",
        cost = 0,
        icon = "X",
        isDeconstruct = true
    })
    
    local team = self.team
    local unitCount = game:getUnitCount(team)
    local unitCapacity = game:getUnitCapacity(team)
    local atCapacity = (unitCapacity > 0) and (unitCount >= unitCapacity) or false
    
    table.insert(options, {
        id = "build_infantry",
        name = "Recruit Infantry",
        cost = 2,
        icon = "infantry",
        disabled = atCapacity
    })
    table.insert(options, {
        id = "build_sniper",
        name = "Recruit Sniper",
        cost = 4,
        icon = "sniper",
        disabled = atCapacity
    })
    table.insert(options, {
        id = "build_tank",
        name = "Recruit Tank",
        cost = 8,
        oilCost = 3,
        icon = "tank",
        disabled = atCapacity
    })
    table.insert(options, {
        id = "build_engineer",
        name = "Recruit Engineer",
        cost = 3, 
        icon = "engineer",
        disabled = atCapacity
    })
    table.insert(options, {
        id = "build_sam",
        name = "Build SAM",
        cost = 4,
        oilCost = 1,
        icon = "sam",
        disabled = atCapacity
    })
    
    -- Recruit Commander (one per HQ nearby)
    local baseHex = game.map:getTile(self.col, self.row)
    local hasCommander = false
    if baseHex then
        local p = game:getPieceAt(self.col, self.row)
        if p and p.type == "commander" and p.team == self.team then hasCommander = true end
        local neighbors = game.map:getNeighbors(baseHex, 1)
        for _, neighbor in ipairs(neighbors) do
            local np = game:getPieceAt(neighbor.col, neighbor.row)
            if np and np.type == "commander" and np.team == self.team then
                hasCommander = true
                break
            end
        end
    end
    if not hasCommander then
        table.insert(options, {
            id = "recruit_commander",
            name = "Recruit Commander",
            cost = 5,
            icon = "commander",
            disabled = atCapacity
        })
    end
    
    return options
end

return M
