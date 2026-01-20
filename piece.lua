-- Game piece/unit system for chess-like movement and combat

local Piece = {}
Piece.__index = Piece

-- Piece types with their properties
local PIECE_TYPES = {
    pawn = { name = "Pawn", moveRange = 3, attackRange = 1, hp = 10, damage = 5, speed = 2, maxAmmo = 3, maxSupply = 5 },
    knight = { name = "Knight", moveRange = 2, attackRange = 2, hp = 3, damage = 3, speed = 3, maxAmmo = 3, maxSupply = 5 },
    bishop = { name = "Bishop", moveRange = 5, attackRange = 5, hp = 3, damage = 3, speed = 2, maxAmmo = 3, maxSupply = 5 },
    rook = { name = "Rook", moveRange = 5, attackRange = 5, hp = 5, damage = 5, speed = 1, maxAmmo = 3, maxSupply = 5 },
    queen = { name = "Queen", moveRange = 5, attackRange = 5, hp = 5, damage = 5, speed = 2, maxAmmo = 3, maxSupply = 5 },
    king = { name = "King", moveRange = 1, attackRange = 1, hp = 10, damage = 5, speed = 2, maxAmmo = 3, maxSupply = 5 },
    
    -- New specialized units
    sniper = { name = "Sniper", moveRange = 2, attackRange = 7, hp = 4, damage = 8, speed = 1, maxAmmo = 2, maxSupply = 5 },
    tank = { name = "Tank", moveRange = 4, attackRange = 3, hp = 15, damage = 7, speed = 3, maxAmmo = 4, maxSupply = 5 },
    engineer = { name = "Engineer", moveRange = 3, attackRange = 0, hp = 8, damage = 0, speed = 2, maxAmmo = 0, maxSupply = 5, canBuild = true },
}

function Piece.new(pieceType, team, gameMap, col, row)
    local self = setmetatable({}, Piece)
    
    if not PIECE_TYPES[pieceType] then
        error("Unknown piece type: " .. pieceType)
    end
    self.gameMap = gameMap
    self.type = pieceType
    self.stats = PIECE_TYPES[pieceType]
    self.team = team or 1  -- Team 1 or 2
    self.col = col or 0  -- 0 means not placed yet
    self.row = row or 0
    self.hp = self.stats.hp
    self.maxHp = self.stats.hp
    self.selected = false
    self.canMove = true
    self.hasMoved = false  -- Track if piece has moved this turn
    
    -- Building system (for engineers)
    self.isBuilding = false  -- Is this piece currently building something?
    self.buildingType = nil  -- What type of structure is being built
    self.buildingTurnsRemaining = 0  -- How many more turns until building completes
    self.buildingTeam = nil  -- Team that owns the structure being built
    
    -- Ammo and supply system
    self.maxAmmo = self.stats.maxAmmo or 3
    self.ammo = self.maxAmmo  -- Current ammo remaining
    self.maxSupply = self.stats.maxSupply or 5
    self.supply = self.maxSupply  -- Current supply remaining (turns until attrition)
    self.attritionDamage = 2  -- Damage per turn when out of supply
    
    self.hexTile = nil
    if col and row then
        self.hexTile = gameMap:getTile(col, row)
    end
    
    return self
end

function Piece:getMovementRange()
    return self.stats.moveRange
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
end

function Piece:resetMove()
    self.hasMoved = false
end

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
end

return Piece
