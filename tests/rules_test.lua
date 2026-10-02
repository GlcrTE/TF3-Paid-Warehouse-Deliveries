-- Tests for the revenue rules of storage_business.script.tl.
-- Run through tools/check.py, which passes a loader for the compiled mod scripts.

return function(load)
	local r = load("storage_business/storage_business.script.tl").rules
	local results = {}

	local function test(name, fn)
		local ok, err = pcall(fn)
		table.insert(results, { name, ok, err and tostring(err) or "" })
	end

	local function storage(id, class, x, y, value)
		return { id = id, class = class, x = x, y = y, value = value }
	end

	local function ids(list)
		local out = {}
		for _, s in ipairs(list) do
			table.insert(out, s.id .. s.class)
		end
		table.sort(out)
		return table.concat(out, ",")
	end

	local function near(a, b)
		return math.abs(a - b) < 1e-9
	end

	test("one warehouse per type within 1 km earns, the most valuable one", function()
		local got = ids(r.selectEarners({
			storage(1, "BULK", 0, 0, 100),
			storage(2, "BULK", 500, 0, 300),
		}, 1000))
		assert(got == "2BULK", got)
	end)

	test("different storage types do not block each other", function()
		local got = ids(r.selectEarners({
			storage(1, "BULK", 0, 0, 100),
			storage(2, "LIQUID", 10, 0, 100),
			storage(2, "UNIVERSAL", 10, 0, 50),
		}, 1000))
		assert(got == "1BULK,2LIQUID,2UNIVERSAL", got)
	end)

	test("warehouses 1 km or more apart both earn", function()
		local got = ids(r.selectEarners({
			storage(1, "GOODS", 0, 0, 100),
			storage(2, "GOODS", 1000, 0, 100),
			storage(3, "GOODS", 0, 1500, 100),
		}, 1000))
		assert(got == "1GOODS,2GOODS,3GOODS", got)
	end)

	test("empty warehouses do not block others", function()
		local got = ids(r.selectEarners({
			storage(1, "BULK", 0, 0, 0),
			storage(2, "BULK", 100, 0, 5),
		}, 1000))
		assert(got == "2BULK", got)
	end)

	test("blocked warehouse does not block a third one", function()
		local got = ids(r.selectEarners({
			storage(1, "BULK", 0, 0, 300),
			storage(2, "BULK", 800, 0, 200),
			storage(3, "BULK", 1600, 0, 100),
		}, 1000))
		assert(got == "1BULK,3BULK", got)
	end)

	test("ties go to the lower entity id", function()
		local got = ids(r.selectEarners({
			storage(7, "FLATBED", 0, 0, 50),
			storage(3, "FLATBED", 10, 0, 50),
		}, 1000))
		assert(got == "3FLATBED", got)
	end)

	test("cargo factor follows the production chain", function()
		assert(r.cargoFactor("::/cargos/coal/coal.cargo") == 1.0)
		assert(r.cargoFactor("::/cargos/steel/steel.cargo") == 1.5)
		assert(r.cargoFactor("::/cargos/tinned_food/tinned_food.cargo") == 2.0)
		assert(r.cargoFactor("::/cargos/machines/machines.cargo") == 2.5)
		assert(r.cargoFactor("::/cargos/vehicles/vehicles.cargo") == 3.0)
	end)

	test("unknown cargo counts as processed", function()
		assert(r.cargoFactor("some_mod::/cargos/gold/gold.cargo") == 1.5)
		assert(r.cargoFactor(nil) == 1.5)
	end)

	test("rate falls with difficulty", function()
		local easy, normal, hard, veryHard = r.yearlyRate(1, 3, 1), r.yearlyRate(3, 3, 1), r.yearlyRate(4, 3, 1), r.yearlyRate(5, 3, 1)
		assert(easy > normal and normal > hard and hard > veryHard, easy .. " " .. normal .. " " .. hard .. " " .. veryHard)
		assert(near(normal, 12))
	end)

	test("rate follows cargo income setting and mod scale", function()
		assert(near(r.yearlyRate(3, 1, 1), 6))
		assert(near(r.yearlyRate(3, 5, 2), 36))
		assert(near(r.yearlyRate(99, 99, 1), 12), "out of range falls back to normal")
	end)

	test("full universal module of raw material earns a quarter of its upkeep on Normal", function()
		-- 500 units for 360 days at 12 per unit and year
		assert(r.payoutAmount(500 * 360, r.yearlyRate(3, 3, 1), 360) == 6000)
	end)

	test("payout rounds down", function()
		assert(r.payoutAmount(1, 12, 360) == 0)
	end)

	return results
end
