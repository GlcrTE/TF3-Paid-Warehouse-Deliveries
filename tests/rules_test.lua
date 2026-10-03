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
		return math.abs(a - b) < 1e-6
	end

	-- runs a year of items through a warehouse; returns the items that paid,
	-- the money, and the fees of item 1 and of the first item after break-even
	local function year(maintenance, margin)
		local earned, items, first, after = 0, 0, nil, nil
		while true do
			local fee = r.itemFee(maintenance, earned, margin)
			if fee <= 0 then
				break
			end
			items = items + 1
			if items == 1 then
				first = fee
			elseif items == r.BREAK_EVEN_ITEMS + 1 then
				after = fee
			end
			earned = earned + fee
		end
		return items, earned, first, after
	end

	test("a warehouse breaks even at 730 items and makes 10% at 1168", function()
		local items, earned, first, after = year(160000, 0.10)
		assert(near(first, 160000 / 730), tostring(first))
		assert(near(after, 16000 / 438), tostring(after))
		assert(items == 1168, tostring(items))
		assert(near(earned, 176000), tostring(earned))
	end)

	test("the 730th item reaches the maintenance", function()
		local earned = 0
		for i = 1, 730 do
			earned = earned + r.itemFee(160000, earned, 0.10)
		end
		assert(near(earned, 160000), tostring(earned))
	end)

	test("every module raises the fee, the item counts stay", function()
		local items, earned, first = year(320000, 0.10)
		assert(near(first, 2 * 160000 / 730), tostring(first))
		assert(items == 1168, tostring(items))
		assert(near(earned, 352000))
	end)

	test("a general storage module (half the maintenance) raises the fee by half", function()
		assert(near(r.itemFee(80000, 0, 0.10), 0.5 * 160000 / 730))
		assert(near(r.itemFee(160000 + 80000, 0, 0.10), 1.5 * 160000 / 730), "one of each")
	end)

	test("at 0% margin the fees stop at the maintenance", function()
		local items, earned = year(160000, 0.0)
		assert(items == 730, tostring(items))
		assert(near(earned, 160000))
	end)

	test("nothing is paid over the cap", function()
		assert(near(r.itemFee(160000, 176000, 0.10), 0))
		assert(near(r.itemFee(160000, 200000, 0.10), 0), "never negative")
	end)

	test("unknown maintenance pays nothing", function()
		assert(near(r.itemFee(nil, 0, 0.10), 0))
		assert(near(r.itemFee(0, 0, 0.10), 0))
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
