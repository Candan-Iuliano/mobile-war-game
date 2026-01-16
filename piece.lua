-- Game piece/unit system for chess-like movement and combat

local Piece = {}
Piece.__index = Piece

-- Piece types with their properties
local PIECE_TYPES = {
    pawn = { name = "Pawn", moveRange = 1, attackRange = 1, hp = 1, speed = 2 },
    knight = { name = "Knight", moveRange = 2, attackRange = 2, hp = 3, speed = 3 },
    bishop = { name = "Bishop", moveRange = 5, attackRange = 5, hp = 3, speed = 2 },
    rook = { name = "Rook", moveRange = 5, attackRange = 5, hp = 5, speed = 1 },
    queen = { name = "Queen", moveRange = 5, attackRange = 5, hp = 5, speed = 2 },
    king = { name = "King", moveRange = 1, attackRange = 1, hp = 10, speed = 2 },
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
end

return Piece
