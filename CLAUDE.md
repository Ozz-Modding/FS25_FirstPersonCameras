# FS25_FirstPersonCameras

FS25 mod (Lua + XML). Adds head and body movement to the first person view, on foot and in a vehicle.
Client side and purely cosmetic — no gameplay effect, no network traffic, nothing saved into the savegame.

## How to talk to me

Write like a person explaining something to a colleague, not like a design document.

- **Plain words.** Say "the view dips" not "a vertical displacement is applied".
- **Ask one thing at a time, and say what it means.** Describe options by what happens in the game, not by their technical name.
- **Short.** Cut the setup, ask the question.
- **Don't pad.** No restating what I just said, no listing options you already ruled out.
- **Recommend, then explain.** Lead with what you think we should do and why in one line.
- **Answer the question I asked.**

## Architecture

`src/main.lua` — mod event listener, keybinds and the three hooks. Nothing else installs hooks.

`src/WalkCamera.lua` — on-foot head movement. Four stacked layers: footstep bob, handheld sway,
breathing, landing recoil.

`src/VehicleSeat.lua` — seat and body suspension for vehicle cameras. Six damped springs (three
translational for the seat, three rotational for the head) plus engine vibration.

`src/FPCSettings.lua` — settings store and the controls injected into the base Settings page.
Persists to `modSettings/FS25_FirstPersonCameras.xml` in the user profile.

## The two load-bearing facts

**1. The base game's on-foot view bobbing is present but zeroed.**
`PlayerCamera.ROLL_BOBBING`, `HORIZONTAL_BOBBING`, `VERTICAL_BOBBING` and
`MAXIMUM_BOBBING_OSCILLATION` are all `0`, so `PlayerCamera:tryApplyViewBobbing` runs but does
nothing. Filling those constants in is tempting and wrong: they drive one crude sine, and the
translation they write goes onto `cameraRootNode`, which the third person camera also uses for zoom.

Instead `WalkCamera` inserts its own transform group between `cameraRootNode` and
`firstPersonCamera` and drives that. The first person camera is linked to `cameraRootNode` with an
identity transform and nothing ever writes to it, so re-parenting is invisible to the game. The game
keeps full ownership of pitch, yaw, roll and zoom; we only write to a node it does not know about.
That is what makes the effect free of drift — there is no shared value to accumulate into.

Hooked from `PlayerCamera.updatePosition`, which is the last thing
`PlayerOnFootStateMachine:updateAsCurrent` does to the camera each frame.

**2. Vehicle cameras are re-posed from scratch every frame, so we can post-process them.**
`VehicleCamera:update` ends by writing the camera node's pose (via `setSeparateCameraPose` for the
smoothed inside cameras, or plain `setTranslation`/`setRotation` for the rest). We append to
`VehicleCamera.update` and rewrite that pose. Because the game recomputes it from `rotX`/`transX`
next frame, our offset cannot accumulate.

The offsets have to be expressed in the *cab's* frame, not the camera's — if you look out the side
window, a bump is still vertical. So the apply step runs the camera's world pose through a three
node chain (`frame` on the mount, `delta` holding our offsets, `proxy` holding the camera relative
to the mount) rather than offsetting along the camera's own axes.

## Where the motion comes from

Nothing is scripted against speed or terrain. `VehicleSeat` finite-differences the world transform
of the node the camera hangs off — twice for linear acceleration, twice for angular — and feeds
that into damped springs. This is the same technique `Suspensions:onUpdate` uses for cab suspension
nodes (`vehicles/specializations/Suspensions.lua`), except that only a handful of vehicles ship
suspension data and the feature is off by default. Measuring instead means it works on every
vehicle and automatically picks up whatever wheel suspension, articulation or cab damping the
vehicle already has.

Two guards matter and should not be removed: the per-axis acceleration clamp, and the teleport
check that resets the springs when the mount jumps more than a few metres in one frame. Without
them a physics hiccup or a vehicle reset snaps the view.

**Rotation sign calibration.** `VehicleSeat.calibrateRotationSigns()` rotates a scratch node by a
known amount at load and reads back which way its axes went. The measured attitude is world
referenced (how far the nose is raised, how far the right side is raised) but has to be fed back
through `setRotation` as Euler angles, and guessing the engine's handedness would silently turn the
head *lag* into a head *lead*. Asking costs three lines and cannot be wrong.

## Playing well with other camera mods

The vehicle hook is installed from `FSBaseMission.onStartMission`, not at file scope, and that is
deliberate. Indoor Camera Position (`FS25_indoorCamPosition`) replaces `VehicleCamera.update` with
its own full copy of the function and never calls `superFunc`, so anything appended to `update`
before it loads is silently dropped. Mods load alphabetically, `FirstPersonCameras` sorts before
`indoorCamPosition`, so at file scope we lose every time. Don't move it back up.

`onStartMission` specifically, rather than `Mission00.load`, for two reasons. It is the last thing to
run before you get control, so it also beats mods that install their overwrite from `loadMap` or from
their own load hook — file scope is not the only place mods patch from. And `FSBaseMission` is where
`onStartMission` is really defined, so hooking it cannot shadow an inherited function; `Mission00.load`
happens to be safe (Mission00 defines its own `load`) but only by luck. `Mission00:onStartMission`
calls `Mission00:superClass().onStartMission(self)`, so a prepend on the base does fire.

Realistic First Person and Cab Cinematic are fine: RFP prepends and appends to `VehicleCamera.update`
without replacing it, and Cab Cinematic doesn't touch `update` at all.

## Keybinds

`FPC_TOGGLE_WALK` (Right Ctrl + B) and `FPC_TOGGLE_VEHICLE` (Right Ctrl + N), both registered by
overwriting `PlayerInputComponent.registerGlobalPlayerActionEvents`. That function is called twice —
once for the on-foot context and again with `Vehicle.INPUT_CONTEXT_NAME` when you get into
something — which makes it the one place to register a binding that has to work in both.

It also switches the input context back before it returns, so registering after `superFunc` without
re-entering the target context puts the binding in whichever context happened to be current. The
hook re-enters it explicitly.

## One trap in the gait curve

The vertical bob is `-cos(2 * stridePhase)`, not `abs(sin(stridePhase))`. `abs(sin)` is the shape
you reach for — a dip per step, never rising above the neutral line — but it has a corner at every
footfall, and a corner in position is an instantaneous reversal of velocity. That reads as a judder
twice a step rather than as a footfall. Any replacement curve has to be smooth at the footfall.

Cadence is also deliberately not derived from real stride lengths. The game walks at 4 m/s and runs
at 7, which are not human speeds; feeding those into a real 0.85 m stride gives nearly five steps a
second. The stride constants are stretched to keep cadence around two steps a second instead.

## Tuning the vehicle springs

`fpcDebug` in the console toggles a peak-held readout of what the springs are actually being fed —
cab acceleration, cab angular acceleration, the resulting seat travel and head lean, and the share of
frames on which the cab did not move at all. Use it before changing a gain.

**Every measured quantity carries its own clock.** This is the single biggest source of wrong
numbers in this file, and it has bitten twice.

The quantities we sample do not all change at the same rate. The cab's transform is interpolated up
to the render rate, so it moves a little every frame. The physics engine's velocity is not — it is
piecewise constant and changes only when the physics steps. Divide either by the other's interval and
the answer is wrong by the ratio between them.

What that looks like in the game: in the cab of a tractor on flat tarmac at 25 mph the readout showed
81.5 m/s² fore/aft, 14.0 sideways and 4.7 vertically, where the truth on all three is near zero. The
tell is that the errors are ordered exactly by how far the cab travels on each axis — a bad interval
scales every axis by the same fraction of its own motion, where noise would not. Fore/aft is always
worst because it carries the road speed, and 8g of imaginary braking is what made the view lurch.

So each measured value gets its own accumulator, holding the wall time since *that* value last
changed: `sincePos`, `sinceVel`, `sinceAtt`. Then it does not matter which quantity is interpolated
or at what rate either loop runs.

Two dead ends, recorded so they are not tried again. Differentiating everything against the render
frame time is wrong whenever a quantity is not interpolated. Differentiating everything against
`g_physicsDtNonInterpolated` is wrong the other way, for the quantities that *are* interpolated —
that was the second attempt and it made the fore/aft axis worse. Neither one clock nor the other
works, because the premise that one clock fits everything is what is wrong.

**Prefer `getLinearVelocity` over differencing a position.** Every differentiation multiplies noise
by the sample rate, and the velocity from the physics body is exact and free. It also sidesteps the
clock question for the linear axes entirely, because a value that changes only at physics steps is
trivially easy to time correctly — you just wait for it to change. `getBodyNode` finds the body via
`Vehicle:getParentComponent`; when there is none, the code falls back to differencing position on its
own clock.

The `speed measured / vehicle says` line in the readout is the timing check, and it is the first
thing to look at when the numbers seem wrong. Those two must agree. If the measured speed is out by
even a few per cent, the sample interval is wrong and every acceleration derived from it is wrong by
a far larger margin.

**Head lean needs the g-force, not just the angular acceleration.** The head springs carry two
drive terms. `gain` is on the cab's angular acceleration and is the bump term. `gGain` is on the
cab's linear acceleration and is the cornering and braking term. Only the second one is sustained,
and only the second one produced anything you could see.

Measuring said so plainly: full lock in a tractor put 12.3 rad/s^2 of roll into the spring and got
0.63 degrees of lean out. That is not a weak spring. 12 rad/s^2 is not a tractor rolling over, it is
noise from differencing the attitude twice, and a 1.6 Hz spring is right to reject a spike that
sharp. A steady corner holds a constant yaw rate, so its yaw *acceleration* is zero — there was no
sustained component in that signal for any amount of gain to find.

The two terms take opposite signs. Angular is a lag (`-pitchAcc`): the cab pitches and your head is
late. Linear is a throw (`+localAccZ`): your body goes against the acceleration, so braking pitches
your head down. Yaw gets no g term — nothing twists you about your own spine.

Pitch runs a much lower `gGain` than roll because the two inputs are not alike. Fore/aft acceleration
in this game is spiky and lateral is smooth: the brakes bite hard and briefly, so a stop from walking
pace peaks over 1.2 g for a fraction of a second, where a steady corner holds a real ~5 m/s². With
both gains near 1, a 6 mph stop nodded the head 5.3 degrees while the same settings gave a well
judged 2.4 degrees of roll at full lock. Don't re-equalise them.

The springs are linear, so read a gain straight off the readout rather than guessing at it: the
lean is proportional to `gGain`, so one measured (acceleration, lean) pair and a target lean gives
the number outright.

But land the final number by driving, not by calculating. Both gGains ended up around a third of
what the physics of a body under 1 g says they should be. That is not an error in the derivation —
it is that a real driver sees their own body move in their peripheral vision and feels the force in
their inner ear, and gets neither of those here, so the same angle reads as the camera being yanked
rather than as their own head moving. About a degree of pitch under braking is the ceiling before it
stops feeling like you.

**Rotation is the only thing that moves the distant world.** Worth keeping in mind when a change
looks like it did nothing. Sliding the seat 37 mm sideways swings the door pillar, half a metre from
your eye, through about 6 degrees, and a barn a hundred metres off through 0.03 — invisible. So
translation on its own always reads as the cab swimming around a driver who is nailed in place, no
matter how large you make it. If the complaint is that the world does not move, the answer is in the
head springs, never in the seat travel.

**The vertical `gain` is 1.0 and should stay there.** The spring is

    x'' = -w^2 x - 2 zeta w x' - gain * a_cab

with `x` the seat's position relative to the cab. For a mass on a spring whose base is being shaken —
which is what a seat is — the textbook coefficient on base acceleration is exactly 1. Any smaller
value is a fudge that makes the seat stiffer than its stated frequency claims, and that is what made
the vertical axis look welded to the wheel: at 0.33 a firm bump moved the view 17 mm. Use `limit` to
keep the travel sane, not the gain. Lateral and fore/aft keep a reduced gain deliberately, because a
seat barely slides sideways — what moves there is your braced body, not the seat.

Travel is `gain / omega^2` per unit of cab acceleration, so a softer spring moves further for the
same gain and the two cannot be tuned independently.

**Engine vibration frequencies must stay well under the frame rate.** Anything approaching half of
it aliases — the samples walk around the waveform instead of tracing it — and the result is a
violent random shake that turning the amplitude down does not fix, because the amplitude was never
the problem. The frequency is capped at a fifth of the current frame rate for that reason, and the
second component is a sub-harmonic rather than a harmonic so it cannot alias either.

## Tuning

Every amplitude and spring parameter is a named constant at the top of `WalkCamera.lua` and
`VehicleSeat.lua`. Spring frequencies are in Hz and damping is a ratio, so they read directly: the
seat is 1.55 Hz and underdamped because a real air seat rebounds once rather than deadening the hit.
The settings page scales each layer on top, with `Off` at one end, so a layer can be killed without
touching code. Braking nod and cornering lean get a slider each rather than sharing the head one,
because they are driven by different measurements and want different gains — see the `gGain` note
above. Both multiply on top of the head scale, so tuning them in game and then folding the result
back into `gGain` is the intended loop.

## Build

`package.bat` zips the mod (excluding `.git`, `.bat`, `.md`, `refs`), `moveDebug.bat` drops it into
the FS25 mods folder unzipped for fast iteration, `moveZip.bat` for a release copy.

Reference: decompiled FS25 Lua at `../Reference/FS25_Lua`. The relevant files are
`player/PlayerCamera.lua`, `player/PlayerMover.lua`, `player/stateMachine/PlayerOnFootStateMachine.lua`,
`vehicles/VehicleCamera.lua`, `vehicles/specializations/Suspensions.lua`.
