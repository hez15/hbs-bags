---------------------------------------------------------------------------
-- ox_inventory server module (hooks, stash registration, etc.)
-- Using the Lua require method which is the standard for current ox_inventory
---------------------------------------------------------------------------

local ox_inv = exports.ox_inventory

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

--- Find a backpack item in the player's inventory by slot
---@param source number
---@param slot number
---@return table|nil
local function getItemAtSlot(source, slot)
    local items = ox_inv:GetInventoryItems(source)
    if not items then return nil end
    for _, item in pairs(items) do
        if item.slot == slot then
            return item
        end
    end
    return nil
end

--- Find a backpack item by its backpackId in the player's inventory
---@param source number
---@param backpackId string
---@return table|nil, number|nil
local function findBackpackById(source, backpackId)
    local items = ox_inv:GetInventoryItems(source)
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

    ox_inv:RegisterStash(stashId, ('Backpack: %s'):format(backpackId), slots, weight)
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

--- Ensure backpack metadata is complete (called when item is used, in case it was created before this resource)
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
        ox_inv:SetMetadata(source, slot, meta)
    end

    return meta
end

---------------------------------------------------------------------------
-- ITEM USE HANDLER
---------------------------------------------------------------------------

for itemName, backpackCfg in pairs(Config.Backpacks) do
    ox_inv:RegisterUsableItem(itemName, function(source, slot, metadata)
        local src = source
        if isLocked(src) then
            return lib.notify(src, { title = 'Backpack', description = 'Please wait...', type = 'error' })
        end
        setLock(src)

        -- Validate item still exists at slot
        local item = getItemAtSlot(src, slot)
        if not item or item.name ~= itemName then
            return lib.notify(src, { title = 'Backpack', description = 'Item not found.', type = 'error' })
        end

        -- Ensure metadata is complete (handles items created before resource was installed)
        local meta = ensureMetadata(src, slot, item)

        if not meta.backpackId then
            return lib.notify(src, { title = 'Backpack', description = 'Invalid backpack.', type = 'error' })
        end

        -- Send to client to open context menu
        TriggerClientEvent('hbs-bags:client:openMenu', src, slot, meta)
    end)
end

---------------------------------------------------------------------------
-- ANTI BAG-IN-BAG: Event-based detection
-- Block backpacks from being moved into backpack stashes only.
-- Normal stashes (house, trunk, etc.) are allowed.
---------------------------------------------------------------------------

-- Listen for inventory item moves and block backpacks going into backpack stashes
AddEventHandler('ox_inventory:itemMoved', function(source, fromInv, toInv, fromSlot, toSlot)
    -- This is a post-move event; for pre-move blocking we use the approach below
end)

-- Use the event-based hook system: ox_inventory emits 'ox_inventory:swapItems'
-- For versions that support exports-based hooks, we try that; otherwise we use event-based
local hookRegistered = false

-- Try the newer module-based hook registration
local success = pcall(function()
    exports.ox_inventory:registerHook('swapItems', function(payload)
        -- Check if a backpack item is being moved INTO a backpack stash
        local itemName = payload.fromSlot and payload.fromSlot.name
        if itemName and Config.BackpackItems[itemName] then
            local toInv = payload.toInventory
            if type(toInv) == 'string' and toInv:find('^' .. Config.StashPrefix) then
                return false
            end
        end

        -- Check reverse direction for swaps
        local toItemName = payload.toSlot and payload.toSlot.name
        if toItemName and Config.BackpackItems[toItemName] then
            local fromInv = payload.fromInventory
            if type(fromInv) == 'string' and fromInv:find('^' .. Config.StashPrefix) then
                return false
            end
        end

        -- Detect equipped backpack leaving player inventory → auto unequip
        local src = payload.source
        if src and equippedBags[src] then
            local equipped = equippedBags[src]
            if itemName and Config.BackpackItems[itemName] then
                local itemMeta = payload.fromSlot and payload.fromSlot.metadata
                if itemMeta and itemMeta.backpackId == equipped.backpackId then
                    local toType = payload.toType
                    if toType ~= 'player' or payload.toInventory ~= payload.fromInventory then
                        equippedBags[src] = nil
                        TriggerClientEvent('hbs-bags:client:forceUnequip', src)
                    end
                end
            end
        end

        return true
    end, {})
    hookRegistered = true
end)

-- If lowercase registerHook failed, try PascalCase RegisterHook
if not hookRegistered then
    pcall(function()
        exports.ox_inventory:RegisterHook('swapItems', function(payload)
            local itemName = payload.fromSlot and payload.fromSlot.name
            if itemName and Config.BackpackItems[itemName] then
                local toInv = payload.toInventory
                if type(toInv) == 'string' and toInv:find('^' .. Config.StashPrefix) then
                    return false
                end
            end

            local toItemName = payload.toSlot and payload.toSlot.name
            if toItemName and Config.BackpackItems[toItemName] then
                local fromInv = payload.fromInventory
                if type(fromInv) == 'string' and fromInv:find('^' .. Config.StashPrefix) then
                    return false
                end
            end

            local src = payload.source
            if src and equippedBags[src] then
                local equipped = equippedBags[src]
                if itemName and Config.BackpackItems[itemName] then
                    local itemMeta = payload.fromSlot and payload.fromSlot.metadata
                    if itemMeta and itemMeta.backpackId == equipped.backpackId then
                        local toType = payload.toType
                        if toType ~= 'player' or payload.toInventory ~= payload.fromInventory then
                            equippedBags[src] = nil
                            TriggerClientEvent('hbs-bags:client:forceUnequip', src)
                        end
                    end
                end
            end

            return true
        end, {})
        hookRegistered = true
    end)
end

if hookRegistered then
    print('^2[hbs-bags]^0 Swap hook registered via export.')
else
    -- Fallback: no hook available, log warning
    print('^1[hbs-bags]^0 WARNING: Could not register swapItems hook. Bag-in-bag prevention and auto-unequip on item removal may not work.')
    print('^1[hbs-bags]^0 Ensure ox_inventory is up to date and supports registerHook exports.')
end

---------------------------------------------------------------------------
-- SERVER CALLBACKS
---------------------------------------------------------------------------

--- Equip backpack
lib.callback.register('hbs-bags:server:equip', function(source, slot)
    local src = source
    if isLocked(src) then return false, 'Please wait...' end
    setLock(src)

    local item = getItemAtSlot(src, slot)
    if not item or not Config.BackpackItems[item.name] then
        return false, 'Invalid item.'
    end

    local meta = ensureMetadata(src, slot, item)

    if not meta.backpackId then
        return false, 'Invalid backpack metadata.'
    end

    -- Check durability
    if meta.durability and meta.durability <= 0 then
        return false, 'This backpack is broken. Repair it first.'
    end

    -- Check if already wearing a different backpack
    local current = equippedBags[src]
    if current then
        if current.backpackId == meta.backpackId then
            return false, 'This backpack is already equipped.'
        end
        return false, 'Unequip your current backpack first.'
    end

    -- Store equipped state server-side
    equippedBags[src] = {
        slot = slot,
        backpackId = meta.backpackId,
        backpackType = meta.backpackType or item.name,
    }

    -- Register stash so it's ready
    registerStash(meta.backpackId, meta.backpackType or item.name, meta.upgrades or {})

    return true, meta.backpackType or item.name
end)

--- Unequip backpack
lib.callback.register('hbs-bags:server:unequip', function(source)
    local src = source
    if isLocked(src) then return false, 'Please wait...' end
    setLock(src)

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

--- Open stash
lib.callback.register('hbs-bags:server:openStash', function(source, slot)
    local src = source
    if isLocked(src) then return false, 'Please wait...' end
    setLock(src)

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

    registerStash(meta.backpackId, meta.backpackType or item.name, meta.upgrades or {})

    local stashId = Config.StashPrefix .. meta.backpackId
    return true, stashId
end)

--- Rename backpack
lib.callback.register('hbs-bags:server:rename', function(source, slot, newName)
    local src = source
    if not Config.Rename.enabled then return false, 'Renaming is disabled.' end
    if isLocked(src) then return false, 'Please wait...' end
    setLock(src)

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

    ox_inv:SetMetadata(src, slot, meta)
    return true, clean
end)

--- Repair backpack
lib.callback.register('hbs-bags:server:repair', function(source, slot)
    local src = source
    if not Config.Repair.enabled then return false, 'Repair is disabled.' end
    if isLocked(src) then return false, 'Please wait...' end
    setLock(src)

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

    local repairCount = ox_inv:GetItemCount(src, Config.Repair.item)
    if not repairCount or repairCount < 1 then
        return false, 'You need a ' .. Config.Repair.item .. '.'
    end

    local removed = ox_inv:RemoveItem(src, Config.Repair.item, 1)
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

    ox_inv:SetMetadata(src, slot, meta)
    return true, meta.durability
end)

--- Upgrade backpack
lib.callback.register('hbs-bags:server:upgrade', function(source, slot, upgradeKey)
    local src = source
    if isLocked(src) then return false, 'Please wait...' end
    setLock(src)

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

    local upgradeItemCount = ox_inv:GetItemCount(src, upgradeCfg.item)
    if not upgradeItemCount or upgradeItemCount < 1 then
        return false, ('You need a %s.'):format(upgradeCfg.label)
    end

    local removed = ox_inv:RemoveItem(src, upgradeCfg.item, 1)
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

    ox_inv:SetMetadata(src, slot, meta)

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
