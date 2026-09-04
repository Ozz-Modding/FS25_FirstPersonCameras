---
-- FPCSettings
--
-- Settings store for First Person Cameras, plus the controls that get injected
-- into the base game's Settings page.
--
-- Values live in modSettings/FS25_FirstPersonCameras.xml under the user profile,
-- so they are per-player and survive across savegames. Everything here is purely
-- cosmetic, so nothing is server-authoritative and nothing is synced.
---

FPCSettings = {}
FPCSettings.CONTROLS = {}
FPCSettings.SETTINGS_FILE = "modSettings/FS25_FirstPersonCameras.xml"
FPCSettings.XML_ROOT = "firstPersonCameras"

-- Order the options appear in the settings page
FPCSettings.menuItems = {
    "walkEnabled",
    "walkBobScale",
    "walkSwayScale",
    "walkLandingScale",
    "vehicleEnabled",
    "vehicleSeatScale",
    "vehicleHeadScale",
    "vehicleEngineScale",
    "vehicleOutsideCameras",
}

local ON_OFF_VALUES = { true, false }
local ON_OFF_STRINGS = { "On", "Off" }

-- 0 means "this layer is off"; 1.0 is the tuned default
local SCALE_VALUES  = { 0, 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0 }
local SCALE_STRINGS = { "Off", "25%", "50%", "75%", "100%", "125%", "150%", "200%", "300%" }

local function scaleSetting(default)
    return { default = default, values = SCALE_VALUES, strings = SCALE_STRINGS }
end

local function boolSetting(default)
    return { default = default, values = ON_OFF_VALUES, strings = ON_OFF_STRINGS }
end

FPCSettings.SETTINGS = {
    -- On foot
    walkEnabled      = boolSetting(true),
    walkBobScale     = scaleSetting(1.0),   -- footstep bob while moving
    walkSwayScale    = scaleSetting(1.0),   -- handheld drift + breathing
    walkLandingScale = scaleSetting(1.0),   -- knee bend on landing

    -- In vehicle
    vehicleEnabled        = boolSetting(true),
    vehicleSeatScale      = scaleSetting(1.0),  -- seat travel (up/down, side, fore/aft)
    vehicleHeadScale      = scaleSetting(1.0),  -- head pitch/roll/yaw lag
    vehicleEngineScale    = scaleSetting(1.0),  -- engine vibration through the seat
    vehicleOutsideCameras = boolSetting(false), -- also apply to the outdoor cameras
}

-- Live values. Seeded from the defaults, overwritten by readSettings().
FPCSettings.settings = {}
for id, def in pairs(FPCSettings.SETTINGS) do
    FPCSettings.settings[id] = def.default
end

function FPCSettings.get(id)
    return FPCSettings.settings[id]
end

function FPCSettings.set(id, value)
    FPCSettings.settings[id] = value
    FPCSettings.writeSettings()

    local control = FPCSettings.CONTROLS[id]
    if control ~= nil and control.setState ~= nil then
        control:setState(FPCSettings.getStateIndex(id))
    end
end

function FPCSettings.toggle(id)
    FPCSettings.set(id, not FPCSettings.settings[id])
    return FPCSettings.settings[id]
end

function FPCSettings.getStateIndex(id, value)
    local setting = FPCSettings.SETTINGS[id]
    if setting == nil then
        return 1
    end

    if value == nil then
        value = FPCSettings.settings[id]
    end

    if type(value) == "number" then
        -- Snap to the closest listed value; a hand edited settings file can hold
        -- something that is not on the list.
        local bestIndex, bestDiff = 1, math.huge
        for i, v in ipairs(setting.values) do
            local diff = math.abs(v - value)
            if diff < bestDiff then
                bestDiff, bestIndex = diff, i
            end
        end
        return bestIndex
    end

    for i, v in ipairs(setting.values) do
        if v == value then
            return i
        end
    end

    return 1
end

-- READ / WRITE ---------------------------------------------------------------

function FPCSettings.writeSettings()
    local path = Utils.getFilename(FPCSettings.SETTINGS_FILE, getUserProfileAppPath())
    local xmlFile = createXMLFile("fpcSettings", path, FPCSettings.XML_ROOT)
    if xmlFile == 0 then
        return
    end

    for _, id in ipairs(FPCSettings.menuItems) do
        local key = FPCSettings.XML_ROOT .. "." .. id .. "#value"
        local value = FPCSettings.settings[id]
        if type(value) == "number" then
            setXMLFloat(xmlFile, key, value)
        elseif type(value) == "boolean" then
            setXMLBool(xmlFile, key, value)
        end
    end

    saveXMLFile(xmlFile)
    delete(xmlFile)
end

function FPCSettings.readSettings()
    local path = Utils.getFilename(FPCSettings.SETTINGS_FILE, getUserProfileAppPath())
    if not fileExists(path) then
        FPCSettings.writeSettings()
        return
    end

    local xmlFile = loadXMLFile("fpcSettings", path)
    if xmlFile == 0 then
        return
    end

    for _, id in ipairs(FPCSettings.menuItems) do
        local key = FPCSettings.XML_ROOT .. "." .. id .. "#value"
        if hasXMLProperty(xmlFile, key) then
            local current = FPCSettings.settings[id]
            if type(current) == "number" then
                FPCSettings.settings[id] = getXMLFloat(xmlFile, key) or current
            elseif type(current) == "boolean" then
                local value = getXMLBool(xmlFile, key)
                if value ~= nil then
                    FPCSettings.settings[id] = value
                end
            end
        end
    end

    delete(xmlFile)
end

-- SETTINGS PAGE --------------------------------------------------------------

FPCSettingsControls = {}

function FPCSettingsControls.onMenuOptionChanged(_, state, menuOption)
    local id = menuOption.id
    local setting = FPCSettings.SETTINGS[id]
    if setting == nil then
        return
    end

    local value = setting.values[state]
    if value ~= nil then
        FPCSettings.settings[id] = value
        FPCSettings.writeSettings()
    end
end

-- clone() copies focus ids, which are supposed to be unique, so re-serve them
local function updateFocusIds(element)
    if element == nil then
        return
    end
    element.focusId = FocusManager:serveAutoFocusId()
    for _, child in pairs(element.elements) do
        updateFocusIds(child)
    end
end

function FPCSettings.addSettingsToMenu()
    local inGameMenu = g_gui.screenControllers[InGameMenu]
    if inGameMenu == nil then
        return
    end

    local settingsPage = inGameMenu.pageSettings
    -- The focus manager ignores controls whose callback target has no name, and it
    -- has to match the page, so borrow the page's name.
    FPCSettingsControls.name = settingsPage.name

    local function addMultiOption(id)
        local originalBox = settingsPage.multiVolumeVoiceBox
        local menuOptionBox = originalBox:clone(settingsPage.gameSettingsLayout)
        menuOptionBox.id = id .. "box"

        local menuMultiOption = menuOptionBox.elements[1]
        menuMultiOption.id = id
        menuMultiOption.target = FPCSettingsControls
        menuMultiOption:setCallback("onClickCallback", "onMenuOptionChanged")
        menuMultiOption:setDisabled(false)

        local toolTip = menuMultiOption.elements[1]
        toolTip:setText(g_i18n:getText("fpc_setting_" .. id .. "_tooltip"))

        local label = menuOptionBox.elements[2]
        label:setText(g_i18n:getText("fpc_setting_" .. id))

        menuMultiOption:setTexts({ table.unpack(FPCSettings.SETTINGS[id].strings) })
        menuMultiOption:setState(FPCSettings.getStateIndex(id))

        FPCSettings.CONTROLS[id] = menuMultiOption

        updateFocusIds(menuOptionBox)
        table.insert(settingsPage.controlsList, menuOptionBox)
        return menuOptionBox
    end

    -- Section header, cloned from an existing one so it picks up the right profile
    local sectionTitle
    for _, elem in ipairs(settingsPage.gameSettingsLayout.elements) do
        if elem.name == "sectionHeader" then
            sectionTitle = elem:clone(settingsPage.gameSettingsLayout)
            break
        end
    end

    if sectionTitle == nil then
        sectionTitle = TextElement.new()
        sectionTitle:applyProfile("fs25_settingsSectionHeader", true)
        sectionTitle.name = "sectionHeader"
        settingsPage.gameSettingsLayout:addElement(sectionTitle)
    end

    sectionTitle:setText(g_i18n:getText("fpc_setting_section"))
    sectionTitle.focusId = FocusManager:serveAutoFocusId()
    table.insert(settingsPage.controlsList, sectionTitle)
    FPCSettings.CONTROLS["fpcSectionHeader"] = sectionTitle

    for _, id in ipairs(FPCSettings.menuItems) do
        addMultiOption(id)
    end

    settingsPage.gameSettingsLayout:invalidateLayout()

    InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(InGameMenuSettingsFrame.onFrameOpen, function()
        for _, id in ipairs(FPCSettings.menuItems) do
            local control = FPCSettings.CONTROLS[id]
            if control ~= nil then
                control:setState(FPCSettings.getStateIndex(id))
            end
        end
    end)
end

-- Let the focus manager see our controls when the settings page opens
FocusManager.setGui = Utils.appendedFunction(FocusManager.setGui, function(_, gui)
    if gui ~= "ingameMenuSettings" then
        return
    end

    for _, control in pairs(FPCSettings.CONTROLS) do
        if not control.focusId or not FocusManager.currentFocusData.idToElementMapping[control.focusId] then
            FocusManager:loadElementFromCustomValues(control, nil, nil, false, false)
        end
    end

    local settingsPage = g_gui.screenControllers[InGameMenu].pageSettings
    settingsPage.gameSettingsLayout:invalidateLayout()
end)
