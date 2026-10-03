-- Paid Warehouse Deliveries
-- When the player's warehouse takes over cargo, the cargo's owner pays a flat
-- handling fee per item. A warehouse that is used pays for its maintenance
-- and makes a small profit; an idle one only costs money.
-- Cargo pays once when a vehicle unloads it at a stop that has one of the
-- player's warehouses in its catchment area.
--
-- The base game pays nothing when cargo arrives in a warehouse: it pays only
-- at the final destination, for the whole trip from where the cargo was
-- produced. This script listens to OnArriveAtStop. If the stop's station has a
-- player warehouse in its catchment area (the base game's circle,
-- catchmentAreaSystem.getStationCatchables), the cargo items on the vehicle
-- are watched. A watched item that then shows up in a player warehouse pays
-- once; items delivered directly to an industry or town don't. Each cargo item
-- pays only once, ever, even if it is unloaded at another warehouse later.
-- The money is booked like transport income, on the vehicle that brought the
-- cargo, so it shows up in the vehicle's and the line's income.
--
-- The fee follows the warehouse's usage in the game year (itemFee): at 50%
-- usage the fees pay its maintenance, at 80% they pay the maintenance plus a
-- margin (mod option, default 10%), and more items pay nothing. So a busy
-- warehouse makes a small profit and no more, and the distance the cargo
-- travelled doesn't matter.
--
-- The game may run the script in several Lua states, so everything that must
-- survive a call (watched and paid items) lives in the script state, which is
-- read and written on every arrival and check. Module variables are only caches.
-- update and handleEvent read, change and write the whole state, like the base
-- game's own game scripts (industry_workers.script), which relies on the game
-- calling them one after another. A write that overwrites another Lua state's
-- write would lose watched items or pay twice, so it is detected and logged
-- (readState).

local MOD_TAG <const> = "[Paid Warehouse Deliveries]"
local MARGIN_PARAM <const> = "glcrte_pwd_margin"

local CONFIG <const> = {
	-- mod option (1-based index): profit margin on top of the maintenance
	margins = { 0.0, 0.10, 0.25, 0.50 },
	defaultMargin = 2,
	-- the list of warehouses is read again this often (fraction of a day), so
	-- removed warehouses are forgotten; an unknown entity at a stop reads it
	-- again sooner (checksPerDay), so new warehouses are found right away
	refreshPerDay = 8,
	-- watched cargo items are checked this many times per in-game day
	checksPerDay = 48,
	-- a vehicle's money is booked as one amount once no item of it has gone
	-- into a warehouse for this fraction of a day (its unloading is done)
	unloadQuietPerDay = 1,
	-- also book the income on the line and the vehicle that brought the cargo,
	-- so it shows up in their statistics
	bookOnVehicle = true,
	-- writes every payment and the first arrivals at warehouse stops to the game log
	diagnostics = false,
	-- at most this many detailed arrival lines per Lua state
	diagnosticsLimit = 10,
}

-- Usage: a warehouse is used 100% if it loads or unloads 2 cargo items a
-- second for a whole game year (730 s), 1460 items.
-- items per year at 50% usage: they earn the maintenance (break-even)
local BREAK_EVEN_ITEMS <const> = 730
-- items per year at 80% usage: they earn the maintenance plus the margin
local MARGIN_ITEMS <const> = 1168

---------------------------------------------------------------------------
-- Payment rules (pure, no game API)
---------------------------------------------------------------------------

-- Fee for one cargo item at a warehouse with this yearly maintenance cost
-- that already earned `earned` this year. The first BREAK_EVEN_ITEMS pay
-- maintenance / BREAK_EVEN_ITEMS each, so 50% usage pays the maintenance.
-- The items up to MARGIN_ITEMS share the margin, so 80% usage makes
-- maintenance x margin profit. Items after that pay nothing. 0 if the
-- maintenance is unknown.
-- The fee follows the maintenance, so every module raises it: a specialized
-- module by 160,000 / 730, a general storage module (half the maintenance)
-- by half of that (1960 prices).
local function itemFee(maintenance : number, earned : number, margin : number) : number
	if maintenance == nil or maintenance <= 0 then
		return 0
	end
	-- less than 1 left is rounding, the step is used up
	local left = maintenance - earned
	if left >= 1 then
		return math.min(maintenance / BREAK_EVEN_ITEMS, left)
	end
	left = maintenance * (1 + margin) - earned
	if left < 1 then
		return 0
	end
	return math.min(maintenance * margin / (MARGIN_ITEMS - BREAK_EVEN_ITEMS), left)
end

-- true if the cargo item was not paid yet. Entity ids can be reused after a
-- cargo item is delivered, so an item is identified by its id and its
-- production time.
local function isUnpaid(paid : {integer : integer}, entity : integer, startTime : integer) : boolean
	return paid[entity] ~= startTime
end

-- drops paid cargo items that no longer exist; `alive(entity, startTime)`
-- tells whether the item still exists. Returns the number of dropped items.
local function prunePaid(paid : {integer : integer}, alive : function(integer, integer) : boolean) : integer
	local dead : {integer} = {}
	for entity, startTime in pairs(paid) do
		if not alive(entity, startTime) then
			table.insert(dead, entity)
		end
	end
	for __, entity in ipairs(dead) do
		paid[entity] = nil
	end
	return #dead
end

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

-- all mod params of the game, 1-based option indices
local function modParams() : {string : {string : any}}
	local ok, params = pcall(api.engine.config.getModParams)
	if ok and params ~= nil then
		return params as {string : {string : any}}
	end
	return {}
end

local function intParam(params : {string : any}, key : string) : integer
	local v = params ~= nil and params[key] or nil
	if type(v) == "number" then
		return math.floor(v as number)
	end
	return nil
end

local marginCache : number = nil

-- profit margin on top of the maintenance for this game
local function getMargin() : number
	if marginCache == nil then
		-- the mod option key is unique, so it is found regardless of how params are namespaced
		local index = CONFIG.defaultMargin
		for __, params in pairs(modParams()) do
			index = intParam(params, MARGIN_PARAM) or index
		end
		marginCache = CONFIG.margins[math.max(1, math.min(#CONFIG.margins, index))]
	end
	return marginCache
end

---------------------------------------------------------------------------
-- Reading the game
---------------------------------------------------------------------------

local function gameTime() : integer
	local timeComp : Engine.Component.GameTime =
		api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME)
	return timeComp.gameTime
end

local function isOwnedBy(entity : Engine.Entity, player : Engine.Entity) : boolean
	local owned : Engine.Component.PlayerOwned = api.engine.getComponent(entity, api.type.ComponentType.PLAYER_OWNED)
	return owned == nil or owned.player == player
end

-- true only if the entity has an owner and it is the player
local function ownedByPlayer(entity : Engine.Entity, player : Engine.Entity) : boolean
	local owned : Engine.Component.PlayerOwned = api.engine.getComponent(entity, api.type.ComponentType.PLAYER_OWNED)
	return owned ~= nil and owned.player == player
end

local function exists(entity : Engine.Entity) : boolean
	return entity ~= nil and entity >= 0 and api.engine.entityExists(entity)
end

local function getSimCargo(entity : Engine.Entity) : Engine.Component.SimCargo
	if not exists(entity) then
		return nil
	end
	return api.engine.getComponent(entity, api.type.ComponentType.SIM_CARGO)
end

-- the construction an entity belongs to, or the entity itself
local function parentConstruction(entity : Engine.Entity) : Engine.Entity
	local ok, parent = pcall(api.engine.system.streetConnectorSystem.getConstructionEntityForSubconstruction, entity)
	if ok and parent ~= nil and parent >= 0 then
		return parent
	end
	return entity
end

-- centre of an entity's bounding box (like the base game's entity_util)
local function boxCentre(entity : Engine.Entity) : Vec3f
	local bv : Engine.Component.BoundingVolume = api.engine.getComponent(entity, api.type.ComponentType.BOUNDING_VOLUME)
	if bv == nil then
		return nil
	end
	return (bv.bbox.max + bv.bbox.min) * 0.5
end

-- warehouse entities, their stock lists and constructions -> construction of
-- the player's warehouse, which identifies it
local warehouses : {Engine.Entity : Engine.Entity} = nil
-- warehouse construction -> its stock list
local stockListOf : {Engine.Entity : Engine.Entity} = {}
local warehousesReadAt : integer = nil

local function readWarehouses()
	local out : {Engine.Entity : Engine.Entity} = {}
	local player = api.engine.util.getPlayer()
	for __, entity in ipairs(api.engine.getEntitiesWithComponent(api.type.ComponentType.WAREHOUSE) or {}) do
		local wh : Engine.Component.Warehouse = api.engine.getComponent(entity, api.type.ComponentType.WAREHOUSE)
		-- ownerless warehouses (e.g. placed by a map) don't count
		if wh ~= nil and wh.construction ~= nil and wh.construction >= 0
				and (ownedByPlayer(entity, player) or ownedByPlayer(wh.construction, player))
				and isOwnedBy(entity, player) and isOwnedBy(wh.construction, player) then
			stockListOf[wh.construction] = wh.stockList
			for __, e in ipairs({ entity, wh.stockList, wh.construction }) do
				if e ~= nil and e >= 0 then
					out[e] = wh.construction
				end
			end
		end
	end
	warehouses = out
	warehousesReadAt = gameTime()
end

-- the player's warehouse (its construction) an entity (warehouse, its stock
-- list, its construction or a part of it) belongs to, nil if it is none
local function warehouseOf(entity : Engine.Entity) : Engine.Entity
	local day = api.util.getDefaultDayDuration()
	local age = warehouses ~= nil and gameTime() - warehousesReadAt or nil
	if age == nil or age < 0 or age >= day / CONFIG.refreshPerDay then
		readWarehouses()
		age = 0
	end
	local wh = warehouses[entity] or warehouses[parentConstruction(entity)]
	-- the entity may be a warehouse built since the list was read
	if wh == nil and age >= day / CONFIG.checksPerDay then
		readWarehouses()
		wh = warehouses[entity] or warehouses[parentConstruction(entity)]
	end
	return wh
end

-- maintenance cost of one entity: its MAINTENANCE_COST component, or what
-- the game calculates for it as a subconstruction; 0 if it has none
local function ownMaintenance(entity : Engine.Entity) : number
	local mc : Engine.Component.MaintenanceCost = api.engine.getComponent(entity, api.type.ComponentType.MAINTENANCE_COST)
	if mc ~= nil and mc.maintenanceCost ~= nil and mc.maintenanceCost > 0 then
		return mc.maintenanceCost
	end
	local ok, cost = pcall(api.engine.util.maintenance.calcMaintenanceForSubconstruction, entity)
	if ok and cost ~= nil and cost > 0 then
		return cost
	end
	return 0
end

-- warehouses whose maintenance breakdown was logged (diagnostics)
local maintenanceLogged : {Engine.Entity : boolean} = {}

-- storage capacity of a warehouse construction (all its stocks), for the diagnostics
local function capacityOf(construction : Engine.Entity) : integer
	local list = stockListOf[construction]
	local stockList : Engine.Component.StockList = list ~= nil and api.engine.getComponent(list, api.type.ComponentType.STOCK_LIST) or nil
	local total = 0
	for __, stock in ipairs(stockList ~= nil and stockList.stocks or {}) do
		total = total + (stock.capacity or 0)
	end
	return total
end

-- Yearly maintenance cost of a warehouse construction, nil if unknown: the sum
-- of its modules, which are subconstructions with their own maintenance,
-- era factor included. This is what the warehouse window shows (checked
-- in-game: 160,000 per module, 80,000 for a universal one, in 1960). The
-- construction's own MAINTENANCE_COST is the modules' cost without the era
-- factor (50,000), so it counts only if there are no modules.
local function maintenanceOf(construction : Engine.Entity) : number
	local own = ownMaintenance(construction)
	local total : number = 0
	local parts : {string} = { string.format("own %d", math.floor(own)) }
	local con : Engine.Component.Construction = api.engine.getComponent(construction, api.type.ComponentType.CONSTRUCTION)
	for __, sub in ipairs(con ~= nil and con.subconstructions or {}) do
		local m = ownMaintenance(sub)
		total = total + m
		table.insert(parts, string.format("%d: %d", sub, math.floor(m)))
	end
	if total <= 0 then
		total = own
	end
	if CONFIG.diagnostics and not maintenanceLogged[construction] then
		maintenanceLogged[construction] = true
		debugPrint(string.format("%s warehouse %d maintenance: total %d per year (%s), capacity %d",
			MOD_TAG, construction, math.floor(total), table.concat(parts, ", "), capacityOf(construction)))
	end
	return total > 0 and total or nil
end

-- the stations of a line stop
local function stopStations(lineEntity : Engine.Entity, stopIndex : integer) : {Engine.Entity}
	local line : Engine.Component.Line = api.engine.getComponent(lineEntity, api.type.ComponentType.LINE)
	local stop = line ~= nil and line.stops[stopIndex + 1] or nil
	if stop == nil then
		return {}
	end
	local group : Engine.Component.StationGroup = api.engine.getComponent(stop.stationGroup, api.type.ComponentType.STATION_GROUP)
	return group ~= nil and group.stations or {}
end

-- The catchment area of a stop: the player warehouses in it (entity and its
-- construction -> warehouse, empty if there is none), all other stocks in it
-- (entities and their constructions), which take cargo directly, and a
-- description for the diagnostics.
local function stopCatchment(lineEntity : Engine.Entity, stopIndex : integer) : {Engine.Entity : Engine.Entity}, {Engine.Entity : boolean}, string
	local inReach : {Engine.Entity : Engine.Entity} = {}
	local others : {Engine.Entity : boolean} = {}
	local stations = stopStations(lineEntity, stopIndex)
	local found : {string} = {}
	for __, station in ipairs(stations) do
		for __, e in ipairs(api.engine.system.catchmentAreaSystem.getStationCatchables(station, true) or {}) do
			local wh = warehouseOf(e)
			if wh ~= nil then
				inReach[e] = wh
				inReach[parentConstruction(e)] = wh
				table.insert(found, tostring(e) .. " warehouse")
			else
				others[e] = true
				others[parentConstruction(e)] = true
				local industry = api.engine.getComponent(e, api.type.ComponentType.INDUSTRY) ~= nil
				table.insert(found, tostring(e) .. (industry and " industry" or " other"))
			end
		end
	end
	return inReach, others, string.format("%d stations, catchables: %s", #stations, #found > 0 and table.concat(found, ", ") or "none")
end

-- the cargo items in a vehicle
local function vehicleItems(vehicle : Engine.Entity) : {Engine.Entity}
	local out : {Engine.Entity} = {}
	local byCargo = api.engine.system.simEntityAtVehicleSystem.getVehicle2Cargo2SimEntitesMap()[vehicle] or {}
	for __, items in pairs(byCargo) do
		for __, item in ipairs(items) do
			table.insert(out, item)
		end
	end
	return out
end

-- cargo item -> warehouse, for every cargo item in a player warehouse
local function itemsInWarehouses() : {integer : Engine.Entity}
	local out : {integer : Engine.Entity} = {}
	local player = api.engine.util.getPlayer()
	local stockSystem = api.engine.system.simEntityAtStockSystem
	for __, entity in ipairs(api.engine.getEntitiesWithComponent(api.type.ComponentType.WAREHOUSE) or {}) do
		local wh : Engine.Component.Warehouse = api.engine.getComponent(entity, api.type.ComponentType.WAREHOUSE)
		local construction = wh ~= nil and wh.stockList ~= nil and wh.stockList >= 0 and warehouseOf(entity) or nil
		if construction ~= nil and isOwnedBy(entity, player) then
			local stockList : Engine.Component.StockList = api.engine.getComponent(wh.stockList, api.type.ComponentType.STOCK_LIST)
			for i = 1, stockList ~= nil and #stockList.stocks or 0 do
				-- getStockEntities returns pairs; the cargo item is the element with a SIM_CARGO component
				for __, entry in ipairs(stockSystem.getStockEntities(wh.stockList, (i - 1) as StockId) or {}) do
					local a, b = entry[1] as Engine.Entity, entry[2]
					local item = getSimCargo(b) ~= nil and b or (getSimCargo(a) ~= nil and a or nil)
					if item ~= nil then
						out[item] = construction
					end
				end
			end
		end
	end
	return out
end

---------------------------------------------------------------------------
-- Game script
---------------------------------------------------------------------------

-- a cargo item that was on board when its vehicle arrived at a warehouse stop
local record Watched
	startTime : integer
	-- game time it was added
	since : integer
	-- the vehicle and line that brought it to the warehouse stop
	vehicle : integer
	line : integer
end

-- money a vehicle earned in its current unloading, not booked yet
local record Unbooked
	amount : number
	items : integer
	line : integer
	-- game time of the last item
	last : integer
end

-- fees a warehouse earned in one game year
local record Earned
	year : integer
	amount : number
end

local record State
	-- game time of the last time the paid list was cleaned up
	lastPrune : integer
	-- money earned but not booked yet (less than 1)
	pending : number
	-- cargo item entity -> production time, for every item that was paid
	paid : {integer : integer}
	-- cargo item entity -> watched item, until it is in a warehouse or gone
	watched : {integer : Watched}
	-- vehicle -> money it earned in its current unloading
	unbooked : {integer : Unbooked}
	-- warehouse (construction) -> fees it earned in the current game year
	earned : {integer : Earned}
	-- counts the writes; with the writing Lua state's tag it shows a write
	-- that overwrote another one (readState)
	version : integer
	writer : string
end

-- the journal carrier of a vehicle (road, rail, ...), nil if unknown
local function journalCarrier(vehicle : Engine.Entity) : any
	local tv : Engine.Component.TransportVehicle = api.engine.getComponent(vehicle, api.type.ComponentType.TRANSPORT_VEHICLE)
	if tv == nil then
		return nil
	end
	local c = api.type["enum"].Carrier
	local j = api.type.JournalEntry.Carrier
	local map : {any : any} = {
		[c.ROAD] = j.ROAD, [c.RAIL] = j.RAIL, [c.TRAM] = j.TRAM, [c.AIR] = j.AIR, [c.WATER] = j.WATER,
	}
	return map[tv.carrier] or j.OTHER
end

-- position of a vehicle: its first carriage (trains) or the vehicle itself
local function vehiclePosition(vehicle : Engine.Entity) : Vec3f
	local carriages : Engine.Component.CarriageList = api.engine.getComponent(vehicle, api.type.ComponentType.CARRIAGE_LIST)
	if carriages ~= nil and #carriages.carriages > 0 then
		local pos = boxCentre(carriages.carriages[1] as Engine.Entity)
		if pos ~= nil then
			return pos
		end
	end
	return boxCentre(vehicle)
end

-- Books income like the base game's transport income. Every account is a
-- separate ledger (verified in-game: income booked only on the vehicle did not
-- reach the player's money), so the amount is booked three times with the
-- vehicle's carrier: on the player (money and finance window), on the line
-- (line statistics) and on the vehicle (vehicle statistics). Without a vehicle
-- it is booked as plain income of the player.
local function bookIncome(amount : integer, vehicle : Engine.Entity, line : Engine.Entity)
	local carrier : any = nil
	local pos : Vec3f = nil
	if exists(vehicle) then
		carrier = journalCarrier(vehicle)
		pos = vehiclePosition(vehicle)
	end
	-- the position shows the amount above the vehicle, like base game income
	local function book(account : Engine.Entity, at : Vec3f)
		local entry = api.type.JournalEntry.new()
		entry.amount = amount
		entry.time = -1
		entry.category.type = api.type.JournalEntry.Type.INCOME
		if carrier ~= nil then
			(entry.category as {string : any}).carrier = carrier
		end
		api.cmd.sendCommand(api.cmd.makeJournalBookAssetCmd(account, entry, at or api.type.Vec3f.new(0, 0, 0)))
	end
	book(api.engine.util.getPlayer(), pos)
	if CONFIG.bookOnVehicle and carrier ~= nil then
		if exists(line) then
			book(line, nil)
		end
		book(vehicle, nil)
	end
end

local errorReported = false

local function reportError(err : any)
	if not errorReported then
		errorReported = true
		debugPrint(MOD_TAG .. " error: " .. tostring(err))
	end
end

local diagCount = 0

local function diag(msg : string)
	if CONFIG.diagnostics and diagCount < CONFIG.diagnosticsLimit then
		diagCount = diagCount + 1
		debugPrint(string.format("%s [arrival %d] %s", MOD_TAG, diagCount, msg))
	end
end

local function alive(entity : integer, startTime : integer) : boolean
	local simCargo = getSimCargo(entity as Engine.Entity)
	return simCargo ~= nil and simCargo.startTime == startTime
end

-- The state of a game that didn't have the mod yet. Cargo already in the
-- player's warehouses counts as paid, so only cargo unloaded from now on pays.
local function newState() : State
	local paid : {integer : integer} = {}
	for item in pairs(itemsInWarehouses()) do
		local simCargo = getSimCargo(item as Engine.Entity)
		if simCargo ~= nil then
			paid[item] = simCargo.startTime
		end
	end
	return { lastPrune = gameTime(), pending = 0, paid = paid, watched = {}, unbooked = {}, earned = {} }
end

-- tag of this Lua state and the version of the state it wrote last
local stateTag : string = nil
local lastWritten : integer = nil
local raceReported = false

-- Reads the state. If it has the version this Lua state wrote last, but from
-- another writer, that writer overwrote this Lua state's write with a copy it
-- had read before: the update and the arrival handler ran at the same time.
local function readState(state : GameScriptState<State>) : State
	local s = state:get()
	if s ~= nil and lastWritten ~= nil and s.version == lastWritten and s.writer ~= stateTag and not raceReported then
		raceReported = true
		debugPrint(string.format("%s error: the script state was overwritten by another Lua state (version %d); payments may be lost or doubled",
			MOD_TAG, lastWritten))
	end
	return s
end

local function writeState(state : GameScriptState<State>, s : State)
	if stateTag == nil then
		stateTag = tostring({}) .. "/" .. tostring(math.random(1, 1000000000))
	end
	s.version = (s.version or 0) + 1
	s.writer = stateTag
	lastWritten = s.version
	state:set(s)
end

-- Cargo on board has no stop information (SimEntityAtVehicle.lineStop1 is -1
-- for cargo) and its target (SimCargo.targetOrPickupEntity) is the final
-- destination even when it is unloaded into a warehouse on the way (both
-- verified in-game). So when a vehicle arrives at a stop with a player
-- warehouse in reach, all items on board are watched, and the update checks
-- where they end up. An item that is already watched now belongs to this
-- vehicle, which brought it here (e.g. after a transfer).
local function onArriveAtStop(state : GameScriptState<State>, data : ArriveAtStop)
	local player = api.engine.util.getPlayer()
	if not exists(data.vehicleEntity) or not isOwnedBy(data.vehicleEntity, player) then
		return
	end
	local inReach, _others, catchment = stopCatchment(data.lineEntity, data.stopIndex)
	if next(inReach) == nil then
		diag(string.format("vehicle %d, line %d, stop %d: no warehouse in reach; %s",
			data.vehicleEntity, data.lineEntity, data.stopIndex, catchment))
		return
	end

	local s = readState(state)
	if s == nil or s.paid == nil then
		s = newState()
	end
	s.watched = s.watched or {}
	local now = gameTime()
	local added = 0
	for __, item in ipairs(vehicleItems(data.vehicleEntity)) do
		local simCargo = getSimCargo(item)
		if simCargo ~= nil and isUnpaid(s.paid, item, simCargo.startTime) then
			local w = s.watched[item]
			if w == nil or w.startTime ~= simCargo.startTime or w.vehicle ~= data.vehicleEntity or w.line ~= data.lineEntity then
				s.watched[item] = { startTime = simCargo.startTime, since = now, vehicle = data.vehicleEntity, line = data.lineEntity }
				added = added + 1
			end
		end
	end
	diag(string.format("vehicle %d, line %d, stop %d: %d items watched; %s",
		data.vehicleEntity, data.lineEntity, data.stopIndex, added, catchment))
	if added > 0 then
		writeState(state, s)
	end
end

-- where a watched cargo item is now: "warehouse" (with the warehouse),
-- "vehicle", "gone" (delivered or destroyed) or "elsewhere" (between vehicle
-- and stock, or in another stock)
-- `scan` returns all items in the player's warehouses; it is called only for
-- items that are off their vehicle, so the contents of every warehouse are
-- not read while all watched items are still on board.
local function locate(item : integer, w : Watched, scan : function() : {integer : Engine.Entity}) : string, Engine.Entity
	local simCargo = getSimCargo(item as Engine.Entity)
	if simCargo == nil or simCargo.startTime ~= w.startTime then
		return "gone", nil
	end
	if api.engine.getComponent(item as Engine.Entity, api.type.ComponentType.SIM_ENTITY_AT_VEHICLE) ~= nil then
		return "vehicle", nil
	end
	local wh = scan()[item]
	if wh ~= nil then
		return "warehouse", wh
	end
	return "elsewhere", nil
end

-- the game year of a game time
local function yearOf(time : integer) : integer
	return math.floor(time / api.util.getDefaultYearDuration())
end

-- pays watched items that are now in a player warehouse and forgets the
-- ones that are gone or watched for longer than a month
local function settle(s : State, now : integer) : boolean
	local month = api.util.getDefaultMonthDuration()
	local done : {integer} = {}
	local paidItems, gone, capped = 0, 0, 0
	local year = yearOf(now)
	local margin = getMargin()
	s.earned = s.earned or {}
	-- warehouse -> its maintenance (-1 if unknown), for the diagnostics
	local touched : {integer : number} = {}
	-- vehicle -> money earned by the items it brought, and its line
	local byVehicle : {integer : number} = {}
	local lineOf : {integer : integer} = {}
	local itemsOf : {integer : integer} = {}
	local scanned : {integer : Engine.Entity} = nil
	local function scan() : {integer : Engine.Entity}
		scanned = scanned or itemsInWarehouses()
		return scanned
	end
	for item, w in pairs(s.watched) do
		local where, wh = locate(item, w, scan)
		if where == "warehouse" then
			table.insert(done, item)
			if isUnpaid(s.paid, item, w.startTime) then
				s.paid[item] = w.startTime
				local e = s.earned[wh]
				if e == nil or e.year ~= year then
					e = { year = year, amount = 0 }
					s.earned[wh] = e
				end
				local maintenance = maintenanceOf(wh)
				local m = itemFee(maintenance, e.amount, margin)
				e.amount = e.amount + m
				touched[wh] = maintenance or -1
				if m > 0 then
					paidItems = paidItems + 1
					local v = w.vehicle or -1
					byVehicle[v] = (byVehicle[v] or 0) + m
					itemsOf[v] = (itemsOf[v] or 0) + 1
					lineOf[v] = w.line or -1
				else
					capped = capped + 1
				end
			end
		elseif where == "gone" or now - w.since >= month then
			table.insert(done, item)
			gone = gone + 1
		end
	end
	for __, item in ipairs(done) do
		s.watched[item] = nil
	end
	if #done == 0 then
		return false
	end

	-- one payment per vehicle and unloading, like the base game: the money is
	-- collected per vehicle and booked when no item has arrived for a while
	s.unbooked = s.unbooked or {}
	for vehicle, m in pairs(byVehicle) do
		local u = s.unbooked[vehicle] or { amount = 0, items = 0, line = lineOf[vehicle] }
		u.amount = u.amount + m
		u.items = u.items + itemsOf[vehicle]
		u.last = now
		s.unbooked[vehicle] = u
	end
	if CONFIG.diagnostics then
		if gone > 0 then
			debugPrint(string.format("%s %d watched cargo items did not go into a warehouse", MOD_TAG, gone))
		end
		for wh, maintenance in pairs(touched) do
			debugPrint(string.format("%s warehouse %d: capacity %d, maintenance %d per year, earned %d of %d this year%s",
				MOD_TAG, wh, capacityOf(wh), math.floor(maintenance), math.floor(s.earned[wh].amount), math.floor(maintenance * (1 + margin)),
				capped > 0 and string.format(" (%d items over the cap)", capped) or ""))
		end
	end

	if now - (s.lastPrune or 0) >= month then
		prunePaid(s.paid, alive)
		-- forget past years and removed warehouses
		local old : {integer} = {}
		for wh, e in pairs(s.earned) do
			if e.year ~= year or not exists(wh as Engine.Entity) then
				table.insert(old, wh)
			end
		end
		for __, wh in ipairs(old) do
			s.earned[wh] = nil
		end
		s.lastPrune = now
	end
	return true
end

local storageBusiness = {}

-- books the money of vehicles that finished unloading; returns true if
-- anything was booked
local function flush(s : State, now : integer) : boolean
	if s.unbooked == nil or next(s.unbooked) == nil then
		return false
	end
	local quiet = api.util.getDefaultDayDuration() / CONFIG.unloadQuietPerDay
	-- no accounting with infinite money
	local finiteMoney = api.engine.util.finance.getPlayersBalance(api.engine.util.getPlayer()) ~= nil
	local done : {integer} = {}
	for vehicle, u in pairs(s.unbooked) do
		if now - u.last >= quiet or now < u.last then
			table.insert(done, vehicle)
			-- fractions are carried over to the next payment
			s.pending = (s.pending or 0) + u.amount
			local amount = math.floor(s.pending)
			if amount > 0 then
				s.pending = s.pending - amount
				if finiteMoney then
					bookIncome(amount, vehicle as Engine.Entity, u.line as Engine.Entity)
					if CONFIG.diagnostics then
						debugPrint(string.format("%s warehouse handling fees: %d for %d cargo items, vehicle %d", MOD_TAG, amount, u.items, vehicle))
					end
				end
			end
		end
	end
	for __, vehicle in ipairs(done) do
		s.unbooked[vehicle] = nil
	end
	return #done > 0
end

-- game time this Lua state last checked the watched items; only saves
-- reading the state on every update
local lastCheck : integer = nil

function storageBusiness.update(_userParams : table, state : GameScriptState<State>, dt : number) : any
	if not state:hasEventSubscriptions() then
		state:subscribeToEvent("OnArriveAtStop")
	end
	if dt == 0.0 then
		return nil
	end
	local ok, err : boolean, any = pcall(function()
		local now = gameTime()
		if lastCheck ~= nil and now >= lastCheck and now - lastCheck < api.util.getDefaultDayDuration() / CONFIG.checksPerDay then
			return
		end
		lastCheck = now
		local s = readState(state)
		if s == nil or s.paid == nil then
			-- first update after the mod was added: note the cargo already stored
			writeState(state, newState())
			return
		end
		if (s.watched == nil or next(s.watched) == nil) and (s.unbooked == nil or next(s.unbooked) == nil) then
			return
		end
		local changed = false
		if s.watched ~= nil and next(s.watched) ~= nil then
			changed = settle(s, now)
		end
		if flush(s, now) then
			changed = true
		end
		if changed then
			writeState(state, s)
		end
	end)
	if not ok then
		reportError(err)
	end
	return nil
end

function storageBusiness.handleEvent(_userParams : table, state : GameScriptState<State>, _src : string, id : string, name : string, param : any) : any
	if id ~= "TransportVehicleSystem" or name ~= "OnArriveAtStop" then
		return nil
	end
	local ok, err : boolean, any = pcall(onArriveAtStop, state, param as ArriveAtStop)
	if not ok then
		reportError(err)
	end
	return nil
end

-- exposed for tests
;(storageBusiness as any as {string : any})["rules"] = {
	BREAK_EVEN_ITEMS = BREAK_EVEN_ITEMS,
	MARGIN_ITEMS = MARGIN_ITEMS,
	itemFee = itemFee,
	isUnpaid = isUnpaid,
	prunePaid = prunePaid,
}

return storageBusiness
