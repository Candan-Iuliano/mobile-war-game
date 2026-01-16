-- Love2D Hex War Game - Main Entry Point
-- A chess-like strategy game on a hex grid

function love.load()
    -- Show console window on Windows
    if love.system.getOS() == "Windows" then
        io.stdout:setvbuf("no")
    end
    
    print("=== Hex War Game Started ===")
    print("Loading modules...")
    
    -- Set window properties
    love.window.setMode(1200, 800)
    love.window.setTitle("Hex War Game")
    
    -- Load required modules
    print("Loading map_generator...")
    HexMap = require("map_generator")
    print("Loading game...")
    Game = require("game")
    
    -- Initialize game
    print("Initializing game...")
    gameInstance = Game.new()
    print("Game ready!")
end

function love.update(dt)
    gameInstance:update(dt)
end

function love.draw()
    gameInstance:draw()
end

function love.mousepressed(x, y, button)
    gameInstance:mousepressed(x, y, button)
end

function love.keypressed(key)
    gameInstance:keypressed(key)
end

function love.mousemoved(x, y, dx, dy)
    gameInstance:mousemoved(x, y, dx, dy)
end

function love.wheelmoved(x, y)
    gameInstance:wheelmoved(x, y)
end
