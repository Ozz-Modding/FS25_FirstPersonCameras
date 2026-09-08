---
-- FS25_FirstPersonCameras
--
-- Two independent first person camera effects, each with its own keybind:
--
--   On foot   - src/WalkCamera.lua
--   In vehicle - src/VehicleSeat.lua
--
-- This file owns the hooks and the keybinds. Both effects are client side and
-- purely visual: no state is synced, nothing runs on a dedicated server.
---

FirstPersonCameras = {}
FirstPersonCameras.MOD_NAME = g_currentModName
FirstPersonCameras.actionEventIds = {}

local function log(...)
    print("[FirstPersonCameras] " .. string.format(...))
end

local function notify(text)
    if g_currentMission ~= nil and g_currentMission.hud ~= nil then
        g_currentMission:showBlinkingWarning(text, 2500)
    end
    log("%s", text)
end

function FirstPersonCameras:loadMap()
    g_currentMission.FirstPersonCameras = self

    -- Has to happen once the engine is up, before the first camera update
    VehicleSeat.calibrateRotationSigns()

    addConsoleCommand("fpcDebug", "Toggle the First Person Cameras seat readout",
        "consoleCommandDebug", VehicleSeat)

    log("loaded - on foot: %s, in vehicle: %s",
        tostring(FPCSettings.get("walkEnabled")),
        tostring(FPCSettings.get("vehicleEnabled")))
end

function FirstPersonCameras:draw()
    VehicleSeat.drawDebug()
end

function FirstPersonCameras:deleteMap()
    if g_currentMission ~= nil then
        g_currentMission.FirstPersonCameras = nil
    end
end

-- KEYBINDS --------------------------------------------------------------

function FirstPersonCameras.onToggleWalk()
    local enabled = FPCSettings.toggle("walkEnabled")
    if not enabled and g_localPlayer ~= nil then
        WalkCamera.reset(g_localPlayer.camera)
    end
    notify(g_i18n:getText(enabled and "fpc_walk_on" or "fpc_walk_off"))
end

function FirstPersonCameras.onToggleVehicle()
    local enabled = FPCSettings.toggle("vehicleEnabled")
    notify(g_i18n:getText(enabled and "fpc_vehicle_on" or "fpc_vehicle_off"))
end

-- Runs twice - on-foot context, then vehicle context on entry - so it's the one
-- place to register a binding that has to work in both.
PlayerInputComponent.registerGlobalPlayerActionEvents = Utils.overwrittenFunction(
    PlayerInputComponent.registerGlobalPlayerActionEvents,
    function(self, superFunc, context, ...)
        superFunc(self, context, ...)

        if not self.player.isOwner then
            return
        end

        -- superFunc switches context back before returning; re-enter the target
        -- context or our bindings land wherever happened to be current.
        local targetContext = context or g_inputBinding:getContextName()
        local previousContext = g_inputBinding:getContextName()
        if previousContext ~= targetContext then
            g_inputBinding:beginActionEventsModification(targetContext)
        end

        local _, walkId = g_inputBinding:registerActionEvent(
            InputAction.FPC_TOGGLE_WALK, self, FirstPersonCameras.onToggleWalk,
            false, true, false, true)
        g_inputBinding:setActionEventTextVisibility(walkId, false)
        FirstPersonCameras.actionEventIds.walk = walkId

        local _, vehicleId = g_inputBinding:registerActionEvent(
            InputAction.FPC_TOGGLE_VEHICLE, self, FirstPersonCameras.onToggleVehicle,
            false, true, false, true)
        g_inputBinding:setActionEventTextVisibility(vehicleId, false)
        FirstPersonCameras.actionEventIds.vehicle = vehicleId

        if previousContext ~= targetContext then
            g_inputBinding:beginActionEventsModification(previousContext)
        end
    end
)

-- HOOKS -------------------------------------------------------------------

-- Last thing the on-foot state machine does to the camera each frame, so we run
-- after it's placed and before render.
PlayerCamera.updatePosition = Utils.appendedFunction(PlayerCamera.updatePosition,
    function(self, dt)
        if self.player == nil or not self.player.isOwner then
            return
        end
        WalkCamera.update(self, dt)
    end
)

-- Fires at most once a frame - only the active vehicle camera updates (see
-- Enterable:onPostUpdate).
--
-- Installed from onStartMission, not file scope: Indoor Camera Position
-- replaces VehicleCamera.update wholesale without calling superFunc, dropping
-- anything hooked before it loads. onStartMission runs last before you get
-- control, so appending there survives whatever chain is left.
FSBaseMission.onStartMission = Utils.prependedFunction(FSBaseMission.onStartMission,
    function()
        VehicleCamera.update = Utils.appendedFunction(VehicleCamera.update,
            function(self, dt)
                VehicleSeat.update(self, dt)
            end
        )
    end
)

Mission00.load = Utils.appendedFunction(Mission00.load, function()
    FPCSettings.readSettings()
    FPCSettings.addSettingsToMenu()
end)

addModEventListener(FirstPersonCameras)
