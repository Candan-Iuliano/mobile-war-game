-- Game piece/unit system for chess-like movement and combat

local Piece = {}
Piece.__index = Piece

-- Toggle to disable ammo consumption/checks for testing
Piece.IGNORE_AMMO = true

-- Generic fallback stats if a type module omits a property
local GENERIC_DEFAULTS = {
    hp = 1,
    attackDice = 1,
    defenseDice = 1,
    maxAmmo = 0,
    moveRange = 1,
    viewRange = 1,
    attackRange = 1,
    maxDie = 6,
    damage = 1,
}

-- Piece types with their properties
-- Piece types are implemented as separate modules (e.g. infantry.lua, sniper.lua)
-- Each type module should return a table: { stats = {...}, methods = {...} }
-- `Piece.new` will load the module for the requested type and compose
-- a prototype chain so type-specific methods are checked before base methods.

function Piece.new(pieceType, team, gameMap, col, row)
    -- Load type module (must be available via require("infantry"), etc.)
    local ok, typeMod = pcall(require, pieceType)
    if not ok or not typeMod then
        error("Unknown piece type or missing module: " .. tostring(pieceType))
    end

    -- Create prototype chain: type methods -> Piece
    local typeProto = typeMod.methods or {}
    setmetatable(typeProto, { __index = Piece })

    -- Create instance and point its metatable to type prototype
    local self = setmetatable({}, { __index = typeProto })

    self.gameMap = gameMap
    self.type = pieceType
    -- Merge provided stats with generic defaults
    local provided = typeMod.stats or {}
    self.stats = {}
    for k, v in pairs(GENERIC_DEFAULTS) do self.stats[k] = v end
    for k, v in pairs(provided) do self.stats[k] = v end
    self.team = team or 1
    self.col = col or 0
    self.row = row or 0
    self.maxHp = self.stats.hp or 1
    self.hp = self.maxHp
    self.selected = false
    self.canMove = true
    self.hasMoved = false
    
    -- Building system (for engineers)
    self.isBuilding = false  -- Is this piece currently building something?
    self.buildingType = nil  -- What type of structure is being built
    self.buildingTurnsRemaining = 0  -- How many more turns until building completes
    self.buildingTeam = nil  -- Team that owns the structure being built
    
    -- Ammo and supply system
    self.maxAmmo = self.stats.maxAmmo or 3
    self.ammo = self.maxAmmo  -- Current ammo remaining
    -- self.maxSupply = self.stats.maxSupply or 5
     self.maxSupply = 50
    self.supply = self.maxSupply  -- Current supply remaining (turns until attrition)
    self.attritionDamage = 2  -- Damage per turn when out of supply
    
    self.hexTile = nil
    if col and row then
        self.hexTile = gameMap:getTile(col, row)
    end
    -- Forest stealth state
    self.hiddenInForest = false
    self.revealedTo = self.revealedTo or {}
    
    -- Waypoint system for multi-step moves
    self.waypoints = {}  -- List of {col, row} waypoints to follow
    self.currentWaypointIndex = 0  -- Index of the waypoint being moved toward
    
    return self
end

-- Default hooks for piece-specific behavior (can be overridden by type modules)
function Piece:getMoveCost(fromCol, fromRow, toCol, toRow)
    -- Return table of resource costs for moving this piece (e.g., { oil = 1 })
    -- Default: no extra cost
    return {}
end

function Piece:onMove(game, fromCol, fromRow, toCol, toRow)
    -- Hook invoked after a move is applied. Default: mark as moved.
    if self.hasMoved == nil then self.hasMoved = true else self.hasMoved = true end
end

function Piece:getBuildCosts()
    -- For unit types that define build costs, return table (e.g., { oil = 1 })
    -- Default: none
    return {}
end

function Piece:getMovementRange()
    return self.stats.moveRange
end

function Piece:getViewRange()
    return self.stats.viewRange or self.stats.moveRange or 3
end

function Piece:getAttackRange()
    return self.stats.attackRange
end

function Piece:getAttackDice()
    return self.stats.attackDice or 1
end

function Piece:getDefenseDice()
    return self.stats.defenseDice or 1
end

function Piece:getDieMax()
    return self.stats.maxDie or 6
end

function Piece:getDamage()
    return self.stats.damage or 1
end

function Piece:useAmmo()
    if Piece.IGNORE_AMMO then
        return true
    end
    if self.ammo > 0 then
        self.ammo = self.ammo - 1
        return true
    end
    return false  -- Out of ammo
end

function Piece:hasAmmo()
    if Piece.IGNORE_AMMO then return true end
    return self.ammo > 0
end

function Piece:consumeSupply()
    if self.supply > 0 then
        self.supply = self.supply - 1
    end
end

function Piece:hasSupply()
    return self.supply > 0
end

function Piece:applyAttrition()
    if not self:hasSupply() then
        self:takeDamage(self.attritionDamage)
    end
end

function Piece:resupply(ammoAmount, supplyAmount)
    ammoAmount = ammoAmount or self.maxAmmo
    supplyAmount = supplyAmount or self.maxSupply
    self.ammo = math.min(self.maxAmmo, self.ammo + ammoAmount)
    self.supply = math.min(self.maxSupply, self.supply + supplyAmount)
end

function Piece:takeDamage(amount)
    self.hp = math.max(0, self.hp - amount)
    return self.hp <= 0  -- Returns true if piece is dead
end

function Piece:heal(amount)
    self.hp = math.min(self.maxHp, self.hp + amount)
end

function Piece:setPosition(col, row)
    local oldCol, oldRow = self.col, self.row
    self.col = col
    self.row = row
    self.hexTile = self.gameMap:getTile(col, row)
    
    -- Mark as moved if position actually changed
    if oldCol ~= col or oldRow ~= row then
        self.hasMoved = true
    end
    -- Entering a forest tile hides the unit from enemy teams until revealed
    if self.hexTile and self.hexTile.isForest then
        self.hiddenInForest = true
        self.revealedTo = {}
    else
        self.hiddenInForest = false
    end
end

function Piece:resetMove()
    self.hasMoved = false
end

function Piece:deselect(game)
    self.selected = false
    if game and game.selectedPiece == self then
        game.selectedPiece = nil
    end
    if game then
        game.validMoves = {}
        game.validAttacks = {}
        game.actionMenu = nil
        game.actionMenuContext = nil
        game.actionMenuContextType = nil
    end
end

-- Note: `startBuilding` is implemented by builder/engineer subclasses.

function Piece:getColor()
    if self.team == 1 then
        return 1, 0, 0  -- Red for team 1
    else
        return 0, 0, 1  -- Blue for team 2
    end
end

function Piece:getActionOptions(game)
    local options = {}
    
    if not game then
        return options  -- Return empty options if game isn't provided
    end
    
    if self.stats.canBuild and not self.isBuilding then
        local onResourceTile = game:getResourceAt(self.col, self.row) ~= nil
        local hasBase = game:getBaseAt(self.col, self.row) ~= nil
        
        table.insert(options, {
            id = "build_hq",
            name = "Build HQ",
            cost = 10,
            buildTurns = 4,
            icon = "hq",
            disabled = onResourceTile or hasBase
        })
        table.insert(options, {
            id = "build_ammo_depot",
            name = "Build Ammo Depot",
            cost = 5,
            buildTurns = 2,
            icon = "ammo_depot",
            disabled = onResourceTile or hasBase
        })
        table.insert(options, {
            id = "build_supply_depot",
            name = "Build Supply Depot",
            cost = 5,
            buildTurns = 2,
            icon = "supply_depot",
            disabled = onResourceTile or hasBase
        })
        table.insert(options, {
            id = "build_resource_mine",
            name = "Build Resource Mine",
            cost = 3,
            buildTurns = 3,
            icon = "resource_mine",
            disabled = hasBase
        })
        table.insert(options, {
            id = "build_airbase",
            name = "Build Airbase",
            cost = 8,
            oilCost = 2,
            buildTurns = 4,
            icon = "airbase",
            disabled = onResourceTile or hasBase
        })
        table.insert(options, {
            id = "place_mine",
            name = "Place Mine",
            cost = 2,
            icon = "mine",
            disabled = (game and game:getMineAt(self.col, self.row) ~= nil) or false
        })
        table.insert(options, {
            id = "build_defense",
            name = "Build Defense",
            cost = 1,
            icon = "defense",
            disabled = (game and game:getDefenseAt(self.col, self.row) ~= nil) or false
        })
    end
    
    -- Sweep for mines
    local disabled = (self.hasMoved or self.isBuilding)
    table.insert(options, {
        id = "sweep_mines",
        name = "Sweep For Mines",
        cost = 0,
        icon = "sweep",
        shortcut = "S",
        disabled = disabled
    })
    
    -- Disarm options
    local startTile = game.map:getTile(self.col, self.row)
    if startTile then
        local neighbors = game.map:getNeighbors(startTile, 1)
        for _, neighbor in ipairs(neighbors) do
            local mine = game:getMineAt(neighbor.col, neighbor.row)
            if mine and mine.revealedTo and mine.revealedTo[self.team] and mine.team ~= self.team then
                table.insert(options, {
                    id = "disarm_mine",
                    name = "Disarm Mine",
                    cost = 0,
                    icon = "disarm",
                    shortcut = "D",
                    targetMine = mine,
                    disabled = (self.hasMoved or self.isBuilding)
                })
            end
        end
    end
    
    return options
end

function Piece:draw(pixelX, pixelY, hexSideLength)
    local r, g, b = self:getColor()
    
    -- Draw piece as a circle
    love.graphics.setColor(r, g, b)
    love.graphics.circle("fill", pixelX, pixelY, hexSideLength * 0.4)
    
    -- Draw outline
    love.graphics.setColor(0, 0, 0)
    love.graphics.circle("line", pixelX, pixelY, hexSideLength * 0.4)
    
    -- Draw selection indicator
    if self.selected then
        love.graphics.setColor(1, 1, 0)
        love.graphics.circle("line", pixelX, pixelY, hexSideLength * 0.5)
    end
    
    -- Draw HP indicator (small bar above piece)
    local healthPercent = self.hp / self.maxHp
    love.graphics.setColor(1, 0, 0)
    love.graphics.rectangle("fill", pixelX - 15, pixelY - 30, 30, 4)
    love.graphics.setColor(0, 1, 0)
    love.graphics.rectangle("fill", pixelX - 15, pixelY - 30, 30 * healthPercent, 4)
    
    -- Draw "E" for engineer pieces
    -- Draw type-specific icon if the type supplies one
    if self.drawIcon and self.type ~= "sam" then
        -- type module provides drawIcon(pixelX, pixelY, hexSideLength)
        pcall(function() self:drawIcon(pixelX, pixelY, hexSideLength) end)
    end

    -- Draw veteran badge (small gold star) if veteran
    if self.veteran then
        local bx = pixelX + hexSideLength * 0.28
        local by = pixelY - hexSideLength * 0.28
        love.graphics.setColor(1, 0.85, 0)
        -- simple star: draw a small filled circle as badge background and a star char
        love.graphics.circle("fill", bx, by, hexSideLength * 0.14)
        love.graphics.setColor(0, 0, 0)
        love.graphics.setFont(love.graphics.newFont(10))
        local text = "^"
        local w = love.graphics.getFont():getWidth(text)
        local h = love.graphics.getFont():getHeight()
        love.graphics.setColor(0, 0, 0)
        love.graphics.print(text, bx - w/2, by - h/2)
    end
end

return Piece
