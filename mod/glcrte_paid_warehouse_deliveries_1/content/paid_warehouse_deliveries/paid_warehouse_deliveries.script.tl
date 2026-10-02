-- Paid Warehouse Deliveries
-- When the player's warehouse takes over cargo, its owner pays a handling fee:
-- a share of the delivery price for the distance the cargo has already
-- travelled. The full price is still paid at the final destination.
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
-- The payment per item is a share (mod option, default 25%) of what the base
-- game pays for delivering that cargo over the same distance: the straight-line
-- distance from where the cargo was produced to the warehouse, plus 8x any
-- climb, times the cargo price and the game's cargo income setting
-- (base game economy/cargo_income.script.lua). Short hops earn little, so a
-- warehouse next to a mine is no money machine.
--
-- The game may run the script in several Lua states, so everything that must
-- survive a call (watched and paid items) lives in the script state, which is
-- read and written on every arrival and check. Module variables are only caches.

local MOD_TAG <const> = "[Paid Warehouse Deliveries]"
local SHARE_PARAM <const> = "glcrte_pwd_share"

local CONFIG <const> = {
	-- mod option (1-based index): share of the base game's delivery price
	shares = { 0.10, 0.25, 0.50, 1.0 },
	defaultShare = 2,
	-- the list of warehouses is read again at most this often (fraction of a
	-- day), so new warehouses are found
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

-- Money per metre and cargo item in the base game, measured like this script
-- measures (between construction centres): in-game, clay over 2,349 m paid
-- 8,781, which is 3.74 per metre. Every base game cargo has the same price
-- (cargotype.script constantFn with initialPrice 4 and finalPrice 3.2 gives
-- 3.8; the game measures from slightly different points).
local PRICE_PER_METRE <const> = 3.74
-- the game's cargo income setting (base game difficulty_util)
local CARGO_INCOME_SCALE <const> = { 0.5, 0.75, 1.0, 1.25, 1.5 }

---------------------------------------------------------------------------
-- Payment rules (pure, no game API)
---------------------------------------------------------------------------

-- base game travel distance: straight line plus 8x the climb to the target
local function travelDistance(dx : number, dy : number, dz : number) : number
	return math.sqrt(dx * dx + dy * dy + dz * dz) + 8.0 * math.max(dz, 0.0)
end

-- money per metre of travel distance and cargo item
local function pricePerMetre(cargoIncomeLevel : integer, share : number) : number
	return PRICE_PER_METRE * (CARGO_INCOME_SCALE[cargoIncomeLevel] or 1.0) * share
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

local priceCache : number = nil

-- money per metre and cargo item for this game
local function getPricePerMetre() : number
	if priceCache == nil then
		local all = modParams()
		-- the mod option key is unique, so it is found regardless of how params are namespaced
		local shareIndex = CONFIG.defaultShare
		for __, params in pairs(all) do
			shareIndex = intParam(params, SHARE_PARAM) or shareIndex
		end
		local share = CONFIG.shares[math.max(1, math.min(#CONFIG.shares, shareIndex))]
		local cargoIncomeLevel = intParam(all[""], "advancedOptions.cargoIncome") or 3
		priceCache = pricePerMetre(cargoIncomeLevel, share)
	end
	return priceCache
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

-- position of a construction, or of the construction a subconstruction (e.g.
-- an industry's stock list) belongs to
local function entityPosition(entity : Engine.Entity) : {number}
	if not exists(entity) then
		return nil
	end
	local con : Engine.Component.Construction = api.engine.getComponent(entity, api.type.ComponentType.CONSTRUCTION)
	if con == nil then
		con = api.engine.getComponent(parentConstruction(entity), api.type.ComponentType.CONSTRUCTION)
	end
	if con == nil then
		return nil
	end
	return { con.transf[13], con.transf[14], con.transf[15] }
end

local function cargoName(cargoType : CargoTypeId) : string
	local ok, name = pcall(api.res.cargoTypeRep.getName, cargoType)
	return ok and tostring(name) or tostring(cargoType)
end

-- warehouse entities, their stock lists and constructions -> position of the
-- player's warehouse
local warehouses : {Engine.Entity : {number}} = nil
local warehousesReadAt : integer = nil

local function readWarehouses()
	local out : {Engine.Entity : {number}} = {}
	local player = api.engine.util.getPlayer()
	for __, entity in ipairs(api.engine.getEntitiesWithComponent(api.type.ComponentType.WAREHOUSE) or {}) do
		local wh : Engine.Component.Warehouse = api.engine.getComponent(entity, api.type.ComponentType.WAREHOUSE)
		if wh ~= nil and wh.construction ~= nil and wh.construction >= 0
				and isOwnedBy(entity, player) and isOwnedBy(wh.construction, player) then
			local pos = entityPosition(wh.construction)
			if pos ~= nil then
				for __, e in ipairs({ entity, wh.stockList, wh.construction }) do
					if e ~= nil and e >= 0 then
						out[e] = pos
					end
				end
			end
		end
	end
	warehouses = out
	warehousesReadAt = gameTime()
end

-- position of the player's warehouse an entity (warehouse, its stock list,
-- its construction or a part of it) belongs to, nil if it is none
local function warehousePosition(entity : Engine.Entity) : {number}
	if warehouses == nil or gameTime() - warehousesReadAt >= api.util.getDefaultDayDuration() / CONFIG.refreshPerDay then
		readWarehouses()
	end
	return warehouses[entity] or warehouses[parentConstruction(entity)]
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
-- construction -> warehouse position, empty if there is none), all other
-- stocks in it (entities and their constructions), which take cargo directly,
-- and a description for the diagnostics.
local function stopCatchment(lineEntity : Engine.Entity, stopIndex : integer) : {Engine.Entity : {number}}, {Engine.Entity : boolean}, string
	local inReach : {Engine.Entity : {number}} = {}
	local others : {Engine.Entity : boolean} = {}
	local stations = stopStations(lineEntity, stopIndex)
	local found : {string} = {}
	for __, station in ipairs(stations) do
		for __, e in ipairs(api.engine.system.catchmentAreaSystem.getStationCatchables(station, true) or {}) do
			local pos = warehousePosition(e)
			if pos ~= nil then
				inReach[e] = pos
				inReach[parentConstruction(e)] = pos
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

-- Books income like the base game's transport income. Every account is a
-- separate ledger (verified in-game: income booked only on the vehicle did not
-- reach the player's money), so the amount is booked three times with the
-- vehicle's carrier: on the player (money and finance window), on the line
-- (line statistics) and on the vehicle (vehicle statistics). Without a vehicle
-- it is booked as plain income of the player.
-- centre of an entity's bounding box (like the base game's entity_util)
local function boxCentre(entity : Engine.Entity) : Vec3f
	local bv : Engine.Component.BoundingVolume = api.engine.getComponent(entity, api.type.ComponentType.BOUNDING_VOLUME)
	if bv == nil then
		return nil
	end
	return (bv.bbox.max + bv.bbox.min) * 0.5
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

local function emptyState() : State
	return { lastPrune = gameTime(), pending = 0, paid = {}, watched = {}, unbooked = {} }
end

-- Cargo on board has no stop information (SimEntityAtVehicle.lineStop1 is -1
-- for cargo) and its target (SimCargo.targetOrPickupEntity) is the final
-- destination even when it is unloaded into a warehouse on the way (both
-- verified in-game). So when a vehicle arrives at a stop with a player
-- warehouse in reach, all items on board are watched, and the update checks
-- where they end up.
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

	local s = state:get()
	if s == nil or s.paid == nil then
		s = emptyState()
	end
	s.watched = s.watched or {}
	local now = gameTime()
	local added = 0
	for __, item in ipairs(vehicleItems(data.vehicleEntity)) do
		local simCargo = getSimCargo(item)
		if simCargo ~= nil and s.watched[item] == nil and isUnpaid(s.paid, item, simCargo.startTime) then
			s.watched[item] = { startTime = simCargo.startTime, since = now, vehicle = data.vehicleEntity, line = data.lineEntity }
			added = added + 1
		end
	end
	diag(string.format("vehicle %d, line %d, stop %d: %d items watched; %s",
		data.vehicleEntity, data.lineEntity, data.stopIndex, added, catchment))
	if added > 0 then
		state:set(s)
	end
end

-- cargo item -> warehouse position, for every cargo item in a player warehouse
local function itemsInWarehouses() : {integer : {number}}
	local out : {integer : {number}} = {}
	local player = api.engine.util.getPlayer()
	local stockSystem = api.engine.system.simEntityAtStockSystem
	for __, entity in ipairs(api.engine.getEntitiesWithComponent(api.type.ComponentType.WAREHOUSE) or {}) do
		local wh : Engine.Component.Warehouse = api.engine.getComponent(entity, api.type.ComponentType.WAREHOUSE)
		local pos = wh ~= nil and wh.stockList ~= nil and wh.stockList >= 0 and warehousePosition(entity) or nil
		if pos ~= nil and isOwnedBy(entity, player) then
			local stockList : Engine.Component.StockList = api.engine.getComponent(wh.stockList, api.type.ComponentType.STOCK_LIST)
			for i = 1, stockList ~= nil and #stockList.stocks or 0 do
				-- getStockEntities returns pairs; the cargo item is the element with a SIM_CARGO component
				for __, entry in ipairs(stockSystem.getStockEntities(wh.stockList, (i - 1) as StockId) or {}) do
					local a, b = entry[1] as Engine.Entity, entry[2]
					local item = getSimCargo(b) ~= nil and b or (getSimCargo(a) ~= nil and a or nil)
					if item ~= nil then
						out[item] = pos
					end
				end
			end
		end
	end
	return out
end

-- where a watched cargo item is now: "warehouse" (with the warehouse
-- position), "vehicle", "gone" (delivered or destroyed) or "elsewhere"
-- (between vehicle and stock, or in another stock)
local function locate(item : integer, w : Watched, inWarehouses : {integer : {number}}) : string, {number}
	local simCargo = getSimCargo(item as Engine.Entity)
	if simCargo == nil or simCargo.startTime ~= w.startTime then
		return "gone", nil
	end
	local pos = inWarehouses[item]
	if pos ~= nil then
		return "warehouse", pos
	end
	if api.engine.getComponent(item as Engine.Entity, api.type.ComponentType.SIM_ENTITY_AT_VEHICLE) ~= nil then
		return "vehicle", nil
	end
	return "elsewhere", nil
end

-- pays watched items that are now in a player warehouse and forgets the
-- ones that are gone or watched for longer than a month
local function settle(s : State, now : integer) : boolean
	local month = api.util.getDefaultMonthDuration()
	local done : {integer} = {}
	local paidItems, gone = 0, 0
	local money = 0.0
	-- vehicle -> money earned by the items it brought, and its line
	local byVehicle : {integer : number} = {}
	local lineOf : {integer : integer} = {}
	local itemsOf : {integer : integer} = {}
	local inWarehouses = itemsInWarehouses()
	for item, w in pairs(s.watched) do
		local where, pos = locate(item, w, inWarehouses)
		if where == "warehouse" then
			table.insert(done, item)
			local simCargo = getSimCargo(item as Engine.Entity)
			local source = entityPosition(simCargo.sourceEntity)
			if source ~= nil and isUnpaid(s.paid, item, w.startTime) then
				s.paid[item] = w.startTime
				paidItems = paidItems + 1
				local m = getPricePerMetre() * travelDistance(pos[1] - source[1], pos[2] - source[2], pos[3] - source[3])
				money = money + m
				local v = w.vehicle or -1
				byVehicle[v] = (byVehicle[v] or 0) + m
				itemsOf[v] = (itemsOf[v] or 0) + 1
				lineOf[v] = w.line or -1
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
	if CONFIG.diagnostics and gone > 0 then
		debugPrint(string.format("%s %d watched cargo items did not go into a warehouse", MOD_TAG, gone))
	end

	if now - (s.lastPrune or 0) >= month then
		prunePaid(s.paid, alive)
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
						debugPrint(string.format("%s warehouse delivery income: %d for %d cargo items, vehicle %d", MOD_TAG, amount, u.items, vehicle))
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
		local s = state:get()
		if s == nil or ((s.watched == nil or next(s.watched) == nil) and (s.unbooked == nil or next(s.unbooked) == nil)) then
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
			state:set(s)
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
	travelDistance = travelDistance,
	pricePerMetre = pricePerMetre,
	isUnpaid = isUnpaid,
	prunePaid = prunePaid,
}

return storageBusiness
