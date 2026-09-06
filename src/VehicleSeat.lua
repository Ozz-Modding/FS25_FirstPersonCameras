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

-- Smoothing on the measured acceleration. The physics/render rate mismatch is
-- handled properly in update() by measuring against physics time; this is just
-- to take the edge off what is left, since differencing a position twice always
-- amplifies noise.
VehicleSeat.ACCELERATION_FILTER_HZ = 18

-- Head springs. Radians.
--
-- Two things tip your head, and they are not the same thing:
--
--   `gain`  is on the cab's ANGULAR acceleration - the machine twisting under
--           you. This is the bump term. It is a transient by nature: the cab
--           snaps one way and back, and your head lags through it.
--   `gGain` is on the cab's LINEAR acceleration - the g-force pressing on your
--           body. This is the term you feel in a corner or under braking, and
--           unlike the bump term it is *sustained*: hold the corner and the lean
--           holds with it.
--
-- The angular term alone was not enough, and measuring showed why rather than
-- just that. At full lock in a tractor the readout showed 12.3 rad/s^2 of roll
-- going in and 0.63 degrees of lean coming out. That is not the spring being
-- too weak - 12 rad/s^2 is not a tractor rolling over, it is noise from
-- differencing the attitude twice, and a 1.6 Hz spring is right to throw a spike
-- that sharp away. There was no sustained component in the signal to find,
-- because a steady corner has a constant yaw rate and therefore zero yaw
-- acceleration. The lean has to come from the g-force instead.
--
-- This matters more than the seat travel does, because rotation is the only
-- thing that moves the distant world across the windscreen. Sliding the seat
-- 37 mm sideways swings the door pillar through several degrees and a barn a
-- hundred metres away through a thirtieth of one, so translation on its own
-- reads as the cab swimming around a driver who is nailed in place.
--
-- Pitch takes a much lower gGain than roll, and that asymmetry is measured, not
-- taste. Fore/aft acceleration in this game is spiky where lateral is smooth:
-- the brakes bite hard and briefly, so a stop from walking pace peaks over 1.2 g
-- for a fraction of a second, while a steady corner holds a genuine ~5 m/s^2.
-- With both gains near 1 that made a 6 mph stop nod the head 5.3 degrees - about
-- what slamming a car to a halt from motorway speed should look like - while the
-- same settings gave a well judged 2.4 degrees of roll at full lock. Equal gains
-- on unequal inputs, so the gains have to be unequal.
--
-- Both gGains were landed by driving, not by calculation. The springs are linear,
-- so the in-game sliders were used to find the multiplier that felt right and
-- then folded back in: 0.375 at 50 percent gives 0.1875, 0.65 at 25 percent gives
-- 0.1625. That leaves both sliders reading 100 percent at the tuned default,
-- which is the point of them.
--
-- Note how much smaller these are than the first honest guess. The calculated
-- values came from asking what a body actually does under 1 g, and they were
-- roughly three times too much in the game. That is not the physics being wrong,
-- it is that a real driver sees their own body move in their own peripheral
-- vision and feels the force in their inner ear, and gets neither here. Anything
-- above about a degree of pitch reads as the camera being yanked rather than as
-- your own head moving. Trust the drive over the derivation on this one.
--
-- `limit` is shared with the bump term above, so it sits high enough to leave
-- that some room and low enough that nothing ever looks broken. With gGain this
-- low the g term no longer approaches it - the limit is now there for the bumps.
--
-- Yaw gets no g term: there is no sideways force that twists you about your own
-- spine, only the machine snapping round under you, which is the angular term.
VehicleSeat.HEAD = {
    pitch = { freq = 1.45, zeta = 0.40, gain = 0.440, gGain = 0.1875, limit = 0.090 },  -- ~5.2 degrees
    roll  = { freq = 1.60, zeta = 0.42, gain = 0.540, gGain = 0.1625, limit = 0.100 },
    yaw   = { freq = 1.90, zeta = 0.55, gain = 0.290, gGain = 0,      limit = 0.060 },
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
    -- Frame to frame change in the applied offset. This is the judder you can
    -- actually see, and it is the number that separates a noisy input from a
    -- broken integrator: small acceleration with a large jump here means the
    -- fault is downstream of the measurement.
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

---Throw away the measurement history without touching the springs, so a
-- teleport or a stall stops driving them but whatever they are already doing
-- rings down naturally instead of snapping to centre.
function VehicleSeat.resetMeasurement(state)
    state.warmup = VehicleSeat.WARMUP_FRAMES
    state.sincePos, state.sinceVel, state.sinceAtt = 0, 0, 0
    state.lastVelX, state.lastVelY, state.lastVelZ = 0, 0, 0
    state.lastPitchRate, state.lastRollRate, state.lastYawRate = 0, 0, 0
    state.filteredAccX, state.filteredAccY, state.filteredAccZ = 0, 0, 0
    state.filteredPitchAcc, state.filteredRollAcc, state.filteredYawAcc = 0, 0, 0
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

---The physics body the camera hangs off, which is what getLinearVelocity needs.
-- Vehicle:getParentComponent walks up until it finds a node the vehicle claims
-- as one of its components, and returns 0 when there is none.
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
        -- false rather than nil, so a vehicle with no physics body is resolved
        -- once and not looked up again every frame
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
        state.sincePos, state.sinceVel, state.sinceAtt = 0, 0, 0
        return
    end

    -- Getting the time interval right is the whole game here.
    --
    -- Measured in the cab of a tractor on flat tarmac at 25 mph, this reported
    -- 81.5 m/s^2 fore/aft, 14.0 sideways and 4.7 vertically, where the truth on
    -- all three is close to zero. Those are ordered exactly by how far the cab
    -- travels on each axis, which is the signature of a wrong sample interval
    -- rather than of noise: a bad dt scales every axis by the same fraction of
    -- its own motion. Fore/aft is worst because it carries the road speed, and
    -- 8g of imaginary braking is what the lurching was.
    --
    -- The trap is that the quantities we sample do not all change at the same
    -- rate. The cab's transform is interpolated up to the render rate, so it
    -- moves a little every frame. The physics engine's velocity is not - it is
    -- piecewise constant and only changes when the physics steps. Divide either
    -- one by the other's interval and the answer is wrong by the ratio between
    -- them, which is exactly what happened.
    --
    -- So each measured quantity carries its own clock: the accumulated wall time
    -- since *that* value last changed, and nothing else. Then it does not matter
    -- which of them is interpolated, or at what rate the game runs either loop.
    state.sincePos = state.sincePos + dts
    state.sinceVel = state.sinceVel + dts
    state.sinceAtt = state.sinceAtt + dts

    -- VELOCITY. Straight from the physics engine where there is a body to ask:
    -- that removes a derivative, and a derivative is where the noise comes from.
    local velX, velY, velZ
    if camera.fpcBodyNode then
        velX, velY, velZ = getLinearVelocity(camera.fpcBodyNode)
    end

    if velX == nil then
        -- No physics body, so difference the position instead - on its own clock.
        if posX ~= state.lastPosX or posY ~= state.lastPosY or posZ ~= state.lastPosZ then
            local sdt = math.max(state.sincePos, 0.0005)
            velX = (posX - state.lastPosX) / sdt
            velY = (posY - state.lastPosY) / sdt
            velZ = (posZ - state.lastPosZ) / sdt
        else
            velX, velY, velZ = state.lastVelX, state.lastVelY, state.lastVelZ
        end
    end

    -- Teleport, vehicle reset, a long stall: anything faster than any vehicle in
    -- the game can plausibly travel is not real movement. Judged against the time
    -- actually elapsed, or a long frame at speed reads as a jump.
    if posX ~= state.lastPosX or posY ~= state.lastPosY or posZ ~= state.lastPosZ then
        local dx, dy, dz = posX - state.lastPosX, posY - state.lastPosY, posZ - state.lastPosZ
        local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
        if distance > VehicleSeat.TELEPORT_SPEED * state.sincePos + VehicleSeat.TELEPORT_MARGIN then
            -- Drop the measurement history but leave the springs alone, so they
            -- ring down naturally instead of snapping to centre.
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
            -- Entering a moving vehicle would otherwise read the whole of its
            -- speed as one sample of acceleration and punch the springs flat
            -- into their limits.
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

    -- Note the two drive terms carry opposite signs, and that is not a slip.
    --
    -- The angular term is a lag: the cab pitches nose up, your head is late, so
    -- it is still looking where the cab used to be - hence -pitchAcc.
    --
    -- The g term is the opposite. Your body is thrown *against* the acceleration,
    -- so braking (acceleration backwards, localAccZ negative) throws you forward
    -- and your head pitches down, which is a negative pitch under the convention
    -- here (pitch is how far the nose is raised). Negative in, negative out, so
    -- the term is +localAccZ. Same for roll: turning left accelerates you left,
    -- localAccX goes negative, your body goes right and your head tips right,
    -- which lowers the right side and so is a negative roll.
    -- The g terms carry their own scales on top of headScale, because braking and
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
    line(string.format("cab accel   side %6.1f  up %6.1f  fore %6.1f  m/s2  (filtered)", d.accX, d.accY, d.accZ))
    line(string.format("            side %6.1f  up %6.1f  fore %6.1f  m/s2  (raw)", d.rawAccX, d.rawAccY, d.rawAccZ))
    line(string.format("cab angular pitch %6.1f  roll %6.1f  yaw %6.1f  rad/s2", d.angPitch, d.angRoll, d.angYaw))
    line(string.format("seat travel side %6.1f  up %6.1f  fore %6.1f  mm",
        d.seatX * 1000, d.seatY * 1000, d.seatZ * 1000))
    line(string.format("head lean   pitch %6.2f  roll %6.2f  yaw %6.2f  deg",
        math.deg(d.headPitch), math.deg(d.headRoll), math.deg(d.headYaw)))
    -- Frames on which the physics did not step. High is normal and harmless
    -- above 60 fps; it is only a problem if something starts differentiating
    -- against frame time again.
    line(string.format("JUDDER      side %6.2f  up %6.2f  fore %6.2f  mm per frame",
        d.jumpX * 1000, d.jumpY * 1000, d.jumpZ * 1000))
    -- The timing check. These two must agree; if the measured speed is out by
    -- even a few per cent then the sample interval is wrong, and every
    -- acceleration above it is wrong by a far larger margin.
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
