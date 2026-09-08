---
-- VehicleSeat
--
-- Seat and body suspension for vehicle cameras.
--
-- The base game bolts the camera straight to the cab. A real seat is sprung and
-- the driver sits as a mass on top of it, so:
--
--   * SEAT   - three damped springs (up/down, side, fore/aft) driven by the
--              mount's acceleration. A bump throws the cab up, the seat lags,
--              then catches up and slightly overshoots.
--   * HEAD   - three more springs driven by angular acceleration: head lags
--              pitch/roll and leans under cornering/braking.
--   * ENGINE - vibration whose rate follows rpm, depth follows load.
--
-- All measured, not scripted, by finite-differencing the mount's world
-- transform - so it works on every vehicle and picks up whatever suspension,
-- articulation or cab damping already exists. Same technique as the base
-- game's Suspensions spec (vehicles/specializations/Suspensions.lua), which
-- few vehicles define and which is off by default.
--
-- Applied after VehicleCamera:update poses the camera, by rebuilding its world
-- transform through a small node chain. The game re-poses from scratch every
-- frame, so nothing accumulates.
---

VehicleSeat = {}

-- Seat springs. Frequency in Hz, zeta is damping ratio, gain is how much of the
-- cab's acceleration the seat gives way to:
--
--     x'' = -w^2 x - 2 zeta w x' - gain * a_cab
--
-- For a mass on a shaken base, the textbook gain is 1.0; less is a fudge that
-- makes the seat stiffer than its stated frequency (at 0.33 vertical looked
-- welded to the wheel: a firm bump moved the view 17 mm). So vertical runs at
-- 1.0 and is kept in check by `limit` instead. Lateral/fore-aft keep reduced
-- gain deliberately: a seat barely slides those ways, your braced body does.
VehicleSeat.SEAT = {
    -- 1.3 Hz underdamped, like a real air seat: rebounds once rather than
    -- deadening the hit
    vertical   = { freq = 1.30, zeta = 0.32, gain = 1.00, limit = 0.10 },
    lateral    = { freq = 2.00, zeta = 0.50, gain = 0.50, limit = 0.06 },
    longitudinal = { freq = 1.90, zeta = 0.48, gain = 0.50, limit = 0.06 },
}

-- Smoothing on measured acceleration, on top of the physics-time measurement in
-- update() - differencing a position twice always leaves some noise.
VehicleSeat.ACCELERATION_FILTER_HZ = 18

-- Head springs. Radians.
--
-- `gain`  - cab's ANGULAR acceleration (twisting). Transient bump term: cab
--           snaps and back, head lags through it.
-- `gGain` - cab's LINEAR acceleration (g-force). Sustained cornering/braking
--           term: hold the corner, the lean holds.
--
-- Angular alone isn't enough: full lock in a tractor fed 12.3 rad/s^2 of roll
-- for only 0.63 degrees of lean - not a weak spring, that's differencing noise
-- a 1.6 Hz spring is right to reject. A steady corner has constant yaw rate, so
-- zero yaw acceleration - no sustained signal there for gain to find. The lean
-- has to come from g-force instead.
--
-- This matters more than seat travel: rotation is the only thing that moves
-- the distant world. Sliding the seat 37 mm sideways swings a door pillar
-- several degrees but a barn 100 m off a thirtieth of one - translation alone
-- reads as the cab swimming around a driver nailed in place.
--
-- Pitch runs a much lower gGain than roll, measured not chosen: fore/aft is
-- spiky (a stop peaks >1.2 g briefly), lateral is smooth (~5 m/s^2 sustained).
-- Equal gains near 1 gave a 6 mph stop 5.3 degrees of nod against a well
-- judged 2.4 degrees of roll at full lock - equal gains on unequal inputs.
--
-- Both gGains were landed by driving: in-game sliders found the feel, then
-- folded back (0.375 at 50% = 0.1875, 0.65 at 25% = 0.1625), leaving both
-- sliders reading 100% at the tuned default.
--
-- Both are far below the calculated 1g value - about a third of it. Not wrong
-- physics: a real driver sees their body move and feels it in their inner ear,
-- and gets neither here, so the same angle reads as being yanked rather than
-- as their own head moving. ~1 degree of pitch under braking is the ceiling.
--
-- `limit` is shared with the bump term; with gGain this low the g term no
-- longer approaches it, so the limit now exists for bumps only.
--
-- Yaw gets no g term - nothing sideways twists you about your own spine.
VehicleSeat.HEAD = {
    pitch = { freq = 1.45, zeta = 0.40, gain = 0.440, gGain = 0.1875, limit = 0.090 },  -- ~5.2 degrees
    roll  = { freq = 1.60, zeta = 0.42, gain = 0.540, gGain = 0.1625, limit = 0.100 },
    yaw   = { freq = 1.90, zeta = 0.55, gain = 0.290, gGain = 0,      limit = 0.060 },
}

-- Engine vibration.
--
-- Keep these low. Near half the frame rate, samples alias and walk around the
-- waveform instead of tracing it - a fine shimmer becomes a violent random
-- shake that turning amplitude down won't fix. Second component is a
-- sub-harmonic, not a harmonic, so it reads as engine lope and can't alias.
VehicleSeat.ENGINE_BASE_HZ = 4.5
VehicleSeat.ENGINE_RPM_HZ = 4.5            -- added on top at full rpm
VehicleSeat.ENGINE_MAX_SAMPLE_RATIO = 0.2  -- cap frequency at a fifth of the frame rate
VehicleSeat.ENGINE_IDLE_AMPLITUDE = 0.00045 -- metres
VehicleSeat.ENGINE_LOAD_AMPLITUDE = 0.00075 -- extra at full load
VehicleSeat.ENGINE_PITCH_RATIO = 0.20      -- radians of shake per metre

-- Guards. A physics hiccup or a teleport must not launch the springs.
VehicleSeat.MAX_ACCELERATION = 60          -- m/s^2 per axis
VehicleSeat.MAX_ANGULAR_ACCELERATION = 60  -- rad/s^2 per axis
VehicleSeat.TELEPORT_SPEED = 60            -- m/s; nothing in the game goes faster
VehicleSeat.TELEPORT_MARGIN = 1            -- m of slack on top
VehicleSeat.MAX_DT = 0.1                   -- s
VehicleSeat.WARMUP_FRAMES = 3              -- samples needed before the springs run

-- Live readout for the fpcDebug console command. Peaks are held and bled off so
-- a single bump stays on screen long enough to read.
VehicleSeat.debug = {
    enabled = false,
    peakDecay = 0.6,        -- per second
    frames = 0, stillFrames = 0, dt = 0,
    measuredSpeed = 0, reportedSpeed = 0,
    accX = 0, accY = 0, accZ = 0,
    rawAccX = 0, rawAccY = 0, rawAccZ = 0,
    -- Frame to frame change in the applied offset - the visible judder. Small
    -- acceleration with a large jump here means the fault is downstream.
    jumpX = 0, jumpY = 0, jumpZ = 0,
    lastOffX = 0, lastOffY = 0, lastOffZ = 0,
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

---Work out which way setRotation turns things. We measure orientation as
-- world referenced angles but must feed it back through setRotation as Euler
-- angles, so rather than assume handedness, rotate a scratch node by a known
-- amount and read which way its axes went.
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

---Node chain used to rebuild the camera's pose: frame holds the mount's world
-- pose, delta holds our offsets, proxy holds the camera relative to the mount.
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
        -- Need a position, velocity and acceleration sample before there's
        -- anything to drive with.
        warmup = VehicleSeat.WARMUP_FRAMES,
        lastPosX = 0, lastPosY = 0, lastPosZ = 0,
        lastVelX = 0, lastVelY = 0, lastVelZ = 0,
        lastPitch = 0, lastRoll = 0, lastYaw = 0,
        lastPitchRate = 0, lastRollRate = 0, lastYawRate = 0,
        sincePos = 0, sinceVel = 0, sinceAtt = 0,
        filteredAccX = 0, filteredAccY = 0, filteredAccZ = 0,
        filteredPitchAcc = 0, filteredRollAcc = 0, filteredYawAcc = 0,
        seatX = 0, seatY = 0, seatZ = 0,
        seatVelX = 0, seatVelY = 0, seatVelZ = 0,
        headPitch = 0, headRoll = 0, headYaw = 0,
        headPitchVel = 0, headRollVel = 0, headYawVel = 0,
        enginePhase = 0,
    }
end

---Discard measurement history without touching the springs, so a teleport or
-- stall stops driving them but they ring down naturally instead of snapping.
function VehicleSeat.resetMeasurement(state)
    state.warmup = VehicleSeat.WARMUP_FRAMES
    state.sincePos, state.sinceVel, state.sinceAtt = 0, 0, 0
    state.lastVelX, state.lastVelY, state.lastVelZ = 0, 0, 0
    state.lastPitchRate, state.lastRollRate, state.lastYawRate = 0, 0, 0
    state.filteredAccX, state.filteredAccY, state.filteredAccZ = 0, 0, 0
    state.filteredPitchAcc, state.filteredRollAcc, state.filteredYawAcc = 0, 0, 0
end

---Semi-implicit Euler on x'' = -w^2 x - 2 zeta w x' + drive, sub-stepped for
-- stability through long frames.
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

---The node the camera hangs off. Position-smoothed inside cameras live under a
-- detached world parent, so go through cameraPositionNode to find the real spot.
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

---The physics body the camera hangs off, for getLinearVelocity.
-- Vehicle:getParentComponent walks up to a node the vehicle claims as its own,
-- returning 0 if there is none.
local function getBodyNode(camera)
    local vehicle = camera.vehicle
    if vehicle == nil or vehicle.getParentComponent == nil or getLinearVelocity == nil then
        return nil
    end

    local node = vehicle:getParentComponent(camera.cameraPositionNode or camera.cameraNode)
    if node == nil or node == 0 or not entityExists(node) then
        return nil
    end

    return node
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
        camera.fpcBodyNode = nil
        return
    end

    local mountNode = getMountNode(camera)
    if mountNode == nil then
        return
    end

    if camera.fpcBodyNode == nil then
        -- false rather than nil, so a body-less vehicle isn't looked up again
        camera.fpcBodyNode = getBodyNode(camera) or false
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

    -- World referenced attitude: nose raise, right-side raise, heading.
    local pitch = math.asin(math.clamp(fwdY, -1, 1))
    local roll = math.asin(math.clamp(rightY, -1, 1))
    local yaw = math.atan2(fwdX, fwdZ)

    -- No previous sample to difference against right after a reset.
    if state.warmup >= VehicleSeat.WARMUP_FRAMES then
        state.warmup = state.warmup - 1
        state.lastPosX, state.lastPosY, state.lastPosZ = posX, posY, posZ
        state.lastPitch, state.lastRoll, state.lastYaw = pitch, roll, yaw
        state.sincePos, state.sinceVel, state.sinceAtt = 0, 0, 0
        return
    end

    -- Getting the time interval right is the whole game here.
    --
    -- Measured in a tractor cab at 25 mph on flat tarmac, a wrong interval once
    -- reported 81.5 m/s^2 fore/aft, 14.0 sideways, 4.7 vertically, where truth
    -- is near zero on all three - ordered exactly by how far the cab travels
    -- per axis, the signature of a bad dt (it scales every axis by the same
    -- fraction of its own motion) rather than noise.
    --
    -- The trap: sampled quantities don't all change at the same rate. The cab
    -- transform interpolates up to render rate; physics velocity is piecewise
    -- constant, changing only on a physics step. Divide one by the other's
    -- interval and the answer is wrong by their ratio.
    --
    -- So each quantity carries its own clock - wall time since it last changed
    -- - and it stops mattering which is interpolated or at what rate.
    state.sincePos = state.sincePos + dts
    state.sinceVel = state.sinceVel + dts
    state.sinceAtt = state.sinceAtt + dts

    -- VELOCITY, straight from the physics body where there is one - removes a
    -- derivative, which is where the noise comes from.
    local velX, velY, velZ
    if camera.fpcBodyNode then
        velX, velY, velZ = getLinearVelocity(camera.fpcBodyNode)
    end

    if velX == nil then
        -- No physics body: difference position instead, on its own clock.
        if posX ~= state.lastPosX or posY ~= state.lastPosY or posZ ~= state.lastPosZ then
            local sdt = math.max(state.sincePos, 0.0005)
            velX = (posX - state.lastPosX) / sdt
            velY = (posY - state.lastPosY) / sdt
            velZ = (posZ - state.lastPosZ) / sdt
        else
            velX, velY, velZ = state.lastVelX, state.lastVelY, state.lastVelZ
        end
    end

    -- Teleport/reset/stall: faster than any vehicle can plausibly travel isn't
    -- real movement. Judged against elapsed time, or a long frame at speed
    -- reads as a jump.
    if posX ~= state.lastPosX or posY ~= state.lastPosY or posZ ~= state.lastPosZ then
        local dx, dy, dz = posX - state.lastPosX, posY - state.lastPosY, posZ - state.lastPosZ
        local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
        if distance > VehicleSeat.TELEPORT_SPEED * state.sincePos + VehicleSeat.TELEPORT_MARGIN then
            -- Drop history, leave the springs to ring down naturally.
            VehicleSeat.resetMeasurement(state)
            return
        end
        state.lastPosX, state.lastPosY, state.lastPosZ = posX, posY, posZ
        state.sincePos = 0
    end

    if VehicleSeat.debug.enabled then
        VehicleSeat.debug.frames = VehicleSeat.debug.frames + 1
        VehicleSeat.debug.dt = dts
        VehicleSeat.debug.measuredSpeed = math.sqrt(velX * velX + velY * velY + velZ * velZ)
        VehicleSeat.debug.reportedSpeed = camera.vehicle ~= nil
            and (camera.vehicle.lastSpeedReal or 0) * 1000 or 0
    end

    -- LINEAR ACCELERATION, on the velocity's clock
    if velX ~= state.lastVelX or velY ~= state.lastVelY or velZ ~= state.lastVelZ then
        local sdt = math.max(state.sinceVel, 0.0005)
        state.sinceVel = 0

        local maxAcc = VehicleSeat.MAX_ACCELERATION
        local accX = math.clamp((velX - state.lastVelX) / sdt, -maxAcc, maxAcc)
        local accY = math.clamp((velY - state.lastVelY) / sdt, -maxAcc, maxAcc)
        local accZ = math.clamp((velZ - state.lastVelZ) / sdt, -maxAcc, maxAcc)

        state.lastVelX, state.lastVelY, state.lastVelZ = velX, velY, velZ

        if state.warmup > 0 then
            -- Otherwise entering a moving vehicle reads its whole speed as one
            -- acceleration sample and punches the springs into their limits.
            state.warmup = state.warmup - 1
        else
            -- Into the cab's own frame: x sideways, y up, z fore/aft
            local ax, ay, az = worldDirectionToLocal(mountNode, accX, accY, accZ)

            if VehicleSeat.debug.enabled then
                holdPeak("rawAccX", ax, sdt)
                holdPeak("rawAccY", ay, sdt)
                holdPeak("rawAccZ", az, sdt)
            end

            local a = math.min(1, sdt * VehicleSeat.ACCELERATION_FILTER_HZ * math.pi * 2)
            state.filteredAccX = state.filteredAccX + (ax - state.filteredAccX) * a
            state.filteredAccY = state.filteredAccY + (ay - state.filteredAccY) * a
            state.filteredAccZ = state.filteredAccZ + (az - state.filteredAccZ) * a
        end
    end

    -- ANGULAR ACCELERATION, on the attitude's clock
    if pitch ~= state.lastPitch or roll ~= state.lastRoll or yaw ~= state.lastYaw then
        local sdt = math.max(state.sinceAtt, 0.0005)
        state.sinceAtt = 0

        local maxAngAcc = VehicleSeat.MAX_ANGULAR_ACCELERATION
        local pitchRate = wrapAngle(pitch - state.lastPitch) / sdt
        local rollRate = wrapAngle(roll - state.lastRoll) / sdt
        local yawRate = wrapAngle(yaw - state.lastYaw) / sdt
        local pitchAcc = math.clamp((pitchRate - state.lastPitchRate) / sdt, -maxAngAcc, maxAngAcc)
        local rollAcc = math.clamp((rollRate - state.lastRollRate) / sdt, -maxAngAcc, maxAngAcc)
        local yawAcc = math.clamp((yawRate - state.lastYawRate) / sdt, -maxAngAcc, maxAngAcc)

        state.lastPitch, state.lastRoll, state.lastYaw = pitch, roll, yaw
        state.lastPitchRate, state.lastRollRate, state.lastYawRate = pitchRate, rollRate, yawRate

        if state.warmup <= 0 then
            local a = math.min(1, sdt * VehicleSeat.ACCELERATION_FILTER_HZ * math.pi * 2)
            state.filteredPitchAcc = state.filteredPitchAcc + (pitchAcc - state.filteredPitchAcc) * a
            state.filteredRollAcc = state.filteredRollAcc + (rollAcc - state.filteredRollAcc) * a
            state.filteredYawAcc = state.filteredYawAcc + (yawAcc - state.filteredYawAcc) * a
        end
    end

    if state.warmup > 0 then
        return
    end

    local localAccX, localAccY, localAccZ = state.filteredAccX, state.filteredAccY, state.filteredAccZ
    local pitchAcc, rollAcc, yawAcc = state.filteredPitchAcc, state.filteredRollAcc, state.filteredYawAcc

    -- SEAT SPRINGS ------------------------------------------------------------
    -- Negative drive: the seat gives way, so a cab accelerating up leaves the
    -- seat behind and below.
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

    -- The two drive terms carry opposite signs deliberately.
    --
    -- Angular is a lag: cab pitches nose up, head is late, still looking where
    -- the cab used to be - hence -pitchAcc.
    --
    -- The g term is a throw: body goes *against* the acceleration. Braking
    -- (localAccZ negative) throws you forward, head pitches down (negative
    -- pitch), so the term is +localAccZ. Same for roll: turning left goes
    -- localAccX negative, body goes right, head tips right (negative roll).
    --
    -- The g terms carry their own scales on top of headScale, since braking and
    -- cornering are read off different measurements and want different gains.
    local brakeScale = FPCSettings.get("vehicleBrakePitchScale")
    local cornerScale = FPCSettings.get("vehicleCornerRollScale")

    state.headPitch, state.headPitchVel = integrate(head.pitch, state.headPitch, state.headPitchVel,
        -pitchAcc * head.pitch.gain + localAccZ * head.pitch.gGain * brakeScale, dts)
    state.headRoll, state.headRollVel = integrate(head.roll, state.headRoll, state.headRollVel,
        -rollAcc * head.roll.gain + localAccX * head.roll.gGain * cornerScale, dts)
    state.headYaw, state.headYawVel = integrate(head.yaw, state.headYaw, state.headYawVel,
        -yawAcc * head.yaw.gain, dts)

    local anglePitch = state.headPitch * headScale
    local angleRoll = state.headRoll * headScale
    local angleYaw = state.headYaw * headScale

    if VehicleSeat.debug.enabled then
        local d = VehicleSeat.debug
        holdPeak("jumpX", offsetX - d.lastOffX, dts)
        holdPeak("jumpY", offsetY - d.lastOffY, dts)
        holdPeak("jumpZ", offsetZ - d.lastOffZ, dts)
        d.lastOffX, d.lastOffY, d.lastOffZ = offsetX, offsetY, offsetZ

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

        -- Cap so vibration can't outrun what the frame rate can draw
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

    -- Park the chain on the mount with no offset, then hang the camera's pose
    -- off it - proxy now holds it relative to the cab.
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

---Peak-hold readout of what the springs are fed, so tuning is measurement, not
-- guesswork. Toggled with the fpcDebug console command.
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
    line(string.format("cab accel   side %6.1f  up %6.1f  fore %6.1f  m/s2  (filtered)", d.accX, d.accY, d.accZ))
    line(string.format("            side %6.1f  up %6.1f  fore %6.1f  m/s2  (raw)", d.rawAccX, d.rawAccY, d.rawAccZ))
    line(string.format("cab angular pitch %6.1f  roll %6.1f  yaw %6.1f  rad/s2", d.angPitch, d.angRoll, d.angYaw))
    line(string.format("seat travel side %6.1f  up %6.1f  fore %6.1f  mm",
        d.seatX * 1000, d.seatY * 1000, d.seatZ * 1000))
    line(string.format("head lean   pitch %6.2f  roll %6.2f  yaw %6.2f  deg",
        math.deg(d.headPitch), math.deg(d.headRoll), math.deg(d.headYaw)))
    line(string.format("JUDDER      side %6.2f  up %6.2f  fore %6.2f  mm per frame",
        d.jumpX * 1000, d.jumpY * 1000, d.jumpZ * 1000))
    -- Timing check: these two must agree, or the sample interval is wrong and
    -- every acceleration above it is wrong by far more.
    line(string.format("speed  measured %6.2f   vehicle says %6.2f  m/s   <- must match",
        d.measuredSpeed, d.reportedSpeed))
    line(string.format("frame %5.1f ms", d.dt * 1000))
end

function VehicleSeat.consoleCommandDebug()
    VehicleSeat.debug.enabled = not VehicleSeat.debug.enabled
    VehicleSeat.debug.frames = 0
    VehicleSeat.debug.stillFrames = 0
    return string.format("First Person Cameras debug readout %s",
        VehicleSeat.debug.enabled and "on" or "off")
end
