-- Tests for the payment rules of paid_warehouse_deliveries.script.tl.
-- Run through tools/check.py, which passes a loader for the compiled mod scripts.

return function(load)
	local r = load("paid_warehouse_deliveries/paid_warehouse_deliveries.script.tl").rules
	local results = {}

	local function test(name, fn)
		local ok, err = pcall(fn)
		table.insert(results, { name, ok, err and tostring(err) or "" })
	end

	local function near(a, b)
		return math.abs(a - b) < 1e-9
	end

	test("travel distance is the straight line", function()
		assert(near(r.travelDistance(300, 400, 0), 500))
	end)

	test("climbing to the target counts 8x extra, descending does not", function()
		assert(near(r.travelDistance(0, 0, 10), 10 + 80))
		assert(near(r.travelDistance(0, 0, -10), 10))
	end)

	test("price is 25% of the base game's 3.74 per metre on default settings", function()
		assert(near(r.pricePerMetre(3, 0.25), 0.935))
	end)

	test("price follows the cargo income setting", function()
		assert(near(r.pricePerMetre(1, 1.0), 1.87))
		assert(near(r.pricePerMetre(5, 1.0), 5.61))
		assert(near(r.pricePerMetre(99, 1.0), 3.74), "out of range falls back to 100%")
	end)

	test("a cargo item pays only once", function()
		local paid = {}
		assert(r.isUnpaid(paid, 42, 1000))
		paid[42] = 1000
		assert(not r.isUnpaid(paid, 42, 1000))
	end)

	test("a reused entity id with a new production time pays again", function()
		local paid = { [42] = 1000 }
		assert(r.isUnpaid(paid, 42, 5000))
	end)

	test("pruning forgets only items that no longer exist", function()
		local paid = { [1] = 10, [2] = 20, [3] = 30 }
		local dropped = r.prunePaid(paid, function(e, t)
			return e ~= 2
		end)
		assert(dropped == 1)
		assert(paid[1] == 10 and paid[2] == nil and paid[3] == 30)
	end)

	return results
end
