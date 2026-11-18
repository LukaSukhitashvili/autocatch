-- AutoCatch - auto catch, dodge, sidestep and auto-throw for Prison Dodgeball.
--
-- Presses only while the game's own predictor says a ball will intersect the player's
-- capsule within CONFIG.pressLead. Timing comes from ThrowFX.catching(), which accepts a
-- press whose age at contact is inside [-0.03, +0.36], so the schedule opens early and
-- refreshes; the stamp is biased 20 ms into the past to survive a late frame.

-- Reload guard. A reload is a fresh execution of this file, so the previous instance's
-- connections, press schedule and dash would run beside the new one. The run publishes
-- `unload`; it is called first so loading is always exactly one instance.
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
-- Catch answers arrive on FX: CatchRefused is broadcast as a Stance event.
local FX = DodgeFX:WaitForChild("Remotes"):WaitForChild("FX")
local DodgeMatch = ReplicatedStorage:WaitForChild("DodgeMatch")

local CONFIG = {
	toggleKey = Enum.KeyCode.RightShift,

	-- Where the press schedule opens. A stamp older than CATCH_WINDOW at contact can never
	-- catch, and a refused press does not arm CatchReadyAt, so re-pressing is free.
	pressLead = 0.220,

	-- Ceiling on the refresh cadence; the live cadence derives from the judge window.
	pressInterval = 0.600,

	-- Timestamp skew: sent as now - bias, so a press a frame after contact still reads early.
	pressBias = 0.012,

	-- Keep pressing this long past the last prediction to cover the local bounce window.
	tail = 0.12,

	-- Detection horizon and radius, identical to IncomingWarning.
	horizon = 1.00,

	-- Turn toward a predicted hit this far out, and hold the turn for a moment.
	faceHorizon = 1.20,
	faceHold = 0.35,

	-- Point-blank net: a ball this close and closing touches regardless of the extrapolation.
	pointBlank = 4.0,

	autoFace = true,
	showLabel = true,

	-- ThrowFX.catching() answers "has a ball" while one is held, so a predicted hit throws it.
	autoThrow = true,
	throwCooldown = 0.38,
	throwRange = 170,
	throwFallback = 120,

	-- Perfect throw: solve the intercept the way the game's own hit test reads it.
	perfectThrow = true,

	-- Silent aim: rewrites the aim point on the game's own Throw remote. Camera untouched.
	silentAim = true,

	-- Also stamp the resolved enemy into the throw payload.
	silentTarget = true,

	-- Keep LockOnTarget on the current target so DodgeInput's own chooseAim agrees with the
	-- rewritten aim.
	lockOnTarget = true,

	-- Camera lock, off by default - silent aim does not need the view.
	autoAim = false,
	aimButton = Enum.UserInputType.MouseButton2,
	aimRange = 200,

	-- Re-entry throw. While eliminated the pickup throw is the player's - no wind-up, no
	-- settled aim - so this switch is off by default and governs only that path.
	autoReentry = false,

	-- One decision pass per this many seconds, shared by both samplers.
	tickInterval = 0.012,

	-- Juke: the hit test leads the body by half its flat velocity, so reversing it flips that
	-- lead away from the capsule for a frame.
	juke = true,
	jukeCooldown = 0.40,
	jukeSpeed = 26,

	-- Dash lead. throwFX judges i-frames as [dodge - 0.03, dodge + 0.26]: at 0.24 contact
	-- landed 0.02 s before the window closed and ate the hit; at 0.15 there is 0.14 s of
	-- slack either side and 9.6 studs of travel still clears HIT_RADIUS.
	autoDodge = true,
	dodgeLead = 0.150,

	-- Sidestep: with the dash on cooldown the body keeps walking out of the ball's line.
	sidestep = true,
	sideLead = 0.360,
	jukeLead = 0.120,
}

-- Numeric configuration. Every key feeds geometry, so a non-number is not a preference -
-- the comparison throws in a hot path and the tick reads like a ball that was never seen.
--
-- The UI library's Round() returns a string for any value without a decimal point, and
-- Slider:SetValue runs its callback at window creation, so a slider hands this table "1"
-- before the user touches it. Hence: coerce on write, re-assert on load, selftest row.
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

-- The write boundary: the table only ever holds a number.
local function setNumber(key, value)
	local number = tonumber(value)
	if number then
		CONFIG[key] = number
	end
end

local OUT_ATTR = Shared.ATTR.Out
local CATCH_ANGLE_COS = math.cos(math.rad(GameConfig.CATCH_ANGLE or 120))
local CATCH_RADIUS = GameConfig.BALL_RADIUS + GameConfig.HIT_RADIUS

-- The body lane reaches further than the catch lane. CATCH_RADIUS is what the catch judge
-- uses; the hit judge scores at ~3.0. Measured: miss=2.64-3.00 closing to 3.2 studs with
-- tca=0.007 took the life. Dashing a passing ball costs a dash; missing one costs a life.
local BODY_HEADROOM = 0.6
local BODY_RADIUS = CATCH_RADIUS + BODY_HEADROOM
local STEP = 0.022222222222222223

-- Dodge sizing. DODGE_MARGIN covers acceleration and the ball's draw lag; MIN_TRAVEL keeps
-- a nudge from reading as a stutter; MAX_LIFE stops a dash against a wall running forever.
local DODGE_MARGIN = 0.6
local DODGE_MIN_TRAVEL = 1.2
local DODGE_MAX_LIFE = 0.30

-- Distance the body owes along `off`. The dash replaces the body's own velocity on that
-- axis, so a body sliding away gains only (dash speed - drift) and owes more; one drifting
-- into the line owes less.
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

-- Escape side. Measured: eight directions from one spot, seven carried the body 10.4-10.6
-- studs and one carried it 0.10 - a full 0.30 s dash travelled 0.007 while the 2.2 s
-- cooldown burned. A blocked side loses to an open one in the opposite direction.
local FUNCTION_CLEAR_RADIUS = 1.6

-- Thin rays, not shape casts. A Spherecast starting flush with geometry reports no hit,
-- and one wide enough to see the wall ahead also reports the opposite side blocked, so a
-- pinned body saw both sides closed. A ray from the root centre reports the floor asked for.
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

-- Direction and clearance. The preferred side holds unless it is blocked and the other is
-- meaningfully more open.
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

-- Per-character catch window: the same source IncomingWarning reads.
local function catchWindow(character)
	local value = character and character:GetAttribute("CatchWin")
	if type(value) == "number" and value > 0.02 and value < 1 then
		return value
	end

	return GameConfig.CATCH_WINDOW or 0.36
end

-- The server publishes the next accepted catch/dash instant, so every gate reads it first.
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
	-- Per-rule tally. Every tracked ball lands in exactly one bucket, so a zero body count
	-- names the rule responsible instead of leaving it to the shape of the deaths.
	pathWhy = {},
	-- Same tally split by source. The segment source carries every ball this game throws, so
	-- its bucket says whether the body answer is alive at all.
	pathWhySeg = {},
	-- Parts held but not moving (pooled seats), kept out of pathWhy.
	pathWhyPartIdle = 0,
	contactAge = {},
	-- Tracker verdict per part. `weld_far` means a flying ball still carrying its throw weld.
	pathDrop = {},
	-- Close passes, newest last, with the raw geometry. A path count of zero over
	-- a round can only be explained by looking at what the tracker actually saw
	-- in the last metre, so this ring is the live witness.
	pathClose = {},
	-- Flight recorder: every tracked ball within 20 studs, every tick, whatever the verdict.
	pathWide = {},
	-- First sighting per ball with distance: separates never visible from always gated.
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
	-- Dash flight records, plus a travel ring so a run of dashes reads as a distribution.
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
	-- Per-class tally keyed on the ball's own `kind`, so bot throws and player throws can be
	-- compared instead of argued about.
	classTally = {},
	classLast = {},
	reject = {},
	laneReject = {},
	lastNote = LocalPlayer:GetAttribute("CatchNote"),
	pressWhy = {},
	aimHeld = false,
	aimTarget = nil,
	lockTarget = nil,
	-- Arrival race: one row at contact, naming the answer that was live and whether the
	-- server would have taken it.
	race = {},
	raceHead = 1,
	raceMax = 24,
	raceTally = {},
	raceHit = {},
	raceLast = nil,
}

local bodyCache = setmetatable({}, { __mode = "k" })

-- Movement-edge tally. No decision reads a key; what movement changes is the body's
-- velocity and who owns Humanoid:Move. Bucketing each decision by whether a key was held
-- is the only way to answer "does holding a key weaken the assist". `seen` is the
-- denominator - fewer presses only matter if the bucket also saw threats.
S.heldInput = false
S.edge = { free = {}, hold = {} }

local function edge(kind)
	local bucket = S.edge[S.heldInput and "hold" or "free"]
	bucket[kind] = (bucket[kind] or 0) + 1
end

-- HitsTaken is session-cumulative, so a reload has to seed from it.
S.hits = tonumber(LocalPlayer:GetAttribute("HitsTaken")) or 0

-- Port of IncomingWarning.timeToHit: same stepping, steering, capsule test and radius.
-- rootVel is injectable so the self-test can pin the body's velocity.
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

-- Handout filter. A sidelined player returns by taking a teammate's ball and hitting
-- someone with it; that ball arrives as a `pass` aimed at the player's feet, so any dodge
-- moves him off the only route back. Passes leave the threat set while eliminated; enemy
-- attacks still register.

-- Throw classification. `kind` is set by ThrowFX from the thrower's identity: a Player-
-- owned character is `attack`, anything else `bot`, a marked handout `pass`. Unknown
-- values keep their own name rather than being folded into an existing bucket.
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

-- One row per class. `seen` counts ticks decide() picked this class, which is comparable
-- across classes; a raw per-tick scan would just count balls.
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

-- ThrowFX.Predict takes pass=false for an attack, so any other value means a pass.
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

-- Belt and braces on the kind check: a mislabelled pass, or a teammate throw that is not
-- a pass, is still not worth moving for with no lives left to lose.
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

-- IncomingWarning's candidate filter minus the team gate: anything predicted to touch the
-- capsule is a threat, and the catch judge does not care who threw it.
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
	-- `hold` means somebody is carrying it. The catch judge refuses bounced balls, the hit
	-- test does not, so `soft` relaxes the bounce flags and nothing else.
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

-- Keyed weakly: a ball counted once is never counted twice, and dead entries are released.
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

-- Approach direction, usable when the segment has no velocity left. A stale direction
-- from another ball rejects a catch the server would have taken.
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

-- Nearest predicted-intersecting ball, its tti, travel direction, and how many candidates
-- were considered.
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

	-- Point-blank net. The predictor steps 22 ms at a time and gives up after the horizon, so
	-- an arrival between two steps reaches the capsule without a hit. Inside pointBlank the
	-- extrapolation is not needed: closing means touching.
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

-- Raw closest-approach threat. ThrowFX answers nothing for a pass or a stalled segment,
-- and both still land - the server's hit test does not consult canHit. The last 0.35 s of
-- flight is a straight line, so the ball's own motion answers it.
--
-- No longer the body's authority, but it still reports an arrival while the press
-- schedule is live and writes the audit row for a ball with no segment at all.
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

-- Physical ball path. Live() is the game's judgement model, not the set of physical
-- balls: a ball leaves it the instant it resolves, and a bounced one re-enters on a
-- segment that still extrapolates the pre-bounce line - so a ricochet arrives with
-- nothing predicting it.
--
-- The part is always there (DodgeBalls holds one per ball for the whole round), so the
-- path is tracked on the part. Velocity comes from the position delta, never from
-- AssemblyLinearVelocity: in flight that field reads 64 studs/s while the ball travels 148.
local ballPath = setmetatable({}, { __mode = "k" })

-- Fastest a ball can be observed to move. A client frame can carry two replication
-- samples, so the observation is faster than the game's throw speed; re-placements run
-- two orders of magnitude above this, so the regimes stay separated.
local PATH_MAX_SPEED =
	4 * math.max(GameConfig.PLAYER_THROW_SPEED or 140, GameConfig.THROW_SPEED or 125)

-- Fastest legal approach, used to price a ball with no measured trajectory yet.
local PATH_THROW_SPEED =
	math.max(GameConfig.PLAYER_THROW_SPEED or 140, GameConfig.THROW_SPEED or 125)

-- How close a trajectory-less ball must be to be the body's business at all.
local PATH_NEAR = 14

-- A re-placed record is a fresh answer for this long. Past it, a trajectory-less record
-- is a ball the tracker lost.
local PATH_ARRIVAL_AGE = 0.10

-- The palm as a radius: shared by the display reconciler and the tracker.
local PALM_RADIUS = 3.2
local PALM_DY = 2.5

-- The part a weld ties this ball to. The weld outlives the carry by tens of studs, so the
-- partner's position is the honest answer to "is this ball being carried".
local function weldAnchor(part)
	local weld = part:FindFirstChildWhichIsA("Weld")
	if not weld then
		return nil
	end
	local other = if weld.Part0 == part then weld.Part1 else weld.Part0
	return other and other.Position or nil
end

-- Whether a part can carry motion at all. Anchoring is not consulted: the server moves
-- every ball by CFrame and leaves it anchored, so skipping anchored parts tracks nothing.
-- Re-placements are rejected by the speed bound. Returns the weld distance so "held in a
-- palm" and "carrying a stale weld" can be told apart.
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

-- A ball that has not moved this far has not been re-sampled. Replication delivers CFrame
-- in 10-20 Hz hops, so advancing the sample clock on unchanged ticks made every hop look
-- instantaneous and rejected as a teleport.
local PATH_EPS = 0.02

-- Longest gap that still counts as a flight sample.
local PATH_MAX_GAP = 0.25

-- How long a segment may still be extrapolated after ThrowFX stops reporting the ball.
-- A bounced ball stops being reported and keeps flying: measured across four deaths, the
-- killer was dropped 0.99-1.17 s before it arrived. This is the horizon the body could
-- act inside, not a guess about the flight.
local ORPHAN_MAX_AGE = 1.6

-- One tracker step, pure: record in, record out plus a verdict naming what the step did.
-- `prev`/`dt` are written only when the ball genuinely moved, so the speed bound compares
-- like with like - 7 studs over 0.05 s is 140 and passes; the same hop over one 12 ms
-- tick is 580 and is a re-placement.
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

	-- Draw lag per part. The replicated part is drawn `state.lag` behind the path ThrowFX
	-- judges; 0.112 s is 15.7 studs at 140 studs/s, so it is added to the sample's age.
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
				-- Two refusals wearing the same clothes: a ball at a hand, and a flying ball with an
				-- uncleaned weld. The distance tells them apart.
				if holdDistance and holdDistance > PALM_RADIUS then
					drop.weld_far = (drop.weld_far or 0) + 1
				else
					drop.weld_near = (drop.weld_near or 0) + 1
				end
			else
				local rec, verdict = pathSample(ballPath[part], part.Position, now)
				-- Stored with the record: "just arrived" and "stopped being seen" are different answers.
				rec.verdict = verdict
				-- nil is correct here: a current draw has nothing to compensate for, and a stale lag
				-- would advance the ball past where it actually is.
				rec.lag = lagOf and lagOf[part] or nil
				ballPath[part] = rec
				drop[verdict] = (drop[verdict] or 0) + 1
			end
		end
	end
end

-- Will this ball pass within reach before the horizon runs out? Answered from the travel
-- between two samples, extended forward - so it holds on the first frame a ball is seen
-- and on the frame after a bounce.
--
-- Asked now, not at the sample: 20 ms of flight at 140 studs/s is 2.8 studs, more than
-- the reach radius. Both the sample age and the draw lag are advanced before anything is
-- measured.
--
-- Returns nil when the ball is receding or clears the radius, plus the rule that
-- answered, so a rejection is never indistinguishable from a ball never tracked.
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

	-- Both ages add: time since the sample and the draw lag it was taken at. Advancing by
	-- one alone read a lagged ball 15.7 studs further away than it was.
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

	-- Hold the worst miss of the last fifth of a second. A refitted segment swings hard -
	-- measured on one ball: 15.80 at 18.5 studs, 2.46 at 10.4, 1.86 at 5.3 inside 0.15 s -
	-- so the newest value is always the friendlier half of a wobbling estimate. The window
	-- ages out on its own, so a ball that passed wide stops being a threat.
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

	-- Already at the body: report it rather than re-arming a shove loop.
	if delta.Magnitude <= radius then
		return nil, miss, nil, "inside", tca, posNow
	end

	if miss > radius then
		return nil, miss, nil, "miss", tca, posNow
	end

	-- Perpendicular offset at closest approach, body toward the line: moving along `-off`
	-- clears, moving along `off` has to cross the line first. Every caller negates it.
	local cpa = delta + rel * tca
	local off = Vector3.new(cpa.X, 0, cpa.Z)
	if off.Magnitude > 1e-3 then
		off = off.Unit
	else
		off = nil
	end

	return math.max(0, tca), miss, travel.Unit, "hit", tca, posNow, off
end

-- A ball that has just re-placed has no trajectory, and the speed bound threw the hop
-- away - but it crosses the reach radius in ~80 ms, less than the next sample. Priced at
-- the game's fastest throw plus the body's own closing speed, so a body running at the
-- ball meets it sooner and one running away meets it later. Bounded by
-- PATH_ARRIVAL_AGE: past that the record is a ball the tracker lost.
local function arrivalThreat(rec, now, rootPos, rootVel, ballVel)
	if not (rec and rec.pos) then
		return nil, nil
	end

	local fresh = rec.verdict == "first" or rec.verdict == "fast" or rec.verdict == "gap"
	if not fresh or (now - (rec.t or now)) > PATH_ARRIVAL_AGE then
		return nil, nil
	end

	-- Inside the body lane's reach the question is not which way the ball is going. Measured:
	-- a world-bounced ball at 2.51 studs with a fresh sample took a life while its post-bounce
	-- velocity pointed away, so every lane answered no_sample. Contact range is contact.
	local delta = rec.pos - rootPos
	local distance = delta.Magnitude
	if distance <= BODY_RADIUS then
		return 0, delta.Unit
	end
	if distance > PATH_NEAR or distance <= 0.001 then
		return nil, nil
	end

	-- A ball not travelling toward the body is not arriving. One sample has no differenced
	-- velocity, but its segment does, so the direction is readable on the first frame.
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

	-- Same draw lag: a point-blank arrival reading 6 studs out while lagged 5 studs is here,
	-- not 43 ms away - and 43 ms is the difference between a press in time and a late one.
	local remaining = distance - (rec.lag or 0) * closing
	if remaining <= 0 then
		return 0, bearing
	end

	return remaining / closing, bearing
end

-- Segment-sourced path. The part tracker assumes motion lives on the DodgeBalls part; in
-- this game it does not. Measured over 123 throws across all four classes: the part sits
-- at the pool position (0,-500,0) for 100% of flight samples - attack 88/88, bot 9/9,
-- loose 6/6, pass 20/20. Only parts welded into a hand ever move, and those are correctly
-- refused as carried balls.
--
-- The live segment is the same line the catch predictor reads and exists for every class,
-- so when the part cannot carry the motion the segment does: same pathThreat, same reason
-- names, one extra source.
local segPath = setmetatable({}, { __mode = "k" })

-- The game's own answer for "where is this ball at time t". ThrowFX appends every segment
-- onto `state.hist` and pathAt picks the newest whose t0 has begun, so reading `state.seg`
-- can read a stale arc: measured on three deaths, the tracker had the ball 3.1-3.9 studs
-- out while the server-side Impact.pos landed 1.63-2.63 from the root.
--
-- `worldPred.real` is not a guess - ThrowFX re-anchors it from every server update, so it
-- is the newest flight line the server actually sent. `bounce.real` is the same object for
-- a model bounce, and `bounce.confirmed` says whether the client's ricochet came back.
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
	-- A predicted bounce is not a bounce. ThrowFX appends its guess to hist the moment it
	-- forecasts contact, and replaying hist replays the guess: measured on two lives, rows
	-- read `nocanhit bounce` while the drawn ball went 12.9 studs out and climbed to 19.
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

-- Arc answer: the earliest time the ball's own arc comes inside the reach radius over the
-- horizon, with the body advancing too. It never answers `past` - it only asks about the
-- next `horizon` seconds.
local ARC_STEP = 1 / 60

-- The body is a capsule, not a point. Distances used to be 3D from the humanoid root,
-- which inflates a chest-height arrival by the vertical offset: measured Impact.pos
-- landed 0.98-2.77 from the root as hits, while BALL_RADIUS + HIT_RADIUS is 2.4.
-- Clamping the ball's height into the capsule fixes the only number the hit test reads.
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

	-- Nothing in the window can close this gap: ball 95 + body 61 studs/s.
	if first > (PATH_THROW_SPEED + 60) * horizon + radius then
		return nil, first, nil, "beyond", nil, p0
	end

	local bestD, bestDt, bestPos, bestOff = first, 0, p0, nil

	-- The scan starts slightly in the past: ticks land ~11 ms apart and the ball crosses the
	-- capsule between two of them, so a forward-only scan first sees it already receding. A
	-- crossing behind `now` answers at tti 0 - the ball is here and the press still counts.
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

-- The flight line for a ball whose bounce is only a guess: worldPred.real, or bounce.real
-- for a model bounce. Extrapolated from its own t0 it passes through the body, which is
-- why this prediction is worth reading and the predicted roll is not.
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

	-- `seg.t0` is the leg's start. This used to read a bare `t0`, which is a global and
	-- therefore nil, so the leg test could never fire - the counter sat at 0 across eight
	-- runs while legSegChanged climbed.
	local legT0 = seg.t0

	-- The drawn ball is the truth. `state.ball.Position` tracked a loose ball 17.8 -> 9.4
	-- studs while the same entry's segment sat frozen at 17.7; the segment is a prediction the
	-- client keeps re-anchoring, and the last two deaths were balls it had 9.9 studs away and
	-- receding. Fall back to the arc only when there is no ball to read.
	--
	-- An unconfirmed bounce is the exception: the drawn ball then takes ThrowFX's guess while
	-- the server still has the throw coming in, so preBouncePos supplies the line the server
	-- actually sent.
	--
	-- That line is not always inbound either - measured on the next batch, src=pre rows
	-- walked 6.9 -> 14.2 studs with a `past` verdict on a ball the server hit. Whichever
	-- curve is still closing is the one that can hurt.
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
			-- Closing means the curve's own ball velocity points at the body right now. Both curves
			-- are asked the same question, and a source that cannot produce a velocity is not closing.
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
			-- Substitute only when the drawn curve stopped closing and the pre-bounce line still is.
			-- Measured: 22 src=pre rows walked away from the body (d=2.7, tca=-0.121) because the old
			-- test took pre whenever live was not closing - which is also true when both are receding.
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

	-- Which curve this sample came from.
	local src = usePre and "pre" or (provisional and "arc" or "live")

	-- Keyed on the ball's part. ThrowFX rebuilds the Live entry freely, so a record keyed on
	-- it would start over every tick and answer no_sample for the whole flight.
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
		-- A one-sample record cannot be differenced but can be priced as an arrival, and that
		-- first tick inside the reach radius is the whole point-blank case.
		return segPath[key]
	end

	rec.arcFallback = provisional
	rec.usePre = usePre
	rec.src = src
	rec.lag = state.lag or 0

	-- A new leg is a new flight. The game re-fits the segment on every bounce and re-anchor,
	-- and differencing across that jump invents travel - measured 105-157 degrees away from
	-- the old leg's direction. Restart the pair and say nothing until two samples exist.
	-- Same rule for a switch of position source: the lines are different curves.
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
		-- `first` is what arms arrivalThreat: here, and cannot be differenced yet.
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

-- A stale sample is history, not motion.
local PART_FRESH = PATH_MAX_GAP

local function partCarries(rec, now)
	if not rec or not rec.prev or not rec.dt then
		return false
	end
	return (now - (rec.t or 0)) <= PART_FRESH
end

-- One authority for "a ball is physically inbound at the body". A ball already at the
-- body is reported `inside` rather than armed again: re-arming a sidestep against a ball
-- that cannot be left behind produces a shoving loop.
local function physicalThreat(character, root, now, horizon, exempt, live)
	local rootPos = root.Position
	local localVel = root.AssemblyLinearVelocity
	local rootVel = Vector3.new(localVel.X, 0, localVel.Z)

	-- The body path goes through isCandidate in its soft form: bounce flags stay relaxed
	-- because a ball off the floor still takes a life, and handouts or friend throws while
	-- out are dropped.
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

		-- Two sources, chosen by what the record is: a live ball off its arc (ThrowFX's own hist,
		-- so bounces are the game's segments, not our guess), a tracked part off its differenced
		-- motion. Chosen per tick, because a record sampled with no drawn ball can gain a segment
		-- later - measured on three lives where the arc answered no_sample for a whole approach.
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
			-- A live ball's part record is a pool seat, so its verdict would be no_sample on the tick
			-- the life leaves. The row's track= note reads the lane that actually answered.
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

		-- The ball that re-placed inside throwing distance: no trajectory to extend, so the
		-- bearing is its own and the arrival is priced at the fastest legal throw.
		if not tti and not arcAnswered then
			-- The one-sample answer needs the ball's own direction; the segment has it.
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

		-- Measured from the advanced position, not the drawn one.
		local distance = ((posNow or rec.pos) - rootPos).Magnitude

		-- Approach events, one per ball, split by thrower: `near6` is the ball entering six
		-- studs, `answered` a stamp the judge would accept or a dash in flight, `ring` the ball
		-- reaching the judge's own contact radius.
		if rec.seg then
			local kind = rec.kind or "unknown"
			-- First sighting in studs: how far away the ball was the first tick the lane could see
			-- it, which is the only distance that answers "could we have moved in time".
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

		-- Flight recorder: every ball inside the near radius, every tick, whatever the verdict.
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

		-- Closest passes with the reason beside the geometry: a miss at 20 studs is aimed at
		-- somebody else, a miss at 2.5 is the error that lost the answer.
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

		-- Closest unexplained pass: whether balls clear by a stud or by fifty.
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
			-- Tracked but parked - a pool seat, not a ball in flight. Counted apart so pathWhy keeps
			-- its meaning.
			S.pathWhyPartIdle = (S.pathWhyPartIdle or 0) + 1
		else
			consider(part, rec, nil)
		end
	end

	-- Parts are sampled; the segment covers what parts cannot. "Carries" is movement, not
	-- membership: every ball is a member while its part sits in the pool, and measuring
	-- membership routed all of them to the blind source.
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
				-- Counted by isCandidate itself: guessing from the thrower name cannot separate a
				-- teammate from an enemy.
				S.pathWhyNotCand = (S.pathWhyNotCand or 0) + 1
			end
		end
	end

	-- The ball that leaves Live() before it arrives. ThrowFX drops an entry the instant it
	-- resolves, and one way it resolves is by landing on this body - so the last frames of
	-- the killer have no entry at all. Measured at four deaths: the part sat 507-510 studs
	-- away at the pool position while the death read track=why=no_sample.
	--
	-- The segment record is keyed on the part, so it survives the drop. Bounded by
	-- ORPHAN_MAX_AGE: a bounced ball keeps flying for up to a second after the entry is gone.
	-- No distance gate - the extrapolation is monotone, so an old record predicts a ball past
	-- the body and is refused there.
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

	-- The server enforces CATCH_COOLDOWN after every catch and publishes it as CatchReadyAt;
	-- pressing inside it is refused. The bound keeps a stale value from disabling catching.
	local catchReady = readyAt(character, "CatchReadyAt")
	if catchReady and now < catchReady and catchReady < now + 10 then
		return false, "cooldown"
	end

	return true, "ok"
end

-- The server's acceptance test for a stamp, written once: inside [-0.03, CATCH_WINDOW] it
-- catches. Every schedule decision is this call, so schedule and fallback cannot disagree.
local function inJudgeBand(stamp, contactAt, window)
	if not (stamp and contactAt) then
		return false
	end

	local age = contactAt - stamp
	return age >= -0.03 and age <= window
end

-- Refresh a stamp once it would be this far into the judge window at contact.
local PRESS_REFRESH = 0.40

-- Mirror of ThrowFX.catching(), diagnostics only: which limb would reject a press.
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

-- Arrival race classifier, pure: names which answer lost the instant the contact clock
-- reached zero, in the server's own order - i-frames, catch judge, hands, body.
--
-- dash / catch / hands / catch-cool / dash-miss / no-press / past / pred-miss.
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

-- Whether the catch covers a ball judged at `contactAt`. The stamp is not per ball -
-- ThrowFX reads one CatchPressT attribute and compares it with whichever ball arrived -
-- so the decision is stated over the stamp and the clock, not over a ball id.
local function catchCovers(stamp, contactAt, window, readyBy, refused, catchable)
	if not (stamp and contactAt) then
		return false
	end
	-- A ball the judge cannot accept is covered by no stamp. That is the difference between
	-- "a press is in flight" and "a press is in flight for THIS ball".
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

-- Which answer the contact audit records: `covered` the judge accepts, `late` a press
-- that missed the band, `nostamp` no press for this ball. The stamp is never cleared, so
-- the distinction is made on age, not existence.
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

	-- Every press is logged against the stamp actually sent, because the server answers with
	-- that same stamp. Pressing is not free: it arms CatchReadyAt whether the catch lands or
	-- not, so mapping presses to answers is the only way to see what produces refusals.
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

-- Throw: DodgeInput.doThrow's server call, minus aim assist, charge and ability branches.
-- Only fires when the hands are full and a hit is predicted.

local throwSeq = 100000

-- Cover time for the palm ball: long enough for the round trip, short enough that a
-- refused throw leaves no hole. reconcileThrow decides once THROW_ACK_WAIT passes.
local THROW_COVER = 0.6
local THROW_ACK_WAIT = 0.5

-- DodgeInput.heldBallPart: the ball welded to the right hand is the one being drawn in
-- the palm. The weld outlives the throw, so a candidate must also be AT the hand -
-- otherwise it hides a ball the player is watching fly.
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

-- Palm guard. The palm is drawn from the ball instance, not from HasBall, and it is
-- hidden with LocalTransparencyModifier - a client-only property. ThrowFX.HidePart writes
-- 1 and records an expiry that nothing in the module ever reads, so a hidden part stays
-- hidden until unrelated code touches it.
--
-- That is the ghost, and it was ours: HidePart ran on every throw for 6 s, and when the
-- server handed the same ball back to the hand it arrived already invisible while
-- HasBall was true. The old sweep only restored parts it had hidden itself.
--
-- So the palm is derived from the server's HasBall every frame: held means drawn, empty
-- means hidden. The one exception is a throw's own cover, bounded by THROW_COVER.

local palmHidden = setmetatable({}, { __mode = "k" })

-- True while a throw's own cover may legitimately hide the palm ball.
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
				-- The server says a ball is held, so the palm draws one - whatever hid it.
				if ball.LocalTransparencyModifier ~= 0 then
					ball.LocalTransparencyModifier = 0
					S.palmRestores = (S.palmRestores or 0) + 1
				end
				palmHidden[ball] = nil
			elseif inPalm and not has then
				-- Empty hands: nothing may be drawn in the palm. The test is geometric because the weld
				-- cannot identify it - a thrown ball keeps its weld downrange, and a ball left behind by
				-- a refused throw is not welded at all.
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

-- Palm watchdog: a visible ball still in the palm with no server flag is a ghost.
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

	-- The ball the server says is held may be in the hand; any other visible one is the bug.
	local held = heldBallPart(character)

	-- The old blind spot: it looked for a visible ball that should not be there and never
	-- for a ball the server says is ours, welded in the palm, drawn at transparency 1.
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
			-- A ball in the palm sits at hand height and inside the palm; a loose ball on the floor
			-- next to a standing player is not a ghost.
			if delta.Magnitude <= 3 and math.abs(delta.Y) <= 2.5 then
				found = ball
				break
			end
		end
	end

	-- The render proxy is what the player sees for a fast ball.
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

-- Who is worth throwing at: not Out, not InPrison, no Health, not InMatch, Lives 0, or
-- ProtectedUntil.
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

-- Prefer the nearest enemy the hand can actually reach, and fall back to the nearest one
-- when nobody is visible - the hands need to be free either way.

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

-- Can this target return the throw? Only three replicated facts matter: hasBall -> no,
-- out -> no, catchReadyAt in the future -> no. Everything else and the ball gets through
-- or misses. A throw into a catcher's hands is an elimination, not a miss.
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

-- Facing is not consulted: an assist snaps to face an inbound ball, so facing at release
-- says nothing about facing at arrival.
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

-- The hit test does not test the body you can see. ThrowFX.touch() asks TargetPoint for a
-- lead position: rewound on the target's own client, led by FlatVel across the view delay
-- and half a ping everywhere else, plus TargetPoint.Tested's own lead. DodgeInput.bodyTarget
-- iterates twice and leaves 1-3 studs of error at range, which is why a clean shot in the
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

	-- Fixed point: flight time depends on the aim point and the lead depends on flight time.
	-- TargetPoint.Tested already carries the lag lead, so a second one overshoots at range.
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

-- The server rebuilds the trajectory from the aim argument, so the redirect happens on
-- the argument, never on the view. One detour for the session, reused across reloads.

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
		-- Hold-only: with the button down a hand-aimed throw is redirected at the solved
		-- intercept. Auto-throw already solves its own and is left alone.
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
	-- Our own throws already leave the hand aimed at a solved intercept, so re-solving them
	-- only adds a second answer. The detour is for throws the player aimed by hand.
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
	-- Our cooldown, not the server's. Holding a ball is the one state where no catch is
	-- possible, so an urgent call skips it.
	if not urgent and (now - S.lastThrow) < CONFIG.throwCooldown then
		return false
	end

	-- The server owns HasBall. A throw without it is a local-only ghost: the client plays the
	-- wind-up, nothing moves on the server, and nothing can be hit with it.
	if LocalPlayer:GetAttribute("HasBall") ~= true then
		return false
	end

	-- A sidelined player throws to get back in, and the server judges that throw like any
	-- other, so it is not gated here. `requireTarget` is the caller's refusal to waste it.
	local myTeam = character:GetAttribute("Team") or LocalPlayer:GetAttribute("Team")
	local target = nearestEnemy(character, myTeam, root.Position)
	local targetRoot = target and target:FindFirstChild("HumanoidRootPart")

	-- Never throw into a catcher - it comes back as the elimination. A safe recipient holds a
	-- ball or is still on cooldown; with nobody safe the ball goes downrange, which still
	-- frees the hand and gives the enemy nothing to catch.
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

	-- Registered before the remote fires: the server's ack can land on the next frame, and
	-- anything that yields in between leaves the ack with nobody to match.
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

	-- The client half of the throw, same calls and order as doThrow. Without it the client
	-- keeps drawing the welded ball and a second throw can fire against a ball already gone.
	pcall(function()
		DodgeAnims.Stop(character, "ThrowWindup", 0.03)
		DodgeAnims.Stop(character, "HoldBall", 0.05)
		DodgeAnims.Play(character, "Throw", { fadeIn = 0.03, fadeOut = 0.15 })
	end)

	-- No HidePart here: it hides a part nothing ever shows again, which is how a ball the
	-- server handed back came back invisible. The palm is drawn from HasBall alone.
	if held then
		S.thrownPart = held
		S.thrownAt = now
	end

	S.throwVisual = okPredict and predicted or nil

	S.lastThrow = now
	S.throws = S.throws + 1
	return true
end

-- Throw reconciliation. A throw is display-only until the server acks it: accepted reuses
-- the prediction, refused or dropped means a phantom throw followed by an empty hand
-- holding a real ball.
--
-- So if THROW_ACK_WAIT passes with no ack and the ball is still welded in the palm, the
-- prediction is stopped and the part shown again.

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

	-- Still welded and still inside the palm means the server never took the ball: the throw
	-- did not happen. Anything else means it left and the cover should expire on its own.
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

-- Two surfaces, one job each: a glanceable HUD line and a control panel. Every control
-- writes straight into CONFIG and the live state, so the panel cannot drift from the
-- assist. Fluent is loaded through pcall - a missing library must not take the catch and
-- dash down with it.

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

-- One summary string from the same counters the diagnostics read, so the HUD and the
-- panel cannot tell different stories.
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
		-- Off on purpose: acrylic re-blurs the game every frame.
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

	-- Every control is registered with the state it owns and read back by S.panelBindings().
	-- A toggle wired to a key nobody reads looks identical from the outside.
	local bindings = {}
	local function bind(id, element, get)
		bindings[#bindings + 1] = { id = id, element = element, get = get }
	end

	-- A paragraph's text is written once, so the live line lives in the label underneath.
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
							-- Deferred: this runs inside the library's own dialog callback, and unload destroys the
							-- library.
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

	-- Handle for diagnostics, so a report can read back what the controls are set to.
	S.panel = { lib = lib, window = Window, failed = nil, bindings = bindings }

	-- Slow refresh, independent of the decision loop: 4 Hz against a 12 ms tick.
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

	-- Snap, don't lerp: at point blank the server reads the replicated root at contact.
	root.CFrame = CFrame.lookAt(root.Position, root.Position + incoming)
	S.turns = S.turns + 1
end

-- Movement impulse. A Humanoid:Move write and an AssemblyLinearVelocity write are both
-- overwritten by the next WalkForce step - fine while the player stands still, useless the
-- moment a key is held. The game's own dash is a Plane LinearVelocity constraint and that
-- is the mechanism that holds, so every evasion uses one. One slot per owner: a new
-- impulse replaces the old one and carries its own lifetime.
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

-- The dash owns the body while its constraint is alive. Overlapping Plane constraints do
-- not add, they argue: measured over 52 dash frames, dashes travelled 0.02, 0.74, 3.66,
-- 6.20 or 9.81 studs depending on the overlap, one of them 3.17 studs backwards.
local function dashLive()
	local velocity = S.dashVel
	if not velocity then
		return false
	end
	-- A constraint whose attachment has left the body is a corpse - death, respawn, teleport.
	-- Without this the handle stays non-nil and every later sidestep is refused by a dash
	-- that no longer exists.
	local attachment = S.dashAtt
	if not attachment or not attachment.Parent then
		S.dashVel = nil
		S.dashAtt = nil
		return false
	end
	return true
end

-- The hit test leads the target by half its flat velocity across the view delay plus half
-- a ping: at 24 studs/s and 70 ms that is ~2.3 studs, most of the capsule. Standing still
-- removes that lead. Only fires when a catch cannot happen anyway.

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

	-- Kill the forward motion the hit test extrapolates, then shove sideways. A constraint
	-- rather than a velocity write for the same reason as the dash: WalkForce rewrites the
	-- velocity from the player's input on the next frame.
	if escape.Magnitude > 0.01 then
		applyImpulse(root, "juke", escape.Unit, CONFIG.jukeSpeed, 0.12)
	end

	S.lastJuke = now
	S.jukes = S.jukes + 1
	return true
end

-- Sustained sidestep. A juke is one shove; with the dash on its 2.2 s cooldown the
-- remaining answer is to keep walking out of the line. Humanoid:Move holds every frame
-- and costs nothing the hit test can punish - half of 22 studs/s over 0.3 s is 3.3 studs.
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

	-- Eliminated bodies do not step. The walk to the re-entry ball is the only movement that
	-- matters in that state, and the assist kept shoving the body off the pickup.
	if character:GetAttribute(OUT_ATTR) == true then
		S.sideOut = (S.sideOut or 0) + 1
		return false
	end

	-- Movement input no longer refuses the sidestep. It used to, so every evade was skipped
	-- the moment the player touched WASD - exactly when a ball is hardest to see. The step
	-- now rides the player's own drift instead of fighting it.

	local flatDir = dir and Vector3.new(dir.X, 0, dir.Z)
	if not flatDir or flatDir.Magnitude < 0.01 then
		return false
	end

	local side = flatDir.Unit:Cross(Vector3.new(0, 1, 0))
	if side.Magnitude < 0.01 then
		return false
	end

	-- Keep the side the body is already drifting toward so two threats in a row do not cancel
	-- out - unless the predictor knows which side of the line the body is on.
	local vel = root.AssemblyLinearVelocity
	local flatVel = Vector3.new(vel.X, 0, vel.Z)
	local unit = side.Unit
	local away = off and Vector3.new(off.X, 0, off.Z)
	if away and away.Magnitude > 0.05 then
		-- `off` is body-toward-line, so the step is `-off`. The old test agreed the unit WITH
		-- `off`: measured over 11 sidesteps, dot(sideDir, off) was positive on 8 and never
		-- negative, and every miss it produced sat inside the reach radius.
		unit = -away.Unit
	elseif flatVel.Magnitude > 1 and unit:Dot(flatVel) < 0 then
		unit = -unit
	end

	-- One committed side per approach. `off` swings as the geometry moves, and re-picking a
	-- side from it on every re-arm is what made the body shuttle instead of stepping once.
	if ball and S.sideBall == ball and S.sideUnit and (now - (S.sideStamp or 0)) < 0.8 then
		unit = S.sideUnit
	else
		S.sideBall = ball
		S.sideUnit = unit
		S.sideStamp = now
	end

	-- The hold. Humanoid:Move keeps the animation honest; the constraint is what travels
	-- while a key is held. Walk speed, not dash speed - this is a step out of the line.
	local hold = math.clamp((tti or 0.2) + 0.10, 0.14, 0.45)
	local walk = humanoid.WalkSpeed > 0 and humanoid.WalkSpeed or 22
	local speed = math.clamp(walk, 8, GameConfig.DODGE_SPEED or 64)

	-- A step into a wall is not a step: same probe as the dash, over the distance this hold
	-- will cover.
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

-- Dodge. The catch judge refuses everything for 0.6 s after a catch lands, so the server's
-- own DODGE_IFRAMES (0.26 s) is the only thing that stops a second ball.
--
-- The impulse is a Plane LinearVelocity constraint exactly as DodgeInput.doDodge builds
-- it, not a one-shot velocity write: the constraint holds against the movement controller
-- for the whole DODGE_TIME, so the dash is real on every client that reads the root.

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

	-- doDodge's own gate: a dash outside a live round is refused and would desync
	-- S.lastDodge from the game's.
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

	-- The server publishes the dash cooldown on both the player and the character. A dash
	-- inside it grants no i-frames and must not write S.lastDodge - that is the only record
	-- of a dash the server actually accepted.
	local dashReady = readyAt(character, "DashReadyAt")
	if dashReady and now < dashReady and dashReady < now + 10 then
		S.dashRefused = (S.dashRefused or 0) + 1
		why.cooldown = (why.cooldown or 0) + 1
		return false
	end

	-- Local record of the last accepted dash. A refusal here means it drifted from the
	-- published attribute, which is its own counter.
	if (now - S.lastDodge) < (GameConfig.DODGE_COOLDOWN or 2.2) then
		why.cadence = (why.cadence or 0) + 1
		return false
	end

	local vel = root.AssemblyLinearVelocity
	local run = Vector3.new(vel.X, 0, vel.Z)
	local dir

	-- Sideways across the ball line beats straight back: it also slides out from under the
	-- hit test's velocity lead. `off` is body-toward-line, so the dash goes along `-off` -
	-- stepping along `off` has to cross the line before it clears anything. The body's drift
	-- is only the tie-break.
	local flat = ballDir and Vector3.new(ballDir.X, 0, ballDir.Z)
	if flat and flat.Magnitude > 0.01 then
		local side = flat.Unit:Cross(Vector3.new(0, 1, 0))
		if side.Magnitude > 0.01 then
			dir = side.Unit
			local away = off and Vector3.new(off.X, 0, off.Z)
			if away and away.Magnitude > 0.05 then
				-- The old sign agreed the dash WITH `off`: measured at miss=0.97, it owed 2.03, crossed
				-- the line and finished 1.06 studs on the far side, still inside the reach radius.
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

	-- How far the dash travels is a property of the ball: the distance to clear the reach
	-- radius plus margin, corrected for the drift the dash takes away.
	local need = dashOwed(miss, off, run, speed)

	local target = math.max(need, DODGE_MIN_TRAVEL)
	local cap = speed * DODGE_MAX_LIFE
	if target > cap then
		target = cap
	end

	-- Probe both sides before the anim is picked, so the animation matches the direction the
	-- body actually travels.
	local probe, room = freeSide(character, root, unit, target)
	if room and room < DODGE_MIN_TRAVEL * 0.4 then
		-- Both sides closed: keeping the 2.2 s cooldown beats a dash that moves 0.03 studs.
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

	-- Distance-gated, not time-gated. A wall-clock tear-down lost up to a stud at 30 fps and
	-- gained one at 144; the gate reads the body's own position and trims the final frame.
	--
	-- The landing is the handback: the constraint erased whatever the key was doing, so the
	-- held direction is restated in the same function that releases it.
	local startPos = root.Position
	local travelled = 0
	local elapsed = 0
	local landed = false

	-- Both are written by the per-frame gate and read by land(), so they must be declared
	-- before it: a local declared below a closure is a global inside it and reads nil.
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

		-- Flight recorder: is the handle still ours, is the constraint still parented, what is it
		-- asking for, and how fast does the body think it is going.
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

-- Single entry point for every branch where catching cannot happen before the ball
-- arrives. The dash is the only thing that stops the hit, so it is spent first.

local function evade(character, root, dir, now, tti, src, sideAt, miss, off, ball)
	if not S.enabled or not tti then
		return false
	end

	-- Decision recorder. A death row says which lane armed the body but not why it declined -
	-- and a hit answered `hit` at 0.128 s with a 2.37 stud miss looked identical to evade
	-- never being called.
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

	-- Armed on capability, not a fixed lead: tti >= owed / speed. A fixed lead fired too late
	-- on a 140 studs/s throw (tca 0.053, 3.4 of 5.3 studs owed) and too early on slow ones.
	local speed = GameConfig.DODGE_SPEED or 64
	local owed = dashOwed(miss, off, root.AssemblyLinearVelocity, speed)
	local lead = math.max(CONFIG.dodgeLead, owed / speed + 0.02)
	local leadTxt = string.format("lead=%.2f owed=%.2f", lead, owed)

	if tti <= lead then
		-- A handout is a ball thrown AT this body to be caught, not at it to be dodged. Gating on
		-- `kind == pass` stopped 8 of 21 dashes being burned on handouts; the free sidestep below
		-- still covers a mislabelled inbound pass.
		--
		-- The test is `kind` and nothing else. isHandout also accepts passTarget/handout, which
		-- are populated on ordinary attack entries too: gating on it dropped attack dashes from
		-- 19 to 2 and lives rose from 3 to 12 in the batch after.
		if ball and ball.kind == "pass" then
			note("dash-handout", leadTxt)
		elseif dodge(character, root, now, dir, src, miss, off) then
			note("dash", leadTxt)
			return true
		else
			note("dash-refused", leadTxt)
		end
	end

	-- The dash is unavailable, so walk out of the line for as long as the ball stays inbound.
	-- A step already in flight owns the body until its hold ends: without this the 0.10 s
	-- re-arm fired two or three times inside one hold, which is the shove that reads as
	-- "keeps pushing me".
	if S.sidestepUntil and now < S.sidestepUntil then
		edge("holdBlock")
		-- A body lock, not a threat lock: a second ball arriving sooner still has to be answered.
		if ball and S.sideBall and ball ~= S.sideBall then
			edge("starve")
			note("hold-other", leadTxt)
		else
			note("hold-same", leadTxt)
		end
		return true
	end

	-- Armed on the distance the step owes, not a fixed lead: the full 1.0 s horizon armed the
	-- step a second out and kept re-arming it for the whole approach.
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

-- Dodge sizing for the decide() lane. decide() returns an arrival time, not a miss, so the
-- geometry is taken from the same pathThreat the physical answer uses, and only when the
-- cached ball is the one being dodged. The alternative is a fixed-length dash whose side
-- was chosen by drift - which is how a dash steps into the line it meant to leave.
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

-- One line describing the last ball inside NEAR_RADIUS, so a death reads as "the gate
-- refused it" or "the ball was never there".
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

-- Frame budget: the frame delta is the game's own hitch, the per-tick cost is ours. Kept
-- as short rings so a report can state both as numbers.
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

	-- Assist movement authority. Humanoid:Move is one slot and the auto-play agent writes it
	-- from its own 20 Hz loop, so a step issued once moves one frame in three - not enough
	-- lateral travel to leave the catch radius. While a sidestep is live this holds the
	-- direction every tick.
	local sideDir = S.sideDir
	if S.sidestepUntil then
		local clock = Workspace:GetServerTimeNow()
		if clock < S.sidestepUntil and sideDir then
			humanoid:Move(sideDir, false)
		else
			-- What the sidestep actually bought, in studs: a step competing with another writer
			-- measures near zero however many times it was issued.
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
	-- The exact volume the hit test uses, refreshed every tick: the volume is an anisotropic
	-- capsule, and a horizontal clearance says nothing about a ball at head height.
	S.lastBody = body

	-- Read once. `state.lag` is how far behind the drawn part is, and that belongs on the
	-- sample the tracker stores.
	local live = ThrowFX.Live()

	-- Physical ball track. Runs before any predictor so every one of them reads a
	-- path sampled on this tick. It is the only input that survives a ball leaving
	-- Live(), a bounce, or a pool round trip.
	trackBalls(now, live)

	-- The palm is reconciled against the server's HasBall every tick.
	sweepThrown(character, now)
	reconcileThrow(character, now)
	watchPalm(character, now)

	-- Shared tick counter: every live copy bumps the same global, so its rate proves how many
	-- copies are running - one instance at 12 ms reads ~83/s.
	getgenv().__acTicks = (getgenv().__acTicks or 0) + 1

	-- Eliminated: the only ball that matters is a teammate's pass, and dodging one costs the
	-- ride back onto the field.
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

	-- Near-ball record. Everything the predictor reasons about lives on `state.seg`, and a
	-- ball with no segment - unarmed, or already dropped by ThrowFX while still in the air -
	-- is invisible to decide() and to the point-blank net. That is the shape of a close-range
	-- hit, so the nearest ball's numbers are kept every tick and read back on a death.
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

	-- The watched ball left Live() while already inside the near radius: ThrowFX stopped
	-- predicting it, it did not go anywhere.
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

	-- The old contact press lived here and never fired once in 25 623 frames: a ball close
	-- enough to be contact still carries a segment, and any segment predicting a hit is
	-- already returned by decide(). The raw net below covers the real gap.

	-- The physical threat is read every tick, before the gate. Reading it inside the gate
	-- would make "the catch had it" and "the ball was never detected" report the same way.
	--
	-- Read above the contact clock, not after it: a ball only the segment lane could see used
	-- to publish `hit@seg d=3.6 tca=0.024` for three ticks while the death row read
	-- `ball=nil tti=-`. Both lanes now feed one clock.
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

	-- Raw fallback for anything the segment predictor refused - a pass, a ball off the world,
	-- a segment ThrowFX stopped advancing. Computed before the history, spent after the catch.
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

	-- Per-frame threat history at quarter rate: forty rows hold the ~2.5 s a hit is decided
	-- in, written as text so a snapshot needs no serialiser.
	S.histClock = S.histClock + 1
	if S.histClock % 4 == 0 then
		local hist = S.hist
		if #hist >= 40 then
			table.remove(hist, 1)
		end
		local catchReady = readyAt(character, "CatchReadyAt")
		local dashReady = readyAt(character, "DashReadyAt")

		-- Whether the predictor had a record for the ball the game calls nearest, and what it
		-- answered: without it the history shows a ball 1.2 studs away and a body that did
		-- nothing, with no way to tell never-sampled from sampled-and-refused.
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

	-- Contact clock. ThrowFX drops a ball from Live() the instant it resolves, so the last
	-- frames before impact often have no segment - and that gap is where the catch is decided.
	--
	-- The segment and physical lanes are two views of the same ball and only one used to
	-- reach this clock. Whichever answers soonest is the ball about to arrive, so the clock
	-- takes the sooner of the two and both lanes feed one schedule.
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

	-- The bearing the clock runs on: judgePress and the facing turn read it, and a physical
	-- answer carries its own. Without it the press is scheduled for a ball the body is not
	-- looking at, which the judge refuses on the cone alone.
	if not dir and clockDir then
		dir = clockDir
	end

	-- A direction left over from the previous ball can read as "facing away" and spend a dash
	-- on a catch that was available.
	local key = best or S.contactBall
	local effDir = dir
	if not effDir and S.lastDirBall == key then
		effDir = S.lastDir
	end

	-- Arming horizon: a stamp is only worth sending if it is still inside the judge window at
	-- contact, so the schedule opens a full window early. Insurance is free - a refused press
	-- does not arm CatchReadyAt. The refresh below keeps the newest stamp young.
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

	-- Contact audit, once per ball at contact: would the judge have accepted a catch on the
	-- ball that just arrived? `catchCovers` is the same predicate the fallback uses, so the
	-- audit cannot disagree with the decision it audits. covered / late / nostamp.
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
		-- `late` has to mean a press that missed the band, not a stamp left over from an earlier
		-- ball. The stamp is never cleared, so a naive test labelled a ball that was never pressed
		-- for as late by however long the round had run - measured at 14.7 s.
		local stampAge = (S.contactAt and S.pressStamp) and (S.contactAt - S.pressStamp) or nil
		local verdict = contactVerdict(covered, stampAge, window)

		-- The same verdict, split by who threw the ball. A round where `covered` is
		-- high for bots and `nostamp` is high for players is a round where the
		-- player class is arriving before the schedule can arm it, which is a
		-- different fault from the schedule refusing it.
		tallyClass(classOf(auditBall), "contact")
		tallyClass(classOf(auditBall), verdict)

		-- How late is late: tens of milliseconds is a refresh one frame early, hundreds is a press
		-- aimed at a different ball.
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

	-- Raw contacts: no segment, so the schedule could not arm it and the body is the only
	-- answer. Counted apart so a point-blank hit reads as exactly that.
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

	-- Death log. Lives dropping is not the same question as a hit landing: the game shifts
	-- Lives on round state (prison, elimination, round start) as well as on damage. Measured
	-- over three drops: HitsTaken=1, HitImpactUndone=1, MatchOuts=2 - two hits for three
	-- drops, so at least one was a round shift.
	--
	-- There is no HitNotSeen attribute on this game's player; the counters that exist are
	-- HitsTaken, HitImpactUndone and HitThrows. `taken` (HitsTaken delta) is the only column
	-- that means damage, and a drop with no delta is tagged `shift`.
	local lives = tonumber(LocalPlayer:GetAttribute("Lives"))
	local hitsTaken = tonumber(LocalPlayer:GetAttribute("HitsTaken"))
	-- Prime the deltas on the first tick with a value: HitsTaken is persistent - it read 1 on
	-- a fresh join - so a delta against nil is zero and the first real hit is tagged `shift`.
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
		-- The game's own death event outranks the delta: a bot's ball took a life with `taken=+0`
		-- while `how=Hit by=Bot` sat on the same row.
		local howText = tostring(S.deathHow or "")
		if not wasHit and S.hbAt and (now - S.hbAt) <= 0.5 and howText:lower():find("hit", 1, true) then
			wasHit = true
		end
		if wasHit then
			S.heartbreaks = (S.heartbreaks or 0) + 1
		end
		local dashReady = readyAt(character, "DashReadyAt")
		local catchReady = readyAt(character, "CatchReadyAt")

		-- What the tracker knew about the ball the game called nearest, asked when the life left.
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
				-- STALE marks a record the tracker stopped updating while the ball was still near.
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

		-- Resolve this life against the arrival ring: an arrival within 0.45 s is the ball that
		-- took it, and the verdict says which answer lost the race.
		local raceNote = "-"
		local hit, hitAge = raceResolve(S.race, S.raceHead, S.raceMax, now, 0.45)
		if hit then
			raceNote = string.format("%s@%.3f", hit.verdict, hitAge)
			S.raceHit[hit.verdict] = (S.raceHit[hit.verdict] or 0) + 1
		end

		-- Which population took the life - the death row already answers whether there was an
		-- answer.
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

		-- The ball the game says landed, only when the Impact event is recent enough to be this
		-- drop.
		if S.impactInfo and S.lastImpact and (now - (S.lastImpact.at or 0)) <= 1.5 then
			log[#log] = log[#log] .. " imp[" .. S.impactInfo .. "]"
			if S.impactNear and S.impactNear ~= "" then
				log[#log] = log[#log] .. " airborne[" .. S.impactNear .. "]"
			end
		end

		-- The flight recorder's last second, verbatim: the only copy of what was visible.
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

	-- Decision trace: the last two seconds in a ring, so a hit is debuggable from the frames
	-- before it.
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

	-- Silent aim plumbing: the shot is redirected on the remote, so this only keeps the
	-- game's own target mirror and diagnostics current.
	if CONFIG.silentAim then
		local holding = LocalPlayer:GetAttribute("HasBall") == true
		if holding or S.aimHeld then
			local target = nearestEnemy(character, myTeam, root.Position)
			S.lockTarget = target
			pointLockOn(target)
		end
	end

	-- Optional camera lock, off by default.
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
			-- A new ball means a new press budget. The decayed clock keeps the same key after the
			-- segment disappears, so the budget is not reset in the last frames of the same ball.
			local key = best or S.contactBall
			if key ~= S.pressBall then
				S.pressBall = key
				S.pressCount = 0
				S.pressStamp = nil
				S.threatBalls = S.threatBalls + 1
			end

			local why = judgePress(character, root, effTti, effDir, now)
			edge("why_" .. tostring(why))

			-- The press schedule is an invariant over the judge window, not a count: at contact the
			-- newest stamp must be no older than CATCH_WINDOW and no newer than the tolerance. Both
			-- ends are compared on the predicted contact time, so a ball that bounces or drops out of
			-- Live() cannot strand a stamp outside the band.
			--
			-- A ball with no stamp of its own is armed on the frame it becomes catchable; the cadence
			-- exists to stop re-stamping the same ball, not to make the next one wait.
			local contactAt = effTti and (now + effTti) or nil
			local cadence = math.max(0.10, math.min(CONFIG.pressInterval, window * 0.35))
			-- Keyed on the ball, not on the stamp being nil, so a key that flickers inside the same
			-- ball cannot turn every tick into a press.
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

			-- The server already refused this ball. It arrives a ping after the press, so the ball is
			-- usually still in the air: stop pressing and become a body.
			if S.refusedBall == key and (now - (S.refusedAt or -99)) < 0.35 then
				S.pressWhy.veto = (S.pressWhy.veto or 0) + 1
			elseif why == "facing" then
				-- Outside the catch cone. The server judges the angle on the replicated root, so turning
				-- and pressing in the same frame presses with a turn it has not seen yet: turn now, press
				-- next tick, and only give up the catch when contact is too close for a turn to arrive.
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

				-- What the press was reasoning about, recorded before the send.
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
				-- The stamp already in flight is inside the band, so nothing is spent here - this used to
				-- dash, burning a 2.2 s cooldown on balls the catch had already answered.
				S.pressWhy.blocked = (S.pressWhy.blocked or 0) + 1
			end
		elseif reason == "holding ball" then
			S.blocked = S.blocked + 1

			-- Hands full is the only state where a catch is impossible by rule. The throw used to
			-- fire on every inbound ball: the 300 s audit showed four of five lost lives were
			-- "Caught by <name>" - our own throw taken by an enemy. So it is spent only when the
			-- dash cannot save us. Not while sidelined: there the ball in hand is the re-entry pickup.
			--
			-- Two faults came from reading "can the dash save us" as a question about the hands:
			--
			--   1. `dashReady` was trusted raw. The server publishes a far-future timestamp in states
			--      where the action is not allowed, carrying a ball among them, so `dashReady > now`
			--      read true for the whole hold and the dash looked unavailable from the pickup on.
			--   2. `pressing` is armed by any ball predicted inside the CATCH window - a schedule
			--      horizon, not an imminent hit - and the frame a pickup welds the ball to the hand is
			--      one of those ticks.
			--
			-- The branch now tests this ball on this tick, on the same clock and lead the dash uses,
			-- and refuses to name the ball already in the hand as the threat.
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

			-- Clearing the palm costs a round trip before CatchReadyAt is even consulted, so a ball
			-- inside the dash lead cannot be answered by a catch - move instead. effTti survives the
			-- frames where ThrowFX has dropped the ball and tti has gone nil.
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
			-- Whether this ball can still be caught is decided from the stamp and the published
			-- CatchReadyAt; a dash spent here would be spent on balls the previous press already
			-- catches, which is how the dash budget ran out.
			--
			-- This window is where every death in live play happened, and a walk-speed step here was
			-- measured and made it worse: 91 steps in 152 s, then 224 in 228 s, and the death count
			-- rose from 1 per 152 s to 4 per 380 s. Counted, not acted on.
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

	-- The body answers whenever the catch cannot, and the test is the judge's own: is the
	-- stamp for this ball still inside the window at the contact time it will be judged, and
	-- is CatchReadyAt already past?
	--
	-- Decided by the stamp, not by canPress: canPress goes false the moment a previous catch
	-- arms CatchReadyAt, so a ball that already had a valid stamp was treated as uncatchable.
	-- That is where the dash budget went - 20 catches and 24 dashes in a 300 s round.
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

	-- Per-ball veto. `catchInFlight` answers "did we press for the ball decide() picked", not
	-- "is the arriving ball covered", and treating it as if it did stood the body down for
	-- every other ball - ricochets and nocanhit balls the judge refuses by construction, whose
	-- only possible answer is the body.
	--
	-- The veto now stands only if the press would be accepted for THIS ball at ITS contact
	-- time.
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
		-- The body answer reads the physical path, not Live(): a ricochet has no segment
		-- predicting a hit, and a ball already resolved by the judge has left Live() entirely.
		-- The part is never invisible.
		--
		-- Full horizon for the sidestep - the catch is ruled out, so every extra tenth is 1.6
		-- studs of travel and the only cost is walking. The lead derives inside `evade` from the
		-- distance owed; passing a horizon armed the step a whole second early.
		--
		-- One case gets a longer lead on purpose: a ball landing before CatchReadyAt re-arms.
		-- Judge refuses, dash is on cooldown, so the step starts early - the "lost a life right
		-- after a catch" shape, measured at catchIn +0.15..+0.43 and dashIn +1.3..+1.5.
		if phTti then
			S.pathOpen = (S.pathOpen or 0) + 1
			S.dashBall = phState
			local catchBy = readyAt(character, "CatchReadyAt")
			local sideAt = (catchBy and (now + phTti) < catchBy) and 0.40 or nil
			local evaded = evade(character, root, phDir, now, phTti, "path", sideAt, phMiss, phOff, phState)
			if evaded then
				S.pathJukes = (S.pathJukes or 0) + 1
			end
			-- The body answer's own ring: a death at 5 studs with a perfect hit answer and no action
			-- is either "evade declined" or "this ball was never handed to it", and the two need
			-- different fixes.
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

	-- Return to the field: while eliminated a ball in hand is the route back in, and that
	-- throw is the player's - a chosen target, on a wind-up. Opt-in via CONFIG.autoReentry.
	if out
		and CONFIG.autoThrow
		and CONFIG.autoReentry
		and LocalPlayer:GetAttribute("HasBall") == true
		and (now - S.lastThrow) > 1.5
	then
		throwHeld(character, root, now, true)
	end

	-- CatchNote is the only refusal channel - CatchRefused is never broadcast on FX, so the
	-- event-based counter read zero forever.
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

-- Ring read-out, oldest first: which reason was live, whether a press was already spent
-- on that ball, and whether either server gate was closed.
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

-- Test agent: drives the character so a round can be measured without a human. Movement
-- goes through Humanoid:Move, which replicates like stick input - no synthetic keys, no
-- teleports, no CFrame warps.

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

-- What the physical track holds right now and what the body answer reads off it.
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

-- Ghost check: the visible display judged against the server's own HasBall, both
-- directions - the old watchdog only watched one and reported zero while the other was
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

-- Press-schedule sweep: one question per profile - is a stamp inside the judge band at
-- the instant of contact? The profiles are the ones that lose lives: first seen at point
-- blank, first seen inside the old 0.22 s lead, and a second ball a frame after a press.
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

-- Physical-path sweep over the trajectories that decide a life - head-on, point-blank,
-- the frame after release, the frame after a bounce - plus the ones that must stay silent.
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

	-- Arrival cases: a ball re-placed next to the body has one position and no trajectory,
	-- which is the shape that answered no_sample on every tick while crossing the reach radius.
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

	-- Part-selection cases. Every ball in DodgeBalls is anchored and CFrame-driven, so a
	-- tracker that skips anchored parts tracks nothing while the balls fly past.
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

	-- Sampling cases: a ball replicated in hops, and a hop whose delta was compared against
	-- one tick instead of the true interval. Both produced a nil path on every tick.
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

-- Segment-source cases. The part tracker cannot answer for any ball this game throws, so
-- these drive a ball with no part at all - the live shape - and require the same verdicts
-- from the player-thrown and bot-thrown copy of the same geometry.
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

	-- The routing bug that kept the segment source silent: `covered` tested tracker
	-- membership, and a pooled part is always a member, so every ball went to a source that
	-- cannot see it. A record with no distinct second position is a parked seat.
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

	-- The seam the reported bug lived at. Everything above drives pathThreat directly, which
	-- proves the predictor understands a segment but not that physicalThreat ever asks it -
	-- and that gate is where the failure was: a test that calls the predictor can never go
	-- red on a routing bug in its caller.
	--
	-- So these drive physicalThreat with the live shape - part parked in the tracker, motion
	-- on the segment - and require the same answer from both populations. The last two cases
	-- are the other direction: a part that really carries the ball, and a ball with no
	-- segment, must not be answered here or the fix becomes a dodge at everything.
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

	-- Hermetic: with live balls in the tracker a fixture could be answered by somebody
	-- else's ball. The tracker is saved, emptied, exercised and restored, all without yielding.
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

		-- The class split: the same geometry must produce the same decision whether the game
		-- called the throw a bot throw or a player throw. These two cases go red if that stops
		-- being true.
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

	-- Contact-audit classification. The audit's history read a 14.7 s old stamp as a late
	-- press, turning "never armed for this ball" into "a few frames behind". Pinned at the
	-- boundary.
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

	-- Class attribution. Every tally is keyed on classOf, so a wrong answer here silently
	-- moves one population's numbers into another's row.
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

	-- Body-path cases: the catch judge refuses a bounced or nocanhit ball, the hit test does
	-- not, so each must stay invisible to the catch decision and visible to the body one.
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

	-- Configuration types. A string here throws in a hot path and a ball that was seen reads
	-- as a ball that was never seen. One row per key, so a report names the exact one.
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

-- The Stance ack is an acceptance, not a landing: measured over 7 acks, the pressed
-- ball's closest approach was 1.83-3.34 studs and HasBall flipped 0.08-0.41 s LATER.
-- `catches` counts acks because that is the only server-authored event; a landing is
-- HasBall rising inside the window an ack leaves open.
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

-- The server answers every catch press. Catch arms CatchReadyAt exactly as CatchRefused
-- does, so the answer decides whether the next 0.6 s is live. Stamps come back with
-- millisecond rounding, so the nearest pending press inside the horizon is the match.
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

			-- What the client knew about the ball that landed, captured when the game says it landed.
			-- Found by id and read off the segment: in flight the part itself is parked in the pool.
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

			-- The game's own impact point against this body, with no predictor in the middle. Every
			-- radius in this file is a guess about where the server draws the hit sphere; this is the
			-- measurement that replaces it.
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

	-- Palm display: every ball this script hid for a throw is put back, so an unload cannot
	-- leave an invisible ball welded to a hand.
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

	-- Panel last: the refresh loop reads Fluent, so clearing it and destroying the library
	-- together stops the timer with the window.
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
