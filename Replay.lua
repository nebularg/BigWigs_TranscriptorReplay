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

-- luacheck: globals Transcriptor BigWigsTSR date time print
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
local timelineState = {}
ns.timelineState = timelineState
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
	[1] = "N", [3] = "N", [4] = "N", [14] = "N", [150] = "N~", [205] = "F",
	[2] = "H", [5] = "H", [6] = "H", [15] = "H",
	[7] = "LFR", [17] = "LFR", [151] = "LFR",
	[8] = "M+", [16] = "M", [23] = "M", [233] = "M~",
	[18] = "E", [19] = "E", [232] = "E",
	[24] = "TW", [33] = "TW", [257] = "TW",
	[220] = "S",
	[236] = "LW", [241] = "LW",
}

local function getLogHeaderInfo(logName)
	local year, month, day, hour, min, sec, zoneId, diff, instanceType, wowVersion, tsVersion = logName:match("^%[(%d+)-(%d+)-(%d+)%]@%[(%d+):(%d+):(%d+)%] %- Zone#(%d+).+#Difficulty#(%d+) %((.+)%)#Type#(.+)#WoWVer#(.+)#TSVer#(.+)$")
	if not tsVersion then
		year, month, day, hour, min, sec, zoneId, diff, instanceType, wowVersion = logName:match("^%[(%d+)-(%d+)-(%d+)%]@%[(%d+):(%d+):(%d+)%] %- Zone:(%d+) Difficulty:(%d+),.+ Type:(.+) Version: (.+)$")
	end
	if not wowVersion then return end
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
	local time, type, info = line:match("<(.-) .-> %[(.-)%] (.*)")
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
	seconds = floor(seconds % 60)
	return ("%02d:%02d"):format(minutes, seconds)
end

local tonumberall do
	local temp = {}
	function tonumberall(...)
		local n = select("#", ...)
		-- Simple versions for common argument counts
		if n == 1 then
			local a = ...
			return tonumber(a)
		elseif n == 2 then
			local a, b = ...
			return tonumber(a), tonumber(b)
		elseif n == 3 then
			local a, b, c = ...
			return tonumber(a), tonumber(b), tonumber(c)
		elseif n == 0 then
			return
		end

		wipe(temp)
		for i = 1, n do
			local v = select(i, ...)
			temp[i] = type(v) ~= "number" and tonumber(v) or v
		end
		return unpack(temp)
	end
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
				local diffName = diffShort[diff] or GetDifficultyInfo(diff) or diff
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
				values = function()
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
	print("|cnYELLOW_FONT_COLOR:TSR:|r", ...)
end

function plugin:Debug(...)
	if not db_debug then return end
	if self.startTime then
		local elapsed = ((GetTime() - self.startTime) * self.db.profile.speed) + self.startLogTime
		self:Print("|cnLIGHTBLUE_FONT_COLOR:[D]|r", ("|cnCOMMON_GRAY_COLOR:%.1f|r"):format(elapsed), ...)
	else
		self:Print("|cnLIGHTBLUE_FONT_COLOR:[D]|r", ...)
	end
end

local function Reset()
	wipe(eventMap)
	wipe(unitEventMap)
	for unit in next, bossState do
		wipe(bossState[unit])
	end
	wipe(timelineState)
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
			local sourceFlags, sourceGUID, sourceName, destGUID, destName, spellId, spellName, extraSpellId, amount, extraSpellName
			local numArgs = select("#", ...)
			if condensed then
				sourceGUID, sourceName, _, spellId, spellName = ...
				destGUID, destName = self.myGUID, self.myName
			elseif event == "SWING_DAMAGE" then
				-- SWING_DAMAGE#Creature-0-5773-2769-216-231935-0002817ADF#Junkyard Hyena#Player-5764-003FF3B3#Blåblåblå#811177#-1#nil#nil#false#false#nil#nil",
				sourceGUID, sourceName, destGUID, destName, amount = ...
			elseif event == "SPELL_DAMAGE" then
				-- SPELL_DAMAGE#Player-5764-003F517F#Kíngflyhunt#Vehicle-0-5773-2769-216-230322-0000017ABE#Stix Bunkjunker#1217459#Lunar Storm",
				sourceGUID, sourceName, destGUID, destName, spellId, spellName = ...
				amount = 1
			else
				-- "SPELL_AURA_APPLIED#Player-4184-005DAF59#Drcornman#Player-4184-007A5B83#Tombom#451997#Viscous Overflow#BUFF#nil",
				-- "SPELL_AURA_APPLIED#1300#Player-3725-0AEEF0CE#Eldunarí-Frostmourne#Player-3725-0AEEF0CE#Eldunarí-Frostmourne#453207#Lit Fuse#BUFF#nil#nil#nil#nil#nil",
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
				extraSpellName = amount
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
				args.spellId, args.spellName, args.spellSchool = spellId, spellName, 0
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

	elseif type == "ENCOUNTER_TIMELINE_EVENT_ADDED" then
		-- "[ENCOUNTER_TIMELINE_EVENT_ADDED] State: 0 (Active)#id#272#source#0#spellName#<secret>#spellID#<secret>#iconFileID#<secret>#duration#8#maxQueueDuration#6#icons#<secret>#severity#<secret>#isApproximate#<secret>"
		local state, eventID, source, duration, maxQueueDuration = tonumberall(info:match("State: (%d).-#id#(.-)#source#(.-)#.-#duration#(.-)#maxQueueDuration#(.-)#"))
		self:Debug(time, type, duration)
		local eventInfo = {
			id = eventID,
			state = state,
			source = source,
			duration = duration,
			maxQueueDuration = maxQueueDuration,
		}
		timelineState[eventID] = eventInfo

		local func = eventMap[type]
		if func and self.module[func] then
			self.module[func](self.module, type, eventInfo)
		end

	elseif type == "ENCOUNTER_TIMELINE_EVENT_STATE_CHANGED" then
		-- "[ENCOUNTER_TIMELINE_EVENT_STATE_CHANGED] 272#State: 2 (Finished)"
		local eventID, state = tonumberall(info:match("(%d+)#State: (%d)"))
		if timelineState[eventID] then
			timelineState[eventID].state = state
		end

		local func = eventMap[type]
		if func and self.module[func] then
			self.module[func](self.module, type, eventID)
		end

		-- if timelineState[eventID] and state > 1 then
		-- 	timelineState[eventID] = nil
		-- end

	elseif type == "ENCOUNTER_TIMELINE_EVENT_REMOVED" then
		-- "[ENCOUNTER_TIMELINE_EVENT_REMOVED] 272"
		local eventID = tonumber(info)

		local func = eventMap[type]
		if func and self.module[func] then
			self.module[func](self.module, type, eventID)
		end
		timelineState[eventID] = nil

	elseif type:sub(1, 14) == "UNIT_SPELLCAST" then
		-- [UNIT_SPELLCAST_SUCCEEDED] Sikran(100.0%-0.0%){Target:??} -Energize- [[boss1:Cast-3-2085-2657-10253-436595-0010A2ACB0:436595]]
		-- [UNIT_SPELLCAST_SUCCEEDED] <secret>#<secret>#{Target:<secret>} [[boss1:<secret>:<secret>:1]]
		local func = unitEventMap[type]
		if func and self.module[func] then
			-- "[[boss1:Cast-3-2085-2657-32297-432965-00AB7F16F4:432965]]"
			-- "[[boss1:<secret>:<secret>:1]]"
			local unit, castGUID, spellID, castID = strsplit(":", info:match("%[%[(.-)%]%]"))
			if unit:sub(1, 4) == "boss" then -- XXX do i actually need to restrict to the registered unit(s)?
				-- self:Debug(time, type, unit, spellID) -- too spammy
				self.module[func](self.module, type, unit, castGUID, spellID ~= "<secret>" and tonumber(spellID) or -1, tonumber(castID))
			end
		end

	elseif type == "CHAT_MSG_ADDON" then
		local func = eventMap[type]
		if func and info:sub(1, 22) == "RAID_BOSS_WHISPER_SYNC" then
			self.module[func](self.module, select(2, ("#"):split(info)))
		end

	elseif type:sub(1, 8) == "CHAT_MSG" then
		local func = eventMap[type]
		if func and self.module[func] then
			self.module[func](self.module, type, ("#"):split(info))
		end

	-- elseif type == "INSTANCE_ENCOUNTER_ENGAGE_UNIT" then
	-- 	-- instanceEncounterUnits = {}

	elseif type:sub(1, 4) == "IEEU" then
		-- [IEEU boss1] Name#Captain Jolly#GUID#Creature-0-5773-1754-5006-126845-0000154FF6#Health#2040148#MaxHealth#2040148#Exists#true#Visible#true#CanAttack#true#ShowUninteractable#true
		-- [IEEU boss1] Name#<secret>#GUID#<secret>#Health#<secret>#MaxHealth#<secret>#Exists#true#Visible#true#CanAttack#true#ShowUninteractable#true
		-- [IEEU boss2] Name#<secret>#GUID#<secret>#Health#<secret>#MaxHealth#<secret>#Exists#true#Visible#true#CanAttack#true#ShowUninteractable#true
		local unit = type:sub(6)
		if not bossState[unit] then bossState[unit] = {} end
		local name, guid, health, healthMax, exists, visible, canAttack = info:match("Name#(.-)#GUID#(.-)#Health#(.-)#MaxHealth#(.-)#Exists#(.-)#Visible#(.-)#CanAttack#(.-)#ShowUninteractable#(.-)")

		-- check for removed unit to update power and target
		local previousUnit = nil
		for bossUnit, bossInfo in next, bossState do
			if unit == bossUnit then
				break
			elseif bossInfo.guid and bossInfo.guid == guid then
				previousUnit = unit
				break
			end
		end
		local boss
		if previousUnit then
			boss = bossState[previousUnit]
			bossState[previousUnit] = wipe(bossState[unit])
			bossState[unit] = boss
		else
			boss = bossState[unit]
		end
		boss.name = name ~= "<secret>" and name or false
		boss.guid = guid ~= "<secret>" and guid or false
		boss.health = health ~= "<secret>" and tonumber(health) or false
		boss.healthMax = healthMax ~= "<secret>" and tonumber(healthMax) or false
		boss.exists = exists == "true" or false
		boss.visible = visible == "true" or false
		boss.canAttack = canAttack == "true" or false
		boss.target = boss.target or nil
		boss.power = boss.power or 0
		boss.powerMax = boss.powerMax or 100

	elseif type == "UNIT_TARGETABLE_CHANGED" then
		-- -boss1- [CanAttack:true#Exists:true#IsVisible:true#Name:Ulgrax the Devourer#GUID:Creature-0-2085-2657-10253-215657-000022982C#Classification:elite#Health:494309999]
		local unit, canAttack, exists, visible, name, guid, _, health = info:match("%-(.-)%- %[CanAttack:(.-)#Exists:(.-)#IsVisible:(.-)#Name:(.-)#GUID:(.-)#Classification:(.-)#Health:(.-)%]")
		local boss = bossState[unit]
		if boss then
			boss.canAttack = canAttack == "true" or false
			boss.exists = exists == "true" or false
			boss.visible = visible == "true" or false
			boss.name = name ~= "<secret>" and name ~= "??" and name or nil
			-- boss.guid = guid ~= "<secret>" and guid ~= "nil" and guid or nil
			-- boss.health =  health ~= "<secret>" and tonumber(health)
		end
	elseif type == "UNIT_TARGET" then
		-- boss1#Sikran#Target: Tombom#TargetOfTarget: Sikran
		-- boss2#Anub'arash#Target: ??#TargetOfTarget: ??
		-- boss1#<secret>#Target: <secret>#TargetOfTarget: <secret>
		local unit, _, target = strsplit("#", info)
		local boss = bossState[unit]
		if boss then
			target = target:sub(9)
			if target == "<secret>" or target == "??" then
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
		-- avoid win/wipe callbacks to prevent stats
		if self.module:GetEncounterID() == tonumber(id) then
			if tonumber(status) == 1 then
				self.module:SendMessage("BigWigs_Message", nil, nil, ("%s has been defeated"):format(self.module.displayName), GREEN_FONT_COLOR, false, false)
				self.module:PlayVictorySound()
			else
				self.module:SendMessage("BigWigs_Message", nil, nil, ("You were defeated by %s"):format(self.module.displayName), YELLOW_FONT_COLOR, false, false)
				local wipeModule = BigWigs:GetPlugin("Wipe")
				local sound = LibStub("LibSharedMedia-3.0"):Fetch("sound", wipeModule.db.profile.wipeSound, true)
				if sound then
					self.module:PlaySoundFile(sound, "master")
				end
			end
			self:Stop(true)
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
		self:Print(("No log named %q found."):format(logName))
		return
	end
	if not silent then
		self:Print(("Loaded %q"):format(logName))
	end

	local _, zoneId, diff = getLogHeaderInfo(logName)
	if not zoneId then
		self:Print("Unsupported log entry?")
		return
	end
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
	do
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
	end

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
			module:SendMessage("BigWigs_Message", nil, nil, ("%s engaged"):format(module.displayName), YELLOW_FONT_COLOR, false, false)
		else
			module:Engage("NoEngage")
			-- this is ok because we're using the BigWigs_SetStage line to start mid-encounter
			local stage = getLogCurrentStage(log, index)
			if stage and module.stage ~= stage then
				module:SetStage(stage)
			end
			-- module:SendMessage("BigWigs_Message", nil, nil, "Replay started", WHITE_FONT_COLOR, false, false)
		end
		local duration = self.endLogTime - self.startLogTime
		module:SendMessage("BigWigs_StartBar", module, nil, "Log Duration", duration, "Interface\\Icons\\spell_holy_borrowedtime", false)

		self:UpdateGUI()
	end

	local pos = index or self.startIndex
	local timeMod = self.db.profile.speed
	local elapsed = ((GetTime() - self.startTime) * timeMod) + self.startLogTime
	local currentLogTime, nextLogTime
	repeat -- batch events at the same timestamp and catch up from scheduling drift
		currentLogTime = self:DoLine(log[pos])
		pos = pos + 1
		if pos > self.endIndex then
			return self:Play(pos)
		end
		nextLogTime = getLogLineTime(log[pos])
	until nextLogTime > elapsed

	local sleep = math.max((nextLogTime - currentLogTime) / timeMod, 0)
	timer = self:ScheduleTimer(function() self:Play(pos) end, sleep)
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
