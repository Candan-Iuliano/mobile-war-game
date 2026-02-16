-- Replay system module for turn-based action replays
local Replay = {}
Replay.__index = Replay

function Replay.new()
    local self = setmetatable({}, Replay)
    self.turnReplays = { [1] = {}, [2] = {} }
    self.currentReplay = nil
    self.replayActive = false
    self.replaySkipRequested = false
    self.replayIndex = nil
    self._recordedActions = {}
    self.preTurnSnapshots = {} -- snapshots taken at start of each team's turn
    self.turnSnapshots = { [1] = nil, [2] = nil } -- snapshots paired with stored replays
    return self
end

function Replay:recordAction(action)
    table.insert(self._recordedActions, action)
end

function Replay:storeTurnReplay(forTeam, actingTeam)
    self.turnReplays[forTeam] = self._recordedActions or {}
    self._recordedActions = {}
    -- If we have a pre-turn snapshot for the acting team, attach it to this stored replay
    if actingTeam and self.preTurnSnapshots and self.preTurnSnapshots[actingTeam] then
        self.turnSnapshots[forTeam] = self.preTurnSnapshots[actingTeam]
        -- clear the preTurn snapshot for that team to avoid stale retention
        self.preTurnSnapshots[actingTeam] = nil
    else
        self.turnSnapshots[forTeam] = nil
    end
end

function Replay:beginReplay(forTeam)
    self.currentReplay = self.turnReplays[forTeam] or {}
    self.replayActive = (#self.currentReplay > 0)
    self.replayIndex = 1
    self.replaySkipRequested = false
    pcall(function()
        print("[DEBUG] beginReplay for team " .. tostring(forTeam) .. ", actions: " .. tostring(#self.currentReplay))
        for i, act in ipairs(self.currentReplay) do
            print("[DEBUG] beginReplay action " .. i .. ": " .. (act.action or "nil"))
        end
    end)
end

function Replay:stepReplay(applyActionFn)
    print("HEY")
    if not self.replayActive then return end
    if self.replaySkipRequested then
        while self.replayIndex and self.currentReplay and self.replayIndex <= #self.currentReplay do
            applyActionFn(self.currentReplay[self.replayIndex])
            self.replayIndex = self.replayIndex + 1
        end
        self:finishReplay()
    elseif self.currentReplay and self.replayIndex and self.replayIndex <= #self.currentReplay then
        applyActionFn(self.currentReplay[self.replayIndex])
        self.replayIndex = self.replayIndex + 1
        -- Don't call finishReplay here; let the game handle it after checking for pending attacks
    end
end

function Replay:finishReplay()
    self.replayActive = false
    self.currentReplay = nil
    self.replayIndex = nil
    self.replaySkipRequested = false
end

-- Utility: shallow copy for tables
function table.shallow_copy(t)
    local t2 = {}
    for k,v in pairs(t) do t2[k]=v end
    return t2
end

function Replay:saveBoardSnapshot(pieces)
    -- Backwards-compatible single snapshot holder
    self.boardSnapshot = {}
    for _, piece in ipairs(pieces) do
        if piece.col and piece.row and piece.col > 0 and piece.row > 0 then
            table.insert(self.boardSnapshot, {
                type = piece.type,
                team = piece.team,
                col = piece.col,
                row = piece.row,
                hp = piece.hp,
                veteran = piece.veteran,
                hiddenInForest = piece.hiddenInForest,
                revealedTo = piece.revealedTo and table.shallow_copy(piece.revealedTo) or nil
            })
        end
    end
end

function Replay:saveBoardSnapshotForTeam(team, pieces, mines)
    if not team then return end
    self.preTurnSnapshots = self.preTurnSnapshots or {}
    local snap = {}
    for _, piece in ipairs(pieces) do
        if piece.col and piece.row and piece.col > 0 and piece.row > 0 then
            table.insert(snap, {
                type = piece.type,
                team = piece.team,
                col = piece.col,
                row = piece.row,
                hp = piece.hp,
                veteran = piece.veteran,
                hiddenInForest = piece.hiddenInForest,
                revealedTo = piece.revealedTo and table.shallow_copy(piece.revealedTo) or nil
            })
        end
    end
    -- Also save mines for replay restoration
    snap.mines = {}
    if mines then
        for _, mine in ipairs(mines) do
            if mine.col and mine.row and mine.col > 0 and mine.row > 0 then
                table.insert(snap.mines, {
                    col = mine.col,
                    row = mine.row,
                    team = mine.team,
                    damage = mine.damage or 5,
                    revealedTo = mine.revealedTo and table.shallow_copy(mine.revealedTo) or nil
                })
            end
        end
    end
    self.preTurnSnapshots[team] = snap
end

function Replay:getBoardSnapshot(forTeam)
    -- If forTeam provided, return the snapshot attached to that team's stored replay (turnSnapshots)
    if forTeam and self.turnSnapshots then
        return self.turnSnapshots[forTeam]
    end
    -- Backwards-compatible fallback
    return self.boardSnapshot
end

return Replay
