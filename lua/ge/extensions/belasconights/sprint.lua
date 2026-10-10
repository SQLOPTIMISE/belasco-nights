-- Belasco Nights sprint: a point-to-point race against rivals. The route is
-- generated on the level's road network from wherever the player is parked, so
-- it works on any map without hand-placed checkpoints.

local M = {}
M.dependencies = {'belasconights_core'}

local logTag = 'belasconights'
local hudCategory = 'belasconights_hud'
local upVec = vec3(0, 0, 1)

local race = nil
local hudTimer = 0

-- The route, the rivals and the road arrows all have to agree on the same roads,
-- so every path search uses these: proper roads only, in the legal direction.
local routeCutoff = 0.9
local routeDirMult = 1e4
local releaseLead = 0.35 -- rivals are let go this long before GO; it takes them about that long to bite

local function core()
  return belasconights_core
end

local function xyDistance(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

local function isPaved(node)
  if (node.radius or 0) < 2 then return false end
  for _, link in pairs(node.links or {}) do
    if (link.drivability or 0) >= 0.9 then return true end
  end
  return false
end

-- route --------------------------------------------------------------------

local function findRoute(pos, dir, cfg)
  local mapData = map.getMap()
  local nodes = mapData and mapData.nodes
  if not nodes then return nil, 'This level has no road map.' end

  local n1, n2, dist = map.findClosestRoad(pos)
  if not n1 or not n2 or (dist and dist > 25) then return nil, 'Get onto a road first.' end
  local startNode = (nodes[n1].pos - pos):dot(dir) > (nodes[n2].pos - pos):dot(dir) and n1 or n2

  local candidates = {}
  for name, node in pairs(nodes) do
    local d = node.pos:distance(pos)
    if d >= cfg.minLength * 0.6 and d <= cfg.maxLength and isPaved(node) then
      table.insert(candidates, name)
    end
  end
  if #candidates == 0 then return nil, 'No paved roads far enough away from here.' end

  for _ = 1, 30 do
    local target = candidates[math.random(#candidates)]
    local path = map.getPath(startNode, target, routeCutoff, routeDirMult)
    if path and #path >= 3 then
      local length = map.getPathLen(path)
      local firstDir = (nodes[path[2]].pos - nodes[path[1]].pos):normalized()
      -- reject routes that start with a U-turn
      if length >= cfg.minLength and length <= cfg.maxLength and firstDir:dot(dir) > 0.2 then
        return {path = path, length = length, nodes = nodes}
      end
    end
  end
  return nil, 'Could not find a good route from here. Try another street.'
end

local function buildCheckpoints(route, spacing)
  local nodes, path = route.nodes, route.path
  local cps = {}
  local acc = 0
  for i = 2, #path - 1 do
    acc = acc + nodes[path[i]].pos:distance(nodes[path[i - 1]].pos)
    if acc >= spacing then
      local node = nodes[path[i]]
      table.insert(cps, {node = path[i], pos = vec3(node.pos), radius = math.max((node.radius or 4) + 5, 12)})
      acc = 0
    end
  end
  local last = nodes[path[#path]]
  -- drop an intermediate checkpoint that sits right before the finish
  if #cps > 0 and cps[#cps].pos:distance(last.pos) < spacing * 0.4 then table.remove(cps) end
  table.insert(cps, {node = path[#path], pos = vec3(last.pos), radius = math.max((last.radius or 4) + 6, 14), finish = true})
  return cps
end

-- helpers ------------------------------------------------------------------

-- Point and direction a given distance along the route, measured from the player.
local function pointAlongRoute(route, startPos, dist)
  local prev = startPos
  for i = 1, #route.path do
    local nodePos = route.nodes[route.path[i]].pos
    local seg = nodePos - prev
    local len = seg:length()
    if len > 0.5 then
      if dist <= len then return prev + seg * (dist / len), seg / len end
      dist = dist - len
      prev = nodePos
    end
  end
  return nil
end

-- Route nodes for the rivals, leaving out the ones they are spawned on top of
-- so that they never turn back for a node behind them.
local function rivalTargets(route, startPos, skipDist)
  local targets = {}
  local travelled = 0
  local prev = startPos
  for i = 1, #route.path do
    local nodePos = route.nodes[route.path[i]].pos
    travelled = travelled + nodePos:distance(prev)
    prev = nodePos
    if travelled > skipDist or i == #route.path then table.insert(targets, route.path[i]) end
  end
  return targets
end

local function reached(pos, cp, margin)
  return xyDistance(pos, cp.pos) < cp.radius + (margin or 0) and math.abs(pos.z - cp.pos.z) < 12
end

local function setFrozen(id, frozen)
  local veh = getObjectByID(id)
  if veh then core_vehicleBridge.executeAction(veh, 'setFreeze', frozen) end
end

-- Spawned cars take a moment before they accept commands, so the hold is
-- repeated until the rivals are released. Stops them rolling off the grid.
local function holdRivals()
  for _, r in ipairs(race.racers) do
    local veh = getObjectByID(r.id)
    if veh then
      core_vehicleBridge.executeAction(veh, 'setFreeze', true)
    end
  end
end

local function cleanup()
  if not race then return end
  local finished = race
  race = nil -- detach first: deleting the rivals fires onVehicleDestroyed
  setFrozen(finished.playerId, false)
  for _, r in ipairs(finished.racers) do
    core().removeVehicle(r.id)
  end
  core_groundMarkers.setPath(nil)
  core().endEvent('sprint')
end

local function abort()
  if not race then return end
  cleanup()
  core().notify('Sprint aborted.', 4, hudCategory)
end

local function progressScore(cpIndex, pos)
  local cp = race.cps[cpIndex]
  if not cp then return cpIndex * 100000 end
  return cpIndex * 100000 - xyDistance(pos, cp.pos)
end

local function getPlayerPlace(playerPos)
  local playerScore = progressScore(race.playerCp, playerPos)
  local place = 1
  for _, r in ipairs(race.racers) do
    if r.finished or (r.score or 0) > playerScore then place = place + 1 end
  end
  return place
end

local function drawMarkers()
  local cp = race.cps[race.playerCp]
  if not cp then return end
  -- a flat disc on the road and a light beam, rather than a sphere that fills the screen up close
  debugDrawer:drawCylinder(cp.pos, cp.pos + vec3(0, 0, 0.25), cp.radius, ColorF(0.1, 0.9, 1, 0.22))
  debugDrawer:drawCylinder(cp.pos, cp.pos + vec3(0, 0, 40), 0.35, ColorF(0.1, 0.9, 1, 0.6))
  local label = cp.finish and 'FINISH' or string.format('CP %d/%d', race.playerCp, #race.cps)
  debugDrawer:drawTextAdvanced(cp.pos + vec3(0, 0, 4), String(label), ColorF(1, 1, 1, 1), true, false, ColorI(0, 0, 0, 180))
  local nextCp = race.cps[race.playerCp + 1]
  if nextCp then
    debugDrawer:drawCylinder(nextCp.pos, nextCp.pos + vec3(0, 0, 25), 0.25, ColorF(0.1, 0.9, 1, 0.25))
  end
end

-- flow ---------------------------------------------------------------------

-- Rivals get their route as soon as they are on the grid. Their engines are
-- off when they spawn, and it is the AI that starts them, which takes a couple
-- of seconds; doing it during the countdown means they launch on GO.
local function arm()
  local cfg = core().getConfig().sprint
  local aiArgs = {
    wpTargetList = race.targets,
    aggression = cfg.aggressionByTier[race.tier] or 0.9,
    avoidCars = 'on',
    driveInLane = 'off',
  }
  for _, r in ipairs(race.racers) do
    local veh = getObjectByID(r.id)
    if veh then
      core().prepareRival(r.id)
      veh:queueLuaCommand('ai.driveUsingPath(' .. serialize(aiArgs) .. ')')
    end
  end
  race.armed = true
end

local function start()
  if race then
    core().notify('A sprint is already running.')
    return
  end
  if not core().beginEvent('sprint') then return end

  local cfg = core().getConfig().sprint
  local veh = getPlayerVehicle(0)
  local pos = vec3(veh:getPosition())
  local dir = vec3(veh:getDirectionVector())
  dir.z = 0
  dir:normalize()

  local route, err = findRoute(pos, dir, cfg)
  if not route then
    core().notify(err)
    core().endEvent('sprint')
    return
  end

  local tier = core().getTier()
  race = {
    state = 'staging',
    timer = 3,
    cps = buildCheckpoints(route, cfg.checkpointSpacing),
    targets = rivalTargets(route, pos, 8 * cfg.opponents + 20),
    length = route.length,
    tier = tier,
    playerId = veh:getID(),
    playerCp = 1,
    racers = {},
    finishedCount = 0,
    time = 0,
  }

  for i = 1, cfg.opponents do
    local entry = core().pickRival(tier)
    if entry then
      -- grid slots follow the road, not the player's nose
      local slotPos, slotDir = pointAlongRoute(route, pos, 8 * i)
      slotPos, slotDir = slotPos or (pos + dir * (8 * i)), slotDir or dir
      slotDir.z = 0
      slotDir:normalize()
      local spawnPos = slotPos + slotDir:cross(upVec) * ((i % 2 == 0) and 1.8 or -1.8)
      local id = core().spawnRival(entry, spawnPos, slotDir)
      if id then
        table.insert(race.racers, {id = id, cp = 1, finished = false, score = 0, gridPos = vec3(spawnPos)})
      end
    end
  end

  holdRivals()
  arm()
  setFrozen(race.playerId, true)
  -- route arrows through every checkpoint, given as road node names
  local routeNodes = {}
  for _, cp in ipairs(race.cps) do table.insert(routeNodes, cp.node) end
  core_groundMarkers.setPath(routeNodes, {cutOffDrivability = routeCutoff, dirMult = routeDirMult})
  core().notify(string.format('Sprint: %.1f km against %d rivals. Get ready.', route.length / 1000, #race.racers), 5, hudCategory)
  log('I', logTag, string.format('Sprint started: %d m, %d checkpoints, %d rivals, tier %d', route.length, #race.cps, #race.racers, tier))
end

local function releaseRivals()
  for _, r in ipairs(race.racers) do setFrozen(r.id, false) end
  race.released = true
end

local function go()
  if not race.released then releaseRivals() end
  setFrozen(race.playerId, false)
  race.state = 'racing'
  core().flash('GO!', 1)
  for _, r in ipairs(race.racers) do
    local veh = getObjectByID(r.id)
    if veh then
      log('D', logTag, string.format('GO: rival %d is %.1f m off its grid slot at %.1f m/s', r.id, vec3(veh:getPosition()):distance(r.gridPos), vec3(veh:getVelocity()):length()))
    end
  end
end

local function finish(place)
  local cfg = core().getConfig().sprint
  local share = cfg.positionShare[place] or 0
  local prize = (cfg.prizeByTier[race.tier] or 0) * (1 + race.length / 1000 * cfg.prizePerKm) * share
  prize = math.floor(prize / 10 + 0.5) * 10
  local rep = cfg.repByPosition[place] or 0
  core().flash(place == 1 and 'YOU WIN' or string.format('FINISHED P%d', place), 3)
  core().notify(string.format('Sprint finished: P%d of %d in %.1f s. +$%d, +%d rep.', place, #race.racers + 1, race.time, prize, rep), 10, hudCategory)
  log('I', logTag, string.format('Sprint finished: place %d, time %.1f, prize %d, rep %d', place, race.time, prize, rep))
  core().addStat(place == 1 and 'sprintWins' or 'sprintFinishes')
  race.state = 'finished'
  race.timer = 8
  core_groundMarkers.setPath(nil)
  core().reward(prize, rep, 'Belasco Nights sprint')
end

local function updateRacing(dtSim)
  race.time = race.time + dtSim

  local playerVeh = getPlayerVehicle(0)
  if not playerVeh or playerVeh:getID() ~= race.playerId then
    abort()
    return
  end
  local playerPos = vec3(playerVeh:getPosition())

  for _, r in ipairs(race.racers) do
    if not r.finished then
      local veh = getObjectByID(r.id)
      if veh then
        local pos = vec3(veh:getPosition())
        if not r.launched and vec3(veh:getVelocity()):length() > 5 then
          r.launched = true
          log('D', logTag, string.format('Rival %d reached 18 km/h %.2f s after GO', r.id, race.time))
        end
        local cp = race.cps[r.cp]
        if cp and reached(pos, cp, 4) then
          r.cp = r.cp + 1
          if r.cp > #race.cps then
            r.finished = true
            race.finishedCount = race.finishedCount + 1
          end
        end
        r.score = progressScore(r.cp, pos)
      end
    end
  end

  local cp = race.cps[race.playerCp]
  if reached(playerPos, cp) then
    race.playerCp = race.playerCp + 1
    if race.playerCp > #race.cps then
      finish(race.finishedCount + 1)
      return
    end
  end

  if race.time > race.length / 8 + 120 then
    core().notify('Sprint over: you ran out of time.', 8, hudCategory)
    cleanup()
    return
  end

  hudTimer = hudTimer + dtSim
  if hudTimer >= 0.25 then
    hudTimer = 0
    core().notify(string.format('Sprint  P%d/%d  CP %d/%d  %.1f s', getPlayerPlace(playerPos), #race.racers + 1,
      math.min(race.playerCp, #race.cps), #race.cps, race.time), 2, hudCategory)
  end
end

local function onUpdate(dtReal, dtSim)
  if not race then return end
  dtSim = dtSim or dtReal

  if race.state == 'staging' then
    drawMarkers()
    race.holdTimer = (race.holdTimer or 0) + dtSim
    if race.holdTimer > 0.5 then
      race.holdTimer = 0
      holdRivals()
    end
    race.timer = race.timer - dtSim
    if race.timer <= 0 then
      race.state = 'countdown'
      race.timer = 3
      race.lastShown = nil
    end
  elseif race.state == 'countdown' then
    drawMarkers()
    local shown = math.ceil(race.timer)
    if shown ~= race.lastShown and shown > 0 then
      race.lastShown = shown
      core().flash(tostring(shown), 1)
    end
    race.timer = race.timer - dtSim
    if not race.released then
      race.holdTimer = (race.holdTimer or 0) + dtSim
      if race.holdTimer > 0.5 then
        race.holdTimer = 0
        holdRivals()
      end
      if race.timer <= releaseLead then releaseRivals() end
    end
    if race.timer <= 0 then go() end
  elseif race.state == 'racing' then
    drawMarkers()
    updateRacing(dtSim)
  elseif race.state == 'finished' then
    race.timer = race.timer - dtSim
    if race.timer <= 0 then cleanup() end
  end
end

local function onVehicleDestroyed(id)
  if not race then return end
  if id == race.playerId then
    abort()
    return
  end
  for i, r in ipairs(race.racers) do
    if r.id == id then
      table.remove(race.racers, i)
      return
    end
  end
end

local function onClientEndMission()
  race = nil
end

M.onUpdate = onUpdate
M.onVehicleDestroyed = onVehicleDestroyed
M.onClientEndMission = onClientEndMission

-- for the minimap
local function getRivalIds()
  local ids = {}
  if race then
    for _, r in ipairs(race.racers) do table.insert(ids, r.id) end
  end
  return ids
end

local function getCheckpoint()
  local cp = race and race.cps[race.playerCp]
  return cp and cp.pos or nil
end

M.start = start
M.getRivalIds = getRivalIds
M.getCheckpoint = getCheckpoint
M.abort = abort

return M
