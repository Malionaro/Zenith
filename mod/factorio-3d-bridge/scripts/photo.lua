-- Photo mode: the client is taking a screenshot (`photo` {on}, docs/PROTOCOL.md) and waits for every
-- chunk its camera sees, thousands of them for a view zoomed far out, while its picture is held. For
-- the duration the chunk snapshots get more of the tick (world.lua: more chunks read a tick, most of
-- the work budget, a longer outbox) and the outbox sends more a tick (transport.lua), since the client
-- shows a loading screen meanwhile. The work budget itself stays the client's to set (`budget`): its
-- UPS governor raises it while the game keeps 60 UPS and cuts it when it doesn't, so the game stays
-- near 60 UPS.
--
-- It lapses by itself LAPSE_TICKS after the client last said it (the client repeats it every few
-- seconds while it waits), ends with `photo` {on = 0}, and with the client (a new hello, a timeout).
-- Deterministic: the tick it lapses at lives in storage.f3d (the client's state), set from a client
-- command like `rate`, and everything else is worked out from it and game.tick.

local M = {}

M.LAPSE_TICKS = 900 -- 15 s of game time
M.STARTS = 8        -- chunks started a tick at most (f3d-chunks-per-tick otherwise)
M.SHARE = 0.85      -- of the work budget for chunk snapshots (0.7 otherwise): the rest for the others
M.BACKLOG = 256     -- messages waiting to be sent before no more chunks are read (64 otherwise)
M.BYTES = 4         -- times f3d-bytes-per-tick sent a tick: localhost UDP takes it easily

-- Catching up: after a join, a teleport, a surface change or a fast walk the client waits for a
-- whole view of chunks (441 at view distance 10), read one a tick (f3d-chunks-per-tick) under a
-- 32 KB a tick outbox: several seconds of a half-empty world. While at least FILL_ON chunks wait
-- to be read (world.lua's queue), until none is left, they get photo mode's limits: more chunks
-- started a tick, more of the work budget, a longer outbox and more bytes a tick. The work budget
-- itself stays the client's UPS governor's, so the game stays near 60 UPS as in photo mode; only
-- the other jobs (live state near the character) wait a little longer meanwhile.
-- Deterministic: the flag lives in storage.f3d and follows the queue, which follows the client's
-- commands and the game's events.
M.FILL_ON = 16

-- Whether the client in storage.f3d is taking a screenshot now.
function M.on()
  local s = storage.f3d
  local untl = s and s.photo_until
  if not untl then
    return false
  end
  if game.tick >= untl then
    s.photo_until = nil
    return false
  end
  return true
end

-- Whether the client in storage.f3d is catching up on its view (world.lua sets it).
function M.filling()
  local s = storage.f3d
  return s ~= nil and s.fill == true
end

-- Photo mode's limits apply: a screenshot loading, or catching up.
function M.boost()
  return M.on() or M.filling()
end

-- {on}: 1 a screenshot is loading (again), 0 it is over.
function M.set(cmd)
  local s = storage.f3d
  if tonumber(cmd.on) == 1 then
    s.photo_until = game.tick + M.LAPSE_TICKS
  else
    s.photo_until = nil
  end
end

function M.reset()
  local s = storage.f3d
  if s then
    s.photo_until = nil
    s.fill = nil
  end
end

return M
