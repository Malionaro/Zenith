-- What enemies near the client's camera are attacking, so the client doesn't have to guess:
-- biters and spitters that are in range of the target of their attack command (a unit's
-- `distraction_command`, or its own command), and worms with a `shooting_target`. The list goes
-- out a few times a second; the client lets an attack lapse when it stops being listed.
--
-- Nothing in the game is changed. What this keeps in `storage` (rate.lua's schedule, the budget's
-- learned cost) is written only in on_tick from what the game has, so it is safe in multiplayer.

local transport = require("scripts.transport")
local world = require("scripts.world")
local map = require("scripts.map")
local rate = require("scripts.rate")
local movers = require("scripts.movers")

local M = {}

local INTERVAL = 10
local MAX_ATTACKERS = 1000
-- Slack on the attack range, in tiles: units start their attack from just outside it.
local SLACK = 0.75

-- Attack ranges by unit prototype, derived from prototypes only (the same on every peer).
local ranges = {}

local function range_of(e)
  local r = ranges[e.name]
  if r == nil then
    r = 1
    local ok, params = pcall(function() return e.prototype.attack_parameters end)
    if ok and params and params.range then
      r = params.range
    end
    ranges[e.name] = r
  end
  return r
end

local function attack_target(e)
  local c = e.commandable
  if not c then
    return nil
  end
  local attack = defines.command.attack
  local cmd = c.distraction_command
  if not (cmd and cmd.type == attack) then
    cmd = c.command
    if not (cmd and cmd.type == attack) then
      return nil
    end
  end
  local t = cmd.target
  if t and t.valid then
    return t
  end
  return nil
end

-- Distance from a unit to the nearest edge of the target's box (its centre for small things).
local function gap(e, t)
  local p, q = e.position, t.position
  local box = t.bounding_box
  local dx = math.max(box.left_top.x - p.x, 0, p.x - box.right_bottom.x)
  local dy = math.max(box.left_top.y - p.y, 0, p.y - box.right_bottom.y)
  if box.left_top.x == box.right_bottom.x then
    dx, dy = p.x - q.x, p.y - q.y
  end
  return math.sqrt(dx * dx + dy * dy)
end

-- one_search (perf.lua): the units come from the movers' search (movers.found), and worms, which don't
-- move, from a search of their own every WORM_EVERY ticks (or when the surface, the radius or the focus by
-- WORM_MOVE tiles changed), kept module-local (worm_lists, by client state) with its count in storage
-- (s.en_worms), so the learnt cost (rate.read) is the same on every peer. A peer that loaded since
-- searches for its own list, uncharged.
local WORM_EVERY = 300
local WORM_MOVE = 32
local worm_lists = setmetatable({}, { __mode = "k" })

local function worms(surface, s, f, r)
  local w = s.en_worms
  local t = game.tick
  local box = { { f.x - r, f.y - r }, { f.x + r, f.y + r } }
  if not w or t - w.tick >= WORM_EVERY or w.si ~= surface.index or w.r ~= r
      or math.max(math.abs(w.x - f.x), math.abs(w.y - f.y)) >= WORM_MOVE then
    local list = surface.find_entities_filtered({ area = box, type = "turret" })
    s.en_worms = { tick = t, n = #list, si = surface.index, x = f.x, y = f.y, r = r }
    worm_lists[s] = { tick = t, list = list }
    return list, #list
  end
  local kept = worm_lists[s]
  if not (kept and kept.tick == w.tick) then
    kept = { tick = w.tick, list = surface.find_entities_filtered({ area = box, type = "turret" }) }
    worm_lists[s] = kept
  end
  local live = {}
  for _, e in pairs(kept.list) do
    if e.valid then
      live[#live + 1] = e
    end
  end
  return live, w.n
end

local function collect(surface, f, r)
  local flat, n = {}, 0
  local all, read
  local units, nu = movers.found("en", surface)
  if nu then
    local s = storage.f3d
    if not units then
      units = surface.find_entities_filtered({ area = { { f.x - r, f.y - r }, { f.x + r, f.y + r } }, type = "unit" })
    end
    local w, nw = worms(surface, s, f, r)
    all = units
    for _, e in ipairs(w) do
      all[#all + 1] = e
    end
    read = nu + nw
  else
    all = surface.find_entities_filtered({
      area = { { f.x - r, f.y - r }, { f.x + r, f.y + r } },
      type = { "unit", "turret" },
    })
    read = #all
  end
  -- What was read is counted before the remote view's filter: the count goes into storage (the
  -- learnt cost, rate.read), and the filter's radar coverage is a cache that can differ between peers.
  local found = map.view_only(all)
  for _, e in pairs(found) do
    local unit = e.unit_number
    local t
    if e.type == "turret" then
      t = e.shooting_target
    else
      t = attack_target(e)
      if t and gap(e, t) > range_of(e) + SLACK then
        t = nil
      end
    end
    if unit and t and t.valid then
      local p = t.position
      flat[#flat + 1] = unit
      flat[#flat + 1] = world.fixed(p.x)
      flat[#flat + 1] = world.fixed(p.y)
      n = n + 1
      if n >= MAX_ATTACKERS then
        break
      end
    end
  end
  return flat, read
end

function M.tick()
  if not rate.due("en", INTERVAL) then
    return
  end
  local f = storage.f3d.focus
  if f.r <= 0 then
    rate.read("en", 0)
    return
  end
  local flat, read = collect(world.surface(), f, f.r)
  rate.read("en", read)
  if #flat > 0 then
    transport.send_now({ t = "en", l = flat })
  end
end

return M
