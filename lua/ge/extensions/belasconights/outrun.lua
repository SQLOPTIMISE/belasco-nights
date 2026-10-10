-- Belasco Nights outrun: a one-on-one street duel with no fixed route.
-- Whoever is in front leads; the leader wins by pulling a set gap on the other.

local M = {}
M.dependencies = {'belasconights_core'}

local logTag = 'belasconights'
local hudCategory = 'belasconights_hud'

local run = nil
local hudTimer = 0
local releaseLead = 0.35 -- the rival is let go this long before GO; it takes about that long to bite

local function core()
  return belasconights_core
end

local function setFrozen(id, frozen)
  local veh = getObjectByID(id)
  if veh then core_vehicleBridge.executeAction(veh, 'setFreeze', frozen) end
end

local function cleanup()
  if not run then return end
  local finished = run
  run = nil -- detach first: deleting the rival fires onVehicleDestroyed
  setFrozen(finished.playerId, false)
  core().removeVehicle(finished.rivalId)
  core().endEvent('outrun')
end

local function abort()
  if not run then return end
  cleanup()
  core().notify('Outrun aborted.', 4, hudCategory)
end

-- The rival leads: it picks its own way through the streets, flat out.
local function rivalLeads()
  local veh = getObjectByID(run.rivalId)
  if not veh then return end
  -- flee picks roads that lead away from the player and drives them flat out
  veh:queueLuaCommand(string.format(
    'ai.setMode("flee") ai.setTargetObjectID(%d) ai.setAggression(%f) ai.setSpeedMode("off") ai.driveInLane("off") ai.setAvoidCars("on")',
    run.playerId, run.aggression))
  run.lead = 'rival'
end

-- The player leads: the rival hunts them down.
local function playerLeads()
  local veh = getObjectByID(run.rivalId)
  if not veh then return end
  veh:queueLuaCommand(string.format(
    'ai.setMode("chase") ai.setTargetObjectID(%d) ai.setAggression(%f)',
    run.playerId, run.aggression))
  run.lead = 'player'
end

local function start()
  if run then
    core().notify('An outrun is already running.')
    return
  end
  if not core().beginEvent('outrun') then return end

  local cfg = core().getConfig().outrun
  local veh = getPlayerVehicle(0)
  local pos = vec3(veh:getPosition())
  local dir = vec3(veh:getDirectionVector())
  dir.z = 0
  dir:normalize()

  local tier = core().getTier()
  local entry = core().pickRival(tier)
  local rivalId = entry and core().spawnRival(entry, pos + dir * 12, dir)
  if not rivalId then
    core().notify('No rival showed up. Try another street.')
    core().endEvent('outrun')
    return
  end

  run = {
    state = 'staging',
    timer = 3,
    tier = tier,
    playerId = veh:getID(),
    rivalId = rivalId,
    aggression = cfg.aggressionByTier[tier] or 0.9,
    lead = 'rival',
    time = 0,
  }
  setFrozen(run.playerId, true)
  setFrozen(run.rivalId, true)
  -- orders go out straight away: the rival spawns with its engine off and the AI
  -- needs the countdown to start it
  rivalLeads()
  core().notify(string.format('Outrun: get %d m clear of your rival to win.', cfg.winGap), 5, hudCategory)
  log('I', logTag, string.format('Outrun started: rival %s/%s, tier %d', entry.model, entry.config, tier))
end

local function go()
  setFrozen(run.playerId, false)
  setFrozen(run.rivalId, false)
  run.state = 'racing'
  core().flash('GO!', 1)
end

local function finish(result)
  local cfg = core().getConfig().outrun
  if result == 'win' then
    local prize = cfg.prizeByTier[run.tier] or 0
    core().flash('YOU WIN', 3)
    core().notify(string.format('Outrun won in %.1f s. +$%d, +%d rep.', run.time, prize, cfg.repWin), 10, hudCategory)
    core().addStat('outrunWins')
    core().reward(prize, cfg.repWin, 'Belasco Nights outrun')
  elseif result == 'lose' then
    core().flash('YOU LOSE', 3)
    core().notify(string.format('Outrun lost. %d rep.', cfg.repLoss), 10, hudCategory)
    core().addStat('outrunLosses')
    core().reward(0, cfg.repLoss, 'Belasco Nights outrun')
  else
    core().notify('Outrun called off: nobody got away.', 8, hudCategory)
  end
  log('I', logTag, string.format('Outrun finished: %s after %.1f s', result, run.time))
  run.state = 'finished'
  run.timer = 6
end

local function updateRacing(dtSim)
  local cfg = core().getConfig().outrun
  run.time = run.time + dtSim

  local playerVeh = getPlayerVehicle(0)
  local rivalVeh = getObjectByID(run.rivalId)
  if not playerVeh or playerVeh:getID() ~= run.playerId or not rivalVeh then
    abort()
    return
  end

  local playerPos = vec3(playerVeh:getPosition())
  local rivalPos = vec3(rivalVeh:getPosition())
  local gap = playerPos:distance(rivalPos)

  -- lead changes when one car is clearly in front of the other
  if run.lead == 'rival' then
    local rivalDir = vec3(rivalVeh:getDirectionVector())
    if (playerPos - rivalPos):dot(rivalDir) > 6 then
      playerLeads()
      core().notify('You have the lead. Lose them!', 4)
    end
  else
    local playerDir = vec3(playerVeh:getDirectionVector())
    if (rivalPos - playerPos):dot(playerDir) > 6 then
      rivalLeads()
      core().notify('They took the lead back.', 4)
    end
  end

  if gap >= cfg.winGap then
    finish(run.lead == 'player' and 'win' or 'lose')
    return
  end
  if run.time >= cfg.timeLimit then
    finish('draw')
    return
  end

  hudTimer = hudTimer + dtSim
  if hudTimer >= 0.25 then
    hudTimer = 0
    core().notify(string.format('Outrun  %s  gap %d / %d m  %.0f s', run.lead == 'player' and 'LEADING' or 'CHASING',
      gap, cfg.winGap, cfg.timeLimit - run.time), 2, hudCategory)
  end
end

local function onUpdate(dtReal, dtSim)
  if not run then return end
  dtSim = dtSim or dtReal

  if run.state == 'staging' then
    run.holdTimer = (run.holdTimer or 0) + dtSim
    if run.holdTimer > 0.5 then
      run.holdTimer = 0
      setFrozen(run.rivalId, true)
    end
    run.timer = run.timer - dtSim
    if run.timer <= 0 then
      run.state = 'countdown'
      run.timer = 3
      run.lastShown = nil
    end
  elseif run.state == 'countdown' then
    local shown = math.ceil(run.timer)
    if shown ~= run.lastShown and shown > 0 then
      run.lastShown = shown
      core().flash(tostring(shown), 1)
    end
    run.timer = run.timer - dtSim
    if not run.released and run.timer <= releaseLead then
      setFrozen(run.rivalId, false)
      run.released = true
    end
    if run.timer <= 0 then go() end
  elseif run.state == 'racing' then
    updateRacing(dtSim)
  elseif run.state == 'finished' then
    run.timer = run.timer - dtSim
    if run.timer <= 0 then cleanup() end
  end
end

local function onVehicleDestroyed(id)
  if run and (id == run.playerId or id == run.rivalId) then abort() end
end

local function onClientEndMission()
  run = nil
end

M.onUpdate = onUpdate
M.onVehicleDestroyed = onVehicleDestroyed
M.onClientEndMission = onClientEndMission

-- for the minimap
local function getRivalIds()
  return run and {run.rivalId} or {}
end

M.start = start
M.getRivalIds = getRivalIds
M.abort = abort

return M
