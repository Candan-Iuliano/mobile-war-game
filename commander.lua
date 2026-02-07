local M = {}

M.stats = {
    name = "Commander",
    hp = 8,
    attackDice = 1,
    defenseDice = 1,
    moveRange = 2,
    attackRange = 1,
    viewRange = 2,
    damage = 1,
    maxAmmo = 0,
    maxDie = 4,
}

M.methods = {}

function M.methods:drawIcon(pixelX, pixelY, hexSideLength)
    love.graphics.setColor(1,1,0)
    love.graphics.setFont(love.graphics.newFont(14))
    local text = "C"
    local w = love.graphics.getFont():getWidth(text)
    local h = love.graphics.getFont():getHeight()
    love.graphics.print(text, pixelX - w/2, pixelY - h/2)
end

return M
