-- Reusable action menu system with arc of hexagons
-- Can be used for bases, pieces, resources, or any other game objects

local ActionMenu = {}
ActionMenu.__index = ActionMenu

function ActionMenu.new(centerX, centerY, options, hexSideLength)
    local self = setmetatable({}, ActionMenu)
    
    self.centerX = centerX
    self.centerY = centerY
    self.options = options or {}
    self.hexSideLength = hexSideLength or 32
    self.hexPositions = self:calculateArc(#options)
    
    return self
end

function ActionMenu:calculateArc(numOptions)
    if numOptions == 0 then return {} end
    
    local positions = {}
    local radius = self.hexSideLength * 1.5 -- Distance from center (increased for better spacing)
    local hexSize = self.hexSideLength * 0.4  -- Size of action menu hexagons
    local arcAngle = math.pi  -- π radians (180 degrees) centered above
    
    for i = 1, numOptions do
        local angle
        if numOptions == 1 then
            -- Single button: place at center (π/2)
            angle = math.pi / 2
        elseif numOptions == 2 then
            -- Two buttons: 45 degrees total range (22.5 degrees on each side of π/2)
            local halfRange = math.pi / 8  -- 22.5 degrees = π/8 radians
            local startAngle = math.pi / 2 - halfRange  -- Start at π/2 - 22.5°
            angle = startAngle + (2 * halfRange / (numOptions - 1)) * (i - 1)
        else
            -- Evenly space buttons from 0 to π, expanding outward from π/2
            -- This naturally centers around π/2
            angle = 0 + (arcAngle / (numOptions - 1) ) * (i - 1)
        end
        
        -- Calculate horizontal position
        local x = self.centerX + radius * math.cos(angle)
        
        -- Create "n" shape arch: center is highest, edges are lower
        -- Calculate how far from center (straight up = π/2)
        local centerAngle = math.pi / 2  -- Straight up
        local angleFromCenter = math.abs(angle - centerAngle)
        
        -- Arch shape: center (angleFromCenter = 0) should be highest
        -- Use cosine to create arch - at center cos(0) = 1, at edges cos(max) < 1
        -- When angleFromCenter = 0: cos(0) = 1, so archCurve = 0 (highest)
        -- When angleFromCenter = max: cos(max) < 1, so archCurve > 0 (lower)
        -- Scale arch height based on number of options - fewer options = gentler curve
        local baseArchHeight = self.hexSideLength 
        local archScale = math.max(0.1, (numOptions - 1) / 3)  -- Scale from 0.3 to 1.0 based on options
        local archHeight = baseArchHeight * archScale
        local archCurve = archHeight * (1 - math.cos(angleFromCenter)) 
        
        -- Base Y is straight up from center (highest point), then add arch curve (edges are lower)
        local baseY = self.centerY - self.hexSideLength * 1.5  -- Base height above center
        local y = baseY + archCurve  -- Add curve (positive = lower on screen, so edges go down)
        
        table.insert(positions, {
            x = x,
            y = y,
            size = hexSize,
            angle = angle
        })
    end
    
    return positions
end

function ActionMenu:generateHexagonPoints(centerX, centerY, size)
    local points = {}
    for i = 0, 5 do
        local angle = (i * 2 * math.pi / 6) - math.pi / 2
        local radius = size
        table.insert(points, centerX + radius * math.cos(angle))
        table.insert(points, centerY + radius * math.sin(angle))
    end
    return points
end

function ActionMenu:draw(canAffordCallback)
    -- canAffordCallback(option) should return true/false for each option, or "deconstruct" for deconstruct action
    
    for i, pos in ipairs(self.hexPositions) do
        local option = self.options[i]
        if option then
            -- Draw hexagon
            local points = self:generateHexagonPoints(pos.x, pos.y, pos.size)
            
            -- Color based on affordability or special type
            local canAfford = true
            if canAffordCallback then
                canAfford = canAffordCallback(option)
            end
            
            if canAfford == "deconstruct" then
                love.graphics.setColor(0.8, 0.2, 0.2, 0.9)  -- Red for deconstruct
            elseif canAfford then
                love.graphics.setColor(0.2, 0.8, 0.2, 0.9)  -- Green if affordable
            else
                love.graphics.setColor(0.5, 0.5, 0.5, 0.9)  -- Gray if can't afford
            end
            love.graphics.polygon("fill", points)
            
            -- Draw outline
            love.graphics.setColor(0, 0, 0, 1)
            love.graphics.polygon("line", points)
            
            -- Draw X symbol for deconstruct option
            if option.icon == "X" then
                love.graphics.setColor(1, 1, 1, 1)
                love.graphics.setLineWidth(3)
                local xSize = pos.size * 0.5
                love.graphics.line(pos.x - xSize, pos.y - xSize, pos.x + xSize, pos.y + xSize)
                love.graphics.line(pos.x + xSize, pos.y - xSize, pos.x - xSize, pos.y + xSize)
                love.graphics.setLineWidth(1)
            end
            
            -- Draw cost text (if option has a cost and it's not deconstruct)
            if option.cost and option.cost > 0 then
                love.graphics.setColor(1, 1, 1, 1)
                love.graphics.setFont(love.graphics.newFont(10))
                local costText = tostring(option.cost)
                local textWidth = love.graphics.getFont():getWidth(costText)
                love.graphics.print(costText, pos.x - textWidth / 2, pos.y - 5)
            end

            -- Draw shortcut letter (if provided)
            if option.shortcut then
                love.graphics.setColor(1, 1, 1, 1)
                love.graphics.setFont(love.graphics.newFont(14))
                local letter = tostring(option.shortcut)
                local lw = love.graphics.getFont():getWidth(letter)
                -- Position the shortcut just above the center of the hex
                love.graphics.print(letter, pos.x - lw / 2, pos.y - pos.size * 0.6)
            end
        end
    end
end

function ActionMenu:handleClick(worldX, worldY)
    -- Returns the clicked option, or nil if nothing was clicked
    
    for i, pos in ipairs(self.hexPositions) do
        local option = self.options[i]
        if option then
            -- Check if click is within hexagon
            local dx = worldX - pos.x
            local dy = worldY - pos.y
            local distance = math.sqrt(dx * dx + dy * dy)
            
            if distance <= pos.size then
                -- Clicked on this option
                return option, i
            end
        end
    end
    
    return nil, nil
end

function ActionMenu:updatePosition(centerX, centerY)
    -- Update the menu position (useful if the object moves)
    self.centerX = centerX
    self.centerY = centerY
    self.hexPositions = self:calculateArc(#self.options)
end

return ActionMenu
