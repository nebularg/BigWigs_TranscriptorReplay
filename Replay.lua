local _, ns = ...

-------------------------------------------------------------------------------
-- Module Declaration
--

local plugin, CL = BigWigs:NewPlugin("TranscriptorReplay")
if not plugin then return end

ns.plugin, ns.CL = plugin, CL

-------------------------------------------------------------------------------
-- Locals
--

local LibSpec = LibStub("LibSpecialization")

-- luacheck: globals Transcriptor BigWigsTSR date GetSpellTexture C_Spell
local GetSpellTexture = GetSpellTexture or C_Spell.GetSpellTexture
local wipe = table.wipe

BigWigsTSR = BigWigsTSR or {}

local eventMap = {}
ns.eventMap = eventMap
local unitEventMap = {}
ns.unitEventMap = unitEventMap
local bossState = {boss1 = {}, boss2 = {}, boss3 = {}, boss4 = {}, boss5 = {}}
ns.bossState = bossState
local groupState = {}
ns.groupState = groupState
local alwaysThrottle = {}
ns.alwaysThrottle = alwaysThrottle

local args = {}
local myName = plugin:UnitName("player")
plugin.myName = myName
local myGUID = plugin:UnitGUID("player")
plugin.myGUID = myGUID
local groupCount = nil
local timer = nil

local diffShort = {
	[1] = "N", [3] = "N", [4] = "N", [14] = "N",
	[2] = "H", [5] = "H", [6] = "H", [15] = "H",
	[7] = "LFR", [17] = "LFR",
	[8] = "M+", [16] = "M", [23] = "M",
	[18] = "E", [19] = "E",
	[24] = "TW",
}

local function getLogHeaderInfo(logName)
	local year, month, day, hour, min, sec, zoneId, diff, diffName, instanceType, wowVersion = logName:match("^%[(%d+)-(%d+)-(%d+)%]@%[(%d+):(%d+):(%d+)%] %- Zone:(%d+) Difficulty:(%d+),(.+) Type:(.+) Version: (.+)$")
	local timestamp = time({ day = day, month = month, year = year, hour = hour, min = min, sec = sec })
	return timestamp, tonumber(zoneId), tonumber(diff), instanceType, wowVersion
end

local function getLogEncounterInfo(log)
	local encounterId, encounterName = nil, nil
	local encounterStart, encounterEnd = 1, #log
	for index, line in next, log do
		if line:find("ENCOUNTER_START", nil, true) then
			-- "ENCOUNTER_START#2051#Kil'jaeden#15#24"
			encounterId, encounterName = line:match("(%d+)#(.-)#%d+#%d+")
			encounterStart = index
		elseif line:find("ENCOUNTER_END", nil, true) then
			-- "2051#Kil'jaeden#15#24#1"
			local id, name = line:match("(%d+)#(.-)#%d+#%d+#%d$")
			if not encounterId then
				encounterId, encounterName = id, name
			end
			if id == encounterId then
				encounterEnd = index
			end
		end
	end
	if encounterId then
		return tonumber(encounterId), encounterName, encounterStart, encounterEnd
	end
end

local function getLogLineTime(line)
	return tonumber(line:match("<(.-) "))
end

local function getLogLineInfo(line)
	local time, type, info = line:match("<(.-) .-> %[(.-)%] (.+)")
	time = tonumber(time)
	return time, type, info
end

local function getLogCurrentStage(log, index)
	-- run through the log to get the current stage before the passed index
	local stage = 1
	for i = 1, index - 1 do
		local line = log[i]
		if line:find("BigWigs_SetStage", nil, true) then
			stage = tonumber(line:match("#(%d+)"))
		end
	end
	return stage
end

local function secondsToTime(seconds)
	local minutes = floor((seconds % 3600) / 60)
	local seconds = floor(seconds % 60)
	return ("%02d:%02d"):format(minutes, seconds)
end

-------------------------------------------------------------------------------
-- Options
--

plugin.defaultDB = {
	always_me = false,
	ignore_role = false,
	speed = 2,
}

local db_debug = false
local db_log = nil
local db_stage = nil
local db_player = nil

local values = {}
local subvalues = {}
local function GetOptions()
	local logs = Transcriptor:GetAll()

	wipe(values)
	for key, log in next, logs do
		if key ~= "ignoredEvents" and log.COMBAT then
			local timestamp, zoneId, diff = getLogHeaderInfo(key)
			local _, name, _, endIndex = getLogEncounterInfo(log.COMBAT)
			if name and diff then
				local diffName = diffShort[tonumber(diff)] or GetDifficultyInfo(diff) or diff
				local length = getLogLineTime(log.COMBAT[endIndex or #log.COMBAT])
				values[key] = ("[%s] %s <%s> [%s]"):format(diffName, name, secondsToTime(length), date("%F %T", timestamp))
			end
		end
	end

	local function setStages(logName)
		db_stage = nil
		wipe(subvalues)
		local log = logs[logName].total
		local _, name, startIndex, endIndex = getLogEncounterInfo(log)
		for i = startIndex, endIndex do
			local time, type, info = getLogLineInfo(log[i])
			if type == "BigWigs_SetStage" then
				local encounter, stage = strsplit("#", info)
				if not db_stage then
					subvalues[startIndex] = ("<%s> Stage %s (Engage)"):format(secondsToTime(time), stage)
					db_stage = startIndex
				else
					subvalues[i] = ("<%s> Stage %s"):format(secondsToTime(time), stage)
				end
			end
		end
		if not next(subvalues) then
			subvalues[startIndex] = ("<%s> Engage"):format(secondsToTime(getLogLineTime(log[startIndex])))
			db_stage = startIndex
		end
	end

	local db = plugin.db.profile

	local options = {
		name = "Replay",
		type = "group",
		handler = plugin,
		args = {
			heading = {
				type = "description",
				name = "Replay a transcriptor log to show BigWigs warnings.".."\n",
				fontSize = "medium",
				width = "full",
				order = 1,
			},
			always_me = {
				type = "toggle",
				name = "Always on me",
				desc = "Make all debuffs target you.",
				get = function(info) return db.always_me end,
				set = function(info, value)
					db.always_me = value
					db_player = nil
					plugin:SetPlayer(myName)
				end,
				order = 2,
			},
			-- ignore_role = {
			-- 	type = "toggle",
			-- 	name = "Ignore role",
			-- 	desc = "Always show warnings, regardless of role restrictions. By default, your current class specialization determines your role.",
			-- 	get = function(info) return db.ignore_role end,
			-- 	set = function(info, value) db.ignore_role = value end,
			-- 	order = 3,
			-- },
			speed = {
				type = "range", min = 1, max = 10, step = 1,
				name = "Playback speed",
				desc = "Run events at faster than normal speed.",
				get = function(info) return db.speed end,
				set = function(info, value) db.speed = value end,
				disabled = function() return plugin:IsPlaying() end,
				order = 4,
			},
			logs = {
				type = "select",
				name = "Transcriptor logs",
				get = function(info)
					return values[db_log] and db_log or false
				end,
				set = function(info, value)
					db_log = value
					db_stage = nil
					db_player = nil
					setStages(value)
					plugin:Load(value, true)
				end,
				values = values,
				disabled = function() return plugin:IsPlaying() end,
				order = 10,
				width = "full",
			},
			stage = {
				type = "select",
				name = "Start at stage",
				get = function(info)
					return subvalues[db_stage] and db_stage or false
				end,
				set = function(info, value)
					db_stage = value
				end,
				values = subvalues,
				hidden = function()
					local count = 0
					for _ in next, subvalues do
						count = count + 1
					end
					return count < 2
				end,
				disabled = function() return plugin:IsPlaying() end,
				order = 11,
				width = "full",
			},
			player = {
				type = "select",
				name = "Viewpoint",
				get = function(info)
					return db_player
				end,
				set = function(info, value)
					db_player = value
					plugin:SetPlayer(db_player)
				end,
				values = function(info)
					local list = {}
					for name, info in next, groupState do
						local classColorInfo = RAID_CLASS_COLORS[info.class]
						list[name] = classColorInfo and _G.WrapTextInColorCode(name, classColorInfo.colorStr) or name
					end
					return list
				end,
				order = 12,
				disabled = function() return db.always_me or not next(groupState) or plugin:IsPlaying() end,
			},
			play = {
				type = "execute",
				name = "Play",
				func = function() plugin:Play(db_stage) end,
				order = 20,
				disabled = function() return not db_log or plugin:IsPlaying() end,
			},
			stop = {
				type = "execute",
				name = "Stop",
				func = function() plugin:Stop() end,
				disabled = function() return not plugin:IsPlaying() end,
				order = 22,
			},
			sep = {
				type = "description",
				name = "",
				order = 30,
				width = "full",
			},
			debug = {
				type = "toggle",
				name = "Debug",
				desc = "Show internal debug messages.",
				get = function(info) return db_debug end,
				set = function(info, value) db_debug = value end,
				order = 31,
			},
			-- create = {
			-- 	type = "execute",
			-- 	name = "Create log",
			-- 	desc = "Save a new log only including events that trigger a callback.",
			-- 	disabled = true,
			-- 	order = 32,
			-- }
		},
	}

	return options
end

plugin.subPanelOptions = {
	key = "BigWigs: Replay",
	name = "Replay",
	options = GetOptions,
}

-------------------------------------------------------------------------------
-- Initialization
--

function plugin:Print(...)
	print("|cffffff00TranscriptorReplay:|r", ...)
end

function plugin:Debug(...)
	if db_debug then
		self:Print("|cff87abff[DEBUG]|r", ...)
	end
end

local function Reset()
	wipe(eventMap)
	wipe(unitEventMap)
	for unit in next, bossState do
		wipe(bossState[unit])
	end
	wipe(alwaysThrottle)
end

-------------------------------------------------------------------------------
-- Log events

function plugin:SetPlayer(name)
	if name == myName then
		self.myName = myName
		self.myGUID = myGUID
	else
		local info = groupState[name]
		if info then
			self.myName = info.name
			self.myGUID = info.guid
		end
	end
end

do
	-- throttle for "always on me"
	local prev = 0

	-- we rarely check flags, but add some for player/creature guids
	local FLAGS_CREATURE = 0x00000848 -- npc, hostile, outside
	local FLAGS_PLAYER = 0x00000414 -- player, friendly, raid
	local FLAGS_ME = 0x00000411 -- player, friendly, mine

	local AURA_EVENTS = {
		["SPELL_AURA_APPLIED"] = true, ["SPELL_AURA_APPLIED_DOSE"] = true,
		["SPELL_AURA_REFRESH"] = true,
		["SPELL_AURA_REMOVED"] = true, ["SPELL_AURA_REMOVED_DOSE"] = true,
	}

	local function trimName(name)
		name = name:gsub("%([^)]+%%%)$", "") -- remove health info
		return name
	end

	local function setFlags(guid)
		if guid:find("^Player") then
			return FLAGS_PLAYER
		end
		return FLAGS_CREATURE
	end

	local function rename(module, key, default)
		local renameModule = BigWigs:GetPlugin("Rename", true)
		if not renameModule then
			return default
		end
		return renameModule:GetName(module, key) or default
	end

	function plugin:OnCombatEvent(time, event, ...)
		local condensed
		if event == "SPELL_DAMAGE[CONDENSED]" or event == "SPELL_PERIODIC_DAMAGE[CONDENSED]" then
			event = event:sub(1, -12)
			condensed = true
		end
		if not eventMap[event] then return end
		if event == "UNIT_DIED" then
			-- UNIT_DIED##nil#Creature-0-2085-2657-10253-63508-000022ACB3#Xuen#-1#false#nil#nil",
			local _, _, destGUID, destName = ...
			local mobId = tonumber(select(6, strsplit("-", destGUID)), 10)
			local func = eventMap[event][mobId]
			if func then
				args.mobId, args.destGUID, args.destName, args.destFlags, args.destRaidFlags, args.time = mobId, destGUID, destName, setFlags(destGUID), 0, (time + self.startTime)
				self.module[func](self.module, args)
			end
		else
			-- "SPELL_AURA_APPLIED#Player-4184-005DAF59#Drcornman#Player-4184-007A5B83#Tombom#451997#Viscous Overflow#BUFF#nil",
			-- "SPELL_AURA_APPLIED#1300#Player-3725-0AEEF0CE#Eldunarí-Frostmourne#Player-3725-0AEEF0CE#Eldunarí-Frostmourne#453207#Lit Fuse#BUFF#nil#nil#nil#nil#nil",
			local sourceFlags, sourceGUID, sourceName, destGUID, destName, spellId, spellName, extraSpellId, amount, extraSpellName
			local numArgs = select("#", ...)
			if condensed then
				sourceGUID, sourceName, _, spellId, spellName = ...
				destGUID, destName = self.myGUID, self.myName
			else
				if numArgs == 8 or numArgs == 12 then -- no flags
					sourceGUID, sourceName, destGUID, destName, spellId, spellName, extraSpellId, amount = ...
				else
					sourceFlags, sourceGUID, sourceName, destGUID, destName, spellId, spellName, extraSpellId, amount = ...
					tonumber(sourceFlags)
				end
			end
			spellId = tonumber(spellId)

			local func
			if event == "SPELL_DISPEL" or event == "SPELL_INTERRUPT" then
				extraSpellId = tonumber(extraSpellId)
				extraSpellName = rename(self.module, extraSpellId, amount)
				func = eventMap[event][extraSpellId] or eventMap[event]["*"]
			else
				func = eventMap[event][spellId] or eventMap[event]["*"]
			end
			if func then
				args.sourceGUID, args.sourceName, args.sourceFlags, args.sourceRaidFlags = sourceGUID, trimName(sourceName), sourceFlags or setFlags(sourceGUID), 0
				if AURA_EVENTS[event] and destGUID:find("^Player") and self.db.profile.always_me and (time - (alwaysThrottle[func] or 0)) > 1.5 then
					alwaysThrottle[func] = time
					args.destGUID, args.destName, args.destFlags, args.destRaidFlags = self.myGUID, self.myName, FLAGS_ME, 0
				else
					local info = groupState[destName]
					if info then
						args.destGUID, args.destName, args.destFlags, args.destRaidFlags = info.guid, info.name, FLAGS_PLAYER, 0
					else
						args.destGUID, args.destName, args.destFlags, args.destRaidFlags = destGUID, trimName(destName), setFlags(destGUID), 0
					end
				end
				args.spellId, args.spellName, args.spellSchool = spellId, rename(self.module, spellId, spellName), 0
				args.time, args.extraSpellId, args.extraSpellName, args.amount = (time + self.startTime), extraSpellId, extraSpellName or amount, tonumber(amount)
				if self.module[func] then
					self:Debug(time, event, func, args.spellId, args.spellName, args.destName)
					self.args = args
					self.module[func](self.module, args)
				end
			end
		end
	end
end

function plugin:DoLine(line)
	local time, type, info = getLogLineInfo(line)

	if type == "CLEU" then
		self:OnCombatEvent(time, ("#"):split(info))

	elseif type:sub(1, 14) == "UNIT_SPELLCAST" then
		-- "[UNIT_SPELLCAST_SUCCEEDED] Sikran(100.0%-0.0%){Target:??} -Energize- [[boss1:Cast-3-2085-2657-10253-436595-0010A2ACB0:436595]]"
		local func = unitEventMap[type]
		if func and self.module[func] then
			-- "[[boss1:Cast-3-2085-2657-32297-432965-00AB7F16F4:432965]]",
			local unit, castId, spellId = strsplit(":", info:match("%[%[(.-)%]%]"))
			if unit:sub(1, 4) == "boss" then -- XXX do i actually need to restrict to the registered unit(s)?
				-- self:Debug(time, type, unit, spellId) -- too spammy
				self.module[func](self.module, type, unit, castId, tonumber(spellId))
			end
		end

	elseif type == "INSTANCE_ENCOUNTER_ENGAGE_UNIT" then
		-- "Fake Args:#boss1#true#true#true#Sikran#Creature-0-2085-2657-32297-214503-00007F16C8#elite#3179340000#boss2#false#false#false#??#nil#normal#0#boss3#false#false#false#??#nil#normal#0#boss4#false#false#false#??#nil#normal#0#boss5#false#false#false#??#nil#normal#0#Real Args:",
		local t = {strsplit("#", info)}
		for i = 2, #t - 1, 8 do -- skip Fake Args:/Real Args:
			local unit = t[i]
			if not bossState[unit] then bossState[unit] = {} end
			local boss = bossState[unit]
			boss.canAttack = t[i + 1] == "true" or false
			boss.exists = t[i + 2] == "true" or false
			boss.visible = t[i + 3] == "true" or false
			boss.name = t[i + 4] ~= "??" and t[i + 4] or nil
			boss.guid = t[i + 5] ~= "nil" and t[i + 6] or nil
			boss.health = tonumber(t[i + 7])
			boss.target = nil
			boss.power = 0
			boss.powerMax = 100
		end

	elseif type == "UNIT_TARGETABLE_CHANGED" then
		-- -boss1- [CanAttack:true#Exists:true#IsVisible:true#Name:Ulgrax the Devourer#GUID:Creature-0-2085-2657-10253-215657-000022982C#Classification:elite#Health:494309999]
		local unit, canAttack, exists, visible, name, guid, _, health = info:match("%-(.-)%- %[CanAttack:(.-)#Exists:(.-)#IsVisible:(.-)#Name:(.-)#GUID:(.-)#Classification:(.-)#Health:(.-)%]")
		local boss = bossState[unit]
		if boss then
			boss.canAttack = canAttack == "true" or false
			boss.exists = exists == "true" or false
			boss.visible = visible == "true" or false
			boss.name = name ~= "??" and name or nil
			-- boss.guid = guid ~= "nil" and guid or nil
			-- boss.health = tonumber(health)
		end
	elseif type == "UNIT_TARGET" then
		-- boss1#Sikran#Target: Tombom#TargetOfTarget: Sikran"
		-- boss2#Anub'arash#Target: ??#TargetOfTarget: ??"
		local unit, _, target = strsplit("#", info)
		local boss = bossState[unit]
		if boss then
			local target = target:sub(9)
			if target == "??" then
				target = nil
			elseif groupState[target] then
				target = groupState[target].name
			end
			boss.target = target
		end

	elseif type == "UNIT_POWER_UPDATE" then
		-- boss1#Sikran#TYPE:ENERGY/3#MAIN:4/100#ALT:0/0"
		local unit, _, _, power, altpower = strsplit("#", info)
		local boss = bossState[unit]
		if boss then
			boss.power, boss.powerMax = strsplit("/", power:sub(6))
		end

	elseif type == "ENCOUNTER_END" then
		-- 2898#Sikran, Captain of the Sureki#16#20#1
		local id, name, diff, size, status = strsplit("#", info)
		-- win/wipe whatever, just play the sound without saving stats
		if self.module:GetEncounterID() == tonumber(id) then
			self.module:Message(false, "green", ("%s has been defeated"):format(self.module.displayName), false, true)
			self.module:PlayVictorySound()
		end
	end

	return time
end

-------------------------------------------------------------------------------
-- Log Playback

function plugin:Load(logName, silent)
	self.module = nil
	self.log = nil
	self.startTime = nil

	local logs = Transcriptor:GetAll()
	local log = logs[logName]
	if not log then
		self:Print(("No log names %q found."):format(logName))
		return
	end
	if not silent then
		self:Print(("Loaded %q"):format(logName))
	end

	local _, zoneId, diff = getLogHeaderInfo(logName)
	local encounterId, encounterName, startIndex, endIndex = getLogEncounterInfo(log.total)
	if not encounterId then
		self:Print("No encounter events found?")
		return
	end

	local module = nil
	BigWigsLoader:LoadZone(zoneId)
	for name, mod in BigWigs:IterateBossModules() do
		if mod:GetEncounterID() == encounterId then
			module = mod
			break
		end
	end
	if not module then
		self:Print(("No boss module for %q (%d) found."):format(encounterName, encounterId))
		return
	end

	wipe(groupState)
	local specId, role, position = LibSpec:MySpecialization()
	groupState[myName] = {
		unit = "player",
		name = myName,
		class = _G.UnitClassBase("player"),
		guid = myGUID,
		specId = specId,
		role = role,
		position = position,
	}
	groupCount = 1

	local index = 1
	local _, type, info, prev
	repeat
		prev = type
		_, type, info = getLogLineInfo(log.total[index])
		if type == "PLAYER_INFO" then
			local name, class, guid, specId, role, position, talents = strsplit("#", info)
			if name then
				local id = (groupCount or 0) + 1
				groupState[name] = {
					unit = ("raid%d"):format(id),
					name = name,
					class = class,
					guid = guid,
					specId = specId,
					role = role,
					position = position,
				}
				groupCount = id
			end
		end
		index = index + 1
	until prev == "PLAYER_INFO" and type ~= "PLAYER_INFO"

	self.module = module
	self.difficulty = diff
	self.log = log.total
	self.startIndex = startIndex
	self.endIndex = endIndex
end

function plugin:Play(index)
	if not self.module then return end
	self:CancelTimer(timer)
	timer = nil

	if index and index > self.endIndex then
		self:Print("Reached the end of the encounter, stopping.")
		self:Stop(true)
		return
	end

	local log = self.log
	local module = self.module

	if not self.playing then
		self.startTime = GetTime()
		self.startLogTime = getLogLineTime(log[index or self.startIndex])
		self.endLogTime = getLogLineTime(log[self.endIndex])
		self.playing = true

		local diff = GetDifficultyInfo(self.difficulty or 0) or "???"
		self:Print(("Starting %q encounter (%s)"):format(module.displayName, diff))
		self:Hook(module)
		module:Enable()

		if not index or index == self.startIndex then
			module:Engage()
			module:Message(false, "yellow", ("%s engaged"):format(module.displayName), false, true)
		else
			module:Engage("NoEngage")
			-- this is ok because we're using the BigWigs_SetStage line to start mid-encounter
			local stage = getLogCurrentStage(log, index)
			if stage and module.stage ~= stage then
				module:SetStage(stage)
			end
		end
		module:Bar(false, self.endLogTime - self.startLogTime, "Log Duration", "spell_holy_borrowedtime")

		self:UpdateGUI()
	end

	local pos = index or self.startIndex
	local timeMod = self.db.profile.speed
	local elapsed = (GetTime() - self.startTime) * timeMod
	local time
	local offset = 0
	repeat -- batch events at the same timestamp and catch up from scheduling drift
		time = self:DoLine(log[pos + offset])
		offset = offset + 1
	until time > (elapsed + self.startLogTime)

	local nextLogTime = getLogLineTime(log[pos + offset])
	local cd = (nextLogTime - time) / timeMod
	timer = self:ScheduleTimer("Play", cd, pos + offset)
end

function plugin:Stop(silent)
	self:CancelTimer(timer)
	timer = nil

	if self.module then
		self.module:Disable()
		self:Unhook()
		Reset()
		if not silent then
			self:Print("Stopped")
		end
	end

	if self.playing then
		self.playing = nil
		self:UpdateGUI()
	end
end

function plugin:IsPlaying()
	return self.playing
end

_G.TSR = plugin
