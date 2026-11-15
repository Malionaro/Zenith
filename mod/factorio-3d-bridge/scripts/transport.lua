-- Moves JSON messages between the mod and the 3D client over localhost UDP.
--
-- Two kinds of outgoing messages:
--   * reliable: world data (chunks, entity adds/removes). Numbered with `r`, queued in
--     storage, and sent at a bounded byte rate. The client asks for a resync on a gap.
--   * immediate: frequent state that the next update replaces anyway (player, movers).

local profile = require("scripts.profile")
local photo = require("scripts.photo")

local M = {}

local warned = false

-- What this tick sent (datagrams, bytes), for the trace (`f3dsend` lines beside `f3dtrace`'s, end_tick):
-- measuring only, module-local.
local sent_n, sent_bytes = 0, 0

-- Datagram numbering, for a client whose hello says `dq`: every datagram it gets ends with a line
-- {"t":"dg","n":N,"k":tick,"b":bytes} (N counting from 1 since the mod loaded, `b` the bytes before
-- it), so the client can tell a datagram the OS dropped (Windows keeps 64 KB of unread datagrams
-- per socket: a tick's burst over that loses its tail) from one that was never sent. Module-local:
-- measuring only, nothing in storage depends on it. While the profiler traces (/f3d-profile trace)
-- each datagram is logged too: "f3ddg <tick> <n> <bytes> <type:count,...>", read beside the client's
-- --udp-trace by tools/udp_loss_check.py.
local dg_n = 0
local DG_BYTES = 64  -- room kept in a batch for the `dg` line
local MAX_DATAGRAM = 65507
-- This tick's message types per datagram being built (tracing only): port -> {type -> count}.
local batch_types = {}

local function numbering()
  local client = storage.f3d and storage.f3d.client
  return client and client.dq
end

local function type_of(data)
  return data:match('^{"t":"([%w_]+)"') or data:match('"t":"([%w_]+)"') or "?"
end

local function count_type(types, data)
  local t = type_of(data)
  types[t] = (types[t] or 0) + 1
end

local function types_text(types)
  local out = {}
  for t, n in pairs(types) do
    out[#out + 1] = t .. ":" .. n
  end
  table.sort(out)
  return table.concat(out, ",")
end

-- On a server only the server instance talks to the client. Single-player has no separate
-- server, so the local instance sends.
local function instance()
  if game.is_multiplayer() then
    return 0
  end
  return nil
end

local function encode(msg)
  msg.k = game.tick
  return helpers.table_to_json(msg)
end

-- Optional arguments are left out rather than passed as nil. `types` (tracing only): the datagram's
-- message types and counts, for its log line.
local function send_datagram(port, data, types)
  local client = storage.f3d and storage.f3d.client
  if client and client.dq and client.port == port and #data + DG_BYTES <= MAX_DATAGRAM then
    dg_n = dg_n + 1
    data = data .. '\n{"t":"dg","n":' .. dg_n .. ',"k":' .. game.tick .. ',"b":' .. #data .. "}"
    if profile.tracing() then
      log("f3ddg " .. game.tick .. " " .. dg_n .. " " .. #data .. " " .. (types and types_text(types) or ""))
    end
  end
  local who = instance()
  local ok, err
  if who then
    ok, err = pcall(helpers.send_udp, port, data, who)
  else
    ok, err = pcall(helpers.send_udp, port, data)
  end
  if not ok and not warned then
    warned = true
    log("[factorio-3d-bridge] send_udp failed: " .. tostring(err))
  end
  sent_n, sent_bytes = sent_n + 1, sent_bytes + #data
end

-- Sending a datagram costs the game about a millisecond whatever its size (helpers.send_udp in
-- 2.1.23 on a laptop: 0.6 to 2.7 ms for 100 bytes to 60 KB), and the bridge sent one per message:
-- on a big base belt items alone took 20 a tick, 50 ms. A client that says `b` in its hello gets
-- the messages joined by newlines into datagrams of up to BATCH_BYTES, sent when one fills and at
-- the end of each tick (end_tick). Only what is sent depends on this buffer, never storage.
local BATCH_BYTES = 60000
local batches = {}  -- port -> {parts, bytes}

local function send_batch(port)
  local b = batches[port]
  if b then
    batches[port] = nil
    local types = batch_types[port]
    batch_types[port] = nil
    send_datagram(port, table.concat(b[1], "\n"), types)
  end
end

local function send_raw(port, data)
  local client = storage.f3d and storage.f3d.client
  local tracing = profile.tracing()
  if not (client and client.b and client.port == port) or #data >= BATCH_BYTES then
    send_batch(port)  -- what was queued goes first
    local types
    if tracing then
      types = {}
      count_type(types, data)
    end
    send_datagram(port, data, types)
    return
  end
  local b = batches[port]
  -- (A `dq` client's datagram ends with its `dg` line: room is kept for it.)
  if b and b[2] + #data + 1 > BATCH_BYTES - (numbering() and DG_BYTES or 0) then
    send_batch(port)
    b = nil
  end
  if tracing then
    local types = batch_types[port]
    if not types then
      types = {}
      batch_types[port] = types
    end
    count_type(types, data)
  end
  if not b then
    b = { {}, 0 }
    batches[port] = b
  end
  b[1][#b[1] + 1] = data
  b[2] = b[2] + #data + 1
end

-- Sends what is waiting for every client; once a tick, after the modules ran.
function M.end_tick()
  for port in pairs(batches) do
    send_batch(port)
  end
  if profile.tracing() then
    -- The tick's datagrams and bytes: tools/trace_sends.py reads them beside f3dtrace's times.
    log("f3dsend " .. game.tick .. " " .. sent_n .. " " .. sent_bytes)
  end
  sent_n, sent_bytes = 0, 0
end

-- Reads pending packets; each one arrives later as on_udp_packet_received.
function M.poll()
  local who = instance()
  local ok, err
  if who then
    ok, err = pcall(helpers.recv_udp, who)
  else
    ok, err = pcall(helpers.recv_udp)
  end
  if not ok and not warned then
    warned = true
    log("[factorio-3d-bridge] UDP is unavailable (" .. tostring(err) .. "). Launch Factorio with --enable-lua-udp <port>.")
  end
end

-- A message written as JSON text by its module: `fields`, the fields after t and k, starting
-- with a comma (big lists cost far less as table.concat than through helpers.table_to_json).
function M.send_text(t, fields)
  local client = storage.f3d.client
  if client then
    send_raw(client.port, '{"t":"' .. t .. '","k":' .. game.tick .. fields .. "}")
  end
end

-- The same, stamped with tick `k` instead of this one (a part sent after its update's tick).
function M.send_text_at(t, k, fields)
  local client = storage.f3d.client
  if client then
    send_raw(client.port, '{"t":"' .. t .. '","k":' .. k .. fields .. "}")
  end
end

function M.send_now(msg)
  local client = storage.f3d.client
  if client then
    send_raw(client.port, encode(msg))
  end
end

function M.send_reliable(msg)
  local s = storage.f3d
  if not s.client then
    return
  end
  s.rseq = s.rseq + 1
  msg.r = s.rseq
  s.outbox_tail = s.outbox_tail + 1
  s.outbox[s.outbox_tail] = msg
end

-- A reliable message written as JSON text by its module (chunk snapshots: world.lua): `fields`, the
-- fields after t, k and r, starting with a comma. helpers.table_to_json in the flush cost 0.3-0.5 ms a
-- KB there, outside the work budget (1.4-2 ms a tick while chunks streamed on the owner's base, 40-65
-- ms ticks in photo mode); the text is made in the module's own slices instead. Kept in the outbox as
-- {r, t, __text}: the same text on every peer, made from game reads.
function M.send_reliable_text(t, fields)
  local s = storage.f3d
  if not s.client then
    return
  end
  s.rseq = s.rseq + 1
  s.outbox_tail = s.outbox_tail + 1
  s.outbox[s.outbox_tail] = { r = s.rseq, t = t, __text = fields }
end

-- The JSON text of a value for such messages: integers and short strings by hand, anything else (a
-- table of mixed values, a number that isn't finite) through helpers.table_to_json, as before.
local ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function escape_char(c)
  return ESCAPES[c] or string.format("\\u%04x", string.byte(c))
end

function M.json_string(v)
  if v:find('[%c"\\]') then
    v = v:gsub('[%c"\\]', escape_char)
  end
  return '"' .. v .. '"'
end

local function plain_number(v)
  return v == v and v > -1e14 and v < 1e14 and v == math.floor(v)
end

local json_value
-- A list of integers, or nil when it is anything else.
local function int_list(v)
  local n = #v
  if n == 0 then
    return nil
  end
  local c = 0
  for _ in pairs(v) do
    c = c + 1
  end
  if c ~= n then
    return nil
  end
  for i = 1, n do
    local x = v[i]
    if type(x) ~= "number" or not plain_number(x) then
      return nil
    end
  end
  return "[" .. table.concat(v, ",") .. "]"
end

json_value = function(v)
  local t = type(v)
  if t == "number" then
    if plain_number(v) then
      return M.small[v] or tostring(v)
    end
  elseif t == "string" then
    return M.json_string(v)
  elseif t == "boolean" then
    return v and "true" or "false"
  elseif t == "table" then
    local text = int_list(v)
    if text then
      return text
    end
    return helpers.table_to_json(v)
  end
  return helpers.table_to_json({ v }):sub(2, -2)
end

-- An object of string keys (a record's extras) as JSON text, in pairs' order (Factorio's is the same
-- on every peer).
function M.json_object(t)
  local parts = {}
  for k, v in pairs(t) do
    parts[#parts + 1] = '"' .. k .. '":' .. json_value(v)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- Lists for a client that says `z` in its hello are delta-coded: in each part, every number is
-- the difference from the same field of the record before it. Neighbours in these lists sit
-- next to each other in the world (items lane by lane, inserters and movers by chunk), so the
-- differences are short: belt items take about 12 bytes instead of 27.
local function compact()
  local c = storage.f3d.client
  return c and c.z
end

-- Text of the small numbers delta-coded lists are mostly made of.
local small = {}
for v = -4096, 4096 do
  small[v] = tostring(v)
end

-- For lists written elsewhere (belt items write their parts over the ticks they are read in):
-- whether the client wants them delta-coded, and the text of small numbers.
M.compact = compact
M.small = small

-- The text of one part: numbers first..last of `flat` (groups of `width`), delta-coded for a `z`
-- client.
function M.encode_groups(flat, width, first, last)
  if not compact() then
    return table.concat(flat, ",", first, last)
  end
  local slice = {}
  for i = first, math.min(first + width - 1, last) do
    slice[i - first + 1] = flat[i]
  end
  -- Differences are mostly small: their text comes from a table, which is faster than
  -- table.concat formatting each number.
  for i = first + width, last do
    local v = flat[i] - flat[i - width]
    slice[i - first + 1] = small[v] or v
  end
  return table.concat(slice, ",")
end

-- Sends parts made by encode_groups as `t` messages stamped with tick `k` (at least one, empty).
-- `extra`, optional: more fields for every part, as JSON text starting with a comma; `tails`,
-- optional: more for single parts, by part, written after the list. Returns the bytes sent.
function M.send_parts(t, k, bodies, extra, tails)
  local client = storage.f3d.client
  if not client then
    return
  end
  local parts = math.max(1, #bodies)
  local head = '{"t":"' .. t .. '","k":' .. k .. ',"parts":' .. parts .. (client.z and ',"z":1' or "") .. (extra or "") .. ',"part":'
  local bytes = 0
  for part = 1, parts do
    local text = head .. part .. ',"l":[' .. (bodies[part] or "") .. "]" .. (tails and tails[part] or "") .. "}"
    bytes = bytes + #text
    send_raw(client.port, text)
  end
  return bytes
end

-- `flat` is groups of `width` numbers; sent as `t` messages of at most `per` groups, parts
-- sharing the tick `k`. An empty list is still sent, as one empty part.
--
-- These are the biggest messages (thousands of belt items ten times a second), and
-- helpers.table_to_json was most of their cost (measured with tools/busy_base.py), so the JSON is
-- written here: the numbers are integers, which table.concat writes as JSON does.
-- `extra`, optional: more fields for every part, as JSON text starting with a comma. Returns the
-- bytes sent (nil without a client).
function M.send_groups(t, flat, width, per, extra)
  if not storage.f3d.client then
    return
  end
  local n = per * width
  local bodies = {}
  for part = 1, math.max(1, math.ceil(#flat / n)) do
    bodies[part] = M.encode_groups(flat, width, (part - 1) * n + 1, math.min(part * n, #flat))
  end
  return M.send_parts(t, game.tick, bodies, extra)
end

-- `list` is records (arrays) whose first four numbers are delta-coded for a `z` client; anything
-- after them (a mover's orientation) stays as is.
-- `p`, optional: the ticks until the next such list (rate.lua), for the client's gliding.
function M.send_records(t, list, per, p)
  local z = compact()
  local parts = math.max(1, math.ceil(#list / per))
  for part = 1, parts do
    local slice = {}
    local first = (part - 1) * per + 1
    for i = first, math.min(part * per, #list) do
      local rec = list[i]
      if z and i > first then
        local prev, coded = list[i - 1], {}
        for j = 1, #rec do
          coded[j] = j <= 4 and rec[j] - prev[j] or rec[j]
        end
        rec = coded
      end
      slice[#slice + 1] = rec
    end
    M.send_now({ t = t, part = part, parts = parts, z = z and 1 or nil, p = p, l = slice })
  end
end

function M.backlog()
  local s = storage.f3d
  return s.outbox_tail - s.outbox_head + 1
end

function M.reset()
  local s = storage.f3d
  s.rseq = 0
  s.outbox = {}
  s.outbox_head = 1
  s.outbox_tail = 0
end

function M.flush()
  local s = storage.f3d
  local client = s.client
  local budget = settings.global["f3d-bytes-per-tick"].value
  if photo.on() then
    budget = budget * photo.BYTES -- a screenshot loading its chunks (photo.lua)
  end
  local sent = 0
  while s.outbox_head <= s.outbox_tail and sent < budget do
    local msg = s.outbox[s.outbox_head]
    s.outbox[s.outbox_head] = nil
    s.outbox_head = s.outbox_head + 1
    -- (A message its module wrote as text, send_reliable_text: no table_to_json here.)
    local data
    if msg.__text then
      data = '{"t":"' .. msg.t .. '","k":' .. game.tick .. ',"r":' .. msg.r .. msg.__text .. "}"
    else
      data = encode(msg)
    end
    sent = sent + #data
    if client then
      send_raw(client.port, data)
    end
  end
  if s.outbox_head > s.outbox_tail then
    s.outbox_head = 1
    s.outbox_tail = 0
  end
end

return M
