local M = {}

M.stats = {
    name = "Sniper",
    hp = 4,
    attackDice = 1,
    defenseDice = 1,
    moveRange = 2,
    attackRange = 3,
    viewRange = 4,
    damage = 2,
    maxAmmo = 2,
    maxDie = 3,
}

M.methods = {
    -- type-specific methods can be added here later
}

function M.methods:drawIcon(pixelX, pixelY, hexSideLength)
    love.graphics.setColor(1,1,1)
    love.graphics.setFont(love.graphics.newFont(16))
    local text = "S"
    local w = love.graphics.getFont():getWidth(text)
    local h = love.graphics.getFont():getHeight()
    love.graphics.print(text, pixelX - w/2, pixelY - h/2)
end

return M
