---
-- WalkCamera
--
-- Head movement for the on-foot first person camera.
--
-- The base game's view bobbing constants are all zero and share cameraRootNode
-- with third person zoom, so we insert our own transform between
-- cameraRootNode and the first person camera and drive that instead. Nothing
-- else writes to it, so there is nothing to fight over or accumulate.
--
-- Four layers stack into that node:
--   1. Footstep bob  - tied to distance travelled, not wall time
--   2. Handheld sway - slow incommensurate sines, always running
--   3. Breathing     - fades in when standing still
--   4. Landing recoil - damped spring kicked on touchdown
---

WalkCamera = {}

-- Footstep bob ---------------------------------------------------------------
--
-- Game walk/run speeds (4/7 m/s) aren't human speeds; a real 0.85 m stride
-- would give ~5 steps/sec. Stride is stretched to keep cadence ~2 steps/sec.
WalkCamera.STRIDE_LENGTH_WALK = 1.85       -- metres per step at a walk
WalkCamera.STRIDE_LENGTH_RUN = 2.60        -- metres per step flat out
WalkCamera.MAX_CADENCE = 3.0               -- steps per second, hard ceiling
WalkCamera.RUN_SPEED = 7                   -- PlayerStateWalk.MAXIMUM_RUN_SPEED
WalkCamera.WALK_SPEED = 4                  -- PlayerStateWalk.MAXIMUM_WALK_SPEED

-- Weighted towards side to side: walking rolls you leg to leg more than it
-- lifts you. Halved from the original set - old 100% now reads as 50%.
WalkCamera.BOB_VERTICAL = 0.010            -- metres, peak, at full run
WalkCamera.BOB_LATERAL = 0.026
WalkCamera.BOB_ROLL = 0.00825              -- radians, ~0.47 degrees
WalkCamera.BOB_PITCH = 0.0020

-- Low pass on the gait layers, to remove frame/speed jitter without visible lag.
WalkCamera.SMOOTHING_RATE = 22             -- per second

-- Handheld sway --------------------------------------------------------------
WalkCamera.SWAY_PITCH = 0.0038             -- radians, ~0.22 degrees
WalkCamera.SWAY_YAW = 0.0046
WalkCamera.SWAY_ROLL = 0.0028
WalkCamera.SWAY_TRANSLATION = 0.0035       -- metres

-- Breathing ------------------------------------------------------------------
WalkCamera.BREATH_RATE = 0.23              -- Hz, ~14 breaths a minute
WalkCamera.BREATH_VERTICAL = 0.0075
WalkCamera.BREATH_PITCH = 0.0022

-- Landing recoil -------------------------------------------------------------
WalkCamera.LANDING_OMEGA = 15.5            -- rad/s
WalkCamera.LANDING_ZETA = 0.42
WalkCamera.LANDING_MAX_FALL_SPEED = 12     -- m/s that counts as a full strength hit
WalkCamera.LANDING_KICK = 1.15             -- m/s of downward camera velocity at full strength
WalkCamera.LANDING_MIN_DROP = 0.9          -- m/s below which a touchdown is ignored
WalkCamera.LANDING_LIMIT_DOWN = -0.16      -- metres
WalkCamera.LANDING_LIMIT_UP = 0.045
WalkCamera.LANDING_PITCH_RATIO = 0.19      -- radians of nod per metre of dip

-- Global caps so no combination of settings can throw the view around
WalkCamera.MAX_OFFSET = 0.25               -- metres
WalkCamera.MAX_ANGLE = 0.09                -- radians, ~5 degrees

WalkCamera.state = {
    stridePhase = 0,
    breathPhase = 0,
    swayTime = 0,
    landOffset = 0,
    landVelocity = 0,
    wasGrounded = true,
    lastAirVelocityY = 0,
    idleBlend = 0,
    speedSmoothed = 0,
    smoothedX = 0,
    smoothedY = 0,
    smoothedPitch = 0,
    smoothedYaw = 0,
    smoothedRoll = 0,
}

---Insert our own transform between the camera root and the first person camera.
local function getOffsetNode(camera)
    if camera.fpcOffsetNode ~= nil and entityExists(camera.fpcOffsetNode) then
        return camera.fpcOffsetNode
    end

    if camera.cameraRootNode == nil or camera.firstPersonCamera == nil then
        return nil
    end

    local node = createTransformGroup("fpcWalkOffset")
    link(camera.cameraRootNode, node)
    setTranslation(node, 0, 0, 0)
    setRotation(node, 0, 0, 0)

    link(node, camera.firstPersonCamera)
    setTranslation(camera.firstPersonCamera, 0, 0, 0)
    setRotation(camera.firstPersonCamera, 0, 0, 0)

    camera.fpcOffsetNode = node
    return node
end

function WalkCamera.reset(camera)
    local state = WalkCamera.state
    state.landOffset = 0
    state.landVelocity = 0
    state.idleBlend = 0
    state.speedSmoothed = 0
    state.smoothedX = 0
    state.smoothedY = 0
    state.smoothedPitch = 0
    state.smoothedYaw = 0
    state.smoothedRoll = 0

    if camera ~= nil and camera.fpcOffsetNode ~= nil and entityExists(camera.fpcOffsetNode) then
        setTranslation(camera.fpcOffsetNode, 0, 0, 0)
        setRotation(camera.fpcOffsetNode, 0, 0, 0)
    end
end

---Steps per second. Stride grows with speed, so cadence rises slower than speed.
local function getCadence(speed)
    local t = math.clamp((speed - WalkCamera.WALK_SPEED * 0.4)
        / (WalkCamera.RUN_SPEED - WalkCamera.WALK_SPEED * 0.4), 0, 1)
    local stride = MathUtil.lerp(WalkCamera.STRIDE_LENGTH_WALK, WalkCamera.STRIDE_LENGTH_RUN, t)
    return math.min(speed / stride, WalkCamera.MAX_CADENCE)
end

---@param camera PlayerCamera
---@param dt number frame time in ms
function WalkCamera.update(camera, dt)
    if camera == nil or camera.player == nil then
        return
    end

    if not FPCSettings.get("walkEnabled") or not camera.isFirstPerson then
        WalkCamera.reset(camera)
        return
    end

    local node = getOffsetNode(camera)
    if node == nil then
        return
    end

    local mover = camera.player.mover
    if mover == nil then
        return
    end

    -- Clamp long frames (loading hitches, alt-tab) so the springs don't fire off
    local dts = math.clamp(dt, 0, 100) * 0.001
    if dts <= 0 then
        return
    end

    local state = WalkCamera.state

    local bobScale = FPCSettings.get("walkBobScale")
    local swayScale = FPCSettings.get("walkSwayScale")
    local landScale = FPCSettings.get("walkLandingScale")

    local offsetX, offsetY, offsetZ = 0, 0, 0
    local pitch, yaw, roll = 0, 0, 0

    -- Smoothed speed so the bob doesn't snap at the threshold; zeroed in the air.
    local rawSpeed = mover.currentSpeed or 0
    if not mover.isGrounded or mover.isSwimming then
        rawSpeed = 0
    end
    state.speedSmoothed = state.speedSmoothed + (rawSpeed - state.speedSmoothed) * math.min(1, dts * 8)

    local speed = state.speedSmoothed
    local isMoving = speed > PlayerMover.SMALL_SPEED_THRESHOLD * 20

    -- Blend towards the idle presentation when standing still
    local idleTarget = isMoving and 0 or 1
    state.idleBlend = state.idleBlend + (idleTarget - state.idleBlend) * math.min(1, dts * 3)

    -- 1. FOOTSTEP BOB ---------------------------------------------------------
    if bobScale > 0 then
        if isMoving then
            -- One stride is two steps, so advance pi per step.
            state.stridePhase = state.stridePhase + getCadence(speed) * math.pi * dts
            if state.stridePhase > math.pi * 2 then
                state.stridePhase = state.stridePhase - math.pi * 2
            end
        end

        -- Amplitude ramps with speed and is cut right down in a crouch
        local intensity = math.clamp(speed / WalkCamera.RUN_SPEED, 0, 1.15)
        if mover.isCrouching then
            intensity = intensity * 0.45
        end
        if mover.isInWater then
            intensity = intensity * 0.6
        end
        intensity = intensity * bobScale * (1 - state.idleBlend)

        local phase = state.stridePhase
        -- Vertical curve is cosine, not abs(sin): abs(sin) has a corner at each
        -- footfall (an instant velocity reversal), which reads as a judder.
        offsetY = offsetY - math.cos(phase * 2) * WalkCamera.BOB_VERTICAL * 0.5 * intensity
        offsetX = offsetX + math.sin(phase) * WalkCamera.BOB_LATERAL * intensity
        roll = roll + math.sin(phase) * WalkCamera.BOB_ROLL * intensity
        pitch = pitch + math.cos(phase * 2) * WalkCamera.BOB_PITCH * intensity
    end

    -- 2. HANDHELD SWAY --------------------------------------------------------
    if swayScale > 0 then
        state.swayTime = state.swayTime + dts
        local t = state.swayTime

        -- Incommensurate frequencies so the pattern never visibly repeats
        local amp = swayScale * MathUtil.lerp(1.0, 0.7, state.idleBlend)

        pitch = pitch + (math.sin(t * 1.11) + math.sin(t * 2.37) * 0.55) * WalkCamera.SWAY_PITCH * amp
        yaw = yaw + (math.sin(t * 0.83) + math.sin(t * 1.97) * 0.6) * WalkCamera.SWAY_YAW * amp
        roll = roll + (math.sin(t * 0.67) + math.sin(t * 1.53) * 0.5) * WalkCamera.SWAY_ROLL * amp

        offsetX = offsetX + math.sin(t * 0.71) * WalkCamera.SWAY_TRANSLATION * amp
        offsetY = offsetY + math.sin(t * 0.94) * WalkCamera.SWAY_TRANSLATION * 0.7 * amp

        -- 3. BREATHING --------------------------------------------------------
        state.breathPhase = state.breathPhase + WalkCamera.BREATH_RATE * math.pi * 2 * dts
        if state.breathPhase > math.pi * 2 then
            state.breathPhase = state.breathPhase - math.pi * 2
        end

        -- Fades in at rest, deepens after a run
        local exertion = 1 + math.clamp(speed / WalkCamera.RUN_SPEED, 0, 1) * 0.8
        local breath = math.sin(state.breathPhase) * swayScale * state.idleBlend * exertion
        offsetY = offsetY + breath * WalkCamera.BREATH_VERTICAL
        pitch = pitch + breath * WalkCamera.BREATH_PITCH
    end

    -- SMOOTH --------------------------------------------------------------
    -- Low pass the gait layers to remove speed/frame jitter; landing spring is
    -- added after and left sharp.
    local alpha = math.min(1, dts * WalkCamera.SMOOTHING_RATE)
    state.smoothedX = state.smoothedX + (offsetX - state.smoothedX) * alpha
    state.smoothedY = state.smoothedY + (offsetY - state.smoothedY) * alpha
    state.smoothedPitch = state.smoothedPitch + (pitch - state.smoothedPitch) * alpha
    state.smoothedYaw = state.smoothedYaw + (yaw - state.smoothedYaw) * alpha
    state.smoothedRoll = state.smoothedRoll + (roll - state.smoothedRoll) * alpha

    offsetX, offsetY = state.smoothedX, state.smoothedY
    pitch, yaw, roll = state.smoothedPitch, state.smoothedYaw, state.smoothedRoll

    -- 4. LANDING RECOIL -------------------------------------------------------
    if landScale > 0 then
        if not mover.isGrounded then
            state.lastAirVelocityY = mover.currentVelocityY or 0
        elseif not state.wasGrounded then
            -- Just touched down. Kick the spring in proportion to how hard.
            local fallSpeed = -math.min(state.lastAirVelocityY, 0)
            if fallSpeed > WalkCamera.LANDING_MIN_DROP then
                local strength = math.clamp(fallSpeed / WalkCamera.LANDING_MAX_FALL_SPEED, 0, 1)
                state.landVelocity = state.landVelocity - WalkCamera.LANDING_KICK * strength * landScale
            end
            state.lastAirVelocityY = 0
        end

        -- Damped spring, sub-stepped so a long frame can't blow it up
        local remaining = dts
        local w = WalkCamera.LANDING_OMEGA
        local z = WalkCamera.LANDING_ZETA
        while remaining > 0 do
            local step = math.min(remaining, 0.005)
            remaining = remaining - step
            local acc = -w * w * state.landOffset - 2 * z * w * state.landVelocity
            state.landVelocity = state.landVelocity + acc * step
            state.landOffset = state.landOffset + state.landVelocity * step
        end

        state.landOffset = math.clamp(state.landOffset, WalkCamera.LANDING_LIMIT_DOWN, WalkCamera.LANDING_LIMIT_UP)

        offsetY = offsetY + state.landOffset
        -- Dipping also nods the head forward
        pitch = pitch + state.landOffset * WalkCamera.LANDING_PITCH_RATIO
    end

    state.wasGrounded = mover.isGrounded

    -- APPLY -------------------------------------------------------------------
    local maxOffset = WalkCamera.MAX_OFFSET
    local maxAngle = WalkCamera.MAX_ANGLE

    setTranslation(node,
        math.clamp(offsetX, -maxOffset, maxOffset),
        math.clamp(offsetY, -maxOffset, maxOffset),
        math.clamp(offsetZ, -maxOffset, maxOffset))

    setRotation(node,
        math.clamp(pitch, -maxAngle, maxAngle),
        math.clamp(yaw, -maxAngle, maxAngle),
        math.clamp(roll, -maxAngle, maxAngle))
end
