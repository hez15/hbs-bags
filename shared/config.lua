Config = {}

-- All backpack types and their properties
-- Each key corresponds to an ox_inventory item name
Config.Backpacks = {
    small_backpack = {
        item = 'small_backpack',
        label = 'Small Backpack',
        slots = 15,
        weight = 15000,
        male = { drawable = 45, texture = 0 },     -- bag component (component 5)
        female = { drawable = 45, texture = 0 },
        allowUnequip = true,
        toggleUse = true,   -- if true, using while equipped toggles equip/unequip; if false, opens stash
    },
    medium_backpack = {
        item = 'medium_backpack',
        label = 'Medium Backpack',
        slots = 25,
        weight = 30000,
        male = { drawable = 45, texture = 1 },
        female = { drawable = 45, texture = 1 },
        allowUnequip = true,
        toggleUse = true,
    },
    large_backpack = {
        item = 'large_backpack',
        label = 'Large Backpack',
        slots = 40,
        weight = 50000,
        male = { drawable = 45, texture = 2 },
        female = { drawable = 45, texture = 2 },
        allowUnequip = true,
        toggleUse = true,
    },

    -- Job-locked bags
    ems_backpack = {
        item = 'ems_backpack',
        label = 'EMS Medical Bag',
        slots = 30,
        weight = 40000,
        male = { drawable = 45, texture = 3 },
        female = { drawable = 45, texture = 3 },
        allowUnequip = true,
        toggleUse = true,
        jobs = { 'ambulance', 'ems' },   -- only these jobs can equip
    },
    fire_backpack = {
        item = 'fire_backpack',
        label = 'Fire Rescue Bag',
        slots = 30,
        weight = 40000,
        male = { drawable = 45, texture = 4 },
        female = { drawable = 45, texture = 4 },
        allowUnequip = true,
        toggleUse = true,
        jobs = { 'fire', 'firefighter' },
    },
    pd_backpack = {
        item = 'pd_backpack',
        label = 'Police Tactical Bag',
        slots = 30,
        weight = 40000,
        male = { drawable = 45, texture = 5 },
        female = { drawable = 45, texture = 5 },
        allowUnequip = true,
        toggleUse = true,
        jobs = { 'police', 'sheriff', 'sasp' },
    },
}

-- Build a flat set of all backpack item names for fast lookups
Config.BackpackItems = {}
for key, data in pairs(Config.Backpacks) do
    Config.BackpackItems[data.item] = true
end

-- Rename settings
Config.Rename = {
    enabled = true,
    maxLength = 24,
}

-- Repair settings
Config.Repair = {
    enabled = true,
    item = 'bag_repair_kit',    -- consumed on repair
    amount = 25,                -- durability restored per repair
}

-- Durability loss per stash open
Config.DurabilityLoss = 1

-- Upgrade items and their effects
Config.Upgrades = {
    reinforced_fabric = {
        item = 'reinforced_fabric',
        label = 'Reinforced Fabric',
        addSlots = 5,
        addWeight = 5000,
        maxApplications = 3,
    },
}

-- Clothing component ID for bags (GTA component index 5 = Bags)
Config.BagComponent = 5

-- Default (no bag) values per gender to restore when unequipping
-- These are the vanilla "no bag" drawables; adjust if your server uses different defaults
Config.DefaultClothing = {
    male   = { drawable = 0, texture = 0 },
    female = { drawable = 0, texture = 0 },
}

-- Cooldown between backpack actions in milliseconds (anti-spam)
Config.ActionCooldown = 1500

-- Stash ID prefix
Config.StashPrefix = 'backpack_'
