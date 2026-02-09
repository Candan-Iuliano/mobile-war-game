-- Radial terrain generator
-- Works with circular hex grid (creates land and mountain tiles for variety)

local RadialGenerator = {}

function RadialGenerator:generate(map)
    math.randomseed(os.time())

    -- All tiles in the circular grid are land by default, with some mountains for variety
    for col = 1, map.cols do
        for row = 1, map.rows do
            local tile = map:getTile(col, row)
            if tile then
                -- 15% chance of mountain, 85% land
                if math.random() < 0.15 then
                    tile.isLand = false
                    tile.terrain = "mountain"
                    tile.terrainCost = 99  -- impassable
                    tile.terrainViewBonus = 0
                else
                    tile.isLand = true
                    tile.terrain = "plain"
                    tile.terrainCost = 1
                    tile.terrainViewBonus = 0

                    -- Add terrain variety on land tiles
                    if math.random() < 0.08 then
                        tile.terrain = "hill"
                        tile.terrainCost = 2
                        tile.terrainViewBonus = 1
                        tile.isHill = true
                    elseif math.random() < 0.10 then
                        tile.terrain = "forest"
                        tile.isForest = true
                    end
                end
            end
        end
    end
end

return RadialGenerator
