-- Game piece/unit system for chess-like movement and combat

local Piece = {}
Piece.__index = Piece

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
    self.stats = typeMod.stats or {}
    self.team = team or 1
    self.col = col or 0
    self.row = row or 0
    self.hp = self.stats.hp or 1
    self.maxHp = self.stats.hp or 1
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

function Piece:getDamage()
    return self.stats.damage or 1
end

function Piece:useAmmo()
    if self.ammo > 0 then
        self.ammo = self.ammo - 1
        return true
    end
    return false  -- Out of ammo
end

function Piece:hasAmmo()
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
    if self.type == "engineer" then
        love.graphics.setColor(1, 1, 1)
        love.graphics.setFont(love.graphics.newFont(16))
        local text = "E"
        local textWidth = love.graphics.getFont():getWidth(text)
        local textHeight = love.graphics.getFont():getHeight()
        love.graphics.print(text, pixelX - textWidth / 2, pixelY - textHeight / 2)
    end
    -- Draw "S" for sniper pieces
    if self.type == "sniper" then
        love.graphics.setColor(1, 1, 1)
        love.graphics.setFont(love.graphics.newFont(16))
        local text = "S"
        local textWidth = love.graphics.getFont():getWidth(text)
        local textHeight = love.graphics.getFont():getHeight()
        love.graphics.print(text, pixelX - textWidth / 2, pixelY - textHeight / 2)
    end

    -- Draw "I" for infantry pieces
    if self.type == "infantry" then
        love.graphics.setColor(1, 1, 1)
        love.graphics.setFont(love.graphics.newFont(16))
        local text = "I"
        local textWidth = love.graphics.getFont():getWidth(text)
        local textHeight = love.graphics.getFont():getHeight()
        love.graphics.print(text, pixelX - textWidth / 2, pixelY - textHeight / 2)
    end
end

return Piece
