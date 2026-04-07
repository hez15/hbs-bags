---------------------------------------------------------------------------
-- SERVER
-- Uses QBX/QBCore item registration instead of ox_inventory exports
-- that may not exist in all ox_inventory versions.
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------------

local playerLocks = {}   -- playerLocks[source] = GetGameTimer() value
local equippedBags = {}  -- equippedBags[source] = { slot, backpackId, backpackType }

---------------------------------------------------------------------------
-- HELPERS
---------------------------------------------------------------------------

--- Generate a unique backpack ID (server-only)
---@return string
local function generateBackpackId()
    local id = ('bag_%s%x'):format(
        string.char(math.random(65, 90)) .. string.char(math.random(65, 90)),
        os.time() + math.random(100000, 999999)
    )
    return id
end

--- Check if a player is action-locked (cooldown)
---@param source number
---@return boolean
local function isLocked(source)
    local lock = playerLocks[source]
    if lock and (GetGameTimer() - lock) < Config.ActionCooldown then
        return true
    end
    return false
end

--- Set action lock for a player
---@param source number
local function setLock(source)
    playerLocks[source] = GetGameTimer()
end

--- Get all items from a player's inventory (compatible across ox_inventory versions)
---@param source number
---@return table|nil
local function getPlayerItems(source)
    -- Try multiple export names for cross-version compat
    local ok, items = pcall(function()
        return exports.ox_inventory:GetInventoryItems(source)
    end)
    if ok and items then return items end

    ok, items = pcall(function()
        return exports.ox_inventory:GetInventory(source)
    end)
    if ok and items then
        -- Some versions return { items = {...} }
        if items.items then return items.items end
        return items
    end

    return nil
end

--- Find a backpack item in the player's inventory by slot
---@param source number
---@param slot number
---@return table|nil
local function getItemAtSlot(source, slot)
    -- Try GetSlot first (most reliable single-slot lookup)
    local ok, item = pcall(function()
        return exports.ox_inventory:GetSlot(source, slot)
    end)
    if ok and item and item.name then return item end

    -- Fallback: iterate all items
    local items = getPlayerItems(source)
    if not items then return nil end
    for _, v in pairs(items) do
        if v.slot == slot then
            return v
        end
    end
    return nil
end

--- Find a backpack item by its backpackId in the player's inventory
---@param source number
---@param backpackId string
---@return table|nil, number|nil
local function findBackpackById(source, backpackId)
    local items = getPlayerItems(source)
    if not items then return nil, nil end
    for _, item in pairs(items) do
        if item.metadata and item.metadata.backpackId == backpackId then
            return item, item.slot
        end
    end
    return nil, nil
end

--- Calculate final stash stats with upgrades applied
---@param backpackType string
---@param upgrades table
---@return number slots, number weight
local function calculateStats(backpackType, upgrades)
    local cfg = Config.Backpacks[backpackType]
    if not cfg then return 15, 15000 end

    local slots = cfg.slots
    local weight = cfg.weight

    if upgrades then
        for upgradeKey, appliedCount in pairs(upgrades) do
            local upgradeCfg = Config.Upgrades[upgradeKey]
            if upgradeCfg then
                slots = slots + (upgradeCfg.addSlots * appliedCount)
                weight = weight + (upgradeCfg.addWeight * appliedCount)
            end
        end
    end

    return slots, weight
end

--- Register (or re-register) a stash for a backpack
---@param backpackId string
---@param backpackType string
---@param upgrades table
local function registerStash(backpackId, backpackType, upgrades)
    local slots, weight = calculateStats(backpackType, upgrades or {})
    local stashId = Config.StashPrefix .. backpackId

    exports.ox_inventory:RegisterStash(stashId, ('Backpack: %s'):format(backpackId), slots, weight)
end

--- Sanitize a user-provided string for naming
---@param input string
---@param maxLen number
---@return string|nil
local function sanitizeString(input, maxLen)
    if type(input) ~= 'string' then return nil end
    local clean = input:gsub('[%c]', ''):match('^%s*(.-)%s*$')
    if not clean or #clean == 0 then return nil end
    if #clean > maxLen then
        clean = clean:sub(1, maxLen)
    end
    return clean
end

--- Send a notification to a player (compatible with ox_lib v3+)
---@param source number
---@param data table
local function notify(source, data)
    TriggerClientEvent('ox_lib:notify', source, data)
end

--- Ensure backpack metadata is complete
---@param source number
---@param slot number
---@param item table
---@return table metadata
local function ensureMetadata(source, slot, item)
    local meta = item.metadata or {}
    local changed = false

    if not meta.backpackId then
        meta.backpackId = generateBackpackId()
        changed = true
    end
    if not meta.backpackType then
        meta.backpackType = item.name
        changed = true
    end
    if not meta.customName then
        meta.customName = Config.Backpacks[item.name] and Config.Backpacks[item.name].label or 'Backpack'
        changed = true
    end
    if meta.durability == nil then
        meta.durability = 100
        changed = true
    end
    if not meta.upgrades then
        meta.upgrades = {}
        changed = true
    end

    if changed then
        meta.description = ('Type: %s | Durability: %d%%'):format(meta.backpackType, meta.durability)
        if meta.customName then
            meta.description = meta.description .. (' | Name: %s'):format(meta.customName)
        end
        exports.ox_inventory:SetMetadata(source, slot, meta)
    end

    return meta
end

---------------------------------------------------------------------------
-- ITEM USE HANDLER
-- ox_inventory triggers this export when a player uses a backpack item.
-- Each item definition in ox_inventory must point here via:
--   server = { export = 'hbs-bags.useBackpack' }
---------------------------------------------------------------------------

exports('useBackpack', function(event, item, inventory, slot, data)
    -- Handle different ox_inventory callback signatures
    local src

    if type(inventory) == 'table' then
        src = inventory.id or inventory
    elseif type(inventory) == 'number' then
        src = inventory
    else
        src = source
    end

    if type(src) ~= 'number' or src <= 0 then return end

    local itemName = type(item) == 'table' and item.name or nil
    if not itemName or not Config.BackpackItems[itemName] then return end

    local itemSlot = slot or (type(item) == 'table' and item.slot) or nil
    if not itemSlot then return end

    -- Validate item still exists at slot
    local invItem = getItemAtSlot(src, itemSlot)
    if not invItem or not Config.BackpackItems[invItem.name] then
        return notify(src, { title = 'Backpack', description = 'Item not found.', type = 'error' })
    end

    -- Ensure metadata is complete
    local meta = ensureMetadata(src, itemSlot, invItem)
    if not meta.backpackId then
        return notify(src, { title = 'Backpack', description = 'Invalid backpack.', type = 'error' })
    end

    -- Auto-equip if not already equipped, then show menu
    local current = equippedBags[src]
    local backpackType = meta.backpackType or invItem.name

    if not current then
        -- Durability check
        if meta.durability and meta.durability <= 0 then
            return notify(src, { title = 'Backpack', description = 'This backpack is broken. Repair it first.', type = 'error' })
        end

        -- Equip
        equippedBags[src] = {
            slot = itemSlot,
            backpackId = meta.backpackId,
            backpackType = backpackType,
        }
        registerStash(meta.backpackId, backpackType, meta.upgrades or {})

        -- Tell client to apply visuals then show menu
        TriggerClientEvent('hbs-bags:client:equipAndMenu', src, itemSlot, backpackType, meta)

    else
        -- Already equipped (same or different bag) — just show menu
        TriggerClientEvent('hbs-bags:client:openMenu', src, itemSlot, meta)
    end
end)

---------------------------------------------------------------------------
-- ANTI BAG-IN-BAG HOOKS (with fallback)
-- Try multiple hook registration methods for ox_inventory compatibility.
---------------------------------------------------------------------------

--- Safely extract item name from a hook slot field
--- In some ox_inventory versions fromSlot/toSlot are tables, in others they're numbers
---@param slotData any
---@return string|nil name, table|nil metadata
local function getSlotInfo(slotData)
    if type(slotData) == 'table' then
        return slotData.name, slotData.metadata
    end
    return nil, nil
end

local function createSwapHandler(payload)
    local fromName, fromMeta = getSlotInfo(payload.fromSlot)
    local toName, _ = getSlotInfo(payload.toSlot)

    -- Check if a backpack item is being moved INTO a backpack stash
    if fromName and Config.BackpackItems[fromName] then
        local toInv = payload.toInventory
        if type(toInv) == 'string' and toInv:find('^' .. Config.StashPrefix) then
            return false
        end
    end

    -- Check reverse direction for swaps
    if toName and Config.BackpackItems[toName] then
        local fromInv = payload.fromInventory
        if type(fromInv) == 'string' and fromInv:find('^' .. Config.StashPrefix) then
            return false
        end
    end

    -- Detect equipped backpack leaving player inventory → auto unequip
    local src = payload.source
    if src and equippedBags[src] then
        local equipped = equippedBags[src]
        if fromName and Config.BackpackItems[fromName] and fromMeta then
            if fromMeta.backpackId == equipped.backpackId then
                local toType = payload.toType
                if toType ~= 'player' or payload.toInventory ~= payload.fromInventory then
                    equippedBags[src] = nil
                    TriggerClientEvent('hbs-bags:client:forceUnequip', src)
                end
            end
        end
    end

    return true
end

local hookRegistered = false

-- Method 1: lowercase registerHook (ox_inventory v2.38+)
if not hookRegistered then
    local ok = pcall(function()
        exports.ox_inventory:registerHook('swapItems', createSwapHandler, {})
    end)
    if ok then
        hookRegistered = true
        print('^2[hbs-bags]^0 Swap hook registered (registerHook).')
    end
end

-- Method 2: PascalCase RegisterHook
if not hookRegistered then
    local ok = pcall(function()
        exports.ox_inventory:RegisterHook('swapItems', createSwapHandler, {})
    end)
    if ok then
        hookRegistered = true
        print('^2[hbs-bags]^0 Swap hook registered (RegisterHook).')
    end
end

if not hookRegistered then
    print('^1[hbs-bags]^0 WARNING: Could not register swapItems hook.')
    print('^1[hbs-bags]^0 Bag-in-bag prevention requires ox_inventory with hook support.')
end

---------------------------------------------------------------------------
-- SERVER CALLBACKS
---------------------------------------------------------------------------

--- Unequip backpack
lib.callback.register('hbs-bags:server:unequip', function(source)
    local src = source

    local current = equippedBags[src]
    if not current then
        return false, 'No backpack equipped.'
    end

    local item = findBackpackById(src, current.backpackId)
    if not item then
        equippedBags[src] = nil
        return true, nil
    end

    local cfg = Config.Backpacks[current.backpackType]
    if cfg and not cfg.allowUnequip then
        return false, 'This backpack cannot be unequipped.'
    end

    equippedBags[src] = nil
    return true, nil
end)

--- Open stash (from menu)
lib.callback.register('hbs-bags:server:openStash', function(source, slot)
    local src = source

    local item = getItemAtSlot(src, slot)
    if not item or not Config.BackpackItems[item.name] then
        return false, 'Invalid item.'
    end

    local meta = ensureMetadata(src, slot, item)

    if not meta.backpackId then
        return false, 'Invalid backpack.'
    end

    if meta.durability and meta.durability <= 0 then
        return false, 'This backpack is broken. Repair it first.'
    end

    -- Reduce durability on each stash open
    if Config.DurabilityLoss and Config.DurabilityLoss > 0 then
        meta.durability = math.max(0, (meta.durability or 100) - Config.DurabilityLoss)
        meta.description = ('Type: %s | Durability: %d%%'):format(
            meta.backpackType or item.name,
            meta.durability
        )
        if meta.customName then
            meta.description = meta.description .. (' | Name: %s'):format(meta.customName)
        end
        exports.ox_inventory:SetMetadata(src, slot, meta)
    end

    registerStash(meta.backpackId, meta.backpackType or item.name, meta.upgrades or {})

    local stashId = Config.StashPrefix .. meta.backpackId
    return true, stashId
end)

--- Rename backpack
lib.callback.register('hbs-bags:server:rename', function(source, slot, newName)
    local src = source
    if not Config.Rename.enabled then return false, 'Renaming is disabled.' end

    local item = getItemAtSlot(src, slot)
    if not item or not Config.BackpackItems[item.name] then
        return false, 'Invalid item.'
    end

    local meta = item.metadata
    if not meta or not meta.backpackId then
        return false, 'Invalid backpack.'
    end

    local clean = sanitizeString(newName, Config.Rename.maxLength)
    if not clean then
        return false, 'Invalid name.'
    end

    meta.customName = clean
    meta.description = ('Type: %s | Durability: %d%% | Name: %s'):format(
        meta.backpackType or item.name,
        meta.durability or 100,
        clean
    )

    exports.ox_inventory:SetMetadata(src, slot, meta)
    return true, clean
end)

--- Repair backpack
lib.callback.register('hbs-bags:server:repair', function(source, slot)
    local src = source
    if not Config.Repair.enabled then return false, 'Repair is disabled.' end

    local item = getItemAtSlot(src, slot)
    if not item or not Config.BackpackItems[item.name] then
        return false, 'Invalid item.'
    end

    local meta = item.metadata
    if not meta or not meta.backpackId then
        return false, 'Invalid backpack.'
    end

    if (meta.durability or 100) >= 100 then
        return false, 'Backpack is already at full durability.'
    end

    local repairCount = exports.ox_inventory:GetItemCount(src, Config.Repair.item)
    if not repairCount or repairCount < 1 then
        return false, 'You need a ' .. Config.Repair.item .. '.'
    end

    local removed = exports.ox_inventory:RemoveItem(src, Config.Repair.item, 1)
    if not removed then
        return false, 'Failed to consume repair kit.'
    end

    meta.durability = math.min(100, (meta.durability or 0) + Config.Repair.amount)
    meta.description = ('Type: %s | Durability: %d%%'):format(
        meta.backpackType or item.name,
        meta.durability
    )
    if meta.customName then
        meta.description = meta.description .. (' | Name: %s'):format(meta.customName)
    end

    exports.ox_inventory:SetMetadata(src, slot, meta)
    return true, meta.durability
end)

--- Upgrade backpack
lib.callback.register('hbs-bags:server:upgrade', function(source, slot, upgradeKey)
    local src = source

    local upgradeCfg = Config.Upgrades[upgradeKey]
    if not upgradeCfg then
        return false, 'Unknown upgrade.'
    end

    local item = getItemAtSlot(src, slot)
    if not item or not Config.BackpackItems[item.name] then
        return false, 'Invalid item.'
    end

    local meta = item.metadata
    if not meta or not meta.backpackId then
        return false, 'Invalid backpack.'
    end

    local upgrades = meta.upgrades or {}
    local currentCount = upgrades[upgradeKey] or 0
    if currentCount >= upgradeCfg.maxApplications then
        return false, ('Max upgrades reached (%d/%d).'):format(currentCount, upgradeCfg.maxApplications)
    end

    local upgradeItemCount = exports.ox_inventory:GetItemCount(src, upgradeCfg.item)
    if not upgradeItemCount or upgradeItemCount < 1 then
        return false, ('You need a %s.'):format(upgradeCfg.label)
    end

    local removed = exports.ox_inventory:RemoveItem(src, upgradeCfg.item, 1)
    if not removed then
        return false, 'Failed to consume upgrade item.'
    end

    upgrades[upgradeKey] = currentCount + 1
    meta.upgrades = upgrades

    meta.description = ('Type: %s | Durability: %d%%'):format(
        meta.backpackType or item.name,
        meta.durability or 100
    )
    if meta.customName then
        meta.description = meta.description .. (' | Name: %s'):format(meta.customName)
    end

    local totalAddSlots = 0
    local totalAddWeight = 0
    for uKey, uCount in pairs(upgrades) do
        local uCfg = Config.Upgrades[uKey]
        if uCfg then
            totalAddSlots = totalAddSlots + (uCfg.addSlots * uCount)
            totalAddWeight = totalAddWeight + (uCfg.addWeight * uCount)
        end
    end
    if totalAddSlots > 0 or totalAddWeight > 0 then
        meta.description = meta.description .. (' | +%d slots, +%dg capacity'):format(totalAddSlots, totalAddWeight)
    end

    exports.ox_inventory:SetMetadata(src, slot, meta)

    registerStash(meta.backpackId, meta.backpackType or item.name, upgrades)

    return true, upgrades[upgradeKey]
end)

--- Inspect backpack (read-only info)
lib.callback.register('hbs-bags:server:inspect', function(source, slot)
    local src = source
    local item = getItemAtSlot(src, slot)
    if not item or not Config.BackpackItems[item.name] then
        return nil, 'Invalid item.'
    end

    local meta = item.metadata
    if not meta then return nil, 'No metadata.' end

    local backpackType = meta.backpackType or item.name
    local upgrades = meta.upgrades or {}
    local slots, weight = calculateStats(backpackType, upgrades)

    return {
        backpackId = meta.backpackId,
        backpackType = backpackType,
        customName = meta.customName or 'Unnamed',
        durability = meta.durability or 100,
        slots = slots,
        weight = weight,
        upgrades = upgrades,
    }, nil
end)

--- Get equipped state for a player (used on client load)
lib.callback.register('hbs-bags:server:getEquipped', function(source)
    local src = source
    local data = equippedBags[src]
    if not data then return nil end

    local item = findBackpackById(src, data.backpackId)
    if not item then
        equippedBags[src] = nil
        return nil
    end

    return data
end)

---------------------------------------------------------------------------
-- PLAYER DISCONNECT CLEANUP
---------------------------------------------------------------------------

AddEventHandler('playerDropped', function()
    local src = source
    playerLocks[src] = nil
    equippedBags[src] = nil
end)

---------------------------------------------------------------------------
-- NETWORKED VISUAL SYNC
---------------------------------------------------------------------------

RegisterNetEvent('hbs-bags:server:syncVisual', function(backpackType, equipped)
    local src = source

    if equipped then
        if not equippedBags[src] then return end
        if equippedBags[src].backpackType ~= backpackType then return end
    end

    TriggerClientEvent('hbs-bags:client:applyVisual', -1, src, backpackType, equipped)
end)

RegisterNetEvent('hbs-bags:server:requestAllVisuals', function()
    local src = source
    for playerId, data in pairs(equippedBags) do
        if playerId ~= src and GetPlayerPed(playerId) ~= 0 then
            TriggerClientEvent('hbs-bags:client:applyVisual', src, playerId, data.backpackType, true)
        end
    end
end)

---------------------------------------------------------------------------
-- STARTUP LOG
---------------------------------------------------------------------------

print('^2[hbs-bags]^0 Backpack system loaded successfully.')
