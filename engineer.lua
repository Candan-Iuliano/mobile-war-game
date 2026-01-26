local M = {}

M.stats = {
    name = "Engineer",
    moveRange = 3,
    attackRange = 0,
    hp = 8,
    damage = 0,
    speed = 2,
    maxAmmo = 0,
    maxSupply = 5,
    canBuild = true,
    maxMines = 2,
}

M.methods = {}

-- Initialize building state on this engineer piece
function M.methods:startBuilding(buildingType, team, buildTurns, resourceTarget, game)
    self.isBuilding = true
    self.buildingType = buildingType
    self.buildingTurnsRemaining = buildTurns
    self.buildingTeam = team
    if resourceTarget then
        self.buildingResourceTarget = resourceTarget
    end
    self.hasMoved = true
    -- Deselect and clear UI when building starts (use Piece:deselect available via prototype)
    if self.deselect then
        self:deselect(game)
    end
    -- If networked and this is a client (not host), send a build request instead of applying locally
    if Network and Network.isConnected and Network.isConnected() and not game.isHost and not game._applyingRemote then
        pcall(function()
            Network.send({type = "startBuildingRequest", col = self.col, row = self.row, buildingType = buildingType, team = team, buildTurns = buildTurns})
        end)
        return
    end
end

-- Engineer-specific build helpers (called on the piece instance)
function M.methods:buildStructure(game, structureType, team, cost, buildTurns)
    -- Deduct cost
    game.teamResources[team] = (game.teamResources[team] or 0) - (cost or 0)

    -- Check if engineer's current tile is valid (no existing base)
    local tile = game.map:getTile(self.col, self.row)
    if tile and tile.isLand and not game:getBaseAt(self.col, self.row) then
        -- Start building process via Piece:startBuilding
        if self.startBuilding then
            self:startBuilding(structureType, team, buildTurns, nil, game)
            return true
        end
    end

    -- If tile already has a base or invalid, refund the cost
    game.teamResources[team] = (game.teamResources[team] or 0) + (cost or 0)
    return false
end

function M.methods:buildResourceMine(game, team, cost, buildTurns)
    -- Check if engineer's current tile has an existing resource
    local existingResource = game:getResourceAt(self.col, self.row)
    if not existingResource then
        return false
    end

    -- Check if resource already has a mine
    if existingResource.hasMine then
        return false
    end

    -- Deduct cost
    game.teamResources[team] = (game.teamResources[team] or 0) - (cost or 0)

    -- Start building process via Piece:startBuilding
    if self.startBuilding then
        self:startBuilding("resource_mine", team, buildTurns, existingResource, game)
        return true
    end

    -- If something went wrong, refund
    game.teamResources[team] = (game.teamResources[team] or 0) + (cost or 0)
    return false
end

-- Place a land mine at the engineer's current tile
function M.methods:placeMine(game)
    -- Ensure placedMines list exists
    self.placedMines = self.placedMines or {}

    -- Only place on land tile
    local tile = game.map:getTile(self.col, self.row)
    if not tile or not tile.isLand then return false end

    -- Don't place if there's already a mine at this tile
    if game:getMineAt(self.col, self.row) then
        return false
    end

    local maxMines = self.stats.maxMines or 2
    -- If at capacity, remove the oldest mine
    if #self.placedMines >= maxMines then
        local oldest = table.remove(self.placedMines, 1)
        if oldest then
            game:removeMine(oldest)
        end
    end

    -- Create mine object
    local mine = {
        col = self.col,
        row = self.row,
        owner = self,
        team = self.team,
        damage = 5,
        placedTurn = game.turnCount or 0,
    }

    -- Reveal the mine to its owner team immediately
    mine.revealedTo = mine.revealedTo or {}
    mine.revealedTo[self.team] = true

    table.insert(self.placedMines, mine)
    -- If networked client, send request to host instead of applying locally
    if Network and Network.isConnected and Network.isConnected() and not game.isHost and not game._applyingRemote then
        pcall(function()
            Network.send({type = "placeMineRequest", col = mine.col, row = mine.row, team = mine.team})
        end)
        return true
    end

    game:addMine(mine)
    return true
end

return M
