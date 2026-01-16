-- Simple test to find errors
print("Starting test...")

print("Loading map_generator...")
local HexMap = require("map_generator")
print("HexMap loaded OK")

print("Loading camera...")
local Camera = require("camera")
print("Camera loaded OK")

print("Loading piece...")
local Piece = require("piece")
print("Piece loaded OK")

print("Loading game...")
local Game = require("game")
print("Game loaded OK")

print("Creating game instance...")
local game = Game.new()
print("Game instance created successfully!")
