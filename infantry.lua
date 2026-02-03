local M = {}

M.stats = {
    name = "Infantry",
    hp = 6,
    attackDice = 1,
    defenseDice = 1,
    moveRange = 3,
    attackRange = 1,
    viewRange = 3,
    damage = 1,
    maxAmmo = 3,
    maxDie = 4,
}

M.methods = {
    -- type-specific methods can be added here later
}

function M.methods:drawIcon(pixelX, pixelY, hexSideLength)
    love.graphics.setColor(1,1,1)
    love.graphics.setFont(love.graphics.newFont(16))
    local text = "I"
    local w = love.graphics.getFont():getWidth(text)
    local h = love.graphics.getFont():getHeight()
    love.graphics.print(text, pixelX - w/2, pixelY - h/2)
end

return M
