-- Each minable entity's own mining_sound (J11): what Factorio plays at each swing while the
-- character's hand mines it (rocks their stone, the stone patch its own, Space Age's plants and ice
-- theirs). The runtime API has no reader for it, so the data stage (data-final-fixes.lua) lists them
-- in a `mod-data` prototype ("zenith-mining-sounds") and the runtime sends them to the client in
-- `eprops` (`ms`, ui_actions.lua). Entities without one play Factorio's default, which the client
-- knows: the wood sound for trees, the ore sound for everything else.
--
-- With them each entity's own repair_sound (K13, `rsd`): what plays while a repair pack mends it (stone
-- walls and furnaces their hammering); without one the client plays Factorio's default_manual_repair.
--
-- A sound is kept as the file of its first variation with "__mod__/" made "mod/" and a variation's
-- number taken off ("base/sound/axe-mining-stone"), how the client finds a sound's variations in the
-- player's install. Only prototype data: the same on every peer.

local M = {}

M.NAME = "zenith-mining-sounds"

-- The first file a Sound plays: {filename}, {variations = {...}}, or a list of variations as
-- sound_variations() makes them.
local function first_file(sound, depth)
  if type(sound) ~= "table" or depth > 4 then
    return nil
  end
  if type(sound.filename) == "string" then
    return sound.filename
  end
  if sound.variations then
    local f = first_file(sound.variations, depth + 1)
    if f then
      return f
    end
  end
  return first_file(sound[1], depth + 1)
end

-- "__base__/sound/axe-mining-stone-1.ogg" -> "base/sound/axe-mining-stone"; nil for anything else.
function M.prefix(file)
  local mod, path = string.match(file or "", "^__([%w_%-]+)__/(.+)$")
  if not mod then
    return nil
  end
  path = path:gsub("%.%w+$", "")
  path = path:gsub("%-%d+$", "")
  return mod .. "/" .. path
end

-- Data stage: the mod-data prototype, {ms = {entity name = sound}, rs = {entity name = sound}}.
function M.prototype(raw)
  local ms, rs = {}, {}
  for _, protos in pairs(raw) do
    if type(protos) == "table" then
      for name, p in pairs(protos) do
        if type(p) == "table" and p.minable and p.mining_sound then
          local sound = M.prefix(first_file(p.mining_sound, 0))
          if sound then
            ms[name] = sound
          end
        end
        if type(p) == "table" and p.repair_sound then
          local sound = M.prefix(first_file(p.repair_sound, 0))
          if sound then
            rs[name] = sound
          end
        end
      end
    end
  end
  return { type = "mod-data", name = M.NAME, data_type = M.NAME, data = { ms = ms, rs = rs } }
end

-- Runtime: the entity's own mining sound, or nil (none, or no list: the client's defaults then).
-- Module-local caches made from prototype data alone.
local caches = {}

local function list(key)
  if caches[key] == nil then
    local ok, l = pcall(function() return prototypes.mod_data[M.NAME].get(key) end)
    caches[key] = (ok and type(l) == "table") and l or false
  end
  return caches[key]
end

function M.of(name)
  local l = list("ms")
  return l and l[name] or nil
end

-- Its own repair sound, or nil (Factorio's default then).
function M.repair_of(name)
  local l = list("rs")
  return l and l[name] or nil
end

return M
