-- manipulations: a READ-ONLY discoverable catalog of vehicle/world/visual/geometry manipulations. Each entry
-- carries the correct, vehicle-agnostic Lua recipe (+ caveats + restore) for a manipulation; the LLM runs it via
-- the named eval tool (vehicle_lua_eval for VE, lua_eval for GE). This tool NEVER touches the engine — it returns
-- curated knowledge; the manipulation executes through the existing eval tools. Pure data + shaping.
-- Recipes distilled from the radialCheatMenu mod (reference only; not bundled). <value> is a placeholder the
-- caller fills before running the recipe.
local M = {}

local CATEGORY_ORDER = { "physics", "world", "visuals", "geometry" }

-- The catalog. Later tasks append more entries (the integrity test guards their shape).
M.CATALOG = {
  {
    key = "power", category = "physics", tool = "vehicle_lua_eval",
    title = "Engine power multiplier",
    description = "Scale engine + electric-motor torque output by a factor (1 = stock, e.g. 5 = 5x).",
    recipe = [[
-- Engine power x<value>. Vehicle-agnostic: iterates all engines + electric motors, then strengthens every
-- clutch so the drivetrain survives the extra torque. Capture base data first if you want a clean restore.
local mult = <value>
local function scale(list)
  for _, e in ipairs(list or {}) do
    if e.torqueCurve then for i = 0, #e.torqueCurve do e.torqueCurve[i] = (e.torqueCurve[i] or 0) * mult end end
    e.maxTorqueRating = math.huge
  end
end
scale(powertrain.getDevicesByCategory("engine"))
scale(powertrain.getDevicesByCategory("electricMotor"))
for _, d in pairs(powertrain.getDevices() or {}) do
  if d.clutchTorque then d.clutchTorque = (d.clutchTorque or 1000) * 1e6 end
  if d.maxTorqueRating then d.maxTorqueRating = math.huge end
end
return "power x" .. mult]],
    caveats = "A bare torque bump shreds the gearbox; this also lifts maxTorqueRating and strengthens clutches. "
      .. "Very high values can make the car undriveable. After editing torqueCurve the engine recomputes on the next throttle input.",
    restore = "reset_vehicle won't undo field edits. Capture each engine's torqueCurve+maxTorqueRating and each "
      .. "device's clutchTorque BEFORE modifying and write them back, or respawn the vehicle.",
  },
  {
    key = "time_of_day", category = "world", tool = "lua_eval",
    title = "Set time of day",
    description = "Set the world clock to a 0..1 fraction of the day (0 = midnight, 0.5 = noon).",
    recipe = [[
-- Time of day. <value> = 0..1 (0/1 midnight, ~0.25 sunrise, 0.5 noon, ~0.75 sunset). play=false freezes the clock.
core_environment.setTimeOfDay({ time = <value>, play = false })
return "time of day set"]],
    caveats = "time is a 0..1 fraction, not hours. play=false freezes the clock at that time; play=true lets it advance. Purely visual.",
    restore = "Set a normal time with play=true (e.g. core_environment.setTimeOfDay({time=0.5, play=true})). Non-destructive.",
  },
  {
    key = "paint_color", category = "visuals", tool = "lua_eval",
    title = "Set vehicle paint colour",
    description = "Set the player vehicle's base paint to an RGB colour (0..255 per channel).",
    recipe = [[
-- Paint the player vehicle. Fill r,g,b (0..255).
local r, g, b = <r>, <g>, <b>
local veh = be:getPlayerVehicle(0)
if veh then veh:setField("color", "", string.format("%d %d %d 255", r, g, b)); veh:postApply() end
return "paint set"]],
    caveats = "Sets the base paint slot's RGB; metallic/clear-coat params are unchanged. Channels are 0..255.",
    restore = "Read the original first (veh:getField('color','')) and re-apply it, or respawn the vehicle.",
  },
  {
    key = "beam_strength", category = "geometry", tool = "vehicle_lua_eval",
    title = "God mode (beam strength)",
    description = "Make all of the vehicle's beams (near-)indestructible so it won't deform or break.",
    recipe = [[
-- God mode: set every beam's strength + deform resistance to a huge value. <value> e.g. 1e10.
local s = <value>
for _, beam in pairs(v.data.beams) do
  if beam.cid ~= nil then obj:setBeamStrength(beam.cid, s); obj:setBeamDeform(beam.cid, s) end
end
return "god mode (beam strength " .. s .. ")"]],
    caveats = "Affects ALL beams; the vehicle won't deform/break. Extremely high values can cause odd physics if "
      .. "the car is wedged in geometry. This is the geometry seam behind 'invulnerable'.",
    restore = "Respawn (reset_vehicle('spawn')) for a clean reset, or capture each beam's beamStrength/beamDeform before and write them back.",
  },
  {
    key = "grip", category = "physics", tool = "vehicle_lua_eval",
    title = "Tire grip multiplier",
    description = "Multiply tire friction for all wheels (1 = stock, >1 = super grip, <1 = ice).",
    recipe = [[
-- Tire grip x<value> on all wheels. Iterates wheels.wheels, scaling each tread/wheel node's
-- friction + sliding-friction coefficients via the physics setter (vehicle-agnostic, no device names).
local mult = <value>
for _, wheel in pairs(wheels.wheels or {}) do
  for _, cid in ipairs(wheel.treadNodes or wheel.nodes or {}) do
    local node = v.data.nodes and v.data.nodes[cid]
    local f = node and node.frictionCoef or 1
    local sf = node and (node.slidingFrictionCoef or node.frictionCoef) or f
    obj:setNodeFrictionSlidingCoefs(cid, f * mult, sf * mult)
  end
end
return "grip x" .. mult]],
    caveats = "Reads each node's BASE frictionCoef from v.data.nodes every call, so re-running is idempotent (not "
      .. "compounding) — but it always multiplies the original jbeam value, so you cannot stack two different multipliers.",
    restore = "Set mult back to 1 (re-applies the base coefs), or respawn the vehicle.",
  },
  {
    key = "brakes", category = "physics", tool = "vehicle_lua_eval",
    title = "Brake force multiplier",
    description = "Scale braking + parking-brake torque for all wheels (1 = stock, >1 = stronger brakes).",
    recipe = [[
-- Brake force x<value> on all wheels. Scales wheel.brakeTorque and wheel.parkingTorque.
local mult = <value>
for _, wheel in pairs(wheels.wheels or {}) do
  wheel.brakeTorque = (wheel.brakeTorque or 0) * mult
  wheel.parkingTorque = (wheel.parkingTorque or 0) * mult
end
return "brakes x" .. mult]],
    caveats = "Multiplies the CURRENT brakeTorque/parkingTorque each call — applying twice compounds it. Capture the "
      .. "base values first if you want a clean undo. Very high values lock the wheels instantly.",
    restore = "Capture each wheel.brakeTorque/parkingTorque before and write them back, or respawn.",
  },
  {
    key = "mass", category = "physics", tool = "vehicle_lua_eval",
    title = "Vehicle mass multiplier",
    description = "Scale the mass of all vehicle nodes (1 = stock, >1 = heavier, <1 = lighter).",
    recipe = [[
-- Vehicle mass x<value>. Reads each node's base nodeWeight from v.data.nodes and writes the scaled mass
-- via the physics setter (vehicle-agnostic; applies to every node).
local mult = <value>
for cid, node in pairs(v.data.nodes or {}) do
  if type(cid) == "number" then
    obj:setNodeMass(cid, (node.nodeWeight or 1) * mult)
  end
end
return "mass x" .. mult]],
    caveats = "The mod targets only BODY/cab nodes (so the chassis keeps its mass distribution); this simplified recipe "
      .. "scales EVERY node from its base nodeWeight, which shifts the centre of mass less but is vehicle-agnostic. "
      .. "Reads base nodeWeight each call so it is idempotent, not compounding.",
    restore = "Set mult back to 1 (re-applies base nodeWeight), or respawn the vehicle.",
  },
  {
    key = "gravity_vehicle", category = "physics", tool = "vehicle_lua_eval",
    title = "Per-vehicle gravity",
    description = "Set this vehicle's local gravity in m/s^2 (Earth = -9.81; 0 = float; e.g. -1.62 = Moon).",
    recipe = [[
-- Per-vehicle gravity. <value> is an ABSOLUTE acceleration in m/s^2 (-9.81 = Earth, 0 = float, positive = up).
local g = <value>
obj:setGravity(g)
return "gravity " .. g .. " m/s^2"]],
    caveats = "Affects ONLY this vehicle, not the world. The mod multiplies the base gravity (obj:getGravity()); this "
      .. "recipe sets an absolute value instead, so pass the target m/s^2 directly (Earth is about -9.81).",
    restore = "Set it back to Earth gravity: obj:setGravity(-9.81), or respawn.",
  },
  {
    key = "gear_ratios", category = "physics", tool = "vehicle_lua_eval",
    title = "Gear ratio multiplier",
    description = "Scale every gearbox/reduction ratio (bigger ratios usually shorten gears: more torque, lower top speed — see caveats).",
    recipe = [[
-- Gear ratios x<value>. Iterates ALL powertrain devices: scales gearRatios[] + min/max/gearRatio on any
-- box with ratios, and cumulativeGearRatio on motors (keeps EV engine-braking sane). Vehicle-agnostic.
local mult = <value>
for _, d in pairs(powertrain.getDevices() or {}) do
  if d.gearRatios then for i, r in pairs(d.gearRatios) do d.gearRatios[i] = r * mult end end
  if d.minGearRatio then d.minGearRatio = d.minGearRatio * mult end
  if d.maxGearRatio then d.maxGearRatio = d.maxGearRatio * mult end
  if d.gearRatio then d.gearRatio = d.gearRatio * mult end
  if d.cumulativeGearRatio then d.cumulativeGearRatio = d.cumulativeGearRatio * mult end
end
return "gear ratios x" .. mult]],
    caveats = "Multiplies the CURRENT ratios each call — applying twice compounds it; drive from a captured base. "
      .. "Bigger ratios shorten gears (more torque, lower top speed); the >1 = taller framing assumes you read it as "
      .. "final-drive. Extreme values can make the car undriveable.",
    restore = "Capture each device's gearRatios/min/max/gearRatio/cumulativeGearRatio before and write them back, or respawn.",
  },
  {
    key = "rev_limit", category = "physics", tool = "vehicle_lua_eval",
    title = "Rev-limiter multiplier",
    description = "Scale the engine's max RPM and rev-limiter so it revs higher (1 = stock, >1 = higher redline).",
    recipe = [[
-- Rev limit x<value>. For every engine, scale maxRPM/maxAV and all rev-limiter fields, and disable
-- over-rev damage so it survives. Vehicle-agnostic (iterates the "engine" category).
local mult = <value>
for _, d in ipairs(powertrain.getDevicesByCategory("engine") or {}) do
  if d.maxRPM then d.maxRPM = d.maxRPM * mult end
  if d.maxAV then d.maxAV = d.maxAV * mult end
  if d.revLimiterRPM then d.revLimiterRPM = d.revLimiterRPM * mult end
  if d.revLimiterAV then d.revLimiterAV = d.revLimiterAV * mult end
  if d.revLimiterMaxAV then d.revLimiterMaxAV = d.revLimiterMaxAV * mult end
  d.valvetrainOverrevDamageAV = math.huge
end
if powertrain.sendTorqueData then powertrain.sendTorqueData() end
return "rev limit x" .. mult]],
    caveats = "Multiplies the CURRENT limiter fields each call — compounds if re-run; drive from a captured base. The "
      .. "mod also rebuilds the torque curve to the new RPM range; this recipe only raises the limit, so torque above "
      .. "the old redline tapers off. Over-rev damage is disabled (valvetrainOverrevDamageAV = huge).",
    restore = "Capture each engine's maxRPM/maxAV/revLimiter* and valvetrainOverrevDamageAV before and write them back, or respawn.",
  },
  {
    key = "engine_brake", category = "physics", tool = "vehicle_lua_eval",
    title = "Engine-braking multiplier",
    description = "Scale engine drag/friction so lifting off the throttle slows you harder (1 = stock, >1 = stronger).",
    recipe = [[
-- Engine braking x<value>. Scales each power unit's dynamicFriction/friction (and brakingCoef on EV motors),
-- which is the deceleration when off-throttle. Iterates engines + electric motors. Vehicle-agnostic.
local mult = <value>
local function scale(list)
  for _, d in ipairs(list or {}) do
    if d.dynamicFriction then d.dynamicFriction = d.dynamicFriction * mult end
    if d.friction then d.friction = d.friction * mult end
    if d.brakingCoef then d.brakingCoef = d.brakingCoef * mult end
  end
end
scale(powertrain.getDevicesByCategory("engine"))
scale(powertrain.getDevicesByCategory("electricMotor"))
return "engine brake x" .. mult]],
    caveats = "Multiplies the CURRENT friction fields each call — compounds if re-run; drive from a captured base. The "
      .. "mod applies this inside its power recalculation; standalone it still works but a separate power-multiplier "
      .. "run would re-derive these from its own base.",
    restore = "Capture each device's dynamicFriction/friction/brakingCoef before and write them back, or respawn.",
  },
  {
    key = "aero_drag", category = "physics", tool = "vehicle_lua_eval",
    title = "Aero drag multiplier",
    description = "Scale aerodynamic drag by changing the level's air density (1 = stock, <1 = less drag/higher top speed).",
    recipe = [[
-- Aero drag x<value>. The sim derives drag from air density; the mod scales the level's airDensity
-- (base 1.204 kg/m^3). Runs as a GE-side LevelInfo edit queued from the vehicle. <value> < 1 = less drag.
local mult = <value>
obj:queueGameEngineLua(string.format([==[
  local names = scenetree.findClassObjects("LevelInfo")
  local li = names and names[1] and scenetree.findObject(names[1])   -- the level's LevelInfo (often named "theLevelInfo")
  if li then li:setField("airDensity", 0, "%g"); li:postApply() end
]==], 1.204 * mult))
return "aero drag x" .. mult]],
    caveats = "Air density is a LEVEL-WIDE property, so this changes drag for EVERY vehicle, not just yours, and also "
      .. "affects engine breathing. The mod re-runs its power calc afterward to compensate for the oxygen change; this "
      .. "recipe only adjusts density. Sets an absolute density (1.204 * mult), so it does not compound.",
    restore = "Reset air density to stock: same recipe with mult = 1 (airDensity 1.204), or reload the level.",
  },
  {
    key = "invulnerable", category = "physics", tool = "vehicle_lua_eval",
    title = "Invulnerability multiplier",
    description = "Strengthen all beams (and torsion bars) so the vehicle resists deformation/breaking (>=10 = god mode).",
    recipe = [[
-- Invulnerability x<value>. Scales every beam's strength + deform resistance (and torsion bars where
-- supported), capped so the physics solver doesn't explode. <value> >= 10 ~= full god mode.
local mult = <value>
local LIMIT = 1e10
local function safe(base) return math.min(base * mult, LIMIT) end
for _, beam in pairs(v.data.beams or {}) do
  if beam.cid ~= nil then
    obj:setBeamStrength(beam.cid, safe(beam.beamStrength or math.huge))
    obj:setBeamDeform(beam.cid, safe(beam.beamDeform or math.huge))
  end
end
if type(obj.setTorsionbarStrength) == "function" then
  for _, t in pairs(v.data.torsionbars or {}) do
    if t.cid ~= nil then
      obj:setTorsionbarStrength(t.cid, safe(t.strength or math.huge))
      obj:setTorsionbarDeform(t.cid, safe(t.deform or math.huge))
    end
  end
end
return "invulnerable x" .. mult]],
    caveats = "Reads each beam's BASE strength/deform from v.data.beams, so re-running is idempotent (not compounding). "
      .. "Values are CAPPED at 1e10 (the ceiling the mod is tuned to; higher destabilises the physics solver). This is the "
      .. "scaled cousin of the geometry 'beam_strength' god-mode entry.",
    restore = "Set mult back to 1 (re-applies base values), or respawn (reset_vehicle('spawn')) for a clean reset.",
  },
  {
    key = "infinite_fuel", category = "physics", tool = "vehicle_lua_eval",
    title = "Infinite fuel (toggle)",
    description = "Refill every fuel tank and EV battery to full. Run repeatedly (or each frame) to keep them topped up.",
    recipe = [[
-- Infinite fuel: refill all fuelTank and electricBattery storages to 100%. Iterates energyStorage (no names).
for _, storage in pairs(energyStorage.getStorages() or {}) do
  if storage.type == "fuelTank" or storage.type == "electricBattery" then
    storage:setRemainingRatio(1)
  end
end
return "fuel/battery refilled"]],
    caveats = "This is a one-shot REFILL, not a sticky cheat: fuel still drains afterward. The mod calls it every frame "
      .. "to keep tanks full — re-run the recipe whenever you want a top-up.",
    restore = "Nothing to undo (it only adds fuel). To drain again, just drive; or set a lower ratio with setRemainingRatio.",
  },
  {
    key = "infinite_n2o", category = "physics", tool = "vehicle_lua_eval",
    title = "Infinite nitrous (toggle)",
    description = "Refill every nitrous (N2O) bottle to full. Run repeatedly to keep nitrous topped up.",
    recipe = [[
-- Infinite nitrous: refill all n2oTank storages to 100%. Iterates energyStorage (no device names).
for _, storage in pairs(energyStorage.getStorages() or {}) do
  if storage.type == "n2oTank" then
    storage:setRemainingRatio(1)
  end
end
return "nitrous refilled"]],
    caveats = "One-shot REFILL, not sticky: nitrous still depletes when used. The mod re-runs it each frame; re-run the "
      .. "recipe to top up. Does nothing on vehicles without an n2oTank.",
    restore = "Nothing to undo (it only adds nitrous).",
  },
  {
    key = "anti_overheat", category = "physics", tool = "vehicle_lua_eval",
    title = "Anti-overheat (toggle)",
    description = "Force engine, oil and brake temperatures back to cool. Run repeatedly to hold them down.",
    recipe = [[
-- Anti-overheat: snap engine thermals + brake temps back to cool on every power unit and wheel. One-shot.
for _, d in pairs(powertrain.getDevices() or {}) do
  if d.thermals then
    d.thermals.coolantTemperature = 20
    d.thermals.oilTemperature = 20
    d.thermals.engineBlockTemperature = 20
    d.thermals.cylinderWallTemperature = 80
    d.thermals.exhaustTemperature = 200
  end
  if d.clutchTemperature ~= nil then d.clutchTemperature = 20 end
end
for _, wheel in pairs(wheels.wheels or {}) do
  wheel.brakeSurfaceTemperature = 20
  wheel.brakeCoreTemperature = 20
  wheel.padTemperature = 20
end
return "thermals cooled"]],
    caveats = "One-shot cooldown: temperatures climb again as you drive — re-run to hold them down (the mod re-applies "
      .. "every frame and even stubs out thermals.update to freeze them, which this minimal recipe does NOT do). It "
      .. "resets temperatures but does not repair heat damage already taken.",
    restore = "Nothing to undo (it only cools). Stop re-running to let temperatures behave normally again.",
  },
  {
    key = "awd_lock", category = "physics", tool = "vehicle_lua_eval",
    title = "Lock diffs / AWD (toggle)",
    description = "Lock every differential 50/50 and lock the transfer case so all wheels get drive (max traction).",
    recipe = [[
-- AWD lock: set every differential to a 50/50 split with huge lock torque, and lock the transfer case.
-- Vehicle-agnostic (iterates the "differential" category). Capture base values first to undo cleanly.
for _, d in ipairs(powertrain.getDevicesByCategory("differential") or {}) do
  d.torqueSplit = 0.5
  d.lockTorque = 9000000
end
local trCase = powertrain.getDevice("transfercase")
if trCase then
  trCase.isBroken = false
  if trCase.activeLockTorque then trCase.activeLockTorque = 9000000 end
end
if electrics and electrics.values then electrics.values.tcclock = 1 end
return "diffs locked / AWD"]],
    caveats = "Overwrites torqueSplit/lockTorque with fixed values (0.5 / 9000000), so it is NOT a multiplier and does "
      .. "not compound. A 50/50 locked diff changes handling (understeer / tire scrub on tight turns).",
    restore = "Capture each differential's torqueSplit/lockTorque (and transfer-case activeLockTorque) before and write them back, or respawn.",
  },
  {
    key = "no_tire_burst", category = "physics", tool = "vehicle_lua_eval",
    title = "Burst-proof tires (toggle)",
    description = "Stop tires from bursting/deflating by disabling the burst threshold and over-inflating them.",
    recipe = [[
-- Burst-proof tires: disable each wheel's burst speed and over-inflate so the tire can't pop or deflate.
-- Iterates wheels.wheels (no names). Toggle-style; re-run if a reset re-arms the burst logic.
for _, wheel in pairs(wheels.wheels or {}) do
  wheel.tireBurstAV = math.huge
  wheel.isInflated = true
  if wheel.setPressure then wheel:setPressure(400000) end
end
return "tires burst-proofed"]],
    caveats = "Over-inflates to ~400 kPa, making tires very stiff (almost solid) — grip/ride quality change noticeably. "
      .. "tireBurstAV = huge disables the speed-based burst; the full mod also intercepts beamstate.deflateTire, which "
      .. "this minimal recipe does NOT, so a forced deflate could still let air out.",
    restore = "Set wheel.tireBurstAV back to its base (or nil) and wheel:setPressure to ~200000, or respawn for stock tires.",
  },
  {
    key = "weather", category = "world", tool = "lua_eval",
    title = "Rain / snow precipitation",
    description = "Spawn or update a precipitation effect (rain or snow) over the scene. kind = 'rain' or 'snow'; "
      .. "drops = particle count (e.g. 1000), or 0 to clear it.",
    recipe = [[
-- Precipitation. <kind> = "rain" or "snow" (string); <drops> = drop count (e.g. 1000), 0 = clear.
-- Creates/updates a reusable "cheat_precipitation" Precipitation object parented to MissionGroup.
local kind, drops = "<kind>", <drops>
drops = math.min(math.max(drops, 0), 10000)
local objWeather = scenetree.findObject("cheat_precipitation")
if drops > 0 and not objWeather then
  objWeather = createObject("Precipitation")
  objWeather:registerObject("cheat_precipitation")
  local root = scenetree.findObject("MissionGroup")
  if root then root:addObject(objWeather) end
  objWeather:setField("boxWidth", 0, "80")
  objWeather:setField("boxHeight", 0, "50")
end
if objWeather then
  if drops > 0 then
    if kind == "snow" then
      objWeather:setField("dataBlock", 0, "Snow_menu")
      objWeather:setField("minSpeed", 0, "0.01"); objWeather:setField("maxSpeed", 0, "0.25")
      objWeather:setField("dropSize", 0, "2.5")
    else
      objWeather:setField("dataBlock", 0, "")   -- empty datablock => default rain
      objWeather:setField("minSpeed", 0, "0.1"); objWeather:setField("maxSpeed", 0, "0.5")
      objWeather:setField("dropSize", 0, "1")
    end
    objWeather:setField("useTrueBillboards", 0, "1")
    objWeather:setField("renderPriority", 0, "10")
  end
  objWeather:setField("numDrops", 0, tostring(drops))
  objWeather:postApply()
end
return "precipitation " .. kind .. " drops=" .. drops]],
    caveats = "GE Lua. The mod runs this through the VE->GE bridge and positions the box over the car; this standalone "
      .. "GE recipe leaves the precipitation box at the world origin, so move the player there or extend the recipe with "
      .. "obj:getPosition to follow a vehicle. The snow path needs a 'Snow_menu' dataBlock to exist in the level (rain, "
      .. "with an empty dataBlock, always works). drops is clamped to 10000. This is a fake local effect, not the "
      .. "level's real weather system.",
    restore = "Re-run with drops=0 to stop the particles, or delete the object: "
      .. "local o = scenetree.findObject('cheat_precipitation'); if o then o:delete() end",
  },
  {
    key = "gravity_world", category = "world", tool = "lua_eval",
    title = "World gravity",
    description = "Set the GLOBAL gravity for the whole simulation, in m/s^2 (Earth = -9.81, 0 = float, "
      .. "-1.62 = Moon, positive = up).",
    recipe = [[
-- World gravity. <value> is an ABSOLUTE acceleration in m/s^2 (-9.81 = Earth, 0 = float, positive = up).
core_environment.setGravity(<value>)
return "world gravity " .. (<value>) .. " m/s^2"]],
    caveats = "GE Lua. Affects EVERY vehicle and object in the world (unlike the per-vehicle 'gravity_vehicle' physics "
      .. "entry, which uses obj:setGravity on one car). Default Earth gravity is -9.81.",
    restore = "Set it back to Earth: core_environment.setGravity(-9.81). Non-destructive.",
  },
  {
    key = "shadow_quality", category = "world", tool = "lua_eval",
    title = "Shadow / light texture-size multiplier",
    description = "Multiply the shadow/texture resolution of all light sources (Sun, point/spot lights, sky, probes). "
      .. "<value> = the multiplier (1 = stock, >1 = sharper shadows + more VRAM/GPU cost, <1 = blurrier/faster).",
    recipe = [[
-- Shadow quality x<value>. Scales obj.texSize on every light/shadow source. Caches each object's base texSize
-- in _G.shadow_defaults_map so re-running is idempotent (always multiplies the ORIGINAL, never compounds).
local multiplier = <value>
if not _G.shadow_defaults_map then _G.shadow_defaults_map = {} end
local classes = { "PointLight", "SpotLight", "Sun", "ScatterSky", "ProjectedShadow", "EnvironmentProbe" }
for _, className in ipairs(classes) do
  local names = scenetree.findClassObjects(className)
  for i = 1, #names do
    local o = scenetree.findObject(names[i])
    if o then
      local id = o:getID()
      if not _G.shadow_defaults_map[id] then _G.shadow_defaults_map[id] = o.texSize or 512 end
      o.texSize = _G.shadow_defaults_map[id] * multiplier
      o:postApply()
    end
  end
end
return "shadow quality x" .. multiplier]],
    caveats = "GE Lua. Caches the base texSize per object in _G.shadow_defaults_map on first run, so it is idempotent "
      .. "(re-running with a new multiplier always scales the ORIGINAL, not the current value). Big multipliers raise "
      .. "VRAM use and can hurt frame-rate; very small ones make shadows blocky. Purely visual.",
    restore = "Re-run with multiplier = 1 (re-applies the cached base texSize for every light).",
  },
  {
    key = "node_position", category = "geometry", tool = "vehicle_lua_eval",
    title = "Move a node",
    description = "Set the local position of ONE soft-body node by its cid. Node ids are vehicle-specific, so the "
      .. "recipe first shows how to FIND a node's cid by name; <x>,<y>,<z> are the target local-space coordinates.",
    recipe = [[
-- Move a node. STEP 1 (discover): node ids are per-vehicle. Inspect v.data.nodes to find the cid you want;
-- it is keyed by both numeric cid AND node name, each entry has .cid, .name and .pos {x,y,z}. For example:
--   for cid, node in pairs(v.data.nodes) do
--     if type(cid) == "number" then print(node.cid .. " " .. tostring(node.name)
--       .. " (" .. node.pos.x .. "," .. node.pos.y .. "," .. node.pos.z .. ")") end
--   end
-- STEP 2 (move): fill <cid> with that numeric cid and <x>,<y>,<z> with the new local position.
local cid = <cid>
obj:setNodePosition(cid, vec3(<x>, <y>, <z>))
return "node " .. cid .. " moved"]],
    caveats = "VE Lua. This is a LOW-LEVEL soft-body seam: a single eval applies ONE step. setNodePosition yanks the "
      .. "node to a new spot in one frame, so the beams attached to it stretch instantly — that can DEFORM or BREAK the "
      .. "vehicle. The mod only moves nodes inside a smooth per-frame loop with damage suppression; to mimic that, apply "
      .. "the 'beam_strength' (god-mode) recipe FIRST and move in small increments across repeated evals (per-frame, "
      .. "beyond a single eval). Positions are LOCAL vehicle space, not world coordinates.",
    restore = "Capture node.pos.x/y/z from v.data.nodes BEFORE moving and setNodePosition it back, or respawn "
      .. "(reset_vehicle('spawn')) for a clean reset.",
  },
  {
    key = "beam_length", category = "geometry", tool = "vehicle_lua_eval",
    title = "Scale beam length (morph)",
    description = "Scale the rest length of a chosen set of beams via their length-ref-ratio (the mod's wheel/body "
      .. "morphing seam). <value> = the ratio (1 = stock, >1 = longer, <1 = shorter). 1.0 restores stock.",
    recipe = [[
-- Scale beam length. STEP 1 (pick beams): v.data.beams is the full beam list; each beam has .cid plus
-- .id1/.id2 (its two node cids) and a .partOrigin string, so you can target a region. Example: scale only
-- beams whose part name contains "wheel" (case-insensitive). STEP 2: <value> = length-ref-ratio (1 = stock).
local ratio = <value>
for _, beam in pairs(v.data.beams) do
  if beam.cid ~= nil then
    local origin = tostring(beam.partOrigin or ""):lower()
    if origin:find("wheel") then          -- <-- change this filter to choose which beams to morph
      obj:setBeamLengthRefRatio(beam.cid, ratio)
    end
  end
end
return "beam length ratio " .. ratio]],
    caveats = "VE Lua. setBeamLengthRefRatio multiplies a beam's REST length, which is exactly how the mod grows/shrinks "
      .. "wheels and bodies. A single eval applies ONE step: jumping straight to a big ratio stretches the beams in one "
      .. "frame and can DEFORM or BREAK the vehicle. The mod ramps the ratio smoothly in a per-frame onUpdate loop with "
      .. "damage suppression and a drivetrain heal afterward; to mimic that, apply the 'beam_strength' (god-mode) recipe "
      .. "FIRST and step the ratio in small amounts across repeated evals (per-frame, beyond a single eval). The default "
      .. "filter ('wheel') is just an example — edit it to target other parts.",
    restore = "Re-run with ratio = 1.0 over the same beam set to return them to stock rest length, or respawn.",
  },
  {
    key = "beam_spring_damp", category = "geometry", tool = "vehicle_lua_eval",
    title = "Set beam spring / damping (suspension feel)",
    description = "Override the spring stiffness and damping of a chosen set of beams (the mod's suspension-morph "
      .. "seam). <spring>,<damp> = new beamSpring/beamDamp (pass -1 for either to leave it unchanged).",
    recipe = [[
-- Set beam spring/damp. STEP 1 (pick beams): v.data.beams holds each beam's BASE .beamSpring, .beamDamp,
-- .springExpansion, .dampExpansion plus .partOrigin, so you can target a region (e.g. the suspension/coilovers).
-- STEP 2: <spring>,<damp> = the new spring/damp (use -1 to keep a field as-is). springExp/dampExp are kept stock.
local spring, damp = <spring>, <damp>
for _, beam in pairs(v.data.beams) do
  if beam.cid ~= nil then
    local origin = tostring(beam.partOrigin or ""):lower()
    if origin:find("suspension") or origin:find("coilover") then  -- <-- change this filter to choose beams
      obj:setBeamSpringDamp(beam.cid, spring, damp, beam.springExpansion or -1, beam.dampExpansion or -1)
    end
  end
end
return "beam spring/damp set"]],
    caveats = "VE Lua. setBeamSpringDamp(cid, spring, damp, springExp, dampExp) sets the beam's stiffness/damping; "
      .. "passing -1 for any of the four leaves that field unchanged. A single eval applies ONE step. The mod derives "
      .. "spring/damp from a ride-height curve inside its per-frame suspension-morph loop (with damage suppression) — "
      .. "applying extreme stiffness in one shot, or combined with a length change, can DEFORM or BREAK the suspension, "
      .. "so apply the 'beam_strength' (god-mode) recipe FIRST and ramp values across repeated evals (per-frame, beyond a "
      .. "single eval) for a smooth result. The default filter (suspension/coilover) is an example — edit it.",
    restore = "Capture each beam's beamSpring/beamDamp (springExpansion/dampExpansion) from v.data.beams BEFORE editing "
      .. "and write them back with setBeamSpringDamp, or respawn for stock suspension.",
  },
}

local function isKnownCategory(cat)
  for _, c in ipairs(CATEGORY_ORDER) do if c == cat then return true end end
  return false
end

local function byKey(a, b) return tostring(a.key) < tostring(b.key) end

-- Pure: compact index — categories (in CATEGORY_ORDER) each with {count, items=[{key,title}]} sorted by key.
function M.buildIndex()
  local byCat = {}
  for _, e in ipairs(M.CATALOG) do
    byCat[e.category] = byCat[e.category] or {}
    byCat[e.category][#byCat[e.category] + 1] = { key = e.key, title = e.title }
  end
  local categories = {}
  for _, cat in ipairs(CATEGORY_ORDER) do
    local items = byCat[cat]
    if items then
      table.sort(items, byKey)
      categories[#categories + 1] = { category = cat, count = #items, items = items }
    end
  end
  return { categories = categories }
end

-- Pure: compact rows for one category — {key,title,description}, sorted by key. Recipes stay behind
-- key= (one category's full entries are ~half the 34 KB catalog). Unknown category -> (nil, err).
function M.buildCategory(cat)
  if not isKnownCategory(cat) then
    return nil, "list_manipulations: unknown category '" .. tostring(cat)
      .. "' (categories: physics, world, visuals, geometry)"
  end
  local out = {}
  for _, e in ipairs(M.CATALOG) do
    if e.category == cat then
      out[#out + 1] = { key = e.key, title = e.title, description = e.description }
    end
  end
  table.sort(out, byKey)
  return { category = cat, count = #out, items = out,
    note = "Pass key=<key> for the full entry (recipe + caveats + restore)." }
end

-- Pure: one full entry by key. Unknown -> (nil, err).
function M.buildEntry(key)
  for _, e in ipairs(M.CATALOG) do
    if e.key == key then return e end
  end
  return nil, "list_manipulations: unknown manipulation '" .. tostring(key)
    .. "' (use list_manipulations with no args to browse)"
end

local function handler(args)
  if args ~= nil and type(args) ~= "table" then
    return nil, "list_manipulations: arguments must be an object"
  end
  args = args or {}
  if args.category ~= nil and type(args.category) ~= "string" then
    return nil, "list_manipulations: 'category' must be a string"
  end
  if args.key ~= nil and type(args.key) ~= "string" then
    return nil, "list_manipulations: 'key' must be a string"
  end
  if args.key ~= nil then return M.buildEntry(args.key) end
  if args.category ~= nil then return M.buildCategory(args.category) end
  return M.buildIndex()
end

M.def = {
  description = "Browse a catalog of gameplay/physics manipulations (power, grip, gravity, god-mode, weather, "
    .. "paint, soft-body geometry, ...), each with the exact vehicle-agnostic Lua recipe + caveats + restore. "
    .. "Run a recipe with the tool named in the entry (vehicle_lua_eval for VE, lua_eval for GE), filling the "
    .. "<value> placeholder. No args = the category index; category=<name> = that category's rows "
    .. "(key/title/description); key=<name> = one full recipe.",
  annotations = { readOnlyHint = true, openWorldHint = false, destructiveHint = false },
  inputSchema = {
    type = "object",
    properties = {
      category = { type = "string", enum = { "physics", "world", "visuals", "geometry" },
                   description = "one category's rows (omit for the index)" },
      key = { type = "string", description = "a manipulation key from the index, e.g. 'power' (returns one full recipe)" },
    },
  },
  handler = handler,
}

function M.register(registry)
  registry:add("list_manipulations", M.def)
end

return M
