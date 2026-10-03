# Paid Warehouse Deliveries (TF3)

A Transport Fever 3 mod: when your warehouse takes over cargo, its owner pays you a handling fee per item. A well-used warehouse pays for its maintenance and makes a small profit; an idle one only costs money. The full price is still paid at the final destination.

## Rules

- The base game pays nothing when cargo arrives in a warehouse. It pays only at the final destination, for the whole trip from where the cargo was produced.
- With this mod, the cargo's owner pays you a handling fee once when a vehicle unloads the cargo at a station or stop that has one of your warehouses in its catchment area (the base game's circle) and it goes into the warehouse. You're the transport company and the cargo belongs to its producer, so the fee comes from the owner, not from your own warehouse. Once the vehicle has finished unloading, its money is booked as one amount, shown above the vehicle like base-game income, as transport income of that vehicle, so it also shows up in the vehicle's and the line's income. Storing it longer earns nothing.
- Cargo that the vehicle delivers directly to an industry or town in the same catchment area doesn't pay; the game already pays for that delivery.
- Each cargo item pays the fee only once, ever. Unloading it again at another warehouse, or moving it back and forth between two, earns nothing extra.
- Only your own warehouses pay. Warehouses without an owner (e.g. placed by a map) don't.
- When the mod is added to a running game, the cargo already in your warehouses counts as paid.

### Amount

The fee follows the warehouse's **usage** in the current game year. A warehouse is used 100% when it loads or unloads 2 cargo items per second for a whole game year (730 s), which is 1,460 items.

| Items unloaded into the warehouse this year | Fee per item | Fees by then | Usage |
|---|---|---|---|
| 1 - 730 | maintenance / 730 | the yearly maintenance (break-even) | 50% |
| 731 - 1,168 | maintenance x margin / 438 | maintenance + margin | 80% |
| more | 0 | | |

The **maintenance** is the warehouse's yearly maintenance cost as shown in its window, the sum of its modules with the era factor. So every module raises the fee: in 1960 a specialized module costs 160,000 a year and adds 219.18 per item, and a general storage module costs half and adds half. The item counts are the same for every warehouse.

The **margin** is the mod option "Warehouse profit margin": 0%, 10% (default), 25% or 50%. At 0% the fees stop once the maintenance is paid.

Examples in 1960 with the default 10% margin:

| Warehouse | Items 1 - 730 | Items 731 - 1,168 | Truck of 22 items | Fees per year at most |
|---|---|---|---|---|
| 1 specialized module | 219.18 | 36.53 | 4,822 | 176,000 |
| 2 specialized modules | 438.36 | 73.06 | 9,644 | 352,000 |
| 1 specialized + 1 general storage module | 328.77 | 54.79 | 7,233 | 264,000 |
| 1 general storage module | 109.59 | 18.26 | 2,411 | 88,000 |

The year's count starts again on 1 January. The distance the cargo travelled doesn't matter.

### Why usage counts

A warehouse costs maintenance whether it's used or not. With the fee tied to it, a warehouse that handles enough cargo pays for itself, and a busy one makes a small profit and no more, so warehouses don't turn into a money machine. A warehouse that sits mostly empty still costs money.

## How it works

`content/paid_warehouse_deliveries/paid_warehouse_deliveries.gs.lua` registers a game script (`paid_warehouse_deliveries.script.tl`) on the simulation side:

1. The script listens to the game's `OnArriveAtStop` event (vehicle, line, stop index).
2. It looks up the stop's stations (`LINE` -> stop -> `STATION_GROUP`) and their catchment area with `catchmentAreaSystem.getStationCatchables(station, true)`, the same circle the base game uses. If none of your warehouses is in it, nothing happens. The list of your warehouses is read again every 1/8 day, and right away (at most 48 times a day) when a stop has an unknown entity in reach, so a new warehouse is found on the first arrival.
3. It notes ("watches") the unpaid cargo items on the vehicle (`simEntityAtVehicleSystem.getVehicle2Cargo2SimEntitesMap`). An item that is already watched now belongs to this vehicle and line, which brought it here (e.g. after a transfer). The vehicle can't tell which items get off: cargo has no stop information (`SIM_ENTITY_AT_VEHICLE.lineStop1` is -1), and its target (`SIM_CARGO.targetOrPickupEntity`) is the final destination even when it is unloaded into a warehouse on the way. Both were checked in-game.
4. 48 times per in-game day, while items are watched, the script checks them. Only if one is off its vehicle, it reads the contents of your warehouses (`simEntityAtStockSystem.getStockEntities`). A watched item that is now in one of them pays once, at the fee for that warehouse's maintenance and the fees it already earned this game year. The maintenance is the sum of the modules' `MAINTENANCE_COST` (subconstructions, era included); the construction's own value (50,000, without era) counts only if it has no modules. Items still on a vehicle stay watched; items that were delivered or destroyed, or that were watched for a month, are dropped.
5. The paid list stores entity id and production time, because entity ids are reused after delivery. Once a month, items that no longer exist are removed from it. The money is booked as `INCOME` with `api.cmd.makeJournalBookAssetCmd`, with the vehicle's carrier (road, rail, tram, air, water), like the base game's transport income. Every account is a separate ledger (checked in-game: income booked only on the vehicle didn't reach the player's money). The money of one vehicle is collected and booked as one amount once no item of it has gone into a warehouse for an in-game day (its unloading is done). The booking on the player carries the vehicle's position, which shows the amount above the vehicle. The amount is booked on three accounts: the player (money and finance window), the line (line statistics) and the vehicle that brought the cargo (vehicle statistics). If the vehicle no longer exists, it's booked as plain income of the player only. Nothing is booked with infinite money.
6. The game runs the script in several Lua states (one per worker thread), so the watched and paid items live only in the script state, which is read and written on every arrival and check. It's saved with the game, so loading a savegame never pays twice. The arrival handler and the update each read, change and write the whole state, like the base game's own game scripts (`industry_workers.script`), which relies on the game calling them one after another. If one write ever overwrote another (it would lose watched items or pay twice), the state's version and writer tag show it and the game log gets `[Paid Warehouse Deliveries] error: the script state was overwritten by another Lua state …`.

Why not the game's `OnCalcTicketPrice` event: it fires only for deliveries to the final destination (industries, towns), never for cargo arriving in a warehouse. This was checked in-game.

## Status

Type-checked against the game's definitions, with the rules covered by tests.

Tested in-game (1.1) with 8 trucks on a clay line (pit -> warehouse with one specialized module -> industry) for about a game year, 1960 to October 1961:

- All 331 items unloaded into the warehouse paid once, at 219.18 each: 4,822 per full truck, 1,095 for 5 items. None was lost or paid twice.
- The yearly count started again at the new year.
- Loading the cargo again at the warehouse paid nothing.

Tested in-game (1.0):

- Unloading the same items at a second warehouse paid nothing.
- The money showed up once each in the bank account, the finance window (road income), the line statistics and the vehicle statistics.
- Each truck's unloading was booked as one amount, shown above the truck like base-game income.

Not yet tested in-game: reaching break-even and the margin step in one year, the handling of ownerless warehouses, cargo already stored when the mod is added, and transfers between lines.

The game logs errors as `[Paid Warehouse Deliveries] error: …`. Set `diagnostics = true` in `paid_warehouse_deliveries.script.tl` to also log:

- the first 10 arrivals per Lua state: `[arrival n] vehicle …, line …, stop …: <n> items watched; catchables …` or `no warehouse in reach`
- every payment: `warehouse handling fees: <amount> for <n> cargo items, vehicle …`
- each warehouse's maintenance and fees this year: `warehouse …: capacity …, maintenance … per year, earned … of … this year`
- watched items that didn't go into a warehouse: `<n> watched cargo items did not go into a warehouse`

The game log is `<Steam>\userdata\<your Steam ID>\3493540\local\crash_dump\stdout.txt`.

## Installation

Copy `mod/glcrte_paid_warehouse_deliveries_1` into your local TF3 mods folder:

```
<Steam>\userdata\<your Steam ID>\3493540\local\mods\
```

Then enable the mod in the game's mod menu. It can be added to running savegames. Only cargo unloaded after the mod is added is paid; cargo already in your warehouses counts as paid.

`tools/deploy.ps1` copies the mod into the `staging_area` folder next to `mods`, where it shows up under "My Mods" in the in-game Mod Manager for uploading to mod.io. `tools/deploy.ps1 -Target mods` installs it as a plain local mod instead. Either way the copy in the other folder is removed, so the mod ID never exists twice.

## Development

```
pip install lupa
python tools/check.py [--game "<TF3 install dir>"]
```

This checks that `_content.json` lists every file in `content/`, type-checks all `.tl` scripts against the game's definitions, and runs the tests in `tests/`.

Tuning values (margins, item counts, diagnostics) are at the top of `paid_warehouse_deliveries.script.tl`.

## Changelog

### 1.1

- The fee follows the warehouse's usage instead of the distance: the first 730 items a year pay its maintenance, the next 438 pay the profit margin, more pay nothing. Every module raises the fee; a general storage module by half as much as a specialized one.
- The mod option "Warehouse handling fee" (share of the delivery price) is replaced by "Warehouse profit margin" (0%, 10%, 25%, 50%). Savegames that already use the mod start with the default 10%.
- Only your own warehouses pay; warehouses without an owner don't.
- Cargo already in your warehouses when the mod is added counts as paid.
- New warehouses are found on the first arrival.
- Cargo transferred between lines pays the vehicle that brought it to the warehouse.

### 1.0

- First release: a handling fee of a share of the delivery price for the distance the cargo travelled.

## License

MIT, see [LICENSE](LICENSE).
