-- Base/Structure system for logistics

local Base = {}
Base.__index = Base

-- Base types with their properties
-- Load specialized base modules
local AIRBASE = {}
local ok_air, air_mod = pcall(require, "airbase")
if ok_air and air_mod and air_mod.stats then
    AIRBASE = air_mod.stats
end

local BASE_TYPES = {
    hq = { name = "HQ", radius = 3, suppliesAmmo = true, suppliesSupply = true, unitCapacity = 10 },
    ammoDepot = { name = "Ammo Depot", radius = 2, suppliesAmmo = true, suppliesSupply = false },
    supplyDepot = { name = "Supply Depot", radius = 2, suppliesAmmo = false, suppliesSupply = true },
    airbase = AIRBASE,
}

function Base.new(baseType, team, gameMap, col, row)
    local self = setmetatable({}, Base)
    
    if not BASE_TYPES[baseType] then
        error("Unknown base type: " .. baseType)
    end
    
    self.gameMap = gameMap
    self.type = baseType
    self.stats = BASE_TYPES[baseType]
    self.team = team or 1  -- Team 1 or 2
    self.col = col or 0  -- 0 means not placed yet
    self.row = row or 0
    self.hexTile = nil
    if col and row then
        self.hexTile = gameMap:getTile(col, row)
    end
    
    return self
end

function Base:setPosition(col, row)
    self.col = col
    self.row = row
    self.hexTile = self.gameMap:getTile(col, row)
end

function Base:getRadius()
    return self.stats.radius
end

function Base:suppliesAmmo()
    return self.stats.suppliesAmmo
end

function Base:suppliesSupply()
    return self.stats.suppliesSupply
end

function Base:getColor()
    if self.team == 1 then
        return 1, 0, 0  -- Red for team 1
    else
        return 0, 0, 1  -- Blue for team 2
    end
end

function Base:draw(pixelX, pixelY, hexSideLength)
    local size = hexSideLength * 0.9
    local r, g, b = self:getColor()

    -- Initialize draw cache per-base to avoid allocating points each frame
    if not self._drawCache or self._drawCache.size ~= hexSideLength then
        self._drawCache = { size = hexSideLength }
        local icoRadius = size * 0.36

        -- pentagon offsets (HQ)
        local pent = {}
        for i = 0, 4 do
            local angle = (i * 2 * math.pi / 5) - math.pi / 2
            table.insert(pent, icoRadius * math.cos(angle))
            table.insert(pent, icoRadius * math.sin(angle))
        end
        self._drawCache.pentagon = pent

        -- hexagon offsets (supplyDepot)
        local hexp = {}
        for i = 0, 5 do
            local angle = (i * 2 * math.pi / 6) - math.pi / 2
            table.insert(hexp, icoRadius * math.cos(angle))
            table.insert(hexp, icoRadius * math.sin(angle))
        end
        self._drawCache.hexagon = hexp

        -- triangle offsets (ammoDepot)
        local tri = { 0, -icoRadius, -size * 0.28, size * 0.28, size * 0.28, size * 0.28 }
        self._drawCache.triangle = tri

        -- wing offsets for airbase (left and right wings)
        local wingL = { -size * 0.58, 0, -size * 0.12, -size * 0.12, -size * 0.12, size * 0.12 }
        local wingR = { size * 0.58, 0, size * 0.12, -size * 0.12, size * 0.12, size * 0.12 }
        self._drawCache.wingL = wingL
        self._drawCache.wingR = wingR
    end

    -- Use translation to draw reusable offset polygons without reconstructing point tables
    love.graphics.push()
    love.graphics.translate(pixelX, pixelY)

    -- Draw a larger, semi-transparent base background so pieces on same tile remain visible
    love.graphics.setColor(r, g, b, 0.18)
    love.graphics.circle("fill", 0, 0, size * 0.6)
    love.graphics.setColor(r, g, b, 0.6)
    love.graphics.circle("line", 0, 0, size * 0.62)

    if self.type == "hq" then
        love.graphics.setColor(r, g, b)
        love.graphics.polygon("fill", self._drawCache.pentagon)
        love.graphics.setColor(0, 0, 0)
        love.graphics.polygon("line", self._drawCache.pentagon)

    elseif self.type == "supplyDepot" then
        love.graphics.setColor(r, g, b)
        love.graphics.polygon("fill", self._drawCache.hexagon)
        love.graphics.setColor(0, 0, 0)
        love.graphics.polygon("line", self._drawCache.hexagon)

    elseif self.type == "ammoDepot" then
        love.graphics.setColor(r, g, b)
        love.graphics.polygon("fill", self._drawCache.triangle)
        love.graphics.setColor(0, 0, 0)
        love.graphics.polygon("line", self._drawCache.triangle)

    else
        -- Default: Square (smaller icon on top of background)
        love.graphics.setColor(r, g, b)
        love.graphics.rectangle("fill", -size * 0.36, -size * 0.36, size * 0.72, size * 0.72)
        love.graphics.setColor(0, 0, 0)
        love.graphics.rectangle("line", -size * 0.36, -size * 0.36, size * 0.72, size * 0.72)
    end

    -- Airbase visual (use cached wing offsets)
    if self.type == "airbase" then
        love.graphics.setColor(r, g, b)
        love.graphics.circle("fill", 0, 0, size * 0.36)
        love.graphics.setColor(0, 0, 0)
        love.graphics.circle("line", 0, 0, size * 0.36)
        love.graphics.setColor(r, g, b)
        love.graphics.polygon("fill", self._drawCache.wingL)
        love.graphics.polygon("fill", self._drawCache.wingR)
        love.graphics.setColor(0,0,0)
        love.graphics.polygon("line", self._drawCache.wingL)
        love.graphics.polygon("line", self._drawCache.wingR)
    end

    love.graphics.pop()
end

return Base
