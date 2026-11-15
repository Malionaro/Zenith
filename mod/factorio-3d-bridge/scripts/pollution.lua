-- Pollution round the client's focus (`pol`), so the client can draw what Factorio's pollution does
-- to the land: trees greying and losing their leaves, lakes turning green, a smog over the worst of
-- it. One number a chunk (`surface.get_pollution`), a square of chunks round the focus, every few
-- seconds: pollution spreads and changes slowly, and a read is a lookup per chunk, so this is cheap.
-- Nothing on a space platform or with pollution switched off in the map settings: the client clears
-- it then.
--
-- Read-only: what this keeps in `storage` (rate.lua's schedule, the budget's learned cost) is written
-- only in on_tick from what the game has, so it is safe in multiplayer.

local transport = require("scripts.transport")
local world = require("scripts.world")
local rate = require("scripts.rate")

local M = {}

local INTERVAL = 300
-- Chunks either side of the focus' chunk: the focus radius (192 tiles, 6 chunks) and a margin, so
-- the client's smog and trees fade out beyond what it draws rather than stopping at an edge.
local MOST_CHUNKS = 12
-- Factorio's default for map_settings.pollution.min_pollution_to_damage_trees.
local DEFAULT_DAMAGE = 60

local function settings()
  local ok, p = pcall(function() return game.map_settings.pollution end)
  if not ok or not p then
    return true, DEFAULT_DAMAGE
  end
  local okd, md = pcall(function() return p.min_pollution_to_damage_trees end)
  return p.enabled ~= false, okd and tonumber(md) or DEFAULT_DAMAGE
end

function M.tick()
  if not rate.due("pol", INTERVAL) then
    return
  end
  local f = storage.f3d.focus
  local surface = world.surface()
  local okp, platform = pcall(function() return surface.platform end)
  -- Only Nauvis' kind of pollution greys trees and greens lakes: Gleba's spores are another
  -- pollutant (2.0's LuaSurface.pollutant_type), and Vulcanus, Fulgora and Aquilo have none.
  local okt, kind = pcall(function()
    local k = surface.pollutant_type
    return k and k.name
  end)
  local other = okt and kind ~= nil and kind ~= "pollution"
  local enabled, damage = settings()
  if f.r <= 0 or (okp and platform) or other or not enabled then
    rate.read("pol", 0)
    transport.send_now({ t = "pol", si = surface.index, w = 0 })
    return
  end
  local n = math.min(MOST_CHUNKS, math.ceil(f.r / 32) + 2)
  local fx, fy = math.floor(f.x / 32), math.floor(f.y / 32)
  local cx, cy = fx - n, fy - n
  local w = 2 * n + 1
  local l, any = {}, false
  for j = 0, w - 1 do
    local y = (cy + j) * 32 + 16
    for i = 0, w - 1 do
      local v = math.floor(surface.get_pollution({ (cx + i) * 32 + 16, y }) + 0.5)
      if v > 0 then
        any = true
      end
      l[#l + 1] = v
    end
  end
  rate.read("pol", w * w)
  if not any then
    transport.send_now({ t = "pol", si = surface.index, w = 0 })
    return
  end
  transport.send_now({ t = "pol", si = surface.index, cx = cx, cy = cy, w = w, l = l, md = math.floor(damage + 0.5) })
end

return M
