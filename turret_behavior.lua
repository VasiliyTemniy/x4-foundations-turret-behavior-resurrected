--[[
	VAS Turret Behavior Menu (Resurrected)

	Adds right-click turret-behavior controls (arm/disarm + mode) for the player's
	occupied ship, the map-selected player ships, and the map-selected player
	stations. Buttons are grouped flat by scope:

		All turrets  →  per-size (XL/L/M/S)  →  per-turret-type

	Original design by Berserk Knight (2019). Original mod used morbideth's
	RightClickAPI / G_Work_Around (both broken on current X4). This rewrite drops
	those and registers directly with kuertee UI Extensions' interact-menu
	callbacks instead. All credit for the menu structure and turret-walk logic
	belongs to Berserk Knight.
]]

local ffi = require("ffi")
local C = ffi.C

ffi.cdef[[
	typedef struct {
		UniverseID contextid;
		const char* path;
		const char* group;
	} UpgradeGroup2;
	typedef struct {
		UniverseID currentcomponent;
		const char* currentmacro;
		const char* slotsize;
		uint32_t count;
		uint32_t operational;
		uint32_t total;
	} UpgradeGroupInfo;
	UpgradeGroupInfo GetUpgradeGroupInfo2(UniverseID destructibleid, const char* macroname, UniverseID contextid, const char* path, const char* group, const char* upgradetypename);
	UpgradeGroup GetUpgradeSlotGroup(UniverseID destructibleid, const char* macroname, const char* upgradetypename, size_t slot);
	const char* GetSlotSize(UniverseID defensibleid, UniverseID moduleid, const char* macroname, bool ismodule, const char* upgradetypename, size_t slot);
	uint32_t GetNumStationModules(UniverseID stationid, bool includeconstructions, bool includewrecks);
	uint32_t GetStationModules(UniverseID* result, uint32_t resultlen, UniverseID stationid, bool includeconstructions, bool includewrecks);
]]

local SEC_SELF    = "vas_tb_self"
local SEC_SELECT  = "vas_tb_selected"
local SEC_STATION = "vas_tb_station"
local CALLBACK_ID = "vas_turret_behavior_resurrected"
local ACTION_TYPE = "vas_tb"
local TEXT_PAGE = 202600531

local orig = {}

local VAS = {
	sectionsRegistered = false,
	playerstations = {},
	interactTargetShips = {},
	interactTargetStations = {},
	addedTypeSubsections = {},
	pendingSections = nil,
}

-- One row of buttons inside a turret-behavior subsection.
-- kind = "armed" (bool arg) or "mode" (string arg)
local SHIP_ACTIONS = {
	{ textId = 8622, kind = "armed", arg = true  },
	{ textId = 8623, kind = "armed", arg = false },
	{ textId = 8614, kind = "mode",  arg = "attackenemies"   },
	{ textId = 8634, kind = "mode",  arg = "attackcapital"   },
	{ textId = 8637, kind = "mode",  arg = "prefercapital"   },
	{ textId = 8635, kind = "mode",  arg = "attackfighters"  },
	{ textId = 8638, kind = "mode",  arg = "preferfighters"  },
	{ textId = 8613, kind = "mode",  arg = "defend"          },
	{ textId = 8616, kind = "mode",  arg = "mining"          },
	{ textId = 8615, kind = "mode",  arg = "missiledefence"  },
	{ textId = 8639, kind = "mode",  arg = "prefermissiles"  },
	{ textId = 8617, kind = "mode",  arg = "autoassist"      },
}

-- Stations don't get mining/auto-assist.
local STATION_ACTIONS = {
	{ textId = 8622, kind = "armed", arg = true  },
	{ textId = 8623, kind = "armed", arg = false },
	{ textId = 8614, kind = "mode",  arg = "attackenemies"   },
	{ textId = 8634, kind = "mode",  arg = "attackcapital"   },
	{ textId = 8637, kind = "mode",  arg = "prefercapital"   },
	{ textId = 8635, kind = "mode",  arg = "attackfighters"  },
	{ textId = 8638, kind = "mode",  arg = "preferfighters"  },
	{ textId = 8613, kind = "mode",  arg = "defend"          },
	{ textId = 8615, kind = "mode",  arg = "missiledefence"  },
	{ textId = 8639, kind = "mode",  arg = "prefermissiles"  },
}

local TOWING_ACTION = { textId = 8633, kind = "mode", arg = "towing" }

-- ----------------------------------------------------------------------------
-- Debug logging
-- ----------------------------------------------------------------------------
-- Every line is buffered into logBuffer; flushDebug() concatenates and emits
-- a single DebugError call, so the in-game log shows ONE multi-line block per
-- apply pass instead of dozens of separate "..." entries that are tedious to
-- copy-paste. flushDebug is called at the end of applyCopy and before every
-- early-return inside it; an outer pcall in the event handler guarantees the
-- buffer is flushed even on unexpected errors.
-- ----------------------------------------------------------------------------
-- Debug toggle is driven from the MD side via player.entity.$vas_tb_debug_chance
-- (int 0..100, the conventional debug_to_file `chance` value used across X4
-- modding). Any value > 0 enables logging. Cdef for GetPlayerID is declared
-- further down in the Copy section; we wrap the lookup in a function so the
-- order of declarations doesn't matter -- isDebugEnabled is called lazily.
local cachedPlayerID
local function isDebugEnabled()
    if not cachedPlayerID then
        cachedPlayerID = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
    end
    local chance = GetNPCBlackboard(cachedPlayerID, "$vas_tb_debug_chance")
    return type(chance) == "number" and chance > 0
end

local logBuffer = {}

local function debug(msg)
    if not isDebugEnabled() then return end
    table.insert(logBuffer, "[VAS-TB] " .. tostring(msg))
end

local function flushDebug()
    if #logBuffer == 0 then return end
    if type(DebugError) == "function" then
        DebugError(table.concat(logBuffer, "\n"))
    end
    logBuffer = {}
end

local function debugNow(msg)
	if not isDebugEnabled() then return end
	if type(DebugError) == "function" then
		DebugError("[VAS-TB] " .. tostring(msg))
	end
end

-- Formatting helpers for debug lines.
local function shipName(id)
    if not id or id == 0 then return "<nil>" end
    local n = GetComponentData(id, "name")
    return (n and n ~= "") and n or ("<#" .. tostring(id) .. ">")
end

local function fmtRec(rec)
    if not rec then return "<nil>" end
    local where
    if rec.kind == "slot" then
        where = string.format("slot %d", rec.slotidx or -1)
    else
        where = string.format("group %s|%s", rec.path or "", rec.group or "")
    end
    return string.format("%s %s %s [icon=%s]",
        where,
        rec.size or "?",
        tostring(rec.type or "?"),
        (rec.ammoicon ~= nil and rec.ammoicon ~= "") and rec.ammoicon or "-")
end

-- ============================================================================
-- Helpers
-- ============================================================================

local function getSizeText(size)
	if size == "extralarge" then return ReadText(1001, 48)
	elseif size == "large"   then return ReadText(1001, 49)
	elseif size == "medium"  then return ReadText(1001, 50)
	elseif size == "small"   then return ReadText(1001, 51)
	end
	return ""
end

local function T(id)
	return ReadText(TEXT_PAGE, id)
end

-- Singular hull slots don't expose their size through GetUpgradeSlotGroup —
-- that struct only carries (path, group). C.GetSlotSize is vanilla's
-- authoritative per-slot lookup (see ego_detailmonitor/menu_ship_configuration.lua:4484).
local function getSlotSize(target, slot)
	local s = ffi.string(C.GetSlotSize(target, 0, "", false, "turret", slot))
	if s == "" then s = "medium" end
	return s
end

local function stationModules(station)
	local n = C.GetNumStationModules(station, false, false)
	if n == 0 then return {} end
	local buf = ffi.new("UniverseID[?]", n)
	n = C.GetStationModules(buf, n, station, false, false)
	local modules = {}
	for i = 0, n - 1 do
		modules[#modules + 1] = buf[i]
	end
	return modules
end

local function turretScanTargets(target)
	if C.IsComponentClass(target, "station") then
		return stationModules(target)
	end
	return { target }
end

local function shipsForSelection(menu)
	local ships = {}
	local seen = {}
	local function add(ship)
		if not ship or ship == 0 then return end
		local key = tostring(ship)
		if seen[key] then return end
		seen[key] = true
		ships[#ships + 1] = ship
	end

	for _, ship in ipairs(menu.selectedplayerships) do
		add(ship)
	end
	if menu.removedOccupiedPlayerShip then
		add(menu.removedOccupiedPlayerShip)
	end
	for _, ship in ipairs(VAS.interactTargetShips) do
		add(ship)
	end
	return ships
end

local function stationsForSelection()
	local stations = {}
	local seen = {}
	local function add(station)
		if not station or station == 0 then return end
		local key = tostring(station)
		if seen[key] then return end
		seen[key] = true
		stations[#stations + 1] = station
	end

	for _, station in ipairs(VAS.playerstations) do
		add(station)
	end
	for _, station in ipairs(VAS.interactTargetStations) do
		add(station)
	end
	return stations
end

local function describeComponentSlot(menu)
	local slot = menu and menu.componentSlot
	local component = slot and slot.component or 0
	if not component or component == 0 then
		return "componentSlot=" .. tostring(slot) .. ", component=0"
	end
	local converted = ConvertStringTo64Bit(tostring(component))
	return string.format("componentSlot=%s, component=%s, ship=%s, station=%s, sector=%s, playerowned=%s",
		tostring(slot),
		tostring(component),
		tostring(C.IsComponentClass(component, "ship")),
		tostring(C.IsComponentClass(component, "station")),
		tostring(C.IsComponentClass(component, "sector")),
		tostring(GetComponentData(converted, "isplayerowned")))
end

local function allowTurretMenuForInteractTarget(menu)
	local target = menu.componentSlot and menu.componentSlot.component or 0
	if not target or target == 0 then return true end
	if C.IsComponentClass(target, "ship") or C.IsComponentClass(target, "station") then
		return GetComponentData(ConvertStringTo64Bit(tostring(target)), "isplayerowned") == true
	end
	return true
end

local function snapshotInteractTarget(menu)
	VAS.interactTargetShips = {}
	VAS.interactTargetStations = {}

	local target = menu.componentSlot and menu.componentSlot.component or 0
	if not target or target == 0 then return end
	local converted = ConvertStringTo64Bit(tostring(target))
	if GetComponentData(converted, "isplayerowned") then
		if C.IsComponentClass(target, "ship") then
			VAS.interactTargetShips[#VAS.interactTargetShips + 1] = converted
		elseif C.IsComponentClass(target, "station") then
			VAS.interactTargetStations[#VAS.interactTargetStations + 1] = converted
		end
	end
end

-- ============================================================================
-- Map menu hook: snapshot the player-owned stations from the current selection
-- so the per-display callback can target them.
-- ============================================================================

function VAS.getSelectedComponentCategories()
	VAS.playerstations = {}
	for id, _ in pairs(orig.mapmenu.selectedcomponents) do
		local c = ConvertStringTo64Bit(id)
		if GetComponentData(c, "isplayerowned") and C.IsComponentClass(c, "station") then
			table.insert(VAS.playerstations, c)
		end
	end
	return orig.getSelectedComponentCategories()
end

-- ============================================================================
-- Turret operations
-- ============================================================================

local function setTurretMode(target, mode, size, turretType)
	if turretType == "all"           then C.SetAllTurretModes(target, mode); return end
	if turretType == "allmissile"    then C.SetAllMissileTurretModes(target, mode); return end
	if turretType == "allnonmissile" then C.SetAllNonMissileTurretModes(target, mode); return end

	for _, scanTarget in ipairs(turretScanTargets(target)) do
		local numslots = tonumber(C.GetNumUpgradeSlots(scanTarget, "", "turret"))
		for j = 1, numslots do
			local sg = C.GetUpgradeSlotGroup(scanTarget, "", "turret", j)
			if (ffi.string(sg.path) == "..") and (ffi.string(sg.group) == "") then
				local current = C.GetUpgradeSlotCurrentComponent(scanTarget, "turret", j)
				if current ~= 0 then
					local slotsize = getSlotSize(scanTarget, j)
					local macro = GetComponentData(ConvertStringTo64Bit(tostring(current)), "macro")
					local shortname = GetMacroData(macro, "shortname")
					if size == slotsize and (turretType == nil or turretType == shortname) then
						C.SetWeaponMode(current, mode)
					end
				end
			end
		end

		local n = C.GetNumUpgradeGroups(scanTarget, "")
		local buf = ffi.new("UpgradeGroup2[?]", n)
		n = C.GetUpgradeGroups2(buf, n, scanTarget, "")
		for i = 0, n - 1 do
			if (ffi.string(buf[i].path) ~= "..") or (ffi.string(buf[i].group) ~= "") then
				local g = { context = buf[i].contextid, path = ffi.string(buf[i].path), group = ffi.string(buf[i].group) }
				local gi = C.GetUpgradeGroupInfo2(scanTarget, "", g.context, g.path, g.group, "turret")
				if gi.count > 0 then
					local slotsize = ffi.string(gi.slotsize)
					local shortname = GetMacroData(ffi.string(gi.currentmacro), "shortname")
					if size == slotsize and (turretType == nil or turretType == shortname) then
						C.SetTurretGroupMode2(target, g.context, g.path, g.group, mode)
					end
				end
			end
		end
	end
end

local function setTurretArmed(target, armed, size, turretType)
	if turretType == "all"           then C.SetAllTurretsArmed(target, armed); return end
	if turretType == "allmissile"    then C.SetAllMissileTurretsArmed(target, armed); return end
	if turretType == "allnonmissile" then C.SetAllNonMissileTurretsArmed(target, armed); return end

	for _, scanTarget in ipairs(turretScanTargets(target)) do
		local numslots = tonumber(C.GetNumUpgradeSlots(scanTarget, "", "turret"))
		for j = 1, numslots do
			local sg = C.GetUpgradeSlotGroup(scanTarget, "", "turret", j)
			if (ffi.string(sg.path) == "..") and (ffi.string(sg.group) == "") then
				local current = C.GetUpgradeSlotCurrentComponent(scanTarget, "turret", j)
				if current ~= 0 then
					local slotsize = getSlotSize(scanTarget, j)
					local macro = GetComponentData(ConvertStringTo64Bit(tostring(current)), "macro")
					local shortname = GetMacroData(macro, "shortname")
					if size == slotsize and (turretType == nil or turretType == shortname) then
						C.SetWeaponArmed(current, armed)
					end
				end
			end
		end

		local n = C.GetNumUpgradeGroups(scanTarget, "")
		local buf = ffi.new("UpgradeGroup2[?]", n)
		n = C.GetUpgradeGroups2(buf, n, scanTarget, "")
		for i = 0, n - 1 do
			if (ffi.string(buf[i].path) ~= "..") or (ffi.string(buf[i].group) ~= "") then
				local g = { context = buf[i].contextid, path = ffi.string(buf[i].path), group = ffi.string(buf[i].group) }
				local gi = C.GetUpgradeGroupInfo2(scanTarget, "", g.context, g.path, g.group, "turret")
				if gi.count > 0 then
					local slotsize = ffi.string(gi.slotsize)
					local shortname = GetMacroData(ffi.string(gi.currentmacro), "shortname")
					if size == slotsize and (turretType == nil or turretType == shortname) then
						C.SetTurretGroupArmed(target, g.context, g.path, g.group, armed)
					end
				end
			end
		end
	end
end

-- ============================================================================
-- Copy turret behaviour (mode + armed) from one ship to others
-- ============================================================================

ffi.cdef[[
	UniverseID GetPlayerID(void);
	const char* GetWeaponMode(UniverseID weaponid);
	const char* GetTurretGroupMode2(UniverseID defensibleid, UniverseID contextid, const char* path, const char* group);
	bool IsWeaponArmed(UniverseID weaponid);
	bool IsTurretGroupArmed(UniverseID defensibleid, UniverseID contextid, const char* path, const char* group);
]]

-- Walks every turret on `ship` and returns lookup tables for the copy logic.
--   records       : ordered list (debug + iteration)
--   bySlot        : singular slot index → record
--   byGroup       : "path|group" → record (groups identify by macro-level path+group)
--   byType        : "size:shortname" → first record matching that (size, type)
--   byAmmoicon    : "size:ammoicon" → first record matching that firing style
--   bySize        : size → first record of that size
--   fallback      : the very first record found, or nil if ship has no turrets
--
-- `ammoicon` is the same string the equipment UI uses to render the firing-style
-- icon on each turret card (see ego_detailmonitor/menu_ship_configuration.lua:5654).
-- Identical icons → same firing style (beam vs plasma vs bullet vs missile vs ...).
local function scanTurrets(ship)
	local records, bySlot, byGroup, byType, byAmmoicon, bySize = {}, {}, {}, {}, {}, {}
	local fallback

	debug(string.format("source %s: scanning turrets", shipName(ship)))

	local function record(rec)
		records[#records + 1] = rec
		byType[rec.size .. ":" .. tostring(rec.type)] = byType[rec.size .. ":" .. tostring(rec.type)] or rec
		if rec.ammoicon and rec.ammoicon ~= "" then
			local k = rec.size .. ":" .. rec.ammoicon
			byAmmoicon[k] = byAmmoicon[k] or rec
		end
		bySize[rec.size] = bySize[rec.size] or rec
		fallback = fallback or rec
		debug(string.format("  %s mode=%s armed=%s",
			fmtRec(rec), rec.mode or "?", tostring(rec.armed)))
	end

	local numslots = tonumber(C.GetNumUpgradeSlots(ship, "", "turret"))
	for j = 1, numslots do
		local sg = C.GetUpgradeSlotGroup(ship, "", "turret", j)
		if (ffi.string(sg.path) == "..") and (ffi.string(sg.group) == "") then
			local current = C.GetUpgradeSlotCurrentComponent(ship, "turret", j)
			if current ~= 0 then
				local macro = GetComponentData(ConvertStringTo64Bit(tostring(current)), "macro")
				local rec = {
					kind     = "slot",
					slotidx  = j,
					weaponid = current,
					size     = getSlotSize(ship, j),
					type     = GetMacroData(macro, "shortname"),
					ammoicon = GetMacroData(macro, "ammoicon"),
					mode     = ffi.string(C.GetWeaponMode(current)),
					armed    = C.IsWeaponArmed(current),
				}
				bySlot[j] = rec
				record(rec)
			end
		end
	end

	-- Vanilla sorts groups alphabetically by g.group before display, so the UI's
	-- M1..M6 / L1..L2 labels follow alphabetical group-name order. Mirror that
	-- here so scan order matches what the player sees in the equipment panel —
	-- combined with first-wins below, the UI's M1 (or L1) becomes the canonical
	-- representative when there are duplicates by type / firing-style / size.
	local groups = {}
	local n = C.GetNumUpgradeGroups(ship, "")
	local buf = ffi.new("UpgradeGroup2[?]", n)
	n = C.GetUpgradeGroups2(buf, n, ship, "")
	for i = 0, n - 1 do
		if (ffi.string(buf[i].path) ~= "..") or (ffi.string(buf[i].group) ~= "") then
			groups[#groups + 1] = { context = buf[i].contextid, path = ffi.string(buf[i].path), group = ffi.string(buf[i].group) }
		end
	end
	table.sort(groups, function(a, b) return a.group < b.group end)
	for _, g in ipairs(groups) do
		local gi = C.GetUpgradeGroupInfo2(ship, "", g.context, g.path, g.group, "turret")
		if gi.count > 0 then
			local macro = ffi.string(gi.currentmacro)
			local rec = {
				kind     = "group",
				context  = g.context,
				path     = g.path,
				group    = g.group,
				size     = ffi.string(gi.slotsize),
				type     = GetMacroData(macro, "shortname"),
				ammoicon = GetMacroData(macro, "ammoicon"),
				mode     = ffi.string(C.GetTurretGroupMode2(ship, g.context, g.path, g.group)),
				armed    = C.IsTurretGroupArmed(ship, g.context, g.path, g.group),
			}
			byGroup[g.path .. "|" .. g.group] = rec
			record(rec)
		end
	end

	debug(string.format("  -> %d turret(s) scanned, fallback=%s",
		#records, fmtRec(fallback)))

	return {
		records    = records,
		bySlot     = bySlot,
		byGroup    = byGroup,
		byType     = byType,
		byAmmoicon = byAmmoicon,
		bySize     = bySize,
		fallback   = fallback,
	}
end

local function applyConfigToSlot(weaponid, cfg)
	C.SetWeaponMode(weaponid, cfg.mode)
	C.SetWeaponArmed(weaponid, cfg.armed)
end

local function applyConfigToGroup(ship, context, path, group, cfg)
	C.SetTurretGroupMode2(ship, context, path, group, cfg.mode)
	C.SetTurretGroupArmed(ship, context, path, group, cfg.armed)
end

-- Common (size, ammoicon) lookup tier: same firing-style icon as the destination.
local function sameAmmoicon(destRec, source)
	if not destRec.ammoicon or destRec.ammoicon == "" then return nil end
	return source.byAmmoicon[destRec.size .. ":" .. destRec.ammoicon]
end

-- Per-destination-turret strategies. Each returns (rec, tierName), or
-- (nil, nil) to fall through to source.fallback (handled by applyCopy).
local function pickByType(destRec, source)
	local typeKey = destRec.size .. ":" .. tostring(destRec.type)
	local rec = source.byType[typeKey]
	if rec then return rec, "exact-type" end
	rec = sameAmmoicon(destRec, source)
	if rec then return rec, "same-firing-style" end
	rec = source.bySize[destRec.size]
	if rec then return rec, "same-size" end
	return nil, nil
end

local function pickBySlot(destRec, source)
	local match
	if destRec.kind == "slot" then
		match = source.bySlot[destRec.slotidx]
	else
		match = source.byGroup[destRec.path .. "|" .. destRec.group]
	end
	-- Position match only counts if the slot sizes line up (covers cross-macro mismatches).
	if match and match.size == destRec.size then
		return match, (destRec.kind == "slot") and "same-slot" or "same-group"
	end
	local rec = sameAmmoicon(destRec, source)
	if rec then return rec, "same-firing-style" end
	rec = source.bySize[destRec.size]
	if rec then return rec, "same-size" end
	return nil, nil
end

local function applyCopy(ship, source, pickFn)
	if not source or not source.fallback then return 0 end
	local count = 0

	debug(string.format("target %s: applying", shipName(ship)))

	local function logDecision(destRec, rec, tier)
		debug(string.format("  %s <- %s (from %s) mode=%s armed=%s",
			fmtRec(destRec),
			tier or "global-fallback",
			fmtRec(rec),
			rec.mode or "?",
			tostring(rec.armed)))
	end

	local numslots = tonumber(C.GetNumUpgradeSlots(ship, "", "turret"))
	for j = 1, numslots do
		local sg = C.GetUpgradeSlotGroup(ship, "", "turret", j)
		if (ffi.string(sg.path) == "..") and (ffi.string(sg.group) == "") then
			local current = C.GetUpgradeSlotCurrentComponent(ship, "turret", j)
			if current ~= 0 then
				local macro = GetComponentData(ConvertStringTo64Bit(tostring(current)), "macro")
				local destRec = {
					kind     = "slot",
					slotidx  = j,
					size     = getSlotSize(ship, j),
					type     = GetMacroData(macro, "shortname"),
					ammoicon = GetMacroData(macro, "ammoicon"),
				}
				local rec, tier = pickFn(destRec, source)
				local cfg = rec or source.fallback
				logDecision(destRec, cfg, tier)
				applyConfigToSlot(current, cfg)
				count = count + 1
			end
		end
	end

	-- Same UI-order sort as scanTurrets so the decision log reads top-to-bottom
	-- as M1, M2, ..., L1, L2 etc.
	local groups = {}
	local n = C.GetNumUpgradeGroups(ship, "")
	local buf = ffi.new("UpgradeGroup2[?]", n)
	n = C.GetUpgradeGroups2(buf, n, ship, "")
	for i = 0, n - 1 do
		if (ffi.string(buf[i].path) ~= "..") or (ffi.string(buf[i].group) ~= "") then
			groups[#groups + 1] = { context = buf[i].contextid, path = ffi.string(buf[i].path), group = ffi.string(buf[i].group) }
		end
	end
	table.sort(groups, function(a, b) return a.group < b.group end)
	for _, g in ipairs(groups) do
		local gi = C.GetUpgradeGroupInfo2(ship, "", g.context, g.path, g.group, "turret")
		if gi.count > 0 then
			local macro = ffi.string(gi.currentmacro)
			local destRec = {
				kind     = "group",
				path     = g.path,
				group    = g.group,
				size     = ffi.string(gi.slotsize),
				type     = GetMacroData(macro, "shortname"),
				ammoicon = GetMacroData(macro, "ammoicon"),
			}
			local rec, tier = pickFn(destRec, source)
			local cfg = rec or source.fallback
			logDecision(destRec, cfg, tier)
			applyConfigToGroup(ship, g.context, g.path, g.group, cfg)
			count = count + 1
		end
	end

	debug(string.format("  -> %d turret(s) applied to %s", count, shipName(ship)))
	return count
end

local function readSelectedShipsFromBlackboard()
	local playerid = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
	local data = GetNPCBlackboard(playerid, "$vas_tb_copy")
	if type(data) ~= "table" or type(data.ships) ~= "table" then return nil end
	local out = {}
	for _, v in ipairs(data.ships) do
		local id = ConvertStringTo64Bit(tostring(v))
		if id and id ~= 0 then out[#out + 1] = id end
	end
	return out
end

local function doCopy(modeName, payload, pickFn)
	local ok, err = pcall(function()
		local targetid = ConvertStringTo64Bit(tostring(payload))
		if not targetid or targetid == 0 then
			debug(modeName .. ": invalid target payload")
			return
		end

		debug(string.format("== %s == target=%s", modeName, shipName(targetid)))

		local ships = readSelectedShipsFromBlackboard()
		if not ships or #ships == 0 then
			debug("no selected ships in blackboard, aborting")
			return
		end

		local source = scanTurrets(targetid)
		if not source.fallback then
			debug("target has no turrets, aborting")
			return
		end

		local appliedShips, appliedTurrets, skipped = 0, 0, 0
		for _, ship in ipairs(ships) do
			if ship == targetid then
				skipped = skipped + 1
				debug(string.format("skipping %s (is target)", shipName(ship)))
			else
				local n = applyCopy(ship, source, pickFn)
				if n > 0 then
					appliedShips = appliedShips + 1
					appliedTurrets = appliedTurrets + n
				end
			end
		end

		debug(string.format("== %s done: %d ship(s), %d turret(s), %d skipped ==",
			modeName, appliedShips, appliedTurrets, skipped))
	end)
	if not ok then
		debug("ERROR: " .. tostring(err))
	end
	flushDebug()
end

local function onCopyByType(_, payload) doCopy("CopyByType", payload, pickByType) end
local function onCopyBySlot(_, payload) doCopy("CopyBySlot", payload, pickBySlot) end

-- ============================================================================
-- Button click dispatch
-- ============================================================================

local function applyToShips(menu, applyFn, arg, size, turretType, isSelf)
	if isSelf then
		applyFn(ConvertStringTo64Bit(tostring(C.GetPlayerOccupiedShipID())), arg, size, turretType)
	else
		for _, ship in ipairs(shipsForSelection(menu)) do
			applyFn(ship, arg, size, turretType)
		end
	end
	menu.onCloseElement("close")
end

local function applyToStations(menu, applyFn, arg, size, turretType)
	for _, station in ipairs(stationsForSelection()) do
		applyFn(station, arg, size, turretType)
	end
	menu.onCloseElement("close")
end

-- ============================================================================
-- Section + subsection management
-- ============================================================================

local function findRootSections(sections)
	local idx = {}
	for i, s in ipairs(sections) do
		if     s.id == SEC_SELF    then idx.self = i
		elseif s.id == SEC_SELECT  then idx.selected = i
		elseif s.id == SEC_STATION then idx.station = i
		end
		if idx.self and idx.selected and idx.station then break end
	end
	return idx
end

-- Each size gets two flat sibling subsections at root level:
--   _<size>        — "All L Turrets" — action buttons for every turret of that size
--   _<size>_types  — "L Turrets per Type" — list of group entries, one per discovered type
-- Empty subsections are hidden by kuertee/vanilla, so sizes the player doesn't
-- own show nothing.
local function sizeRow(prefix, size, sizeTextId)
	local sizeWord = string.format(T(30), ReadText(1001, sizeTextId))
	return
		{ id = prefix .. "_" .. size,            text = sizeWord },
		{ id = prefix .. "_" .. size .. "_types", text = string.format(T(31), ReadText(1001, sizeTextId)) }
end

local function baseShipSubsections(prefix)
	local out = { { id = prefix .. "_all", text = T(32) } }
	local xl1, xl2 = sizeRow(prefix, "extralarge", 48); table.insert(out, xl1); table.insert(out, xl2)
	local l1,  l2  = sizeRow(prefix, "large",      49); table.insert(out, l1);  table.insert(out, l2)
	local m1,  m2  = sizeRow(prefix, "medium",     50); table.insert(out, m1);  table.insert(out, m2)
	local s1,  s2  = sizeRow(prefix, "small",      51); table.insert(out, s1);  table.insert(out, s2)
	return out
end

local function baseStationSubsections()
	local out = {
		{ id = SEC_STATION .. "_all",        text = T(32) },
		{ id = SEC_STATION .. "_nonmissile", text = T(33) },
		{ id = SEC_STATION .. "_missile",    text = T(34) },
	}
	local xl1, xl2 = sizeRow(SEC_STATION, "extralarge", 48); table.insert(out, xl1); table.insert(out, xl2)
	local l1,  l2  = sizeRow(SEC_STATION, "large",      49); table.insert(out, l1);  table.insert(out, l2)
	local m1,  m2  = sizeRow(SEC_STATION, "medium",     50); table.insert(out, m1);  table.insert(out, m2)
	local s1,  s2  = sizeRow(SEC_STATION, "small",      51); table.insert(out, s1);  table.insert(out, s2)
	return out
end

-- Fired by kuertee before menu.actions is populated.
-- First call: append our three root sections with base subsections.
-- Subsequent calls: trim any per-type subsections left over from previous opens,
-- so the freshly-equipped turret set is reflected cleanly.
local function onPrepareSections(sections)
	VAS.pendingSections = sections
	VAS.addedTypeSubsections = {}

	if not VAS.sectionsRegistered then
		table.insert(sections, {
			id = SEC_SELF,
			text = T(20),
			isorder = nil,
			isplayerinteraction = true,
			subsections = baseShipSubsections(SEC_SELF),
		})
		table.insert(sections, {
			id = SEC_SELECT,
			text = T(21),
			isorder = nil,
			isplayerinteraction = true,
			subsections = baseShipSubsections(SEC_SELECT),
		})
		table.insert(sections, {
			id = SEC_STATION,
			text = T(22),
			isorder = nil,
			isplayerinteraction = true,
			subsections = baseStationSubsections(),
		})
		VAS.sectionsRegistered = true
		return
	end

	local idx = findRootSections(sections)
	if idx.self     then sections[idx.self].subsections     = baseShipSubsections(SEC_SELF)    end
	if idx.selected then sections[idx.selected].subsections = baseShipSubsections(SEC_SELECT)  end
	if idx.station  then sections[idx.station].subsections  = baseStationSubsections()         end
end

-- Reserve a per-type group's actions list. The group itself is attached to its
-- parent size section via menu.insertInteractionGroup (chemodun nested-group
-- API). Returns (groupId, isNew); callers attach the group on isNew = true.
local function ensureTypeGroup(menu, baseId, size, turretType)
	local typeSuffix = string.gsub(string.lower(turretType), " ", "_")
	local groupId = baseId .. "_" .. size .. "_" .. typeSuffix
	if VAS.addedTypeSubsections[groupId] then return groupId, false end
	menu.actions[groupId] = {}
	VAS.addedTypeSubsections[groupId] = true
	return groupId, true
end

-- ============================================================================
-- Button population
-- ============================================================================

local function populateShipSection(menu, sectionId, size, turretType, isSelf, istug)
	if not menu.actions[sectionId] or #menu.actions[sectionId] > 0 then return end
	for _, a in ipairs(SHIP_ACTIONS) do
		local applyFn = (a.kind == "armed") and setTurretArmed or setTurretMode
		local arg = a.arg
		menu.insertInteractionContent(sectionId, {
			type = ACTION_TYPE,
			text = ReadText(1001, a.textId),
			script = function() applyToShips(menu, applyFn, arg, size, turretType, isSelf) end,
		})
	end
	if istug then
		menu.insertInteractionContent(sectionId, {
			type = ACTION_TYPE,
			text = ReadText(1001, TOWING_ACTION.textId),
			script = function() applyToShips(menu, setTurretMode, TOWING_ACTION.arg, size, turretType, isSelf) end,
		})
	end
end

local function populateStationSection(menu, sectionId, size, turretType)
	if not menu.actions[sectionId] or #menu.actions[sectionId] > 0 then return end
	for _, a in ipairs(STATION_ACTIONS) do
		local applyFn = (a.kind == "armed") and setTurretArmed or setTurretMode
		local arg = a.arg
		menu.insertInteractionContent(sectionId, {
			type = ACTION_TYPE,
			text = ReadText(1001, a.textId),
			script = function() applyToStations(menu, applyFn, arg, size, turretType) end,
		})
	end
end

local function addShipTurretButtons(menu, baseId, size, turretType, isSelf, istug)
	local allId       = baseId .. "_all"
	local sizeId      = baseId .. "_" .. size
	local typesId     = baseId .. "_" .. size .. "_types"
	local typeId, isNewType = ensureTypeGroup(menu, baseId, size, turretType)

	-- Flat root subsections (action buttons only; populated once per open).
	populateShipSection(menu, allId,  nil,  "all", isSelf, false)
	populateShipSection(menu, sizeId, size, nil,   isSelf, false)
	-- Per-type listing goes inside the sibling "_types" root subsection via
	-- chemodun's nested-group navigation. Group buttons are added once per
	-- (size, type); the action buttons for that type are populated lazily.
	if isNewType then
		menu.insertInteractionGroup(typesId, typeId, turretType)
	end
	populateShipSection(menu, typeId, size, turretType, isSelf, istug)
end

local function addStationTurretButtons(menu, size, turretType, ismissileturret)
	local baseId       = SEC_STATION
	local missileId    = baseId .. (ismissileturret and "_missile" or "_nonmissile")
	local missileScope = ismissileturret and "allmissile" or "allnonmissile"
	local allId   = baseId .. "_all"
	local sizeId  = baseId .. "_" .. size
	local typesId = baseId .. "_" .. size .. "_types"
	local typeId, isNewType = ensureTypeGroup(menu, baseId, size, turretType)

	populateStationSection(menu, allId,     nil,  "all")
	populateStationSection(menu, sizeId,    size, nil)
	populateStationSection(menu, missileId, nil,  missileScope)
	if isNewType then
		menu.insertInteractionGroup(typesId, typeId, turretType)
	end
	populateStationSection(menu, typeId, size, turretType)
end

-- ============================================================================
-- Turret discovery (per ship / per station)
-- ============================================================================

local function findShipTurrets(menu, ship, isSelf)
	local baseId = isSelf and SEC_SELF or SEC_SELECT

	local numslots = tonumber(C.GetNumUpgradeSlots(ship, "", "turret"))
	for j = 1, numslots do
		local sg = C.GetUpgradeSlotGroup(ship, "", "turret", j)
		if (ffi.string(sg.path) == "..") and (ffi.string(sg.group) == "") then
			local current = C.GetUpgradeSlotCurrentComponent(ship, "turret", j)
			if current ~= 0 then
				local slotsize  = getSlotSize(ship, j)
				local macro     = GetComponentData(ConvertStringTo64Bit(tostring(current)), "macro")
				local shortname = GetMacroData(macro, "shortname")
				local istug     = GetComponentData(ConvertStringTo64Bit(tostring(current)), "istugweapon")
				addShipTurretButtons(menu, baseId, slotsize, shortname, isSelf, istug)
			end
		end
	end

	local n = C.GetNumUpgradeGroups(ship, "")
	local buf = ffi.new("UpgradeGroup2[?]", n)
	n = C.GetUpgradeGroups2(buf, n, ship, "")
	for i = 0, n - 1 do
		if (ffi.string(buf[i].path) ~= "..") or (ffi.string(buf[i].group) ~= "") then
			local g  = { context = buf[i].contextid, path = ffi.string(buf[i].path), group = ffi.string(buf[i].group) }
			local gi = C.GetUpgradeGroupInfo2(ship, "", g.context, g.path, g.group, "turret")
			if gi.count > 0 then
				local slotsize  = ffi.string(gi.slotsize)
				local shortname = GetMacroData(ffi.string(gi.currentmacro), "shortname")
				local istug     = GetComponentData(ConvertStringTo64Bit(tostring(gi.currentcomponent)), "istugweapon")
				addShipTurretButtons(menu, baseId, slotsize, shortname, isSelf, istug)
			end
		end
	end
end

local function findStationTurrets(menu, station)
	local found = 0
	for _, module in ipairs(stationModules(station)) do
		local numslots = tonumber(C.GetNumUpgradeSlots(module, "", "turret"))
		for j = 1, numslots do
			local sg = C.GetUpgradeSlotGroup(module, "", "turret", j)
			if (ffi.string(sg.path) == "..") and (ffi.string(sg.group) == "") then
				local current = C.GetUpgradeSlotCurrentComponent(module, "turret", j)
				if current ~= 0 then
					local slotsize       = getSlotSize(module, j)
					local macro          = GetComponentData(ConvertStringTo64Bit(tostring(current)), "macro")
					local shortname      = GetMacroData(macro, "shortname")
					local ismissileturret = C.IsComponentClass(current, "missileturret")
					addStationTurretButtons(menu, slotsize, shortname, ismissileturret)
					found = found + 1
				end
			end
		end

		local n = C.GetNumUpgradeGroups(module, "")
		local buf = ffi.new("UpgradeGroup2[?]", n)
		n = C.GetUpgradeGroups2(buf, n, module, "")
		for i = 0, n - 1 do
			if (ffi.string(buf[i].path) ~= "..") or (ffi.string(buf[i].group) ~= "") then
				local g  = { context = buf[i].contextid, path = ffi.string(buf[i].path), group = ffi.string(buf[i].group) }
				local gi = C.GetUpgradeGroupInfo2(module, "", g.context, g.path, g.group, "turret")
				if gi.count > 0 then
					local slotsize       = ffi.string(gi.slotsize)
					local shortname      = GetMacroData(ffi.string(gi.currentmacro), "shortname")
					local ismissileturret = IsMacroClass(ffi.string(gi.currentmacro), "missileturret")
					addStationTurretButtons(menu, slotsize, shortname, ismissileturret)
					found = found + gi.count
				end
			end
		end
	end
	debugNow(string.format("station turret discovery: station=%s, modules=%d, turretentries=%d",
		tostring(station), #stationModules(station), found))
end

-- ============================================================================
-- Per-display entry point
-- ============================================================================

local function onPrepareActions(actions, definedactions)
	local menu = orig.menu
	if not menu then return end
	debugNow("prepareActions: " .. describeComponentSlot(menu))
	if not allowTurretMenuForInteractTarget(menu) then return end
	snapshotInteractTarget(menu)

	local occupiedShip = C.GetPlayerOccupiedShipID()
	if occupiedShip ~= 0 then
		findShipTurrets(menu, ConvertStringTo64Bit(tostring(occupiedShip)), true)
	end

	local selectedShips = shipsForSelection(menu)
	if #selectedShips > 0 then
		local onlyOccupied =
			(occupiedShip ~= 0)
			and (#selectedShips == 1)
			and (selectedShips[1] == ConvertStringTo64Bit(tostring(occupiedShip)))
		if not onlyOccupied then
			for _, ship in ipairs(selectedShips) do
				findShipTurrets(menu, ship, false)
			end
		end
	end

	local selectedStations = stationsForSelection()
	if #selectedStations > 0 then
		for _, station in ipairs(selectedStations) do
			findStationTurrets(menu, station)
		end
	end
end

-- ============================================================================
-- Init
-- ============================================================================

local function init()
	DebugError("VAS_TurretBehavior init")

	for _, m in ipairs(Menus) do
		if m.name == "InteractMenu" then
			orig.menu = m
		elseif m.name == "MapMenu" then
			orig.mapmenu = m
			orig.getSelectedComponentCategories = m.getSelectedComponentCategories
			m.getSelectedComponentCategories = VAS.getSelectedComponentCategories
		end
	end

	if orig.menu and orig.menu.registerCallback then
		orig.menu.registerCallback("prepareSections_on_start",         onPrepareSections, CALLBACK_ID)
		orig.menu.registerCallback("prepareActions_prepare_custom_action", onPrepareActions, CALLBACK_ID)
	else
		DebugError("VAS_TurretBehavior: kuertee UI Extensions InteractMenu not found; cannot register callbacks")
	end

	RegisterEvent("VAS_TB.CopyByType", onCopyByType)
	RegisterEvent("VAS_TB.CopyBySlot", onCopyBySlot)
end

init()
