# Paid Warehouse Deliveries (TF3)

A Transport Fever 3 mod: when your warehouse takes over cargo, its owner pays you a handling fee, 25% of the delivery price for the distance the cargo has already travelled. The full price is still paid at the final destination.

## Rules

- The base game pays nothing when cargo arrives in a warehouse. It pays only at the final destination, for the whole trip from where the cargo was produced.
- With this mod, the cargo's owner pays you a handling fee once when a vehicle unloads the cargo at a station or stop that has one of your warehouses in its catchment area (the base game's circle) and it goes into the warehouse. You're the transport company and the cargo belongs to its producer, so the fee comes from the owner, not from your own warehouse. Once the vehicle has finished unloading, its money is booked as one amount, shown above the vehicle like base-game income, as transport income of that vehicle, so it also shows up in the vehicle's and the line's income. Storing it longer earns nothing.
- Cargo that the vehicle delivers directly to an industry or town in the same catchment area doesn't pay; the game already pays for that delivery.
- Each cargo item pays the fee only once, ever. Unloading it again at another warehouse, or moving it back and forth between two, earns nothing extra.

### Amount

Fee per cargo item = **share x what the base game pays for delivering cargo over the same distance**.

The distance is the straight line from where the cargo was produced to the warehouse, plus 8x any climb, the way the base game measures deliveries (`economy/cargo_income.script.lua`). The base game pays about 3.74 per metre for every base game cargo (measured in-game: clay delivered over 2,349 m paid 8,781 per item at the industry), scaled by its *cargo income* setting (50% to 150%; 100% in all presets).

The **share** is the mod option "Warehouse handling fee": 10%, 25% (default), 50% or 100%.

Example with default settings: coal produced 4 km from the warehouse pays 4,000 m x 3.74 x 25% = 3,740 per item.

### Why distance counts

Without it, a warehouse right next to a mine would earn the full amount on every item for almost no transport work. Because the payment follows the distance, short hops earn little. At 25% of the normal delivery rate it also shouldn't cover a vehicle's running costs on its own, so hauling cargo to a far-away warehouse just for the payment loses money.

## How it works

`content/paid_warehouse_deliveries/paid_warehouse_deliveries.gs.lua` registers a game script (`paid_warehouse_deliveries.script.tl`) on the simulation side:

1. The script listens to the game's `OnArriveAtStop` event (vehicle, line, stop index).
2. It looks up the stop's stations (`LINE` -> stop -> `STATION_GROUP`) and their catchment area with `catchmentAreaSystem.getStationCatchables(station, true)`, the same circle the base game uses. If none of your warehouses is in it, nothing happens.
3. It notes ("watches") the unpaid cargo items on the vehicle (`simEntityAtVehicleSystem.getVehicle2Cargo2SimEntitesMap`). The vehicle can't tell which items get off: cargo has no stop information (`SIM_ENTITY_AT_VEHICLE.lineStop1` is -1), and its target (`SIM_CARGO.targetOrPickupEntity`) is the final destination even when it is unloaded into a warehouse on the way. Both were checked in-game.
4. 48 times per in-game day, while items are watched, the script reads the contents of your warehouses (`simEntityAtStockSystem.getStockEntities`). A watched item that is now in one of them pays once, measured from its source (`SIM_CARGO.sourceEntity`, position of its construction) to that warehouse. Items still on a vehicle stay watched; items that were delivered or destroyed, or that were watched for a month, are dropped.
5. The paid list stores entity id and production time, because entity ids are reused after delivery. Once a month, items that no longer exist are removed from it. The cargo income level comes from `api.engine.config.getModParams()[""]["advancedOptions.cargoIncome"]` (1-based). The money is booked as `INCOME` with `api.cmd.makeJournalBookAssetCmd`, with the vehicle's carrier (road, rail, tram, air, water), like the base game's transport income. Every account is a separate ledger (checked in-game: income booked only on the vehicle didn't reach the player's money). The money of one vehicle is collected and booked as one amount once no item of it has gone into a warehouse for an in-game day (its unloading is done). The booking on the player carries the vehicle's position, which shows the amount above the vehicle. The amount is booked on three accounts: the player (money and finance window), the line (line statistics) and the vehicle that brought the cargo (vehicle statistics). If the vehicle no longer exists, it's booked as plain income of the player only. Nothing is booked with infinite money.
6. The game runs the script in several Lua states (one per worker thread), so the watched and paid items live only in the script state, which is read and written on every arrival and check. It's saved with the game, so loading a savegame never pays twice.

Why not the game's `OnCalcTicketPrice` event: it fires only for deliveries to the final destination (industries, towns), never for cargo arriving in a warehouse. This was checked in-game.

## Status

Type-checked against the game's definitions, with the rules covered by tests. Tested in-game with two trucks on clay routes:

- Every item unloaded into a warehouse paid once (44 items, about 592 each for about 630 m).
- Unloading the same items at a second warehouse paid nothing.
- The money showed up once each in the bank account, the finance window (road income), the line statistics and the vehicle statistics.
- Each truck's unloading was booked as one amount (about 13,000 for 22 items), shown above the truck like base-game income.

The game logs errors as `[Paid Warehouse Deliveries] error: …`. Set `diagnostics = true` in `paid_warehouse_deliveries.script.tl` to also log:

- the first 10 arrivals per Lua state: `[arrival n] vehicle …, line …, stop …: <n> items watched; catchables …` or `no warehouse in reach`
- every payment: `warehouse delivery income: <amount> for <n> cargo items, vehicle …`
- watched items that didn't go into a warehouse: `<n> watched cargo items did not go into a warehouse`

The game log is `<Steam>\userdata\<your Steam ID>\3493540\local\crash_dump\stdout.txt`.

## Installation

Copy `mod/glcrte_paid_warehouse_deliveries_1` into your local TF3 mods folder:

```
<Steam>\userdata\<your Steam ID>\3493540\local\mods\
```

Then enable the mod in the game's mod menu. It can be added to running savegames. Only cargo unloaded after the mod is added is paid.

`tools/deploy.ps1` copies the mod into the `staging_area` folder next to `mods`, where it shows up under "My Mods" in the in-game Mod Manager for uploading to mod.io. `tools/deploy.ps1 -Target mods` installs it as a plain local mod instead. Either way the copy in the other folder is removed, so the mod ID never exists twice.

## Development

```
pip install lupa
python tools/check.py [--game "<TF3 install dir>"]
```

This checks that `_content.json` lists every file in `content/`, type-checks all `.tl` scripts against the game's definitions, and runs the tests in `tests/`.

Tuning values (shares, diagnostics) are at the top of `paid_warehouse_deliveries.script.tl`.

## License

MIT, see [LICENSE](LICENSE).
