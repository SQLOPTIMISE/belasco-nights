-- Belasco Nights core: owns the night-mode state, the player's cash/rep save,
-- the rival roster and the radial menu. Events (sprint, outrun) live in their
-- own extensions and call back into this one.
--
-- Hooks fired for other extensions:
--   onBelascoNightsStart()
--   onBelascoNightsEnd()

local M = {}
M.dependencies = {'core_environment'}

local logTag = 'belasconights'
local dataDir = '/belascoNights/'
local savePath = '/settings/belascoNights/save.json'
local checkInterval = 1 -- seconds between clock checks

local config = nil
local roster = nil
local story = nil
local save = nil

local active = false      -- is the street scene on right now
local manual = nil        -- nil: follow the clock, true: forced on, false: forced off until dawn
local forcedTime = nil    -- time of day to restore when a forced night ends
local spawnedTraffic = false
local currentEvent = nil  -- name of the extension running an event, e.g. 'sprint'
local checkTimer = 0
local menuRegistered = false

local upVec = vec3(0, 0, 1)

-- data ---------------------------------------------------------------------

local function loadData()
  config = jsonReadFile(dataDir .. 'config.json') or {}
  roster = jsonReadFile(dataDir .. 'roster.json') or {slots = {}}
  story = jsonReadFile(dataDir .. 'story.json') or {chapters = {}}
  save = jsonReadFile(savePath) or {}
  save.cash = save.cash or 0
  save.rep = save.rep or 0
  save.storySeen = save.storySeen or {}
  save.stats = save.stats or {}
end

local function writeSave()
  jsonWriteFile(savePath, save, true)
end

local function getConfig()
  if not config then loadData() end
  return config
end

-- messages -----------------------------------------------------------------

local function notify(msg, ttl, category)
  ui_message(msg, ttl or 5, category or logTag)
end

local function flash(msg, ttl)
  guihooks.trigger('ScenarioFlashMessage', {{msg, ttl or 1}})
end

-- player state -------------------------------------------------------------

local function isCareer()
  return career_career ~= nil and career_career.isActive() == true
end

local function getTier()
  local tier = 1
  for _, t in ipairs(getConfig().tiers or {}) do
    if save.rep >= t.minRep and t.tier > tier then tier = t.tier end
  end
  return tier
end

local function checkStory()
  for _, chapter in ipairs(story.chapters or {}) do
    if save.rep >= chapter.minRep and not save.storySeen[chapter.id] then
      save.storySeen[chapter.id] = true
      writeSave()
      log('I', logTag, 'Story chapter: ' .. chapter.id)
      guihooks.trigger('toastrMsg', {type = 'info', title = chapter.title, msg = chapter.text, config = {timeOut = 20000}})
      return -- one chapter at a time
    end
  end
end

local function reward(cash, rep, label)
  cash = cash or 0
  rep = rep or 0
  if cash ~= 0 then
    if isCareer() and career_modules_playerAttributes then
      career_modules_playerAttributes.addAttributes({money = cash}, {label = label or 'Belasco Nights', tags = {'gameplay', 'reward'}})
    else
      save.cash = save.cash + cash
    end
  end
  save.rep = math.max(0, save.rep + rep)
  writeSave()
  checkStory()
end

local function getCash()
  return save.cash
end

-- Takes cash from the mod's own wallet. Returns false if there is not enough.
local function spend(amount, label)
  if isCareer() then return false end
  if save.cash < amount then
    notify(string.format('Not enough cash: %s costs $%d and you have $%d.', label or 'that', amount, save.cash))
    return false
  end
  save.cash = save.cash - amount
  writeSave()
  return true
end

-- Small per-player preferences kept with the save, e.g. the garage text size.
local function getSetting(name)
  return save.settings and save.settings[name]
end

local function setSetting(name, value)
  save.settings = save.settings or {}
  save.settings[name] = value
  writeSave()
end

local function addStat(name)
  save.stats[name] = (save.stats[name] or 0) + 1
  writeSave()
end

local function getStatusText()
  local cashText = isCareer() and 'career wallet' or string.format('$%d', save.cash)
  return string.format('Rep %d (tier %d), cash %s', save.rep, getTier(), cashText)
end

-- roster -------------------------------------------------------------------

-- First entry of a slot whose config is installed, or nil.
local function getSlotVehicle(slotName)
  for _, entry in ipairs(roster.slots[slotName] or {}) do
    if FS:fileExists('/vehicles/' .. entry.model .. '/' .. entry.config .. '.pc') then
      return entry
    end
  end
  return nil
end

local function isInstalled(entry)
  return FS:fileExists('/vehicles/' .. entry.model .. '/' .. entry.config .. '.pc')
end

-- Stock power of the player's current config, or nil if the game does not know it.
local function getPlayerPower()
  local details = core_vehicles.getCurrentVehicleDetails()
  local power = details and details.configs and tonumber(details.configs.Power)
  return power and power > 0 and power or nil
end

-- Rivals are matched to the player's car: the tier only decides how much more
-- power they get. Without a power figure, fall back to the tier's own list.
local function pickRival(tier)
  local power = getConfig().matchPlayerCar ~= false and getPlayerPower()
  if power then
    local band = (getConfig().rivalPowerBandByTier or {})[tier] or {0.9, 1.15}
    local all, inBand = {}, {}
    for name, list in pairs(roster.slots) do
      if string.find(name, 'rivals_', 1, true) then
        for _, entry in ipairs(list) do
          if entry.power then
            table.insert(all, entry)
            if entry.power >= power * band[1] and entry.power <= power * band[2] then table.insert(inBand, entry) end
          end
        end
      end
    end
    for _ = 1, 10 do
      local entry = inBand[math.random(math.max(#inBand, 1))]
      if entry and isInstalled(entry) then return entry end
    end
    -- nothing in the band: take one of the closest by power
    local target = power * (band[1] + band[2]) * 0.5
    table.sort(all, function(x, y) return math.abs(x.power - target) < math.abs(y.power - target) end)
    for i = 1, math.min(#all, 12) do
      if isInstalled(all[i]) then return all[i] end
    end
  end

  local list = roster.slots['rivals_tier' .. tostring(tier)] or {}
  for _ = 1, 10 do
    local entry = list[math.random(#list)]
    if entry and isInstalled(entry) then return entry end
  end
  return getSlotVehicle('starter')
end

-- Headlights on, and quick arcade shifting so manual cars do not fumble the launch.
local function prepareRival(id)
  local veh = id and getObjectByID(id)
  if veh then
    veh:queueLuaCommand('electrics.setLightsState(2) if controller.mainController and controller.mainController.setGearboxMode then controller.mainController.setGearboxMode("arcade") end')
  end
end

-- Spawns a rival car at pos facing dir, without taking the player out of their car.
-- Returns the vehicle id, or nil.
local function spawnRival(entry, pos, dir)
  local rot = quatFromDir(dir, upVec)
  local veh = core_vehicles.spawnNewVehicle(entry.model, {
    config = entry.config,
    pos = pos,
    rot = rot,
    autoEnterVehicle = false,
    canSpawnAnotherVehicleCheck = false,
    removeTraffic = false,
  })
  if not veh then
    log('E', logTag, 'Could not spawn rival ' .. tostring(entry.model) .. ' / ' .. tostring(entry.config))
    return nil
  end
  spawn.safeTeleport(veh, pos, rot, nil, nil, false)
  prepareRival(veh:getID())
  return veh:getID()
end

local function removeVehicle(id)
  local veh = id and getObjectByID(id)
  if veh then veh:delete() end
end

local function spawnStarter()
  if isCareer() then
    notify('In career, buy your starter car from a dealership.')
    return
  end
  local entry = getSlotVehicle('starter')
  if not entry then
    notify('No starter car is installed.')
    return
  end
  core_vehicles.replaceVehicle(entry.model, {config = entry.config})
  notify('Starter car: ' .. (entry.name or entry.model))
end

-- events -------------------------------------------------------------------

local function beginEvent(name)
  if not active then
    notify('The streets are closed. Switch Belasco Nights on first.')
    return false
  end
  if currentEvent then
    notify('Finish or abort the current event first.')
    return false
  end
  if not getPlayerVehicle(0) then
    notify('You need a car.')
    return false
  end
  currentEvent = name
  return true
end

local function endEvent(name)
  if currentEvent == name then currentEvent = nil end
end

local function isEventRunning()
  return currentEvent ~= nil
end

local function abortEvent()
  if not currentEvent then return end
  local ext = extensions['belasconights_' .. currentEvent]
  currentEvent = nil
  if ext and ext.abort then ext.abort() end
end

-- night mode ---------------------------------------------------------------

-- Holds the clock at night. If it is already night the time is kept and only
-- stopped, so a forced-on scene never runs into dawn.
local function forceNight(alreadyNight)
  local tod = core_environment.getTimeOfDay()
  if not tod then return end
  forcedTime = {time = tod.time, play = tod.play}
  if not alreadyNight then tod.time = getConfig().nightTime or 0.5 end
  tod.play = false
  core_environment.setTimeOfDay(tod)
end

local function restoreTime()
  if not forcedTime then return end
  local tod = core_environment.getTimeOfDay()
  if tod then
    tod.time = forcedTime.time
    tod.play = forcedTime.play
    core_environment.setTimeOfDay(tod)
  end
  forcedTime = nil
end

local function startTraffic()
  local amount = getConfig().freeroamTrafficAmount or 0
  if isCareer() or amount <= 0 then return end
  local traffic = extensions.gameplay_traffic
  if traffic and traffic.getState() == 'off' then
    -- traffic is a nicety: if the game cannot spawn it, the scene still opens
    local ok, err = pcall(traffic.setupTraffic, amount)
    if ok then
      spawnedTraffic = true
    else
      log('W', logTag, 'Could not start traffic: ' .. tostring(err))
    end
  end
end

local function stopTraffic()
  if spawnedTraffic and gameplay_traffic then
    gameplay_traffic.deleteVehicles()
  end
  spawnedTraffic = false
end

-- night look ---------------------------------------------------------------
-- Stock nights are close to pitch black. While the streets are open the sky's
-- night ambient light is raised and tinted blue-violet, so the road and scenery
-- are readable without losing the night feel. The level's own value is put back
-- when the streets close.

local lookLevels = {'off', 'low', 'medium', 'high'}
local originalNightColor = nil

local function getLookLevel()
  return getSetting('nightBrightness') or getConfig().nightBrightness or 'medium'
end

local function findSky()
  local names = scenetree.findClassObjects('ScatterSky')
  return names and names[1] and scenetree.findObject(names[1]) or nil
end

local function restoreLook()
  local sky = originalNightColor and findSky()
  if sky then
    sky:setField('nightColor', 0, originalNightColor)
    sky:postApply()
  end
  originalNightColor = nil
end

local function applyLook()
  local color = (getConfig().nightColors or {})[getLookLevel()]
  if not color then
    restoreLook()
    return
  end
  local sky = findSky()
  if not sky then return end
  originalNightColor = originalNightColor or sky:getField('nightColor', 0)
  sky:setField('nightColor', 0, color)
  sky:postApply()
end

local function cycleLook()
  local current = getLookLevel()
  local nextLevel = lookLevels[1]
  for i, level in ipairs(lookLevels) do
    if level == current then nextLevel = lookLevels[i % #lookLevels + 1] end
  end
  setSetting('nightBrightness', nextLevel)
  if active then applyLook() end
  notify('Night brightness: ' .. nextLevel, 4)
end

-- music --------------------------------------------------------------------
-- Plays every .ogg in /belascoNights/music/ in shuffled order while the streets are open.

local musicSourceId = nil
local musicQueue = {}

local function stopMusic()
  if musicSourceId then
    local source = scenetree.findObjectById(musicSourceId)
    if source then source:stop(-1) end
    Engine.Audio.deleteSource(musicSourceId)
    musicSourceId = nil
  end
end

local function playNextTrack()
  stopMusic()
  if #musicQueue == 0 then
    musicQueue = FS:findFiles(dataDir .. 'music/', '*.ogg', 0, false, false) or {}
    for i = #musicQueue, 2, -1 do
      local j = math.random(i)
      musicQueue[i], musicQueue[j] = musicQueue[j], musicQueue[i]
    end
  end
  local track = table.remove(musicQueue)
  if not track then return end
  musicSourceId = Engine.Audio.createSource('AudioMusic', track)
  local source = musicSourceId and scenetree.findObjectById(musicSourceId)
  if not source then
    musicSourceId = nil
    return
  end
  source:setVolume(getConfig().musicVolume or 0.6)
  source:play(-1)
  log('I', logTag, 'Music: ' .. track)
end

local function updateMusic()
  if not active or getConfig().music == false then
    stopMusic()
    return
  end
  local source = musicSourceId and scenetree.findObjectById(musicSourceId)
  if not source or not source:isPlaying() then playNextTrack() end
end

local function setActive(state)
  if active == state then return end
  active = state
  if state then
    log('I', logTag, 'Street scene on')
    notify('Belasco Nights: the streets are open. ' .. getStatusText(), 8)
    applyLook()
    startTraffic()
    extensions.hook('onBelascoNightsStart')
    checkStory()
  else
    log('I', logTag, 'Street scene off')
    abortEvent()
    stopTraffic()
    restoreLook()
    notify('Belasco Nights: the streets go quiet.', 6)
    extensions.hook('onBelascoNightsEnd')
  end
end

local function refresh()
  local lightState = core_environment.getLightState()
  if not lightState then return end -- no TimeOfDay, e.g. main menu
  local night = lightState.isNight == true
  if manual == false and not night then manual = nil end -- forced-off only lasts until dawn
  if manual ~= nil then
    setActive(manual)
  else
    setActive(night)
  end
  updateMusic()
end

-- Manual switch. In career the clock is not ours to change, so the mode only follows it.
local function toggle()
  local lightState = core_environment.getLightState()
  if not lightState then return end
  if isCareer() then
    notify(active and ('Belasco Nights is on. ' .. getStatusText()) or 'In career the streets open when night falls.')
    return
  end
  if active then
    if forcedTime then
      restoreTime()
      manual = nil
    else
      manual = false
    end
    setActive(false)
  else
    manual = true
    forceNight(lightState.isNight == true)
    setActive(true)
  end
end

local function isActive()
  return active
end

-- radial menu --------------------------------------------------------------

local function registerMenu()
  if menuRegistered or not core_quickAccess then return end
  menuRegistered = true
  core_quickAccess.addEntry({
    level = '/root/sandbox/', title = 'Belasco Nights', icon = 'flag', uniqueID = 'belasconights',
    categoryOrder = 40, ['goto'] = '/root/sandbox/belasconights/'
  })
  -- the uniqueID makes a second registration (after a Lua reload) replace the first
  core_quickAccess.addEntry({level = '/root/sandbox/belasconights/', uniqueID = 'belasconights_entries', generator = function(entries)
    if not isCareer() then
      table.insert(entries, {
        title = active and 'Night mode off' or 'Night mode on', icon = 'trafficLight', uniqueID = 'belasconights_toggle',
        onSelect = function() toggle() return {'hide'} end
      })
    end
    if active and not currentEvent then
      table.insert(entries, {
        title = 'Start sprint race', icon = 'routeSimpleFlag', uniqueID = 'belasconights_sprint',
        onSelect = function() belasconights_sprint.start() return {'hide'} end
      })
      table.insert(entries, {
        title = 'Start outrun', icon = 'carsChase', uniqueID = 'belasconights_outrun',
        onSelect = function() belasconights_outrun.start() return {'hide'} end
      })
    end
    if currentEvent then
      table.insert(entries, {
        title = 'Abort event', icon = 'flag', uniqueID = 'belasconights_abort',
        onSelect = function() abortEvent() return {'hide'} end
      })
    end
    if not isCareer() and not currentEvent then
      table.insert(entries, {
        title = 'Get starter car', icon = 'carPlus', uniqueID = 'belasconights_starter',
        onSelect = function() spawnStarter() return {'hide'} end
      })
    end
    if not isCareer() and not currentEvent and belasconights_garage then
      local near = belasconights_garage.getNearest()
      table.insert(entries, {
        title = belasconights_garage.isAtGarage() and 'Garage' or (near and string.format('Garage (%d m)', near.dist) or 'Garage'),
        icon = 'wrench', uniqueID = 'belasconights_garage',
        -- at a garage the shop is a radial submenu, so it works on a controller
        onSelect = function()
          if belasconights_garage.isAtGarage() then return {'goto', belasconights_garage.menuLevel} end
          belasconights_garage.open()
          return {'hide'}
        end
      })
    end
    if active then
      table.insert(entries, {
        title = 'Brightness: ' .. getLookLevel(), icon = 'trafficLight', uniqueID = 'belasconights_look',
        onSelect = function() cycleLook() return {'reload'} end
      })
    end
    table.insert(entries, {
      title = 'Status', icon = 'cup', uniqueID = 'belasconights_status',
      onSelect = function() notify(getStatusText(), 8) return {'hide'} end
    })
  end})
end

-- game hooks ---------------------------------------------------------------

local function onUpdate(dtReal)
  checkTimer = checkTimer + dtReal
  if checkTimer < checkInterval then return end
  checkTimer = 0
  refresh()
end

local function resetLevelState()
  stopMusic()
  originalNightColor = nil
  active = false
  manual = nil
  forcedTime = nil
  spawnedTraffic = false
  currentEvent = nil
end

local function onClientStartMission()
  resetLevelState()
  checkTimer = checkInterval
end

local function onClientEndMission()
  if active then extensions.hook('onBelascoNightsEnd') end
  resetLevelState()
end

local function onQuickAccessLoaded()
  menuRegistered = false
  registerMenu()
end

local function onExtensionLoaded()
  loadData()
  log('I', logTag, 'Belasco Nights core loaded')
end

M.onUpdate = onUpdate
M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientEndMission
M.onBeforeRadialOpened = registerMenu
M.onQuickAccessLoaded = onQuickAccessLoaded
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = function()
  stopMusic()
  restoreLook()
end

M.toggle = toggle
M.isActive = isActive
M.isCareer = isCareer
M.getConfig = getConfig
M.getTier = getTier
M.getStatusText = getStatusText
M.getSlotVehicle = getSlotVehicle
M.pickRival = pickRival
M.prepareRival = prepareRival
M.getPlayerPower = getPlayerPower
M.spawnRival = spawnRival
M.removeVehicle = removeVehicle
M.spawnStarter = spawnStarter
M.reward = reward
M.addStat = addStat
M.getSetting = getSetting
M.cycleLook = cycleLook
M.setSetting = setSetting
M.getCash = getCash
M.spend = spend
M.isEventRunning = isEventRunning
M.notify = notify
M.flash = flash
M.beginEvent = beginEvent
M.endEvent = endEvent
M.abortEvent = abortEvent

return M
