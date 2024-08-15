local _, ns = ...

local plugin, CL = ns.plugin, ns.CL

local LibSpec = LibStub("LibSpecialization")

-- luacheck: globals C_ChatInfo UnitClassBase
local wipe = table.wipe

local eventMap = ns.eventMap
local unitEventMap = ns.unitEventMap
local bossState = ns.bossState
local groupState = ns.groupState

local myName = plugin:UnitName("player")
local myGUID = plugin:UnitGUID("player")

local classColorMessages = true

local FILTER_EVENTS = {
	["SPELL_DAMAGE"] = true,
	["SPELL_MISSED"] = true,
	["SPELL_PERIODIC_DAMAGE"] = true,
	["SPELL_PERIODIC_MISSED"] = true,
}

local hookModule = nil
local hooks = {}
local hookFuncs = {}

function plugin:Hook(module)
	if not module then return end
	if next(hooks) then
		if hookModule == module then
			return
		end
		self:Unhook(hookModule)
	end

	hookModule = module
	for name, func in next, hookFuncs do
		hooks[name] = module[name]
		module[name] = func
	end

	self:RegisterMessage("BigWigs_BarCreated")
	self:RegisterMessage("BigWigs_BarEmphasized")
end

function plugin:Unhook()
	self:UnregisterMessage("BigWigs_BarCreated")
	self:UnregisterMessage("BigWigs_BarEmphasized")

	if hookModule then
		for name, func in next, hooks do
			hookModule[name] = func
		end
		hooks = {}
		hookModule = nil
	end
end

-------------------------------------------------------------------------------
-- Hooks

function hookFuncs.Sync()
	-- noop
end

function hookFuncs.Win(module)
	-- no BigWigs_OnBossWin to prevent stats
	module:Debug(":Win", module:GetEncounterID(), module.moduleName)
	if module.OnWin then module:OnWin() end
	-- fire victory stuff in ENCOUNTER_END
end

function hookFuncs.Debug(module, ...)
	hooks.Debug(module, ...)
	plugin:Debug(...)
end

function hookFuncs.Log(module, event, func, ...)
	hooks.Log(module, event, func, ...)
	if FILTER_EVENTS[event] then
		-- remove common damage handler (_DAMAGE is almost always after _AURA_APPLIED)
		local auraEvents = eventMap["SPELL_AURA_APPLIED"]
		if auraEvents then
			for k, v in next, auraEvents do
				if v == func then
					auraEvents[k] = nil
				end
			end
		end
		return
	end

	if not eventMap[event] then
		eventMap[event] = {}
	end
	for i = 1, select("#", ...) do
		local id = select(i, ...)
		eventMap[event][id] = func
	end
end

function hookFuncs.RemoveLog(module, event, ...)
	hooks.RemoveLog(module, event, ...)
	for i = 1, select("#", ...) do
		local id = select(i, ...)
		eventMap[event][id] = nil
	end
end

function hookFuncs.Death(module, func, ...)
	hooks.Death(module, func, ...)
	local event = "UNIT_DIED"
	if not eventMap[event] then
		eventMap[event] = {}
	end
	for i = 1, select("#", ...) do
		local id = select(i, ...)
		eventMap[event][id] = func
	end
end

function hookFuncs.RegisterUnitEvent(module, event, func, ...)
	hooks.RegisterUnitEvent(module, event, func, ...)
	unitEventMap[event] = func or event
end

function hookFuncs.UnregisterUnitEvent(module, event, ...)
	hooks.UnregisterUnitEvent(module, event, ...)
	unitEventMap[event] = nil
end

function hookFuncs.Engage(module, ...)
	hooks.Engage(module, ...)

	-- updateData
	local messagesModule = BigWigs:GetPlugin("Messages", true)
	classColorMessages = not messagesModule or messagesModule.db.profile.classcolor

	local specId, role, position = LibSpec:MySpecialization()
	groupState[myName] = {
		name = myName,
		class = UnitClassBase("player"),
		guid = myGUID,
		specId = specId,
		role = role,
		position = position,
		unit = "player",
	}
end

function hookFuncs.ColorName(module, player, overwrite)
	local function coloredName(name, useColor)
		local info = groupState[name]
		if info then
			name = gsub(info.name, "%-.+", "")
			local color = useColor and RAID_CLASS_COLORS[info.class]
			return color and color:WrapTextInColorCode(name) or name
		end
		-- return "???"
		return gsub(name, "%-.+", "")
	end

	if type(player) == "table" then
		local tmp = {}
		for i = 1, #player do
			tmp[i] = coloredName(player[i], classColorMessages or overwrite)
		end
		return tmp
	end
	return coloredName(player, classColorMessages or overwrite)
end

do
	local bosstargets = {}
	for i = 1, 5 do -- goes to 8 now? but TS IEEU only tracks 5
		bosstargets[("boss%dtarget"):format(i)] = ("boss%d"):format(i)
	end

	function hookFuncs.UnitName(module, unit)
		if bossState[unit] then
			return bossState[unit].name
		else
			local boss = bosstargets[unit]
			if bossState[boss] then
				return bossState[boss].target
			end
		end
		for name, info in next, groupState do
			if name == unit or info.unit == unit then
				return info.name
			end
		end
		return hooks.UnitName(module, unit)
	end
end

function hookFuncs.UnitGUID(module, unit)
	if bossState[unit] then
		return bossState[unit].guid
	end
	for name, info in next, groupState do
		if name == unit or info.unit == unit then
			return info.guid
		end
	end
	return hooks.UnitGUID(module, unit)
end

function hookFuncs.UnitIsInteractable(module, unit)
	if bossState[unit] then
		return bossState[unit].canAttack -- bossState[unit].exists and
	end
	return hooks.UnitIsInteractable(module, unit)
end

function hookFuncs.UnitTokenFromGUID(module, guid)
	for unit, info in next, bossState do
		if info.guid == guid then
			return unit
		end
	end
	for _, info in next, groupState do
		if info.guid == guid then
			return info.unit
		end
	end
	return hooks.UnitTokenFromGUID(module, guid)
end

function hookFuncs.GetUnitTarget(module, func, _, guid)
	C_Timer.After(0.1, function()
		func(module, myName, myGUID, 0.1)
	end)
end

function hookFuncs.Tanking(module, targetUnit, sourceUnit)
	if bossState[targetUnit] then
		return bossState[targetUnit].target == module:UnitName(sourceUnit)
	end
end

do
	local function getPlayerRole(name)
		return groupState[name] and groupState[name].role
	end

	local function getPlayerRolePosition(name)
		return groupState[name] and groupState[name].postion
	end

	function hookFuncs.Tank(module, unit)
		return getPlayerRole(unit) == "TANK"
	end

	function hookFuncs.Healer(module, unit)
		return getPlayerRole(unit) == "HEALER"
	end

	function hookFuncs.Damager(module, unit)
		return getPlayerRole(unit) == "DAMAGER"
	end

	function hookFuncs.Melee(module, unit)
		return getPlayerRolePosition(unit) == "MELEE"
	end

	function hookFuncs.Ranged(module, unit)
		return getPlayerRolePosition(unit) == "RANGED"
	end
end

function hookFuncs.Difficulty()
	return plugin.difficulty
end

function hookFuncs.LFR()
	return plugin.difficulty == 7 or plugin.difficulty == 17
end

function hookFuncs.Normal()
	return plugin.difficulty == 1
		or plugin.difficulty == 3
		or plugin.difficulty == 4
		or plugin.difficulty == 14
		or plugin.difficulty == 173
		or plugin.difficulty == 205
end

function hookFuncs.Easy()
	return plugin.difficulty == 14 or plugin.difficulty == 17
end

function hookFuncs.Heroic()
	return plugin.difficulty == 2
		or plugin.difficulty == 5
		or plugin.difficulty == 6
		or plugin.difficulty == 15
		or plugin.difficulty == 24
		or plugin.difficulty == 174
end

function hookFuncs.Mythic()
	return plugin.difficulty == 8 or plugin.difficulty == 16 or plugin.difficulty == 23
end

function hookFuncs.DelayedMessage(module, key, delay, color, text, icon, sound)
	local timeMod = plugin.db.profile.speed
	if timeMod > 1 then
		delay = delay / timeMod
	end
	hooks.DelayedMessage(module, key, delay, color, text, icon, sound)
end

function hookFuncs.Berserk(module, seconds, noMessages, customBoss, customBerserk, customFinalMessage, customBarText)
	-- remove all messages except final berserk (if used)
	if noMessages ~= 0 then
		local key, icon, berserk = "berserk", 26662, module:SpellName(26662)
		if type(customBerserk) == "number" then
			key, icon, berserk = customBerserk, customBerserk, module:SpellName(customBerserk)
		elseif type(customBerserk) == "string" then
			berserk = customBerserk
		end
		module:DelayedMessage(key, seconds, "red", customFinalMessage or format(CL.custom_end, customBoss or module.displayName, berserk), icon, "Alarm")
	end
	noMessages = 0
	hooks.Berserk(module, seconds, noMessages, customBoss, customBerserk, customFinalMessage, customBarText)
end

-- throttle chat stuff for "always on me" and only print to chat instead of say/yell
do
	local prev = 0
	function hookFuncs.Say(module, key, msg, directPrint)
		if not module:CheckOption(key, "SAY") then return end
		local t = GetTime()
		if t - prev < 1.5 then return end
		prev = t

		if not msg then
			msg = module:SpellName(key) or key
		elseif type(msg) == "number" then
			msg = module:SpellName(msg) or msg
		end
		if not directPrint then
			msg = CL.on:format(msg, myName)
		end
		local color = C_ChatInfo.GetColorForChatType("SAY")
		print(color:WrapTextInColorCode(("SAY: %s"):format(msg)))
	end
end

do
	local prev = 0
	function hookFuncs.Yell(module, key, msg, directPrint)
		if not module:CheckOption(key, "SAY") then return end
		local t = GetTime()
		if t - prev < 1.5 then return end
		prev = t

		if not msg then
			msg = module:SpellName(key) or key
		elseif type(msg) == "number" then
			msg = module:SpellName(msg) or msg
		end
		if not directPrint then
			msg = CL.on:format(msg, myName)
		end
		local color = C_ChatInfo.GetColorForChatType("YELL")
		print(color:WrapTextInColorCode(("YELL: %s"):format(msg)))
	end
end

do
	local prev = 0
	function hookFuncs.SayCountdown(module, key, seconds, textOrIcon, startAt)
		if not module:CheckOption(key, "SAY_COUNTDOWN") then return end
		local t = GetTime()
		if t - prev < 1.5 then return end
		prev = t

		local start = startAt or 3
		local tbl = { false }
		local text = (type(textOrIcon) == "number" and textOrIcon < 9 and ("{rt%d}"):format(textOrIcon)) or textOrIcon
		local function printTime()
			if not tbl[1] then
				local msg = text and format("%s %d", text, start) or start
				local color = C_ChatInfo.GetColorForChatType("SAY")
				print(color:WrapTextInColorCode(("SAY: %s"):format(msg)))
				start = start - 1
			end
		end
		local startOffset = start + 0.2
		for i = 1.2, startOffset do
			C_Timer.After(seconds - i, printTime)
		end
		module.sayCountdowns[key] = tbl
	end
end

do
	local prev = 0
	function hookFuncs.YellCountdown(module, key, seconds, textOrIcon, startAt)
		if not module:CheckOption(key, "SAY_COUNTDOWN") then return end
		local t = GetTime()
		if t - prev < 1.5 then return end
		prev = t

		local start = startAt or 3
		local tbl = { false }
		local text = (type(textOrIcon) == "number" and textOrIcon < 9 and ("{rt%d}"):format(textOrIcon)) or textOrIcon
		local function printTime()
			if not tbl[1] then
				local msg = text and format("%s %d", text, start) or start
				local color = C_ChatInfo.GetColorForChatType("YELL")
				print(color:WrapTextInColorCode(("YELL: %s"):format(msg)))
				start = start - 1
			end
		end
		local startOffset = start + 0.2
		for i = 1.2, startOffset do
			C_Timer.After(seconds - i, printTime)
		end
		module.sayCountdowns[key] = tbl
	end
end


-------------------------------------------------------------------------------
-- Handle bars
do
	local function barUpdater(bar)
		if plugin.db.profile.speed == 1 then return end

		local t = GetTime()
		local timeMod = plugin.db.profile.speed
		-- local s = (t - bar.start) / (bar.exp - bar.start) * timeMod
		-- local faket = (bar.exp - bar.start) * s + bar.start
		local faket = timeMod * t - timeMod * bar.start + bar.start
		if faket >= bar.exp then
			if bar.pauseWhenDone then
				bar:Pause()
				bar.candyBarBar:SetMinMaxValues(-1, 0)
				bar.candyBarBar:SetValue(0)
				bar:SetDuration(0)
				bar:SetTimeVisibility(false)
			else
				bar:Stop()
			end
		else
			local time = bar.exp - faket
			bar.remaining = time

			if bar.fill then
				bar.candyBarBar:SetValue((faket-bar.start)+bar.gap)
			else
				bar.candyBarBar:SetValue(time)
			end

			local p = bar.isApproximate and "~" or ""
			if time > 59.9 then -- 1 minute to 1 hour
				local m = floor(time/60)
				local s = time - (m*60)
				bar.candyBarDuration:SetFormattedText("%s%d:%02d", p, m, s)
			elseif time < 10 then -- 0 to 10 seconds
				bar.candyBarDuration:SetFormattedText("%s%.1f", p, time)
			else -- 10 seconds to one minute
				bar.candyBarDuration:SetFormattedText("%s%.0f", p, time)
			end

			if bar.timeCallback and time < bar.timeCallbackTrigger then
				bar.timeCallbackTrigger = 0
				bar.timeCallback(bar)
				bar.timeCallback = nil
			end
		end
	end

	function plugin:BigWigs_BarCreated(_, _, bar, module)
		if module == hookModule then
			bar:AddUpdateFunction(barUpdater)
			barUpdater(bar)
		end
	end

	function plugin:BigWigs_BarEmphasized(_, _, bar)
		if bar:Get("bigwigs:module") == hookModule then
			barUpdater(bar)
		end
	end
end
