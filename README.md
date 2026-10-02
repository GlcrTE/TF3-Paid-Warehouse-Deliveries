# Storage Business (TF3)

A Transport Fever 3 mod that lets warehouses ("Lager" in the German version) earn money for the cargo they store.

## Rules

- Once per in-game day the mod counts the cargo stored in each of your warehouses. At the end of each month it pays out the total as income in the finance journal. Cargo only earns for the days it was actually stored, so filling a warehouse just before the payout earns almost nothing.
- The amounts are kept small: storage income offsets part of a warehouse's upkeep, but storing alone never pays for a warehouse.

### Revenue

Revenue per stored unit and year = **base rate x cargo factor x cargo income setting x mod option**.

The **base rate** follows the game's *infrastructure maintenance* setting, so it differs per difficulty. The difficulty presets set this level (Easy 1, Normal 3, Hard 4, Very Hard 5), so custom settings work too:

| Infrastructure maintenance level | 1 (Easy) | 2 | 3 (Normal) | 4 (Hard) | 5 (Very Hard) |
|---|---|---|---|---|---|
| Per unit of raw material and year | 18 | 15 | 12 | 8 | 5 |

The game's *cargo income* setting scales this further (50% to 150%; 100% in all presets).

The **cargo factor** depends on how far down a production chain the cargo is. Every base game cargo has the same transport price, so the price can't be used here:

| Factor | Cargo |
|---|---|
| 1.0 raw materials | clay, coal, crude oil, fish, grain, iron ore, logs, rubber, sand, stone, vegetables, wool |
| 1.5 made from raw materials | bricks, cement, chemicals, fabric, fertilizer, fuel, glass, meat, planks, sawdust, sheet metal, steel, tires |
| 2.0 made from processed goods | beverages, dyes, furniture, paper, plastic, tinned food |
| 2.5 next step | books, clothes, machines, tools |
| 3.0 | vehicles |

Cargo from other mods counts as 1.5. Universal stocks can hold several cargo types, and each counts with its own factor.

The **mod option** "Storage revenue" scales everything: Low (50%), Normal (100%, default), High (200%).

Example on Normal: a universal module (500 units, 25,000 upkeep a year) earns 6,000 a year when full of coal, and 18,000 when full of vehicles.

### Exploit prevention: one warehouse per storage type within 1 km

The storage type is the cargo class of a stock: universal, liquid, bulk, flatbed or goods. For each type, only one warehouse within a 1 km circle earns money:

1. The warehouse whose stored cargo of that type is worth the most (units x cargo factor) earns.
2. Every other warehouse with the same storage type within 1 km of it earns nothing for that type.
3. Repeat with the next most valuable warehouse that is not excluded yet.

Different storage types do not exclude each other, so a bulk warehouse and a liquid warehouse next to each other both earn. Several modules of the same type in **one** warehouse all count, because adding modules is a normal expansion. Empty warehouses never exclude others. The check runs again every day, so the earning warehouse can change when stock levels change.

## How it works

`content/storage_business/storage_business.gs.lua` registers a game script (`storage_business.script.tl`) on the simulation side:

1. Warehouses are found through the `WAREHOUSE` component, which points to the warehouse's stock list and construction. The position comes from the construction's transform.
2. For each storage stock, `api.engine.util.stock.getStockCargoTypes` and `simEntityAtStockSystem.getStockCountForCargoType` give the stored amount per cargo type. `api.res.cargoTypeRep.getName` gives the cargo name for the cargo factor, and `stock.cargoTypes.cargoClassesIncluded` gives the storage type.
3. The difficulty levels come from `api.engine.config.getModParams()[""]` (`advancedOptions.infrastructureMaintenanceScale`, `advancedOptions.cargoIncome`). They are 1-based, as the base game's `difficulty_util.getScale` shows.
4. The weighted stored units times days are added up in the script state, which is saved with the game. Each month they are booked as `INCOME` with `api.cmd.makeJournalBookAssetCmd`, like the base game's mission rewards. Nothing is booked with infinite money.

Only warehouses owned by the player count (or warehouses without an owner component).

## Status

Type-checked against the game's definitions, with the rules covered by tests. **Not yet tested in-game.** Still to verify:

- The rate logged at game start (`[Storage Business] maintenance level ...`) matches the chosen difficulty and mod option.
- `stock.cargoTypes.cargoClassesIncluded` is readable from a game script.
- How the income shows up in the finance window (the category is `INCOME`, with no carrier).

The game log (`<Steam>\userdata\<your Steam ID>\3493540\local\crash_dump\stdout.txt`) shows lines starting with `[Storage Business]`: the revenue rate, each monthly payout and the first error, if any. Set `debugLog = true` in `storage_business.script.tl` to also log each daily sample.

## Installation

Copy `mod/glcrte_storage_business_1` into your local TF3 mods folder:

```
<Steam>\userdata\<your Steam ID>\3493540\local\mods\
```

Then enable the mod in the game's mod menu. It can be added to running savegames. Counting starts when the mod first runs.

`tools/deploy.ps1` copies the mod into the `staging_area` folder next to `mods`, where it shows up under "My Mods" in the in-game Mod Manager for uploading to mod.io. `tools/deploy.ps1 -Target mods` installs it as a plain local mod instead. Either way the copy in the other folder is removed, so the mod ID never exists twice.

## Development

```
pip install lupa
python tools/check.py [--game "<TF3 install dir>"]
```

This checks that `_content.json` lists every file in `content/`, type-checks all `.tl` scripts against the game's definitions, and runs the tests in `tests/`.

Tuning values (exclusion radius, rates per difficulty, cargo factors) are at the top of `storage_business.script.tl`.

## License

MIT, see [LICENSE](LICENSE).
