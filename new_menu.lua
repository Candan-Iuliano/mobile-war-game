-- Reusable simple menu module for buttons
-- API:
-- local Menu = require('new_menu')
-- m = Menu.new(x, y, options, opts)
-- options = { {label='Infantry', onClick=function() ... end}, ... }
-- m:draw()
-- m:handleClick(screenX, screenY)

local Menu = {}
Menu.__index = Menu

function Menu.new(x, y, options, opts)
    opts = opts or {}
    local self = setmetatable({}, Menu)
    self.x = x or 0
    self.y = y or 0
    self.options = options or {}
    self.width = opts.width or 180
    self.itemHeight = opts.itemHeight or 24
    self.padding = opts.padding or 8
    self.title = opts.title or nil
    self.buttonWidth = opts.buttonWidth or 100
    self.buttonHeight = opts.buttonHeight or 24
    -- Check if button mode: if any option has onClick
    self.buttonMode = false
    for _, opt in ipairs(self.options) do
        if opt.onClick then
            self.buttonMode = true
            break
        end
    end
    return self
end

function Menu:draw(canAffordCallback)
    if self.buttonMode then
        self:drawButtons()
    else
        self:drawList(canAffordCallback)
    end
end

function Menu:drawButtons()
    local opts = self.options or {}
    local btnW = self.buttonWidth
    local btnH = self.buttonHeight
    local padding = self.padding
    local startX = self.x
    local startY = self.y

    for i, opt in ipairs(opts) do
        local bx = startX
        local by = startY + (i-1) * (btnH + padding)
        love.graphics.setColor(0.2, 0.2, 0.2, 0.9)
        love.graphics.rectangle("fill", bx, by, btnW, btnH, 4, 4)
        local displayLabel = opt.displayLabel or opt.label or "Button"
        if not opt.displayLabel and opt.cost and type(opt.cost) == 'number' and opt.cost > 0 then
            displayLabel = displayLabel .. " (cost " .. opt.cost .. ")"
        end
        local r, g, b, a = 1, 1, 1, 1
        if opt.disabled then
            r, g, b, a = 0.6, 0.6, 0.6, 1
        elseif opt.isDeconstruct then
            r, g, b, a = 1, 0.5, 0.5, 1
        end
        love.graphics.setColor(r, g, b, a)
        love.graphics.setFont(love.graphics.newFont(12))
        love.graphics.printf(displayLabel, bx, by + 4, btnW, "center")
    end
end

function Menu:drawList(canAffordCallback)
    local opts = self.options or {}
    local itemH = self.itemHeight
    local padding = self.padding
    local panelW = self.width
    local panelH = #opts * itemH + padding * 2 + (self.title and 20 or 0)
    local panelX = self.x
    local panelY = self.y

    love.graphics.setColor(0.12, 0.12, 0.14, 0.95)
    love.graphics.rectangle("fill", panelX, panelY, panelW, panelH, 8, 8)
    love.graphics.setColor(1,1,1,1)

    local textX = panelX + 8
    local textY = panelY + padding
    if self.title then
        love.graphics.setFont(love.graphics.newFont(12))
        love.graphics.print(self.title, textX, textY)
        textY = textY + 18
    end

    love.graphics.setFont(love.graphics.newFont(12))
    for i, opt in ipairs(opts) do
        local iy = textY + (i-1) * itemH
        local label = opt.label or opt.id or ("item " .. tostring(i))
        if opt.cost and type(opt.cost) == 'number' and opt.cost > 0 then
            label = string.format("%s (cost %d)", label, opt.cost)
        end
        local disabled = opt.disabled
        if canAffordCallback and not disabled then
            local afford = canAffordCallback(opt)
            if afford == false then disabled = true end
        end
        if disabled then
            love.graphics.setColor(0.6,0.6,0.6,1)
        else
            love.graphics.setColor(1,1,1,1)
        end
        love.graphics.print(label, textX, iy)
    end
end

function Menu:handleClick(mx, my)
    if self.buttonMode then
        return self:handleButtonClick(mx, my)
    else
        return self:handleListClick(mx, my)
    end
end

function Menu:handleButtonClick(mx, my)
    local opts = self.options or {}
    local btnW = self.buttonWidth
    local btnH = self.buttonHeight
    local padding = self.padding
    local startX = self.x
    local startY = self.y

    for i, opt in ipairs(opts) do
        local bx = startX
        local by = startY + (i-1) * (btnH + padding)
        if mx >= bx and mx <= bx + btnW and my >= by and my <= by + btnH then
            if opt.onClick then
                opt.onClick()
            end
            return true
        end
    end
    return false
end

function Menu:handleListClick(mx, my)
    local opts = self.options or {}
    local itemH = self.itemHeight
    local padding = self.padding
    local panelW = self.width
    local panelH = #opts * itemH + padding * 2 + (self.title and 20 or 0)
    local panelX = self.x
    local panelY = self.y
    if mx < panelX or mx > panelX + panelW or my < panelY or my > panelY + panelH then
        return nil
    end
    local textY = panelY + padding + (self.title and 20 or 0)
    local relY = my - textY
    local idx = math.floor(relY / itemH) + 1
    if idx >= 1 and idx <= #opts then
        return opts[idx], idx
    end
    return nil
end

return Menu
