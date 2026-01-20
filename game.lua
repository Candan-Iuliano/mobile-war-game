-- Core game logic and state management

local Game = {}
Game.__index = Game


local Camera = require("camera")
local Piece = require("piece")
local Base = require("base")
local Resource = require("resource")
local ActionMenu = require("action_menu")
local FogOfWar = require("fog_of_war")

function Game.new()
    local self = setmetatable({}, Game)
    
    -- Game state
    self.state = "placing"  -- "placing", "playing", "gameOver"
    self.currentTurn = 1    -- Team 1 or 2
    self.turnCount = 0
    
    -- Placement phase
    self.piecesPerTeam = 4  -- Number of pieces per team (3 pawns + 1 engineer)
    self.piecesToPlace = self.piecesPerTeam * 2  -- Total pieces (4 for each team)
    self.piecesPlaced = 0
    self.basesPerTeam = 3  -- HQ, Ammo Depot, Supply Depot
    self.basesToPlace = self.basesPerTeam * 2  -- Total bases (3 for each team)
    self.basesPlaced = 0
    self.placementTeam = 1  -- Which team is currently placing (starts with team 1)
    self.placementPhase = "pieces"  -- "pieces" or "bases"
    
    -- Map setup
    self.hexSideLength = 32
    self.mapWidth = 20
    self.mapHeight = 20
    self.map = HexMap.new(self.mapWidth, self.mapHeight, self.hexSideLength)
    self.map:initializeGrid()
    self:generateMapTerrain()
    
    -- Starting areas for teams (top and bottom rows, 5 rows deep)
    self.startingAreaDepth = 5
    self.teamStartingAreas = {
        [1] = {rowStart = 1, rowEnd = 5},   -- Team 1: top 5 rows
        [2] = {rowStart = self.mapHeight - 4, rowEnd = self.mapHeight}  -- Team 2: bottom 5 rows
    }
    
    -- Camera
    self.camera = Camera.new(self.mapWidth * 20, self.mapHeight * 20, 1)
    
    -- Pieces (units)
    self.pieces = {}
    self:initializePieces()
    
    -- Bases (structures)
    self.bases = {}
    self:initializeBases()
    
    -- Resources
    self.resources = {}
    self:generateResources()
    
    -- Resource currency (for building units/bases)
    self.teamResources = {[1] = 0, [2] = 0}  -- Resources owned by each team
    
    -- Fog of War system
    self.fogOfWar = FogOfWar.new(self.map, 2)
    
    -- Initialize starting areas as explored and visible for each team
    for team = 1, 2 do
        local area = self.teamStartingAreas[team]
        if area then
            for row = area.rowStart, area.rowEnd do
                for col = 1, self.mapWidth do
                    self.fogOfWar:setTileVisible(team, col, row, true)
                end
            end
        end
    end
    
    -- Input handling
    self.selectedPiece = nil
    self.validMoves = {}
    self.validAttacks = {}
    self.isDragging = false
    self.dragStartX = 0
    self.dragStartY = 0
    
    -- Action menu UI (reusable for bases, pieces, resources, etc.)
    self.actionMenu = nil  -- ActionMenu instance
    self.actionMenuContext = nil  -- Context object (base, piece, etc.) that opened the menu
    
    return self
end

function Game:generateMapTerrain()
    -- Use balanced terrain generator for competitive play
    self.map:generateTerrain("balanced")
end

function Game:initializePieces()
    -- Create 3 pawns for team 1 to be placed (not positioned yet)
    for i = 1, 3 do
        self:addPiece("pawn", 1, nil, nil)  -- col and row will be set during placement
    end
    -- Create 1 engineer for team 1
    self:addPiece("engineer", 1, nil, nil)
    
    -- Create 3 pawns for team 2 to be placed (not positioned yet)
    for i = 1, 3 do
        self:addPiece("pawn", 2, nil, nil)  -- col and row will be set during placement
    end
    -- Create 1 engineer for team 2
    self:addPiece("engineer", 2, nil, nil)
end

function Game:initializeBases()
    -- Create bases for team 1: HQ, Ammo Depot, Supply Depot
    self:addBase("hq", 1, nil, nil)
    self:addBase("ammoDepot", 1, nil, nil)
    self:addBase("supplyDepot", 1, nil, nil)
    
    -- Create bases for team 2: HQ, Ammo Depot, Supply Depot
    self:addBase("hq", 2, nil, nil)
    self:addBase("ammoDepot", 2, nil, nil)
    self:addBase("supplyDepot", 2, nil, nil)
end

function Game:addBase(baseType, team, col, row)
    local base = Base.new(baseType, team, self.map, col, row)
    table.insert(self.bases, base)
end

function Game:generateResources()
    -- Generate a few resource tiles scattered across the map
    local numResources = 5  -- Number of resources to place
    
    for i = 1, numResources do
        local attempts = 0
        local placed = false
        
        while not placed and attempts < 100 do
            attempts = attempts + 1
            local col = math.random(5, self.mapWidth - 5)  -- Avoid edges
            local row = math.random(5, self.mapHeight - 5)
            
            local tile = self.map:getTile(col, row)
            if tile and tile.isLand then
                -- Check if tile is already occupied
                if not self:getPieceAt(col, row) and not self:getBaseAt(col, row) and not self:getResourceAt(col, row) then
                    local resource = Resource.new("generic", self.map, col, row)
                    table.insert(self.resources, resource)
                    placed = true
                end
            end
        end
    end
end

function Game:getResourceAt(col, row)
    for _, resource in ipairs(self.resources) do
        if resource.col == col and resource.row == row then
            return resource
        end
    end
    return nil
end

function Game:addPiece(pieceType, team, col, row)
    local piece = Piece.new(pieceType, team, self.map, col, row)
    table.insert(self.pieces, piece)
end

function Game:update(dt)
    -- Update game logic here
    if self.state == "playing" then
        -- Update pieces, animations, etc.
        
        -- Update fog of war visibility for all teams
        for team = 1, 2 do
            self.fogOfWar:updateVisibility(team, self.pieces, self.bases, self.teamStartingCorners)
        end
    elseif self.state == "placing" then
        -- Update fog of war for the team that's placing
        self.fogOfWar:updateVisibility(self.placementTeam, self.pieces, self.bases, self.teamStartingCorners)
    end
end

function Game:draw()
    love.graphics.push()
    love.graphics.applyTransform(self.camera:getTransform())
    
    -- Draw map
    self.map:draw(0, 0)
    
    -- Draw starting areas during placement phase
    if self.state == "placing" then
        self:drawStartingAreas()
    end
    
    -- Draw grid coordinates for debugging
    --self:drawGridCoordinates()
    
    -- Draw bases (only draw placed bases)
    for _, base in ipairs(self.bases) do
        if base.col > 0 and base.row > 0 then  -- Only draw if placed
            local pixelX, pixelY = self.map:gridToPixels(base.col, base.row)
            base:draw(pixelX, pixelY, self.hexSideLength)
            
            -- Draw influence radius (optional visual indicator)
            self:drawBaseRadius(base, pixelX, pixelY)
        end
    end
    
    -- Draw resources
    for _, resource in ipairs(self.resources) do
        local pixelX, pixelY = self.map:gridToPixels(resource.col, resource.row)
        resource:draw(pixelX, pixelY, self.hexSideLength)
    end
    
    -- Draw action menu (if base is selected)
    if self.actionMenu then
        self:drawActionMenu()
    end
    
    -- Draw pieces (only draw placed pieces)
    for _, piece in ipairs(self.pieces) do
        if piece.col > 0 and piece.row > 0 then  -- Only draw if placed
            local pixelX, pixelY = self.map:gridToPixels(piece.col, piece.row)
            piece:draw(pixelX, pixelY, self.hexSideLength)
        end
    end
    
    -- Draw valid moves if a piece is selected
    if self.selectedPiece then
        self:drawValidMoves()
    end
    
    -- Draw valid placement tiles during placement phase
    if self.state == "placing" then
        self:drawValidPlacementTiles()
    end
    
    -- Debug: Draw line of sight visualization for selected piece
    if self.selectedPiece and self.selectedPiece.col > 0 and self.selectedPiece.row > 0 then
        local sourceHex = self.map:getTile(self.selectedPiece.col, self.selectedPiece.row)
        if sourceHex then
            local visionRange = self.selectedPiece:getMovementRange() or 3
            self.map:drawLineOfSightDebug(sourceHex, visionRange, 0, 0)
        end
    end
    
    -- Draw fog of war for current player's team (after all game elements)
    if self.state == "playing" then
        self.fogOfWar:draw(self.currentTurn, self.camera, 0, 0)
    elseif self.state == "placing" then
        -- During placement, show fog for the team that's placing
        self.fogOfWar:draw(self.placementTeam, self.camera, 0, 0)
    end
    
    love.graphics.pop()
    
    -- Draw UI (always on screen)
    self:drawUI()
end



function Game:drawValidMoves()
    -- Draw valid movement tiles
    love.graphics.setColor(0, 1, 0, 0.3)
    for _, move in ipairs(self.validMoves) do
        local tile = self.map:getTile(move.col, move.row)
        if tile then
            local points = tile.points
            love.graphics.polygon("fill", points)
        end
    end
    
    -- Draw valid attack tiles
    love.graphics.setColor(1, 0, 0, 0.3)
    for _, attack in ipairs(self.validAttacks) do
        local tile = self.map:getTile(attack.col, attack.row)
        if tile then
            local points = tile.points
            love.graphics.polygon("fill", points)
        end
    end
end

function Game:drawValidPlacementTiles()
    -- Highlight all land tiles that are not occupied
    love.graphics.setColor(0, 1, 0, 0.2)
    for col = 1, self.map.cols do
        for row = 1, self.map.rows do
            local tile = self.map:getTile(col, row)
            if tile and tile.isLand and not self:getPieceAt(col, row) and not self:getBaseAt(col, row) and not self:getResourceAt(col, row) then
                local points = tile.points
                love.graphics.polygon("fill", points)
            end
        end
    end
end

function Game:drawStartingAreas()
    -- Draw starting area indicators for both teams (top and bottom strips)
    for team, area in pairs(self.teamStartingAreas) do
        -- Determine color based on team and whether it's the current placement team
        local isCurrentTeam = (team == self.placementTeam)
        local alpha = isCurrentTeam and 0.3 or 0.15
        local r, g, b = team == 1 and 1 or 0, 0, team == 1 and 0 or 1  -- Red for team 1, Blue for team 2
        
        -- Draw fill for starting area
        love.graphics.setColor(r, g, b, alpha)
        for col = 1, self.mapWidth do
            for row = area.rowStart, area.rowEnd do
                local tile = self.map:getTile(col, row)
                if tile and tile.isLand and tile.points then
                    love.graphics.polygon("fill", tile.points)
                end
            end
        end
        
        -- Draw outline for current team's starting area
        if isCurrentTeam then
            love.graphics.setColor(r, g, b, 0.6)
            for col = 1, self.mapWidth do
                for row = area.rowStart, area.rowEnd do
                    local tile = self.map:getTile(col, row)
                    if tile and tile.isLand and tile.points then
                        love.graphics.polygon("line", tile.points)
                    end
                end
            end
        end
    end
end

function Game:drawBaseRadius(base, pixelX, pixelY)
    -- Draw hexagons within the base's influence radius, respecting terrain
    local radius = base:getRadius()
    
    -- Use getHexesWithinRange which respects terrain passability
    -- Pass base's team so enemy pieces don't block the visualization
    local visited = {}
    self:getHexesWithinRange(base.col, base.row, radius, visited, base.team)
    
    -- Draw each hex in range (only passable terrain)
    love.graphics.setColor(1, 0, 0, 0.15)  -- Red, transparent fill
    for _, hex in ipairs(visited) do
        local tile = self.map:getTile(hex.col, hex.row)
        if tile then
            local points = tile.points
            love.graphics.polygon("fill", points)
        end
    end
    
    -- Draw outline for hexes in range
    love.graphics.setColor(1, 0, 0, 0.4)  -- Red, more visible outline
    for _, hex in ipairs(visited) do
        local tile = self.map:getTile(hex.col, hex.row)
        if tile then
            local points = tile.points
            love.graphics.polygon("line", points)
        end
    end
end

function Game:drawUI()
    love.graphics.setColor(1, 1, 1)
    love.graphics.setFont(love.graphics.newFont(14))
    
    if self.state == "placing" then
        -- Placement phase UI
        local teamName = self.placementTeam == 1 and "Red" or "Blue"
        local teamPiecesPlaced = 0
        for _, piece in ipairs(self.pieces) do
            if piece.team == self.placementTeam and piece.col > 0 and piece.row > 0 then
                teamPiecesPlaced = teamPiecesPlaced + 1
            end
        end
        local remaining = self.piecesPerTeam - teamPiecesPlaced
        love.graphics.print("Placement Phase - Turn 0", 10, 10)
        love.graphics.print("Team " .. teamName .. " placing", 10, 30)
        love.graphics.print("Pieces remaining: " .. remaining, 10, 50)
        love.graphics.setFont(love.graphics.newFont(10))
        love.graphics.print("Click on land tiles to place your pawns", 10, 70)
    else
        -- Normal gameplay UI
        local teamColor = self.currentTurn == 1 and "Red" or "Blue"
        love.graphics.print("Team: " .. teamColor .. " | Turn: " .. self.turnCount, 10, 10)
        love.graphics.print("Resources: " .. (self.teamResources[self.currentTurn] or 0), 10, 30)
        
        -- Count bases for current team
        local hqCount = 0
        local ammoDepotCount = 0
        local supplyDepotCount = 0
        for _, base in ipairs(self.bases) do
            if base.team == self.currentTurn and base.col > 0 and base.row > 0 then
                if base.type == "hq" then
                    hqCount = hqCount + 1
                elseif base.type == "ammoDepot" then
                    ammoDepotCount = ammoDepotCount + 1
                elseif base.type == "supplyDepot" then
                    supplyDepotCount = supplyDepotCount + 1
                end
            end
        end
        local basesInfo = string.format("Bases: HQ: %d | Ammo: %d | Supply: %d", hqCount, ammoDepotCount, supplyDepotCount)
        love.graphics.setFont(love.graphics.newFont(12))
        love.graphics.print(basesInfo, 10, 50)
        
        -- Show building engineers for current team
        local yOffset = 70
        love.graphics.setFont(love.graphics.newFont(11))
        for _, piece in ipairs(self.pieces) do
            if piece.team == self.currentTurn and piece.isBuilding and piece.buildingTurnsRemaining then
                local buildingName = piece.buildingType == "resource_mine" and "Resource Mine" or
                                   piece.buildingType == "ammoDepot" and "Ammo Depot" or
                                   piece.buildingType == "supplyDepot" and "Supply Depot" or
                                   "Structure"
                local buildText = string.format("Engineer building: %s (%d turns)", buildingName, piece.buildingTurnsRemaining)
                love.graphics.print(buildText, 10, yOffset)
                yOffset = yOffset + 15
            end
        end
        
        love.graphics.setFont(love.graphics.newFont(14))
        
        -- Draw selected piece info
        if self.selectedPiece then
            local info = string.format("Selected: %s (HP: %d/%d)", 
                self.selectedPiece.stats.name, 
                self.selectedPiece.hp, 
                self.selectedPiece.maxHp)
            love.graphics.print(info, 10, yOffset)
            yOffset = yOffset + 20
            
            -- Show building status if building
            if self.selectedPiece.isBuilding then
                local buildingName = self.selectedPiece.buildingType == "resource_mine" and "Resource Mine" or
                                   self.selectedPiece.buildingType == "ammoDepot" and "Ammo Depot" or
                                   self.selectedPiece.buildingType == "supplyDepot" and "Supply Depot" or
                                   "Structure"
                local buildInfo = string.format("Building: %s (%d turns left)",
                    buildingName,
                    self.selectedPiece.buildingTurnsRemaining or 0)
                love.graphics.print(buildInfo, 10, yOffset)
                yOffset = yOffset + 20
                love.graphics.setFont(love.graphics.newFont(10))
                local controlsY = yOffset
                love.graphics.print("Click to select piece | Right-click to move | E: End Turn | R: Reset", 10, controlsY)
            else
                -- Show ammo and supply
                local ammoInfo = string.format("Ammo: %d/%d | Supply: %d/%d", 
                    self.selectedPiece.ammo,
                    self.selectedPiece.maxAmmo,
                    self.selectedPiece.supply,
                    self.selectedPiece.maxSupply)
                love.graphics.print(ammoInfo, 10, yOffset)
                yOffset = yOffset + 20
                
                -- Draw controls
                love.graphics.setFont(love.graphics.newFont(10))
                local controlsY = yOffset
                love.graphics.print("Click to select piece | Right-click to move | E: End Turn | R: Reset", 10, controlsY)
            end
        else
            -- Draw controls
            love.graphics.setFont(love.graphics.newFont(10))
            local controlsY = yOffset
            love.graphics.print("Click to select piece | Right-click to move | E: End Turn | R: Reset", 10, controlsY)
        end
    end
end

function Game:mousepressed(x, y, button)
    local worldX, worldY = self.camera:screenToWorld(x, y)
    local col, row = self.map:pixelsToGrid(worldX, worldY)
    
    if self.state == "placing" then
        -- Placement phase: place pieces or bases on click
        if button == 1 then  -- Left click
            if self.placementPhase == "pieces" then
                self:placePiece(col, row)
            else
                self:placeBase(col, row)
            end
        end
    else
        -- Normal gameplay
        if button == 1 then  -- Left click
            -- Check if clicking on action menu first
            if self.actionMenu and self:handleActionMenuClick(worldX, worldY) then
                return  -- Action menu handled the click
            end
            
            -- Check if clicking on a piece first (pieces have priority over bases)
            local piece = self:getPieceAt(col, row)
            local base = self:getBaseAt(col, row)
            
            -- If there's a piece, handle piece selection logic
            if piece and piece.team == self.currentTurn and piece.col > 0 and piece.row > 0 then
                -- If clicking on already selected piece with menu open, close menu and deselect
                if piece == self.selectedPiece and self.actionMenu then
                    self.actionMenu = nil
                    self.actionMenuContext = nil
                    self.actionMenuContextType = nil
                    self.selectedPiece.selected = false
                    self.selectedPiece = nil
                    self.validMoves = {}
                    self.validAttacks = {}
                    return
                end
                
                -- If clicking on already selected engineer (no menu), open build menu
                if piece == self.selectedPiece and piece.stats.canBuild then
                    self:openActionMenu(piece, "piece")
                    return
                end
                
                -- Otherwise, select this piece
                if self.actionMenu then
                    self.actionMenu = nil
                    self.actionMenuContext = nil
                    self.actionMenuContextType = nil
                end
                self:selectPiece(col, row)
                return
            end
            
            -- If no piece but there's a base, handle base selection
            if base and base.team == self.currentTurn and base.col > 0 and base.row > 0 then
                self:selectBase(base)
                return
            end
            
            -- Otherwise, try to select a piece (in case piece team check failed)
            if self.actionMenu then
                self.actionMenu = nil
                self.actionMenuContext = nil
                self.actionMenuContextType = nil
            end
            self:selectPiece(col, row)
        elseif button == 2 then  -- Right click
            if self.selectedPiece then
                self:movePiece(col, row)
            end
            -- Right click closes action menu
            if self.actionMenu then
                self.actionMenu = nil
                self.actionMenuContext = nil
                self.actionMenuContextType = nil
            end
        end
    end
end

function Game:selectPiece(col, row)
    -- Don't allow selection during placement phase
    if self.state == "placing" then
        return
    end
    
    -- Find piece at this location
    local piece = self:getPieceAt(col, row)
    
    -- If clicking on the already selected piece, deselect it
    if piece and piece == self.selectedPiece then
        self.selectedPiece.selected = false
        self.selectedPiece = nil
        self.validMoves = {}
        self.validAttacks = {}
        return
    end
    
    -- Deselect previous piece
    if self.selectedPiece then
        self.selectedPiece.selected = false
    end
    
    if piece and piece.team == self.currentTurn then

        piece.selected = true
        self.selectedPiece = piece
        self:calculateValidMoves()

    else
        self.selectedPiece = nil
        self.validMoves = {}
        self.validAttacks = {}
    end
end

function Game:getPieceAt(col, row)
    for _, piece in ipairs(self.pieces) do
        if piece.col == col and piece.row == row then
            return piece
        end
    end
    return nil
end

function Game:getBaseAt(col, row)
    for _, base in ipairs(self.bases) do
        if base.col == col and base.row == row then
            return base
        end
    end
    return nil
end

function Game:selectBase(base)
    -- Deselect piece if one is selected
    if self.selectedPiece then
        self.selectedPiece.selected = false
        self.selectedPiece = nil
        self.validMoves = {}
        self.validAttacks = {}
    end
    
    -- If clicking the same base and menu is already open, close menu
    if self.actionMenu and self.actionMenuContext == base then
        self.actionMenu = nil
        self.actionMenuContext = nil
        self.actionMenuContextType = nil
        return
    end
    
    -- Open menu for this base
    self:openActionMenu(base, "base")
end

-- Generic function to open action menu for any object
-- context: the object (base, piece, resource, etc.)
-- contextType: "base", "piece", "resource", etc.
function Game:openActionMenu(context, contextType)
    -- Generate action options based on context type and object
    local options = self:getActionOptions(context, contextType)
    
    if #options == 0 then
        -- No options available, don't show menu
        return
    end
    
    -- Get pixel position of the context object
    local pixelX, pixelY
    if contextType == "base" then
        pixelX, pixelY = self.map:gridToPixels(context.col, context.row)
    elseif contextType == "piece" then
        pixelX, pixelY = self.map:gridToPixels(context.col, context.row)
    elseif contextType == "resource" then
        pixelX, pixelY = self.map:gridToPixels(context.col, context.row)
    else
        return  -- Unknown context type
    end
    
    -- Create ActionMenu instance
    self.actionMenu = ActionMenu.new(pixelX, pixelY, options, self.hexSideLength)
    self.actionMenuContext = context
    self.actionMenuContextType = contextType
end

-- Get action options for a given context object
-- This is where you define what actions are available for each object type
function Game:getActionOptions(context, contextType)
    local options = {}
    
    if contextType == "base" then
        if context.type == "hq" then
            -- HQ can build infantry (pawns)
            table.insert(options, {
                id = "build_infantry",
                name = "Build Infantry",
                cost = 2,  -- Cost in resources
                icon = "pawn"  -- For future use
            })
            -- Sniper
            table.insert(options, {
                id = "build_sniper",
                name = "Build Sniper",
                cost = 4,
                icon = "sniper"
            })
            -- Tank
            table.insert(options, {
                id = "build_tank",
                name = "Build Tank",
                cost = 6,
                icon = "tank"
            })
            -- Engineer
            table.insert(options, {
                id = "build_engineer",
                name = "Build Engineer",
                cost = 3,
                icon = "engineer"
            })
        end
        -- Add deconstruct option to all bases
        table.insert(options, {
            id = "deconstruct",
            name = "Deconstruct",
            cost = 0,  -- Free
            icon = "X",
            isDeconstruct = true  -- Flag for red coloring
        })
        -- Add more base types here as needed
    elseif contextType == "piece" then
        -- Engineer can build structures
        if context.stats.canBuild and not context.isBuilding then
            -- Check if engineer is on a resource tile or if tile already has a base
            local onResourceTile = self:getResourceAt(context.col, context.row) ~= nil
            local hasBase = self:getBaseAt(context.col, context.row) ~= nil
            
            table.insert(options, {
                id = "build_hq",
                name = "Build HQ",
                cost = 10,
                buildTurns = 4,  -- Takes 4 turns to build
                icon = "hq",
                disabled = onResourceTile or hasBase  -- Can't build bases on resource tiles or occupied tiles
            })
            table.insert(options, {
                id = "build_ammo_depot",
                name = "Build Ammo Depot",
                cost = 5,
                buildTurns = 2,  -- Takes 2 turns to build
                icon = "ammo_depot",
                disabled = onResourceTile or hasBase  -- Can't build bases on resource tiles or occupied tiles
            })
            table.insert(options, {
                id = "build_supply_depot",
                name = "Build Supply Depot",
                cost = 5,
                buildTurns = 2,  -- Takes 2 turns to build
                icon = "supply_depot",
                disabled = onResourceTile or hasBase  -- Can't build bases on resource tiles or occupied tiles
            })
            table.insert(options, {
                id = "build_resource_mine",
                name = "Build Resource Mine",
                cost = 8,
                buildTurns = 3,  -- Takes 3 turns to build
                icon = "resource_mine",
                disabled = hasBase  -- Can't build mine if tile has a base
            })
        end
    elseif contextType == "resource" then
        -- Add resource actions here (e.g., harvest, upgrade, etc.)
    end
    
    return options
end

function Game:drawActionMenu()
    if not self.actionMenu then return end
    
    -- Create callback to check if option is affordable and enabled
    local canAffordCallback = function(option)
        -- Deconstruct is always shown as red (special case)
        if option.isDeconstruct then return "deconstruct" end
        
        -- Check if option is disabled
        if option.disabled then return false end
        
        if not option.cost then return true end
        
        local team
        if self.actionMenuContextType == "base" then
            team = self.actionMenuContext.team
        elseif self.actionMenuContextType == "piece" then
            team = self.actionMenuContext.team
        else
            team = self.currentTurn
        end
        
        return self.teamResources[team] >= option.cost
    end
    
    self.actionMenu:draw(canAffordCallback)
end

function Game:handleActionMenuClick(worldX, worldY)
    if not self.actionMenu then return false end
    
    local option, index = self.actionMenu:handleClick(worldX, worldY)
    if option then
        self:executeAction(option)
        return true
    end
    
    return false
end

function Game:executeAction(option)
    if not self.actionMenu or not self.actionMenuContext then return end
    
    local context = self.actionMenuContext
    local contextType = self.actionMenuContextType
    
    -- Check if option is disabled
    if option.disabled then
        return  -- Can't execute disabled actions
    end
    
    -- Get team from context
    local team = context.team or self.currentTurn
    
    -- Check if player can afford this action
    if option.cost and self.teamResources[team] < option.cost then
        return  -- Can't afford
    end
    
    -- Execute action based on option ID
    if option.id == "build_infantry" and contextType == "base" then
        -- Build a pawn near the base
        self:buildUnitNearBase(context, "pawn", team, option.cost)
    elseif option.id == "build_sniper" and contextType == "base" then
        -- Build a sniper near the base
        self:buildUnitNearBase(context, "sniper", team, option.cost)
    elseif option.id == "build_tank" and contextType == "base" then
        -- Build a tank near the base
        self:buildUnitNearBase(context, "tank", team, option.cost)
    elseif option.id == "build_engineer" and contextType == "base" then
        -- Build an engineer near the base
        self:buildUnitNearBase(context, "engineer", team, option.cost)
    elseif option.id == "build_hq" and contextType == "piece" then
        -- Engineer builds an HQ
        self:buildStructureNearPiece(context, "hq", team, option.cost, option.buildTurns)
    elseif option.id == "build_ammo_depot" and contextType == "piece" then
        -- Engineer builds an ammo depot
        self:buildStructureNearPiece(context, "ammoDepot", team, option.cost, option.buildTurns)
    elseif option.id == "build_supply_depot" and contextType == "piece" then
        -- Engineer builds a supply depot
        self:buildStructureNearPiece(context, "supplyDepot", team, option.cost, option.buildTurns)
    elseif option.id == "build_resource_mine" and contextType == "piece" then
        -- Engineer builds a resource mine
        self:buildResourceMineNearPiece(context, team, option.cost, option.buildTurns)
    elseif option.id == "deconstruct" and contextType == "base" then
        -- Deconstruct the base (remove it from the game)
        for i, base in ipairs(self.bases) do
            if base == context then
                table.remove(self.bases, i)
                break
            end
        end
    end
    -- Add more action handlers here as needed
    
    -- Close menu after action
    self.actionMenu = nil
    self.actionMenuContext = nil
    self.actionMenuContextType = nil
end

function Game:buildUnitNearBase(base, unitType, team, cost)
    -- Deduct cost
    self.teamResources[team] = self.teamResources[team] - cost
    
    -- Find an adjacent empty land tile to place the unit
    local baseHex = self.map:getTile(base.col, base.row)
    if not baseHex then return end
    
    local neighbors = self.map:getNeighbors(baseHex, 1)
    for _, neighbor in ipairs(neighbors) do
        local tile = self.map:getTile(neighbor.col, neighbor.row)
        if tile and tile.isLand then
            -- Check if tile is empty
            if not self:getPieceAt(neighbor.col, neighbor.row) and 
               not self:getBaseAt(neighbor.col, neighbor.row) and
               not self:getResourceAt(neighbor.col, neighbor.row) then
                -- Place unit here
                self:addPiece(unitType, team, neighbor.col, neighbor.row)
                return
            end
        end
    end
    
    -- If no adjacent tile found, try within 2 tiles
    local extendedNeighbors = self.map:getNeighbors(baseHex, 2)
    for _, neighbor in ipairs(extendedNeighbors) do
        local tile = self.map:getTile(neighbor.col, neighbor.row)
        if tile and tile.isLand then
            if not self:getPieceAt(neighbor.col, neighbor.row) and 
               not self:getBaseAt(neighbor.col, neighbor.row) and
               not self:getResourceAt(neighbor.col, neighbor.row) then
                self:addPiece(unitType, team, neighbor.col, neighbor.row)
                return
            end
        end
    end
end

function Game:buildStructureNearPiece(piece, structureType, team, cost, buildTurns)
    -- Deduct cost
    self.teamResources[team] = self.teamResources[team] - cost
    
    -- Check if engineer's current tile is valid (no existing base)
    local tile = self.map:getTile(piece.col, piece.row)
    if tile and tile.isLand and not self:getBaseAt(piece.col, piece.row) then
        -- Start building process
        piece.isBuilding = true
        piece.buildingType = structureType
        piece.buildingTurnsRemaining = buildTurns
        piece.buildingTeam = team
        piece.hasMoved = true  -- Can't move while building
        return
    end
    
    -- If tile already has a base, refund the cost
    self.teamResources[team] = self.teamResources[team] + cost
 end

function Game:buildResourceMineNearPiece(piece, team, cost, buildTurns)
    -- Check if engineer's current tile has an existing resource
    local existingResource = self:getResourceAt(piece.col, piece.row)
    if not existingResource then
        -- Can't build mine here - no resource tile
        return
    end
    
    -- Check if resource already has a mine (owner is set means it's been captured/mined)
    if existingResource.hasMine then
        -- Already has a mine
        return
    end
    
    -- Deduct cost
    self.teamResources[team] = self.teamResources[team] - cost
    
    -- Start building process
    piece.isBuilding = true
    piece.buildingType = "resource_mine"
    piece.buildingTurnsRemaining = buildTurns
    piece.buildingTeam = team
    piece.buildingResourceTarget = existingResource  -- Store reference to the resource
    piece.hasMoved = true  -- Can't move while building
end

function Game:calculateValidMoves()
    self.validMoves = {}
    self.validAttacks = {}
    
    if not self.selectedPiece then return end
    
    -- If piece has already moved this turn or is currently building, don't show any moves
    -- Make sure to handle pieces without building properties (old pieces)
    local isBuilding = self.selectedPiece.isBuilding or false
    if self.selectedPiece.hasMoved or isBuilding then
        return
    end
    
    local moveRange = self.selectedPiece:getMovementRange()
    local attackRange = self.selectedPiece:getMovementRange()  -- Attack range equals move range
    
    -- Get all neighbors within move range (enemy pieces block movement)
    local visited = {}
    self:getHexesWithinRange(self.selectedPiece.col, self.selectedPiece.row, moveRange, visited, self.selectedPiece.team)
    
    for _, hex in ipairs(visited) do
        if hex.col ~= self.selectedPiece.col or hex.row ~= self.selectedPiece.row then
            local tile = self.map:getTile(hex.col, hex.row)
            if tile and tile.isLand and not self:getPieceAt(hex.col, hex.row) then
                table.insert(self.validMoves, hex)
            end
        end
    end
    
    -- Get hexes in attack range (same as move range)
    -- Only show attacks if piece has ammo
    if self.selectedPiece:hasAmmo() then
        local attackHexes = {}
        self:getHexesWithinRange(self.selectedPiece.col, self.selectedPiece.row, attackRange, attackHexes, self.selectedPiece.team)
        
        for _, hex in ipairs(attackHexes) do
            if hex.col ~= self.selectedPiece.col or hex.row ~= self.selectedPiece.row then
                local piece = self:getPieceAt(hex.col, hex.row)
                if piece and piece.team ~= self.selectedPiece.team then
                    table.insert(self.validAttacks, hex)
                end
            end
        end
    end
end

function Game:getHexesWithinRange(col, row, range, visited, team)
    visited = visited or {}
    team = team or self.currentTurn  -- Default to current turn's team
    
    if range <= 0 then return end
    
    -- Get the hex tile for this position
    local startHex = self.map:getTile(col, row)
    if not startHex then return end
    
    -- Use BFS to explore hexes, but only through passable terrain
    local queue = {{hex = startHex, distance = 0}}
    local visitedSet = {}
    visitedSet[col .. "," .. row] = true
    
    while #queue > 0 do
        local current = table.remove(queue, 1)
        local currentHex = current.hex
        local currentDistance = current.distance
        
        -- Add to visited if it's not the starting hex and within range
        if currentDistance > 0 and currentDistance <= range then
            local key = currentHex.col .. "," .. currentHex.row
            if not visited[key] then
                visited[key] = currentHex
                table.insert(visited, currentHex)
            end
        end
        
        -- Stop if we've reached the maximum range
        if currentDistance >= range then
            goto continue
        end
        
        -- Get immediate neighbors (range 1)
        local neighbors = self.map:getNeighbors(currentHex, 1)
        
        for _, neighbor in ipairs(neighbors) do
            local neighborKey = neighbor.col .. "," .. neighbor.row
            
            -- Only explore if not visited and terrain is passable (land)
            if not visitedSet[neighborKey] then
                local neighborTile = self.map:getTile(neighbor.col, neighbor.row)
                if neighborTile and neighborTile.isLand then
                    -- Check if tile is occupied by enemy piece (blocks movement)
                    local pieceOnTile = self:getPieceAt(neighbor.col, neighbor.row)
                    local isEnemyOccupied = pieceOnTile and pieceOnTile.team ~= team
                    
                    if not isEnemyOccupied then
                        -- Terrain is passable and not blocked by enemy, add to queue
                        visitedSet[neighborKey] = true
                        table.insert(queue, {
                            hex = neighborTile,
                            distance = currentDistance + 1
                        })
                    end
                    -- If terrain is not passable (water) or blocked by enemy, don't explore past it
                end
            end
        end
        ::continue::
    end
end

function Game:isWithinRange(startCol, startRow, targetCol, targetRow, range)
    -- Use BFS to check if target is within range, respecting impassable terrain
    local visited = {}
    local queue = {{col = startCol, row = startRow, distance = 0}}
    visited[startCol .. "," .. startRow] = true
    
    while #queue > 0 do
        local current = table.remove(queue, 1)
        
        -- Check if we found the target
        if current.col == targetCol and current.row == targetRow then
            return current.distance <= range
        end
        
        -- Don't explore further if we've exceeded range
        if current.distance >= range then
            goto continue
        end
        
        -- Get neighbors
        local currentHex = self.map:getTile(current.col, current.row)
        if currentHex then
            local neighbors = self.map:getNeighbors(currentHex, 1)
            for _, neighbor in ipairs(neighbors) do
                local key = neighbor.col .. "," .. neighbor.row
                if not visited[key] then
                    -- Only explore through passable terrain (land)
                    local neighborTile = self.map:getTile(neighbor.col, neighbor.row)
                    if neighborTile and neighborTile.isLand then
                        visited[key] = true
                        table.insert(queue, {col = neighbor.col, row = neighbor.row, distance = current.distance + 1})
                    end
                    -- If terrain is not passable (water), don't explore past it
                end
            end
        end
        ::continue::
    end
    
    return false
end

function Game:resupplyPieceFromBases(piece)
    -- Check all friendly bases to see if piece is within range
    for _, base in ipairs(self.bases) do
        if base.team == piece.team and base.col > 0 and base.row > 0 then
            if self:isWithinRange(base.col, base.row, piece.col, piece.row, base:getRadius()) then
                -- Piece is within range, resupply based on base type
                if base:suppliesAmmo() then
                    piece.ammo = piece.maxAmmo
                end
                if base:suppliesSupply() then
                    piece.supply = piece.maxSupply
                end
            end
        end
    end
end

function Game:generateResourceIncome(team)
    local income = 0
    
    -- Count HQs owned by this team (each HQ generates 1 resource)
    for _, base in ipairs(self.bases) do
        if base.team == team and base.type == "hq" and base.col > 0 and base.row > 0 then
            income = income + 1
        end
    end
    
    -- Count resource tiles with mines owned by this team
    for _, resource in ipairs(self.resources) do
        if resource.owner == team and resource.hasMine then
            -- Mined resources produce 2
            income = income + 2
        end
    end
    
    -- Add income to team's resources
    self.teamResources[team] = self.teamResources[team] + income
end

function Game:movePiece(col, row)
    if not self.selectedPiece then return end
    
    -- Check if move is valid
    local isValidMove = false
    for _, move in ipairs(self.validMoves) do
        if move.col == col and move.row == row then
            isValidMove = true
            break
        end
    end
    
    -- Check if attack is valid
    local isValidAttack = false
    local targetPiece = nil
    for _, attack in ipairs(self.validAttacks) do
        if attack.col == col and attack.row == row then
            isValidAttack = true
            targetPiece = self:getPieceAt(col, row)
            break
        end
    end
    
    if isValidMove then
        self.selectedPiece:setPosition(col, row)
        
        self:calculateValidMoves()
    elseif isValidAttack and targetPiece then
        -- Check if piece has ammo
        if not self.selectedPiece:hasAmmo() then
            return  -- Can't attack without ammo
        end
        
        -- Use ammo and attack
        self.selectedPiece:useAmmo()
        local damage = self.selectedPiece:getDamage()
        local wasKilled = targetPiece:takeDamage(damage)
        
        if wasKilled then
            -- Remove dead piece
            for i, piece in ipairs(self.pieces) do
                if piece == targetPiece then
                    table.remove(self.pieces, i)
                    break
                end
            end
            -- Only move to the enemy tile if we killed them
            self.selectedPiece:setPosition(col, row)
        end
        -- If enemy survived, attacker stays in place (no movement)
        -- Mark piece as moved since it attacked
        self.selectedPiece.hasMoved = true
        self:calculateValidMoves()
    end
end

function Game:keypressed(key)
    if key == "e" then
        self:endTurn()
    elseif key == "r" then
        self:resetGame()
    elseif key == "w" then
        self.camera:pan(0, 20)  -- Move up
    elseif key == "s" then
        self.camera:pan(0, -20)  -- Move down
    elseif key == "a" then
        self.camera:pan(20, 0)  -- Move left
    elseif key == "d" then
        self.camera:pan(-20, 0)  -- Move right
    end
end

function Game:mousemoved(x, y, dx, dy)
    -- Handle camera panning with middle mouse or space
    if love.mouse.isDown(3) then  -- Middle mouse
        self.camera:pan(dx, dy)
    end
end

function Game:wheelmoved(x, y)
    if y > 0 then
        self.camera:zoomIn(0.1)
    else
        self.camera:zoomOut(0.1)
    end
end

function Game:endTurn()
    -- Can't end turn during placement phase
    if self.state == "placing" then
        return
    end
    
    -- Apply supply consumption and attrition only for the team that just ended their turn
    local teamThatEnded = self.currentTurn
    for _, piece in ipairs(self.pieces) do
        if piece.team == teamThatEnded then
            -- Process building progress
            if piece.isBuilding and piece.buildingTurnsRemaining then
                piece.buildingTurnsRemaining = piece.buildingTurnsRemaining - 1
                
                -- Check if building is complete (0 or less turns remaining)
                if piece.buildingTurnsRemaining <= 0 then
                    -- Place the completed structure
                    if piece.buildingType == "resource_mine" then
                        -- Mark the resource as having a mine and owned by the team
                        if piece.buildingResourceTarget then
                            piece.buildingResourceTarget.hasMine = true
                            piece.buildingResourceTarget:capture(piece.buildingTeam)
                        end
                    else
                        -- It's a base structure (HQ, Ammo Depot, Supply Depot)
                        self:addBase(piece.buildingType, piece.buildingTeam, piece.col, piece.row)
                    end
                    
                    -- Clear building state completely
                    piece.isBuilding = false
                    piece.buildingType = nil
                    piece.buildingTurnsRemaining = 0
                    piece.buildingTeam = nil
                    piece.buildingResourceTarget = nil
                    piece.hasMoved = false  -- Reset hasMoved so engineer can act on their next turn
                end
            end
            
            piece:consumeSupply()  -- Reduce supply by 1 turn first
            piece:applyAttrition()  -- Take damage if out of supply
            
            -- Then check if piece is within range of any friendly base for resupply
            -- This resupplies them to full for the next turn
            self:resupplyPieceFromBases(piece)
        end
        
        -- Remove dead pieces (from attrition or other damage) for all teams
        if piece.hp <= 0 then
            for i, p in ipairs(self.pieces) do
                if p == piece then
                    table.remove(self.pieces, i)
                    break
                end
            end
        end
    end
    
    -- Generate resources from captured resource tiles
    self:generateResourceIncome(teamThatEnded)
    
    self.selectedPiece = nil
    self.validMoves = {}
    self.validAttacks = {}
    
    -- Switch to next team's turn
    self.currentTurn = self.currentTurn == 1 and 2 or 1
    
    -- Only increment turn counter when it goes back to team 1 (after both teams have played)
    if self.currentTurn == 1 then
        self.turnCount = self.turnCount + 1
    end
    
    -- Reset move status for ALL pieces of the current team at the START of their turn
    -- This includes engineers who just completed building
    for _, piece in ipairs(self.pieces) do
        if piece.team == self.currentTurn then
            piece:resetMove()
        end
    end
end

function Game:isInStartingArea(col, row, team)
    -- Check if position is within the team's starting area (top or bottom 5 rows)
    local area = self.teamStartingAreas[team]
    if not area then return false end
    
    -- Check if row is within starting area depth
    return row >= area.rowStart and row <= area.rowEnd
end

function Game:placePiece(col, row)
    -- Check if tile is valid (must be land and not occupied)
    local tile = self.map:getTile(col, row)
    if not tile or not tile.isLand then
        return  -- Can't place on water or invalid tile
    end
    
    -- Check if position is within the team's starting area
    if not self:isInStartingArea(col, row, self.placementTeam) then
        return  -- Can't place outside starting area
    end
    
    -- Check if tile is already occupied
    if self:getPieceAt(col, row) then
        return  -- Tile already has a piece
    end
    
    -- Find the first unplaced piece for the current placement team
    for _, piece in ipairs(self.pieces) do
        if piece.team == self.placementTeam and piece.col == 0 and piece.row == 0 then
            -- Place this piece
            piece:setPosition(col, row)
            self.piecesPlaced = self.piecesPlaced + 1
            
            -- Check if current team has finished placing
            local teamPiecesPlaced = 0
            for _, p in ipairs(self.pieces) do
                if p.team == self.placementTeam and p.col > 0 and p.row > 0 then
                    teamPiecesPlaced = teamPiecesPlaced + 1
                end
            end
            
            if teamPiecesPlaced >= self.piecesPerTeam then
                -- Current team finished placing pieces, switch to bases or next team
                if self.placementTeam == 1 then
                    -- Team 1 finished pieces, switch to bases
                    self.placementPhase = "bases"
                else
                    -- Team 2 finished pieces, switch to bases
                    self.placementPhase = "bases"
                end
            end
            return
        end
    end
end

function Game:placeBase(col, row)
    -- Check if tile is valid (must be land and not occupied)
    local tile = self.map:getTile(col, row)
    if not tile or not tile.isLand then
        return  -- Can't place on water or invalid tile
    end
    
    -- Check if position is within the team's starting area
    if not self:isInStartingArea(col, row, self.placementTeam) then
        return  -- Can't place outside starting area
    end
    
    -- Check if tile is already occupied by piece or base
    if self:getPieceAt(col, row) or self:getBaseAt(col, row) then
        return  -- Tile already has something
    end
    
    -- Find the first unplaced base for the current placement team
    for _, base in ipairs(self.bases) do
        if base.team == self.placementTeam and base.col == 0 and base.row == 0 then
            -- Place this base
            base:setPosition(col, row)
            self.basesPlaced = self.basesPlaced + 1
            
            -- Check if current team has finished placing bases
            local teamBasesPlaced = 0
            for _, b in ipairs(self.bases) do
                if b.team == self.placementTeam and b.col > 0 and b.row > 0 then
                    teamBasesPlaced = teamBasesPlaced + 1
                end
            end
            
            if teamBasesPlaced >= self.basesPerTeam then
                -- Current team finished placing bases, switch to next team
                if self.placementTeam == 1 then
                    -- Team 1 finished, switch to Team 2 pieces
                    self.placementTeam = 2
                    self.placementPhase = "pieces"
                else
                    -- Both teams finished placing, start the game
                    self.state = "playing"
                    self.turnCount = 1
                    self.currentTurn = 1  -- Team 1 goes first
                    -- Reset all pieces so they can move in the first turn
                    for _, p in ipairs(self.pieces) do
                        p:resetMove()
                    end
                end
            end
            return
        end
    end
end





function Game:resetGame()
    self.pieces = {}
    self.bases = {}
    self.resources = {}
    self.teamResources = {[1] = 0, [2] = 0}
    self.currentTurn = 1
    self.turnCount = 0
    self.state = "placing"
    self.piecesPlaced = 0
    self.basesPlaced = 0
    self.placementTeam = 1
    self.placementPhase = "pieces"
    self.selectedPiece = nil
    self.actionMenu = nil
    self.actionMenuContext = nil
    self.actionMenuContextType = nil
    self:initializePieces()
    self:initializeBases()
    self:generateResources()
end

return Game
