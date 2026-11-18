-- AutoCatch v4 — predicted-hit only, range independent.
--
-- v3 pressed continuously while *any* enemy ball was in flight. Two consequences:
--   * every ball the player merely brushed got converted into a catch, because a
--     press runs ThrowFX's late-catch scan over every ball currently bouncing off
--     the player, and that scan has no notion of "aimed at me";
--   * presses fired when nothing was inbound, which is noise, not catching.
--
-- v4 presses only while the game's own predictor says a ball will intersect the
-- player's capsule within CONFIG.pressLead seconds. That is the exact predictor
-- behind IncomingWarning (same candidate filter, same segment stepping, same
-- capsule test, same radius), so the script and the on-screen arrow agree.
--
-- Timing rule, taken from ThrowFX.catching():
--   contactTime - pressTime must land in [-0.03, +0.36]
-- so the press must exist before contact, not after it. v4 therefore opens the
-- press 0.30 s out and refreshes every 20 ms until the ball resolves, which keeps
-- the newest press inside the window no matter which frame contact lands on. The
-- timestamp is biased 20 ms into the past to survive a press that fires a frame
-- after the server already resolved the hit.
--
-- The press is the game's own path, not a forgery:
--   CatchPressT attribute -> Action:FireServer("Catch", serverTime) -> ThrowFX.MarkAction
--
-- Handout rule, v6: a sidelined player returns to the field by taking a ball from
-- a teammate and hitting someone with it. ThrowFX marks those throws kind="pass",
-- and they are aimed at the player's own feet, so any dodge, juke or turn moves
-- him off the ball he needs. While eliminated, pass-kind balls are dropped from
-- the threat set before the predictor sees them. Enemy attacks still register.

-- Reload guard. A reload is a fresh execution of this file, so without this the
-- previous instance keeps its own connections, its own press schedule and its own
-- dash alive beside the new one, and every measurement afterwards is the sum of
-- two assistants. The previous run publishes `unload`; call it first, so loading
-- this file is always exactly one instance no matter how many times it is run.
do
	local previous = getgenv and getgenv().__autocatch
	if type(previous) == "table" and type(previous.unload) == "function" then
		pcall(previous.unload)
	end
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local DodgeFX = ReplicatedStorage:WaitForChild("DodgeFX")
local DodgeGame = ReplicatedStorage:WaitForChild("DodgeGame")
local Shared = require(DodgeFX:WaitForChild("Shared"))
local ThrowFX = require(DodgeFX:WaitForChild("ThrowFX"))
local Ballistics = require(DodgeGame:WaitForChild("Ballistics"))
local GameConfig = require(DodgeGame:WaitForChild("GameConfig"))
local TargetPoint = require(DodgeGame:WaitForChild("TargetPoint"))
local DodgeAnims = require(DodgeGame:WaitForChild("DodgeAnims"))
local Action = DodgeGame:WaitForChild("Remotes"):WaitForChild("Action")
-- Catch answers arrive on FX, not Action: CatchRefused is broadcast as a Stance
-- event beside the throw and dodge effects, and it is the only word on whether a
-- press could count.
local FX = DodgeFX:WaitForChild("Remotes"):WaitForChild("FX")
local DodgeMatch = ReplicatedStorage:WaitForChild("DodgeMatch")

local CONFIG = {
	toggleKey = Enum.KeyCode.RightShift,

	-- Where the press schedule opens. The judge accepts a stamp whose age at
	-- contact is at most CATCH_WINDOW, so the schedule is defined by that window
	-- rather than by a press count: a stamp older than the window at contact can
	-- never catch, whatever the ball does, and a stamp inside it catches whenever
	-- the prediction holds. Re-pressing is free - a refused press is answered on
	-- CatchNote but does not arm CatchReadyAt (measured: the attribute does not
	-- move), which is why the old one-press budget was leaving the last third of a
	-- second with nothing to send and nothing to fall back to.
	pressLead = 0.220,

	-- Ceiling on the refresh cadence. The live cadence is derived from the judge
	-- window in the decision loop; this only caps it for a window that reads long.
	pressInterval = 0.600,

	-- Timestamp skew. The stamp is sent as now - bias, so a frame that fires just
	-- after contact still reads as a press made before it.
	pressBias = 0.012,

	-- Keep pressing this long after the last clean prediction, so the local bounce
	-- window is covered even if the predictor loses the ball at contact.
	tail = 0.12,

	-- Detection horizon and radius, identical to IncomingWarning.
	horizon = 1.00,

	-- Turn toward a predicted hit this far out, and hold the turn for a moment.
	faceHorizon = 1.20,
	faceHold = 0.35,

	-- Safety net for the predictor: a ball this close and closing is going to
	-- touch the capsule regardless of how the extrapolation reads.
	pointBlank = 4.0,

	autoFace = true,
	showLabel = true,

	-- ThrowFX.catching() returns false, "has a ball" while the player is holding
	-- one, so a second inbound ball cannot be caught until the held ball leaves the
	-- hand. When a hit is predicted and the hands are full, throw it.
	autoThrow = true,
	throwCooldown = 0.38,
	throwRange = 170,
	throwFallback = 120,

	-- Perfect throw: solve the intercept the way the game's own hit test reads it.
	perfectThrow = true,

	-- Silent aim. Rewrites the aim point on the game's own Throw remote so the
	-- shot lands on the solved intercept no matter where the mouse is pointing.
	-- The camera is never touched: manual aim stays exactly where the player put it.
	silentAim = true,

	-- Also stamp the resolved enemy into the throw payload, so the server
	-- associates the hit with the model the ball was aimed at.
	silentTarget = true,

	-- Keep LocalPlayer.LockOnTarget pointed at the current target. DodgeInput's
	-- own chooseAim falls back to it for a mouse throw that hits nothing, which
	-- keeps the character's turn and the local FX prediction in sync with the
	-- rewritten aim.
	lockOnTarget = true,

	-- Camera lock. Off by default: silent aim does the redirect without touching
	-- the view. Left in for anyone who wants the old hold-to-lock behaviour.
	autoAim = false,
	aimButton = Enum.UserInputType.MouseButton2,
	aimRange = 200,

	-- Re-entry throw. An eliminated player picks a ball up off the floor and
	-- throws it at a live enemy to get back on the field. That throw is a shot at
	-- a specific opponent from a standing start with the whole arena watching, and
	-- firing it the instant the ball is grabbed lands nowhere: the pickup has no
	-- wind-up, the aim has not settled, and the receiver is whoever happened to be
	-- nearest on that frame.
	--
	-- So it is the player's throw. Auto-throw stays on for normal in-round play;
	-- this switch governs only the sidelined pickup, and it is off by default.
	-- Silent aim and the aim-lock still apply to the manual throw, because they
	-- live on the game's own Throw remote rather than on this path.
	autoReentry = false,

	-- One decision pass per this many seconds, shared by both samplers. The old
	-- loop ran the full predictor twice per frame; at 120 fps that is CPU the
	-- network thread then has to compete with.
	tickInterval = 0.012,

	-- Juke: when a hit is predicted and catching is impossible (holding, cooldown,
	-- out of window) the hit test still leads the player by half its own flat
	-- velocity across the view delay, so plain strafing gets caught. Reversing the
	-- horizontal velocity flips that lead away from the body for a frame.
	juke = true,
	jukeCooldown = 0.40,
	jukeSpeed = 26,

	-- Dash. The server's own i-frames are the only thing that stops a ball the
	-- 0.6 s catch cooldown has already made uncatchable. throwFX judges them as
	-- [dodge - 0.03, dodge + 0.26], so contact has to land near the middle of that
	-- 0.29 s span, not at its far edge. A 0.24 lead put contact 0.02 s before the
	-- window closed, and every prediction that ran even slightly long ate the hit:
	-- that is what a close-range hit looks like, contact at tti ~= -0.05 with the
	-- dash already spent. At 0.15 the window has 0.14 s of slack on either side,
	-- and 9.6 studs of lateral displacement still clears HIT_RADIUS (1.3).
	autoDodge = true,
	dodgeLead = 0.150,

	-- Sidestep. When the dash is inside its 2.2 s cooldown there is no cooldown
	-- left to spend, so the body keeps walking out of the ball's line instead of
	-- standing in it. Scoped to a live prediction and released immediately after.
	sidestep = true,
	sideLead = 0.360,
	jukeLead = 0.120,
}

-- Numeric configuration ---------------------------------------------------------
--
-- Every key listed here feeds geometry: a comparison, a horizon, a lead. A
-- non-number in that position is not a preference, it is a fault - the comparison
-- throws inside a hot path and the tick loses its answer, which reads exactly like
-- a ball that was never seen.
--
-- This is not hypothetical. The UI library's Round() does:
--
--     z = tostring(z)
--     return z:find(".") and tonumber(...) or z
--
-- so a value with no decimal point comes back as the STRING it was given, and
-- Slider:SetValue runs its changed callback during window creation. A slider whose
-- default is an integer therefore hands this table "1" before the user has touched
-- anything, and the physical body answer dies with a type error on every tick
-- while the catch and dash paths keep working. The string is invisible in a
-- counter and obvious in a type check, so: coerce on write, re-assert on load, and
-- a selftest row that fails if one ever gets through.
local NUMERIC_CONFIG = {
	"pressLead",
	"pressInterval",
	"pressBias",
	"tail",
	"horizon",
	"faceHorizon",
	"faceHold",
	"pointBlank",
	"throwCooldown",
	"throwRange",
	"throwFallback",
	"aimRange",
	"tickInterval",
	"jukeCooldown",
	"jukeSpeed",
	"dodgeLead",
	"sideLead",
	"jukeLead",
}

local function normalizeConfig()
	local repaired = {}
	for _, key in ipairs(NUMERIC_CONFIG) do
		local raw = CONFIG[key]
		if type(raw) ~= "number" then
			local value = tonumber(raw)
			if value then
				CONFIG[key] = value
				repaired[#repaired + 1] = key
			end
		end
	end
	return repaired
end

-- The write boundary. A slider hands back whatever the library decided the value
-- is; the table is ours and it only ever holds a number.
local function setNumber(key, value)
	local number = tonumber(value)
	if number then
		CONFIG[key] = number
	end
end

local OUT_ATTR = Shared.ATTR.Out
local CATCH_ANGLE_COS = math.cos(math.rad(GameConfig.CATCH_ANGLE or 120))
local CATCH_RADIUS = GameConfig.BALL_RADIUS + GameConfig.HIT_RADIUS

-- The body lane deliberately reaches further than the catch lane. `CATCH_RADIUS`
-- is what the catch judge uses to decide a ball is catchable; it is not what the
-- hit judge uses, and the difference is not observable from the payload.
-- Measured: `Ball_m158` read a constant `miss=2.64` then `3.00` on its approach,
-- closed to 3.2 studs with `tca=0.007`, and took the life anyway - a predicted
-- clearance of 0.6 studs on a ball the server scored as a hit. The body does not
-- get to be wrong in that direction: dashing a ball that would have passed costs
-- a dash, missing one that arrives costs a life.
local BODY_HEADROOM = 0.6
local BODY_RADIUS = CATCH_RADIUS + BODY_HEADROOM
local STEP = 0.022222222222222223

-- Dodge sizing. `DODGE_MARGIN` is what the body has to add to the tracker's own
-- predicted miss before the hit test is out of reach: one stud for the frames
-- spent accelerating to dash speed and a little for the draw lag on the ball.
-- `DODGE_MIN_TRAVEL` keeps a dash that only needed a nudge from reading as a
-- stutter; `DODGE_MAX_LIFE` is the ceiling that keeps a dash against a wall from
-- running until the next round.
local DODGE_MARGIN = 0.6
local DODGE_MIN_TRAVEL = 1.2
local DODGE_MAX_LIFE = 0.30

-- How far the body has to travel along `off` to clear the ball, given that the
-- dash replaces the body's own velocity along that axis for as long as it runs.
-- `miss` is the offset the tracker predicts if nothing changes, and it already
-- includes the body's drift; what it does not include is the fact that the dash
-- takes that drift away. A body already sliding away from the line gains only
-- (dash speed - drift) per second of dash, so it owes more distance than the raw
-- gap; a body drifting into the line owes less, because the dash stops the loss
-- as well as adding to the offset. Without this a dash fired while strafing
-- lands exactly where the gap said it should and still ends up short.
local function dashOwed(miss, off, rootVel, speed)
	local clear = BODY_RADIUS + DODGE_MARGIN
	if type(miss) ~= "number" or miss < 0 then
		return clear
	end
	local owed = math.max(0, clear - miss)
	if off and rootVel then
		local drift = Vector3.new(rootVel.X, 0, rootVel.Z):Dot(Vector3.new(off.X, 0, off.Z))
		local gain = math.clamp(1 - drift / speed, 0.25, 4)
		owed = owed / gain
	end
	return owed
end

-- Escape side ---------------------------------------------------------------
--
-- The side a dash or step picks is a bet on open floor, and nothing checked it.
-- Measured live: eight directions probed from one standing spot, seven carried
-- the body 10.4-10.6 studs and one carried it 0.10. A dash aimed at that one
-- spent its whole 0.30 s at 64 studs/s pressing into geometry and travelled
-- 0.007 studs, which reads to the player as "the dodge did nothing" while the
-- 2.2 s cooldown burns. The subset of the body line the step is leaving is worth
-- less than the floor it has to cross to leave it, so a blocked side loses to an
-- open one in the opposite direction.
local FUNCTION_CLEAR_RADIUS = 1.6

-- Thin rays, not a fat shape. Every shape-cast flavour failed on the one case
-- that matters: a body already flush with geometry. A Spherecast that starts
-- overlapping reports no hit at all, and an overlap sphere wide enough to read
-- the wall ahead also reaches back across the body and reports the opposite
-- direction blocked, so a pinned body saw both sides closed and stayed put.
-- A ray from the root centre starts outside any wall the capsule can touch, so
-- it reports exactly the run of floor in the direction asked about.
local function clearRun(character, root, unit, dist)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = { character }
	local pool = Workspace:FindFirstChild("DodgeBalls")
	if pool then
		ignore[#ignore + 1] = pool
	end
	params.FilterDescendantsInstances = ignore

	local origin = root.Position
	local best = dist
	for _, dy in ipairs({ -1.6, 0, 1.6 }) do
		local from = origin + Vector3.new(0, dy, 0) + unit * 0.05
		local ok, hit = pcall(function()
			return Workspace:Raycast(from, unit * dist, params)
		end)
		if not ok then
			return best
		end
		if hit then
			local d = (hit.Position - from).Magnitude
			if d < best then
				best = d
			end
		end
	end
	return math.max(0, best - 0.05)
end

-- Returns the direction to travel and the clearance along it. The preferred side
-- is kept unless it is blocked and the other side is meaningfully more open,
-- so an ordinary dash is unchanged and a wall-pinned one flips.
local function freeSide(character, root, unit, dist)
	local want = math.max(dist, DODGE_MIN_TRAVEL)
	local ahead = clearRun(character, root, unit, want)
	if ahead >= want * 0.75 then
		return unit, ahead
	end
	local behind = clearRun(character, root, -unit, want)
	if behind > ahead + 0.5 then
		return -unit, behind
	end
	return unit, ahead
end

-- The catch window is per character: IncomingWarning reads CatchWin off the
-- character and falls back to GameConfig.CATCH_WINDOW. Reading the same source
-- keeps the press plan on the same clock as the green zone the game draws.
local function catchWindow(character)
	local value = character and character:GetAttribute("CatchWin")
	if type(value) == "number" and value > 0.02 and value < 1 then
		return value
	end

	return GameConfig.CATCH_WINDOW or 0.36
end

-- The server publishes the exact instant it will accept the next catch or dash.
-- Publishing a refusal back to the client is cheap; spending the 2.2 s dash
-- cooldown on one is not, so every gate reads the server's own number first.
local function readyAt(character, name)
	local fromPlayer = LocalPlayer:GetAttribute(name)
	if type(fromPlayer) == "number" then
		return fromPlayer
	end
	local fromCharacter = character and character:GetAttribute(name)
	if type(fromCharacter) == "number" then
		return fromCharacter
	end

	return nil
end

local S = {
	enabled = true,
	presses = 0,
	catches = 0,
	hits = 0,
	blocked = 0,
	throws = 0,
	turns = 0,
	jukes = 0,
	threatFrames = 0,
	frames = 0,
	lastPress = -math.huge,
	lastThrow = -math.huge,
	threwFor = nil,
	autoThrows = 0,
	autoThrowLast = nil,
	lastJuke = -math.huge,
	lastDodge = -math.huge,
	dodges = 0,
	dodgeUntil = 0,
	dashVel = nil,
	dashAtt = nil,
	dashTarget = 0,
	dashTravel = 0,
	dashUnit = nil,
	dashBlocked = 0,
	handbacks = 0,
	pathLegReset = 0,
	lastTti = nil,
	lastDir = nil,
	lastDirBall = nil,
	ballCount = 0,
	threatUntil = 0,
	faceUntil = 0,
	contactAt = nil,
	contactBall = nil,
	pressLog = {},
	byStamp = {},
	stampCount = 0,
	catchAcks = 0,
	catchLands = 0,
	ackTimes = {},
	sideOut = 0,
	sideBall = nil,
	sideUnit = nil,
	sideStamp = 0,
	catchRefusals = 0,
	pressMeta = nil,
	refuseLast = nil,
	ackLast = nil,
	dashRefused = 0,
	dodgeWhy = {},
	dodgeBy = {},
	pathJukes = 0,
	pathOpen = 0,
	pathHeld = 0,
	-- Per-rule tally for the physical body answer. Every tracked ball that is not
	-- answered lands in exactly one bucket: skipped by the candidate filter, already
	-- inside the reach radius, no usable sample yet, too slow, closest approach
	-- already past, beyond the horizon, or clearing the radius. A zero body count
	-- with a full bucket tells which rule is responsible instead of leaving it to
	-- the shape of the deaths.
	pathWhy = {},
	-- The same tally, split by which source answered. `pathWhy` alone hides the
	-- fact that the part source answers almost nothing; the segment source is the
	-- one carrying every ball this game actually throws, so its own bucket says
	-- whether the body answer is alive at all.
	pathWhySeg = {},
	-- Parts the tracker holds but that are not carrying motion (pooled seats).
	-- Kept out of `pathWhy` so that tally keeps meaning "a ball was judged".
	pathWhyPartIdle = 0,
	contactAge = {},
	-- What the tracker did with each ball part this round. `weld_far` is the one
	-- to watch: a refusal there means a ball was flying while still carrying the
	-- weld from its throw, which is the body answer going blind, not a carried
	-- ball.
	pathDrop = {},
	-- Close passes, newest last, with the raw geometry. A path count of zero over
	-- a round can only be explained by looking at what the tracker actually saw
	-- in the last metre, so this ring is the live witness.
	pathClose = {},
	-- Full flight recorder: every tracked ball within 20 studs of the body,
	-- every tick, whatever the verdict. The close ring answers "how close did it
	-- get"; this answers "what was known in the last second", which is the only
	-- question that matters after a life drops.
	pathWide = {},
	-- First sighting of every ball the lane could answer, with the distance it
	-- was at. Separates "the ball was never visible" from "it was visible and
	-- every answer was gated", which are different faults with the same symptom.
	sightLog = {},
	-- Every six-stud crossing with the press age and the judge band at that
	-- instant. A press that exists but lands in `late` means the prediction, not
	-- the press, is what lost the ball.
	near6Log = {},
	pathMinMiss = math.huge,
	pathMinMissAt = nil,
	lastPhysicalTti = nil,
	pressStamp = nil,
	contactLog = {},
	contactOk = 0,
	contactBad = 0,
	contactNoStamp = 0,
	contactLogged = nil,
	hist = {},
	histClock = 0,
	deathSnap = nil,
	deathHow = nil,
	heartbreaks = 0,
	hbLog = {},
	hitImpacts = 0,
	lastImpact = nil,
	refusedAt = nil,
	refusedBall = nil,
	pressedBall = nil,
	pressBall = nil,
	thrownPart = nil,
	thrownAt = nil,
	thrownHides = 0,
	throwRefused = 0,
	throwAcks = 0,
	throwUnsafe = 0,
	throwPending = nil,
	throwVisual = nil,
	palmRestores = 0,
	palmGhosts = 0,
	palmInvis = 0,
	palmInvisLog = {},
	reconLog = {},
	palmLog = {},
	palmNear = nil,
	palmNearAt = 0,
	palmAt = 0,
	sidesteps = 0,
	lastSide = 0,	sidestepUntil = nil,
	sideDir = nil,
	deathLog = {},
	lastLives = nil,
	lastReason = nil,
	nearNow = nil,
	lostAt = nil,
	lostInfo = nil,
	lostCount = 0,
	trace = {},
	traceHead = 1,
	traceMax = 160,
	pressCount = 0,
	-- Dash flight records. A dash that spends its life and moves a centimetre
	-- looks identical to one that never fired unless the per-frame facts are
	-- kept, and the travel ring makes a run of dashes readable as a distribution
	-- instead of a single last value.
	dashLog = {},
	dashLogN = 0,
	dashTravels = {},
	evadeWhy = {},
	evadeLog = {},
	evadeN = 0,
	bodyLog = {},
	bodyN = 0,
	threatBalls = 0,
	unreachable = 0,
	handouts = 0,
	silentAims = 0,
	nativeThrows = 0,
	pingSum = 0,
	pingN = 0,
	pingAvg = 0,
	aimLast = nil,
	lastTick = 0,
	refusals = {},
	kinds = {},
	-- Per-class outcome tally. The complaint that started this work is a claim
	-- about two populations - bot throws and player throws - behaving differently,
	-- and no counter in the file could separate them. Every sighting, press, dash,
	-- catch and lost life now lands in exactly one bucket keyed on the ball's own
	-- `kind`, so the two populations can be compared instead of argued about.
	classTally = {},
	classLast = {},
	reject = {},
	laneReject = {},
	lastNote = LocalPlayer:GetAttribute("CatchNote"),
	pressWhy = {},
	aimHeld = false,
	aimTarget = nil,
	lockTarget = nil,
	-- Arrival race. One row per ball the instant the contact clock reaches zero:
	-- which answer was live, and whether the server would have accepted it. A
	-- death is resolved against this ring, so "dodged and still hit" becomes a
	-- verdict instead of a shrug.
	race = {},
	raceHead = 1,
	raceMax = 24,
	raceTally = {},
	raceHit = {},
	raceLast = nil,
}

local bodyCache = setmetatable({}, { __mode = "k" })

-- Movement-edge tally. Every decision in this file is made without ever reading a
-- key: there is no gate on movement input anywhere in the catch, dash or sidestep
-- path. What movement changes is the body's velocity and who owns Humanoid:Move,
-- so the only way to answer "does holding a key weaken the assist" is to bucket
-- each decision by whether a movement key was held on that tick and compare the
-- rates per threat seen. `seen` is the denominator: a bucket with fewer presses
-- is only a fault if it also saw threats.
S.heldInput = false
S.edge = { free = {}, hold = {} }

local function edge(kind)
	local bucket = S.edge[S.heldInput and "hold" or "free"]
	bucket[kind] = (bucket[kind] or 0) + 1
end

-- The hit counter is a session-cumulative attribute, so a reload mid-round has to
-- seed from it or every later reading understates the damage taken.
S.hits = tonumber(LocalPlayer:GetAttribute("HitsTaken")) or 0

-- Port of IncomingWarning.timeToHit: same segment stepping, same steer handling,
-- same capsule test, same radius. rootVel is injectable so the self-test can pin
-- the player's velocity instead of reading it off the live assembly.
local function timeToHit(state, character, rootPart, body, now, horizon, radius, rootVel)
	local seg = state.seg
	if not seg then
		return nil
	end

	local t = math.max(now, seg.t0)
	local prevPos = Shared.PosAt(seg, t - seg.t0)
	local rootPos = rootPart.Position
	local vel = rootVel or Ballistics.SteerVel(rootPart.AssemblyLinearVelocity)
	local ballVel = Shared.VelAt(seg, t - seg.t0)
	local delta = rootPos - prevPos

	if ballVel.Magnitude * horizon + 30 < delta.Magnitude then
		return nil
	end

	if 8 < delta.Magnitude and ballVel:Dot(delta) <= 0 then
		return nil
	end

	local steering = false
	if state.target == character then
		steering = state.steerNext ~= nil
	end

	local steerNext = state.steerNext
	local endT = now + horizon
	local origin = now

	while t < endT do
		local nextT = t + STEP

		while steering do
			if not (steerNext <= nextT) then
				break
			end

			local steerAt = steerNext
			steerNext = steerAt + Ballistics.STEER_STEP

			if t < steerAt then
				local newSeg, done = Ballistics.SteerStep(
					seg,
					steerAt,
					rootPos + vel * (steerAt - origin),
					vel
				)

				if done then
					steering = false
				end
				if newSeg then
					seg = newSeg
				end
			end
		end

		local curPos = Shared.PosAt(seg, nextT - seg.t0)
		local hit, frac = Ballistics.BodyHit(
			prevPos,
			curPos,
			rootPos + vel * (nextT - origin),
			body,
			radius
		)

		if hit then
			return t + (nextT - t) * frac - origin
		end

		prevPos = curPos
		t = nextT
	end

	return nil
end

-- Handout filter --------------------------------------------------------------
--
-- A sidelined player gets back into the round by taking a ball from a teammate,
-- throwing it and hitting someone. The ball arrives as a *pass*, and it is aimed
-- at exactly where the player is standing. Every evasion path in this script
-- moves the body off that line, so treating a pass as a threat while eliminated
-- throws away the only route back onto the field.
--
-- While eliminated the only thing worth doing with an inbound ball is standing
-- still and letting it arrive, so passes are filtered out of the threat set
-- entirely. Enemy attacks still register (they cost nothing to dodge, and the
-- point-blank net must not be widened to cover passes).

-- Throw classification -------------------------------------------------------
--
-- The two populations this file has to serve are keyed by the ball's own `kind`,
-- which ThrowFX derives from the thrower's identity: a character owned by a
-- Player is `attack`, one that is not is `bot`, and anything marked as a pass is
-- `pass`. That marker is the authoritative answer to "who threw this" and it is
-- already on every live entry, so classification is a read, not an inference.
--
-- Unknown values are kept as themselves rather than folded into a bucket: a new
-- class appearing in the game should show up in the tally by name, not be
-- silently counted against an existing population.
local function classOf(state)
	if state == nil then
		return "none"
	end

	local kind = state.kind
	if type(kind) == "string" and kind ~= "" then
		return kind
	end

	if state.botThrow == true then
		return "bot"
	end

	return "unknown"
end

-- One row per class, created on first sighting. `seen` counts ticks on which
-- decide() picked this class as the ball it would answer, which is the only
-- measure of "the assist noticed it" that is comparable across classes: a raw
-- per-tick scan would just report how many balls exist.
local function classRow(kind)
	local row = S.classTally[kind]
	if not row then
		row = {
			seen = 0,
			press = 0,
			dash = 0,
			catch = 0,
			loss = 0,
			contact = 0,
			covered = 0,
			late = 0,
			nostamp = 0,
			near6 = 0,
			answered = 0,
			ring = 0,
		}
		S.classTally[kind] = row
	end
	return row
end

local function tallyClass(kind, field)
	classRow(kind)[field] = (classRow(kind)[field] or 0) + 1
end

local function isEliminated()
	if LocalPlayer:GetAttribute("InPrison") == true then
		return true
	end
	if (LocalPlayer:GetAttribute("Lives") or 1) <= 0 then
		return true
	end

	local character = LocalPlayer.Character
	if character and character:GetAttribute(OUT_ATTR) == true then
		return true
	end

	return false
end

-- ThrowFX.Predict takes `pass = false` for an attack, so any other value on a
-- live entry means the throw was a pass. `kind` is the live marker that actually
-- matters: every ball state carries kind = "attack" | "pass" | "bot".
local function isHandout(state, character)
	if state.kind == "pass" then
		return true
	end
	if state.pass ~= nil and state.pass ~= false then
		return true
	end
	if state.passTarget ~= nil then
		return true
	end
	if state.handout == true then
		return true
	end

	return false
end

-- While sidelined, a teammate's ball cannot cost anything and may be the ball
-- that gets him back in. Belt and braces on top of the kind check: a pass that
-- arrives mislabelled, or a teammate throw that is not a pass at all, is still
-- not worth moving for when there are no lives left to lose.
local function isFriendThrow(state, myTeam)
	local thrower = state.thrower
	if not thrower or myTeam == nil then
		return false
	end

	local ok, team = pcall(function()
		return thrower:GetAttribute("Team")
	end)

	return ok and team ~= nil and team == myTeam
end

-- Exactly the filter IncomingWarning.candidate uses, minus the team gate. The
-- catch judge does not care who threw the ball, and eliminated players keep
-- throwing from the sideline, so a ball from a teammate or an outsider is still
-- a ball that will break a face. Anything predicted to touch the capsule is a
-- threat; anything that cannot touch it is not.
local function isCandidate(state, character, out, myTeam, requireCanHit, soft, lane)
	local reject = S.reject
	local function no(reason)
		reject[reason] = (reject[reason] or 0) + 1
		if lane then
			local byLane = S.laneReject[lane]
			if not byLane then
				byLane = {}
				S.laneReject[lane] = byLane
			end
			byLane[reason] = (byLane[reason] or 0) + 1
		end
		return false
	end
	if not state.seg then
		return no("noseg")
	end
	if requireCanHit ~= false and not state.canHit then
		return no("canhit")
	end
	-- `hold` means somebody is carrying this ball. The bounce flags mean it has
	-- already come off the floor or a wall, which the catch judge refuses but the
	-- hit test does not: a post-bounce ball still takes a life. The catch path has
	-- to drop them, the body path has to keep seeing them, so `soft` relaxes the
	-- bounce flags and nothing else.
	if state.hold or (not soft and (state.bounce or state.worldBounced or state.floored)) then
		return no("state")
	end
	if state.thrower == character then
		return no("self")
	end
	if state.ignore and state.ignore[character] then
		return no("ignore")
	end
	if out and (isHandout(state, character) or isFriendThrow(state, myTeam)) then
		return no("out")
	end
	return true
end

-- Live ball entries are rebuilt or replaced by ThrowFX, so the handout tally is
-- keyed weakly: a ball counted once is never counted twice, and the table does
-- not keep dead entries alive.
local handoutSeen = setmetatable({}, { __mode = "k" })

local function tallyHandouts(live, character, myTeam)
	for _, state in pairs(live) do
		if state.seg and state.canHit and (isHandout(state, character) or isFriendThrow(state, myTeam)) then
			if not handoutSeen[state] then
				handoutSeen[state] = true
				S.handouts = S.handouts + 1
			end
		end
	end
end

local function travelDir(state, now)
	local seg = state.seg
	if not seg then
		return nil
	end

	local ok, vel = pcall(Shared.VelAt, seg, math.max(0, now - seg.t0))
	if ok and typeof(vel) == "Vector3" and vel.Magnitude > 0.01 then
		return vel.Unit
	end

	return nil
end

-- Direction the ball is coming from, usable even when the segment has no
-- velocity left to read. The cone check must never be fed a stale direction from
-- a different ball: a wrong angle rejects a catch the server would have taken.
local function approachDir(state, root, now)
	local dir = travelDir(state, now)
	if dir then
		return dir
	end

	local part = state.part
	if part and part.Parent then
		local delta = root.Position - part.Position
		local flat = Vector3.new(delta.X, 0, delta.Z)
		if flat.Magnitude > 0.05 then
			return flat.Unit
		end
	end

	return nil
end

-- Returns the nearest ball that is predicted to intersect the player, its
-- time-to-impact, its travel direction, and how many candidates were considered.
-- `out` is the eliminated state: while it is true, balls the game marks as passes
-- are handouts and are dropped before they can become a threat.
local function decide(live, character, root, body, now, myTeam, rootVel, out)
	if type(live) ~= "table" then
		return nil, nil, nil, 0
	end

	local best, bestTti, bestDir, count = nil, nil, nil, 0

	for _, state in pairs(live) do
		if isCandidate(state, character, out, myTeam) then
			count = count + 1

			local ok, tti = pcall(
				timeToHit,
				state,
				character,
				root,
				body,
				now,
				CONFIG.horizon,
				CATCH_RADIUS,
				rootVel
			)

			if ok and tti and (not bestTti or tti < bestTti) then
				best = state
				bestTti = tti
				bestDir = approachDir(state, root, now)
			end
		end
	end

	if bestTti then
		return best, bestTti, bestDir, count
	end

	-- Safety net. The predictor steps 22 ms at a time and gives up after the
	-- horizon, so a ball that arrives between two steps, or one whose steered
	-- segment was rewritten by the thrower a frame ago, can reach the capsule
	-- without ever producing a hit. At this distance the extrapolation is not
	-- needed: a ball inside pointBlank that is still closing will touch. Press.
	local rootPos = root.Position

	for _, state in pairs(live) do
		if isCandidate(state, character, out, myTeam) then
			local seg = state.seg
			local t = math.max(now, seg.t0)
			local okPos, ballPos = pcall(Shared.PosAt, seg, t - seg.t0)

			if okPos and typeof(ballPos) == "Vector3" then
				local delta = rootPos - ballPos
				local dist = delta.Magnitude

				if dist <= CONFIG.pointBlank and dist > 0.01 then
					local dir = approachDir(state, root, now)

					if dir and dir:Dot(delta.Unit) >= 0.35 then
						return state, 0, dir, count
					end
				end
			end
		end
	end

	return best, bestTti, bestDir, count
end

-- Raw closest-approach threat ------------------------------------------------
--
-- ThrowFX answers nothing for a pass (canHit is false by construction) and for a
-- ball whose segment it has stopped advancing, and both still land: the server's
-- hit test does not consult canHit. Passes killed two lives in the 300 s run and
-- were invisible to every predictor above. On the last 0.35 s the flight is a
-- straight line, so the ball's own replicated motion is enough to answer whether
-- it is going to pass through the body and when.
--
-- This is no longer the body's authority - physicalThreat is - but it still says
-- "something is arriving" while the press schedule is live, and it still writes
-- the raw-contact audit row for a ball with no segment at all.
local rawTrack = setmetatable({}, { __mode = "k" })

local function rawThreat(live, character, root, now)
	if type(live) ~= "table" then
		return nil, nil
	end

	local rootPos = root.Position
	local bestTti, bestDir = nil, nil

	for _, state in pairs(live) do
		local pos = state.real

		if typeof(pos) == "Vector3" and not state.hold and state.thrower ~= character then
			local rec = rawTrack[state]

			if rec and now > rec.t and (pos - rec.pos).Magnitude > 0.01 then
				rec.vel = (pos - rec.pos) / (now - rec.t)
				rec.pos, rec.t = pos, now
			elseif not rec then
				rawTrack[state] = { pos = pos, t = now, vel = nil }
			end

			local vel = rec and rec.vel
			if vel and vel.Magnitude > 25 then
				local delta = rootPos - pos
				local speedSq = vel:Dot(vel)
				local tca = delta:Dot(vel) / speedSq

				if tca >= -0.05 and tca <= 0.35 then
					local miss = (delta - vel * tca).Magnitude
					if miss <= CATCH_RADIUS + 0.8 and (not bestTti or tca < bestTti) then
						bestTti = math.max(0, tca)
						bestDir = vel.Unit
					end
				end
			end
		end
	end

	return bestTti, bestDir
end

-- Physical ball path ----------------------------------------------------------
--
-- Every predictor above answers from ThrowFX.Live() or from a state in that map.
-- Live() is the game's own judgement model, not the set of physical balls: a
-- ball leaves it the instant it resolves, and a ball that has come off the world
-- re-enters with a segment that still extrapolates the pre-bounce line. A
-- ricochet therefore arrives with no segment predicting a hit and no velocity
-- history to derive one from, which is the point-blank hit that looks dodgeable
-- on screen: on the frame the ball appears, nothing in Live() says it is coming.
--
-- The part itself is always there. DodgeBalls holds one part per ball for the
-- whole round - parked, held, flying, bouncing, pooled - so tracking the part
-- instead of the state gives a path that survives every one of those
-- transitions.
--
-- Velocity comes from the position delta, never from AssemblyLinearVelocity. In
-- flight that field reports 64 studs/s while the ball is travelling 148, so it
-- is a false witness; the delta is the motion. A delta is discarded only when it
-- implies a re-placement rather than flight, which is what pooling to the
-- parking position looks like.
local ballPath = setmetatable({}, { __mode = "k" })

-- Fastest a ball can be *observed* to move. The ball's own ceiling is the game's
-- throw speed; the observation adds a second factor, because a client frame can
-- carry two replication samples at once and the delta is then travelled over one
-- frame instead of two. A bound below that deletes real flight exactly when the
-- frame rate dips - which is the moment the answer matters. Re-placements are not
-- near this number: pooling moves a ball hundreds of studs inside one tick, two
-- orders of magnitude above the bound, so the two regimes stay separated without
-- any tuning in between.
local PATH_MAX_SPEED =
	4 * math.max(GameConfig.PLAYER_THROW_SPEED or 140, GameConfig.THROW_SPEED or 125)

-- Fastest legal approach in the game. Used to price a ball that has no measured
-- trajectory yet, so the answer errs early rather than late.
local PATH_THROW_SPEED =
	math.max(GameConfig.PLAYER_THROW_SPEED or 140, GameConfig.THROW_SPEED or 125)

-- How close a ball must be for a trajectory-less arrival to be the body's
-- business at all. Beyond this the next sample will carry a velocity.
local PATH_NEAR = 14

-- A ball that has just been re-placed is a fresh answer for this long. Past it,
-- a record without a trajectory is a ball the tracker stopped seeing, and
-- pricing that as an arrival would walk the body away from nothing forever.
local PATH_ARRIVAL_AGE = 0.10

-- The palm, as a radius rather than an object. Used both by the display
-- reconciler below and by the tracker, which needs the same answer to "is this
-- ball at that hand" that the ghost check uses.
local PALM_RADIUS = 3.2
local PALM_DY = 2.5

-- The part a weld ties this ball to, if any. The game welds a ball to the
-- thrower's RightHand and that weld is still parented when the ball is already
-- tens of studs away, so the object's existence is not the same question as "is
-- this ball being carried". The partner's position is the honest answer, and it
-- is returned here so the tracker can report the distance rather than guess.
local function weldAnchor(part)
	local weld = part:FindFirstChildWhichIsA("Weld")
	if not weld then
		return nil
	end
	local other = if weld.Part0 == part then weld.Part1 else weld.Part0
	return other and other.Position or nil
end

-- Whether a part can carry a ball's motion at all. Anchoring is deliberately not
-- consulted: the server moves every ball by CFrame and leaves the part anchored,
-- so `not part.Anchored` selects nothing and the tracker goes blind while balls
-- fly past it. Motion is the position delta; a re-placement is rejected by the
-- speed bound below, which is the only test that needs to know about teleports.
--
-- Returns the candidate answer plus the distance to the part it is welded to, so
-- a report can separate "held in a palm" from "carrying a weld that was never
-- cleaned up". A refusal that cannot be attributed is a refusal that silently
-- blinds the body answer.
local function pathCandidate(part, exempt)
	if not (part and part.Parent) then
		return false, nil
	end
	if exempt and exempt[part] then
		return false, nil
	end
	if part:FindFirstChildWhichIsA("Weld") then
		local anchor = weldAnchor(part)
		return false, anchor and (part.Position - anchor).Magnitude or nil
	end
	return true, nil
end

-- A ball that has not moved this far between two ticks has not been re-sampled.
-- Replication delivers a ball's CFrame in hops (10-20 Hz), not at the tick rate,
-- so most ticks observe the same position. Advancing the sample clock on those
-- ticks is what made every hop look instantaneous - the delta was compared
-- against one tick of elapsed time and rejected as a teleport, forever.
local PATH_EPS = 0.02

-- Longest gap that still counts as a flight sample. Anything older cannot claim
-- the ball travelled the distance in that time; it was somewhere else.
local PATH_MAX_GAP = 0.25

-- How long a segment record may still be extrapolated after ThrowFX stops
-- reporting the ball. This is a different question from PATH_MAX_GAP: that one
-- asks whether a *sample* is a flight sample, this one asks whether a *ball*
-- is still in the air. A ball that bounces stops being reported (the bounce
-- sets canHit=false and clears the target) and then keeps flying - measured at
-- four live deaths, the ball that took the life was dropped 0.99-1.17 s before
-- it arrived. The old gate reused PATH_MAX_GAP and closed the lane at a quarter
-- of that, so every one of those balls was unreachable by construction.
--
-- The bound is not a guess about the flight, it is the horizon the body could
-- act inside. A record older than this predicts a ball already past the body
-- (the extrapolation is monotone), which pathThreat refuses on its own.
local ORPHAN_MAX_AGE = 1.6

-- One tracker step. Pure: takes the record for a part and this tick's position,
-- returns the record to store and a verdict naming what the step decided. Every
-- sampling rule lives here rather than in the loop, because this is exactly where
-- the anchored/CFrame blindness lived and a rule that cannot be asserted is a
-- rule that silently stops holding. The verdict exists so a live round can say
-- which rule is consuming the balls, instead of showing a path count of zero.
--
-- `prev`/`dt` are only written when the ball genuinely moved, and `dt` is the
-- time between two *distinct* positions, so the speed bound compares like with
-- like: a hop of 7 studs over 0.05 s is 140 studs/s and passes; the same hop
-- over one 12 ms tick is 580 and is a re-placement.
local function pathSample(rec, pos, now)
	if not rec then
		return { pos = pos, t = now }, "first"
	end

	local moved = (pos - rec.pos).Magnitude
	if moved <= PATH_EPS then
		return rec, "repeat"
	end

	local dt = now - rec.t
	if dt <= 0.001 then
		return rec, "stale"
	end

	if dt > PATH_MAX_GAP then
		-- Re-placed, not travelled: pooling to the parking position, or a gap
		-- long enough that the two points are unrelated.
		rec.prev, rec.dt = nil, nil
		rec.pos, rec.t = pos, now
		return rec, "gap"
	end

	if moved > PATH_MAX_SPEED * dt then
		rec.prev, rec.dt = nil, nil
		rec.pos, rec.t = pos, now
		return rec, "fast"
	end

	rec.prev, rec.dt = rec.pos, dt
	rec.pos, rec.t = pos, now
	return rec, "flight"
end

local function trackBalls(now, live)
	local balls = Workspace:FindFirstChild("DodgeBalls")
	if not balls then
		return
	end

	-- Draw lag per part. The replicated part is drawn `state.lag` seconds in the
	-- past - ThrowFX.keep() evaluates the path at (a2 - lag) - while `state.seg`
	-- is evaluated at now. That difference is real flight the tracker has not
	-- seen yet: 0.112 s of lag is 15.7 studs at 140 studs/s, several times the
	-- reach radius the path answer is compared against. Recorded per part here
	-- and added to the sample's age before any prediction reads it.
	local lagOf
	if live then
		lagOf = {}
		for _, state in pairs(live) do
			if state.part then
				lagOf[state.part] = tonumber(state.lag) or 0
			end
		end
	end

	local drop = S.pathDrop
	for _, part in ipairs(balls:GetChildren()) do
		if part:IsA("BasePart") then
			local ok, holdDistance = pathCandidate(part)
			if not ok then
				-- Two different refusals wear the same clothes here. A ball at a
				-- hand is correctly ignored; a ball flying with a weld that was
				-- never cleaned up is the tracker going blind, and the distance
				-- is what tells them apart.
				if holdDistance and holdDistance > PALM_RADIUS then
					drop.weld_far = (drop.weld_far or 0) + 1
				else
					drop.weld_near = (drop.weld_near or 0) + 1
				end
			else
				local rec, verdict = pathSample(ballPath[part], part.Position, now)
				-- The verdict is stored with the record: the body answer has to
				-- know whether a trajectory-less record is a ball that just
				-- arrived or one the tracker stopped seeing.
				rec.verdict = verdict
				-- After pathSample, because it can return a brand new record.
				-- nil clears the lag and that is correct: a ball whose draw is
				-- current - an own throw, a settled ball - has nothing to
				-- compensate for, and holding a stale lag would advance it past
				-- where it actually is.
				rec.lag = lagOf and lagOf[part] or nil
				ballPath[part] = rec
				drop[verdict] = (drop[verdict] or 0) + 1
			end
		end
	end
end

-- The question the body answer actually asks: will this ball pass within reach
-- of the body before the horizon runs out? Answered from the ball's travel
-- between the previous sample and this one, extended forward at the same speed,
-- so it holds on the first frame a ball is ever seen and on the frame after a
-- bounce - the two frames where a velocity estimate and a stale segment both
-- lie. Relative motion, because the hit test leads the body by its own velocity.
--
-- The question is asked *now*, not at the sample. A record is a position at
-- time rec.t, and between rec.t and now the ball has kept moving; at 140 studs/s
-- a single 20 ms of it is 2.8 studs, which is larger than the reach radius the
-- answer is compared against. The position is therefore advanced to this tick
-- before anything is measured. Every prediction in this file that skipped that
-- step was quietly answering about the past.
--
-- The sample is also the *drawn* position, and the game draws the ball `lag`
-- seconds behind the path it judges. `rec.lag` is that delay, captured from
-- ThrowFX.Live() when the sample was taken. It is flight the tracker has not
-- seen yet, so it advances the same way time-since-sample does. A ball drawn
-- current reports no lag and the arithmetic is unchanged.
--
-- Returns nil when the ball is receding (its closest approach happened before the
-- previous sample) or when the path clears the reach radius entirely. The fourth
-- return names the rule that answered, so a live report can say which one is
-- throwing away the balls that reach the body - a rejection that is never counted
-- is indistinguishable from a ball that was never tracked.
local function pathThreat(rec, now, rootPos, rootVel, horizon, radius)
	if not (rec and rec.prev and rec.pos and rec.dt and rec.dt > 0) then
		return nil, nil, nil, "no_sample", nil
	end

	local travel = (rec.pos - rec.prev) / rec.dt
	local rel = travel - rootVel
	local speedSq = rel:Dot(rel)
	if speedSq < 1e-6 then
		return nil, nil, nil, "speed", nil
	end

	-- The sample is the drawn position, and the draw is `rec.lag` seconds behind
	-- the ball's real one. Both ages add: the time since the sample AND the
	-- draw lag it was taken at. Advancing by only the first is why a ball drawn
	-- 0.112 s in the past read as 15.7 studs further away than it was, and why
	-- the point-blank class cleared the reach radius on paper while hitting in
	-- the game.
	local age = math.max(0, now - rec.t) + (rec.lag or 0)
	local posNow = rec.pos + travel * age
	local delta = posNow - rootPos
	local tca = -delta:Dot(rel) / speedSq

	if tca < -rec.dt then
		return nil, nil, nil, "past", tca, posNow
	end
	if tca > horizon then
		return nil, nil, nil, "beyond", tca, posNow
	end

	local miss = (delta + rel * tca).Magnitude

	-- Pessimistic over a window, not optimistic on one sample. A segment is
	-- refitted every sample, and the fit swings the perpendicular hard: measured
	-- live on one ball, miss read 15.80 at 18.5 studs, then 2.46 at 10.4, then
	-- 1.86 at 5.3 inside 0.15 s. Every one of those was "the truth" for its own
	-- tick, so an answer taken on the newest value is always answering the
	-- friendlier half of a wobbling estimate. Holding the worst value seen in the
	-- last fifth of a second answers the ball that is actually closing, and ages
	-- out on its own so a ball that passed wide is not treated as a threat
	-- forever.
	do
		local worstAt = rec.missWorstAt
		if not worstAt or (now - worstAt) > 0.20 then
			rec.missWorst = miss
			rec.missWorstAt = now
		elseif miss < (rec.missWorst or math.huge) then
			rec.missWorst = miss
		end
		miss = math.min(miss, rec.missWorst or miss)
	end

	-- At the body already. It is here now; the tick that mattered was the one
	-- before this one, and re-arming a sidestep against a ball that cannot be
	-- left behind only produces a shoving loop. Reported separately from `miss`
	-- so a report can tell "cleared the body" from "arrived".
	if delta.Magnitude <= radius then
		return nil, miss, nil, "inside", tca, posNow
	end

	if miss > radius then
		return nil, miss, nil, "miss", tca, posNow
	end

	-- The perpendicular offset at closest approach, in the horizontal plane. It
	-- points from the body TOWARD the point on the ball's line the body will pass
	-- closest through, so moving along it makes `miss` smaller and moving along
	-- `-off` makes it bigger. The sign is the whole answer for a dash: the same
	-- distance spent along `-off` clears, and spent along `off` has to cross the
	-- line first. Every caller below negates it for exactly that reason.
	local cpa = delta + rel * tca
	local off = Vector3.new(cpa.X, 0, cpa.Z)
	if off.Magnitude > 1e-3 then
		off = off.Unit
	else
		off = nil
	end

	return math.max(0, tca), miss, travel.Unit, "hit", tca, posNow, off
end

-- A ball that has just arrived has no trajectory to measure, and the speed bound
-- has correctly thrown the hop away. The answer is still owed: the pool parks a
-- ball at (0,-500,0), the server re-places it at the thrower's hand, and from
-- there it crosses the reach radius in ~80 ms - less than the next replication
-- sample. Every predictor in this file needs two positions to say anything, so
-- this is the one case where it has to answer from one: the ball is here, at
-- throwing distance, and the body has to move before the sample exists.
--
-- Priced at the game's fastest legal throw plus the body's own motion toward the
-- ball, which is the earliest it could arrive. The closing speed is the whole
-- point: a body running at the ball meets it sooner than a body standing still,
-- and a body running away meets it later or not at all. Pricing from the ball
-- alone made the stationary case exact and every moving case late, which is the
-- shape that reads as "works when I stop moving".
--
-- Bounded by age: past PATH_ARRIVAL_AGE the record is a ball the tracker lost,
-- not one that just landed, and arming on that would walk the body away from
-- nothing for as long as the ball sat still.
local function arrivalThreat(rec, now, rootPos, rootVel, ballVel)
	if not (rec and rec.pos) then
		return nil, nil
	end

	local fresh = rec.verdict == "first" or rec.verdict == "fast" or rec.verdict == "gap"
	if not fresh or (now - (rec.t or now)) > PATH_ARRIVAL_AGE then
		return nil, nil
	end

	-- Inside the body lane's reach the question is not which way the ball is
	-- going. The ball is already in contact range and the next server tick
	-- resolves it, so the answer is "now" no matter what the velocity says.
	-- Measured: a world-bounced ball at 2.51 studs with a fresh sample took a
	-- life while every lane answered `no_sample`; its post-bounce velocity
	-- pointed away from the body, so the outbound guard below refused the one
	-- answer that was owed. A ball in contact range is a contact problem.
	local delta = rec.pos - rootPos
	local distance = delta.Magnitude
	if distance <= BODY_RADIUS then
		return 0, delta.Unit
	end
	if distance > PATH_NEAR or distance <= 0.001 then
		return nil, nil
	end

	-- A ball that is not travelling toward the body is not arriving. One sample
	-- has no differenced velocity, but the segment it came from does, so the
	-- direction is readable even on the frame the pair does not exist yet.
	-- Without this the answer armed on any fresh record inside PATH_NEAR - the
	-- ball just thrown, and every ball on its way somewhere else.
	if ballVel and ballVel:Dot(delta) >= 0 then
		S.arrivalOutbound = (S.arrivalOutbound or 0) + 1
		return nil, nil
	end

	-- Bearing is body to ball, so a positive dot is the body closing the gap.
	local bearing = delta.Unit
	local toward = rootVel and rootVel:Dot(bearing) or 0
	local closing = PATH_THROW_SPEED + toward
	if closing <= 1 then
		return nil, nil
	end

	-- Same draw lag as the path answer. The sample is where the ball was drawn,
	-- and the ball has been closing at this speed for `lag` seconds since. A
	-- point-blank arrival that reads 6 studs out while lagged by 5 studs is
	-- here, not 43 ms away - and that 43 ms is the whole difference between a
	-- press the judge sees in time and one it sees late.
	local remaining = distance - (rec.lag or 0) * closing
	if remaining <= 0 then
		return 0, bearing
	end

	return remaining / closing, bearing
end

-- Segment-sourced path ---------------------------------------------------------
--
-- The part tracker above assumes the ball's motion lives on the DodgeBalls part.
-- In this game it does not. Measured over 123 throws across all four classes: the
-- part sits at the pool position (0,-500,0) for 100% of the flight samples of
-- every class - attack 88/88, bot 9/9, loose 6/6, pass 20/20, parkedFrac 1.00.
-- The only parts that ever move are ones welded into a hand, which are correctly
-- refused as carried balls. So a tracker keyed on the part is blind to every ball
-- in flight, and physicalThreat has never once answered for one: over a full
-- session pathWhy reads hit=1 against no_sample=11021.
--
-- That blindness is not a class difference - it is total - but it explains the
-- reported behaviour exactly. With the body answer dead, a dodge can only be
-- spent by the catch branch as a fallback when pressing is refused, so the body
-- reacts to schedule pressure instead of to contact. The ball that arrives before
-- a press can be sent therefore gets nothing.
--
-- The live segment is the same line the catch predictor reads and it exists for
-- every class, so when the part cannot carry the motion the segment does. Same
-- pathThreat, same reason names, one extra source.
local segPath = setmetatable({}, { __mode = "k" })

-- The game's own answer for "where is this ball at absolute time t".
--
-- ThrowFX does not hold one segment per ball: it appends every segment the ball
-- has flown onto `state.hist` and its own `pathAt` picks the newest one whose
-- `t0` has begun. A ball that bounced is on a later segment than the one that
-- was current when the bounce was predicted, and the pre-bounce copies kept on
-- `worldPred.real` / `bounce.real` are the ones that were rolled back.
--
-- Reading `state.seg` and advancing it by `now - t0` therefore reads a stale
-- arc. Measured on the last three deaths: the tracker had the ball 3.1, 3.9 and
-- 3.2 studs out while the server's own impact point (`Impact.pos`, which is the
-- only position in the payload that is not a prediction) landed 1.63, 2.09 and
-- 2.63 studs from the root - inside the 2.4 reach radius. The arc was being
-- extrapolated past the end of its own flight, where a parabola keeps
-- accelerating away from the body. That is also where `past` and `no_sample`
-- came from on the tick that mattered.
-- The flight line the server still has, while ThrowFX's bounce is only a guess.
--
-- `predictBounce` folds the guess into the entry immediately: `worldBounced`
-- goes true, a new segment starts at the bounce time, and the entry's own
-- `hist` gets the ricochet. `undoWorld` puts it back, but that is a whole
-- `WORLD_CONFIRM + ping` later - and the ball keeps flying at the body meanwhile.
--
-- `worldPred.real` is not the guess: ThrowFX re-anchors it from every server
-- update (`ref.worldPred.real = {p0, v0, t0, g}`), so it is the newest flight
-- line the server actually sent. `bounce.real` is the same object for a model
-- bounce, and `bounce.confirmed` says whether the client's version of it came
-- back from the server.
local function preBounceSeg(state)
	local wp = state.worldPred
	if state.worldBounced
		and type(wp) == "table"
		and type(wp.real) == "table"
		and typeof(wp.real.p0) == "Vector3" then
		return wp.real
	end
	local b = state.bounce
	if type(b) == "table"
		and b.confirmed ~= true
		and type(b.real) == "table"
		and typeof(b.real.p0) == "Vector3" then
		return b.real
	end
	return nil
end

local function arcAt(state, t)
	local seg = state.seg
	local hist = state.hist
	if type(hist) == "table" and #hist > 0 then
		for i = #hist, 1, -1 do
			if hist[i].t0 <= t + 1e-6 then
				seg = hist[i]
				break
			end
		end
	end
	-- A predicted bounce is not a bounce. ThrowFX appends its guess to `hist` the
	-- moment it forecasts contact, so replaying hist replays the guess - and the
	-- guess walks the ball away from the body. Measured on two lives: rows read
	-- `nocanhit bounce` while the drawn ball went 12.9 studs out and climbed to
	-- 19, and the ball took the life either way. While the bounce is unconfirmed
	-- the server's own pre-bounce line is the flight, so the replay starts there.
	local pre = preBounceSeg(state)
	if pre then
		seg = pre
	end
	if not (seg and typeof(seg.p0) == "Vector3") then
		return nil, nil
	end
	local dt = math.max(0, t - seg.t0)
	local okP, p = pcall(Shared.PosAt, seg, dt)
	local okV, v = pcall(Shared.VelAt, seg, dt)
	if not okP or typeof(p) ~= "Vector3" then
		return nil, nil
	end
	return p, (okV and typeof(v) == "Vector3") and v or nil
end

-- Arc answer. The body lane used to difference the last two drawn samples,
-- which answers only while the ball is mid-flight and never on the frame it
-- arrives; `no_sample` on the arrival frame was the whole failure. This walks
-- the ball's own arc forward over the decision horizon instead: the earliest
-- time the arc comes inside the reach radius, with the body advancing too. It
-- cannot answer `past`, because it never asks about the last tick - only about
-- the next `horizon` seconds.
local ARC_STEP = 1 / 60

-- The body is a capsule, not a point. Every distance this file used to take was
-- 3D from the humanoid root, which inflates a ball arriving at chest or head
-- height by the whole vertical offset: measured impact points (`Impact.pos`,
-- server-side, no predictor) landed 0.98-2.77 studs from the root while the
-- server had resolved them as hits, and `BALL_RADIUS + HIT_RADIUS` is 2.4 -
-- so a hit at 2.77 from the root was a hit at under 2.4 from the axis.
-- Clamping the ball's height into the capsule before measuring removes that
-- offset from the only number the hit test cares about.
local BODY_LOW, BODY_HIGH = -2.2, 1.5

local function capsuleDist(p, body)
	local dy = p.Y - body.Y
	local vert = dy - math.clamp(dy, BODY_LOW, BODY_HIGH)
	local dx = p.X - body.X
	local dz = p.Z - body.Z
	return math.sqrt(dx * dx + dz * dz + vert * vert)
end

local function arcThreat(state, now, rootPos, rootVel, horizon, radius)
	local p0, v0 = arcAt(state, now)
	if not p0 then
		return nil, nil, nil, "no_sample", nil
	end

	local first = capsuleDist(p0, rootPos)
	if first <= radius then
		return nil, first, nil, "inside", 0, p0
	end

	-- Nothing in the window can close this gap: the ball flies at 95 and the
	-- body runs at 61, so the fastest possible closure is 156 studs/s.
	if first > (PATH_THROW_SPEED + 60) * horizon + radius then
		return nil, first, nil, "beyond", nil, p0
	end

	local bestD, bestDt, bestPos, bestOff = first, 0, p0, nil

	-- The scan starts slightly in the past. Ticks land ~11 ms apart and the ball
	-- crosses the capsule between two of them, so a forward-only scan from `now`
	-- first sees the ball already receding - measured on three deaths, the first
	-- recorded sample was 3.1 studs out and climbing, while the same ball was
	-- resolved by the server 0.02 s earlier. A crossing found behind `now` is
	-- answered at tti 0: the ball is here, and the press or the dash is still
	-- worth sending.
	local back = -math.ceil(0.08 / ARC_STEP)
	local n = math.max(1, math.ceil(horizon / ARC_STEP))
	for i = back, n do
		local dt = i * ARC_STEP
		if dt > horizon then
			break
		end
		local p, v = arcAt(state, now + dt)
		if p then
			-- A ball below the court has already landed. `BALL_MIN_Y` is 1.15;
			-- below that the arc is extrapolating through the floor and every
			-- further sample is fiction.
			if p.Y < 0.9 then
				break
			end
			local body = rootPos + rootVel * dt
			local delta = p - body
			local d = capsuleDist(p, body)
			if d < bestD then
				bestD, bestDt, bestPos = d, dt, p
			end
			if d <= radius then
				local cpa = Vector3.new(delta.X, 0, delta.Z)
				local off = cpa.Magnitude > 1e-3 and cpa.Unit or nil
				local dir = v or (p - p0)
				if dir.Magnitude < 1e-3 then
					dir = nil
				else
					dir = dir.Unit
				end
				return math.max(0, dt), d, dir, "hit", math.max(0, dt), p, off
			end
		end
	end

	local cpa = bestPos and Vector3.new(bestPos.X - rootPos.X, 0, bestPos.Z - rootPos.Z)
	if cpa and cpa.Magnitude > 1e-3 then
		bestOff = cpa.Unit
	end
	return nil, bestD, nil, "miss", math.max(0, bestDt), bestPos, bestOff
end

local function livePos(state)
	local b = state.ball
	if b and typeof(b.Position) == "Vector3" then
		return b.Position
	end
	local d = state.drawn
	if typeof(d) == "Vector3" then
		return d
	end
	return nil
end

-- The flight line, for a ball whose bounce is only a guess.
--
-- ThrowFX predicts wall and model contact itself. The moment it does,
-- `predictBounce` folds the ricochet into the entry: `worldBounced` goes true,
-- `canHit` false, a new segment starts at the bounce time, and the drawn ball
-- follows the predicted roll. If the server disagrees it calls `undoWorld`, but
-- that is a whole `WORLD_CONFIRM + ping` later - and the ball keeps flying at the
-- body in the meantime.
--
-- Measured on one life: the drawn ball tracked a throw 67 -> 12.9 studs, then
-- turned around and walked back out to 19 studs with `nocanhit bounce` on every
-- row, while the same ball took the life. The pre-bounce line - `worldPred.real`,
-- or `bounce.real` for a model bounce - is the flight the server still has.
-- Extrapolated from its own `t0` it passes exactly through the body, which is why
-- the prediction is worth reading and the roll is not.
local function preBouncePos(state, t)
	local real = preBounceSeg(state)
	if not real then
		return nil
	end
	local dt = math.max(0, t - (real.t0 or t))
	local ok, p = pcall(Shared.PosAt, real, dt)
	if ok and typeof(p) == "Vector3" then
		return p
	end
	return nil
end

local function segSample(state, now, rootPos)
	local seg = state.seg
	if not seg or typeof(seg.p0) ~= "Vector3" then
		return nil
	end

	-- `seg.t0` is the leg's start. This used to read a bare `t0`, which is a
	-- global and therefore nil: every record was written with `leg = nil` and
	-- tested `leg ~= nil`, so a re-anchor that kept the same segment table never
	-- reset the sample pair and `legT0Changed` never counted once. Measured: the
	-- counter sat at 0 across eight runs while `legSegChanged` climbed, which is
	-- the signature of a leg test that can never fire.
	local legT0 = seg.t0

	-- The drawn ball is the truth. Measured on a live entry: `state.ball.Position`
	-- (which is `state.drawn`) tracked a `loose` ball 17.8 -> 9.4 studs while the
	-- same entry's segment sat frozen at 17.7 for the whole run, and an `attack`
	-- ball read 15.2 on the ball against 14.6 on the segment. The segment is a
	-- prediction the client keeps re-anchoring; the ball is the position the
	-- client draws, and the last two deaths were both balls the segment had 9.9
	-- studs away and receding while the server resolved them on the body.
	--
	-- So difference the ball, and fall back to the arc only when there is no ball
	-- to read - that is the case the segment lane was invented for and it is
	-- still real for an entry whose shadow has not spawned yet.
	--
	-- An unconfirmed bounce is the exception, and it is the one that killed.
	-- ThrowFX draws its guess the moment it predicts contact, so the drawn ball
	-- takes the predicted ricochet while the server still has the throw coming
	-- in. Reading the roll answers `miss`/`past` on a ball that is about to
	-- arrive: measured at 12.9 studs out and receding, four ticks before the
	-- life left. `preBouncePos` gives the last line the server actually sent -
	-- ThrowFX re-anchors `worldPred.real` from every server update - so the
	-- inbound flight is measured until the bounce is real.
	--
	-- But the pre-bounce line is not always the inbound one either: measured on
	-- the next batch, `src=pre` rows walked a ball 6.9 -> 14.2 studs with a
	-- `past` verdict while the server resolved a hit on it, so preferring that
	-- source unconditionally simply swapped which curve lied. Whichever curve is
	-- still closing on the body is the one that can hurt, so the choice is made
	-- on that, both curves are read this tick, and only one of them is stored.
	local pos = livePos(state)
	local provisional = pos == nil
	if not pos then
		pos = arcAt(state, now)
	end
	local usePre = false
	local pre = preBouncePos(state, now)
	if pos and pre then
		if not rootPos then
			-- No body to measure against (self-test and any caller without a
			-- root): the old unconditional preference stands.
			pos = pre
			usePre = true
			provisional = false
		else
			-- A curve is "closing" when its own ball velocity points at the body
			-- right now. Both curves are asked the same question off their own
			-- segment, so neither source wins by being the one read first. A
			-- source that cannot produce a velocity is not closing - fail closed,
			-- because a curve that cannot be checked is a curve that gets skipped.
			local function closes(p, s)
				if not s then
					return false
				end
				local okV, v = pcall(Shared.VelAt, s, math.max(0, now - (s.t0 or now)))
				if not okV or typeof(v) ~= "Vector3" then
					return false
				end
				return (rootPos - p):Dot(v) > 0
			end

			local liveClosing = closes(pos, seg)
			local preClosing = closes(pre, preBounceSeg(state))
			-- Substitute only when the drawn curve has stopped closing and the
			-- pre-bounce line still is. Measured: 22 `src=pre` rows in one batch
			-- still walked away from the body (`d=2.7`, `tca=-0.121`) because the
			-- old test took pre whenever live was not closing - which is also true
			-- when *both* are receding. Two receding curves are a ball that has
			-- gone by; handing that to the pre-bounce line invents an inbound ball
			-- out of a dead one and lets it answer `past` on a threat that is
			-- simply over.
			if preClosing and not liveClosing then
				pos = pre
				usePre = true
				provisional = false
			end
		end
	end
	if not pos then
		return nil
	end

	-- Which curve this sample came from. A prediction that answers `past` on a
	-- ball that is still coming has one of three sources to blame and they are
	-- indistinguishable from the numbers alone.
	local src = usePre and "pre" or (provisional and "arc" or "live")

	-- Keyed on the ball's part, not on the Live entry. ThrowFX rebuilds the entry
	-- table freely (it is documented as doing so in `tallyHandouts`), and a record
	-- keyed on a table that is replaced every tick is a record that is created
	-- every tick - so `prev` never exists and the segment lane answers
	-- `no_sample` for the whole flight. The part is the pool seat and survives.
	local key = state.part or state
	local rec = segPath[key]
	if not rec then
		segPath[key] = {
			pos = pos,
			prev = nil,
			dt = nil,
			t = now,
			seg = true,
			kind = classOf(state),
			leg = legT0,
			legSeg = seg,
			verdict = "first",
			provisional = provisional,
			arcFallback = provisional,
			usePre = usePre,
			src = src,
			lag = state.lag or 0,
		}
		S.segFirstSight = (S.segFirstSight or 0) + 1
		-- Returned rather than swallowed. A one-sample record cannot be
		-- differenced, so pathThreat answers `no_sample` on it - but it *can* be
		-- priced as an arrival, and dropping it here meant the ball's first tick
		-- inside the reach radius produced no answer at all. That tick is the
		-- whole point-blank case.
		return segPath[key]
	end

	rec.arcFallback = provisional
	rec.usePre = usePre
	rec.src = src
	rec.lag = state.lag or 0

	-- A new leg is a new flight. The game re-fits the segment on every bounce and
	-- on every re-anchor, and the position it reports jumps by however much the
	-- old leg had drifted. Differencing across that jump produces a travel vector
	-- that never existed - measured at 105-157 degrees away from the old leg's
	-- direction on the frames after a bounce - and every downstream answer (miss,
	-- tca, and above all the dash axis) was built from it. Restart the pair on the
	-- new leg and say nothing until two samples exist on it.
	--
	-- The same applies to a switch of position source: the pre-bounce line and
	-- the drawn roll are different curves, so differencing one against the other
	-- is the same fabricated travel vector under a different name.
	if rec.legSeg ~= seg or rec.leg ~= legT0 or rec.usePre ~= usePre then
		if rec.legSeg ~= seg then
			S.legSegChanged = (S.legSegChanged or 0) + 1
			if provisional or rec.provisional then
				S.legSegChangedProv = (S.legSegChangedProv or 0) + 1
			end
		elseif rec.leg ~= legT0 then
			S.legT0Changed = (S.legT0Changed or 0) + 1
			if provisional or rec.provisional then
				S.legT0ChangedProv = (S.legT0ChangedProv or 0) + 1
			end
		else
			S.legPreChanged = (S.legPreChanged or 0) + 1
		end
		rec.legSeg = seg
		rec.leg = legT0
		rec.provisional = provisional
		rec.arcFallback = provisional
		rec.usePre = usePre
		rec.lag = state.lag or 0
		rec.pos = pos
		rec.prev = nil
		rec.dt = nil
		rec.t = now
		-- `first` is what arms arrivalThreat. A record with no pair and a fresh
		-- stamp is a ball that is here and cannot be differenced, which is the one
		-- case that predictor exists to answer.
		rec.verdict = "first"
		S.pathLegReset = (S.pathLegReset or 0) + 1
		return rec
	end

	if now > rec.t and (pos - rec.pos).Magnitude > 0.01 then
		rec.prev, rec.pos = rec.pos, pos
		rec.dt = now - rec.t
		rec.t = now
		rec.verdict = nil
	else
		rec.pos, rec.t = pos, now
	end

	return rec
end

-- Does this tracked part actually carry the ball's motion right now? A record
-- only has prev/dt after two genuinely distinct positions at flight speed, and
-- `rec.t` is the time of the last distinct position. A part that moved once and
-- then stopped keeps its old prev/dt, so freshness is part of the test: a stale
-- sample is not motion, it is history.
local PART_FRESH = PATH_MAX_GAP

local function partCarries(rec, now)
	if not rec or not rec.prev or not rec.dt then
		return false
	end
	return (now - (rec.t or 0)) <= PART_FRESH
end

-- One authority for "a ball is physically inbound at the body". Walks the
-- tracked parts, skips anything welded into a hand, and skips a pass while
-- eliminated - a teammate's handout is the route back onto the field, not a
-- threat. Returns the soonest arrival with the direction of travel.
--
-- A ball already at the body is answered `inside` by pathThreat rather than
-- armed again: it is here now, the tick that mattered was the one before this
-- one, and re-arming a sidestep against a ball that cannot be left behind only
-- produces a shoving loop in which the body walks for as long as the ball
-- happens to sit near it.
local function physicalThreat(character, root, now, horizon, exempt, live)
	local rootPos = root.Position
	local localVel = root.AssemblyLinearVelocity
	local rootVel = Vector3.new(localVel.X, 0, localVel.Z)

	-- The body answer used to take any Live entry that was not held and not our
	-- own throw. That let a teammate's re-entry pass, a ball the game had already
	-- stopped marking canHit, and a handout thrown to this player while out all
	-- arm the body. The catch path has always gone through `isCandidate`; the
	-- body path now goes through it too, in its soft form: bounce flags stay
	-- relaxed because a ball off the floor still takes a life, and everything
	-- that is a handout or a friend's throw while out is dropped.
	local out = character and character:GetAttribute(OUT_ATTR) == true
	local myTeam = character and (character:GetAttribute("Team") or LocalPlayer:GetAttribute("Team"))

	local bestTti, bestDir, bestMiss, bestPart, bestState, bestOff, bestTca
	local why = S.pathWhy
	local close = S.pathClose
	local wide = S.pathWide
	local radius = BODY_RADIUS
	local liveParts = {}

	local function consider(part, rec, state)
		local tti, miss, dir, reason, tca, posNow, off

		-- Two sources, chosen by what the record is: a live ball is answered off
		-- its arc (ThrowFX's own `hist`, so bounces and roll-outs are the game's
		-- segments and not our guess at them); a tracked part is answered off
		-- its differenced motion, because that is the only thing a part knows.
		--
		-- The lane was chosen once, at sample time, and that is a fault of its
		-- own: `arcFallback` says the record was sampled with no drawn ball, and
		-- the entry can lose its segment later in the flight. Measured on three
		-- lives: the ball left Live() 7.8 studs out, the arc lane answered
		-- `no_sample` for the whole approach, and the body sat still for 0.4 s
		-- with `body-notti` because nothing else was ever asked - while the
		-- record still held a fresh pair it could have been differenced from.
		-- So a `no_sample` from the arc hands the question to the pair.
		local arcAnswered = false
		if rec.seg and rec.arcFallback and state then
			arcAnswered = true
			tti, miss, dir, reason, tca, posNow, off =
				arcThreat(state, now, rootPos, rootVel, horizon, radius)
			S.arcCalls = (S.arcCalls or 0) + 1
			if reason == "no_sample" and partCarries(rec, now) then
				arcAnswered = false
				S.arcToPair = (S.arcToPair or 0) + 1
			end
		end
		if not arcAnswered then
			tti, miss, dir, reason, tca, posNow, off =
				pathThreat(rec, now, rootPos, rootVel, horizon, radius)
		end

		why[reason] = (why[reason] or 0) + 1
		if rec.seg then
			S.pathWhySeg[reason] = (S.pathWhySeg[reason] or 0) + 1
			-- The row's `track=` note reads this. A live ball's motion is on the
			-- segment and its part record is a pool seat, so asking pathThreat
			-- about the record answers `no_sample/STALE` on the exact tick the
			-- life leaves - the note was reporting the wrong lane's verdict.
			if part then
				S.arcLast = S.arcLast or {}
				S.arcLast[part] = {
					reason = reason,
					miss = miss,
					tti = tti,
					at = now,
					pos = posNow,
				}
			end
		end

		-- The ball that re-placed itself inside throwing distance. The speed
		-- bound rejected the hop, so there is no trajectory to extend; the
		-- bearing is the ball's own and the arrival is priced at the fastest
		-- legal throw. This is the point-blank shape that used to read
		-- `no_sample` on every tick while the ball crossed the body.
		if not tti and not arcAnswered then
			-- The one-sample answer needs the ball's own direction, and on the
			-- frame the record is created there is no pair to difference. The
			-- segment still has a velocity at this instant, so read it there.
			local arrivalVel = nil
			if state then
				local _, v = arcAt(state, now)
				if v then
					arrivalVel = v
				end
			end
			local arrivalTti, arrivalDir = arrivalThreat(rec, now, rootPos, rootVel, arrivalVel)
			if arrivalTti then
				tti, dir, reason = arrivalTti, arrivalDir, "arrival"
				why.arrival = (why.arrival or 0) + 1
				if rec.seg then
					S.pathWhySeg.arrival = (S.pathWhySeg.arrival or 0) + 1
				end
			end
		end

		-- Measured from the advanced position, not the drawn one: the
		-- recorder exists to say how far away the ball was when the decision
		-- ran, and the drawn position is the one that lied about it.
		local distance = ((posNow or rec.pos) - rootPos).Magnitude

		-- Approach events, one per ball, split by who threw it.
		--
		-- This is the only measurement in the file that answers the reported
		-- complaint directly: when a ball actually got to the body, did each
		-- population get an answer? `near6` is the ball entering six studs -
		-- close enough that it is plainly coming for this body and not for
		-- somebody else. `answered` is a stamp the judge would accept on it, or a
		-- dash already in flight. `ring` is the ball reaching the judge's own
		-- contact radius. Counting all three per class means the two populations
		-- are compared on the same question instead of on how many throws the
		-- game happened to produce.
		if rec.seg then
			local kind = rec.kind or "unknown"
			-- First sighting, in studs. The whole "could we have moved in time"
			-- question is decided by how far away the ball was the first tick the
			-- lane could see it, and that number was never recorded - every death
			-- row was a distance at impact, which is the one distance that cannot
			-- answer it.
			if not rec.sightD then
				rec.sightD = distance
				local log = S.sightLog
				log[#log + 1] = string.format(
					"%.2f %s %s d=%.1f tti=%s",
					now % 1000,
					part and part.Name or "?",
					kind,
					distance,
					tti and string.format("%.3f", tti) or "-"
				)
				if #log > 80 then
					table.remove(log, 1)
				end
			end

			if distance <= 6 and not rec.nearOnce then
				rec.nearOnce = true
				tallyClass(kind, "near6")
				local band = judgePress(character, root, tti, dir, now)
				tallyClass(kind, band)
				local nl = S.near6Log
				local wp = state and state.worldPred
				local bs = state and state.bounce
				nl[#nl + 1] = string.format(
					"%.2f %s %s d=%.1f tti=%s pressAge=%s band=%s prov=%s can=%s wb=%s b=%s wpa=%s wpmax=%s bconf=%s",
					now % 1000,
					part and part.Name or "?",
					kind,
					distance,
					tti and string.format("%.3f", tti) or "-",
					S.pressStamp and string.format("%.3f", now - S.pressStamp) or "none",
					tostring(band),
					tostring(rec.provisional),
					tostring(state and state.canHit),
					tostring(state and state.worldBounced),
					tostring(type(bs) == "table"),
					type(wp) == "table" and wp.at and string.format("%.3f", os.clock() - wp.at) or "-",
					type(wp) == "table" and wp.max and string.format("%.3f", wp.max) or "-",
					type(bs) == "table" and tostring(bs.confirmed) or "-"
				)
				if #nl > 60 then
					table.remove(nl, 1)
				end

				local window = catchWindow(character)
				local contactAt = now + (tti or 0)
				local answered = false
				if S.pressStamp then
					local age = contactAt - S.pressStamp
					answered = age >= -0.03 and age <= window
				end
				if not answered and S.dashUntil and now <= S.dashUntil then
					answered = true
				end
				if answered then
					tallyClass(kind, "answered")
				end
			end

			if distance <= radius and not rec.ringOnce then
				rec.ringOnce = true
				tallyClass(kind, "ring")
			end
		end

		-- Flight recorder. Every ball inside the near radius, every tick,
		-- whatever the verdict. This is the only record that can answer why
		-- a life was lost: the ball's own distance, the geometry that was
		-- measured, and the rule that answered, in the order they happened.
		if distance <= 20 then
			wide[#wide + 1] = string.format(
				"%.2f %s %s%s%s d=%.1f tca=%s miss=%s age=%.3f lag=%.3f src=%s",
				now % 1000,
				part and part.Name or (state and tostring(state.id)) or "?",
				reason,
				rec.seg and "@seg" or "",
				rec.provisional and "@prov" or "",
				distance,
				tca and string.format("%.3f", tca) or "-",
				miss and string.format("%.2f", miss) or "-",
				rec.t and (now - rec.t) or -1,
				rec.lag or 0,
				rec.src or "-"
			)
			if #wide > 120 then
				table.remove(wide, 1)
			end
		end

		-- Closest passes, in the order the tracker saw them. The reason is
		-- kept beside the geometry: a `miss` at 20 studs is a ball aimed at
		-- somebody else, a `miss` at 2.5 is the one stud of error that lost
		-- the answer, and `no_sample` says the ball was never sampled at all.
		if reason == "hit" or (reason == "miss" and miss and miss <= radius * 3) then
			close[#close + 1] = string.format(
				"%.2f %s %s%s tca=%s miss=%.2f dt=%s age=%s d=%.1f lag=%.3f",
				now % 1000,
				part and part.Name or (state and tostring(state.id)) or "?",
				reason,
				rec.seg and "@seg" or "",
				tca and string.format("%.3f", tca) or "-",
				miss,
				rec.dt and string.format("%.3f", rec.dt) or "-",
				rec.t and string.format("%.3f", now - rec.t) or "-",
				distance,
				rec.lag or 0
			)
			if #close > 48 then
				table.remove(close, 1)
			end
		end

		-- Closest unexplained pass. When the body answer reads zero over a
		-- round this is the number that says whether balls are clearing the
		-- reach radius by a stud or by fifty.
		if reason == "miss" and miss and miss < (S.pathMinMiss or math.huge) then
			S.pathMinMiss = miss
			S.pathMinMissAt = now
		end

		if tti and (not bestTti or tti < bestTti) then
			bestTti, bestDir, bestMiss, bestPart, bestState = tti, dir, miss, part, state
			bestOff, bestTca = off, tca
		end
		return tti
	end

	for part, rec in pairs(ballPath) do
		if not pathCandidate(part, exempt) then
			why.skip = (why.skip or 0) + 1
		elseif not partCarries(rec, now) then
			-- Tracked but parked: the part is a seat in the pool, not a ball in
			-- flight. Answering from it produces the `no_sample` flood that hid
			-- the dead body answer for a whole session. Counted apart so the
			-- original reason set keeps its meaning.
			S.pathWhyPartIdle = (S.pathWhyPartIdle or 0) + 1
		else
			consider(part, rec, nil)
		end
	end

	-- Parts are sampled; the segment covers what the parts cannot. A ball whose
	-- part genuinely carries its motion is left to the part tracker alone, so no
	-- ball is counted twice and no part-derived answer is overridden. "Carries"
	-- is movement, not membership: every ball in this game is a member of the
	-- tracker while its part sits in the pool, and measuring membership instead
	-- of motion routed all of them to the blind source and left the segment with
	-- nothing to answer for at all.
	if type(live) == "table" then
		for _, state in pairs(live) do
			local part = state.part
			local covered = partCarries(ballPath[part], now) and pathCandidate(part, exempt)
			if part then
				liveParts[part] = true
			end

			if not covered and isCandidate(state, character, out, myTeam, false, true, "live") then
				if not (exempt and part and exempt[part]) then
					local rec = segSample(state, now, rootPos)
					if rec then
						consider(part, rec, state)
					end
				end
			elseif not covered then
				-- Measured, not assumed. The soft filter is the one gate on the Live
				-- lane, so "does it drop threats" was being answered by reading code.
				-- The reason is counted by isCandidate itself (`S.laneReject.live`),
				-- because guessing at it from the thrower name could not separate a
				-- teammate from an enemy while the session has no Team attribute.
				S.pathWhyNotCand = (S.pathWhyNotCand or 0) + 1
			end
		end
	end

	-- The ball that leaves Live() before it arrives. ThrowFX drops an entry the
	-- instant the judge resolves it, and one of the ways it resolves is by
	-- landing on this body - so the last few frames of the ball that actually
	-- takes the life are frames with no Live() entry at all. The part cannot
	-- answer either: measured at four live deaths, the killer's part sat at the
	-- pool position 507-510 studs away, `partCarries` correctly refused it, and
	-- the death read `near=Ball@0.00 [nocanhit,bounce] track=why=no_sample`.
	--
	-- The segment record survives that drop - it is keyed on the part now, not
	-- on the entry - so the last sampled position and the pair behind it are
	-- still here. Answering from them is the only way a ball can be met on the
	-- frames it stops being reported. Bounded by ORPHAN_MAX_AGE, not by the
	-- sample gap: a ball that bounced keeps flying for up to a second after the
	-- entry is gone, and that whole second is time the body could have used.
	--
	-- No distance gate on the last sampled position: a ball dropped 140 studs
	-- out and closing is exactly the one worth answering, and its store position
	-- is the one number that says nothing about where it is now. The gate that
	-- matters is the predicted arrival, which pathThreat already applies - the
	-- extrapolation is monotone, so a record that is genuinely old predicts a
	-- ball already past the body and is refused there.
	for key, rec in pairs(segPath) do
		local part = typeof(key) == "Instance" and key or nil
		if part and not liveParts[part] then
			local age = now - (rec.t or 0)
			if age > ORPHAN_MAX_AGE then
				S.orphanStale = (S.orphanStale or 0) + 1
			elseif pathCandidate(part, exempt) and not (exempt and exempt[part]) then
				S.orphanSeen = (S.orphanSeen or 0) + 1
				local got = consider(part, rec, nil)
				if got then
					S.orphanAnswer = (S.orphanAnswer or 0) + 1
					S.orphanLast = string.format(
						"part=%s tti=%.3f age=%.3f d=%.1f",
						part.Name,
						got,
						age,
						(rec.pos - rootPos).Magnitude
					)
				end
			end
		end
	end

	return bestTti, bestDir, bestMiss, bestPart, bestState, bestOff, bestTca
end

local function canPress(character, now)
	if not S.enabled then
		return false, "off"
	end
	-- Test seam. A dodge can only be measured where the catch cannot answer
	-- first, and in a live round that window is rare and never scheduled. This
	-- flag makes every press unavailable so the body path runs against the same
	-- balls, the same predictor and the same constraints as production.
	if S.benchNoCatch then
		return false, "bench"
	end
	if LocalPlayer:GetAttribute("InPrison") == true then
		return false, "prison"
	end
	if LocalPlayer:GetAttribute("HasBall") == true then
		return false, "holding ball"
	end
	if character:GetAttribute(OUT_ATTR) == true then
		return false, "out"
	end

	-- The server enforces CATCH_COOLDOWN (0.6 s) after every catch and publishes it
	-- as CatchReadyAt. Pressing inside that window is guaranteed to be refused, so
	-- it is spent on nothing. The sanity bound keeps a stale or replayed value from
	-- disabling catching for the rest of the round.
	local catchReady = readyAt(character, "CatchReadyAt")
	if catchReady and now < catchReady and catchReady < now + 10 then
		return false, "cooldown"
	end

	return true, "ok"
end

-- The server's acceptance test for a stamp, written once. `age` is how old the
-- stamp is when the ball is judged: inside [-0.03, CATCH_WINDOW] it catches,
-- outside it cannot. Every schedule decision below is this one call, so the
-- schedule and the fallback can never disagree about what "armed" means.
local function inJudgeBand(stamp, contactAt, window)
	if not (stamp and contactAt) then
		return false
	end

	local age = contactAt - stamp
	return age >= -0.03 and age <= window
end

-- Refresh a stamp once it would be this far into the judge window at contact.
-- Below 1.0 the freshest stamp is always replaced while it is still valid, so
-- the catch never depends on a prediction made more than a fraction of a second
-- early.
local PRESS_REFRESH = 0.40

-- Mirror of the client half of ThrowFX.catching(), diagnostics only: it says in
-- advance which limb of the judge would reject a press, so a round gives a tally
-- instead of a mystery.
local function judgePress(character, root, tti, dir, now)
	if not tti then
		return "no threat"
	end

	local window = catchWindow(character)
	local contactAt = now + tti
	local pressAt = now - CONFIG.pressBias

	if not inJudgeBand(pressAt, contactAt, window) then
		return (contactAt - pressAt) < -0.03 and "late" or "early"
	end

	if dir then
		local look = root.CFrame.LookVector
		local flatLook = Vector3.new(look.X, 0, look.Z)
		local flatDir = Vector3.new(-dir.X, 0, -dir.Z)

		if flatLook.Magnitude > 0.01 and flatDir.Magnitude > 0.01 then
			if flatLook.Unit:Dot(flatDir.Unit) < CATCH_ANGLE_COS then
				return "facing"
			end
		end
	end

	return "ok"
end

-- Arrival race classifier, pure: takes the facts that are authoritative at the
-- instant the contact clock reaches zero and names which answer lost. The order
-- mirrors the server's own contact chain - i-frames, then the catch judge, then
-- the hands, then the body - so a verdict that says `catch` and a life that
-- still dropped is a genuine client/server disagreement, not our timing.
--
-- Verdicts:
--   dash       i-frames covered this instant
--   catch      a stamp was inside the window and CatchReadyAt was past
--   hands      HasBall while the ball arrived
--   catch-cool a stamp was inside the window but CatchReadyAt was still ahead
--   dash-miss  a dash was spent, its i-frames had already run out
--   no-press   no stamp and no dash on this ball
--   past       a stamp existed but the judge window had gone by
--   pred-miss  the arrival was never predicted at all
local function raceVerdict(f)
	if not f or not f.tti then
		return "pred-miss"
	end

	if f.dashActive then
		return "dash"
	end
	if f.covers then
		return "catch"
	end
	if f.hands then
		return "hands"
	end
	if f.stamp and f.readyIn and f.readyIn > 0 then
		return "catch-cool"
	end
	if f.dashSpent then
		return "dash-miss"
	end
	if not f.stamp then
		return "no-press"
	end
	return "past"
end

-- Newest arrival within `span` seconds of `now`. Pure over a ring so the death
-- resolution can be exercised without a round: pass any head/max and a stub
-- table and the answer is the same one the live log gets.
local function raceResolve(ring, head, max, now, span)
	for i = 1, max do
		local idx = ((head - 1 - i) % max) + 1
		local e = ring[idx]
		if e then
			local age = now - e.t
			-- Negative ages are rows written after the instant being resolved;
			-- they are not this death's ball and must not be blamed for it.
			if age >= 0 and age <= span then
				return e, age
			end
		end
	end
	return nil, nil
end

-- One step of the press schedule, pure: no state, no remotes, no clock read.
-- The loop feeds it the contact clock it already has and the selftest sweeps it
-- across contact profiles, so the arming rule is exercised without a ball.
--
-- `rearm` is true when this ball has no stamp of its own yet. The cadence is a
-- refresh limiter, not a press rate: a new ball must be armed on the frame it
-- becomes catchable, otherwise the first ball after any other press loses the
-- whole window to a counter.
local function scheduleDue(contactAt, stamp, now, window, rearm, lastPress, cadence)
	if not contactAt then
		return false, "none"
	end

	-- Stamping now is only worth a packet if that stamp will still be inside the
	-- window when the ball is judged. Both ends use the same predicate as the
	-- judge, so a press is never sent outside the band it is meant to fill.
	local freshAt = now - CONFIG.pressBias
	if not inJudgeBand(freshAt, contactAt, window) then
		return false, "band"
	end

	if rearm or not stamp then
		return true, "arm"
	end

	if not inJudgeBand(stamp, contactAt, window) then
		return true, "rearm"
	end

	if (contactAt - stamp) > window * PRESS_REFRESH then
		if (now - (lastPress or -math.huge)) >= cadence then
			return true, "refresh"
		end
		return false, "cadence"
	end

	return false, "held"
end

-- Whether the catch will cover a ball judged at `contactAt`. The stamp is not
-- per ball: ThrowFX.catching() reads one attribute, `CatchPressT`, and compares
-- it with the judge time of whichever ball has arrived. A press made while
-- watching a different ball therefore still catches this one, which is why the
-- decision is stated over the stamp and the clock rather than over a ball id.
--
-- Each disqualifier is a refusal the server itself makes: no stamp at all, a
-- stamp outside the window at contact, CatchReadyAt still in the future when the
-- ball lands, or this exact ball already answered "Refused".
local function catchCovers(stamp, contactAt, window, readyBy, refused, catchable)
	if not (stamp and contactAt) then
		return false
	end
	-- A ball the judge cannot accept is not covered by any stamp. This is the
	-- difference between "a press is in flight" and "a press is in flight for
	-- THIS ball": a bounced ball, or one the game has stopped marking canHit, is
	-- refused by the judge by construction, so standing the body down for it is
	-- standing still for a ball that was never catchable.
	if catchable == false then
		return false
	end
	if refused then
		return false
	end
	if readyBy and contactAt < readyBy then
		return false
	end
	return inJudgeBand(stamp, contactAt, window)
end

-- Which answer the contact audit records, stated once so it can be asserted.
--
-- `covered` is the judge accepting the stamp for this contact. `late` is a press
-- that exists and missed the band, which means the schedule was armed for this
-- ball but a fraction of a second off. `nostamp` is no press for this ball at
-- all: either none was sent, or the only stamp on record is older than a second
-- past the window and therefore belongs to some earlier ball. The stamp is never
-- cleared, so the distinction has to be made on age, not on existence.
local CONTACT_STALE = 1.0

local function contactVerdict(covered, stampAge, window)
	if covered then
		return "covered"
	end
	if stampAge and stampAge <= window + CONTACT_STALE then
		return "late"
	end
	return "nostamp"
end

local function press(character, now)	local stamp = now - CONFIG.pressBias

	S.lastPress = now
	S.presses = S.presses + 1
	edge("press")
	S.pressStamp = stamp
	LocalPlayer:SetAttribute("CatchPressT", stamp)
	Action:FireServer("Catch", stamp)
	ThrowFX.MarkAction(character, "Catch", stamp)

	-- Every press is logged against the stamp that was actually sent, because the
	-- server answers with that same stamp. Pressing is not free: the server arms
	-- CatchReadyAt whether the catch lands or is refused, so a press that cannot
	-- land costs the next 0.6 s of catching outright. Mapping presses to answers
	-- is the only way to see which condition is producing refusals.
	local meta = S.pressMeta or {}
	local rec = {
		stamp = stamp,
		at = os.clock(),
		tti = meta.tti,
		dist = meta.dist,
		speed = meta.speed,
		side = meta.side,
		dot = meta.dot,
		win = catchWindow(character),
		kind = meta.kind,
		outcome = "pending",
	}

	local log = S.pressLog
	log[#log + 1] = rec
	if #log > 24 then
		table.remove(log, 1)
	end

	S.byStamp[stamp] = rec
	if S.stampCount > 80 then
		for key in pairs(S.byStamp) do
			if S.byStamp[key].outcome ~= "pending" then
				S.byStamp[key] = nil
			end
		end
		S.stampCount = 0
	end
	S.stampCount = S.stampCount + 1
end

-- Throw ----------------------------------------------------------------------
--
-- Replica of DodgeInput.doThrow's server call, minus the aim assist, charge and
-- ability branches. Only fires when the hands are full and a hit is predicted,
-- because a full pair of hands is the one state the server refuses to catch in.

local throwSeq = 100000

-- Cover time for the palm ball: long enough to cover the round trip, short
-- enough that a refused throw cannot leave a hole. The real decision is made by
-- reconcileThrow once THROW_ACK_WAIT has passed without a server ack.
local THROW_COVER = 0.6
local THROW_ACK_WAIT = 0.5

-- DodgeInput.heldBallPart, verbatim: the ball welded to the right hand is the one
-- the client is drawing in the palm, and it is the part doThrow hides after the
-- remote fires.
--
-- The weld outlives the throw for a moment, and during that moment the ball is
-- already in flight. Returning it as "held" then hides a ball the player is
-- watching fly, so a candidate also has to be at the hand, not just welded to it.
local function heldBallPart(character)
	local hand = character and (character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm"))
	local balls = Workspace:FindFirstChild("DodgeBalls")
	if not (hand and balls) then
		return nil
	end

	local handPos = hand.Position
	for _, ball in ipairs(balls:GetChildren()) do
		local weld = ball:FindFirstChildWhichIsA("Weld")
		if weld and weld.Part0 == hand and (ball.Position - handPos).Magnitude <= 5 then
			return ball
		end
	end
end

-- Palm guard ------------------------------------------------------------------
--
-- The palm is drawn from the ball instance, not from HasBall, and it is hidden
-- with LocalTransparencyModifier, a client-only property. ThrowFX.HidePart writes
-- 1 and records an expiry in its own table, but nothing in the module ever reads
-- that expiry - only ShowPart clears it - so a hidden part stays hidden until
-- unrelated code happens to touch it.
--
-- That is the ghost, and it was ours. HidePart ran on every throw for
-- MAX_FLIGHT + 2 (6 s). When the server handed the same ball instance back to the
-- hand - pooling, or a throw it refused - the part arrived welded in the palm with
-- LocalTransparencyModifier already at 1 while HasBall was true: a held ball drawn
-- invisible. The old sweep only restored parts it had hidden itself, through
-- `palmHidden`, and the watchdog only ever looked for a *visible* ball that should
-- not be there. Both counters therefore read zero while the hand drew nothing.
--
-- So the palm is now derived from the server's own HasBall every frame instead of
-- from a timer: held means drawn, empty means hidden. The one exception is the
-- throw's own cover, bounded by THROW_COVER, which always ends by re-reading the
-- server. A refused or dropped throw cannot leave a ball hidden, duplicated, or
-- stuck in the palm.

local palmHidden = setmetatable({}, { __mode = "k" })

-- True for the window in which a throw's own cover may legitimately be hiding the
-- palm ball. Outside it, HasBall alone decides what the palm draws.
local function coverActive(now)
	return now - (S.lastThrow or -math.huge) < THROW_COVER
end

local function sweepThrown(character, now)
	local hand = character and (character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm"))
	local balls = Workspace:FindFirstChild("DodgeBalls")
	if not (hand and balls) then
		return
	end

	local has = LocalPlayer:GetAttribute("HasBall") == true
	local handPos = hand.Position

	for _, ball in ipairs(balls:GetChildren()) do
		if ball:IsA("BasePart") then
			local delta = ball.Position - handPos
			local inPalm = delta.Magnitude <= PALM_RADIUS and math.abs(delta.Y) <= PALM_DY

			if inPalm and has then
				-- The server says a ball is held, so the palm must draw one. This is
				-- unconditional and outside any timer: whatever hid the part, the
				-- held ball is shown again.
				if ball.LocalTransparencyModifier ~= 0 then
					ball.LocalTransparencyModifier = 0
					S.palmRestores = (S.palmRestores or 0) + 1
				end
				palmHidden[ball] = nil
			elseif inPalm and not has then
				-- Empty hands: nothing may be drawn in the palm. Unconditional, for
				-- the same reason - a ball left behind there is exactly the display
				-- bug, and the weld cannot be trusted to identify it (a thrown ball
				-- keeps its weld downrange, and a ball left in the palm after a
				-- refused throw is not welded at all). The test is geometric, so it
				-- catches every shape; a ball merely passing through is hidden for
				-- the frames it overlaps, then shown again by the branch below.
				if ball.LocalTransparencyModifier ~= 1 then
					ball.LocalTransparencyModifier = 1
					S.thrownHides = (S.thrownHides or 0) + 1
				end
				palmHidden[ball] = true
			elseif palmHidden[ball] then
				ball.LocalTransparencyModifier = 0
				palmHidden[ball] = nil
			end
		end
	end
end

-- Palm watchdog. A ball leaving the hand is normal for two frames; a visible ball
-- that is still sitting in the palm half a second later with no server flag is a
-- ghost, and reporting it is the only way to tell a real display bug from a
-- passing impression. Cheap: one 0.1 s pass over DodgeBalls, and only while the
-- hand is empty.
local function watchPalm(character, now)
	if now - (S.palmAt or 0) < 0.05 then
		return
	end
	S.palmAt = now

	local hand = character and (character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm"))
	local balls = Workspace:FindFirstChild("DodgeBalls")
	if not (hand and balls) then
		S.palmNear = nil
		return
	end

	-- The ball the server says we are holding is allowed to be in the hand. Any
	-- other visible ball in the same place is the display bug.
	local held = heldBallPart(character)

	-- The blind spot the old watchdog had: it looked for a visible ball that
	-- should not be there and never for the inverse - a ball the server says is
	-- ours, welded in the palm, drawn at LocalTransparencyModifier = 1. That is
	-- exactly the shape a refused throw leaves behind, and on screen it reads as
	-- a ghost while every visible-ball counter stays at zero. A pending throw is
	-- excluded because its cover is legitimately up for one round trip.
	local has = LocalPlayer:GetAttribute("HasBall") == true
	if has and not coverActive(now) and held and held.LocalTransparencyModifier >= 0.5 then
		S.palmInvis = (S.palmInvis or 0) + 1
		if S.palmInvis % 20 == 1 then
			local log = S.palmInvisLog
			if #log >= 8 then
				table.remove(log, 1)
			end
			log[#log + 1] = string.format("%s ltm=%.2f at=%.2f", held.Name, held.LocalTransparencyModifier, os.clock())
		end
	end

	local found = nil
	for _, ball in ipairs(balls:GetChildren()) do
		if ball ~= held and ball:IsA("BasePart") and ball.LocalTransparencyModifier < 0.5 and ball.Transparency < 0.5 then
			local delta = ball.Position - hand.Position
			-- A ball in the palm sits at hand height and inside the palm. A loose
			-- ball on the floor next to a standing player is not a ghost, and
			-- counting it as one hides the real thing.
			if delta.Magnitude <= 3 and math.abs(delta.Y) <= 2.5 then
				found = ball
				break
			end
		end
	end

	-- The render proxy is what the player actually sees for a fast ball, so a
	-- stuck glide part looks exactly like a ball parked in the hand.
	local fx = Workspace:FindFirstChild("DodgeFX_Local")
	if not found and fx then
		for _, part in ipairs(fx:GetChildren()) do
			if part:IsA("BasePart") and part.Name:sub(1, 9) == "BallGlide" and part.Transparency < 0.5 then
				local delta = part.Position - hand.Position
				if delta.Magnitude <= 3 and math.abs(delta.Y) <= 2.5 then
					found = part
					break
				end
			end
		end
	end

	if not found then
		S.palmNear = nil
		return
	end

	if S.palmNear ~= found then
		S.palmNear = found
		S.palmNearAt = now
		return
	end

	if (now - (S.palmNearAt or now)) > 0.5 then
		S.palmNear = nil
		S.palmGhosts = (S.palmGhosts or 0) + 1
		local log = S.palmLog
		if #log >= 8 then
			table.remove(log, 1)
		end
		log[#log + 1] = string.format("%s vis=%.2f held=%s", found.Name, found.LocalTransparencyModifier, tostring(LocalPlayer:GetAttribute("HasBall")))
	end
end

-- Who is worth throwing at. The same population DodgeInput's kindOf accepts as an
-- enemy, minus the states where a hit cannot mean anything:
--   * Out        - eliminated this round, walks the sidelines and can still throw
--                  at the arena from outside; hitting them does nothing
--   * InPrison   - jailed, no hit registration
--   * no Health  - dead body still in the world
--   * not InMatch / Lives 0 - waiting on a respawn
--   * ProtectedUntil - spawn shield, shots pass through
local function isEngageable(model, myTeam, now)
	if not model then
		return false
	end

	local root = model:FindFirstChild("HumanoidRootPart")
	if not root then
		return false
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health <= 0 then
		return false
	end

	local team = model:GetAttribute("Team")
	if team == nil or team == myTeam then
		return false
	end

	if model:GetAttribute(OUT_ATTR) == true or model:GetAttribute("InPrison") == true then
		return false
	end

	local protectedUntil = model:GetAttribute("ProtectedUntil")
	if type(protectedUntil) == "number" and now < protectedUntil then
		return false
	end

	local player = Players:GetPlayerFromCharacter(model)
	if player then
		if player:GetAttribute("InMatch") == false then
			return false
		end
		-- Eliminated players keep a character on the sideline and can still throw
		-- back into the arena; a hit on them registers nothing.
		if (player:GetAttribute("Lives") or 1) <= 0 then
			return false
		end
		if player:GetAttribute("InPrison") == true then
			return false
		end
	end

	return true
end

-- Line of sight --------------------------------------------------------------
--
-- The nearest enemy is often on the other side of a rail, a barrier or a wall,
-- and a throw at them spends the ball on masonry. Prefer the nearest enemy the
-- hand can actually reach, and fall back to the nearest one when nobody is
-- visible (hands need to be free either way).

local losParams = RaycastParams.new()
losParams.FilterType = Enum.RaycastFilterType.Exclude

local function losFilter()
	local list = {}

	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			table.insert(list, player.Character)
		end
	end

	for _, name in ipairs({ "DodgeBots", "DodgeBalls", "DodgeFX_Local" }) do
		local folder = Workspace:FindFirstChild(name)
		if folder then
			table.insert(list, folder)
		end
	end

	return list
end

local function clearShot(origin, targetRoot)
	local chest = targetRoot.Position + Vector3.new(0, 1, 0)
	local hit = Workspace:Raycast(origin, chest - origin, losParams)
	return hit == nil
end

local function nearestEnemy(character, myTeam, origin)
	local now = Workspace:GetServerTimeNow()
	local best, bestDist
	local fallback, fallbackDist
	local candidates = {}

	local function consider(model)
		if not model or model == character then
			return
		end
		if not isEngageable(model, myTeam, now) then
			return
		end

		local root = model:FindFirstChild("HumanoidRootPart")
		local dist = (root.Position - origin).Magnitude
		if dist < 4 or dist > CONFIG.throwRange then
			return
		end

		if not fallbackDist or dist < fallbackDist then
			fallback = model
			fallbackDist = dist
		end

		candidates[#candidates + 1] = { model = model, root = root, dist = dist }
	end

	for _, player in ipairs(Players:GetPlayers()) do
		consider(player.Character)
	end

	local bots = Workspace:FindFirstChild("DodgeBots")
	if bots then
		for _, model in ipairs(bots:GetChildren()) do
			consider(model)
		end
	end

	if #candidates == 0 then
		return fallback
	end

	losParams.FilterDescendantsInstances = losFilter()
	local myRoot = character:FindFirstChild("HumanoidRootPart")
	local hand = myRoot and Ballistics.HandOrigin(myRoot) or origin

	for _, candidate in ipairs(candidates) do
		if not bestDist or candidate.dist < bestDist then
			if clearShot(hand, candidate.root) then
				best = candidate.model
				bestDist = candidate.dist
			end
		end
	end

	return best or fallback
end

-- The decision itself, pure: three replicated facts, one answer - can this
-- target return the throw?
--
--   hasBall      -> no. ThrowFX.catching answers "has a ball" while a player
--                   holds one, so a thrower with a ball cannot catch.
--   out          -> no. An eliminated player is not a target at all.
--   catchReadyAt -> no while it is still in the future: the server answers
--                   "cooldown" until then. A far-future value is a stale or
--                   replayed attribute, not a cooldown, hence the sanity bound.
--
-- Everything else and the ball gets through or misses. A throw into a catcher's
-- hands is not a hit, it is an elimination: the catcher is credited and the
-- thrower is out. That is the only remaining way the assist loses a life now, so
-- the throw is aimed only where this returns false.
local function targetCanCatch(hasBall, out, catchReadyAt, now)
	if hasBall then
		return false
	end
	if out then
		return false
	end
	if catchReadyAt and now < catchReadyAt and catchReadyAt < now + 10 then
		return false
	end
	return true
end

-- Whether a target can answer a throw that leaves now. Facing is deliberately not
-- consulted - an assist-equipped enemy snaps to face an inbound ball, so facing
-- at release says nothing about facing at arrival, and treating it as safety
-- would be a coin flip dressed as a check.
local function canCatchThrow(target, now)
	if not target then
		return false
	end

	local humanoid = target:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false
	end

	local player = Players:GetPlayerFromCharacter(target)
	local holder = player or target
	local hasBall = holder:GetAttribute("HasBall") == true
	local out = (player and player:GetAttribute("Out") == true)
		or target:GetAttribute("Out") == true

	return targetCanCatch(hasBall, out, readyAt(target, "CatchReadyAt"), now)
end

-- Perfect aim -----------------------------------------------------------------
--
-- The game's hit test does not test the body you can see. ThrowFX.touch() asks
-- TargetPoint for a *lead* position:
--   * the target's own client rewinds it by Back() = BPView + BPBack,
--   * every other machine leads it by FlatVel * 0.5 * (VIEW_DELAY + ping * 0.5),
--   * TargetPoint.Tested() then adds FlatVel * Lead() where Lead is BPLead + BPShare.
-- So the ball has to be aimed where the target will be when the ball arrives, and
-- then a little further, by that same lag lead. DodgeInput.bodyTarget iterates this
-- twice; twice leaves 1-3 studs of error at range, which is why a clean shot in the
-- crosshair still misses a moving target. This iterates to convergence.

local function flatVelOf(root)
	local vel = root.AssemblyLinearVelocity
	local flat = Vector3.new(vel.X, 0, vel.Z)

	if flat.Magnitude > 24 then
		flat = flat.Unit * 24
	end

	return flat
end

local function perfectAim(character, root, target, targetRoot)
	local speed = GameConfig.PLAYER_THROW_SPEED or GameConfig.THROW_SPEED
	local origin = Ballistics.HandOrigin(root)
	local flat = flatVelOf(targetRoot)
	local chest = Vector3.new(0, 1, 0)

	local aim = TargetPoint.Tested(character, target, targetRoot)
	if typeof(aim) ~= "Vector3" then
		aim = targetRoot.Position
	end
	aim = aim + chest

	-- Fixed point: the flight time depends on where the ball is aimed and the
	-- lead depends on the flight time. TargetPoint.Tested already carries the
	-- lag lead the hit test applies (leadPos: half flat velocity across the view
	-- delay plus half a ping), so adding a second lead here overshoots the
	-- capsule at range. This iterates the game's own bodyTarget to convergence
	-- and nothing more.
	for _ = 1, 6 do
		local t = (aim - origin).Magnitude / speed
		local base = TargetPoint.Tested(character, target, targetRoot)
		if typeof(base) ~= "Vector3" then
			base = targetRoot.Position
		end
		aim = base + flat * t + chest
	end

	return aim
end

-- Silent aim ------------------------------------------------------------------
--
-- DodgeInput.doThrow resolves an aim point from the camera ray and hands it to
-- Action:FireServer("Throw", aim, origin, stamp, seq, passTarget, attackTarget,
-- attackTargetPos). The server rebuilds the trajectory from that point, so the
-- redirect has to happen on the argument, not on the view. One detour is
-- installed for the whole session and reused across reloads; a new load swaps the
-- rewrite closure instead of stacking a second hook.

local function pointLockOn(target)
	if not CONFIG.lockOnTarget then
		return
	end

	local value = LocalPlayer:FindFirstChild("LockOnTarget")
	if not value then
		value = Instance.new("ObjectValue")
		value.Name = "LockOnTarget"
		value.Parent = LocalPlayer
	end

	if value.Value ~= target then
		value.Value = target
	end
end

local SILENT_HOOK = getgenv().__autocatch_silent

if not SILENT_HOOK then
	SILENT_HOOK = { active = false }

	local function handler(self, ...)
		local state = SILENT_HOOK
		-- The rewrite is a hold-only assist, as asked: with the button down it
		-- redirects a hand-aimed throw at the solved intercept, and with the button
		-- up the player's own aim goes out untouched. The script's own auto-throw
		-- never needs it - throwHeld already solves the intercept before it fires.
		if not state.active or self ~= state.action or not S.aimHeld then
			return state.original(self, ...)
		end

		if getnamecallmethod() ~= "FireServer" then
			return state.original(self, ...)
		end

		local args = table.pack(...)
		-- args[1] = "Throw"; args[6] non-nil means this is a pass and must keep
		-- its own target untouched.
		if args.n < 2 or args[1] ~= "Throw" or args[6] ~= nil then
			return state.original(self, ...)
		end

		-- A broken rewrite must never break a throw: on any error the original
		-- arguments go out unchanged.
		local ok = pcall(state.rewrite, args)
		if not ok then
			return state.original(self, ...)
		end

		return state.original(self, table.unpack(args, 1, args.n))
	end

	SILENT_HOOK.original = hookmetamethod(game, "__namecall", handler)
	getgenv().__autocatch_silent = SILENT_HOOK
end

SILENT_HOOK.action = Action
SILENT_HOOK.active = CONFIG.silentAim == true
SILENT_HOOK.rewrite = function(args)
	-- The script's own throws already leave the hand aimed at a solved intercept
	-- point (throwHeld), so re-solving them here only adds a second, slightly
	-- different answer to the same question. Leave those untouched; the detour is
	-- for throws the player aimed by hand.
	if args[4] ~= nil and args[4] == S.lastThrowStamp and args[5] == S.lastThrowSeq then
		S.nativeThrows = S.nativeThrows + 1
		return
	end

	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (character and root) then
		return
	end

	local now = Workspace:GetServerTimeNow()
	local myTeam = character:GetAttribute("Team") or LocalPlayer:GetAttribute("Team")

	local target = args[7]
	if target == nil or not isEngageable(target, myTeam, now) then
		local value = LocalPlayer:FindFirstChild("LockOnTarget")
		target = value and value.Value
	end
	if target == nil or not isEngageable(target, myTeam, now) then
		target = nearestEnemy(character, myTeam, root.Position)
	end

	local targetRoot = target and target:FindFirstChild("HumanoidRootPart")
	if not targetRoot then
		return
	end

	local aim = perfectAim(character, root, target, targetRoot)
	args[2] = aim
	S.lastSilentAim = aim

	if CONFIG.silentTarget then
		args[7] = target
		args[8] = targetRoot.Position
	end

	S.silentAims = S.silentAims + 1
	S.aimLast = aim
	S.aimTarget = target
end

local function throwHeld(character, root, now, requireTarget, urgent)
	-- The 0.38 s cooldown is ours, not the server's: the game's own throw gate is
	-- the ball itself. Holding a ball is the one state where no catch is possible,
	-- so when a ball is already closing, spending this cooldown means eating the
	-- hit with a ball in hand. An urgent call skips it.
	if not urgent and (now - S.lastThrow) < CONFIG.throwCooldown then
		return false
	end

	-- The server owns HasBall. A throw fired without it is a local-only ghost:
	-- the client plays the wind-up and keeps drawing a ball in the palm, nothing
	-- moves on the server, and nothing can be hit with it. That ghost is what the
	-- extra "still shootable" ball in hand was, so the gate lives here, in the one
	-- function every throw path goes through.
	if LocalPlayer:GetAttribute("HasBall") ~= true then
		return false
	end

	-- A sidelined player throws to get back in: a hit while eliminated returns him
	-- to his side. The server judges that throw like any other, so it is not
	-- gated here. `requireTarget` is the caller's way of refusing to spend the
	-- ball into empty air.
	local myTeam = character:GetAttribute("Team") or LocalPlayer:GetAttribute("Team")
	local target = nearestEnemy(character, myTeam, root.Position)
	local targetRoot = target and target:FindFirstChild("HumanoidRootPart")

	-- Never throw into a catcher. The ball comes back as the elimination, and no
	-- amount of aim fixes it - the enemy only has to press. A safe recipient is an
	-- enemy holding a ball or still on the catch cooldown; with nobody safe the
	-- ball is thrown downrange instead, which still frees the hand for the next
	-- catch and gives the enemy nothing to catch.
	if target and canCatchThrow(target, now) then
		S.throwUnsafe = (S.throwUnsafe or 0) + 1
		target = nil
		targetRoot = nil
		if requireTarget then
			return false
		end
	end

	if requireTarget and not targetRoot then
		return false
	end

	local aimPos

	if targetRoot and CONFIG.perfectThrow then
		aimPos = perfectAim(character, root, target, targetRoot)
	elseif targetRoot then
		aimPos = targetRoot.Position
	else
		local look = root.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude < 0.01 then
			flat = Vector3.new(0, 0, -1)
		end
		aimPos = root.Position + flat.Unit * CONFIG.throwFallback
	end

	S.lastThrowTarget = target

	local flatAim = Vector3.new(aimPos.X, root.Position.Y, aimPos.Z)
	if (flatAim - root.Position).Magnitude > 1 then
		root.CFrame = CFrame.lookAt(root.Position, flatAim)
	end

	local origin = Ballistics.HandOrigin(root)
	local stamp = Workspace:GetServerTimeNow()
	throwSeq = throwSeq + 1

	local okLaunch, launch = pcall(Ballistics.Attack, origin, aimPos, GameConfig.PLAYER_THROW_SPEED)
	if not okLaunch or type(launch) ~= "table" then
		return false
	end

	-- Captured before the throw leaves the client: once the ball is hidden or has
	-- moved, the glide would start away from the palm.
	local held = heldBallPart(character)

	-- Registered before the remote fires, not after. The server's confirmation can
	-- land on the next frame, and anything the throw path does between FireServer
	-- and this assignment - an animation call that yields - is a window in which
	-- the ack has nobody to match. That window is why every throw looked refused.
	S.throwPending = {
		part = held,
		at = now,
		seq = throwSeq,
		acked = false,
	}

	local okPredict, predicted = pcall(ThrowFX.Predict, throwSeq, {
		-- Same `from` the game passes: the glide starts at the ball in the palm, so
		-- the visual leaves the hand instead of appearing a stud in front of it.
		from = held and held.LocalTransparencyModifier < 0.5 and held.Position or nil,
		skin = LocalPlayer:GetAttribute(Shared.ATTR.Skin) or Shared.DEFAULTS.Skin,
		fx = LocalPlayer:GetAttribute(Shared.ATTR.Throw) or Shared.DEFAULTS.Throw,
		p0 = launch.p0,
		v0 = launch.v0,
		t0 = stamp,
		g = launch.g,
		pass = false,
	})

	S.lastThrowAim = aimPos
	S.lastThrowStamp = stamp
	S.lastThrowSeq = throwSeq
	Action:FireServer("Throw", aimPos, origin, stamp, throwSeq, nil, nil, nil)

	-- The client half of the throw. doThrow does all of this after the remote, and
	-- without it the client keeps drawing the welded ball in the palm: the model
	-- is never hidden, the hold animation never stops, and a second throw can fire
	-- against a ball the server has already taken away. Same calls, same order.
	pcall(function()
		DodgeAnims.Stop(character, "ThrowWindup", 0.03)
		DodgeAnims.Stop(character, "HoldBall", 0.05)
		DodgeAnims.Play(character, "Throw", { fadeIn = 0.03, fadeOut = 0.15 })
	end)

	-- No HidePart here. ThrowFX.HidePart writes LocalTransparencyModifier = 1 and
	-- records an expiry nothing in the module ever reads, so a part it hid stayed
	-- hidden until unrelated code touched it - which is exactly how a ball the
	-- server handed back into the same hand came back invisible. The palm is now
	-- drawn from HasBall alone in sweepThrown: held means drawn, empty means
	-- hidden. The cost is one round trip of a visible ball in the palm after a
	-- throw; the alternative was a ghost with no expiry.
	if held then
		S.thrownPart = held
		S.thrownAt = now
	end

	S.throwVisual = okPredict and predicted or nil

	S.lastThrow = now
	S.throws = S.throws + 1
	return true
end

-- Throw reconciliation --------------------------------------------------------
--
-- One throw, three things that can be wrong, all of them display-only:
--
--   accepted  -> the server broadcasts `Throw` on DodgeFX FX carrying `ref` equal
--                to the id we gave Predict, so the prediction is reused and the
--                ball leaves the hand. Cover expires on its own.
--   refused   -> no broadcast ever arrives. The prediction would fly for 1.2 s
--                and then vanish, and the palm ball would stay hidden for the
--                whole cover window with the ball still ours. That is the ghost:
--                a phantom throw followed by an empty hand holding a real ball.
--   dropped   -> same as refused from the client's side.
--
-- So the throw is only believed once the server says so. If `THROW_ACK_WAIT`
-- passes with no ack and the ball is still welded in the palm, the prediction is
-- stopped and the part is shown again. `ShowPart` clears ThrowFX's own expiry
-- entry, and the direct write covers the case where that entry is already gone.

local function reconcileThrow(character, now)
	local pending = S.throwPending
	if not pending then
		return
	end

	if pending.acked then
		-- Confirmed: the ball left the hand for real. Nothing to restore, and the
		-- prediction is the same ref OnThrow reused.
		S.throwPending = nil
		S.throwVisual = nil
		return
	end

	if now - pending.at < THROW_ACK_WAIT then
		return
	end

	local part = pending.part
	local hand = character and (character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm"))

	-- Still welded to the hand and still inside the palm means the server never
	-- took the ball away: the throw did not happen. Anything else means the ball
	-- did leave (or was replaced) and the cover should be left to expire.
	if part and hand and part.Parent == Workspace.DodgeBalls and (part.Position - hand.Position).Magnitude <= PALM_RADIUS then
		pcall(ThrowFX.ShowPart, part)
		part.LocalTransparencyModifier = 0
		palmHidden[part] = nil

		if S.throwVisual then
			pcall(ThrowFX.Stop, S.throwVisual, false)
		end

		S.throwRefused = S.throwRefused + 1
		local log = S.palmInvisLog
		if #log >= 8 then
			table.remove(log, 1)
		end
		log[#log + 1] = string.format("refused=%s at=%.2f seq=%d", part.Name, os.clock(), pending.seq)
	end

	S.throwPending = nil
	S.throwVisual = nil
	local recon = S.reconLog
	if #recon >= 8 then
		table.remove(recon, 1)
	end
	recon[#recon + 1] = string.format("clear delta=%.3f acked=%s seq=%d", now - pending.at, tostring(pending.acked), pending.seq)
end

-- UI -------------------------------------------------------------------------
--
-- Two surfaces, one job each. The HUD line stays where it was - one glanceable
-- string in the corner, no interaction. The panel is the control surface: every
-- toggle and slider writes straight into CONFIG and the live state, so what the
-- panel says is what the assist is doing, never a copy that can drift.
--
-- Fluent is the Microsoft-Fluent-style library: static panel, no animated hub, no
-- dependencies beyond the loadstring. It is loaded through pcall because the
-- assist has to keep working with no internet - a missing panel must not take the
-- catch and dash down with it.

local gui
local label
local Fluent
local panelFailed = nil

local function buildLabel()
	if not CONFIG.showLabel then
		return
	end

	gui = Instance.new("ScreenGui")
	gui.Name = "AutoCatchStatus"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 200
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

	label = Instance.new("TextLabel")
	label.Name = "Status"
	label.Size = UDim2.new(0, 250, 0, 26)
	label.Position = UDim2.new(0.5, -125, 0, 132)
	label.BackgroundColor3 = Color3.fromRGB(12, 14, 18)
	label.BackgroundTransparency = 0.25
	label.BorderSizePixel = 0
	label.Font = Enum.Font.GothamMedium
	label.TextSize = 13
	label.TextColor3 = Color3.fromRGB(120, 255, 170)
	label.Text = "AUTO CATCH"
	label.Parent = gui

	-- The engine applies the topbar inset to ScreenGui children even with
	-- IgnoreGuiInset set, so measure once and correct the offset.
	local drift = 132 - label.AbsolutePosition.Y
	if math.abs(drift) > 0.5 then
		label.Position = UDim2.new(0.5, -125, 0, 132 + drift)
	end

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = label
end

local function paint(text, good)
	if label then
		label.Text = text
		label.TextColor3 = good and Color3.fromRGB(120, 255, 170) or Color3.fromRGB(255, 196, 110)
	end
end

-- One summary string, built from the same counters the diagnostics read. This is
-- what the HUD shows and what the panel's status paragraph refreshes to, so the
-- two can never tell different stories.
local function summaryText()
	return string.format(
		"catch %s  |  press %d  ack %d  |  hit %d  bad %d  |  dash %d  side %d  |  path open %d fired %d",
		S.enabled and "on" or "off",
		S.presses or 0,
		S.catchAcks or 0,
		S.contactOk or 0,
		S.contactBad or 0,
		S.dodges or 0,
		S.sidesteps or 0,
		S.pathOpen or 0,
		S.pathJukes or 0
	)
end

local function ensurePanel()
	if Fluent or panelFailed then
		return Fluent
	end

	local ok, result = pcall(function()
		return loadstring(game:HttpGet("https://github.com/dawid-scripts/Fluent/releases/latest/download/main.lua"))()
	end)

	if not ok or type(result) ~= "table" then
		panelFailed = tostring(result)
		return nil
	end

	Fluent = result
	return Fluent
end

local function buildPanel()
	local lib = ensurePanel()
	if not lib then
		return nil
	end

	local Window = lib:CreateWindow({
		Title = "AutoCatch",
		SubTitle = "dodgeball assist",
		TabWidth = 150,
		Size = UDim2.fromOffset(540, 430),
		-- Off on purpose. Acrylic re-blurs the game every frame, and this script's
		-- whole argument is that a frame must not be spent where an answer lives.
		Acrylic = false,
		Theme = "Dark",
		MinimizeKey = Enum.KeyCode.LeftControl,
	})

	local Tabs = {
		Assist = Window:AddTab({ Title = "Assist", Icon = "shield" }),
		Aim = Window:AddTab({ Title = "Aim", Icon = "crosshair" }),
		Tuning = Window:AddTab({ Title = "Tuning", Icon = "sliders-horizontal" }),
		Diag = Window:AddTab({ Title = "Diagnostics", Icon = "activity" }),
	}

	-- Every control is registered with the state it is supposed to own. A button
	-- that does nothing and a toggle wired to a key nobody reads look identical
	-- from the outside, so the binding is recorded here and read back by
	-- S.panelBindings() instead of being taken on trust.
	local bindings = {}
	local function bind(id, element, get)
		bindings[#bindings + 1] = { id = id, element = element, get = get }
	end

	-- A paragraph's text is written once by the library, so the live line lives in
	-- the label underneath it and is rewritten by the refresh timer below.
	local statusParagraph = Tabs.Assist:AddParagraph({
		Title = "Status",
		Content = "",
	})
	local statusLabel = statusParagraph and statusParagraph.Title
	if statusLabel then
		statusLabel.Text = summaryText()
	end

	local hud = Tabs.Assist:AddToggle("ShowHud", {
		Title = "On-screen status line",
		Description = "The compact summary above the hotbar. Hiding it does not touch the panel.",
		Default = CONFIG.showLabel == true,
	})
	hud:OnChanged(function(value)
		CONFIG.showLabel = value
		if value and not gui then
			buildLabel()
		elseif not value and gui then
			gui:Destroy()
			gui, label = nil, nil
		end
	end)
	bind("ShowHud", hud, function()
		return CONFIG.showLabel == true
	end)

	-- The master switch is the same flag RightShift flips, not a second one.
	local enabled = Tabs.Assist:AddToggle("Enabled", {
		Title = "Catch + dodge",
		Description = "Master switch. RightShift does the same thing.",
		Default = S.enabled == true,
	})
	enabled:OnChanged(function(value)
		S.enabled = value
	end)
	bind("Enabled", enabled, function()
		return S.enabled == true
	end)

	local throwToggle = Tabs.Assist:AddToggle("AutoThrow", {
		Title = "Auto throw",
		Description = "Throw the held ball when a dash cannot save the hit.",
		Default = CONFIG.autoThrow == true,
	})
	throwToggle:OnChanged(function(value)
		CONFIG.autoThrow = value
	end)
	bind("AutoThrow", throwToggle, function()
		return CONFIG.autoThrow == true
	end)

	local reentry = Tabs.Assist:AddToggle("AutoReentry", {
		Title = "Auto throw on re-entry",
		Description = "Off: the sidelined pickup is thrown by you. On: fires the instant the ball is grabbed.",
		Default = CONFIG.autoReentry == true,
	})
	reentry:OnChanged(function(value)
		CONFIG.autoReentry = value
	end)
	bind("AutoReentry", reentry, function()
		return CONFIG.autoReentry == true
	end)

	local dodgeToggle = Tabs.Assist:AddToggle("Dodge", {
		Title = "Dash",
		Description = "Spend the server dash when contact is inside the i-frame band.",
		Default = CONFIG.autoDodge ~= false,
	})
	dodgeToggle:OnChanged(function(value)
		CONFIG.autoDodge = value
	end)
	bind("Dodge", dodgeToggle, function()
		return CONFIG.autoDodge ~= false
	end)

	local sideToggle = Tabs.Assist:AddToggle("Sidestep", {
		Title = "Sidestep",
		Description = "Walk out of the line when the dash is unavailable.",
		Default = CONFIG.sidestep ~= false,
	})
	sideToggle:OnChanged(function(value)
		CONFIG.sidestep = value
	end)
	bind("Sidestep", sideToggle, function()
		return CONFIG.sidestep ~= false
	end)

	-- Aim ------------------------------------------------------------------
	local aim = Tabs.Aim:AddToggle("SilentAim", {
		Title = "Silent aim",
		Description = "Rewrites the aim point on the game's own Throw remote. Camera untouched.",
		Default = CONFIG.silentAim == true,
	})
	aim:OnChanged(function(value)
		CONFIG.silentAim = value
		SILENT_HOOK.active = value
	end)
	bind("SilentAim", aim, function()
		return CONFIG.silentAim == true
	end)

	local aimTarget = Tabs.Aim:AddToggle("SilentTarget", {
		Title = "Stamp target",
		Description = "Also put the resolved enemy in the throw payload.",
		Default = CONFIG.silentTarget == true,
	})
	aimTarget:OnChanged(function(value)
		CONFIG.silentTarget = value
	end)
	bind("SilentTarget", aimTarget, function()
		return CONFIG.silentTarget == true
	end)

	local lock = Tabs.Aim:AddToggle("AimLock", {
		Title = "Aim lock (hold RMB)",
		Description = "Moves the camera onto the target while the right button is held. Off by default.",
		Default = CONFIG.autoAim == true,
	})
	lock:OnChanged(function(value)
		CONFIG.autoAim = value
		if not value then
			S.aimHeld = false
		end
	end)
	bind("AimLock", lock, function()
		return CONFIG.autoAim == true
	end)

	local perfect = Tabs.Aim:AddToggle("PerfectThrow", {
		Title = "Perfect throw",
		Description = "Solve the intercept the way the game's hit test reads it.",
		Default = CONFIG.perfectThrow ~= false,
	})
	perfect:OnChanged(function(value)
		CONFIG.perfectThrow = value
	end)
	bind("PerfectThrow", perfect, function()
		return CONFIG.perfectThrow ~= false
	end)

	-- Tuning ---------------------------------------------------------------
	local function tune(id, key, title, description, min, max, rounding)
		local value = tonumber(CONFIG[key]) or min
		local slider = Tabs.Tuning:AddSlider(id, {
			Title = title,
			Description = description,
			Default = value,
			Min = min,
			Max = max,
			Rounding = rounding or 2,
		})
		slider:OnChanged(function(new)
			setNumber(key, new)
		end)
		bind(id, slider, function()
			return tonumber(CONFIG[key])
		end)
		return slider
	end

	tune("DodgeLead", "dodgeLead", "Dash lead", "Seconds before contact the dash is spent.", 0.04, 0.30)
	tune("SideLead", "sideLead", "Sidestep lead", "Seconds before contact the walk begins.", 0.10, 0.90)
	tune("Horizon", "horizon", "Threat horizon", "How far ahead a ball is answered at all.", 0.30, 1.20)
	tune("PressBias", "pressBias", "Press bias", "Stamp offset applied when pressing.", 0.0, 0.05)

	local cooldown = Tabs.Tuning:AddSlider("ThrowCooldown", {
		Title = "Throw cooldown",
		Description = "Local gap between throws.",
		Default = CONFIG.throwCooldown,
		Min = 0.10,
		Max = 1.00,
		Rounding = 2,
	})
	cooldown:OnChanged(function(value)
		setNumber("throwCooldown", value)
	end)
	bind("ThrowCooldown", cooldown, function()
		return tonumber(CONFIG.throwCooldown)
	end)

	-- Diagnostics ----------------------------------------------------------
	Tabs.Diag:AddParagraph({
		Title = "Sweep",
		Content = "selftest folds every pure sweep into one pass/fail. Path and frame rows are live.",
	})

	Tabs.Diag:AddButton({
		Title = "Run selftest",
		Description = "Every pure sweep, folded into one pass/fail.",
		Callback = function()
			local result = S.selftest()
			local failing = {}
			for _, row in ipairs(result.rows) do
				if row:find("FAIL") then
					failing[#failing + 1] = row
				end
			end
			lib:Notify({
				Title = "selftest",
				Content = string.format("%d rows, %d failures", #result.rows, result.failures),
				SubContent = failing[1] or "all green",
				Duration = 8,
			})
		end,
	})

	Tabs.Diag:AddButton({
		Title = "Ghost report",
		Description = "Palm display audit.",
		Callback = function()
			local ghost = S.ghostReport()
			lib:Notify({
				Title = "ghost",
				Content = tostring(ghost.verdict),
				SubContent = string.format("restores %d, ghosts %d", S.palmRestores or 0, S.palmGhosts or 0),
				Duration = 8,
			})
		end,
	})

	Tabs.Diag:AddButton({
		Title = "Frame budget",
		Description = "Game frame delta vs this script's per-tick cost.",
		Callback = function()
			local stats = S.frameStats()
			local frames = stats.frames or {}
			local steps = stats.step or {}
			lib:Notify({
				Title = "frame budget",
				Content = string.format(
					"frame p99 %.1f ms  step p99 %.2f ms",
					(frames.p99 or 0) * 1000,
					(steps.p99 or 0) * 1000
				),
				SubContent = string.format("spikes %d over 50 ms", stats.spikes or 0),
				Duration = 10,
			})
		end,
	})

	Tabs.Diag:AddButton({
		Title = "Copy counters",
		Description = "Put the live summary on the clipboard.",
		Callback = function()
			local text = summaryText()
			if setclipboard then
				setclipboard(text)
			end
			lib:Notify({ Title = "counters", Content = "copied", SubContent = text, Duration = 6 })
		end,
	})

	-- Unload ---------------------------------------------------------------
	Tabs.Diag:AddButton({
		Title = "Unload script",
		Description = "Stop everything and leave the game as it was.",
		Callback = function()
			Window:Dialog({
				Title = "Unload",
				Content = "Disconnect, restore the palm display, and remove the panel?",
				Buttons = {
					{
						Title = "Unload",
						Callback = function()
							-- Deferred: this runs inside the library's own dialog
							-- callback, and the unload destroys the library. Let the
							-- dialog finish dismissing first, then tear down.
							task.defer(function()
								if S.unload then
									S.unload()
								end
							end)
						end,
					},
					{ Title = "Cancel", Callback = function() end },
				},
			})
		end,
	})

	Window:SelectTab(1)

	-- A handle for diagnostics. The panel is part of the deliverable, so a report
	-- must be able to read back what its controls are set to without clicking.
	S.panel = { lib = lib, window = Window, failed = nil, bindings = bindings }

	-- Slow refresh, independent of the decision loop. 4 Hz is enough for a status
	-- line and is 1/15th of the tick rate the catch path runs at.
	task.spawn(function()
		while Fluent == lib and not lib.Unloaded do
			local text = summaryText()
			paint(text, S.enabled == true)
			if statusLabel then
				pcall(function()
					statusLabel.Text = text
				end)
			end
			task.wait(0.25)
		end
	end)

	return Window
end

local function facingDot(root, dir)
	local flat = Vector3.new(dir.X, 0, dir.Z)
	local look = root.CFrame.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)

	if flat.Magnitude < 0.01 or flatLook.Magnitude < 0.01 then
		return 1
	end

	return flatLook.Unit:Dot(-flat.Unit)
end

local function rotateTo(root, dir)
	local flat = Vector3.new(dir.X, 0, dir.Z)
	if flat.Magnitude < 0.01 then
		return
	end

	local incoming = -flat.Unit
	if facingDot(root, dir) >= CATCH_ANGLE_COS then
		return
	end

	-- Snap, don't lerp: at point blank there is no time to interpolate through
	-- the cone, and the server reads the replicated root at contact.
	root.CFrame = CFrame.lookAt(root.Position, root.Position + incoming)
	S.turns = S.turns + 1
end

-- Movement impulse ------------------------------------------------------------
--
-- Every evasion that has to survive the movement controller uses this. A
-- `Humanoid:Move` write and a direct AssemblyLinearVelocity write are both
-- overwritten by the next WalkForce step - which is fine while the player stands
-- still and useless the moment a movement key is held, because then the
-- controller has an input to enforce and the assist has only a suggestion. The
-- game's own dash is a Plane LinearVelocity constraint and that is the mechanism
-- that actually holds, so it is the mechanism used here for the dash, the
-- sidestep and the juke alike. One slot per owner: a new impulse of the same kind
-- replaces the old one instead of stacking, and each carries its own lifetime.
local impulseSlots = {}

local function stopImpulse(slot)
	local entry = impulseSlots[slot]
	if not entry then
		return
	end
	impulseSlots[slot] = nil
	pcall(function()
		entry.vel:Destroy()
	end)
	pcall(function()
		entry.att:Destroy()
	end)
end

local function applyImpulse(root, slot, unit, speed, life)
	stopImpulse(slot)

	local attachment = Instance.new("Attachment")
	attachment.Parent = root

	local velocity = Instance.new("LinearVelocity")
	velocity.Attachment0 = attachment
	velocity.MaxForce = math.max(root.AssemblyMass, 1) * 2500
	velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	velocity.PrimaryTangentAxis = Vector3.new(1, 0, 0)
	velocity.SecondaryTangentAxis = Vector3.new(0, 0, 1)
	velocity.PlaneVelocity = Vector2.new(unit.X, unit.Z) * speed
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.Parent = root

	impulseSlots[slot] = { vel = velocity, att = attachment }

	task.delay(life, function()
		local entry = impulseSlots[slot]
		if entry and entry.vel == velocity then
			stopImpulse(slot)
		end
	end)

	return velocity, attachment
end

local function stopAllImpulses()
	for slot in pairs(impulseSlots) do
		stopImpulse(slot)
	end
end

-- The dash owns the body while its constraint is alive. Three Plane constraints
-- with the same MaxForce do not add, they argue, and the solver's answer is not
-- the dash's. Measured live over 52 dash frames: a sidestep impulse was alive
-- for 26 of them, and the dash travelled 0.02, 0.74, 3.66, 6.20 or 9.81 studs
-- depending on whether one overlapped and which way it pushed. One of those
-- dashes moved the body 3.17 studs backwards along its own axis. So every other
-- writer to the same plane stands down for the dash window, and the dash's
-- displacement stops being a property of the schedule.
local function dashLive()
	local velocity = S.dashVel
	if not velocity then
		return false
	end
	-- A constraint whose attachment has left the body is a corpse: the character
	-- was destroyed mid-dash (death, respawn, teleport). Without this check the
	-- handle stays non-nil and every sidestep and juke for the rest of the
	-- session is refused by a dash that no longer exists.
	local attachment = S.dashAtt
	if not attachment or not attachment.Parent then
		S.dashVel = nil
		S.dashAtt = nil
		return false
	end
	return true
end

-- Juke -----------------------------------------------------------------------
--
-- The hit test on every machine that is not the target's own leads the target by
-- half its flat velocity across the view delay plus half a ping
-- (ThrowFX.leadPos). On a 24 studs/s strafe at 70 ms ping that is ~2.3 studs of
-- forward lead, which is most of the capsule. Standing still or braking removes
-- that lead, so the prediction lands past the body instead of on it. This only
-- fires when a catch cannot happen anyway.

local function juke(character, root, dir, now)
	if not CONFIG.juke then
		return false
	end
	if dashLive() then
		S.dashBlocked = (S.dashBlocked or 0) + 1
		return false
	end
	if (now - S.lastJuke) < CONFIG.jukeCooldown then
		return false
	end

	local vel = root.AssemblyLinearVelocity
	local flat = Vector3.new(vel.X, 0, vel.Z)
	local escape = Vector3.new(0, 0, 0)

	if dir then
		local flatDir = Vector3.new(dir.X, 0, dir.Z)
		if flatDir.Magnitude > 0.01 then
			local side = flatDir.Unit:Cross(Vector3.new(0, 1, 0))
			if side.Magnitude > 0.01 then
				if flat.Magnitude > 1 and side:Dot(flat) < 0 then
					side = -side
				end
				escape = side.Unit * CONFIG.jukeSpeed
			end
		end
	end

	-- Kill the forward motion the hit test is extrapolating, then shove sideways.
	-- The shove is a constraint rather than a velocity write for the same reason
	-- the dash is: the WalkForce step rewrites AssemblyLinearVelocity from the
	-- player's input on the next frame, so a write that works while standing still
	-- does nothing at all while a key is held. The constraint overrides the input
	-- for its own short life and then releases it.
	if escape.Magnitude > 0.01 then
		applyImpulse(root, "juke", escape.Unit, CONFIG.jukeSpeed, 0.12)
	end

	S.lastJuke = now
	S.jukes = S.jukes + 1
	return true
end

-- Sustained sidestep. A juke is one shove; when the dash is still on its 2.2 s
-- cooldown there is no cooldown left to spend, so the remaining answer is to keep
-- walking out of the line for as long as the ball is closing. Humanoid:Move holds
-- against the movement controller every frame, and it costs nothing the hit test
-- can punish: the server leads by half our velocity, and half of 22 studs/s over
-- the last 0.3 s is 3.3 studs, which is inside the 8+ studs the sidestep covers.
local function sidestep(character, root, dir, now, tti, off, ball)
	if not CONFIG.sidestep or (now - S.lastSide) < 0.10 then
		return false
	end
	if dashLive() then
		S.dashBlocked = (S.dashBlocked or 0) + 1
		return false
	end

	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or root.Anchored then
		return false
	end

	-- Eliminated bodies do not step. `dodge` has always refused here, `canPress`
	-- refuses here, and the sidestep did not - so while sidelined, walking to the
	-- loose ball that re-enters the field, the assist kept taking the keyboard and
	-- shoving the body off the pickup. The walk to that ball is the only movement
	-- that matters in that state and nothing else is worth a step.
	if character:GetAttribute(OUT_ATTR) == true then
		S.sideOut = (S.sideOut or 0) + 1
		return false
	end

	-- Movement input no longer refuses the sidestep. It used to: a key-down test
	-- meant every evade was skipped the moment the player touched WASD, which is
	-- exactly when a ball is hardest to see and the assist is most wanted. The
	-- sidestep now rides the player's own drift instead of fighting it - the side
	-- is chosen to agree with the current velocity below - and the hold is short
	-- enough that it reads as the player stepping out of the line rather than the
	-- assist taking the keyboard.

	local flatDir = dir and Vector3.new(dir.X, 0, dir.Z)
	if not flatDir or flatDir.Magnitude < 0.01 then
		return false
	end

	local side = flatDir.Unit:Cross(Vector3.new(0, 1, 0))
	if side.Magnitude < 0.01 then
		return false
	end

	-- Keep whatever side the body is already drifting toward, so two threats in a
	-- row do not cancel each other out. Unless the predictor knows which side of
	-- the ball's line the body is on - then the away side wins, because a step
	-- toward the line has to cross it before it clears anything.
	local vel = root.AssemblyLinearVelocity
	local flatVel = Vector3.new(vel.X, 0, vel.Z)
	local unit = side.Unit
	local away = off and Vector3.new(off.X, 0, off.Z)
	if away and away.Magnitude > 0.05 then
		-- `off` is body-toward-line. The step is `-off`. The old test agreed the
		-- unit WITH `off`, which walked the body into the ball's line: measured
		-- live over 11 sidesteps, dot(sideDir, off) was positive on 8 and never
		-- negative, and the misses it produced (0.82-2.36) all sat inside the
		-- reach radius.
		unit = -away.Unit
	elseif flatVel.Magnitude > 1 and unit:Dot(flatVel) < 0 then
		unit = -unit
	end

	-- One committed side per approach. `off` is recomputed every tick and swings
	-- as the geometry moves; re-picking a side from it on every re-arm is what
	-- made the body shuttle instead of stepping once. The first side chosen for
	-- this ball holds until the ball changes or the commitment ages out.
	if ball and S.sideBall == ball and S.sideUnit and (now - (S.sideStamp or 0)) < 0.8 then
		unit = S.sideUnit
	else
		S.sideBall = ball
		S.sideUnit = unit
		S.sideStamp = now
	end

	-- The hold. `Humanoid:Move` states the intent and keeps the animation honest;
	-- the constraint is what actually travels while a movement key is held or the
	-- auto-play agent is circling. Walk speed rather than dash speed: this is a
	-- step out of the line, not a second dash, and the dash cooldown is the only
	-- budget this assists spends on distance.
	local hold = math.clamp((tti or 0.2) + 0.10, 0.14, 0.45)
	local walk = humanoid.WalkSpeed > 0 and humanoid.WalkSpeed or 22
	local speed = math.clamp(walk, 8, GameConfig.DODGE_SPEED or 64)

	-- A step into a wall is not a step. Same probe as the dash, over the distance
	-- this hold will actually cover, and the committed side follows whatever the
	-- probe chose so a re-arm inside the hold does not flip back into the wall.
	local probe = freeSide(character, root, unit, speed * hold)
	if probe ~= unit then
		unit = probe
		S.sideFlipped = (S.sideFlipped or 0) + 1
	end
	if S.sideBall == ball then
		S.sideUnit = unit
	end

	humanoid:Move(unit, false)
	applyImpulse(root, "side", unit, speed, hold)
	S.sideDir = unit
	if not S.sidestepUntil then
		S.sideFrom = root.Position
	end
	S.lastSide = now
	S.sidestepUntil = now + hold
	S.sidesteps = (S.sidesteps or 0) + 1
	edge("side")
	return true
end

-- Dodge ----------------------------------------------------------------------
--
-- The catch judge refuses everything for 0.6 s after a catch lands, so a second
-- ball inside that window cannot be caught by anyone. The dodge action is the
-- game's answer: the server applies DODGE_IFRAMES (0.26 s) on receipt, which is
-- wider than the throw's own travel time at arena range.
--
-- The impulse is a Plane LinearVelocity constraint, exactly as DodgeInput.doDodge
-- builds it, not a one-shot AssemblyLinearVelocity write: the constraint holds
-- against the movement controller for the whole DODGE_TIME, so the dash is real
-- on every client that reads the replicated root. A direct velocity write is
-- cancelled by the next WalkForce step and the hit test then reads a stationary
-- target again.

local function dashStop()
	local velocity = S.dashVel
	local attachment = S.dashAtt
	S.dashVel = nil
	S.dashAtt = nil

	if velocity then
		pcall(function()
			velocity:Destroy()
		end)
	end
	if attachment then
		pcall(function()
			attachment:Destroy()
		end)
	end
end

-- DodgeAnims.Play picks its clip from the same object-space test, so deriving
-- the name here keeps the remote's second argument honest.
local function dashAnim(root, unit)
	local localDir = root.CFrame:VectorToObjectSpace(unit)
	if localDir.Z < -0.55 then
		return "DashForward"
	elseif localDir.Z > 0.55 then
		return "DodgeBack"
	elseif localDir.X < 0 then
		return "DodgeLeft"
	end
	return "DodgeRight"
end

local function dodge(character, root, now, ballDir, src, miss, off)
	local why = S.dodgeWhy
	if not CONFIG.autoDodge then
		why.off = (why.off or 0) + 1
		return false
	end

	-- doDodge's own gates. A dash fired outside a live round is refused by the
	-- server and still burns nothing but the packet; the cooldown is only written
	-- on receipt, so a refused dash would desync S.lastDodge from the game's.
	if LocalPlayer:GetAttribute("InMatch") ~= true then
		why.inmatch = (why.inmatch or 0) + 1
		return false
	end
	if DodgeMatch:GetAttribute("Phase") ~= "Playing" then
		why.phase = (why.phase or 0) + 1
		return false
	end
	if character:GetAttribute(OUT_ATTR) == true then
		why.out = (why.out or 0) + 1
		return false
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or root.Anchored then
		why.body = (why.body or 0) + 1
		return false
	end

	-- The server publishes the dash cooldown on both the player and the
	-- character. A dash inside that window is refused and grants no i-frames, so
	-- it is not worth the packet, and it must not write S.lastDodge either: that
	-- is the only record of a dash the server actually accepted.
	local dashReady = readyAt(character, "DashReadyAt")
	if dashReady and now < dashReady and dashReady < now + 10 then
		S.dashRefused = (S.dashRefused or 0) + 1
		why.cooldown = (why.cooldown or 0) + 1
		return false
	end

	-- Local record of the last dash the server accepted. The published cooldown
	-- above should already cover this; a refusal here means S.lastDodge and the
	-- attribute have drifted, which is a separate fault from a dash on cooldown
	-- and gets its own counter.
	if (now - S.lastDodge) < (GameConfig.DODGE_COOLDOWN or 2.2) then
		why.cadence = (why.cadence or 0) + 1
		return false
	end

	local vel = root.AssemblyLinearVelocity
	local run = Vector3.new(vel.X, 0, vel.Z)
	local dir

	-- Sideways across the ball line beats straight back: it also slides out from
	-- under the hit test's own velocity lead, and it costs less distance.
	--
	-- Which side is not a matter of taste. The predictor already computes the
	-- body's perpendicular offset at closest approach (`off`); stepping along it
	-- adds to that offset, and stepping against it has to cross the line before
	-- it clears anything - a dash that travels ten studs and ends up on the ball's
	-- path. The body's own drift is only the tie-break, for the case where the
	-- body is exactly on the line and both sides are equally good.
	local flat = ballDir and Vector3.new(ballDir.X, 0, ballDir.Z)
	if flat and flat.Magnitude > 0.01 then
		local side = flat.Unit:Cross(Vector3.new(0, 1, 0))
		if side.Magnitude > 0.01 then
			dir = side.Unit
			local away = off and Vector3.new(off.X, 0, off.Z)
			if away and away.Magnitude > 0.05 then
				-- `off` is body-toward-line, so the dash goes along `-off`. The old
				-- sign agreed the dash WITH `off`: measured live at miss=0.97 the
				-- dash owed 2.03, crossed the line and finished 1.06 studs on the
				-- far side, still inside the 2.4 reach radius - a dash that spent
				-- its whole budget to arrive closer to the ball.
				dir = -away.Unit
			elseif run.Magnitude > 1 and dir:Dot(run) < 0 then
				dir = -dir
			end
		end
	end

	if not dir then
		local move = humanoid.MoveDirection
		local moveFlat = Vector3.new(move.X, 0, move.Z)
		if moveFlat.Magnitude >= 0.1 then
			dir = moveFlat.Unit
		else
			local look = root.CFrame.LookVector
			dir = -Vector3.new(look.X, 0, look.Z).Unit
		end
	end

	local unit = dir.Unit
	local speed = GameConfig.DODGE_SPEED or 64

	-- How far this dash has to travel is a property of the ball in front of it,
	-- not of the action. `miss` is the centre-to-centre distance the tracker
	-- predicts at closest approach, so the distance still owed is whatever it
	-- takes to reach the catch radius plus margin, corrected for the drift the
	-- dash is about to take away. A dash that only has to step half a stud should
	-- not spend ten, and a dash that has to step eight should not stop at four.
	local need = dashOwed(miss, off, run, speed)

	local target = math.max(need, DODGE_MIN_TRAVEL)
	local cap = speed * DODGE_MAX_LIFE
	if target > cap then
		target = cap
	end

	-- The side is only worth taking if the floor is there to take it. Probe both
	-- before the anim is picked, so the animation matches the direction the body
	-- actually travels.
	local probe, room = freeSide(character, root, unit, target)
	if room and room < DODGE_MIN_TRAVEL * 0.4 then
		-- Both sides closed. Spending the 2.2 s cooldown on a dash that can move a
		-- tenth of a stud is strictly worse than keeping it: measured live, one such
		-- dash ran its full life and finished 0.03 studs *behind* its own axis,
		-- pushed back by the same geometry it was aimed at.
		S.dashNoRoom = (S.dashNoRoom or 0) + 1
		return false
	end
	if probe ~= unit then
		unit = probe
		S.dashFlipped = (S.dashFlipped or 0) + 1
	end
	local anim = dashAnim(root, unit)

	S.dashBallId = S.dashBall and S.dashBall.id or nil

	dashStop()

	-- A dash takes the body from every other writer to the same plane. Cancelling
	-- theirs is half the fix; refusing to start theirs is the other half, above.
	stopImpulse("side")
	stopImpulse("juke")
	S.sidestepUntil = nil
	S.sideDir = nil

	local attachment = Instance.new("Attachment")
	attachment.Parent = root

	local velocity = Instance.new("LinearVelocity")
	velocity.Attachment0 = attachment
	velocity.MaxForce = math.max(root.AssemblyMass, 1) * 2500
	velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	velocity.PrimaryTangentAxis = Vector3.new(1, 0, 0)
	velocity.SecondaryTangentAxis = Vector3.new(0, 0, 1)
	velocity.PlaneVelocity = Vector2.new(unit.X, unit.Z) * speed
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.Parent = root

	S.dashVel = velocity
	S.dashAtt = attachment
	S.dashTarget = target
	S.dashNeed = need
	S.dashMiss = miss
	S.dashOff = off
	S.dashSrc = src
	S.dashVel0 = run

	-- Distance-gated, not time-gated. `task.delay(DODGE_TIME)` tore the
	-- constraint down on the wall clock, so the last frame contributed whatever
	-- the frame happened to be: at 30 fps the dash lost up to a stud, at 144 fps
	-- it gained one, and a hitch could land it anywhere in between. The gate below
	-- reads the body's own position and trims the final frame's speed so the
	-- total lands on `target` whatever the frame rate was.
	--
	-- The landing is the handback. The constraint forced the whole plane to the
	-- dash velocity, which erased whatever the player's key was doing, so the
	-- held direction is restated here - in the same function that releases the
	-- constraint - instead of waiting for the movement controller to notice on
	-- its own. No key means the dash's own momentum goes, which is the landing
	-- the game gives the action.
	local startPos = root.Position
	local travelled = 0
	local elapsed = 0
	local landed = false

	-- Both of these are written by the per-frame gate and read by `land()`, so
	-- they have to be declared before it. A local declared below a closure is a
	-- global inside it, and the read then reports nil for a dash that stopped
	-- perfectly well - which is the one number this instrumentation exists for.
	local stopWhy = "gone"
	local frames = 0

	local function land()
		if landed then
			return
		end
		landed = true
		dashStop()
		S.dashTravel = travelled
		S.dashStopWhy = stopWhy
		S.dashFrames = frames
		do
			local ring = S.dashTravels or {}
			S.dashTravels = ring
			ring[#ring + 1] = string.format("%.2f/%s", travelled, stopWhy)
			if #ring > 12 then
				table.remove(ring, 1)
			end
		end
		do
			local disp = root.Position - startPos
			S.dashDrift = Vector3.new(disp.X, 0, disp.Z).Magnitude
		end
		if not root.Parent then
			return
		end

		local current = root.AssemblyLinearVelocity
		local md = humanoid.MoveDirection
		local mdFlat = Vector3.new(md.X, 0, md.Z)
		if mdFlat.Magnitude > 0.1 then
			local walk = humanoid.WalkSpeed > 0 and humanoid.WalkSpeed or 22
			local want = mdFlat.Unit
			root.AssemblyLinearVelocity =
				Vector3.new(want.X * walk, math.min(current.Y, 0), want.Z * walk)
			pcall(function()
				humanoid:Move(want, false)
			end)
			S.handbacks = (S.handbacks or 0) + 1
		else
			root.AssemblyLinearVelocity = Vector3.new(0, math.min(current.Y, 0), 0)
		end
	end

	local conn
	conn = RunService.Stepped:Connect(function(_, dt)
		if S.dashVel ~= velocity then
			conn:Disconnect()
			return
		end
		if not root.Parent then
			conn:Disconnect()
			stopWhy = "noparent"
			dashStop()
			return
		end

		frames = frames + 1
		elapsed = elapsed + dt
		local d = root.Position - startPos
		travelled = Vector3.new(d.X, 0, d.Z):Dot(unit)

		-- Flight recorder. A dash that spends its whole life and moves a
		-- centimetre is indistinguishable from a dash that never got a
		-- constraint unless the per-frame facts are kept: is the handle still
		-- ours, is the constraint still parented, what is it asking for, and
		-- how fast does the body actually think it is going.
		do
			local log = S.dashLog
			local flatV = root.AssemblyLinearVelocity
			log[S.dashLogN + 1] = string.format(
				"f=%d t=%.3f tr=%.2f plane=%.1f own=%s parent=%s vel=%.1f anc=%s st=%s hasBall=%s",
				frames, elapsed, travelled,
				velocity.PlaneVelocity.Magnitude,
				tostring(S.dashVel == velocity),
				tostring(velocity.Parent == root),
				Vector3.new(flatV.X, 0, flatV.Z).Magnitude,
				tostring(root.Anchored),
				tostring(humanoid:GetState()):gsub("Enum.HumanoidStateType.", ""),
				tostring(LocalPlayer:GetAttribute("HasBall")))
			S.dashLogN = S.dashLogN + 1
			if S.dashLogN >= 120 then
				S.dashLogN = 0
			end
		end

		local remaining = target - travelled
		if remaining <= 0 then
			stopWhy = "dist"
			conn:Disconnect()
			land()
			return
		end
		if elapsed >= DODGE_MAX_LIFE then
			stopWhy = "life"
			conn:Disconnect()
			land()
			return
		end

		local step = speed * dt
		if step > remaining then
			velocity.PlaneVelocity = Vector2.new(unit.X, unit.Z) * (remaining / math.max(dt, 1e-3))
		end
	end)

	why.fire = (why.fire or 0) + 1
	S.dodgeBy[src or "?"] = (S.dodgeBy[src or "?"] or 0) + 1
	Action:FireServer("Dodge", now, anim)
	ThrowFX.MarkAction(character, "Dodge", now)

	S.lastDodge = now
	S.dodges = S.dodges + 1
	edge("dash")
	S.dodgeUnit = unit
	S.dodgeUntil = now + (GameConfig.DODGE_IFRAMES or 0.26)
	return true
end

-- Evade -----------------------------------------------------------------------
--
-- Single entry point for every branch where catching cannot happen before the
-- ball arrives. The dash is the only thing that actually stops the hit (server
-- i-frames), so it is spent first at dodgeLead; the brake catches whatever the
-- dash cooldown leaves uncovered, and it is free.

local function evade(character, root, dir, now, tti, src, sideAt, miss, off, ball)
	if not S.enabled or not tti then
		return false
	end

	-- Decision recorder. A death row says which lane armed the body but not what
	-- the body did or why it declined, and the last death that mattered was a
	-- ball answered `hit` at 0.128 s with a 2.37 stud miss - inside the catch
	-- radius, inside nothing else - that took a life with no dash and no stamp.
	-- Without the branch name that is indistinguishable from evade never being
	-- called at all.
	local why = S.evadeWhy
	local function note(branch, extra)
		why[branch] = (why[branch] or 0) + 1
		local log = S.evadeLog
		local n = (S.evadeN or 0) + 1
		S.evadeN = n
		log[(n % 80) + 1] = string.format(
			"%.2f src=%s ball=%s tti=%.3f miss=%s off=%s %s",
			now,
			tostring(src),
			tostring(ball and ball.id),
			tti,
			miss and string.format("%.2f", miss) or "-",
			off and "y" or "-",
			extra or ""
		)
	end

	-- Armed on capability, not on a fixed lead. A dash can still clear a ball as
	-- long as the distance it owes, divided by dash speed, fits inside the time
	-- left - `tti >= owed / speed`. The old fixed lead fired too late on a fast
	-- ball: measured live at tca 0.053 on a 140 studs/s throw, where a dash could
	-- cover 3.4 of the 5.3 studs it still owed, and the ball arrived inside the
	-- reach radius. It also fired too early on slow ones, spending a 2.2 s
	-- cooldown on a ball that was not arriving yet.
	local speed = GameConfig.DODGE_SPEED or 64
	local owed = dashOwed(miss, off, root.AssemblyLinearVelocity, speed)
	local lead = math.max(CONFIG.dodgeLead, owed / speed + 0.02)
	local leadTxt = string.format("lead=%.2f owed=%.2f", lead, owed)

	if tti <= lead then
		-- A handout is a ball thrown AT this body to be caught, not a ball being
		-- thrown at it to be dodged. Spending the 2.2 s dash cooldown on one is
		-- spending it on the wrong ball: measured over six runs, `pass`-class
		-- entries burned 8 of 21 dashes, and the same runs lost 3 lives in the
		-- one busy round. A handout still gets the free sidestep below, because
		-- a mislabelled pass that is genuinely inbound must not be ignored.
		--
		-- The test is `kind` and nothing else. `isHandout` also accepts
		-- `passTarget`/`handout`, and those are populated on ordinary attack
		-- entries too: gating on the full predicate dropped attack-class dashes
		-- from 19 to 2 in one batch, and the batch after it lost 12 lives where
		-- the one before lost 3 - the clearest evidence in this file that the
		-- dash is what saves the life. `kind` is the marker ThrowFX sets for a
		-- pass and it is the only one that distinguishes the two populations.
		if ball and ball.kind == "pass" then
			note("dash-handout", leadTxt)
		elseif dodge(character, root, now, dir, src, miss, off) then
			note("dash", leadTxt)
			return true
		else
			note("dash-refused", leadTxt)
		end
	end

	-- The dash is unavailable, either because the server's cooldown is still
	-- running or because this ball is not close enough to spend it on yet. Walk
	-- out of the line for as long as the ball stays inbound.
	--
	-- A step already in flight owns the body until its hold ends. Without this
	-- the 0.10 s re-arm fired two or three times inside one 0.14-0.45 s hold,
	-- restarting the same impulse each time - that is the shove that reads as
	-- "keeps pushing me", and on the path lane it ran for the whole flight.
	if S.sidestepUntil and now < S.sidestepUntil then
		edge("holdBlock")
		-- ...but only for the ball the step was taken for. The hold is a body
		-- lock, not a threat lock: a second ball arriving sooner than this one
		-- used to get nothing at all for the rest of the hold, which is a
		-- quarter of a second of standing still with a live ball inbound.
		if ball and S.sideBall and ball ~= S.sideBall then
			edge("starve")
			note("hold-other", leadTxt)
		else
			note("hold-same", leadTxt)
		end
		return true
	end

	-- Armed on the distance the step owes, not on a fixed lead. At walk speed the
	-- body needs `owed / walk` seconds to clear; `sideAt` used to be the full
	-- 1.0 s horizon on the path lane, which armed the step a whole second out and
	-- then kept re-arming it for the entire approach.
	local walk = 22
	local leadSide = sideAt
		or math.clamp(dashOwed(miss, off, root.AssemblyLinearVelocity, walk) / walk + 0.08, 0.14, 0.5)

	if tti <= leadSide and sidestep(character, root, dir, now, tti, off, ball) then
		note("side", leadTxt .. string.format(" leadSide=%.2f", leadSide))
		return true
	end

	if tti <= CONFIG.jukeLead then
		local ok = juke(character, root, dir, now)
		note(ok and "juke" or "juke-refused", leadTxt)
		return ok
	end

	note("none", leadTxt .. string.format(" leadSide=%.2f", leadSide))
	return false
end

-- Dodge sizing for the decide() lane. `decide()` returns an arrival time, not a
-- miss, so a dash fired from that lane has no geometry of its own and would fall
-- back to a fixed three studs. The physical threat read each tick does know the
-- miss, and it is cached where it is read; this hands it over only when the
-- cached ball is the one being dodged, so a dash never inherits another ball's
-- numbers.
--
-- The physical read runs after the catch block, so on the tick a dash fires the
-- cache describes the previous tick, and only when that read happened to pick
-- this ball. When it did not, the geometry is read again from the same
-- `pathThreat` the physical answer uses - same sample, same capsule radius,
-- same perpendicular. The alternative is a fixed-length dash whose side was
-- chosen by the body's drift, which is how a dash ends up stepping into the
-- line it was meant to leave.
local function dashGeom(state, character, root, now)
	if not state then
		return nil, nil
	end
	if S.lastPhysicalState == state then
		return S.lastPhysicalMiss, S.lastPhysicalOff
	end
	local rec = segSample(state, now, root.Position)
	if not rec then
		return nil, nil
	end
	local vel = root.AssemblyLinearVelocity
	local _, miss, _, _, _, _, off = pathThreat(
		rec,
		now,
		root.Position,
		Vector3.new(vel.X, 0, vel.Z),
		CONFIG.horizon,
		BODY_RADIUS
	)
	return miss, off
end

-- Loop -----------------------------------------------------------------------

-- Anything this close is a contact problem, not a trajectory problem.
local NEAR_RADIUS = 14

-- One line describing the last ball that got inside NEAR_RADIUS. The flags are
-- what decide() gates on, so a death reads as "the ball was there and the gate
-- refused it" or "the ball was never there at all" instead of a guess.
local function nearText(now)
	local n = S.nearNow
	if not n then
		return "none"
	end

	local flags = { n.kind or "?" }
	flags[#flags + 1] = n.canHit and "canHit" or "nocanhit"
	if n.bounce then
		flags[#flags + 1] = "bounce"
	end
	if n.worldBounced then
		flags[#flags + 1] = "world"
	end
	if n.floored then
		flags[#flags + 1] = "floored"
	end
	if n.hold then
		flags[#flags + 1] = "hold"
	end
	if not n.hasSeg then
		flags[#flags + 1] = "noseg"
	end

	return string.format(
		"%s@%.2fd=%.1f tti=%s [%s]",
		n.name,
		now - (n.at or now),
		n.dist or -1,
		n.tti and string.format("%.3f", n.tti) or "-",
		table.concat(flags, ",")
	)
end

-- Frame budget ----------------------------------------------------------------
--
-- Two numbers decide whether an answer can be late for reasons that have nothing
-- to do with the ball: the frame delta, which is the game's own hitch, and this
-- script's per-tick cost, which is ours. Both are kept as short rings so a report
-- can say "our tick costs 0.4 ms at p99 while the frame hitches to 90 ms" instead
-- of leaving it to a story. Nothing here changes behaviour; it is the measurement
-- the correctness argument rests on.
local FRAME_RING = 600

local function ringPush(ring, key, value)
	local entry = ring[key]
	if not entry then
		entry = { n = 0, head = 1, values = {} }
		ring[key] = entry
	end
	entry.values[entry.head] = value
	entry.head = (entry.head % FRAME_RING) + 1
	entry.n = math.min(entry.n + 1, FRAME_RING)
end

local function ringStats(entry)
	if not entry or entry.n == 0 then
		return nil
	end
	local sorted = table.create(entry.n)
	for i = 1, entry.n do
		sorted[i] = entry.values[i]
	end
	table.sort(sorted)
	local function at(frac)
		local i = math.clamp(math.floor(#sorted * frac + 0.5), 1, #sorted)
		return sorted[i]
	end
	return {
		n = #sorted,
		p50 = at(0.50),
		p95 = at(0.95),
		p99 = at(0.99),
		max = sorted[#sorted],
	}
end

S.frameStats = function()
	local frames = ringStats(S.frameRing and S.frameRing.frame)
	local steps = ringStats(S.frameRing and S.frameRing.step)
	return {
		frames = frames,
		step = steps,
		spikes = S.frameSpikes or 0,
		ticks = getgenv().__acTicks or 0,
		note = "frames=game frame delta, step=this script's per-tick cost",
	}
end

local function noteFrame(dt)
	if type(dt) ~= "number" or dt <= 0 or dt > 5 then
		return
	end
	S.frameRing = S.frameRing or {}
	ringPush(S.frameRing, "frame", dt)
	if dt >= 0.05 then
		S.frameSpikes = (S.frameSpikes or 0) + 1
	end
end

local function noteStepCost(cost)
	if type(cost) ~= "number" then
		return
	end
	S.frameRing = S.frameRing or {}
	ringPush(S.frameRing, "step", cost)
end

local function step()
	-- One decision pass per tickInterval, whichever sampler gets here first. The
	-- predictor walks every candidate segment, so running it twice a frame at
	-- 120 fps buys nothing but CPU the network thread has to compete with.
	local clock = os.clock()
	if (clock - S.lastTick) < CONFIG.tickInterval then
		return
	end
	S.lastTick = clock

	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	if not (character and root and humanoid and humanoid.Health > 0) then
		paint("AUTO CATCH — no character", false)
		return
	end

	-- Assist movement authority. Two controllers want the body: this assist's
	-- sidestep and the auto-play agent's circling. `Humanoid:Move` is one slot, so
	-- whoever writes last wins - and the agent writes from its own 20 Hz loop. A
	-- sidestep issued once and then overwritten 50 ms later moves for one frame in
	-- three, which is not enough lateral travel to leave a 2.4 stud catch radius
	-- once the hit test's own velocity lead is subtracted. While a sidestep is
	-- live this holds the direction every tick; the agent yields below.
	local sideDir = S.sideDir
	if S.sidestepUntil then
		local clock = Workspace:GetServerTimeNow()
		if clock < S.sidestepUntil and sideDir then
			humanoid:Move(sideDir, false)
		else
			-- What the sidestep actually bought, in studs of lateral travel. A
			-- sidestep that competes with another movement writer measures near
			-- zero here however many times it was issued, which is why this is a
			-- distance and not a call count.
			local from = S.sideFrom
			if from and root then
				local flat = root.Position - from
				local dist = Vector3.new(flat.X, 0, flat.Z).Magnitude
				S.sideTravelN = (S.sideTravelN or 0) + 1
				S.sideTravelSum = (S.sideTravelSum or 0) + dist
				S.sideTravelMax = math.max(S.sideTravelMax or 0, dist)
			end
			S.sideFrom = nil
			S.sidestepUntil = nil
			S.sideDir = nil
			stopImpulse("side")
			-- Only stand the body down if the player is not asking it to move.
			-- `Move(zero)` here used to erase a held key for a frame, which reads
			-- as a stutter at exactly the moment the sidestep ended.
			local held = humanoid.MoveDirection
			if Vector3.new(held.X, 0, held.Z).Magnitude <= 0.1 then
				humanoid:Move(Vector3.zero, false)
			end
		end
	end

	local phase = DodgeMatch:GetAttribute("Phase")
	if phase ~= "Playing" then
		paint("AUTO CATCH — " .. tostring(phase), false)
		return
	end

	if not S.enabled then
		paint("AUTO CATCH — off (" .. tostring(CONFIG.toggleKey.Name) .. ")", false)
		return
	end

	local now = Workspace:GetServerTimeNow()
	local myTeam = character:GetAttribute("Team") or LocalPlayer:GetAttribute("Team")
	local body = bodyCache[character]
	if not body then
		body = Ballistics.Body(character)
		bodyCache[character] = body
	end
	-- The exact volume the hit test uses, refreshed every tick. The dodge audit
	-- runs the game's own BodyHit against it rather than a hand-rolled distance,
	-- because the volume is an anisotropic capsule and a horizontal clearance
	-- says nothing about whether a ball at head height went through it.
	S.lastBody = body

	-- The replicated ball state for this tick, read once. The physical tracker
	-- needs it now rather than below: `state.lag` is how far behind the drawn
	-- part is, and that number belongs on the sample the tracker stores.
	local live = ThrowFX.Live()

	-- Physical ball track. Runs before any predictor so every one of them reads a
	-- path sampled on this tick. It is the only input that survives a ball leaving
	-- Live(), a bounce, or a pool round trip.
	trackBalls(now, live)

	-- The palm is reconciled against the server's HasBall every tick.
	sweepThrown(character, now)
	reconcileThrow(character, now)
	watchPalm(character, now)

	-- Shared tick counter. Every live copy of this script bumps the same global,
	-- so its rate proves how many copies are actually running: one instance at a
	-- 12 ms tick reads ~83/s, a stacked duplicate reads ~166/s.
	getgenv().__acTicks = (getgenv().__acTicks or 0) + 1

	-- Eliminated: the only ball that matters is a teammate's pass, and dodging one
	-- costs the ride back onto the field. Drop passes from the threat set instead
	-- of moving out from under them.
	local out = isEliminated()

	-- While eliminated, a teammate's pass is the route back onto the field, not a
	-- threat. Live() knows which parts are passes this tick; the physical track
	-- does not, so the exemption is built here and handed to it.
	local exempt
	if out then
		exempt = {}
		for _, state in pairs(live) do
			if state.part and (isHandout(state, character) or isFriendThrow(state, myTeam)) then
				exempt[state.part] = true
			end
		end
	end

	-- Near-ball record ---------------------------------------------------------
	-- Everything the predictor can reason about lives on `state.seg`. A ball with
	-- no segment - unarmed this tick, or already dropped by ThrowFX while still
	-- in the air - is invisible to decide() and to the point-blank net under it.
	-- That is exactly the shape of a close-range hit, so the nearest ball's own
	-- numbers are kept every tick and read back when a life drops.
	local nearBall, nearDist, nearTti = nil, math.huge, nil
	local present = setmetatable({}, { __mode = "k" })

	-- Part to live state. The catch judge is stated over a ball, so the body veto
	-- has to be too: the physical track knows the part that is arriving, and this
	-- map is how that part is asked whether the catch could have taken it.
	local stateOfPart = setmetatable({}, { __mode = "k" })

	if type(live) == "table" then
		for _, state in pairs(live) do
			local kind = state.kind or "?"
			S.kinds[kind] = (S.kinds[kind] or 0) + 1
			present[state] = true
			if state.part then
				stateOfPart[state.part] = state
			end

			local seg = state.seg
			if seg then
				local okPos, ballPos = pcall(Shared.PosAt, seg, math.max(now, seg.t0) - seg.t0)
				if okPos and typeof(ballPos) == "Vector3" then
					local dist = (ballPos - root.Position).Magnitude
					if dist < nearDist then
						nearBall, nearDist = state, dist
					end
					if dist <= NEAR_RADIUS then
						local okTti, t = pcall(
							timeToHit,
							state,
							character,
							root,
							body,
							now,
							CONFIG.horizon,
							CATCH_RADIUS,
							nil
						)
						nearTti = (okTti and t) or nil
					end
				end
			end
		end
	end

	-- The ball watched last tick is gone from Live() while it was already inside
	-- the near radius. It has not gone anywhere; ThrowFX has stopped predicting
	-- it. Counting that is how "never saw the ball" is separated from "saw it and
	-- every answer was gated".
	if S.watchBall and not present[S.watchBall] and S.watchInfo then
		S.lostAt = now
		S.lostInfo = S.watchInfo
		S.lostCount = (S.lostCount or 0) + 1
		S.watchBall, S.watchInfo = nil, nil
	end

	if nearBall and nearDist <= NEAR_RADIUS then
		S.nearNow = {
			name = nearBall.part and nearBall.part.Name or "?",
			dist = nearDist,
			tti = nearTti,
			at = now,
			kind = nearBall.kind,
			canHit = nearBall.canHit,
			bounce = nearBall.bounce,
			hold = nearBall.hold,
			worldBounced = nearBall.worldBounced,
			floored = nearBall.floored,
			hasSeg = nearBall.seg ~= nil,
		}
		S.watchBall, S.watchInfo = nearBall, S.nearNow
		S.nearPart = nearBall.part
	end

	if out and type(live) == "table" then
		tallyHandouts(live, character, myTeam)
	end

	local best, tti, dir, count = decide(live, character, root, body, now, myTeam, nil, out)

	-- Which population the answer came from. Counted on the tick decide() named a
	-- ball, not on the tick a ball existed, so the two classes are compared on the
	-- same question: did the predictor pick this one.
	if tti then
		tallyClass(classOf(best), "seen")
		S.classLast[classOf(best)] = now
	end

	-- The old contact press lived here: a "decide() missed it but a fast ball is
	-- inside reach" branch. It never fired once in 25 623 frames, because the two
	-- conditions cannot coincide - a ball close enough to be contact still carries
	-- a segment, and any segment predicting a hit is already returned by decide().
	-- The raw closest-approach net below covers the real gap (balls no predictor
	-- will answer for), so the branch is gone rather than lying in the counters.

	-- The physical threat is read every tick, before the gate. It is the body's
	-- input, and it is also the only number that proves the ball was seen at all:
	-- reading it inside the gate would make "the catch already had it" and "the
	-- ball was never detected" report the same way, and those are different faults.
	--
	-- Read here, above the contact clock, not after it. The catch schedule used to
	-- be driven only by decide()'s answer while the body lane read this one, so a
	-- ball that only the segment lane could see produced exactly the sequence the
	-- flight recorder captured on a lost life: `hit@seg d=3.6 tca=0.024 miss=1.93`
	-- three ticks running, and a death row reading `ball=nil tti=-`. One predictor
	-- answered, the other never heard it, and the press schedule listens to the
	-- second one. Both are now the same clock.
	local phTti, phDir, phMiss, phPart, phState, phOff = physicalThreat(character, root, now, CONFIG.horizon, exempt, live)
	S.lastPhysicalTti = phTti
	S.lastPhysicalMiss = phMiss
	S.lastPhysicalOff = phOff
	S.lastPhysicalState = phState

	if phTti then
		edge("seen")
		local keyBall = phState or phPart
		if keyBall ~= S.edgeBall then
			S.edgeBall = keyBall
			edge("ball")
		end
		if not tti then
			S.pathSchedule = (S.pathSchedule or 0) + 1
		end
	end

	-- Raw fallback. Anything the segment predictor refused to answer for - a pass,
	-- a ball that has already come off the world, a segment ThrowFX stopped
	-- advancing - still lands, and the last fraction of a second is a straight
	-- line. Computed before the history so a death snapshot shows it, and spent
	-- after the catch decision so it never competes with a catchable ball.
	local rawTti, rawDir = nil, nil
	if not tti and not phTti then
		rawTti, rawDir = rawThreat(live, character, root, now)
		if rawTti and rawTti <= CONFIG.dodgeLead then
			S.threatUntil = now + CONFIG.tail
		end
	end

	S.ballCount = count
	S.frames = S.frames + 1

	-- Which side of the movement edge this tick is on. Read once, here, so every
	-- decision made below is bucketed against the input state that produced it.
	do
		local md = humanoid.MoveDirection
		S.heldInput = Vector3.new(md.X, 0, md.Z).Magnitude > 0.1
		edge("tick")
	end

	-- Per-frame threat history. Sampled at quarter rate so forty rows hold the
	-- ~2.5 s a hit is actually decided in, and written as text so a snapshot can
	-- be carried out of the game without a serialiser.
	S.histClock = S.histClock + 1
	if S.histClock % 4 == 0 then
		local hist = S.hist
		if #hist >= 40 then
			table.remove(hist, 1)
		end
		local catchReady = readyAt(character, "CatchReadyAt")
		local dashReady = readyAt(character, "DashReadyAt")

		-- Whether the predictor had a usable record for the ball the game calls
		-- nearest, and what that record answered. Without this the history shows a
		-- ball 1.2 studs away and a body that did nothing, with no way to tell
		-- "never sampled" from "sampled and refused".
		local nearKey = nearBall and (nearBall.part or nearBall) or nil
		local nearRec = nearKey and segPath[nearKey] or nil
		local nearRecText = "-"
		if nearBall then
			if not nearRec then
				nearRecText = "rec=none"
			else
				local lv = root.AssemblyLinearVelocity
				local _, _, _, nr = pathThreat(
					nearRec,
					now,
					root.Position,
					Vector3.new(lv.X, 0, lv.Z),
					CONFIG.horizon,
					CATCH_RADIUS
				)
				nearRecText = "rec=" .. tostring(nr)
			end
		end

		hist[#hist + 1] = string.format(
			"%.2f %s d=%.1f tti=%s %s%s%s%s%s cr=%s dr=%s has=%s ball=%s raw=%s %s",
			now % 1000,
			nearBall and (nearBall.part and nearBall.part.Name or "?") or "-",
			nearBall and nearDist or -1,
			nearTti and string.format("%.3f", nearTti) or "-",
			nearBall and tostring(nearBall.kind) or "-",
			nearBall and nearBall.canHit and " canhit" or " nocanhit",
			nearBall and nearBall.bounce and " bounce" or "",
			nearBall and nearBall.hold and " hold" or "",
			nearBall and nearBall.worldBounced and " world" or "",
			catchReady and string.format("%.2f", catchReady - now) or "-",
			dashReady and string.format("%.2f", dashReady - now) or "-",
			tostring(LocalPlayer:GetAttribute("HasBall")),
			best and (best.part and best.part.Name or "?") or "-",
			rawTti and string.format("%.3f", rawTti) or "-",
			nearRecText
		)
	end

	-- Contact clock. ThrowFX drops a ball from Live() the instant it resolves, so
	-- the last few frames before impact frequently have no segment left to
	-- predict from — and that gap is exactly where the catch is decided. Holding
	-- the contact time keeps the press schedule running through it.
	--
	-- The segment answer and the physical answer are two views of the same ball,
	-- and only one of them used to reach this clock. `decide()` runs the segment
	-- predictor over Live(); `physicalThreat` runs the part tracker and the
	-- segment lane under it, and on a real lost life the second one answered
	-- (`hit@seg d=3.6 tca=0.024 miss=1.93`, three ticks in a row) while the death
	-- row read `ball=nil tti=-` and no press was ever scheduled. Whichever
	-- answers soonest is the ball that is about to arrive, so the clock takes the
	-- sooner of the two and both lanes feed one schedule.
	local clockTti, clockBall, clockDir = tti, best, dir
	if phTti and (not clockTti or phTti < clockTti) then
		clockTti = phTti
		clockBall = phState or phPart
		clockDir = phDir or dir
	end

	if clockTti then
		S.contactAt = now + clockTti
		S.contactBall = clockBall
	elseif not (S.contactAt and now <= S.contactAt + 0.06) then
		S.contactAt = nil
		S.contactBall = nil
	end

	local effTti = clockTti
	if not effTti and S.contactAt then
		effTti = S.contactAt - now
	end

	-- The bearing the clock is running on. `judgePress` and the facing turn read
	-- this one, and a physical-lane answer carries its own: without it the press
	-- is scheduled for a ball the body is not looking at, which the judge refuses
	-- on the cone alone.
	if not dir and clockDir then
		dir = clockDir
	end

	-- The cone is judged against this ball's own approach. A direction left over
	-- from the previous ball is worse than no direction at all: it can read as
	-- "facing away" and spend a dash on a catch that was available.
	local key = best or S.contactBall
	local effDir = dir
	if not effDir and S.lastDirBall == key then
		effDir = S.lastDir
	end

	-- Arming horizon. A stamp is only worth sending if it is still inside the
	-- judge window when the ball is judged, so the schedule opens a full window
	-- before contact rather than at a shorter lead. The gap this closes is the
	-- point-blank one: a ball first seen inside the old lead, or one that arrives
	-- sooner than the prediction said, had no stamp armed at all and the only
	-- answer left was a dash on a 2.2 s cooldown. The refresh below keeps the
	-- newest stamp young; the early arm is insurance, and insurance is free
	-- because a refused press does not arm CatchReadyAt.
	local window = catchWindow(character)
	local armHorizon = math.max(CONFIG.pressLead, window - CONFIG.pressBias)

	if effTti then
		S.lastTti = effTti
		if tti then
			S.lastThreatAt = now
			S.lastThreatBall = best
			S.lastThreatTti = tti
		end
		if dir then
			S.lastDir = dir
			S.lastDirBall = best or S.contactBall
		end

		if tti and tti <= CONFIG.faceHorizon then
			S.faceUntil = now + CONFIG.faceHold
			if CONFIG.autoFace and dir then
				rotateTo(root, dir)
			end
		end

		if effTti <= math.max(armHorizon, CONFIG.dodgeLead) then
			S.threatUntil = now + CONFIG.tail
		end
	end

	-- Disable AutoRotate only while a hit is predicted, so the movement controller
	-- cannot spin the character away from the ball before the turn replicates.
	if now <= S.faceUntil then
		if humanoid.AutoRotate then
			humanoid.AutoRotate = false
		end
	elseif not humanoid.AutoRotate then
		humanoid.AutoRotate = true
	end

	-- Raw fallback. Anything the segment predictor refused to answer for - a pass,
	-- a ball that has already come off the world, a segment ThrowFX stopped
	-- advancing - still lands, and the last fraction of a second is a straight
	-- line. This runs only when no catchable threat was predicted, so it never
	-- competes with the catch.
	local pressable, reason = canPress(character, now)
	local pressing = now <= S.threatUntil
	S.lastReason = reason
	edge("cap_" .. tostring(reason))

	-- Contact audit. One row per ball, written the first tick the contact clock
	-- reaches zero: would the judge have accepted the catch on the ball that just
	-- arrived? Read here, where `S.contactAt` and `S.pressStamp` are both
	-- authoritative. The history ring reads a decaying copy of the contact clock,
	-- so it reports a gap on every frame of a ball it never actually saw arrive;
	-- this cannot, and it fires once per ball instead of once per tick.
	--
	-- The answer is `catchCovers` - the same predicate the fallback uses to decide
	-- whether to spend a dash - so the audit can never disagree with the decision
	-- it is auditing. `covered` means the catch should have landed; `late` means a
	-- stamp existed but the clock had moved past it; `nostamp` means no press at
	-- all, which is the hands or the round, not the schedule.
	local auditBall = best or S.contactBall
	if effTti and effTti <= 0 and auditBall and S.contactLogged ~= auditBall then
		S.contactLogged = auditBall
		local catchReadyNow = readyAt(character, "CatchReadyAt")
		local covered = catchCovers(
			S.pressStamp,
			S.contactAt,
			window,
			catchReadyNow,
			S.refusedBall == auditBall
		)
		-- `late` has to mean a press that missed the band, not a stamp left lying
		-- around from a previous ball. The stamp is never cleared, so a naive
		-- "stamp exists" test labels a ball that was never pressed for as late by
		-- however long the round has been running - measured at up to 14.7 s. That
		-- reads as a schedule a few frames behind when the truth is no press at
		-- all, which is a different fault with a different repair. Anything older
		-- than a second past the window is no press.
		local stampAge = (S.contactAt and S.pressStamp) and (S.contactAt - S.pressStamp) or nil
		local verdict = contactVerdict(covered, stampAge, window)

		-- The same verdict, split by who threw the ball. A round where `covered` is
		-- high for bots and `nostamp` is high for players is a round where the
		-- player class is arriving before the schedule can arm it, which is a
		-- different fault from the schedule refusing it.
		tallyClass(classOf(auditBall), "contact")
		tallyClass(classOf(auditBall), verdict)

		-- How late is late. `late` on every contact is a schedule that arrives
		-- after the ball, and the size of the gap decides which repair is right:
		-- tens of milliseconds is a refresh that fires one frame too early,
		-- hundreds is a press aimed at a different ball. Recorded per class
		-- because the whole question is whether one population is systematically
		-- closer to the edge than the other.
		if S.contactAt and S.pressStamp then
			local age = S.contactAt - S.pressStamp
			local kind = classOf(auditBall)
			local row = S.contactAge[kind]
			if not row then
				row = { n = 0, sum = 0, min = math.huge, max = -math.huge, late = 0, ancient = 0 }
				S.contactAge[kind] = row
			end
			row.n = row.n + 1
			row.sum = row.sum + age
			row.min = math.min(row.min, age)
			row.max = math.max(row.max, age)
			if age > window then
				row.late = row.late + 1
			end
			if age > window + 1.0 then
				row.ancient = row.ancient + 1
			end
		end

		-- Arrival race row. Read entirely from state that is authoritative at
		-- this instant - the stamp, the two server gates, and the dash window -
		-- so a death can be resolved against it instead of guessed at.
		local raceFacts = {
			tti = effTti,
			covers = covered,
			stamp = S.pressStamp ~= nil,
			readyIn = catchReadyNow and (catchReadyNow - now) or nil,
			hands = LocalPlayer:GetAttribute("HasBall") == true,
			dashActive = now <= (S.dodgeUntil or 0),
			dashSpent = (now - (S.lastDodge or -math.huge)) < (GameConfig.DODGE_COOLDOWN or 2.2),
		}
		local race = raceVerdict(raceFacts)
		S.raceTally[race] = (S.raceTally[race] or 0) + 1
		S.raceLast = { t = now, verdict = race, ball = auditBall, tti = effTti }
		S.race[S.raceHead] = {
			t = now,
			verdict = race,
			name = auditBall.part and auditBall.part.Name or "?",
			tti = effTti,
			pressAge = S.pressStamp and (now - S.pressStamp) or nil,
			readyIn = catchReadyNow and (catchReadyNow - now) or nil,
			dashAge = S.lastDodge and (now - S.lastDodge) or nil,
		}
		S.raceHead = (S.raceHead % S.raceMax) + 1

		if covered then
			S.contactOk = (S.contactOk or 0) + 1
		elseif S.pressStamp then
			S.contactBad = (S.contactBad or 0) + 1
		else
			S.contactNoStamp = (S.contactNoStamp or 0) + 1
		end

		local log = S.contactLog
		log[#log + 1] = string.format(
			"%s age=%s pressable=%s reason=%s tti=%s",
			verdict,
			S.contactAt and S.pressStamp and string.format("%.3f", S.contactAt - S.pressStamp) or "-",
			tostring(pressable),
			tostring(reason),
			string.format("%.3f", effTti)
		)
		if #log > 32 then
			table.remove(log, 1)
		end
	end

	-- Raw contacts. The predictor had no segment for this ball, so the schedule
	-- could not arm it and the body is the only answer. Counted separately: a
	-- point-blank hit that came in without a segment must read as exactly that in
	-- the log, not hide behind the segment audit above.
	if rawTti and rawTti <= 0 then
		if not S.rawContact then
			S.rawContact = true
			S.rawContacts = (S.rawContacts or 0) + 1
			local log = S.contactLog
			log[#log + 1] = string.format(
				"raw tti=%.3f pressable=%s reason=%s",
				rawTti,
				tostring(pressable),
				tostring(reason)
			)
			if #log > 32 then
				table.remove(log, 1)
			end
		end
	elseif not rawTti then
		S.rawContact = false
	end

	-- Death log. Lives dropping is not the same question as a hit landing, and
	-- treating them as one is why every recorded "death" in this session read
	-- `taken=+0 outs=+0` with no ball inbound: the game shifts `Lives` on round
	-- state (prison, elimination, round start) as well as on damage. Measured at
	-- the end of a batch of three life drops: `HitsTaken=1`, `HitImpactUndone=1`,
	-- `MatchOuts=2` - two hits total for three drops, so at least one drop was a
	-- round shift. This comment used to claim the opposite.
	--
	-- There is also no `HitNotSeen` attribute on this game's player - read on a
	-- live client, the only hit counters that exist are `HitsTaken`,
	-- `HitImpactUndone` and `HitThrows`. The `unseen=+0` column was therefore
	-- reading a missing attribute on every row and always printing zero, which
	-- made "the server resolved a hit we never drew" look disproven when it had
	-- never been measured at all.
	--
	-- So: `taken` (HitsTaken delta) is the only column that means damage. A drop
	-- with no delta is tagged `shift` and is not counted as a hit.
	local lives = tonumber(LocalPlayer:GetAttribute("Lives"))
	local hitsTaken = tonumber(LocalPlayer:GetAttribute("HitsTaken"))
	-- Prime the deltas on the first tick that has a value. `HitsTaken` is a
	-- persistent player attribute - it read 1 on a freshly joined server, before
	-- this client had been hit once - so a delta taken against a nil snapshot is
	-- zero, and the load's first real hit is tagged `shift`. That is the whole
	-- reason every row in this session read `taken=+0`.
	if lives and hitsTaken and S.lastHitsTaken == nil then
		S.lastHitsTaken = hitsTaken
		S.lastOuts = tonumber(LocalPlayer:GetAttribute("MatchOuts"))
	end
	if lives and S.lastLives and lives < S.lastLives then
		local log = S.deathLog
		if #log >= 12 then
			table.remove(log, 1)
		end
		local dTaken = (hitsTaken or 0) - (S.lastHitsTaken or hitsTaken or 0)
		S.lastHitsTaken = hitsTaken
		local outs = tonumber(LocalPlayer:GetAttribute("MatchOuts"))
		local dOuts = (outs or 0) - (S.lastOuts or outs or 0)
		S.lastOuts = outs
		S.lifeDrops = (S.lifeDrops or 0) + 1
		local wasHit = dTaken > 0
		-- The game's own death event outranks the delta. `HitsTaken` does not move
		-- on every heartbreak - a bot's ball took a life with `taken=+0` while
		-- `how=Hit by=Bot kitty_girl` sat on the same row - so a row tagged
		-- `shift` was hiding real hits as well as round shifts.
		local howText = tostring(S.deathHow or "")
		if not wasHit and S.hbAt and (now - S.hbAt) <= 0.5 and howText:lower():find("hit", 1, true) then
			wasHit = true
		end
		if wasHit then
			S.heartbreaks = (S.heartbreaks or 0) + 1
		end
		local dashReady = readyAt(character, "DashReadyAt")
		local catchReady = readyAt(character, "CatchReadyAt")

		-- What the tracker knew about the ball the game called nearest, asked at
		-- the instant the life left. Without this the log can only say the ball
		-- was 4.7 studs away in Live(); it cannot say whether the physical path
		-- had an answer for it or had already been rejected.
		local trackNote = "untracked"
		local arcLast = S.arcLast and S.arcLast[S.nearPart]
		if arcLast and (now - (arcLast.at or 0)) <= 0.15 then
			trackNote = string.format(
				"%s why=%s miss=%s tti=%s age=%.3f lane=arc",
				S.nearNow and S.nearNow.name or S.nearPart.Name,
				tostring(arcLast.reason),
				arcLast.miss and string.format("%.2f", arcLast.miss) or "-",
				arcLast.tti and string.format("%.3f", arcLast.tti) or "-",
				now - (arcLast.at or now)
			)
		elseif S.nearPart and root then
			local rec = ballPath[S.nearPart]
			if rec then
				local vel = root.AssemblyLinearVelocity
				local tti2, miss2, _, reason2, _, posNow2 =
					pathThreat(rec, now, root.Position, Vector3.new(vel.X, 0, vel.Z), CONFIG.horizon, CATCH_RADIUS)
				-- STALE marks a record the tracker stopped updating while the ball
				-- was still reported near. Without it a `miss` from a 0.6 s old
				-- sample reads exactly like a live one.
				local age2 = now - (rec.t or now)
				trackNote = string.format(
					"%s why=%s%s miss=%s tti=%s age=%.3f lag=%.3f d=%.1f",
					S.nearNow and S.nearNow.name or S.nearPart.Name,
					tostring(reason2),
					age2 > 0.35 and "/STALE" or "",
					miss2 and string.format("%.2f", miss2) or "-",
					tti2 and string.format("%.3f", tti2) or "-",
					age2,
					rec.lag or 0,
					((posNow2 or rec.pos) - root.Position).Magnitude
				)
			end
		end

		-- Resolve this life against the arrival ring. An arrival within 0.45 s of
		-- the drop is the ball that took the life; the verdict on it says which
		-- answer lost the race.
		local raceNote = "-"
		local hit, hitAge = raceResolve(S.race, S.raceHead, S.raceMax, now, 0.45)
		if hit then
			raceNote = string.format("%s@%.3f", hit.verdict, hitAge)
			S.raceHit[hit.verdict] = (S.raceHit[hit.verdict] or 0) + 1
		end

		-- Which population took the life. The death row already answers "was there
		-- an answer"; this answers "for whom", which is the whole question when the
		-- same body handles both classes differently.
		local lostKind = classOf(S.contactBall or S.lastThreatBall)
		tallyClass(lostKind, "loss")
		S.lostClass = lostKind

		log[#log + 1] = string.format(
			"%s %d->%d class=%s reason=%s race=%s has=%s ball=%s tti=%s saw=%s@%s catchIn=%s dashIn=%s refused=%d soft=%s near=%s lost=%s track=%s",
			wasHit and "HIT " or "shift",
			S.lastLives,
			lives,
			lostKind,
			tostring(reason),
			raceNote,
			tostring(LocalPlayer:GetAttribute("HasBall")),
			tostring(S.contactBall),
			effTti and string.format("%.3f", effTti) or "-",
			tostring(S.lastThreatBall),
			S.lastThreatAt and string.format("%.2f", now - S.lastThreatAt) or "never",
			catchReady and string.format("%.2f", catchReady - now) or "-",
			dashReady and string.format("%.2f", dashReady - now) or "-",
			S.pressWhy.veto or 0,
			S.lastPhysicalTti and string.format("%.3f", S.lastPhysicalTti) or "-",
			nearText(now),
			S.lostInfo and string.format("%s@%.2f", S.lostInfo.name, now - (S.lostAt or now)) or "none",
			trackNote
		)
		log[#log] = log[#log] .. string.format(
			" how=%s by=%s@%.2f taken=%+d outs=%+d throwAgo=%s",
			tostring(S.deathHow or "-"),
			tostring(S.deathBy or "-"),
			S.hbAt and (now - S.hbAt) or -1,
			dTaken,
			dOuts,
			S.lastThrow and string.format("%.2f", now - S.lastThrow) or "never"
		)

		-- The ball the game says landed, and what this client knew about it. Only
		-- when the Impact event is recent enough to belong to this drop.
		if S.impactInfo and S.lastImpact and (now - (S.lastImpact.at or 0)) <= 1.5 then
			log[#log] = log[#log] .. " imp[" .. S.impactInfo .. "]"
			if S.impactNear and S.impactNear ~= "" then
				log[#log] = log[#log] .. " airborne[" .. S.impactNear .. "]"
			end
		end

		-- The flight recorder's last second, verbatim. A death is a question
		-- about what was visible, and this is the only copy of it.
		local wide = S.pathWide
		for i = math.max(1, #wide - 9), #wide do
			log[#log + 1] = "  w " .. wide[i]
		end
		if #log > 40 then
			table.move(log, #log - 39, #log, 1, log)
		end
	end
	if lives then
		S.lastLives = lives
	end

	-- Decision trace. A hit is only debuggable if the frames before it are still
	-- readable, so the last two seconds of decisions are kept in a ring buffer.
	-- The hint comes from `why`, and the ball identity is what makes a press map
	-- back to the ball that actually landed.
	local trace = S.trace
	trace[S.traceHead] = {
		t = now,
		reason = reason,
		pressing = pressing,
		tti = effTti,
		ball = best or S.contactBall,
		presses = S.presses,
		hasBall = LocalPlayer:GetAttribute("HasBall") == true,
		dashReady = readyAt(character, "DashReadyAt"),
		catchReady = readyAt(character, "CatchReadyAt"),
	}
	S.traceHead = (S.traceHead % S.traceMax) + 1

	-- Silent aim plumbing. The shot itself is redirected on the Throw remote, so
	-- all this does is keep the game's own target mirror and diagnostics current.
	if CONFIG.silentAim then
		local holding = LocalPlayer:GetAttribute("HasBall") == true
		if holding or S.aimHeld then
			local target = nearestEnemy(character, myTeam, root.Position)
			S.lockTarget = target
			pointLockOn(target)
		end
	end

	-- Optional camera lock, off by default. Silent aim needs none of this; it is
	-- only here for the old hold-to-look behaviour.
	if CONFIG.autoAim and S.aimHeld then
		local target = nearestEnemy(character, myTeam, root.Position)
		local targetRoot = target and target:FindFirstChild("HumanoidRootPart")
		local cam = Workspace.CurrentCamera

		if targetRoot and cam then
			local aimPos = CONFIG.perfectThrow and perfectAim(character, root, target, targetRoot)
				or targetRoot.Position
			S.aimLast = aimPos
			S.aimTarget = target
			cam.CFrame = CFrame.lookAt(cam.CFrame.Position, aimPos)
		else
			S.aimTarget = nil
		end
	end

	if pressing then
		S.threatFrames = S.threatFrames + 1

		if pressable then
			-- A new ball means a new press budget. The decayed contact clock keeps
			-- the same key after the segment disappears, so the budget is not reset
			-- in the last frames of the same ball.
			local key = best or S.contactBall
			if key ~= S.pressBall then
				S.pressBall = key
				S.pressCount = 0
				S.pressStamp = nil
				S.threatBalls = S.threatBalls + 1
			end

			local why = judgePress(character, root, effTti, effDir, now)
			edge("why_" .. tostring(why))

			-- The press schedule is an invariant over the judge window, not a
			-- count: at the instant the ball arrives, the newest stamp must be no
			-- older than CATCH_WINDOW and no newer than the 30 ms tolerance. Both
			-- ends are compared on the predicted contact time, so a ball that
			-- speeds up, bounces, or drops out of Live() cannot strand a stamp
			-- outside the band - the schedule re-derives from the same contact
			-- clock the judge will use.
			--
			-- A ball with no stamp of its own is armed on the frame it becomes
			-- catchable, whatever the refresh cadence says. The cadence exists to
			-- stop the same ball being re-stamped pointlessly, not to make the
			-- first ball after any other press wait out a counter.
			local contactAt = effTti and (now + effTti) or nil
			local cadence = math.max(0.10, math.min(CONFIG.pressInterval, window * 0.35))
			-- A ball this schedule has never armed gets its first stamp whatever the
			-- cadence says. Keyed on the ball, not on the stamp being nil, so a key
			-- that flickers inside the same ball cannot turn every tick into a press.
			local rearm = S.pressedBall ~= key
			local canAttempt, scheduleWhy = scheduleDue(
				contactAt,
				S.pressStamp,
				now,
				window,
				rearm,
				S.lastPress,
				cadence
			)

			-- The server already answered this ball with a refusal. It arrives a
			-- ping after the press, so the ball is normally still in the air when it
			-- lands: stop pressing and become a body instead, because a refused
			-- catch has no second press worth sending.
			if S.refusedBall == key and (now - (S.refusedAt or -99)) < 0.35 then
				S.pressWhy.veto = (S.pressWhy.veto or 0) + 1
			elseif why == "facing" then
				-- Outside the 120 deg catch cone. The server judges the angle on the
				-- replicated root, so turning and pressing in the same frame presses
				-- with a turn it has not seen yet. Turn now, press on the next tick,
				-- and only give up the catch for the dash when contact is too close
				-- for a turn to arrive.
				S.pressWhy[why] = (S.pressWhy[why] or 0) + 1
				if effDir then
					rotateTo(root, effDir)
				end
				if effTti and effTti <= 0.09 then
					tallyClass(classOf(best or S.contactBall), "dash")
					local dMiss, dOff = dashGeom(best, character, root, now)
					S.dashBall = best
					evade(character, root, dir or effDir, now, effTti, "facing", nil, dMiss, dOff, best)
				end
			elseif canAttempt then
				S.pressCount = S.pressCount + 1
				S.pressWhy[why] = (S.pressWhy[why] or 0) + 1
				S.pressedBall = key

				-- What the press was reasoning about. Recorded before the send so the
				-- answer can be matched back to the numbers that produced it.
				local metaBall = best or S.contactBall
				local metaPos = metaBall and metaBall.real
				S.pressMeta = {
					tti = effTti,
					dist = typeof(metaPos) == "Vector3" and (metaPos - root.Position).Magnitude or nil,
					speed = metaBall and metaBall.vSpeed or nil,
					side = (S.sidestepUntil and now <= S.sidestepUntil) or false,
					dot = effDir and facingDot(root, effDir) or nil,
					kind = metaBall and metaBall.kind or nil,
				}
				tallyClass(classOf(metaBall), "press")
				press(character, now)
			elseif scheduleWhy == "cadence" then
				-- The stamp already in flight is inside the judge band. The cadence
				-- only withheld a fresher one, so nothing is spent here: the fallback
				-- below leaves the body alone while that stamp can still catch. This
				-- used to dash, which burned a 2.2 s cooldown on balls the catch had
				-- already answered.
				S.pressWhy.blocked = (S.pressWhy.blocked or 0) + 1
			end
		elseif reason == "holding ball" then
			S.blocked = S.blocked + 1

			-- Hands full is the only state where a catch is impossible by rule. The
			-- throw used to fire on every inbound ball, and the 300 s audit showed
			-- the cost: four of five lost lives were "Caught by <name>" - our own
			-- throw taken by an enemy, which eliminates the thrower. A dash is free
			-- of that risk, so the throw is now spent only when the dash cannot save
			-- us: on cooldown, this is the last answer left.
			--
			-- Not while sidelined. There the ball in hand is the re-entry pickup and
			-- the throw is the player's - see CONFIG.autoReentry.
			--
			-- Whether the dash can save us is a question about *this ball on this
			-- tick*, and it was being answered as a question about the hands. Two
			-- separate faults came out of reading it that way, and together they
			-- turned the last-resort throw into a throw on every acquisition:
			--
			--   1. `dashReady` was trusted raw. The catch path already bounds
			--      CatchReadyAt to `now + 10` for exactly this reason - the server
			--      publishes a far-future timestamp in states where the action is
			--      not allowed at all, and carrying the ball is one of them. Read
			--      unbounded, `dashReady > now` is true for the entire hold, so the
			--      dash reads as unavailable from the frame of the pickup onward.
			--   2. `pressing` is armed by any ball predicted to arrive inside the
			--      *catch* window (0.35 s). That is the schedule's horizon, not a
			--      statement that a hit is imminent, and in a live round it is true
			--      most of the time. The frame a pickup welds the ball to the hand
			--      is one of those ticks: the ball is at the palm, `decide()` has
			--      not yet seen the game mark it held, and the answer is "a ball is
			--      arriving".
			--
			-- The branch was written for one thing: the ball that is about to land
			-- on this body, with no dash left to answer it. So it now tests that,
			-- with the same clock and the same lead the dash itself uses, and it
			-- refuses to name the ball already in the hand as the threat.
			local dashReady = readyAt(character, "DashReadyAt")
			local dashBlocked = dashReady ~= nil and dashReady > now and dashReady < now + 10
			local dashCadence = (now - S.lastDodge) < (GameConfig.DODGE_COOLDOWN or 2.2)
			local canDash = not (dashBlocked or dashCadence)

			local effBall = best or S.contactBall
			local ownBall = effBall == nil
				or effBall.hold == true
				or effBall.thrower == character
			local incoming = effTti ~= nil and effTti > 0 and effTti <= CONFIG.dodgeLead

			if CONFIG.autoThrow
				and not out
				and not canDash
				and incoming
				and not ownBall
				and S.threwFor ~= effBall
			then
				-- One throw per ball. The escape exists to free the hand for the
				-- catch, not to empty the palm on every frame of the same arrival.
				if throwHeld(character, root, now, false, true) then
					S.threwFor = effBall
					S.autoThrows = (S.autoThrows or 0) + 1
					S.autoThrowLast = string.format(
						"tti=%.3f ball=%s dashIn=%s cadence=%s",
						effTti,
						tostring(effBall and effBall.id),
						dashReady and string.format("%.2f", dashReady - now) or "-",
						tostring(dashCadence)
					)
				end
			end

			-- Clearing the palm costs a round trip before CatchReadyAt will even be
			-- consulted, so a ball already inside the dash lead cannot be answered
			-- by a catch. Move instead of standing there holding it. effTti is the
			-- contact clock, so the answer survives the frames where ThrowFX has
			-- already dropped the ball and tti has gone nil.
			local holdTti = tti or effTti
			if holdTti and holdTti <= CONFIG.dodgeLead then
				tallyClass(classOf(best or S.contactBall), "dash")
				local dMiss, dOff = dashGeom(best, character, root, now)
				S.dashBall = best
				evade(character, root, dir or effDir, now, holdTti, "hold", nil, dMiss, dOff, best)
			elseif holdTti then
				-- Inside the hands branch the body only moves once the ball is
				-- inside the throw-lead. Counted so a death in this branch says
				-- whether the ball was early or the body was late.
				S.holdLate = (S.holdLate or 0) + 1
			else
				S.holdNoTti = (S.holdNoTti or 0) + 1
			end
		elseif reason == "cooldown" then
			-- The server refuses a catch for 0.6 s after one lands. Whether this ball
			-- can still be caught is decided once, below, from the stamp and the
			-- CatchReadyAt the server publishes - a dash spent here would be spent on
			-- balls the previous press already catches, which is how the dash budget
			-- ran out in the first place.
			--
			-- This window is where every death in live play happened. A walk-speed
			-- step was tried here and measured, because it is the only answer with no
			-- cooldown of its own: 91 steps in 152 s, then 224 in 228 s, and the death
			-- count went up rather than down (1 per 152 s before, 4 per 380 s after,
			-- with a dash in that batch finishing 0.03 studs *behind* its own axis).
			-- Stepping through the lockout moves the body without regard for where the
			-- next ball is coming from, so it is not an answer - it is a second thing
			-- to be hit by. Counted, not acted on.
			if best ~= S.pressBall then
				S.pressBall = best
				S.unreachable = S.unreachable + 1
			end
			S.coolWindow = (S.coolWindow or 0) + 1
		elseif reason ~= "off" then
			-- Catch is unavailable for a reason other than the hands: dash or brake
			-- so the hit test's own velocity lead overshoots instead of landing.
			local otherTti = tti or effTti
			if otherTti then
				tallyClass(classOf(best or S.contactBall), "dash")
				local dMiss, dOff = dashGeom(best, character, root, now)
				S.dashBall = best
				evade(character, root, dir or effDir, now, otherTti, "other", nil, dMiss, dOff, best)
			end
		end
	end

	-- The body is the answer whenever the catch cannot be. The test is the judge's
	-- own: is the stamp for this ball, measured against the contact time it will be
	-- judged at, still inside the window - and is CatchReadyAt already past by the
	-- time it lands?
	--
	-- Decided by the stamp, not by whether another press could be sent right now.
	-- The old test asked `canPress`, which goes false the moment a previous catch
	-- arms CatchReadyAt - so a ball that already had a valid stamp and would land
	-- was treated as uncatchable and got a dash spent on it. That is where the dash
	-- budget went: 20 catches and 24 dashes in a 300 s round, leaving nothing in
	-- reserve for the balls that genuinely cannot be caught. Only the judge
	-- refusing this ball, or CatchReadyAt outliving it, disqualifies a stamp.
	local catchInFlight = false
	local catchBall = best or S.contactBall
	if effTti then
		local contactAt = now + effTti
		catchInFlight = catchCovers(
			S.pressStamp,
			contactAt,
			window,
			readyAt(character, "CatchReadyAt"),
			S.refusedBall == catchBall
		)
	end

	-- The physical threat was read above, before the contact clock, so the press
	-- schedule and the body lane are fed by the same answer. Nothing to re-read.

	-- Per-ball veto -----------------------------------------------------------------
	-- `catchInFlight` answers "did we press for the ball decide() picked". It does
	-- not answer "is the ball that is actually arriving covered", and treating it
	-- as if it did is the fault this block exists to remove: a press aimed at one
	-- ball stood the body down for every other ball, including ricochets and balls
	-- the game had stopped marking canHit. Those are refused by the catch judge by
	-- construction, so the only answer they can ever have is the body, and it was
	-- being withheld for them.
	--
	-- The veto is now stated over the arriving part: it stands only if the press
	-- would be accepted for THIS ball at ITS contact time.
	local heldForThisBall = false
	if phTti and (phPart or phState) then
		local state = phState or stateOfPart[phPart]
		local catchable = state ~= nil and isCandidate(state, character, out, myTeam, true, false, "catch")

		heldForThisBall = catchInFlight
			and catchCovers(
				S.pressStamp,
				now + phTti,
				window,
				readyAt(character, "CatchReadyAt"),
				S.refusedBall == state,
				catchable
			)
	end

	if not heldForThisBall then
		-- The body answer reads the physical path, not Live(). A ricochet has no
		-- segment that predicts a hit and no velocity history, and a ball already
		-- resolved by the judge has left Live() entirely - both are invisible to
		-- every other predictor on exactly the frames that decide the hit. The
		-- part is never invisible.
		--
		-- Full horizon for the sidestep: the catch has already been ruled out, so
		-- every extra tenth of a second is another 1.6 studs of lateral travel and
		-- the only cost is walking. The arming lead itself is derived inside
		-- `evade` from the distance the step owes, not passed in as a horizon -
		-- passing the horizon armed the step a whole second before the ball.
		--
		-- One case gets a longer lead on purpose: a ball that lands before
		-- CatchReadyAt re-arms. There the judge refuses every press, the dash is
		-- usually still on cooldown from the catch that just landed, and the
		-- sidestep is the only answer left - so it starts walking early instead
		-- of waiting for its own short lead. That is the "lost a life right after
		-- a catch" shape: measured at death with catchIn +0.15..+0.43 and
		-- dashIn +1.3..+1.5, i.e. both actions unavailable and no step taken.
		if phTti then
			S.pathOpen = (S.pathOpen or 0) + 1
			S.dashBall = phState
			local catchBy = readyAt(character, "CatchReadyAt")
			local sideAt = (catchBy and (now + phTti) < catchBy) and 0.40 or nil
			local evaded = evade(character, root, phDir, now, phTti, "path", sideAt, phMiss, phOff, phState)
			if evaded then
				S.pathJukes = (S.pathJukes or 0) + 1
			end
			-- The body answer's own ring. `evadeWhy` says what evade decided but not
			-- whether the arriving ball was ever handed to it: a death at 5 studs
			-- with a perfect 0.126 s `hit` answer and no action is either "evade was
			-- asked and declined" or "this ball was never the one it was asked
			-- about", and the two need different fixes.
			local bl = S.bodyLog
			local bn = (S.bodyN or 0) + 1
			S.bodyN = bn
			bl[(bn % 150) + 1] = string.format(
				"%.2f body ball=%s tti=%.3f miss=%s off=%s evaded=%s sideAt=%s catchIn=%s dashIn=%s has=%s",
				now % 1000,
				tostring(phState and phState.id),
				phTti,
				phMiss and string.format("%.2f", phMiss) or "-",
				phOff and "y" or "-",
				tostring(evaded),
				sideAt and string.format("%.2f", sideAt) or "-",
				catchBy and string.format("%.2f", catchBy - now) or "-",
				readyAt(character, "DashReadyAt") and
					string.format("%.2f", readyAt(character, "DashReadyAt") - now) or "-",
				tostring(LocalPlayer:GetAttribute("HasBall"))
			)
		elseif S.nearNow then
			local bl = S.bodyLog
			local bn = (S.bodyN or 0) + 1
			S.bodyN = bn
			bl[(bn % 150) + 1] = string.format(
				"%.2f body-notti near=%s d=%.1f age=%.3f has=%s",
				now % 1000,
				tostring(S.nearNow.name),
				S.nearNow.dist or -1,
				now - (S.nearNow.at or now),
				tostring(LocalPlayer:GetAttribute("HasBall"))
			)
		end
	elseif phTti then
		S.pathHeld = (S.pathHeld or 0) + 1
		local bl = S.bodyLog
		local bn = (S.bodyN or 0) + 1
		S.bodyN = bn
		bl[(bn % 150) + 1] = string.format(
			"%.2f body-veto ball=%s tti=%.3f miss=%s",
			now % 1000,
			tostring(phState and phState.id),
			phTti,
			phMiss and string.format("%.2f", phMiss) or "-"
		)
	end

	-- Return to the field. While eliminated, a ball in hand is the route back in.
	-- That throw belongs to the player: it needs a chosen target and it has to
	-- leave on a wind-up, not on the frame the pickup welds to the hand. This
	-- block is therefore opt-in (CONFIG.autoReentry, off by default) and stays
	-- out of the way otherwise - the handout filter above keeps the body still
	-- until the teammate's pass actually arrives, so nothing else acts here.
	if out
		and CONFIG.autoThrow
		and CONFIG.autoReentry
		and LocalPlayer:GetAttribute("HasBall") == true
		and (now - S.lastThrow) > 1.5
	then
		throwHeld(character, root, now, true)
	end

	-- Refusal tally. The server writes CatchNote as "why|stamp" whenever a catch is
	-- denied, and that attribute is the ONLY refusal channel: CatchRefused is never
	-- broadcast on FX, so the earlier event-based counter read zero forever. One
	-- round gives an exact count here instead.
	local note = LocalPlayer:GetAttribute("CatchNote")
	if type(note) == "string" and note ~= S.lastNote then
		S.lastNote = note
		local why = note:match("^(.-)|") or note
		S.refusals[why] = (S.refusals[why] or 0) + 1
		S.catchRefusals = S.catchRefusals + 1

		-- The answer belongs to the newest press still pending inside the judge
		-- horizon. Tying it back is what makes the press log readable: an outcome
		-- of "refused" beside tti/dist/speed/dot says which condition produced it.
		local answered = nil
		local bestGap = 1.0
		for _, rec in pairs(S.byStamp) do
			if rec.outcome == "pending" then
				local gap = now - rec.at
				if gap >= 0 and gap < bestGap then
					answered, bestGap = rec, gap
				end
			end
		end

		if answered then
			answered.outcome = "refused"
			answered.refuseWhy = why
			answered.answerAt = os.clock()
		end

		-- A refusal names the ball that was turned down by omission: whatever
		-- pressBall was at that moment. Remembering it turns the refusal into a
		-- dodge on the next frame instead of another wasted press.
		if why == "Refused" then
			S.refusedAt = now
			S.refusedBall = S.pressedBall
		end
	end

	-- Ping sampler. Eight samples a second is enough to see a trend without
	-- adding any traffic of its own.
	local ping = LocalPlayer:GetNetworkPing()
	if ping then
		S.pingSum = S.pingSum + ping
		S.pingN = S.pingN + 1
		if S.pingN >= 8 then
			S.pingAvg = S.pingSum / S.pingN
			S.pingSum = 0
			S.pingN = 0
		end
	end

	local status = if tti then string.format("%.2fs", tti) else "armed"
	if not pressable and pressing then
		status = status .. " (" .. reason .. ")"
	end

	paint("AUTO CATCH — " .. status, pressable)
end

-- Debug surface ---------------------------------------------------------------

S.CONFIG = CONFIG
S.isEngageable = isEngageable
S.isEliminated = isEliminated
S.isHandout = isHandout
S.isFriendThrow = isFriendThrow
S.nearestEnemy = nearestEnemy
S.catchWindow = catchWindow
S._silent = SILENT_HOOK
S._throwFX = ThrowFX
S._shared = Shared
S._perfectAim = perfectAim
S._dodge = dodge
S._evade = evade
S._dashStop = dashStop
S._freeSide = freeSide
S._clearRun = clearRun

S._pressNow = function()
	local character = LocalPlayer.Character
	if character then
		press(character, Workspace:GetServerTimeNow())
	end
end

-- Ring-buffer read-out, oldest first. A hit is read backwards from here: which
-- reason was live, whether a press was already spent on that ball, and whether
-- the server had either gate closed at the time.
S.traceDump = function()
	local rows = {}
	local head = S.traceHead
	for i = 1, S.traceMax do
		local idx = ((head - 1 + i - 1) % S.traceMax) + 1
		local e = S.trace[idx]
		if e then
			rows[#rows + 1] = string.format(
				"%.3f %s press=%s tti=%s hasBall=%s catchReady=%s dashReady=%s",
				e.t,
				tostring(e.reason),
				tostring(e.presses),
				e.tti and string.format("%.3f", e.tti) or "-",
				tostring(e.hasBall),
				e.catchReady and string.format("%.2f", e.catchReady - e.t) or "-",
				e.dashReady and string.format("%.2f", e.dashReady - e.t) or "-"
			)
		end
	end
	return rows
end

S._throwNow = function()
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (character and root) then
		return false
	end
	return throwHeld(character, root, Workspace:GetServerTimeNow())
end

-- Test agent ------------------------------------------------------------------
--
-- Drives the character so a round can be measured without a human at the keys.
-- Movement goes through Humanoid:Move, which is client-owned and replicates the
-- same way stick input does: no synthetic key events, no teleports, no CFrame
-- warps. The agent strafes around the nearest enemy, reverses on a timer, jumps,
-- and throws whenever a ball is in hand, which is exactly the load the catch and
-- throw paths have to survive.

local agent = { running = false, until_ = 0 }

function S.agentStop()
	agent.running = false
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:Move(Vector3.zero, false)
		humanoid.AutoRotate = true
	end
	S.sidestepUntil = nil
	S.sideDir = nil
	return true
end

function S.agentStart(seconds)
	S.agentStop()

	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return false, "no humanoid"
	end

	agent.running = true
	agent.until_ = os.clock() + (seconds or 60)

	task.spawn(function()
		local flip = 1
		local nextFlip = os.clock() + 2
		local nextJump = os.clock() + 1.5
		local nextThrow = os.clock()

		while agent.running and os.clock() < agent.until_ do
			local char = LocalPlayer.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			local hum = char and char:FindFirstChildOfClass("Humanoid")

			if root and hum and hum.Health > 0 then
				local phase = DodgeMatch:GetAttribute("Phase")
				local myTeam = char:GetAttribute("Team") or LocalPlayer:GetAttribute("Team")
				local enemy = nearestEnemy(char, myTeam, root.Position)

				if phase == "Playing" and enemy then
					local eroot = enemy:FindFirstChild("HumanoidRootPart")
					if eroot then
						local toEnemy = eroot.Position - root.Position
						local flat = Vector3.new(toEnemy.X, 0, toEnemy.Z)

						if flat.Magnitude > 0.1 then
							local forward = flat.Unit
							local side = forward:Cross(Vector3.new(0, 1, 0))

							if os.clock() > nextFlip then
								flip = -flip
								nextFlip = os.clock() + 1.5 + math.random() * 2
							end

							-- Circle at a fixed radius, close in, back out: the same
							-- range and angle changes a player makes while dodging.
							local radial = if flat.Magnitude > 34
								then forward
								elseif flat.Magnitude < 18 then -forward
								else Vector3.zero

							local move = (side * flip + radial * 0.6)
							if move.Magnitude > 0.01 then
								-- The assist owns the body while a sidestep or a dash
								-- is live. Two writers on Humanoid:Move means the
								-- assist gets one frame in three; see step()'s hold.
								if not dashLive()
									and not (S.sidestepUntil and Workspace:GetServerTimeNow() < S.sidestepUntil)
								then
									hum:Move(move.Unit, false)
								end
							end
						end
					end
				else
					if not dashLive()
						and not (S.sidestepUntil and Workspace:GetServerTimeNow() < S.sidestepUntil)
					then
						hum:Move(Vector3.zero, false)
					end
				end

				if os.clock() > nextJump then
					hum.Jump = true
					nextJump = os.clock() + 1.2 + math.random() * 2
				end

				if os.clock() > nextThrow and LocalPlayer:GetAttribute("HasBall") == true then
					S._throwNow()
					nextThrow = os.clock() + 1.0
				end
			end

			task.wait(0.05)
		end

		S.agentStop()
	end)

	return true
end

-- What the physical track holds right now, and what the body answer reads off it.
-- Diagnostic: the tracker is the only input that survives a ball leaving Live(),
-- so when a death says "we never saw it" this is where the answer lives.
S.pathDebug = function()
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local now = Workspace:GetServerTimeNow()
	local rows = {}

	for part, rec in pairs(ballPath) do
		rows[#rows + 1] = string.format(
			"%s prev=%s dt=%s pos=%s dist=%s lag=%.3f age=%.3f weld=%s",
			part.Name,
			rec.prev and "yes" or "no",
			rec.dt and string.format("%.3f", rec.dt) or "-",
			rec.pos and string.format("%.1f,%.1f,%.1f", rec.pos.X, rec.pos.Y, rec.pos.Z) or "-",
			root and string.format("%.1f", (rec.pos - root.Position).Magnitude) or "-",
			rec.lag or 0,
			rec.t and (now - rec.t) or -1,
			part:FindFirstChildWhichIsA("Weld") and "yes" or "no"
		)
	end

	local tti, dir, miss, part = nil, nil, nil, nil
	local segRows = {}
	if root then
		local live = ThrowFX.Live()
		tti, dir, miss, part = physicalThreat(character, root, now, CONFIG.horizon, nil, live)
		if type(live) == "table" then
			for _, state in pairs(live) do
				local rec = segPath[state.part or state]
				if rec then
					segRows[#segRows + 1] = string.format(
						"%s kind=%s prev=%s dt=%s dist=%s age=%.3f",
						tostring(state.id),
						tostring(state.kind),
						rec.prev and "yes" or "no",
						rec.dt and string.format("%.3f", rec.dt) or "-",
						rec.pos and string.format("%.1f", (rec.pos - root.Position).Magnitude) or "-",
						rec.t and (now - rec.t) or -1
					)
				end
			end
		end
	end

	return {
		now = now,
		tracked = #rows,
		rows = rows,
		segRows = segRows,
		threat = tti,
		miss = miss,
		part = part and part.Name or nil,
		drop = S.pathDrop,
		why = S.pathWhy,
		whySeg = S.pathWhySeg,
		close = S.pathClose,
		race = S.raceDump(),
		raceTally = S.raceTally,
		raceHit = S.raceHit,
		raceLast = S.raceLast,
	}
end

-- Arrival ring, newest first. A death reads this to name the answer that lost.
S.raceDump = function()
	local now = Workspace:GetServerTimeNow()
	local rows = {}
	for i = 1, S.raceMax do
		local idx = ((S.raceHead - 1 - i) % S.raceMax) + 1
		local e = S.race[idx]
		if e then
			rows[#rows + 1] = string.format(
				"%.3f %s %s tti=%.3f pressAge=%s readyIn=%s dashAge=%s",
				now - e.t,
				e.name,
				e.verdict,
				e.tti or 0,
				e.pressAge and string.format("%.3f", e.pressAge) or "-",
				e.readyIn and string.format("%.3f", e.readyIn) or "-",
				e.dashAge and string.format("%.3f", e.dashAge) or "-"
			)
		end
	end
	return rows
end

S.classDump = function()
	local order = {}
	for kind in pairs(S.classTally) do
		order[#order + 1] = kind
	end
	table.sort(order)

	local rows = {}
	for _, kind in ipairs(order) do
		local r = S.classTally[kind]
		local arrivals = (r.catch + r.loss)
		rows[#rows + 1] = string.format(
			"%-7s seen=%-6d press=%-5d dash=%-5d catch=%-4d loss=%-4d contact=%-4d covered=%-4d late=%-4d nostamp=%-4d catchRate=%s",
			kind,
			r.seen,
			r.press,
			r.dash,
			r.catch,
			r.loss,
			r.contact,
			r.covered,
			r.late,
			r.nostamp,
			arrivals > 0 and string.format("%.2f", r.catch / arrivals) or "-"
		)

		local age = S.contactAge[kind]
		if age and age.n > 0 and age.min < math.huge then
			rows[#rows + 1] = string.format(
				"        ageAtContact n=%d mean=%+.3f min=%+.3f max=%+.3f late=%d ancient=%d",
				age.n,
				age.sum / age.n,
				age.min,
				age.max,
				age.late,
				age.ancient
			)
		end

		-- The class comparison, stated as a rate rather than a count: of the balls
		-- this population threw that reached the body, how many arrived with an
		-- answer already in place. This is the number the whole instrument exists
		-- to produce and it does not depend on a death to be readable.
		if r.near6 > 0 then
			rows[#rows + 1] = string.format(
				"        approach near6=%d answered=%d ring=%d answerRate=%.2f",
				r.near6,
				r.answered,
				r.ring,
				r.answered / r.near6
			)
		end
	end

	if #rows == 0 then
		return { "no throws seen yet" }
	end

	return rows
end

S.probe = function(state, horizon)
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")

	if not (character and root) then
		return nil
	end

	local body = bodyCache[character]
	if not body then
		body = Ballistics.Body(character)
		bodyCache[character] = body
	end

	return timeToHit(
		state,
		character,
		root,
		body,
		Workspace:GetServerTimeNow(),
		horizon or CONFIG.horizon,
		CATCH_RADIUS
	)
end

S.decide = function(live, now, rootVel)
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")

	if not (character and root) then
		return nil
	end

	local body = bodyCache[character]
	if not body then
		body = Ballistics.Body(character)
		bodyCache[character] = body
	end

	local myTeam = character:GetAttribute("Team") or LocalPlayer:GetAttribute("Team")
	return decide(
		live,
		character,
		root,
		body,
		now or Workspace:GetServerTimeNow(),
		myTeam,
		rootVel,
		isEliminated()
	)
end

-- Same pass, with the eliminated flag pinned. Lets a live pass be fed through
-- both readings of the filter without waiting to actually be knocked out.
S.decideAs = function(live, out, now)
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")

	if not (character and root) then
		return nil
	end

	local body = bodyCache[character]
	if not body then
		body = Ballistics.Body(character)
		bodyCache[character] = body
	end

	local myTeam = character:GetAttribute("Team") or LocalPlayer:GetAttribute("Team")
	return decide(live, character, root, body, now or Workspace:GetServerTimeNow(), myTeam, nil, out == true)
end

-- Synthetic fixtures. Each case pins a ball's world line relative to the player
-- and asserts whether the detector should treat it as an inbound hit.
-- Ghost check. The visible ball display is judged against the server's own
-- `HasBall`, not against our intentions: one ball drawn in the palm exactly when
-- the server says one is held. Both directions are measured, because the old
-- watchdog only ever watched one of them and reported zero while the other was
-- on screen.
S.ghostReport = function()
	local character = LocalPlayer.Character
	local hand = character and (character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm"))
	local balls = Workspace:FindFirstChild("DodgeBalls")
	local has = LocalPlayer:GetAttribute("HasBall") == true

	local out = {
		hasBall = has,
		pending = S.throwPending ~= nil,
		throws = S.throws,
		throwAcks = S.throwAcks,
		throwRefused = S.throwRefused,
		palmGhosts = S.palmGhosts,
		palmInvis = S.palmInvis,
		palmLogLast = S.palmLog[#S.palmLog],
		palmInvisLast = S.palmInvisLog[#S.palmInvisLog],
	}

	if not (hand and balls) then
		out.verdict = "no character"
		return out
	end

	local handPos = hand.Position
	local visible, hidden = 0, 0

	for _, ball in ipairs(balls:GetChildren()) do
		if ball:IsA("BasePart") then
			local delta = ball.Position - handPos
			if delta.Magnitude <= PALM_RADIUS and math.abs(delta.Y) <= PALM_DY then
				if ball.LocalTransparencyModifier >= 0.5 or ball.Transparency >= 0.5 then
					hidden = hidden + 1
				else
					visible = visible + 1
				end
			end
		end
	end

	out.palmVisible = visible
	out.palmHidden = hidden

	if has then
		-- Held: exactly one ball must be drawn, unless our own throw is still
		-- inside its bounded cover window.
		out.verdict = (visible == 0 and not coverActive(Workspace:GetServerTimeNow())) and "GHOST (held but not drawn)" or "clean"
	else
		-- Empty hands: nothing may be drawn in the palm at all.
		out.verdict = visible > 0 and "GHOST (drawn but not held)" or "clean"
	end

	return out
end

-- Press-schedule sweep. Pure: it drives `scheduleDue` with a contact clock and
-- the live judge window, sampling at the loop's own tick, and asks one question
-- per profile - is a stamp inside the judge band at the instant of contact?
--
-- The profiles are the ones that actually lose lives: a ball first seen late at
-- point blank, a ball first seen inside the old 0.22 s lead, and a second ball
-- arriving a frame after the first press. Each of those used to reach contact
-- with nothing armed, which left the dash as the only answer.
S.pressTest = function()
	local character = LocalPlayer.Character
	if not character then
		return { ok = false, error = "no character" }
	end

	local window = catchWindow(character)
	local bias = CONFIG.pressBias
	local cadence = math.max(0.10, math.min(CONFIG.pressInterval, window * 0.35))
	local dt = CONFIG.tickInterval

	local function run(name, seenBefore, priorPressAgo, expect)
		local contactAt = 1000
		local now = contactAt - seenBefore
		local stamp = nil
		local lastPress = priorPressAgo and (now - priorPressAgo) or nil
		local sent = 0

		while now <= contactAt do
			local due = scheduleDue(contactAt, stamp, now, window, stamp == nil, lastPress, cadence)
			if due then
				stamp = now - bias
				lastPress = now
				sent = sent + 1
			end
			now = now + dt
		end

		local armed = inJudgeBand(stamp, contactAt, window)
		local pass = armed == expect

		return {
			name = name,
			pass = pass,
			detail = string.format(
				"seen=%.3f sent=%d stamp=%s age=%s",
				seenBefore,
				sent,
				stamp and "yes" or "no",
				stamp and string.format("%.3f", contactAt - stamp) or "-"
			),
		}
	end

	local cases = {
		run("press_far", 0.90, nil, true),
		run("press_window_edge", window - bias + 0.02, nil, true),
		run("press_past_old_lead", 0.30, nil, true),
		run("press_at_old_lead", 0.22, nil, true),
		run("press_close", 0.10, nil, true),
		run("press_pointblank", 0.05, nil, true),
		run("press_contact", 0.02, nil, true),
		run("press_back_to_back", 0.20, 0.02, true),
		run("press_after_prior_ball", 0.20, 0.10, true),
		run("press_never_seen", -0.05, nil, false),
	}

	local failures = 0
	local rows = {}
	for _, case in ipairs(cases) do
		if not case.pass then
			failures = failures + 1
		end
		rows[#rows + 1] = string.format(
			"%s %s %s",
			case.name,
			case.pass and "PASS" or "FAIL",
			case.detail
		)
	end

	return { ok = failures == 0, failures = failures, rows = rows, window = window }
end

-- Catch-coverage sweep. Pure: the same predicate the loop uses to decide
-- whether a dash is needed, driven across the contact profiles that occur in a
-- round. Each case is a way the server answers a catch, so a regression here is a
-- life, not a log line.
S.catchTest = function()
	local window = 0.36
	local contactAt = 1000

	local cases = {
		{ name = "cover_in_band", stamp = contactAt - 0.10, readyBy = contactAt - 0.50, covered = true },
		{ name = "cover_window_edge", stamp = contactAt - window + 0.0005, readyBy = nil, covered = true },
		{ name = "cover_just_past_edge", stamp = contactAt - window - 0.001, readyBy = nil, covered = false },
		{ name = "cover_future_stamp", stamp = contactAt + 0.04, readyBy = nil, covered = false },
		{ name = "cover_stamp_edge_tolerance", stamp = contactAt + 0.02, readyBy = nil, covered = true },
		{ name = "cover_cooldown", stamp = contactAt - 0.10, readyBy = contactAt + 0.20, covered = false },
		{ name = "cover_cooldown_edge", stamp = contactAt - 0.10, readyBy = contactAt - 0.001, covered = true },
		{ name = "cover_refused", stamp = contactAt - 0.10, readyBy = nil, refused = true, covered = false },
		{ name = "cover_no_stamp", stamp = nil, readyBy = nil, covered = false },
		{ name = "cover_no_contact", stamp = contactAt - 0.10, readyBy = nil, noContact = true, covered = false },
		-- The per-ball rule. A stamp that would otherwise cover the ball does not
		-- cover one the judge cannot accept, so the body has to answer it. Both
		-- shapes occur in a round: a ricochet, and a ball the game stopped marking
		-- canHit. Every recorded hit death was one of these, arriving while a press
		-- aimed at a different ball was still in flight.
		{
			name = "cover_not_catchable",
			stamp = contactAt - 0.10,
			readyBy = nil,
			catchable = false,
			covered = false,
		},
		{
			name = "cover_catchable_explicit",
			stamp = contactAt - 0.10,
			readyBy = nil,
			catchable = true,
			covered = true,
		},
	}

	local failures = 0
	local rows = {}
	for _, case in ipairs(cases) do
		local stampContact = contactAt
		if case.noContact then
			stampContact = nil
		end

		local covered =
			catchCovers(case.stamp, stampContact, window, case.readyBy, case.refused, case.catchable)
		local pass = covered == case.covered
		if not pass then
			failures = failures + 1
		end
		rows[#rows + 1] = string.format(
			"%s %s expected=%s got=%s",
			case.name,
			pass and "PASS" or "FAIL",
			tostring(case.covered),
			tostring(covered)
		)
	end

	return { ok = failures == 0, failures = failures, rows = rows }
end

-- Physical-path sweep. Pure: it drives `pathThreat` over the trajectories that
-- decide a life - a head-on throw, a point-blank arrival, the first frame after
-- release, and the first frame after a bounce - plus the ones that must stay
-- silent. The ricochet cases are the reason this seam exists: the frame after a
-- bounce is the one frame where both a velocity estimate and a Live() segment are
-- wrong, and it is also the frame a point-blank hit is decided on.
S.pathTest = function()
	local rootPos = Vector3.new(0, 0, 0)
	local rootVel = Vector3.new(0, 0, 0)
	local horizon = 1.0
	local radius = CATCH_RADIUS
	local V = Vector3.new

	local cases = {
		{ name = "path_head_on", prev = V(0, 0, 10), pos = V(0, 0, 8), dt = 0.014, threat = true, maxTti = 0.15, reason = "hit" },
		{ name = "path_point_blank", prev = V(0, 0, 4.0), pos = V(0, 0, 2.6), dt = 0.008, threat = true, maxTti = 0.05, reason = "hit" },
		{ name = "path_entry_from_hand", prev = V(0, 0, 20), pos = V(0, 0, 18.2), dt = 0.014, threat = true },
		{ name = "path_after_bounce", prev = V(3, 0, 6), pos = V(2.7, 0, 4.4), dt = 0.014, threat = true, maxTti = 0.15 },
		{ name = "path_bounce_away", prev = V(0, 0, 4), pos = V(2, 0, 6), dt = 0.014, threat = false, reason = "past" },
		{ name = "path_clears_by_a_stud", prev = V(3.5, 0, 10), pos = V(3.5, 0, 8), dt = 0.014, threat = false, reason = "miss" },
		{ name = "path_receding", prev = V(0, 0, 5), pos = V(0, 0, 6), dt = 0.014, threat = false, reason = "past" },
		{ name = "path_resting", prev = V(0, 0, 5), pos = V(0, 0, 5), dt = 0.014, threat = false, reason = "speed" },
		{ name = "path_no_prev", prev = nil, pos = V(0, 0, 5), dt = 0.014, threat = false, reason = "no_sample" },
		{ name = "path_beyond_horizon", prev = V(0, 0, 200), pos = V(0, 0, 198), dt = 0.014, threat = false, reason = "beyond" },
		{
			-- The sample is stale by 30 ms. The ball kept flying in that time and
			-- the arrival is 30 ms closer, so the answer has to be stated from
			-- now: 13.7 studs at 142.9 studs/s is 96 ms, where the pre-age
			-- number was 126. A predictor that reports the second one is
			-- answering about the past, and at intercept time that is the
			-- difference between a dash that lands and one that starts after the
			-- hit.
			name = "path_stale_30ms",
			prev = V(0, 0, 20),
			pos = V(0, 0, 18),
			dt = 0.014,
			age = 0.030,
			threat = true,
			maxTti = 0.097,
			reason = "hit",
		},
		{
			-- Same geometry, stale far enough that the ball is already at the
			-- body. It must read `inside`, not a future hit: a sidestep against
			-- a ball that has arrived is a walk, not an evasion.
			name = "path_stale_past_body",
			prev = V(0, 0, 10),
			pos = V(0, 0, 8),
			dt = 0.014,
			age = 0.050,
			threat = false,
			reason = "inside",
		},
		{
			-- Draw lag. ThrowFX draws the replicated part at
			-- `pathAt(now - state.lag)`, while the judge evaluates at now, so a
			-- sample carries real, unseen flight on top of its own age. A ball
			-- 20 studs out at 140 studs/s drawn 112 ms behind is 4.3 studs out,
			-- not 20: 31 ms to contact, not 143. Without the lag term this row
			-- reports 0.143 and every close ball is answered 112 ms late - the
			-- exact window a point-blank hit is decided in.
			name = "path_lag_140",
			prev = V(0, 0, 28),
			pos = V(0, 0, 20),
			dt = 8 / 140,
			lag = 0.112,
			threat = true,
			maxTti = 0.05,
			reason = "hit",
		},
		{
			-- The same sample with no lag: the draw is current, the arithmetic
			-- must be identical to before the fix. Pins 143 ms, not less.
			name = "path_lag_zero_unchanged",
			prev = V(0, 0, 28),
			pos = V(0, 0, 20),
			dt = 8 / 140,
			lag = 0,
			threat = true,
			minTti = 0.13,
			maxTti = 0.15,
			reason = "hit",
		},
		{
			-- A ball the drawn sample still shows two studs from the body, while
			-- the lag says it has already gone through it. The verdict has to be
			-- `past`, both because the hit is behind us and because a sidestep
			-- against it would walk the body into the next ball.
			name = "path_lag_already_past",
			prev = V(0, 0, 5.8),
			pos = V(0, 0, -2),
			dt = 7.8 / 140,
			lag = 0.112,
			threat = false,
			reason = "past",
		},
		{
			-- Drawn 18 studs out, lagged 115 ms: advance 16.1 studs and it is
			-- inside the reach radius. `inside`, not a future hit - this is the
			-- classification that decides whether the body answer arms at all.
			name = "path_lag_point_blank_inside",
			prev = V(0, 0, 26),
			pos = V(0, 0, 18),
			dt = 8 / 140,
			lag = 0.115,
			threat = false,
			reason = "inside",
		},
		{
			-- Moving-player cases. The whole suite used to run with a zero root
			-- velocity, which is the one input that makes the relative frame
			-- identical to the world frame: a predictor that ignores body motion
			-- passes every row above and fails only in play. Each of these is a
			-- position already covered with a velocity attached, asserting the
			-- same outcome, plus the two contrasts that only movement can show.
			name = "path_move_head_on",
			prev = V(0, 0, 10),
			pos = V(0, 0, 8),
			dt = 0.014,
			rootVel = V(0, 0, 22),
			threat = true,
			maxTti = 0.07,
			reason = "hit",
		},
		{
			name = "path_move_receding",
			prev = V(0, 0, 10),
			pos = V(0, 0, 8),
			dt = 0.014,
			rootVel = V(0, 0, -22),
			threat = true,
			maxTti = 0.09,
			reason = "hit",
		},
		{
			name = "path_move_strafe_same",
			prev = V(0, 0, 10),
			pos = V(0, 0, 8),
			dt = 0.014,
			rootVel = V(22, 0, 0),
			threat = true,
			maxTti = 0.12,
			reason = "hit",
		},
		{
			-- A ball that clears a still body by 3 studs. Strafing at 22 studs/s
			-- toward its line carries the body into it, and the relative frame is
			-- the only reason that is visible: the ball's own path never changes.
			name = "path_move_strafe_into_line",
			prev = V(3, 0, 10),
			pos = V(3, 0, 8),
			dt = 0.014,
			rootVel = V(22, 0, 0),
			threat = true,
			maxTti = 0.12,
			reason = "hit",
		},
		{
			-- The same ball at 2 studs, which would hit a still body. Strafing
			-- away at 22 opens the gap past the reach radius before it arrives.
			name = "path_move_strafe_out_of_line",
			prev = V(2, 0, 10),
			pos = V(2, 0, 8),
			dt = 0.014,
			rootVel = V(-22, 0, 0),
			threat = false,
			reason = "miss",
		},
		{
			-- Running with the ball at exactly its observed speed: nothing closes,
			-- so there is no arrival to answer. This is the guard that keeps a
			-- receding body from being walked around by a ball that can never
			-- catch it. The ball travels -Z, so the body has to as well.
			name = "path_move_matches_ball",
			prev = V(0, 0, 10),
			pos = V(0, 0, 8),
			dt = 0.014,
			rootVel = V(0, 0, -2 / 0.014),
			threat = false,
			reason = "speed",
		},
	}

	local failures = 0
	local rows = {}
	for _, case in ipairs(cases) do
		local rec = { prev = case.prev, pos = case.pos, dt = case.dt, t = 0, lag = case.lag }
		local vel = case.rootVel or rootVel
		local tti, _, _, reason = pathThreat(rec, case.age or 0, rootPos, vel, horizon, radius)
		local got = tti ~= nil
		local pass = got == case.threat

		if pass and tti and case.maxTti then
			pass = tti <= case.maxTti
		end
		if pass and tti and case.minTti then
			pass = tti >= case.minTti
		end

		-- The rejection rule is part of the contract: the live tally in pathWhy
		-- uses these names, so a rewrite that starts rejecting for a new reason
		-- shows up here rather than in a lost life.
		if pass and case.reason then
			pass = reason == case.reason
		end

		if not pass then
			failures = failures + 1
		end

		rows[#rows + 1] = string.format(
			"%s %s expected=%s tti=%s why=%s",
			case.name,
			pass and "PASS" or "FAIL",
			tostring(case.threat),
			tti and string.format("%.3f", tti) or "nil",
			tostring(reason)
		)
	end

	-- Arrival cases. A ball re-placed next to the body has one position and no
	-- trajectory, which is exactly the shape that killed a life in the 240 s run:
	-- `no_sample` on every tick while the ball crossed the reach radius. These
	-- rows pin the rule that answers it, and the bounds that keep it from arming
	-- on a ball the tracker merely lost.
	local arrivalCases = {
		{
			-- Pooled at (0,-500,0) then re-placed 9 studs out: the hop is a
			-- re-placement and the answer is the arrival, priced at throw speed.
			name = "arrival_after_pool",
			rec = { pos = rootPos + V(0, 0, 9), t = 100, verdict = "fast" },
			age = 0,
			threat = true,
			maxTti = 9 / PATH_THROW_SPEED + 1e-6,
		},
		{
			name = "arrival_first_sight",
			rec = { pos = rootPos + V(6, 0, 0), t = 100, verdict = "first" },
			age = 0,
			threat = true,
			maxTti = 6 / PATH_THROW_SPEED + 1e-6,
		},
		{
			-- Same position, 300 ms later: the tracker lost it, and the ball has
			-- not moved. Nothing is arriving.
			name = "arrival_too_stale",
			rec = { pos = rootPos + V(0, 0, 9), t = 100 - 0.3, verdict = "fast" },
			age = 0.3,
			threat = false,
		},
		{
			-- A trajectory exists, so the arrival rule must not speak for it.
			name = "arrival_has_flight",
			rec = { pos = rootPos + V(0, 0, 9), t = 100, verdict = "flight" },
			age = 0,
			threat = false,
		},
		{
			name = "arrival_beyond_near",
			rec = { pos = rootPos + V(0, 0, 30), t = 100, verdict = "fast" },
			age = 0,
			threat = false,
		},
		{
			-- Running at the ball: it arrives sooner than the ball alone says, so
			-- the answer has to be sooner. Standing still is the one speed where
			-- this difference is zero.
			--
			-- Sign convention: the bearing is body to ball, so the ball sits at
			-- +Z and running at it is +Z. Same for every case below; the dot
			-- product is what turns that into a closing speed.
			name = "arrival_closing_body",
			rec = { pos = rootPos + V(0, 0, 9), t = 100, verdict = "fast" },
			age = 0,
			rootVel = V(0, 0, 22),
			threat = true,
			maxTti = 9 / (PATH_THROW_SPEED + 22) + 1e-6,
		},
		{
			-- Running away: same ball, later arrival.
			name = "arrival_receding_body",
			rec = { pos = rootPos + V(0, 0, 9), t = 100, verdict = "fast" },
			age = 0,
			rootVel = V(0, 0, -22),
			threat = true,
			minTti = 9 / (PATH_THROW_SPEED - 22) - 1e-6,
		},
		{
			-- Strafing: closing speed is unchanged, so the arrival is unchanged.
			-- A predictor that folded the whole velocity vector into the closing
			-- term would shorten this one and fire early on every strafe.
			name = "arrival_strafe_body",
			rec = { pos = rootPos + V(0, 0, 9), t = 100, verdict = "fast" },
			age = 0,
			rootVel = V(22, 0, 0),
			threat = true,
			maxTti = 9 / PATH_THROW_SPEED + 1e-6,
		},
		{
			-- Same draw lag on the trajectory-less path. The sample is 9 studs
			-- out, drawn 50 ms behind: at throw speed the ball has closed 7 of
			-- them, so the arrival is 14 ms away, not 64. This is the case that
			-- arms the body answer before a point-blank ball crosses the radius.
			name = "arrival_lag_shortens",
			rec = { pos = rootPos + V(0, 0, 9), t = 100, verdict = "fast", lag = 0.05 },
			age = 0,
			threat = true,
			maxTti = 2 / PATH_THROW_SPEED + 1e-6,
		},
		{
			-- Lag covers the whole sampled distance: it is here now.
			name = "arrival_lag_already_here",
			rec = { pos = rootPos + V(0, 0, 9), t = 100, verdict = "fast", lag = 0.1 },
			age = 0,
			threat = true,
			maxTti = 1e-6,
		},
		{
			-- Outrunning the fastest legal throw: the ball never arrives.
			name = "arrival_body_outruns_ball",
			rec = { pos = rootPos + V(0, 0, 9), t = 100, verdict = "fast" },
			age = 0,
			rootVel = V(0, 0, -150),
			threat = false,
		},
	}

	for _, case in ipairs(arrivalCases) do
		local tti = arrivalThreat(case.rec, 100 + (case.age or 0), rootPos, case.rootVel)
		local pass = (tti ~= nil) == case.threat
		if pass and tti and case.maxTti then
			pass = tti <= case.maxTti
		end
		if pass and tti and case.minTti then
			pass = tti >= case.minTti
		end
		if not pass then
			failures = failures + 1
		end
		rows[#rows + 1] = string.format(
			"%s %s expected=%s tti=%s",
			case.name,
			pass and "PASS" or "FAIL",
			tostring(case.threat),
			tti and string.format("%.3f", tti) or "nil"
		)
	end

	-- Part-selection cases. The measured failure is here: every ball in
	-- DodgeBalls is anchored and CFrame-driven, so a tracker that skips anchored
	-- parts tracks nothing while the balls fly past it. The rule is motion-based,
	-- and these rows pin down what it accepts and what it must still refuse.
	local function stubPart(parented, welded)
		return {
			Parent = parented and true or nil,
			FindFirstChildWhichIsA = function(_, class)
				if class == "Weld" and welded then
					return { ClassName = "Weld" }
				end
				return nil
			end,
		}
	end

	local partCases = {
		{ name = "path_part_anchored", part = stubPart(true, false), exempt = nil, expect = true },
		{ name = "path_part_welded", part = stubPart(true, true), exempt = nil, expect = false },
		{ name = "path_part_orphan", part = stubPart(false, false), exempt = nil, expect = false },
	}

	local exemptCase = stubPart(true, false)
	partCases[#partCases + 1] =
		{ name = "path_part_exempt", part = exemptCase, exempt = { [exemptCase] = true }, expect = false }

	for _, case in ipairs(partCases) do
		local got = pathCandidate(case.part, case.exempt)
		local pass = got == case.expect
		if not pass then
			failures = failures + 1
		end

		rows[#rows + 1] = string.format(
			"%s %s tracked=%s",
			case.name,
			pass and "PASS" or "FAIL",
			tostring(got)
		)
	end

	-- Sampling cases. These are the two shapes that made the tracker blind in a
	-- live round: a ball replicated in hops (most ticks see the same position),
	-- and a hop whose delta is compared against one tick instead of the true
	-- interval. Both produced a nil path on every tick while balls flew past.
	local sampleCases = {
		{
			name = "path_first_sample",
			rec = nil,
			pos = V(0, 0, 10),
			now = 100,
			wantPrev = false,
			wantVerdict = "first",
		},
		{
			-- 7 studs replicated in one hop at 20 Hz is real flight. Against one
			-- 12 ms tick it would look like 580 studs/s.
			name = "path_replicated_hop",
			rec = { pos = V(0, 0, 17), t = 100 },
			pos = V(0, 0, 10),
			now = 100.05,
			wantPrev = true,
			wantDt = 0.05,
			wantVerdict = "flight",
		},
		{
			-- Same position as last tick: the sample clock must not advance, or
			-- the next hop is measured against a single tick again.
			name = "path_repeated_position",
			rec = { pos = V(0, 0, 10), t = 100, prev = V(0, 0, 17), dt = 0.05 },
			pos = V(0, 0, 10),
			now = 100.07,
			wantPrev = true,
			wantDt = 0.05,
			wantT = 100,
			wantVerdict = "repeat",
		},
		{
			-- A hop batched into one frame: two replication samples arrive
			-- together, so the observed speed is twice the ball's. A client
			-- hitch must not be able to delete the last trajectory, and the bound
			-- is stated against exactly this case.
			name = "path_batched_hop",
			rec = { pos = V(0, 0, 26.7), t = 100 },
			pos = V(0, 0, 17.4),
			now = 100.0167,
			wantPrev = true,
			wantDt = 0.0167,
			wantVerdict = "flight",
		},
		{
			name = "path_pool_teleport",
			rec = { pos = V(0, 0, 10), t = 100 },
			pos = V(0, -500, 0),
			now = 100.05,
			wantPrev = false,
			wantVerdict = "fast",
		},
		{
			name = "path_stale_gap",
			rec = { pos = V(0, 0, 10), t = 100 },
			pos = V(0, 0, 12),
			now = 103,
			wantPrev = false,
			wantVerdict = "gap",
		},
		{
			-- A frame spike. 120 ms between ticks is a hitch, not a re-placement:
			-- the ball is still the same ball and the interval is honest, so the
			-- trajectory survives it. This is the case that says a stutter cannot
			-- silently delete the answer - the sweep would catch it if it could.
			name = "path_frame_spike",
			rec = { pos = V(0, 0, 30), t = 100 },
			pos = V(0, 0, 12.6),
			now = 100.12,
			wantPrev = true,
			wantDt = 0.12,
			wantVerdict = "flight",
		},
		{
			-- Past the gap guard the two positions are unrelated and the path
			-- restarts, which is correct: claiming flight across an unknown
			-- interval would invent a velocity.
			name = "path_gap_too_long",
			rec = { pos = V(0, 0, 30), t = 100 },
			pos = V(0, 0, 12.6),
			now = 100.42,
			wantPrev = false,
			wantVerdict = "gap",
		},
	}

	for _, case in ipairs(sampleCases) do
		local rec, verdict = pathSample(case.rec, case.pos, case.now)
		local gotPrev = rec.prev ~= nil
		local pass = gotPrev == case.wantPrev

		if pass and case.wantDt then
			pass = rec.dt and math.abs(rec.dt - case.wantDt) < 1e-6
		end
		if pass and case.wantT then
			pass = rec.t == case.wantT
		end
		-- The verdict is the name the live tally counts under, so a row that
		-- stops matching its own accounting is a fault even when the stored
		-- record looks right.
		if pass and case.wantVerdict then
			pass = verdict == case.wantVerdict
		end

		if not pass then
			failures = failures + 1
		end

		rows[#rows + 1] = string.format(
			"%s %s prev=%s dt=%s why=%s",
			case.name,
			pass and "PASS" or "FAIL",
			tostring(gotPrev),
			rec.dt and string.format("%.3f", rec.dt) or "nil",
			tostring(verdict)
		)
	end

	return { ok = failures == 0, failures = failures, rows = rows }
end

-- Throw-safety sweep. Pure: it drives `targetCanCatch` over the three replicated
-- facts a target publishes, and asks one question - would a throw at this target
-- come back as an elimination? The cases are the ones that occur in a round: a
-- ready, empty-handed enemy (the throw would be caught), an enemy still on the
-- catch cooldown after catching something, an enemy holding a ball, an eliminated
-- player, and the two stale-attribute shapes a replicated timestamp can take.
S.throwTest = function()
	local now = 1000

	local cases = {
		{ name = "throw_ready_empty", hasBall = false, out = false, readyAt = now - 0.2, canCatch = true },
		{ name = "throw_ready_none", hasBall = false, out = false, readyAt = nil, canCatch = true },
		{ name = "throw_cooling", hasBall = false, out = false, readyAt = now + 0.40, canCatch = false },
		{ name = "throw_cooling_edge", hasBall = false, out = false, readyAt = now + 0.001, canCatch = false },
		{ name = "throw_holding", hasBall = true, out = false, readyAt = now - 1.0, canCatch = false },
		{ name = "throw_eliminated", hasBall = false, out = true, readyAt = now - 1.0, canCatch = false },
		{ name = "throw_stale_future", hasBall = false, out = false, readyAt = now + 1e6, canCatch = true },
		{ name = "throw_stale_past", hasBall = false, out = false, readyAt = now - 5.0, canCatch = true },
		{ name = "throw_holding_and_cooling", hasBall = true, out = false, readyAt = now + 0.2, canCatch = false },
	}

	local failures = 0
	local rows = {}
	for _, case in ipairs(cases) do
		local canCatch = targetCanCatch(case.hasBall, case.out, case.readyAt, now)
		local pass = canCatch == case.canCatch
		if not pass then
			failures = failures + 1
		end
		rows[#rows + 1] = string.format(
			"%s %s expected=%s got=%s",
			case.name,
			pass and "PASS" or "FAIL",
			tostring(case.canCatch),
			tostring(canCatch)
		)
	end

	return { ok = failures == 0, failures = failures, rows = rows }
end

-- Panel bindings, read back. Every control is stored at creation with the state
-- it claims to own, so this answers one question per control: does the panel show
-- what the assist is actually running on? A toggle wired to a key nobody reads
-- looks perfect in a screenshot - it only shows up here, as a mismatch.
S.panelBindings = function()
	local panel = S.panel
	if not (panel and panel.bindings) then
		return { ok = false, rows = { "panel_bindings FAIL no-panel" }, failures = 1 }
	end

	local rows, failures = {}, 0
	for _, entry in ipairs(panel.bindings) do
		-- Fluent keeps the state on the element as `.Value`; there is no reader
		-- method, and the metatable's __index is a dispatcher rather than a
		-- table, so this is the only honest read.
		local shown = entry.element.Value
		local live = entry.get()
		local match
		if type(live) == "number" then
			match = tonumber(shown) ~= nil and math.abs(tonumber(shown) - live) < 0.005
		else
			match = shown == live
		end
		if not match then
			failures = failures + 1
		end
		rows[#rows + 1] = string.format(
			"%s %s shown=%s live=%s",
			entry.id,
			match and "PASS" or "FAIL",
			tostring(shown),
			tostring(live)
		)
	end

	return { ok = failures == 0, rows = rows, failures = failures }
end

-- Arrival-race sweep. The classifier is the join between "the client answered"
-- and "the server took it": every recorded death resolves to exactly one of
-- these verdicts through the same ring lookup the live log uses. A `catch` or
-- `dash` verdict on a life that still dropped is a client/server disagreement;
-- `dash-miss`, `catch-cool`, `no-press` and `past` are ours.
S.raceTest = function()
	local cases = {
		{ name = "race_dash_cover", facts = { tti = -0.001, dashActive = true }, expect = "dash" },
		{ name = "race_catch_cover", facts = { tti = -0.001, covers = true }, expect = "catch" },
		{
			name = "race_dash_miss",
			facts = { tti = -0.001, dashSpent = true, dashActive = false, stamp = false },
			expect = "dash-miss",
		},
		{
			name = "race_catch_cool",
			facts = { tti = -0.001, covers = false, stamp = true, readyIn = 0.2 },
			expect = "catch-cool",
		},
		{
			name = "race_hands",
			facts = { tti = -0.001, covers = false, stamp = false, hands = true },
			expect = "hands",
		},
		{
			name = "race_no_press",
			facts = { tti = -0.001, covers = false, stamp = false, hands = false },
			expect = "no-press",
		},
		{
			name = "race_past",
			facts = { tti = -0.001, covers = false, stamp = true, readyIn = -0.5 },
			expect = "past",
		},
		{ name = "race_late_sight", facts = { tti = nil }, expect = "pred-miss" },
	}

	local rows, failures = {}, 0
	for _, case in ipairs(cases) do
		local got = raceVerdict(case.facts)
		local pass = got == case.expect
		if not pass then
			failures = failures + 1
		end
		rows[#rows + 1] =
			string.format("%s %s expected=%s got=%s", case.name, pass and "PASS" or "FAIL", case.expect, got)
	end

	-- Success-then-hit. A catch verdict 120 ms before the drop is the shape the
	-- live log recorded: the client answered, the server undid it afterwards.
	-- Anything older than the window must not be blamed for the life, or the log
	-- pins every death on the last ball it happened to see.
	local ring = {
		[1] = { t = 100.0, verdict = "catch", name = "Ball_a" },
		[2] = { t = 100.2, verdict = "no-press", name = "Ball_b" },
		[3] = { t = 101.0, verdict = "dash-miss", name = "Ball_c" },
	}
	local resolveCases = {
		{ name = "race_resolve_recent", now = 100.32, expect = "no-press", span = 0.45 },
		{ name = "race_success_then_hit", now = 100.12, expect = "catch", span = 0.45 },
		{ name = "race_resolve_too_old", now = 100.9, expect = nil, span = 0.45 },
	}
	for _, case in ipairs(resolveCases) do
		local e = raceResolve(ring, 4, 8, case.now, case.span)
		local got = e and e.verdict or nil
		local pass = got == case.expect
		if not pass then
			failures = failures + 1
		end
		rows[#rows + 1] = string.format(
			"%s %s expected=%s got=%s",
			case.name,
			pass and "PASS" or "FAIL",
			tostring(case.expect),
			tostring(got)
		)
	end

	return { ok = failures == 0, rows = rows, failures = failures }
end

-- Segment-source cases. The part tracker cannot answer for any ball this game
-- throws - the part is pooled for the whole flight of every class - so the body
-- answer depends entirely on the segment source. These cases drive it with a
-- ball that has no part at all, which is exactly the live shape, and require the
-- same verdicts from the player-thrown and bot-thrown copy of the same geometry.
S.segPathTest = function()
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local rows, failures = {}, 0

	if not root then
		rows[#rows + 1] = "segpath SKIP no root"
		return { rows = rows, failures = 0 }
	end

	local origin = root.Position
	local now = Workspace:GetServerTimeNow()

	local function run(name, kind, offset, velocity, expectHit)
		local state = {
			id = "fixture_" .. kind,
			kind = kind,
			botThrow = kind == "bot",
			seg = {
				p0 = origin + offset,
				v0 = velocity,
				t0 = now - 0.05,
				g = Vector3.zero,
			},
		}

		segSample(state, now)
		local rec = segSample(state, now + 0.02)
		local tti, miss, _, reason

		if rec then
			tti, miss, _, reason = pathThreat(
				rec,
				now + 0.02,
				origin,
				Vector3.zero,
				1.0,
				CATCH_RADIUS
			)
		end

		local got = tti ~= nil
		local pass = got == expectHit
		if not pass then
			failures = failures + 1
		end

		rows[#rows + 1] = string.format(
			"%s %s tti=%s reason=%s miss=%s",
			name,
			pass and "PASS" or "FAIL",
			tti and string.format("%.3f", tti) or "nil",
			tostring(reason),
			miss and string.format("%.2f", miss) or "-"
		)
	end

	run("segpath_attack_inbound", "attack", Vector3.new(0, 0, 30), Vector3.new(0, 0, -120), true)
	run("segpath_bot_inbound", "bot", Vector3.new(0, 0, 30), Vector3.new(0, 0, -120), true)
	run("segpath_attack_receding", "attack", Vector3.new(0, 0, 10), Vector3.new(0, 0, 120), false)
	run("segpath_bot_receding", "bot", Vector3.new(0, 0, 10), Vector3.new(0, 0, 120), false)
	run("segpath_attack_passing", "attack", Vector3.new(20, 0, 30), Vector3.new(0, 0, -120), false)
	run("segpath_bot_passing", "bot", Vector3.new(20, 0, 30), Vector3.new(0, 0, -120), false)

	-- The routing bug that kept the segment source silent for a whole session:
	-- `covered` tested whether the part was in the tracker, and the pooled part
	-- always is, so every ball was handed to a source that cannot see it. These
	-- cases pin the test that replaces it. A record with no distinct second
	-- position is a parked seat and must not count as carrying motion, however
	-- recently it was touched.
	local carryCases = {
		{
			name = "carry_parked_never_moved",
			rec = { pos = origin, prev = nil, dt = nil, t = now },
			now = now,
			expect = false,
		},
		{
			name = "carry_parked_recent_touch",
			rec = { pos = origin, prev = nil, dt = nil, t = now - 0.01 },
			now = now,
			expect = false,
		},
		{
			name = "carry_moving",
			rec = { pos = origin, prev = origin - Vector3.new(0, 0, 6), dt = 0.04, t = now - 0.01 },
			now = now,
			expect = true,
		},
		{
			name = "carry_stopped",
			rec = { pos = origin, prev = origin - Vector3.new(0, 0, 6), dt = 0.04, t = now - 1.5 },
			now = now,
			expect = false,
		},
		{
			name = "carry_nil_rec",
			rec = nil,
			now = now,
			expect = false,
		},
	}
	for _, case in ipairs(carryCases) do
		local got = partCarries(case.rec, case.now)
		local pass = got == case.expect
		if not pass then
			failures = failures + 1
		end
		rows[#rows + 1] = string.format(
			"%s %s expected=%s got=%s",
			case.name,
			pass and "PASS" or "FAIL",
			tostring(case.expect),
			tostring(got)
		)
	end

	-- The seam the reported bug actually lived at ---------------------------
	--
	-- Everything above drives pathThreat directly, which proves the predictor
	-- understands a segment. It does not prove physicalThreat ever asks it, and
	-- that gate is where the failure was: `covered` tested tracker membership,
	-- the pooled part is always a member, so every ball was routed to a source
	-- that cannot see it and the segment answered for nothing at all. A test
	-- that calls the predictor can never go red on a routing bug in its caller.
	--
	-- So these drive physicalThreat with the live shape - a ball whose part is
	-- parked in the tracker and whose only motion is on the segment - and
	-- require the same answer from both populations. The last two cases are the
	-- other direction: a ball the part does carry, and a ball with no segment at
	-- all, must not be answered by this path, or the fix becomes a dodge at
	-- everything.
	local stubCharacter = {
		GetAttribute = function()
			return nil
		end,
	}
	local stubRoot = {
		Position = origin,
		AssemblyLinearVelocity = Vector3.zero,
	}

	local function stubPart()
		return {
			Name = "FixtureBall",
			Parent = true,
			FindFirstChildWhichIsA = function()
				return nil
			end,
		}
	end

	local function watchState(kind)
		return {
			id = "watch_" .. kind,
			kind = kind,
			botThrow = kind == "bot",
			hold = false,
			thrower = "fixture",
			seg = {
				p0 = origin + Vector3.new(0, 0, 30),
				v0 = Vector3.new(0, 0, -120),
				t0 = now - 0.05,
				g = Vector3.zero,
			},
		}
	end

	local function segTally()
		local n = 0
		for _, count in pairs(S.pathWhySeg) do
			n = n + count
		end
		return n
	end

	local function watchRun(state, part)
		state.part = part
		segSample(state, now)
		segSample(state, now + 0.02)
		local before = segTally()
		local tti, dir, miss = physicalThreat(stubCharacter, stubRoot, now + 0.02, 1.0, nil, { state })
		return tti, dir, miss, segTally() - before
	end

	local function check(name, pass, detail)
		if not pass then
			failures = failures + 1
		end
		rows[#rows + 1] = string.format("%s %s %s", name, pass and "PASS" or "FAIL", detail)
	end

	-- Hermetic: with live balls in the tracker a fixture case could be answered
	-- by somebody else's ball and pass or fail for the wrong reason. The tracker
	-- is saved, emptied, exercised and restored - the whole block runs without
	-- yielding, so no live tick can observe the empty state.
	local savedPath = {}
	for part, rec in pairs(ballPath) do
		savedPath[part] = rec
		ballPath[part] = nil
	end

	-- 1. Same geometry, two populations: the whole returned tuple must agree.
	local attackTti, attackDir, attackMiss = watchRun(watchState("attack"), nil)
	local botTti, botDir, botMiss = watchRun(watchState("bot"), nil)
	local sameAnswer = attackTti ~= nil
		and botTti ~= nil
		and type(attackMiss) == "number"
		and type(botMiss) == "number"
		and attackDir ~= nil
		and botDir ~= nil
		and math.abs(attackTti - botTti) <= 1e-9
		and math.abs(attackMiss - botMiss) <= 1e-9
		and (attackDir - botDir).Magnitude <= 1e-9

	check(
		"watch_class_blind",
		sameAnswer,
		string.format(
			"attack=%.4f/%s bot=%.4f/%s",
			attackTti or -1,
			attackMiss and string.format("%.3f", attackMiss) or "-",
			botTti or -1,
			botMiss and string.format("%.3f", botMiss) or "-"
		)
	)

	-- 2. The live shape: part parked in the tracker, motion on the segment.
	local parkedPart = stubPart()
	ballPath[parkedPart] = { pos = origin + Vector3.new(500, 0, 0), t = now }
	local parkedTti, _, _, parkedSeg = watchRun(watchState("attack"), parkedPart)
	ballPath[parkedPart] = nil
	parkedPart.Parent = nil

	check(
		"watch_parked_part_answered",
		parkedTti ~= nil and parkedSeg > 0,
		string.format("tti=%s segTicks=%d", parkedTti and string.format("%.3f", parkedTti) or "nil", parkedSeg)
	)

	-- 3. A part that really carries the motion keeps the answer to itself.
	local carryPart = stubPart()
	ballPath[carryPart] = {
		pos = origin + Vector3.new(0, 0, 30),
		prev = origin + Vector3.new(0, 0, 34),
		dt = 0.04,
		t = now + 0.02,
	}
	local _, _, _, carrySeg = watchRun(watchState("bot"), carryPart)
	ballPath[carryPart] = nil
	carryPart.Parent = nil

	check("watch_carrying_part_wins", carrySeg == 0, string.format("segTicks=%d", carrySeg))

	-- 4. No segment, parked part: nothing to answer for, so no answer.
	local silentPart = stubPart()
	ballPath[silentPart] = { pos = origin + Vector3.new(0, 0, 30), t = now }
	local silentState = watchState("attack")
	silentState.seg = nil
	local silentTti, _, _, silentSeg = watchRun(silentState, silentPart)
	ballPath[silentPart] = nil
	silentPart.Parent = nil

	check(
		"watch_no_segment_silent",
		silentTti == nil and silentSeg == 0,
		string.format("tti=%s segTicks=%d", silentTti and string.format("%.3f", silentTti) or "nil", silentSeg)
	)

	for part, rec in pairs(savedPath) do
		ballPath[part] = rec
	end

	return { rows = rows, failures = failures }
end

S.selftest = function()
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")

	if not (character and root) then
		return { ok = false, error = "no character" }
	end

	local body = bodyCache[character]
	if not body then
		body = Ballistics.Body(character)
		bodyCache[character] = body
	end

	local now = Workspace:GetServerTimeNow()
	local origin = root.Position
	local myTeam = character:GetAttribute("Team") or "Red"
	local enemyTeam = if myTeam == "Blue" then "Red" else "Blue"

	local function make(offset, velocity, over)
		local state = {
			seg = {
				p0 = origin + offset,
				v0 = velocity,
				t0 = now,
				g = Vector3.new(0, 0, 0),
			},
			canHit = true,
			kind = "attack",
			team = enemyTeam,
			thrower = Workspace,
		}

		if over then
			for key, value in pairs(over) do
				state[key] = value
			end
		end

		return state
	end

	-- Throwers for the team-side rule. A bare Instance carries the same Team
	-- attribute a character does, which is all isFriendThrow reads.
	local friendThrower = Instance.new("Folder")
	friendThrower:SetAttribute("Team", myTeam)
	local enemyThrower = Instance.new("Folder")
	enemyThrower:SetAttribute("Team", enemyTeam)

	local cases = {
		{ name = "incoming", expect = true, state = make(Vector3.new(0, 0, 30), Vector3.new(0, 0, -120)) },		{ name = "graze", expect = true, state = make(Vector3.new(2, 0, 30), Vector3.new(0, 0, -120)) },
		{ name = "behind", expect = true, state = make(Vector3.new(0, 0, -30), Vector3.new(0, 0, 120)) },
		{ name = "passing", expect = false, state = make(Vector3.new(15, 0, 30), Vector3.new(0, 0, -120)) },
		{ name = "receding", expect = false, state = make(Vector3.new(0, 0, 20), Vector3.new(0, 0, 120)) },
		{
			name = "teammate",
			expect = true,
			state = make(Vector3.new(0, 0, 30), Vector3.new(0, 0, -120), { team = myTeam }),
		},
		{
			name = "pass_kind",
			expect = true,
			state = make(Vector3.new(0, 0, 30), Vector3.new(0, 0, -120), { kind = "pass" }),
		},
		{
			name = "loose_kind",
			expect = true,
			state = make(Vector3.new(0, 0, 30), Vector3.new(0, 0, -120), { kind = "loose" }),
		},
		{
			name = "no_canhit",
			expect = false,
			state = make(Vector3.new(0, 0, 30), Vector3.new(0, 0, -120), { canHit = false }),
		},
		{ name = "pointblank", expect = true, state = make(Vector3.new(0, 0, 3), Vector3.new(0, 0, -120)) },
		{ name = "pointblank_side", expect = true, state = make(Vector3.new(3, 0, 0), Vector3.new(-120, 0, 0)) },
		{
			-- Sidelined: a teammate's pass is the ride back in. Not a threat.
			name = "pass_while_out",
			expect = false,
			out = true,
			state = make(Vector3.new(0, 0, 30), Vector3.new(0, 0, -120), { kind = "pass", team = myTeam }),
		},
		{
			name = "pass_flag_while_out",
			expect = false,
			out = true,
			state = make(Vector3.new(0, 0, 30), Vector3.new(0, 0, -120), { pass = true, team = myTeam }),
		},
		{
			-- Still a threat while sidelined: a ball that is not a pass.
			name = "attack_while_out",
			expect = true,
			out = true,
			state = make(Vector3.new(0, 0, 30), Vector3.new(0, 0, -120)),
		},
		{
			-- In the field a pass can still break a face, so it still counts.
			name = "pass_while_in",
			expect = true,
			state = make(Vector3.new(0, 0, 30), Vector3.new(0, 0, -120), { kind = "pass" }),
		},
		{
			-- The point-blank net must obey the same filter.
			name = "pointblank_pass_while_out",
			expect = false,
			out = true,
			state = make(Vector3.new(0, 0, 3), Vector3.new(0, 0, -120), { kind = "pass" }),
		},
		{
			-- Belt and braces: a teammate's throw is not worth moving for while out,
			-- even if it arrives labelled as an attack.
			name = "friend_while_out",
			expect = false,
			out = true,
			state = make(Vector3.new(0, 0, 30), Vector3.new(0, 0, -120), { thrower = friendThrower }),
		},
		{
			-- Same ball in the field: a teammate's throw can still hurt, catch it.
			name = "friend_while_in",
			expect = true,
			state = make(Vector3.new(0, 0, 30), Vector3.new(0, 0, -120), { thrower = friendThrower }),
		},
		{
			-- An enemy ball while sidelined is still tracked, so a stray body block
			-- does not pin him off the pickup.
			name = "enemy_while_out",
			expect = true,
			out = true,
			state = make(Vector3.new(0, 0, 30), Vector3.new(0, 0, -120), { thrower = enemyThrower }),
		},

		-- The class split. The same geometry must produce the same decision whether
		-- the game called the throw a bot throw or a player throw: the predictor is
		-- class-blind by construction, and if that ever stops being true these two
		-- cases are the ones that say so. They exist so a future change cannot make
		-- one population easy and the other invisible without a test going red.
		{
			name = "attack_class_inbound",
			expect = true,
			state = make(Vector3.new(0, 0, 30), Vector3.new(0, 0, -120), { kind = "attack", botThrow = false }),
		},
		{
			name = "bot_class_inbound",
			expect = true,
			state = make(Vector3.new(0, 0, 30), Vector3.new(0, 0, -120), { kind = "bot", botThrow = true }),
		},
		{
			name = "attack_class_pointblank",
			expect = true,
			state = make(Vector3.new(0, 0, 3), Vector3.new(0, 0, -120), { kind = "attack", botThrow = false }),
		},
		{
			name = "bot_class_pointblank",
			expect = true,
			state = make(Vector3.new(0, 0, 3), Vector3.new(0, 0, -120), { kind = "bot", botThrow = true }),
		},
		{
			name = "attack_class_passing",
			expect = false,
			state = make(Vector3.new(15, 0, 30), Vector3.new(0, 0, -120), { kind = "attack", botThrow = false }),
		},
		{
			name = "bot_class_passing",
			expect = false,
			state = make(Vector3.new(15, 0, 30), Vector3.new(0, 0, -120), { kind = "bot", botThrow = true }),
		},
	}

	local rows = {}
	local failures = 0

	for _, case in ipairs(cases) do
		local _, tti = decide(
			{ [1] = case.state },
			character,
			root,
			body,
			now,
			myTeam,
			Vector3.zero,
			case.out == true
		)

		-- The fixture asserts detection: whether the ball is a threat at all. The
		-- press window is a separate concern (judgePress), so tying this to
		-- CONFIG.pressLead would make a timing tune look like a filter regression.
		local got = tti ~= nil
		local pass = got == case.expect
		if not pass then
			failures = failures + 1
		end

		rows[#rows + 1] = string.format(
			"%s %s tti=%s",
			case.name,
			pass and "PASS" or "FAIL",
			tti and string.format("%.3f", tti) or "nil"
		)
	end

	-- Contact-audit classification. The audit's history was reading a 14.7 s old
	-- stamp as a "late" press, which turns "no press was ever armed for this ball"
	-- into "the schedule was a few frames behind" - two faults with different
	-- repairs. Pinned at the boundary so a future edit cannot widen the window.
	local verdictCases = {
		{ name = "verdict_covered", covered = true, age = 0.10, expect = "covered" },
		{ name = "verdict_late", covered = false, age = 0.30, expect = "late" },
		{ name = "verdict_late_near_boundary", covered = false, age = 1.35, expect = "late" },
		{ name = "verdict_ancient_is_nostamp", covered = false, age = 1.37, expect = "nostamp" },
		{ name = "verdict_two_seconds", covered = false, age = 2.0, expect = "nostamp" },
		{ name = "verdict_fourteen_seconds", covered = false, age = 14.747, expect = "nostamp" },
		{ name = "verdict_nil_age", covered = false, age = nil, expect = "nostamp" },
	}
	for _, case in ipairs(verdictCases) do
		local got = contactVerdict(case.covered, case.age, 0.36)
		local pass = got == case.expect
		if not pass then
			failures = failures + 1
		end
		rows[#rows + 1] = string.format(
			"%s %s expected=%s got=%s",
			case.name,
			pass and "PASS" or "FAIL",
			case.expect,
			tostring(got)
		)
	end

	-- Class attribution. Every tally in this file is keyed on classOf, so a wrong
	-- answer here silently moves a population's numbers into another population's
	-- row - the exact failure the tally exists to detect. Pinned directly.
	local classCases = {
		{ name = "class_attack", state = { kind = "attack", botThrow = false }, expect = "attack" },
		{ name = "class_bot", state = { kind = "bot", botThrow = true }, expect = "bot" },
		{ name = "class_pass", state = { kind = "pass" }, expect = "pass" },
		{ name = "class_loose", state = { kind = "loose" }, expect = "loose" },
		{ name = "class_kind_wins", state = { kind = "bot", botThrow = false }, expect = "bot" },
		{ name = "class_botflag_only", state = { botThrow = true }, expect = "bot" },
		{ name = "class_nil", state = nil, expect = "none" },
		{ name = "class_bare", state = {}, expect = "unknown" },
	}
	for _, case in ipairs(classCases) do
		local got = classOf(case.state)
		local pass = got == case.expect
		if not pass then
			failures = failures + 1
		end
		rows[#rows + 1] = string.format(
			"%s %s expected=%s got=%s",
			case.name,
			pass and "PASS" or "FAIL",
			case.expect,
			tostring(got)
		)
	end

	-- Body-path cases. The catch judge refuses a bounced or nocanhit ball; the hit
	-- test does not. Each must stay invisible to the catch decision and visible to
	-- the body decision, and the body decision reads the physical path, so the
	-- sweep drives that predicate directly.
	local path = S.pathTest()
	if path and path.rows then
		for _, row in ipairs(path.rows) do
			rows[#rows + 1] = row
		end
		failures = failures + (path.failures or 0)
	end

	-- The press schedule is the other half of a catch: the threat filter above
	-- says which balls are catchable, this says whether a stamp was actually in
	-- the judge band when one arrives. A round that reports clean filters and
	-- still loses lives is failing here, so it runs in the same report.
	local press = S.pressTest()
	if press and press.rows then
		for _, row in ipairs(press.rows) do
			rows[#rows + 1] = row
		end
		failures = failures + (press.failures or 0)
	end

	-- The segment source is the only one that can answer for a real ball, so a
	-- regression there is a silent return to a dead body answer.
	local segRes = S.segPathTest()
	if segRes and segRes.rows then
		for _, row in ipairs(segRes.rows) do
			rows[#rows + 1] = row
		end
		failures = failures + (segRes.failures or 0)
	end

	-- And the throw, which is the last way a life goes missing: a throw into a
	-- catcher is an elimination, not a miss.
	local throw = S.throwTest()
	if throw and throw.rows then
		for _, row in ipairs(throw.rows) do
			rows[#rows + 1] = row
		end
		failures = failures + (throw.failures or 0)
	end

	-- Catch coverage: whether a stamp already in flight would be accepted for the
	-- ball that arrives. This is the test that separates "the schedule failed" from
	-- "the ball was never catchable", and it is the same call the dash decision
	-- makes, so a wrong answer here spends a 2.2 s cooldown on nothing.
	local cover = S.catchTest()
	if cover and cover.rows then
		for _, row in ipairs(cover.rows) do
			rows[#rows + 1] = row
		end
		failures = failures + (cover.failures or 0)
	end

	-- Arrival race: whether the answer that was live when the ball arrived is
	-- one the server takes, and which verdict a death resolves to.
	local race = S.raceTest()
	if race and race.rows then
		for _, row in ipairs(race.rows) do
			rows[#rows + 1] = row
		end
		failures = failures + (race.failures or 0)
	end

	-- Configuration types. The body answer compares against these numbers on every
	-- tick, so a string here is not a cosmetic fault: the comparison throws, the
	-- tick is lost, and a ball that was seen reads as a ball that was never seen.
	-- One row per key, so a report names the exact one that went bad.
	for _, key in ipairs(NUMERIC_CONFIG) do
		local kind = type(CONFIG[key])
		local pass = kind == "number"
		if not pass then
			failures = failures + 1
		end
		rows[#rows + 1] = string.format("config_number_%s %s (%s)", key, pass and "PASS" or "FAIL", kind)
	end

	return { ok = failures == 0, failures = failures, rows = rows }
end

buildLabel()

-- Any value the previous session or a hand-edited table left behind is repaired
-- before the first tick reads it.
S.configRepairs = normalizeConfig()

-- The panel is optional by construction: if the library cannot be fetched, the
-- assist still catches and dashes and the HUD still reports. A library that
-- loads but throws while building is torn down and reported the same way, so a
-- half-built window can never sit on the screen.
local okPanel, panelErr = pcall(buildPanel)
if not okPanel then
	panelFailed = tostring(panelErr)
	S.panel = { failed = panelFailed }
	if Fluent then
		pcall(function()
			Fluent:Destroy()
		end)
		Fluent = nil
	end
elseif not S.panel then
	S.panel = { failed = panelFailed or "library unavailable" }
end

-- Second pass, because creating a slider runs its changed callback, and the
-- library's own Round() hands back a string for any value without a decimal
-- point. Repairing here means the panel cannot seed the geometry with a type it
-- cannot use. Repairs are kept for the sweep rather than swallowed.
do
	local afterPanel = normalizeConfig()
	for _, key in ipairs(afterPanel) do
		S.configRepairs[#S.configRepairs + 1] = key .. "@panel"
	end
end

local connections = {}
local connection

-- Every entry into `step` is costed, including the early returns, because those
-- are exactly the ticks a hitch would produce. The wrapper is the only thing
-- connected, so no sampler can bypass the measurement.
local function timedStep()
	local started = os.clock()
	step()
	noteStepCost(os.clock() - started)
end

connection = RunService.RenderStepped:Connect(timedStep)
table.insert(connections, connection)

-- Second sampler at physics rate: a render hitch must not drop the press window.
connection = RunService.Heartbeat:Connect(timedStep)
table.insert(connections, connection)

-- The frame delta itself, straight from the physics heartbeat.
connection = RunService.Heartbeat:Connect(noteFrame)
table.insert(connections, connection)

connection = UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end

	if input.KeyCode == CONFIG.toggleKey then
		S.enabled = not S.enabled
		print("[AutoCatch] " .. (if S.enabled then "ON" else "OFF"))
	end

	if input.UserInputType == CONFIG.aimButton then
		S.aimHeld = true
	end
end)
table.insert(connections, connection)

connection = UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == CONFIG.aimButton then
		S.aimHeld = false
	end
end)
table.insert(connections, connection)

-- The Stance ack is an acceptance, not a landing. Measured over 7 acks: the
-- pressed ball's closest approach was 1.83-3.34 studs and HasBall flipped
-- 0.08-0.41 s LATER - the ack arrives about 0.11 s before contact, which is the
-- draw lag plus the round trip. `catches` counts acks because that is the only
-- server-authored event there is, but what the player sees is the ball in the
-- palm, so a landing gets its own count: HasBall rising inside the window an ack
-- leaves open. A press that is accepted and does not land shows as acks rising
-- while lands does not.
connection = LocalPlayer:GetAttributeChangedSignal("HasBall"):Connect(function()
	if LocalPlayer:GetAttribute("HasBall") ~= true then
		return
	end
	local now = os.clock()
	local times = S.ackTimes
	for i = #times, 1, -1 do
		if (now - times[i]) <= 0.6 then
			table.remove(times, i)
			S.catchLands = S.catchLands + 1
			break
		end
	end
	for i = #times, 1, -1 do
		if (now - times[i]) > 0.6 then
			table.remove(times, i)
		end
	end
end)
table.insert(connections, connection)

-- Catches are counted from the server's own answer, not from HasBall: the
-- attribute can rise and fall inside one replication interval and was reading 8
-- against 17 acknowledged catches. The FX ack is the authoritative event.
connection = LocalPlayer:GetAttributeChangedSignal("HitsTaken"):Connect(function()
	S.hits = tonumber(LocalPlayer:GetAttribute("HitsTaken")) or S.hits
end)
table.insert(connections, connection)

-- Stance payloads carry the character NAME, not the character instance, so the
-- identity test has to accept both spellings.
local function isMyModel(model)
	if model == nil then
		return false
	end
	if model == LocalPlayer.Character or model == LocalPlayer.Name then
		return true
	end
	return typeof(model) == "Instance" and model == LocalPlayer.Character
end

-- The server answers every catch press, and that answer is the only
-- authoritative word on whether a press could count. Catch arms CatchReadyAt
-- exactly the same as CatchRefused does, so the answer decides whether the next
-- 0.6 s is live. Stamps come back with millisecond rounding on the broadcast, so
-- the nearest pending press inside the refusal horizon is the match.
local function matchPress(stamp)
	if type(stamp) ~= "number" then
		return nil
	end
	local exact = S.byStamp[stamp]
	if exact and exact.outcome == "pending" then
		return exact
	end
	local best, bestGap = nil, 0.75
	for _, rec in pairs(S.byStamp) do
		if rec.outcome == "pending" then
			local gap = math.abs(rec.stamp - stamp)
			if gap < bestGap then
				best, bestGap = rec, gap
			end
		end
	end
	return best
end

connection = FX.OnClientEvent:Connect(function(kind, payload)
	if kind ~= "Stance" or type(payload) ~= "table" then
		-- Death attribution comes from the game's own events: HeartBreak names the
		-- attacker and the mechanism, Impact names the ball that landed. A life
		-- dropping without either is a prison/round event, not a hit.
		-- Server confirmation for our own throw. Predict registers the visual
		-- under our seq and the broadcast carries it back as `ref`, which is the
		-- key OnThrow looks up. Matching it here is what earns the right to leave
		-- the palm hidden; without it every throw was believed on faith.
		if kind == "Throw" and type(payload) == "table" and payload.ownerId == LocalPlayer.UserId then
			local pending = S.throwPending
			local ref = payload.ref or payload.id
			if pending and ref ~= nil and tostring(ref) == tostring(pending.seq) then
				pending.acked = true
				S.throwAcks = S.throwAcks + 1
			end
			return
		end
		if kind == "HeartBreak" and type(payload) == "table" and payload.target == LocalPlayer.Character then
			S.heartbreaks = S.heartbreaks + 1
			edge("death")
			-- The game's own account of the life: `how` is the mechanism and `by`
			-- the thrower. This is the only authoritative answer to "was the body
			-- hit by a ball or did the life go somewhere else", and the life-drop
			-- row reads it back by age instead of inferring it from deltas.
			S.deathHow = tostring(payload.how)
			S.deathBy = payload.by ~= nil and tostring(payload.by) or nil
			S.hbAt = Workspace:GetServerTimeNow()
			local hb = S.hbLog
			if #hb >= 8 then
				table.remove(hb, 1)
			end
			hb[#hb + 1] = string.format(
				"how=%s by=%s lives=%s at=%.2f",
				tostring(payload.how),
				tostring(payload.by),
				tostring(payload.lives),
				os.clock()
			)
			S.deathHow = tostring(payload.how)
			S.deathSnap = table.clone(S.hist)
			return
		end
		if kind == "Impact" and type(payload) == "table" and payload.victim == LocalPlayer.Character then
			S.hitImpacts = S.hitImpacts + 1
			local at = Workspace:GetServerTimeNow()
			S.lastImpact = {
				id = tostring(payload.id),
				at = at,
				pos = payload.pos,
			}

			-- What the client knew about the ball that landed, captured at the
			-- instant the game says it landed. Until this existed, every hit row
			-- could only describe whichever ball the tracker thought was nearest,
			-- which is not the same question - the last recorded hit had a
			-- `nocanhit,world` ball sitting 3.3 studs away and read `ball=nil`.
			-- The ball's own entry is found by id and its flight position is read
			-- off the segment, because in flight the part itself is parked in the
			-- pool far from the play.
			local function segPos(st)
				if not (st.seg and typeof(st.seg.p0) == "Vector3") then
					return nil
				end
				local t0 = st.seg.t0 or at
				local ok, p = pcall(Shared.PosAt, st.seg, math.max(at, t0) - t0)
				if ok and typeof(p) == "Vector3" then
					return p
				end
				return nil
			end

			local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
			local rootPos = root and root.Position or nil
			local killer, near = nil, {}
			local okLive, liveNow = pcall(ThrowFX.Live)
			if okLive and type(liveNow) == "table" then
				for _, st in pairs(liveNow) do
					if st.id ~= nil and tostring(st.id) == tostring(payload.id) then
						killer = st
					end
					local p = segPos(st)
					if p and rootPos then
						local d = (p - rootPos).Magnitude
						if d <= 10 then
							near[#near + 1] = string.format(
								"%s %s d=%.1f can=%s b=%s w=%s",
								tostring(st.id),
								tostring(st.kind),
								d,
								tostring(st.canHit),
								tostring(st.bounce),
								tostring(st.worldBounced)
							)
						end
					end
				end
			end

			if killer then
				local p = segPos(killer)
				S.impactInfo = string.format(
					"id=%s kind=%s can=%s b=%s w=%s fl=%s hold=%s d=%.1f",
					tostring(killer.id),
					tostring(killer.kind),
					tostring(killer.canHit),
					tostring(killer.bounce),
					tostring(killer.worldBounced),
					tostring(killer.floored),
					tostring(killer.hold),
					p and rootPos and (p - rootPos).Magnitude or -1
				)
			else
				S.impactInfo = "id=" .. tostring(payload.id) .. " noLiveEntry"
			end
			table.sort(near)
			S.impactNear = table.concat(near, " | ")

			-- The game's own impact point against this body, with no predictor in
			-- the middle. Every radius in this file is a guess about where the
			-- server draws the hit sphere; this is the measurement that replaces
			-- the guess. `payload.pos` is server-authoritative and it arrives
			-- with the impact, while the body is still standing where it stood.
			if rootPos and typeof(payload.pos) == "Vector3" then
				local d = (payload.pos - rootPos).Magnitude
				local dx = payload.pos.X - rootPos.X
				local dz = payload.pos.Z - rootPos.Z
				local horiz = math.sqrt(dx * dx + dz * dz)
				S.impactDist = d
				S.impactDistLog = S.impactDistLog or {}
				local il = S.impactDistLog
				il[#il + 1] = string.format("%.2f/%.2f/%.2f", d, horiz, payload.pos.Y - rootPos.Y)
				if #il > 40 then
					table.remove(il, 1)
				end
				S.impactInfo = (S.impactInfo or "") .. string.format(" hitD=%.2f", d)
			end
			return
		end
		return
	end
	if not isMyModel(payload.model) then
		return
	end
	if payload.kind ~= "Catch" and payload.kind ~= "CatchRefused" then
		return
	end

	local rec = matchPress(payload.t)

	if payload.kind == "Catch" then
		S.catchAcks = S.catchAcks + 1
		edge("ack")
		S.catches = S.catchAcks
		S.ackLast = os.clock()
		table.insert(S.ackTimes, S.ackLast)
		if #S.ackTimes > 8 then
			table.remove(S.ackTimes, 1)
		end
		-- The press record carries the class of the ball the press was for, so a
		-- caught ball is attributed to the population that threw it.
		tallyClass((S.pressMeta and S.pressMeta.kind) or "unknown", "catch")
	else
		S.catchRefusals = S.catchRefusals + 1
		edge("refuse")
		S.refuseLast = os.clock()
		S.refuseRec = rec
	end

	if rec then
		rec.outcome = if payload.kind == "Catch" then "caught" else "refused"
		rec.answerAt = os.clock()
		rec.answerStamp = payload.t
		rec.answerGap = payload.t - rec.stamp
	end
end)
table.insert(connections, connection)

getgenv().__autocatch = S

local function teardown()
	if S.unloaded then
		return
	end
	S.unloaded = true

	S.agentStop()
	S.aimHeld = false
	dashStop()
	stopAllImpulses()

	-- The detour stays installed for the session but goes inert, so a reload
	-- cannot stack a second one. Re-enable it by reloading the script.
	SILENT_HOOK.active = false
	pointLockOn(nil)

	for _, item in ipairs(connections) do
		pcall(function()
			item:Disconnect()
		end)
	end
	table.clear(connections)

	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.AutoRotate = true
	end

	-- Palm display. Every ball this script hid for a throw is put back: the
	-- module's own hide is undone and the client-only transparency is cleared, so
	-- an unload cannot leave an invisible ball welded to a hand. The table is
	-- weakly keyed, so a ball the game already removed has taken its entry with
	-- it and cannot be written to here.
	for part in pairs(palmHidden) do
		pcall(ThrowFX.ShowPart, part)
		pcall(function()
			part.LocalTransparencyModifier = 0
		end)
		S.palmRestores = (S.palmRestores or 0) + 1
	end
	table.clear(palmHidden)

	if gui then
		gui:Destroy()
		gui = nil
		label = nil
	end

	-- Panel last: the refresh loop above reads Fluent, so clearing it and
	-- destroying the library in the same breath stops the timer with the window.
	if Fluent then
		pcall(function()
			Fluent:Destroy()
		end)
		Fluent = nil
	end
	S.panel = nil

	if getgenv().__autocatch == S then
		getgenv().__autocatch = nil
	end
end

S.unload = teardown

if STATE and STATE.onCleanup then
	STATE.onCleanup(teardown)
end

print("[AutoCatch] v6 loaded - toggle " .. CONFIG.toggleKey.Name)
