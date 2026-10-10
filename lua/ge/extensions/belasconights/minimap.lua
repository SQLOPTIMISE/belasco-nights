-- Belasco Nights minimap: a small heading-up road map in the bottom-left corner
-- while the streets are open. Shows nearby roads, traffic, the rivals of the
-- current event and the next sprint checkpoint.

local M = {}
M.dependencies = {'belasconights_core'}

local im = ui_imgui

local refreshInterval = 0.4 -- seconds between rebuilding the list of nearby roads
local refreshTimer = refreshInterval
local roads = {}            -- {ax, ay, bx, by, width} in world coordinates
local upVec = vec3(0, 0, 1)
local p1, p2 = im.ImVec2(0, 0), im.ImVec2(0, 0)

local colors = nil

local function core()
  return belasconights_core
end

local function getCfg()
  return core().getConfig().minimap or {}
end

local function initColors()
  colors = {
    road = im.GetColorU322(im.ImVec4(0.5, 0.54, 0.68, 0.95)),
    border = im.GetColorU322(im.ImVec4(0.18, 0.88, 1, 0.9)),
    player = im.GetColorU322(im.ImVec4(1, 1, 1, 1)),
    rival = im.GetColorU322(im.ImVec4(1, 0.2, 0.2, 1)),
    rivalRing = im.GetColorU322(im.ImVec4(1, 1, 1, 0.9)),
    traffic = im.GetColorU322(im.ImVec4(1, 0.85, 0.3, 0.95)),
    checkpoint = im.GetColorU322(im.ImVec4(0.18, 0.88, 1, 1)),
  }
end

local function refreshRoads(pos, range)
  roads = {}
  local mapData = map.getMap()
  local nodes = mapData and mapData.nodes
  if not nodes then return end
  local reach = range * 1.5
  local seen = {}
  for name, node in pairs(nodes) do
    local dx, dy = node.pos.x - pos.x, node.pos.y - pos.y
    if dx * dx + dy * dy < reach * reach and math.abs(node.pos.z - pos.z) < 40 then
      for other, _ in pairs(node.links or {}) do
        -- a link may be listed on one end only or on both; draw each once
        local key = name < other and (name .. '|' .. other) or (other .. '|' .. name)
        if not seen[key] and nodes[other] then
          seen[key] = true
          local o = nodes[other].pos
          table.insert(roads, {node.pos.x, node.pos.y, o.x, o.y, math.min(node.radius or 3, 8)})
        end
      end
    end
  end
end

local function rivalIds()
  local ids = {}
  for _, ext in ipairs({belasconights_sprint, belasconights_outrun}) do
    if ext and ext.getRivalIds then
      for _, id in ipairs(ext.getRivalIds() or {}) do ids[id] = true end
    end
  end
  return ids
end

local function onUpdate(dtReal)
  if not core().isActive() or getCfg().enabled == false then return end
  local veh = getPlayerVehicle(0)
  if not veh then return end
  if not colors then initColors() end

  local pos = vec3(veh:getPosition())
  local fwd = vec3(veh:getDirectionVector())
  fwd.z = 0
  if fwd:length() < 0.01 then return end
  fwd:normalize()
  local right = fwd:cross(upVec)

  local range = getCfg().range or 220
  refreshTimer = refreshTimer + dtReal
  if refreshTimer >= refreshInterval then
    refreshTimer = 0
    refreshRoads(pos, range)
  end

  local viewport = im.GetMainViewport()
  local uiScale = (viewport and viewport.Size.y or 1080) / 1080
  local size = (getCfg().size or 300) * uiScale
  local margin = 24 * uiScale
  local left = (viewport and viewport.Pos.x or 0) + margin
  local top = (viewport and viewport.Pos.y or 0) + (viewport and viewport.Size.y or 1080) - size - margin

  im.SetNextWindowPos(im.ImVec2(left, top), im.Cond_Always)
  im.SetNextWindowSize(im.ImVec2(size, size), im.Cond_Always)
  im.SetNextWindowBgAlpha(0.6)
  local flags = bit.bor(im.WindowFlags_NoTitleBar, im.WindowFlags_NoResize, im.WindowFlags_NoMove, im.WindowFlags_NoScrollbar, im.WindowFlags_NoInputs)
  if im.Begin('##belasconightsMinimap', nil, flags) then
    local dl = im.GetWindowDrawList()
    local cx, cy = left + size * 0.5, top + size * 0.62 -- player sits below centre: more road ahead
    local k = size * 0.5 / range

    -- world position to map pixels, heading up
    local function project(x, y)
      local rx, ry = x - pos.x, y - pos.y
      return cx + (rx * right.x + ry * right.y) * k, cy - (rx * fwd.x + ry * fwd.y) * k
    end

    for _, r in ipairs(roads) do
      p1.x, p1.y = project(r[1], r[2])
      p2.x, p2.y = project(r[3], r[4])
      im.ImDrawList_AddLine(dl, p1, p2, colors.road, math.max(2, r[5] * k * 1.6))
    end

    -- puts a marker on the map, held at the edge when it is out of range
    local function marker(worldPos, radius, color, ring)
      local x, y = project(worldPos.x, worldPos.y)
      local inset = radius + 4 * uiScale
      local clamped = x < left + inset or x > left + size - inset or y < top + inset or y > top + size - inset
      p1.x = math.max(left + inset, math.min(left + size - inset, x))
      p1.y = math.max(top + inset, math.min(top + size - inset, y))
      im.ImDrawList_AddCircleFilled(dl, p1, radius, color)
      if ring then im.ImDrawList_AddCircle(dl, p1, radius + 2 * uiScale, ring) end
      return clamped
    end

    local rivals = rivalIds()
    local playerId = veh:getID()
    for _, other in ipairs(getAllVehicles()) do
      local id = other:getID()
      if id ~= playerId and not rivals[id] then
        local op = other:getPosition()
        local dx, dy = op.x - pos.x, op.y - pos.y
        if dx * dx + dy * dy < range * range * 2 then
          p1.x, p1.y = project(op.x, op.y)
          im.ImDrawList_AddCircleFilled(dl, p1, 4 * uiScale, colors.traffic)
        end
      end
    end

    local checkpoint = belasconights_sprint and belasconights_sprint.getCheckpoint and belasconights_sprint.getCheckpoint()
    if checkpoint then marker(checkpoint, 8 * uiScale, colors.checkpoint) end

    for id, _ in pairs(rivals) do
      local rival = getObjectByID(id)
      if rival then marker(rival:getPosition(), 7 * uiScale, colors.rival, colors.rivalRing) end
    end

    -- the player: a dot with a line showing which way is forward
    p1.x, p1.y = cx, cy
    p2.x, p2.y = cx, cy - 16 * uiScale
    im.ImDrawList_AddLine(dl, p1, p2, colors.player, 3 * uiScale)
    im.ImDrawList_AddCircleFilled(dl, p1, 6 * uiScale, colors.player)

    p1.x, p1.y = left + 1, top + 1
    p2.x, p2.y = left + size - 1, top + 1
    im.ImDrawList_AddLine(dl, p1, p2, colors.border, 2 * uiScale)
  end
  im.End()
end

M.onUpdate = onUpdate

return M
