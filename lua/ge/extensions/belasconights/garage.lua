-- Belasco Nights garage: a parts shop that spends the mod's own cash. It opens
-- at any of the level's garage facilities, so there is nothing to place by hand.
-- Freeroam only: career mode has its own garages and part shopping.

local M = {}
M.dependencies = {'belasconights_core'}

local im = ui_imgui
local jbeamIO = require('jbeam/io')

local logTag = 'belasconights'
local checkInterval = 1

local garages = nil       -- {name, pos} for the current level
local nearest = nil       -- {name, pos, dist} closest garage to the player
local atGarage = false
local checkTimer = 0

local windowOpen = im.BoolPtr(false)
local searchBuf = im.ArrayChar(128)
local shop = nil          -- cached view of the player's parts tree
local rebuildIn = nil     -- seconds until the shop is rebuilt after a respawn
local resizeWindow = true -- apply the scaled window size on the next frame

local green = im.ImVec4(0.4, 1, 0.5, 1)
local grey = im.ImVec4(0.6, 0.6, 0.6, 1)
local cyan = im.ImVec4(0.3, 0.9, 1, 1)

local function core()
  return belasconights_core
end

local function getCfg()
  return core().getConfig().garage or {}
end

-- locations ----------------------------------------------------------------

local function loadGarages()
  garages = {}
  if not freeroam_facilities then return end
  for _, facility in ipairs(freeroam_facilities.getFacilitiesByType('garage') or {}) do
    local pos = freeroam_facilities.getAverageDoorPositionForFacility(facility)
    if pos then table.insert(garages, {name = facility.name or facility.id, pos = vec3(pos)}) end
  end
end

local function updateNearest()
  if not garages then loadGarages() end
  local veh = getPlayerVehicle(0)
  nearest = nil
  if not veh then return end
  local pos = vec3(veh:getPosition())
  for _, garage in ipairs(garages) do
    local dist = garage.pos:distance(pos)
    if not nearest or dist < nearest.dist then nearest = {name = garage.name, pos = garage.pos, dist = dist} end
  end
end

-- shop data ----------------------------------------------------------------

-- Part and slot names are usually plain strings, but some are translation
-- tables; fall back to the next candidate for those.
local function text(...)
  for i = 1, select('#', ...) do
    local candidate = select(i, ...)
    if type(candidate) == 'string' and candidate ~= '' then return candidate end
  end
  return '?'
end

local function partPrice(value)
  return math.floor((value or 100) * (getCfg().priceFactor or 1) / 5 + 0.5) * 5
end

-- Builds a display copy of the parts tree: every slot that has something to
-- choose from, with names and prices looked up once rather than every frame.
local function buildShop()
  shop = nil
  local veh = getPlayerVehicle(0)
  local vehData = veh and core_vehicle_manager.getVehicleData(veh:getID())
  if not vehData or not vehData.config or not vehData.config.partsTree then return end
  local available = jbeamIO.getAvailableParts(vehData.ioCtx)

  local function partInfo(name)
    local part = jbeamIO.getPart(vehData.ioCtx, name)
    local info = part and part.information or {}
    return {
      name = name,
      label = text(info.name, available[name] and available[name].description, name),
      value = tonumber(info.value) or 100,
    }
  end

  local flat = {}
  local function convert(node, slotName, parentPartName)
    local slotUi = parentPartName and available[parentPartName] and available[parentPartName].slotInfoUi
    local slotLabel = text(slotUi and slotUi[slotName] and slotUi[slotName].description, slotName)
    local entry = {
      path = node.path,
      slotLabel = slotLabel,
      chosen = node.chosenPartName ~= '' and node.chosenPartName and partInfo(node.chosenPartName) or nil,
      options = {},
      children = {},
    }
    for _, name in ipairs(node.suitablePartNames or {}) do
      if name ~= node.chosenPartName then table.insert(entry.options, partInfo(name)) end
    end
    table.sort(entry.options, function(a, b) return a.value < b.value end)
    entry.search = string.lower(slotLabel .. ' ' .. (entry.chosen and entry.chosen.label or ''))
    for _, option in ipairs(entry.options) do entry.search = entry.search .. ' ' .. string.lower(option.label) end

    local names = tableKeys(node.children or {})
    table.sort(names)
    for _, childSlot in ipairs(names) do
      local child = convert(node.children[childSlot], childSlot, node.chosenPartName)
      if child then table.insert(entry.children, child) end
    end
    table.sort(entry.children, function(a, b) return a.slotLabel < b.slotLabel end)

    if #entry.options == 0 and #entry.children == 0 then return nil end
    if #entry.options > 0 then table.insert(flat, entry) end
    return entry
  end

  local root = convert(vehData.config.partsTree, 'main', nil)
  if not root then return end
  table.sort(flat, function(a, b) return a.slotLabel < b.slotLabel end)
  local details = core_vehicles.getCurrentVehicleDetails()
  shop = {
    vehId = veh:getID(),
    root = root,
    flat = flat,
    carName = text(details and details.configs and details.configs.Name, details and details.model and details.model.Name, veh.jbeam),
  }
end

local function findNode(node, path)
  if node.path == path then return node end
  for _, child in pairs(node.children or {}) do
    local found = findNode(child, path)
    if found then return found end
  end
  return nil
end

-- Price of fitting an option in place of what is there now: the old part is
-- taken in part exchange, but never for more than the new one costs.
local function swapCost(entry, option)
  local credit = entry.chosen and partPrice(entry.chosen.value) * (getCfg().tradeIn or 0.5) or 0
  return math.max(0, math.floor((partPrice(option.value) - credit) / 5 + 0.5) * 5)
end

local function buy(entry, option)
  local cost = swapCost(entry, option)
  local veh = getPlayerVehicle(0)
  local vehData = veh and core_vehicle_manager.getVehicleData(veh:getID())
  if not vehData then return end
  local tree = deepcopy(vehData.config.partsTree)
  local node = findNode(tree, entry.path)
  if not node then return end
  if not core().spend(cost, option.label) then return end

  node.chosenPartName = option.name
  node.children = {} -- the new part brings its own slots; the game fills them with defaults
  core_vehicle_partmgmt.setPartsTreeConfig(tree, true)
  log('I', logTag, string.format('Garage: fitted %s for $%d', option.name, cost))
  core().notify(string.format('Fitted: %s  (-$%d)', option.label, cost), 5)
  shop = nil
  rebuildIn = 0.5
  if getCfg().autoSaveBuild ~= false then M.saveBuildIn = 2 end
end

local function repair()
  local price = getCfg().repairPrice or 200
  if not core().spend(price, 'Repair') then return end
  be:resetVehicle(0)
  core().notify(string.format('Repaired  (-$%d)', price), 4)
end

-- window -------------------------------------------------------------------

-- The window is drawn with the game's debug UI, whose text is sized for 1080p.
-- Scale it with the screen so it stays readable at 1440p and 4K; the A- / A+
-- buttons adjust it from there and the choice is kept with the save.
local function getScale()
  local saved = core().getSetting('garageTextScale')
  if saved then return saved end
  local viewport = im.GetMainViewport()
  local height = viewport and viewport.Size.y or 1080
  return math.max(1.25, math.min(4, height / 1080 * (getCfg().textScale or 1.3)))
end

local function changeScale(delta)
  core().setSetting('garageTextScale', math.max(1, math.min(4, getScale() + delta)))
  resizeWindow = true
end

local function drawOptions(entry)
  local cash = core().getCash()
  if entry.chosen then
    im.TextColored(green, 'Fitted: ' .. entry.chosen.label)
  else
    im.TextColored(grey, 'Fitted: nothing')
  end
  for i, option in ipairs(entry.options) do
    local cost = swapCost(entry, option)
    im.PushID1(entry.path .. tostring(i))
    if cost > cash then im.BeginDisabled() end
    if im.Button('Fit') then buy(entry, option) end
    if cost > cash then im.EndDisabled() end
    im.PopID()
    im.SameLine()
    im.Text(string.format('$%d', cost))
    im.SameLine()
    im.Text(option.label)
  end
end

local function drawNode(entry)
  local label = entry.slotLabel
  if entry.chosen then label = label .. ':  ' .. entry.chosen.label end
  if im.TreeNode1(label .. '##' .. entry.path) then
    if #entry.options > 0 then drawOptions(entry) end
    for _, child in ipairs(entry.children) do drawNode(child) end
    im.TreePop()
  end
end

local function drawWindow()
  local scale = getScale()
  if resizeWindow then
    local viewport = im.GetMainViewport()
    local maxW = viewport and viewport.Size.x * 0.9 or 1700
    local maxH = viewport and viewport.Size.y * 0.9 or 950
    im.SetNextWindowSize(im.ImVec2(math.min(620 * scale, maxW), math.min(520 * scale, maxH)), im.Cond_Always)
    resizeWindow = false
  end
  if im.Begin('Belasco Nights Garage', windowOpen) then
    im.SetWindowFontScale(scale)
    if not shop then
      im.Text('Getting the car on the lift...')
    else
      im.TextColored(cyan, shop.carName or 'Your car')
      im.SameLine()
      im.TextColored(green, string.format('   Cash: $%d', core().getCash()))
      local repairPrice = getCfg().repairPrice or 200
      if core().getCash() < repairPrice then im.BeginDisabled() end
      if im.Button(string.format('Repair car  ($%d)', repairPrice)) then repair() end
      if core().getCash() < repairPrice then im.EndDisabled() end
      im.SameLine()
      if im.Button('Save build') then M.saveBuild(true) end
      im.SameLine()
      if im.Button('A-') then changeScale(-0.25) end
      im.SameLine()
      if im.Button('A+') then changeScale(0.25) end
      im.TextWrapped('Your old part is taken in part exchange. Fitting a part rebuilds the car, which also repairs it.')
      im.Separator()
      im.SetNextItemWidth(260 * scale)
      im.InputText('Search parts', searchBuf, 128)
      local filter = string.lower(ffi.string(searchBuf))
      im.BeginChild1('belasconightsParts', im.ImVec2(0, 0), true)
      im.SetWindowFontScale(scale)
      if filter ~= '' then
        local shown = 0
        for _, entry in ipairs(shop.flat) do
          if shown < 60 and string.find(entry.search, filter, 1, true) then
            shown = shown + 1
            im.TextColored(cyan, entry.slotLabel)
            drawOptions(entry)
            im.Separator()
          end
        end
        if shown == 0 then im.Text('Nothing matches.') end
      else
        for _, child in ipairs(shop.root.children) do drawNode(child) end
      end
      im.EndChild()
    end
  end
  im.End()
end

-- radial menu ---------------------------------------------------------------
-- The same shop, driven entirely from the radial menu so it works on a
-- controller. One menu level is reused for every screen: `nav` says which slot
-- is being looked at, and picking an entry changes `nav` and reloads the level.

local menuLevel = '/root/sandbox/belasconights/garage/'
local pageSize = 6
local nav = {path = nil, options = false, page = 1}
local menuRegistered = false

local function navTo(path, options)
  nav.path = path
  nav.options = options or false
  nav.page = 1
  return {'reload'}
end

local function parentPath(path)
  local parent = string.match(path or '', '^(.*/)[^/]+/$')
  return parent
end

-- Adds one page of `items` to `entries`, with a "More" entry when there are further pages.
local function addPaged(entries, items)
  local pages = math.max(1, math.ceil(#items / pageSize))
  if nav.page > pages then nav.page = 1 end
  for i = (nav.page - 1) * pageSize + 1, math.min(nav.page * pageSize, #items) do
    table.insert(entries, items[i])
  end
  if pages > 1 then
    table.insert(entries, {
      title = string.format('More (%d/%d)', nav.page, pages), icon = 'arrowsShuffle', uniqueID = 'belasconights_garage_more',
      onSelect = function() nav.page = nav.page % pages + 1 return {'reload'} end
    })
  end
end

local function generateMenu(entries)
  if core().isCareer() then return end
  local range = getCfg().range or 30
  updateNearest()
  if not nearest or nearest.dist > range then
    table.insert(entries, {
      title = nearest and string.format('Route to garage (%d m)', nearest.dist) or 'No garage on this map', icon = 'wrench',
      uniqueID = 'belasconights_garage_route',
      onSelect = function() M.open() return {'hide'} end
    })
    return
  end
  local veh = getPlayerVehicle(0)
  if not shop or not veh or shop.vehId ~= veh:getID() then buildShop() end
  if not shop then
    table.insert(entries, {title = 'Car is on the lift, try again', icon = 'wrench', onSelect = function() return {'reload'} end})
    return
  end

  local node = nav.path and findNode(shop.root, nav.path) or shop.root
  if node == shop.root then nav.path = nil nav.options = false end
  local cash = core().getCash()
  local items = {}

  if nav.options and #node.options > 0 then
    -- parts that fit this slot
    for _, option in ipairs(node.options) do
      local cost = swapCost(node, option)
      table.insert(items, {
        title = string.format('$%d  %s', cost, option.label), icon = 'wrench',
        desc = cost > cash and 'Not enough cash' or ('Replaces: ' .. (node.chosen and node.chosen.label or 'nothing')),
        enabled = cost <= cash,
        onSelect = function()
          if cost > core().getCash() then
            core().notify(string.format('Not enough cash: %s costs $%d.', option.label, cost))
            return {'reload'}
          end
          buy(node, option)
          return {'hide'}
        end
      })
    end
  else
    if node == shop.root then
      local repairPrice = getCfg().repairPrice or 200
      table.insert(items, {
        title = string.format('Repair car ($%d)', repairPrice), icon = 'wrench',
        desc = string.format('Cash: $%d', cash),
        onSelect = function() repair() return {'hide'} end
      })
    elseif #node.options > 0 then
      table.insert(items, {
        title = 'Change: ' .. node.slotLabel, icon = 'wrench',
        desc = 'Fitted: ' .. (node.chosen and node.chosen.label or 'nothing'),
        onSelect = function() return navTo(node.path, true) end
      })
    end
    for _, child in ipairs(node.children) do
      table.insert(items, {
        title = child.slotLabel, icon = 'carPlus',
        desc = child.chosen and child.chosen.label or 'Empty',
        -- a slot with nothing below it goes straight to its parts list
        onSelect = function() return navTo(child.path, #child.children == 0) end
      })
    end
  end

  addPaged(entries, items)
  if node ~= shop.root then
    table.insert(entries, {
      title = 'Up', icon = 'twoArrowsHorizontal', uniqueID = 'belasconights_garage_up',
      desc = string.format('Cash: $%d', cash),
      onSelect = function()
        if nav.options and #node.children > 0 then return navTo(node.path, false) end
        return navTo(parentPath(node.path), false)
      end
    })
  end
end

local function registerMenu()
  if menuRegistered or not core_quickAccess then return end
  menuRegistered = true
  core_quickAccess.addEntry({level = menuLevel, uniqueID = 'belasconights_garage_entries', generator = generateMenu})
end

local function onQuickAccessLoaded()
  menuRegistered = false
  registerMenu()
end

-- opening and closing ------------------------------------------------------

local function close()
  windowOpen[0] = false
  shop = nil
end

local function open()
  if core().isCareer() then
    core().notify('In career, use the career garages.')
    return
  end
  if core().isEventRunning() then
    core().notify('Finish the event first.')
    return
  end
  updateNearest()
  local range = getCfg().range or 30
  if not nearest then
    core().notify('This map has no garages.')
    return
  end
  if nearest.dist > range then
    core_groundMarkers.setPath(nearest.pos)
    core().notify(string.format('Nearest garage: %s, %d m away. Route set.', nearest.name, nearest.dist), 8)
    return
  end
  core_groundMarkers.setPath(nil)
  buildShop()
  resizeWindow = true
  windowOpen[0] = true
end

local function toggle()
  if windowOpen[0] then close() else open() end
end

-- Saves the car as a config called "belasco_nights" for its model, so the build
-- can be loaded again from the vehicle selector.
local function saveBuild(announce)
  if not getPlayerVehicle(0) then return end
  core_vehicle_partmgmt.saveLocal('belasco_nights.pc')
  if announce then core().notify('Build saved as the "belasco_nights" config for this car.', 6) end
end

-- hooks --------------------------------------------------------------------

local function onUpdate(dtReal)
  if M.saveBuildIn then
    M.saveBuildIn = M.saveBuildIn - dtReal
    if M.saveBuildIn <= 0 then
      M.saveBuildIn = nil
      saveBuild(false)
    end
  end
  if rebuildIn then
    rebuildIn = rebuildIn - dtReal
    if rebuildIn <= 0 then
      rebuildIn = nil
      if windowOpen[0] then buildShop() end
    end
  end

  checkTimer = checkTimer + dtReal
  if checkTimer >= checkInterval then
    checkTimer = 0
    if core().isCareer() then
      atGarage = false
    else
      updateNearest()
      local range = getCfg().range or 30
      local here = nearest ~= nil and nearest.dist <= range
      if here and not atGarage then
        core().notify(string.format('%s: open the radial menu, Belasco Nights, Garage.', nearest.name), 8, 'belasconights_garage')
        nav.path, nav.options, nav.page = nil, false, 1
      end
      atGarage = here
      -- drove off with the window open
      if windowOpen[0] and nearest and nearest.dist > range * 2 then close() end
    end
  end

  if windowOpen[0] then
    local veh = getPlayerVehicle(0)
    if shop and (not veh or veh:getID() ~= shop.vehId) then shop = nil rebuildIn = 0.5 end
    drawWindow()
  end
end

local function onVehicleSpawned(id)
  if windowOpen[0] and shop and id == shop.vehId then
    shop = nil
    rebuildIn = 0.5
  end
end

local function onClientStartMission()
  garages = nil
  nearest = nil
  atGarage = false
  close()
end

local function isAtGarage()
  return atGarage
end

local function getNearest()
  return nearest
end

M.onUpdate = onUpdate
M.onBeforeRadialOpened = registerMenu
M.onQuickAccessLoaded = onQuickAccessLoaded
M.menuLevel = menuLevel
M.onVehicleSpawned = onVehicleSpawned
M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientStartMission

M.open = open
M.close = close
M.toggle = toggle
M.saveBuild = saveBuild
M.isAtGarage = isAtGarage
M.getNearest = getNearest

return M
