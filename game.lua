-- Core game logic and state management

local Game = {}
Game.__index = Game


local Camera = require("camera")
local Piece = require("piece")

function Game.new()
    local self = setmetatable({}, Game)
    
    -- Game state
    self.state = "placing"  -- "placing", "playing", "gameOver"
    self.currentTurn = 1    -- Team 1 or 2
    self.turnCount = 0
    
    -- Placement phase
    self.piecesToPlace = 3  -- Number of pawns to place
    self.piecesPlaced = 0
    
    -- Map setup
    self.hexSideLength = 32
    self.mapWidth = 20
    self.mapHeight = 20
    self.map = HexMap.new(self.mapWidth, self.mapHeight, self.hexSideLength)
    self.map:initializeGrid()
    self:generateMapTerrain()
    
    -- Camera
    self.camera = Camera.new(self.mapWidth * 20, self.mapHeight * 20, 1)
    
    -- Pieces (units)
    self.pieces = {}
    self:initializePieces()
    
    -- Input handling
    self.selectedPiece = nil
    self.validMoves = {}
    self.validAttacks = {}
    self.isDragging = false
    self.dragStartX = 0
    self.dragStartY = 0
    
    return self
end

function Game:generateMapTerrain()
    -- Simple terrain generation: random islands
    for col = 1, self.map.cols do
        for row = 1, self.map.rows do
            local tile = self.map.grid[col][row]
            -- 70% chance of land
            if math.random() < 0.7 then
                tile.isLand = true
            else
                tile.isLand = false
            end
        end
    end
end

function Game:initializePieces()
    -- Create 3 pawns to be placed (not positioned yet)
    for i = 1, self.piecesToPlace do
        self:addPiece("pawn", 1, nil, nil)  -- col and row will be set during placement
    end
end

function Game:addPiece(pieceType, team, col, row)
    local piece = Piece.new(pieceType, team, self.map, col, row)
    table.insert(self.pieces, piece)
end

function Game:update(dt)
    -- Update game logic here
    if self.state == "playing" then
        -- Update pieces, animations, etc.
    end
end

function Game:draw()
    love.graphics.push()
    love.graphics.applyTransform(self.camera:getTransform())
    
    -- Draw map
    self.map:draw(0, 0)
    
    -- Draw grid coordinates for debugging
    self:drawGridCoordinates()
    
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
    
    love.graphics.pop()
    
    -- Draw UI (always on screen)
    self:drawUI()
end

function Game:drawGridCoordinates()
    love.graphics.setColor(0.5, 0.5, 0.5)
    love.graphics.setFont(love.graphics.newFont(8))
    
    for col = 1, math.min(self.map.cols, 15) do
        for row = 1, math.min(self.map.rows, 15) do
            local pixelX, pixelY = self.map:gridToPixels(col, row)
            love.graphics.print(col .. "," .. row, pixelX - 10, pixelY - 5)
        end
    end
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
            if tile and tile.isLand and not self:getPieceAt(col, row) then
                local points = tile.points
                love.graphics.polygon("fill", points)
            end
        end
    end
end

function Game:drawUI()
    love.graphics.setColor(1, 1, 1)
    love.graphics.setFont(love.graphics.newFont(14))
    
    if self.state == "placing" then
        -- Placement phase UI
        local remaining = self.piecesToPlace - self.piecesPlaced
        love.graphics.print("Placement Phase - Turn 0", 10, 10)
        love.graphics.print("Pieces remaining: " .. remaining, 10, 30)
        love.graphics.setFont(love.graphics.newFont(10))
        love.graphics.print("Click on land tiles to place your pawns", 10, 50)
    else
        -- Normal gameplay UI
        local teamColor = self.currentTurn == 1 and "Red" or "Blue"
        love.graphics.print("Team: " .. teamColor .. " | Turn: " .. self.turnCount, 10, 10)
        
        -- Draw selected piece info
        if self.selectedPiece then
            local info = string.format("Selected: %s (HP: %d/%d)", 
                self.selectedPiece.stats.name, 
                self.selectedPiece.hp, 
                self.selectedPiece.maxHp)
            love.graphics.print(info, 10, 30)
        end
        
        -- Draw controls
        love.graphics.setFont(love.graphics.newFont(10))
        love.graphics.print("Click to select piece | Right-click to move | E: End Turn | R: Reset", 10, 60)
    end
end

function Game:mousepressed(x, y, button)
    local worldX, worldY = self.camera:screenToWorld(x, y)
    local col, row = self.map:pixelsToGrid(worldX, worldY)
    
    if self.state == "placing" then
        -- Placement phase: place pieces on click
        if button == 1 then  -- Left click
            self:placePiece(col, row)
        end
    else
        -- Normal gameplay
        if button == 1 then  -- Left click
            self:selectPiece(col, row)
        elseif button == 2 then  -- Right click
            if self.selectedPiece then
                self:movePiece(col, row)
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
        -- Don't allow selection if piece has already moved this turn
        -- if piece.hasMoved then
        --     self.selectedPiece = nil
        --     self.validMoves = {}
        --     self.validAttacks = {}
        -- else
            piece.selected = true
            self.selectedPiece = piece
            self:calculateValidMoves()
        -- end
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

function Game:calculateValidMoves()
    self.validMoves = {}
    self.validAttacks = {}
    
    if not self.selectedPiece then return end
    
    -- If piece has already moved this turn, don't show any moves
    if self.selectedPiece.hasMoved then
        return
    end
    
    local moveRange = self.selectedPiece:getMovementRange()
    local attackRange = self.selectedPiece:getAttackRange()
    
    -- Get all neighbors within move range
    local visited = {}
    self:getHexesWithinRange(self.selectedPiece.col, self.selectedPiece.row, moveRange, visited)
    
    for _, hex in ipairs(visited) do
        if hex.col ~= self.selectedPiece.col or hex.row ~= self.selectedPiece.row then
            local tile = self.map:getTile(hex.col, hex.row)
            if tile and tile.isLand and not self:getPieceAt(hex.col, hex.row) then
                table.insert(self.validMoves, hex)
            end
        end
    end
    
    -- Get hexes in attack range
    local attackHexes = {}
    self:getHexesWithinRange(self.selectedPiece.col, self.selectedPiece.row, attackRange, attackHexes)
    
    for _, hex in ipairs(attackHexes) do
        if hex.col ~= self.selectedPiece.col or hex.row ~= self.selectedPiece.row then
            local piece = self:getPieceAt(hex.col, hex.row)
            if piece and piece.team ~= self.selectedPiece.team then
                table.insert(self.validAttacks, hex)
            end
        end
    end
end

function Game:getHexesWithinRange(col, row, range, visited)
    visited = visited or {}
    
    if range <= 0 then return end
    
    -- Get the hex tile for this position
    local startHex = self.map:getTile(col, row)
    if not startHex then return end
    
    -- Get immediate neighbors (range 1)
    local neighbors = self.map:getNeighbors(startHex, 1)
    
    for _, neighbor in ipairs(neighbors) do
        local key = neighbor.col .. "," .. neighbor.row
        if not visited[key] then
            visited[key] = neighbor
            table.insert(visited, neighbor)
            self:getHexesWithinRange(neighbor.col, neighbor.row, range - 1, visited)
        end
    end
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
        -- Simple attack: deal damage equal to piece's move range
        local damage = self.selectedPiece:getMovementRange()
        if targetPiece:takeDamage(damage) then
            -- Remove dead piece
            for i, piece in ipairs(self.pieces) do
                if piece == targetPiece then
                    table.remove(self.pieces, i)
                    break
                end
            end
        end
        self.selectedPiece:setPosition(col, row)
        self:calculateValidMoves()
    end
end

function Game:keypressed(key)
    if key == "e" then
        self:endTurn()
    elseif key == "r" then
        self:resetGame()
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
    
    self.selectedPiece = nil
    self.validMoves = {}
    self.validAttacks = {}
    
    -- Increment turn count (no team switching since we only have one team)
    self.turnCount = self.turnCount + 1
    
    -- Reset move status for ALL pieces at the START of the new turn
    for _, piece in ipairs(self.pieces) do
        piece:resetMove()
    end
end

function Game:placePiece(col, row)
    -- Check if placement is valid
    if self.piecesPlaced >= self.piecesToPlace then
        return  -- All pieces placed
    end
    
    -- Check if tile is valid (must be land and not occupied)
    local tile = self.map:getTile(col, row)
    if not tile or not tile.isLand then
        return  -- Can't place on water or invalid tile
    end
    
    -- Check if tile is already occupied
    if self:getPieceAt(col, row) then
        return  -- Tile already has a piece
    end
    
    -- Find the first unplaced piece
    for _, piece in ipairs(self.pieces) do
        if piece.col == 0 and piece.row == 0 then
            -- Place this piece
            piece:setPosition(col, row)
            self.piecesPlaced = self.piecesPlaced + 1
            
            -- Check if all pieces are placed
            if self.piecesPlaced >= self.piecesToPlace then
                -- Transition to normal gameplay
                self.state = "playing"
                self.turnCount = 1
                -- Reset all pieces so they can move in the first turn
                for _, p in ipairs(self.pieces) do
                    p:resetMove()
                end
            end
            return
        end
    end
end

function Game:resetGame()
    self.pieces = {}
    self.currentTurn = 1
    self.turnCount = 0
    self.state = "placing"
    self.piecesPlaced = 0
    self.selectedPiece = nil
    self:initializePieces()
end

return Game
