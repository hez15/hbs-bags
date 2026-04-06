# hbs-bags — FiveM Wearable Backpack System

A production-ready, secure wearable backpack system for FiveM servers running **QBX Core** with **ox_inventory**, **ox_lib**, **ox_target**, and **illenium-appearance**.

## Features

- **Wearable backpacks** with visible clothing synced to all players
- **Per-backpack stash storage** — each physical backpack item has its own persistent stash
- **Durability system** — backpacks degrade and can be repaired
- **Upgrade system** — reinforced fabric increases capacity (slots and weight)
- **Rename system** — players can give backpacks custom display names
- **Full interaction menu** — context menu with Open, Equip, Unequip, Rename, Repair, Upgrade, Inspect
- **Anti-duplication** — server-authoritative validation prevents stash spoofing and item duplication
- **Anti bag-in-bag** — backpack items cannot be placed inside stashes or containers
- **Networked visuals** — backpack clothing is visible to all players, persists on relog

## Dependencies

| Resource | Required |
|---|---|
| [qbx_core](https://github.com/Qbox-project/qbx_core) | Yes |
| [ox_inventory](https://github.com/overextended/ox_inventory) | Yes |
| [ox_lib](https://github.com/overextended/ox_lib) | Yes |
| [ox_target](https://github.com/overextended/ox_target) | Yes |
| [illenium-appearance](https://github.com/iLLeniumStudios/illenium-appearance) | Yes |

## Installation

### 1. Place the resource

Copy the `hbs-bags` folder into your server's `resources/` directory.

### 2. Add to server.cfg

```cfg
# Make sure dependencies start before hbs-bags
ensure ox_lib
ensure ox_inventory
ensure ox_target
ensure qbx_core
ensure illenium-appearance
ensure hbs-bags
```

### 3. Add items to ox_inventory

Add the following to your `ox_inventory/data/items.lua`:

```lua
['small_backpack'] = {
    label = 'Small Backpack',
    weight = 500,
    stack = false,
    consume = 0,
    close = true,
},

['medium_backpack'] = {
    label = 'Medium Backpack',
    weight = 750,
    stack = false,
    consume = 0,
    close = true,
},

['large_backpack'] = {
    label = 'Large Backpack',
    weight = 1000,
    stack = false,
    consume = 0,
    close = true,
},

['bag_repair_kit'] = {
    label = 'Bag Repair Kit',
    weight = 200,
    stack = true,
    consume = 0,
    close = true,
},

['reinforced_fabric'] = {
    label = 'Reinforced Fabric',
    weight = 300,
    stack = true,
    consume = 0,
    close = true,
},
```

> **Important:** Backpack items must have `stack = false` so each one is a unique instance with its own metadata.

### 4. Configure backpack types

Edit `shared/config.lua` to customize backpack types, clothing drawables, repair/upgrade settings, and more.

**Clothing drawables:** You must set the correct GTA V ped component drawable/texture IDs for component 5 (Bags) for both male and female models. Use a clothing tool or illenium-appearance's wardrobe to find the correct values for your server.

### 5. Restart server

```
ensure hbs-bags
```

## Configuration

All configuration is in `shared/config.lua`.

### Backpack Types

```lua
Config.Backpacks = {
    small_backpack = {
        item = 'small_backpack',
        label = 'Small Backpack',
        slots = 15,
        weight = 15000,
        male = { drawable = 45, texture = 0 },
        female = { drawable = 45, texture = 0 },
        allowUnequip = true,
        toggleUse = true,
    },
}
```

- `slots` — number of inventory slots in the stash
- `weight` — maximum weight capacity in grams
- `male/female` — GTA ped component 5 drawable and texture IDs
- `allowUnequip` — whether the player can unequip this backpack
- `toggleUse` — if true, using the item while equipped toggles unequip; if false, opens stash

### Rename

```lua
Config.Rename = {
    enabled = true,
    maxLength = 24,
}
```

### Repair

```lua
Config.Repair = {
    enabled = true,
    item = 'bag_repair_kit',
    amount = 25,
}
```

### Upgrades

```lua
Config.Upgrades = {
    reinforced_fabric = {
        item = 'reinforced_fabric',
        label = 'Reinforced Fabric',
        addSlots = 5,
        addWeight = 5000,
        maxApplications = 3,
    },
}
```

## How It Works

### Metadata System

Every backpack item carries metadata:

```lua
metadata = {
    backpackId = "bag_XX1a2b3c",   -- permanent unique ID, server-generated
    backpackType = "small_backpack", -- config key
    customName = "My Bag",           -- display only, never affects stash
    durability = 100,                -- 0–100
    upgrades = {
        reinforced_fabric = 2,       -- number of times applied
    },
}
```

- `backpackId` is generated server-side when the item is first created and **never changes**
- `customName` is purely cosmetic and has no effect on stash identity
- `upgrades` tracks how many times each upgrade has been applied

### Stash ID Generation

Each backpack's stash ID is derived **exclusively** from `backpackId`:

```
stash ID = "backpack_" .. backpackId
```

This means:
- Renaming a backpack does NOT create a new stash
- Each physical backpack item maps to exactly one stash
- The stash persists across renames, trades, and server restarts

### Renaming

Players can rename their backpack via the interaction menu. The rename:
- Uses `lib.inputDialog` on the client
- Sends the new name to the server
- Server validates ownership, sanitizes input, enforces max length
- Updates `metadata.customName` only — stash ID is untouched
- The custom name appears in the item description and menu title

### Repair

When durability drops below 100%:
1. Player selects "Repair Backpack" from the menu
2. Server verifies the backpack exists and durability < 100
3. Server checks for and consumes one `bag_repair_kit`
4. Durability increases by `Config.Repair.amount` (capped at 100)
5. Metadata is updated

### Upgrades (Reinforced Fabric)

`reinforced_fabric` is a consumable upgrade item:
1. Player selects "Upgrade Backpack" from the menu
2. Server verifies the backpack and checks upgrade cap (`maxApplications`)
3. Server consumes one `reinforced_fabric` item
4. `metadata.upgrades.reinforced_fabric` increments
5. Stash is re-registered with new calculated stats

**Stats calculation:**
```
final slots = base slots + (addSlots * times applied)
final weight = base weight + (addWeight * times applied)
```

Upgrades are stored in metadata and dynamically applied — they never modify the base config.

### Anti-Duplication Strategy

All critical operations are **server-authoritative**:

1. **Stash ID is server-generated** — clients cannot define or guess stash IDs
2. **Item validation** — server verifies the item exists in the player's inventory before any action
3. **Ownership checks** — metadata is validated server-side before stash access
4. **Per-player action locks** — prevents rapid multi-trigger spam
5. **Cooldowns** — configurable delay between actions
6. **Swap detection** — if a backpack item leaves the player's inventory while equipped, it auto-unequips

### Anti Bag-in-Bag

Backpack items are **blocked from entering any non-player inventory**:

- ox_inventory `swapItems` hook checks if the moved item is a backpack
- If destination is a stash, container, drop, or another player's backpack stash → **blocked**
- This covers drag/drop, swap, give, and stash transfers
- Enforced entirely server-side via ox_inventory hooks

## Troubleshooting

### Backpack doesn't show visually
- Verify the drawable/texture IDs in `Config.Backpacks` are correct for your server's clothing
- Use illenium-appearance's wardrobe to find the right component 5 values
- Ensure illenium-appearance is started before hbs-bags

### Stash doesn't open
- Check server console for errors
- Verify the item has `stack = false` in ox_inventory items
- Ensure the item has valid metadata (give a fresh item to test)

### "Invalid backpack" error
- The item may have been created before hbs-bags was installed (no metadata)
- Give yourself a new backpack item to get proper metadata

### Backpack goes inside another backpack
- Ensure hbs-bags is started and the `swapItems` hook is registered
- Check that all backpack item names are listed in `Config.Backpacks`

### Visual not syncing to other players
- Ensure illenium-appearance is running and exports are available
- The system broadcasts appearance changes via server events to all clients

### Items disappear after upgrade
- Upgrades only modify metadata, not the item itself
- Check server console for ox_inventory errors

### Resource won't start
- Verify all dependencies are started before hbs-bags in server.cfg
- Check for Lua syntax errors in server console
- Ensure `lua54 'yes'` is supported (FXServer b5181+)
