---
-- VehicleSeat
--
-- Seat and body suspension for vehicle cameras.
--
-- In the base game the camera is bolted to the cab: the view moves exactly with
-- the vehicle, so a tractor crossing a rut just teleports the horizon. A real
-- seat is sprung, and the driver on it is a mass on top of that spring. This
-- reproduces both:
--
--   * SEAT   - three damped springs (up/down, side to side, fore/aft) driven by
--              the acceleration of the point the camera hangs off. Hit a bump
--              and the cab jumps up while the seat stays behind, then catches
--              up and overshoots slightly.
--   * HEAD   - three more springs driven by the angular acceleration of the
--              cab, so your head lags when the machine pitches and rolls, and
--              leans in a corner or under braking.
--   * ENGINE - a small vibration whose rate follows engine rpm and whose depth
--              follows load.
--
-- All of it is measured, not scripted: we finite-difference the mount node's
-- world transform. That means it works on every vehicle, including ones with no
-- suspension data of their own, and it picks up whatever wheel suspension,
-- articulation or cab damping the vehicle already has.
--
-- This is the same technique the base game's Suspensions specialization uses for
-- cab suspension nodes (see vehicles/specializations/Suspensions.lua), which
-- only a handful of vehicles define and which is off by default.
--
-- The result is applied after VehicleCamera:update has posed the camera, by
-- rebuilding the camera's world transform through a small node chain. The game
-- re-poses the camera from scratch every frame, so nothing accumulates.
---

VehicleSeat = {}

-- Seat springs. Frequency in Hz, zeta is the damping ratio, gain is how much of
-- the cab's acceleration the seat actually gives way to.
--
-- `gain` is the coefficient on the cab's acceleration in
--
--     x'' = -w^2 x - 2 zeta w x' - gain * a_cab
--
-- where x is the seat's position relative to the cab. For a mass on a spring
-- whose base is being shaken - which is exactly what a seat is - the textbook
-- coefficient is **1.0**. Anything less is a fudge that quietly makes the seat
-- stiffer than its stated frequency, and it was the reason the vertical axis
-- looked welded to the wheel: at 0.33 a firm bump moved the view 17 mm.
--
-- So vertical runs at the honest 1.0 and is held in check by `limit` instead.
-- Lateral and fore/aft keep a reduced gain on purpose: a seat barely slides in
-- those directions, what moves is your body, and you are braced against it.
VehicleSeat.SEAT = {
    -- 1.3 Hz and underdamped, which is where a real tractor air seat sits: it
    -- rebounds once rather than deadening the hit
    vertical   = { freq = 1.30, zeta = 0.32, gain = 1.00, limit = 0.10 },
    lateral    = { freq = 2.00, zeta = 0.50, gain = 0.50, limit = 0.06 },
    longitudinal = { freq = 1.90, zeta = 0.48, gain = 0.50, limit = 0.06 },
}

-- Vehicle transforms are written by the physics step, which does not line up
-- with the render frame. On frames between physics steps the cab has not moved
-- at all, so a raw double difference comes out as a spike train - zero, zero,
-- enormous - rather than a smooth acceleration. Low pass it before it reaches
-- the springs; the energy is the same but the springs get a signal they can
-- actually follow instead of a series of hammer blows.
VehicleSeat.ACCELERATION_FILTER_HZ = 18

-- Head springs, driven by angular acceleration. Radians. Around 1.5 degrees of
-- lean per 5 rad/s^2, which is a firm but not violent bump.
VehicleSeat.HEAD = {
    pitch = { freq = 1.45, zeta = 0.40, gain = 0.440, limit = 0.100 },  -- ~5.7 degrees
    roll  = { freq = 1.60, zeta = 0.42, gain = 0.540, limit = 0.110 },
    yaw   = { freq = 1.90, zeta = 0.55, gain = 0.290, limit = 0.060 },
}

-- Engine vibration.
--
-- Keep these low. Anything approaching half the frame rate aliases: the samples
-- walk around the waveform instead of tracing it, and what should be a fine
-- shimmer comes out as a violent random shake that no amount of turning the
-- amplitude down will fix. The second component is a sub-harmonic rather than a
-- harmonic for the same reason - it reads as an engine lope and cannot alias.
VehicleSeat.ENGINE_BASE_HZ = 4.5
VehicleSeat.ENGINE_RPM_HZ = 4.5            -- added on top at full rpm
VehicleSeat.ENGINE_MAX_SAMPLE_RATIO = 0.2  -- cap frequency at a fifth of the frame rate
VehicleSeat.ENGINE_IDLE_AMPLITUDE = 0.00045 -- metres
VehicleSeat.ENGINE_LOAD_AMPLITUDE = 0.00075 -- extra at full load
VehicleSeat.ENGINE_PITCH_RATIO = 0.20      -- radians of shake per metre

-- Guards. A physics hiccup or a teleport must not launch the springs.
VehicleSeat.MAX_ACCELERATION = 60          -- m/s^2 per axis
VehicleSeat.MAX_ANGULAR_ACCELERATION = 60  -- rad/s^2 per axis
VehicleSeat.TELEPORT_DISTANCE = 4          -- m moved in one frame
VehicleSeat.MAX_DT = 0.1                   -- s
VehicleSeat.WARMUP_FRAMES = 3              -- samples needed before the springs run

-- Live readout for the fpcDebug console command. Peaks are held and bled off so
-- a single bump stays on screen long enough to read.
VehicleSeat.debug = {
    enabled = false,
    peakDecay = 0.6,        -- per second
    frames = 0, stillFrames = 0, dt = 0,
    accX = 0, accY = 0, accZ = 0,
    angPitch = 0, angRoll = 0, angYaw = 0,
    seatX = 0, seatY = 0, seatZ = 0,
    headPitch = 0, headRoll = 0, headYaw = 0,
}

local function holdPeak(field, value, dts)
    local decayed = VehicleSeat.debug[field] * (1 - math.min(1, dts * VehicleSeat.debug.peakDecay))
    VehicleSeat.debug[field] = math.max(decayed, math.abs(value))
end

-- Set once, at load, by calibrateRotationSigns()
VehicleSeat.signX = 1
VehicleSeat.signY = 1
VehicleSeat.signZ = 1

---Work out which way setRotation turns things.
--
-- We measure the mount's orientation as three world referenced angles (how far
-- its forward axis is raised, how far its right axis is raised, which way it
-- points) and then have to feed the answer back through setRotation as Euler
-- angles. Rather than assume the engine's handedness, ask it: rotate a scratch
-- node by a known amount and see which way its axes went.
function VehicleSeat.calibrateRotationSigns()
    local probe = createTransformGroup("fpcRotationProbe")

    setRotation(probe, 0.2, 0, 0)
    local _, fy, _ = localDirectionToWorld(probe, 0, 0, 1)
    VehicleSeat.signX = fy >= 0 and 1 or -1

    setRotation(probe, 0, 0, 0.2)
    local _, ry, _ = localDirectionToWorld(probe, 1, 0, 0)
    VehicleSeat.signZ = ry >= 0 and 1 or -1

    setRotation(probe, 0, 0.2, 0)
    local fx, _, fz = localDirectionToWorld(probe, 0, 0, 1)
    VehicleSeat.signY = math.atan2(fx, fz) >= 0 and 1 or -1

    delete(probe)
end

---Node chain used to rebuild the camera's pose. frame carries the mount's world
-- pose, delta carries our offsets in the mount's frame, and proxy carries the
-- camera's pose relative to the mount so the offsets compose correctly.
function VehicleSeat.getNodes()
    if VehicleSeat.frameNode ~= nil and entityExists(VehicleSeat.frameNode) then
        return VehicleSeat.frameNode, VehicleSeat.deltaNode, VehicleSeat.proxyNode
    end

    VehicleSeat.frameNode = createTransformGroup("fpcSeatFrame")
    VehicleSeat.deltaNode = createTransformGroup("fpcSeatDelta")
    VehicleSeat.proxyNode = createTransformGroup("fpcSeatProxy")
    link(getRootNode(), VehicleSeat.frameNode)
    link(VehicleSeat.frameNode, VehicleSeat.deltaNode)
    link(VehicleSeat.deltaNode, VehicleSeat.proxyNode)

    return VehicleSeat.frameNode, VehicleSeat.deltaNode, VehicleSeat.proxyNode
end

local function newState()
    return {
        -- One sample for a position, one for a velocity, one for an
        -- acceleration. Until we have all three there is nothing to drive with.
        warmup = VehicleSeat.WARMUP_FRAMES,
        lastPosX = 0, lastPosY = 0, lastPosZ = 0,
        lastVelX = 0, lastVelY = 0, lastVelZ = 0,
        lastPitch = 0, lastRoll = 0, lastYaw = 0,
        lastPitchRate = 0, lastRollRate = 0, lastYawRate = 0,
        filteredAccX = 0, filteredAccY = 0, filteredAccZ = 0,
        filteredPitchAcc = 0, filteredRollAcc = 0, filteredYawAcc = 0,
        seatX = 0, seatY = 0, seatZ = 0,
        seatVelX = 0, seatVelY = 0, seatVelZ = 0,
        headPitch = 0, headRoll = 0, headYaw = 0,
        headPitchVel = 0, headRollVel = 0, headYawVel = 0,
        enginePhase = 0,
    }
end

---Semi-implicit Euler on x'' = -w^2 x - 2 zeta w x' + drive, sub-stepped so the
-- spring stays stable through a long frame.
local function integrate(spring, position, velocity, drive, dts)
    local w = spring.freq * math.pi * 2
    local damping = 2 * spring.zeta * w
    local stiffness = w * w

    local remaining = dts
    while remaining > 0 do
        local step = math.min(remaining, 0.004)
        remaining = remaining - step
        local acc = -stiffness * position - damping * velocity + drive
        velocity = velocity + acc * step
        position = position + velocity * step
    end

    if position > spring.limit then
        position, velocity = spring.limit, math.min(velocity, 0)
    elseif position < -spring.limit then
        position, velocity = -spring.limit, math.max(velocity, 0)
    end

    return position, velocity
end

local function wrapAngle(angle)
    while angle > math.pi do angle = angle - math.pi * 2 end
    while angle < -math.pi do angle = angle + math.pi * 2 end
    return angle
end

---The node the camera hangs off. For an inside camera with position smoothing
-- the camera itself lives under a detached world parent, so we have to go
-- through cameraPositionNode to find the actual place in the vehicle.
local function getMountNode(camera)
    local node = camera.cameraPositionNode or camera.cameraNode
    if node == nil then
        return nil
    end

    local parent = getParent(node)
    if parent ~= nil and parent ~= 0 and entityExists(parent) then
        return parent
    end

    if camera.vehicle ~= nil and camera.vehicle.rootNode ~= nil then
        return camera.vehicle.rootNode
    end

    return nil
end

function VehicleSeat.shouldApply(camera)
    if not FPCSettings.get("vehicleEnabled") then
        return false
    end
    if camera.cameraNode == nil or not entityExists(camera.cameraNode) then
        return false
    end
    if not camera.isInside and not FPCSettings.get("vehicleOutsideCameras") then
        return false
    end
    -- Head tracking owns the camera node outright; stay out of its way
    if camera.headTrackingNode ~= nil and g_gameSettings:getValue(GameSettings.SETTING.IS_HEAD_TRACKING_ENABLED) then
        return false
    end
    return true
end

---@param camera VehicleCamera
---@param dt number frame time in ms
function VehicleSeat.update(camera, dt)
    if not VehicleSeat.shouldApply(camera) then
        camera.fpcSeat = nil
        return
    end

    local mountNode = getMountNode(camera)
    if mountNode == nil then
        return
    end

    local dts = math.clamp(dt * 0.001, 0, VehicleSeat.MAX_DT)
    if dts <= 0 then
        return
    end

    local state = camera.fpcSeat
    if state == nil then
        state = newState()
        camera.fpcSeat = state
    end

    -- MEASURE -----------------------------------------------------------------
    local posX, posY, posZ = getWorldTranslation(mountNode)
    local fwdX, fwdY, fwdZ = localDirectionToWorld(mountNode, 0, 0, 1)
    local rightX, rightY, rightZ = localDirectionToWorld(mountNode, 1, 0, 0)

    -- World referenced attitude: how far the nose is raised, how far the right
    -- side is raised, and which way we point.
    local pitch = math.asin(math.clamp(fwdY, -1, 1))
    local roll = math.asin(math.clamp(rightY, -1, 1))
    local yaw = math.atan2(fwdX, fwdZ)

    -- First frame after a reset has no previous sample to difference against.
    if state.warmup >= VehicleSeat.WARMUP_FRAMES then
        state.warmup = state.warmup - 1
        state.lastPosX, state.lastPosY, state.lastPosZ = posX, posY, posZ
        state.lastPitch, state.lastRoll, state.lastYaw = pitch, roll, yaw
        return
    end

    local dx, dy, dz = posX - state.lastPosX, posY - state.lastPosY, posZ - state.lastPosZ

    -- Teleport, vehicle reset, entering from a long way off: start again rather
    -- than feed a several-metre jump into the springs.
    if math.abs(dx) + math.abs(dy) + math.abs(dz) > VehicleSeat.TELEPORT_DISTANCE then
        camera.fpcSeat = newState()
        return
    end

    local velX, velY, velZ = dx / dts, dy / dts, dz / dts
    local accX = math.clamp((velX - state.lastVelX) / dts, -VehicleSeat.MAX_ACCELERATION, VehicleSeat.MAX_ACCELERATION)
    local accY = math.clamp((velY - state.lastVelY) / dts, -VehicleSeat.MAX_ACCELERATION, VehicleSeat.MAX_ACCELERATION)
    local accZ = math.clamp((velZ - state.lastVelZ) / dts, -VehicleSeat.MAX_ACCELERATION, VehicleSeat.MAX_ACCELERATION)

    -- Into the cab's own frame: x is sideways, y is up, z is fore/aft
    local localAccX, localAccY, localAccZ = worldDirectionToLocal(mountNode, accX, accY, accZ)

    local maxAngAcc = VehicleSeat.MAX_ANGULAR_ACCELERATION
    local pitchRate = wrapAngle(pitch - state.lastPitch) / dts
    local rollRate = wrapAngle(roll - state.lastRoll) / dts
    local yawRate = wrapAngle(yaw - state.lastYaw) / dts
    local pitchAcc = math.clamp((pitchRate - state.lastPitchRate) / dts, -maxAngAcc, maxAngAcc)
    local rollAcc = math.clamp((rollRate - state.lastRollRate) / dts, -maxAngAcc, maxAngAcc)
    local yawAcc = math.clamp((yawRate - state.lastYawRate) / dts, -maxAngAcc, maxAngAcc)

    state.lastPosX, state.lastPosY, state.lastPosZ = posX, posY, posZ
    state.lastVelX, state.lastVelY, state.lastVelZ = velX, velY, velZ
    state.lastPitch, state.lastRoll, state.lastYaw = pitch, roll, yaw
    state.lastPitchRate, state.lastRollRate, state.lastYawRate = pitchRate, rollRate, yawRate

    if VehicleSeat.debug.enabled then
        VehicleSeat.debug.frames = VehicleSeat.debug.frames + 1
        if dx == 0 and dy == 0 and dz == 0 then
            VehicleSeat.debug.stillFrames = VehicleSeat.debug.stillFrames + 1
        end
        VehicleSeat.debug.dt = dts
    end

    -- Entering a moving vehicle would otherwise read the whole of its speed as a
    -- single frame of acceleration and punch the springs into their limits.
    if state.warmup > 0 then
        state.warmup = state.warmup - 1
        return
    end

    -- One pole low pass, see ACCELERATION_FILTER_HZ
    local accAlpha = math.min(1, dts * VehicleSeat.ACCELERATION_FILTER_HZ * math.pi * 2)
    state.filteredAccX = state.filteredAccX + (localAccX - state.filteredAccX) * accAlpha
    state.filteredAccY = state.filteredAccY + (localAccY - state.filteredAccY) * accAlpha
    state.filteredAccZ = state.filteredAccZ + (localAccZ - state.filteredAccZ) * accAlpha
    state.filteredPitchAcc = state.filteredPitchAcc + (pitchAcc - state.filteredPitchAcc) * accAlpha
    state.filteredRollAcc = state.filteredRollAcc + (rollAcc - state.filteredRollAcc) * accAlpha
    state.filteredYawAcc = state.filteredYawAcc + (yawAcc - state.filteredYawAcc) * accAlpha

    localAccX, localAccY, localAccZ = state.filteredAccX, state.filteredAccY, state.filteredAccZ
    pitchAcc, rollAcc, yawAcc = state.filteredPitchAcc, state.filteredRollAcc, state.filteredYawAcc

    -- SEAT SPRINGS ------------------------------------------------------------
    -- Negative drive: the seat gives way against whatever the cab is doing, so a
    -- cab accelerating upwards leaves the seat behind and below.
    local seatScale = FPCSettings.get("vehicleSeatScale")
    local seat = VehicleSeat.SEAT

    state.seatX, state.seatVelX = integrate(seat.lateral, state.seatX, state.seatVelX, -localAccX * seat.lateral.gain, dts)
    state.seatY, state.seatVelY = integrate(seat.vertical, state.seatY, state.seatVelY, -localAccY * seat.vertical.gain, dts)
    state.seatZ, state.seatVelZ = integrate(seat.longitudinal, state.seatZ, state.seatVelZ, -localAccZ * seat.longitudinal.gain, dts)

    local offsetX = state.seatX * seatScale
    local offsetY = state.seatY * seatScale
    local offsetZ = state.seatZ * seatScale

    -- HEAD SPRINGS ------------------------------------------------------------
    local headScale = FPCSettings.get("vehicleHeadScale")
    local head = VehicleSeat.HEAD

    state.headPitch, state.headPitchVel = integrate(head.pitch, state.headPitch, state.headPitchVel, -pitchAcc * head.pitch.gain, dts)
    state.headRoll, state.headRollVel = integrate(head.roll, state.headRoll, state.headRollVel, -rollAcc * head.roll.gain, dts)
    state.headYaw, state.headYawVel = integrate(head.yaw, state.headYaw, state.headYawVel, -yawAcc * head.yaw.gain, dts)

    local anglePitch = state.headPitch * headScale
    local angleRoll = state.headRoll * headScale
    local angleYaw = state.headYaw * headScale

    if VehicleSeat.debug.enabled then
        holdPeak("accX", localAccX, dts)
        holdPeak("accY", localAccY, dts)
        holdPeak("accZ", localAccZ, dts)
        holdPeak("angPitch", pitchAcc, dts)
        holdPeak("angRoll", rollAcc, dts)
        holdPeak("angYaw", yawAcc, dts)
        holdPeak("seatX", offsetX, dts)
        holdPeak("seatY", offsetY, dts)
        holdPeak("seatZ", offsetZ, dts)
        holdPeak("headPitch", anglePitch, dts)
        holdPeak("headRoll", angleRoll, dts)
        holdPeak("headYaw", angleYaw, dts)
    end

    -- ENGINE VIBRATION --------------------------------------------------------
    local engineScale = FPCSettings.get("vehicleEngineScale")
    local vehicle = camera.vehicle
    if engineScale > 0 and vehicle ~= nil and vehicle.spec_motorized ~= nil
        and vehicle.getIsMotorStarted ~= nil and vehicle:getIsMotorStarted() then

        local rpm = math.clamp(vehicle:getMotorRpmPercentage() or 0, 0, 1)
        local load = math.clamp(vehicle:getMotorLoadPercentage() or 0, 0, 1)

        -- Never let the vibration outrun what the frame rate can actually draw
        local frequency = math.min(
            VehicleSeat.ENGINE_BASE_HZ + VehicleSeat.ENGINE_RPM_HZ * rpm,
            VehicleSeat.ENGINE_MAX_SAMPLE_RATIO / dts)

        state.enginePhase = state.enginePhase + frequency * math.pi * 2 * dts
        if state.enginePhase > math.pi * 2 then
            state.enginePhase = state.enginePhase - math.pi * 2
        end

        local amplitude = (VehicleSeat.ENGINE_IDLE_AMPLITUDE + VehicleSeat.ENGINE_LOAD_AMPLITUDE * load) * engineScale
        -- Fundamental plus a sub-harmonic, so it lopes rather than hums
        local shake = (math.sin(state.enginePhase) + math.sin(state.enginePhase * 0.5) * 0.35) * amplitude

        offsetY = offsetY + shake
        offsetX = offsetX + shake * 0.35
        anglePitch = anglePitch + shake * VehicleSeat.ENGINE_PITCH_RATIO
    end

    if offsetX == 0 and offsetY == 0 and offsetZ == 0
        and anglePitch == 0 and angleRoll == 0 and angleYaw == 0 then
        return
    end

    -- APPLY -------------------------------------------------------------------
    local frameNode, deltaNode, proxyNode = VehicleSeat.getNodes()

    -- Park the chain on the mount with no offset, then hang the camera's current
    -- pose off it. proxy now holds the camera's pose relative to the cab.
    setTranslation(deltaNode, 0, 0, 0)
    setRotation(deltaNode, 0, 0, 0)
    setWorldTranslation(frameNode, posX, posY, posZ)
    setWorldQuaternion(frameNode, getWorldQuaternion(mountNode))

    local camX, camY, camZ = getWorldTranslation(camera.cameraNode)
    local camQX, camQY, camQZ, camQW = getWorldQuaternion(camera.cameraNode)
    setWorldTranslation(proxyNode, camX, camY, camZ)
    setWorldQuaternion(proxyNode, camQX, camQY, camQZ, camQW)

    -- Now move the cab out from under it and read where the camera ended up
    setTranslation(deltaNode, offsetX, offsetY, offsetZ)
    setRotation(deltaNode,
        anglePitch * VehicleSeat.signX,
        angleYaw * VehicleSeat.signY,
        angleRoll * VehicleSeat.signZ)

    local newX, newY, newZ = getWorldTranslation(proxyNode)
    local newQX, newQY, newQZ, newQW = getWorldQuaternion(proxyNode)

    setWorldTranslation(camera.cameraNode, newX, newY, newZ)
    setWorldQuaternion(camera.cameraNode, newQX, newQY, newQZ, newQW)
end

---Peak-hold readout of what the springs are actually being fed, so tuning is a
-- measurement rather than a guess. Toggled with the fpcDebug console command.
function VehicleSeat.drawDebug()
    if not VehicleSeat.debug.enabled then
        return
    end

    local d = VehicleSeat.debug
    setTextColor(1, 1, 1, 1)
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextBold(false)

    local x, y, size = 0.02, 0.62, 0.014
    local function line(text)
        renderText(x, y, size, text)
        y = y - size * 1.25
    end

    setTextBold(true)
    line("First Person Cameras - vehicle seat (peak held)")
    setTextBold(false)
    line(string.format("cab accel   side %6.1f  up %6.1f  fore %6.1f  m/s2", d.accX, d.accY, d.accZ))
    line(string.format("cab angular pitch %6.1f  roll %6.1f  yaw %6.1f  rad/s2", d.angPitch, d.angRoll, d.angYaw))
    line(string.format("seat travel side %6.1f  up %6.1f  fore %6.1f  mm",
        d.seatX * 1000, d.seatY * 1000, d.seatZ * 1000))
    line(string.format("head lean   pitch %6.2f  roll %6.2f  yaw %6.2f  deg",
        math.deg(d.headPitch), math.deg(d.headRoll), math.deg(d.headYaw)))
    -- A high still-frame count means the render rate is outrunning the physics
    -- step, so the cab transform is being sampled more often than it changes.
    line(string.format("frame %5.1f ms   frames with no cab movement: %4.1f %%",
        d.dt * 1000, d.frames > 0 and (d.stillFrames / d.frames * 100) or 0))
end

function VehicleSeat.consoleCommandDebug()
    VehicleSeat.debug.enabled = not VehicleSeat.debug.enabled
    VehicleSeat.debug.frames = 0
    VehicleSeat.debug.stillFrames = 0
    return string.format("First Person Cameras debug readout %s",
        VehicleSeat.debug.enabled and "on" or "off")
end
