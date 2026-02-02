local M = {}

math.randomseed(os.time())

local function shuffle(t)
    for i = #t, 2, -1 do
        local j = math.random(i)
        t[i], t[j] = t[j], t[i]
    end
end

-- Create a single 4x4 template ensuring connectivity and at least `minOpenings` perimeter openings
local function generateTemplate(w, h, minOpenings)
    w = w or 4; h = h or 4
    minOpenings = minOpenings or 3

    local maxTries = 400
    local minLandFraction = 0.70 -- require at least this fraction of template to be connected land
    local minLandCount = math.max(2, math.ceil(w * h * minLandFraction))
    for attempt = 1, maxTries do
        local cells = {}
        for y = 1, h do
            cells[y] = {}
            for x = 1, w do
                -- bias toward land but allow water
                cells[y][x] = (math.random() < 0.65)
            end
        end

        -- Ensure connectivity: find largest connected land component
        local visited = {}
        local dirs = {{1,0},{-1,0},{0,1},{0,-1}}
        local function flood(sx, sy)
            local q = {{sx, sy}}
            local comp = {}
            visited[sy * 100 + sx] = true
            while #q > 0 do
                local p = table.remove(q,1)
                local cx, cy = p[1], p[2]
                table.insert(comp, {x = cx, y = cy})
                for _,d in ipairs(dirs) do
                    local nx, ny = cx + d[1], cy + d[2]
                    if nx >= 1 and nx <= w and ny >=1 and ny <= h then
                        if not visited[ny * 100 + nx] and cells[ny][nx] then
                            visited[ny * 100 + nx] = true
                            table.insert(q, {nx, ny})
                        end
                    end
                end
            end
            return comp
        end

        local bestComp = {}
        visited = {}
        for y = 1, h do
            for x = 1, w do
                if cells[y][x] and not visited[y * 100 + x] then
                    local comp = flood(x, y)
                    if #comp > #bestComp then bestComp = comp end
                end
            end
        end
        -- If no sufficiently large connected land component, retry
        if #bestComp == 0 or #bestComp < minLandCount then
            -- try next attempt
        else
        -- Keep only largest component as land (ensures connectivity)
        local newCells = {}
        for y = 1, h do newCells[y] = {} end
        for _,c in ipairs(bestComp) do newCells[c.y][c.x] = true end
        cells = newCells

        -- Count perimeter openings (land tiles on outer perimeter)
        local openings = 0
        for x = 1, w do if cells[1][x] then openings = openings + 1 end end
        for x = 1, w do if cells[h][x] then openings = openings + 1 end end
        for y = 1, h do if cells[y][1] then openings = openings + 1 end end
        for y = 1, h do if cells[y][w] then openings = openings + 1 end end

        if openings < minOpenings then
            -- open some random perimeter cells
            local perimeter = {}
            for x = 1, w do table.insert(perimeter, {x = x, y = 1}) end
            for x = 1, w do table.insert(perimeter, {x = x, y = h}) end
            for y = 1, h do table.insert(perimeter, {x = 1, y = y}) end
            for y = 1, h do table.insert(perimeter, {x = w, y = y}) end
            shuffle(perimeter)
            local i = 1
            while openings < minOpenings and i <= #perimeter do
                local p = perimeter[i]
                if not cells[p.y][p.x] then
                    cells[p.y][p.x] = true
                    openings = openings + 1
                end
                i = i + 1
            end
        end

        -- Place some resources randomly on land tiles
        local landList = {}
        for y = 1, h do for x = 1, w do if cells[y][x] then table.insert(landList, {x=x,y=y}) end end end
        local numResources = math.random(0, math.min(2, #landList))
        shuffle(landList)
        local resources = {}
        for i = 1, numResources do
            local rc = landList[i]
            table.insert(resources, {x = rc.x, y = rc.y, type = (math.random() < 0.15) and "oil" or "generic"})
        end

        return {w = w, h = h, cells = cells, resources = resources}
        end
    end 
    -- fallback: full land
    local cells = {}
    for y = 1, h do cells[y] = {}; for x = 1, w do cells[y][x] = true end end
    return {w=w,h=h,cells=cells,resources={}}
end

function M:generate(map)
    -- Template grid dims
    local tw, th = 4, 4
    local mapTw = math.floor(map.cols / tw)
    local mapTh = math.floor(map.rows / th)

    -- Generate a small library of templates
    local templates = {}
    for i = 1, 10 do
        templates[i] = generateTemplate(tw, th, 3)
    end

    -- Fill the map by randomly selecting templates and optionally rotating/flipping
    for ty = 0, mapTh - 1 do
        for tx = 0, mapTw - 1 do
            local tmpl = templates[math.random(#templates)]
            local flipH = (math.random() < 0.5)
            local flipV = (math.random() < 0.5)
            local rot = math.random(0,5) -- hex rotations not strictly applied; use simple rotations of grid cell

            for y = 1, th do
                for x = 1, tw do
                    local sx, sy = x, y
                    -- apply flips
                    if flipH then sx = tw - sx + 1 end
                    if flipV then sy = th - sy + 1 end
                    -- rotation (90-degree multiples applied on square template)
                    local rx, ry = sx, sy
                    for r = 1, rot do
                        rx, ry = ry, tw - rx + 1
                    end
                    local cellVal = tmpl.cells[ry][rx]
                    local globalCol = tx * tw + x
                    local globalRow = ty * th + y
                    local tile = map:getTile(globalCol, globalRow)
                    if tile then
                        tile.isLand = (cellVal == true)
                        tile.decorationType = nil
                        -- default terrain fields
                        tile.terrain = "plain"
                        tile.terrainCost = 1
                        tile.terrainViewBonus = 0
                        tile.isForest = false
                        tile.isHill = false
                        if tile.isLand then
                            if math.random() < 0.06 then
                                tile.terrain = "hill"
                                tile.terrainCost = 2
                                tile.terrainViewBonus = 1
                                tile.isHill = true
                            elseif math.random() < 0.08 then
                                tile.terrain = "forest"
                                tile.isForest = true
                            end
                        end
                    end
                end
            end

            -- Place template resources into global coordinates
            for _, r in ipairs(tmpl.resources) do
                local gx = tx * tw + r.x
                local gy = ty * th + r.y
                local tile = map:getTile(gx, gy)
                if tile and tile.isLand then
                    tile.resourceType = r.type
                end
            end
        end
    end

    -- If map size not a multiple of template, fill remaining edges as mixed land
    for col = 1, map.cols do
        for row = 1, map.rows do
            local t = map:getTile(col, row)
            if not t or t.isLand == nil then
                local tile = map:getTile(col, row)
                if tile then tile.isLand = (math.random() < 0.6) end
            end
        end
    end
end

return M
