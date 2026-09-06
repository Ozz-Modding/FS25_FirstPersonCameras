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

**Never differentiate the cab's transform against frame time.** Vehicle transforms are written by
the physics step, so render frames in between see the cab exactly where they saw it last.
Differentiating that every frame samples a staircase, and the fiction that falls out is enormous —
on flat ground at 30 km/h it reads over 1000 m/s² of fore/aft acceleration where the truth is zero,
which is more than enough to slam the fore/aft spring into its travel limit and back. Fore/aft is
always the worst axis because it is the one carrying the vehicle's actual travel.

Two things make this easy to get wrong. It scales with frame rate, and it **disappears entirely when
the render rate equals the physics rate** — so testing at a locked 60 fps says the code is fine when
it is not.

The fix in `update()` is to accumulate `g_physicsDtNonInterpolated`, which is how far the physics
actually advanced this frame and is zero on frames where it did not step, and to take a measurement
only when that accumulator is non-zero, dividing by it. That gives zero fiction at every frame rate
tested (30 through 240) and passes a real 1.5 Hz bump through at unity gain. The springs still
integrate every frame, so the output stays smooth; only the measurement waits.

The still-frame percentage in the readout is that accumulator being zero. A high figure is normal and
harmless above 60 fps — it is only a symptom if something has started differentiating against frame
time again.

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
touching code.

## Build

`package.bat` zips the mod (excluding `.git`, `.bat`, `.md`, `refs`), `moveDebug.bat` drops it into
the FS25 mods folder unzipped for fast iteration, `moveZip.bat` for a release copy.

Reference: decompiled FS25 Lua at `../Reference/FS25_Lua`. The relevant files are
`player/PlayerCamera.lua`, `player/PlayerMover.lua`, `player/stateMachine/PlayerOnFootStateMachine.lua`,
`vehicles/VehicleCamera.lua`, `vehicles/specializations/Suspensions.lua`.
