-- Storage Business
-- Warehouses ("Lager") earn money for the cargo they store. Once per in-game
-- day the stored cargo of every warehouse is sampled. At the end of each month
-- the samples are paid out as income, so cargo only pays for the days it was
-- actually stored.
--
-- The revenue depends on
-- * the cargo: the further down a production chain, the more it earns
--   (raw materials 1x up to vehicles 3x)
-- * the difficulty: the game's infrastructure maintenance level, scaled by its
--   cargo income setting
-- * the mod option (50% / 100% / 200%)
--
-- Exploit prevention: per storage type (the cargo class of a stock: universal,
-- liquid, bulk, flatbed, goods) only one warehouse within a 1 km circle earns.
-- The warehouse whose stored cargo is worth the most wins, the others of the
-- same type within 1 km of it earn nothing for that day.

local MOD_TAG <const> = "[Storage Business]"
local SCALE_PARAM <const> = "glcrte_sb_rate"

local CONFIG <const> = {
	-- m: per storage type, only one warehouse within this distance earns money
	exclusionRadius = 1000.0,
	-- mod option (1-based index): revenue scale
	scales = { 0.5, 1.0, 2.0 },
	defaultScale = 2,
	-- writes every daily sample to the game log
	debugLog = false,
}

-- Money per stored unit of raw material and year, by the game's infrastructure
-- maintenance level (1-based, as in the difficulty presets: Easy 1, Normal 3,
-- Hard 4, Very Hard 5). On Normal a universal module full of raw material
-- (500 units) earns 6,000 a year, a quarter of its 25,000 maintenance. Full of
-- vehicles it earns 18,000, so storing alone never pays for a warehouse.
local YEARLY_RATE_BY_LEVEL <const> = { 18.0, 15.0, 12.0, 8.0, 5.0 }
local DEFAULT_LEVEL <const> = 3
-- the game's cargo income setting (base game difficulty_util)
local CARGO_INCOME_SCALE <const> = { 0.5, 0.75, 1.0, 1.25, 1.5 }

-- Value factor per cargo, by its depth in the production chain:
-- 1 raw, 2 made from raw materials, 3 made from processed goods, and so on.
local CARGO_FACTOR <const> : {string : number} = {
	-- raw materials
	clay = 1.0, coal = 1.0, crude_oil = 1.0, fish = 1.0, grain = 1.0, iron_ore = 1.0,
	logs = 1.0, rubber = 1.0, sand = 1.0, stone = 1.0, vegetables = 1.0, wool = 1.0,
	-- made from raw materials
	bricks = 1.5, cement = 1.5, chemicals = 1.5, fabric = 1.5, fertilizer = 1.5, fuel = 1.5,
	glass = 1.5, meat = 1.5, planks = 1.5, sawdust = 1.5, sheet_metal = 1.5, steel = 1.5,
	tires = 1.5,
	-- made from processed goods
	beverages = 2.0, dyes = 2.0, furniture = 2.0, paper = 2.0, plastic = 2.0, tinned_food = 2.0,
	-- made from goods of the previous step
	books = 2.5, clothes = 2.5, machines = 2.5, tools = 2.5,
	vehicles = 3.0,
}
-- cargo added by other mods
local UNKNOWN_CARGO_FACTOR <const> = 1.5

---------------------------------------------------------------------------
-- Revenue rules (pure, no game API)
---------------------------------------------------------------------------

-- the cargo of one storage type stored in one warehouse
local record Storage
	id : Engine.Entity
	class : string
	x : number
	y : number
	-- stored units weighted by cargo factor
	value : number
end

-- "::/cargos/coal/coal.cargo" -> 1.0
local function cargoFactor(resName : string) : number
	local name = resName ~= nil and resName:match("([%w_]+)%.cargo$") or nil
	return name ~= nil and CARGO_FACTOR[name] or UNKNOWN_CARGO_FACTOR
end

-- money per weighted unit and year for the given (1-based) game settings
local function yearlyRate(maintenanceLevel : integer, cargoIncomeLevel : integer, scale : number) : number
	local rate = YEARLY_RATE_BY_LEVEL[maintenanceLevel] or YEARLY_RATE_BY_LEVEL[DEFAULT_LEVEL]
	return rate * (CARGO_INCOME_SCALE[cargoIncomeLevel] or 1.0) * scale
end

-- Per storage type, the warehouses that earn: the one whose cargo is worth the
-- most earns, every other one of that type within `radius` of it is skipped, and
-- so on. Empty storages neither earn nor block others.
local function selectEarners(storages : {Storage}, radius : number) : {Storage}
	local byClass : {string : {Storage}} = {}
	for __, s in ipairs(storages) do
		if s.value > 0 then
			local list = byClass[s.class]
			if list == nil then
				list = {}
				byClass[s.class] = list
			end
			table.insert(list, s)
		end
	end

	local out : {Storage} = {}
	local r2 = radius * radius
	for __, list in pairs(byClass) do
		table.sort(list, function(a : Storage, b : Storage) : boolean
			if a.value ~= b.value then
				return a.value > b.value
			end
			return a.id < b.id
		end)
		local picked : {Storage} = {}
		for __, s in ipairs(list) do
			local blocked = false
			for __, p in ipairs(picked) do
				local dx, dy = s.x - p.x, s.y - p.y
				if dx * dx + dy * dy < r2 then
					blocked = true
					break
				end
			end
			if not blocked then
				table.insert(picked, s)
				table.insert(out, s)
			end
		end
	end
	return out
end

local function totalValue(earners : {Storage}) : number
	local sum = 0.0
	for __, s in ipairs(earners) do
		sum = sum + s.value
	end
	return sum
end

-- `unitDays` weighted units stored for one day each, at `rate` per unit and year
local function payoutAmount(unitDays : number, rate : number, daysPerYear : number) : integer
	if daysPerYear <= 0 then
		return 0
	end
	return math.floor(unitDays * rate / daysPerYear)
end

---------------------------------------------------------------------------
-- Reading the warehouses
---------------------------------------------------------------------------

local function isOwnedBy(entity : Engine.Entity, player : Engine.Entity) : boolean
	local owned : Engine.Component.PlayerOwned = api.engine.getComponent(entity, api.type.ComponentType.PLAYER_OWNED)
	return owned == nil or owned.player == player
end

local function stockClass(stock : Engine.Component.StockList.Stock) : string
	local set = stock.cargoTypes
	local classes = set ~= nil and set.cargoClassesIncluded or nil
	if classes ~= nil and classes[1] ~= nil then
		return classes[1]
	end
	return "UNIVERSAL"
end

local factorCache : {CargoTypeId : number} = {}

local function cargoTypeFactor(cargoType : CargoTypeId) : number
	local f = factorCache[cargoType]
	if f == nil then
		f = cargoFactor(api.res.cargoTypeRep.getName(cargoType))
		factorCache[cargoType] = f
	end
	return f
end

-- weighted value of the cargo in one stock; universal stocks can hold several cargo types
local function stockValue(stockListEntity : Engine.Entity, stockId : StockId) : number
	local stockSystem = api.engine.system.simEntityAtStockSystem
	local value = 0.0
	for __, cargoType in ipairs(api.engine.util.stock.getStockCargoTypes(stockListEntity, stockId) or {}) do
		local count = stockSystem.getStockCountForCargoType(stockListEntity, stockId, cargoType) or 0
		if count > 0 then
			value = value + count * cargoTypeFactor(cargoType)
		end
	end
	return value
end

local function collectStorages() : {Storage}
	local out : {Storage} = {}
	local player = api.engine.util.getPlayer()
	local storageStock = api.type["enum"].StockListType.StorageStock

	for __, entity in ipairs(api.engine.getEntitiesWithComponent(api.type.ComponentType.WAREHOUSE) or {}) do
		local wh : Engine.Component.Warehouse = api.engine.getComponent(entity, api.type.ComponentType.WAREHOUSE)
		local con : Engine.Component.Construction = nil
		local stockList : Engine.Component.StockList = nil
		if wh ~= nil and wh.construction ~= nil and wh.construction >= 0 then
			con = api.engine.getComponent(wh.construction, api.type.ComponentType.CONSTRUCTION)
		end
		if wh ~= nil and wh.stockList ~= nil and wh.stockList >= 0 then
			stockList = api.engine.getComponent(wh.stockList, api.type.ComponentType.STOCK_LIST)
		end

		if con ~= nil and stockList ~= nil and isOwnedBy(entity, player) and isOwnedBy(wh.construction, player) then
			-- a warehouse with several modules of one type has several stocks of that type
			local byClass : {string : number} = {}
			for i = 1, #stockList.stocks do
				local stock = stockList.stocks[i]
				if stock.type == storageStock then
					local class = stockClass(stock)
					byClass[class] = (byClass[class] or 0) + stockValue(wh.stockList, (i - 1) as StockId)
				end
			end
			for class, value in pairs(byClass) do
				table.insert(out, { id = entity, class = class, x = con.transf[13], y = con.transf[14], value = value })
			end
		end
	end
	return out
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

local rateCache : number = nil

-- money per weighted unit and year
local function getRate() : number
	if rateCache == nil then
		local all = modParams()
		-- the mod option key is unique, so it is found regardless of how params are namespaced
		local scaleIndex = CONFIG.defaultScale
		for __, params in pairs(all) do
			scaleIndex = intParam(params, SCALE_PARAM) or scaleIndex
		end
		local scale = CONFIG.scales[math.max(1, math.min(#CONFIG.scales, scaleIndex))]

		local base = all[""]
		local maintenanceLevel = intParam(base, "advancedOptions.infrastructureMaintenanceScale") or DEFAULT_LEVEL
		local cargoIncomeLevel = intParam(base, "advancedOptions.cargoIncome") or 3
		rateCache = yearlyRate(maintenanceLevel, cargoIncomeLevel, scale)
		debugPrint(string.format("%s maintenance level %d, cargo income level %d, scale %.2f: %.2f per unit of raw material and year",
			MOD_TAG, maintenanceLevel, cargoIncomeLevel, scale, rateCache))
	end
	return rateCache
end

---------------------------------------------------------------------------
-- Game script
---------------------------------------------------------------------------

local record State
	-- game time of the last daily sample
	lastSample : integer
	-- game time of the last monthly payout
	lastPayout : integer
	-- weighted stored units times days since the last payout
	unitDays : number
end

local function log(msg : string)
	if CONFIG.debugLog then
		debugPrint(MOD_TAG .. " " .. msg)
	end
end

local function bookIncome(amount : integer)
	local entry = api.type.JournalEntry.new()
	entry.amount = amount
	entry.time = -1
	entry.category.type = api.type.JournalEntry.Type.INCOME
	api.cmd.sendCommand(api.cmd.makeJournalBookAssetCmd(api.engine.util.getPlayer(), entry, api.type.Vec3f.new(0, 0, 0)))
end

local errorReported = false

local function reportError(err : any)
	if not errorReported then
		errorReported = true
		debugPrint(MOD_TAG .. " error: " .. tostring(err))
	end
end

-- the weighted stored cargo of all warehouses that earn today
local function sample() : number
	local storages = collectStorages()
	local earners = selectEarners(storages, CONFIG.exclusionRadius)
	local value = totalValue(earners)
	log(string.format("sample: %d storages, %d earning, value %.0f", #storages, #earners, value))
	return value
end

local storageBusiness = {}

function storageBusiness.update(_userParams : table, state : GameScriptState<State>, dt : number) : any
	if dt == 0.0 then
		return nil
	end
	local ok, err : boolean, any = pcall(function()
		local timeComp : Engine.Component.GameTime =
			api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME)
		local now = timeComp.gameTime
		local day = api.util.getDefaultDayDuration()
		local month = api.util.getDefaultMonthDuration()
		local daysPerMonth = month / day
		local daysPerYear = api.util.getDefaultYearDuration() / day

		local s = state:get()
		if s == nil or s.lastSample == nil or s.lastPayout == nil or now < s.lastSample then
			-- first run, or the game time was reset: start counting from now
			state:set({ lastSample = now, lastPayout = now, unitDays = 0 })
			return
		end

		local changed = false
		if now - s.lastSample >= day then
			-- after a long gap (e.g. the mod was disabled) at most one month counts
			local days = math.min((now - s.lastSample) / day, daysPerMonth)
			s.unitDays = (s.unitDays or 0) + sample() * days
			s.lastSample = now
			changed = true
		end

		if now - s.lastPayout >= month then
			local amount = payoutAmount(s.unitDays or 0, getRate(), daysPerYear)
			-- no accounting with infinite money
			if amount > 0 and api.engine.util.finance.getPlayersBalance(api.engine.util.getPlayer()) ~= nil then
				bookIncome(amount)
				debugPrint(MOD_TAG .. " storage income: " .. tostring(amount))
			end
			s.unitDays = 0
			s.lastPayout = now
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

-- exposed for tests
;(storageBusiness as any as {string : any})["rules"] = {
	selectEarners = selectEarners,
	totalValue = totalValue,
	payoutAmount = payoutAmount,
	cargoFactor = cargoFactor,
	yearlyRate = yearlyRate,
}

return storageBusiness
