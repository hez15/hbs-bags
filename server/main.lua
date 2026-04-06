local ox_inventory = exports.ox_inventory

---------------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------------

-- Per-player action lock to prevent multi-trigger spam
-- playerLocks[source] = current game timer or nil
local playerLocks = {}

-- Server-authoritative equipped state: equippedBags[source] = { slot = n, backpackId = "...", backpackType = "..." }
local equippedBags = {}

---------------------------------------------------------------------------
-- HELPERS
---------------------------------------------------------------------------

--- Generate a unique backpack ID (server-only)
---@return string
local function generateBackpackId()
    -- 8 random hex chars + current time for uniqueness
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
    local items = ox_inventory:GetInventoryItems(source)
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
---@return table|nil, number|nil  item, slot
local function findBackpackById(source, backpackId)
    local items = ox_inventory:GetInventoryItems(source)
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

    ox_inventory:RegisterStash(stashId, ('Backpack: %s'):format(backpackId), slots, weight)
end

--- Sanitize a user-provided string for naming
---@param input string
---@param maxLen number
---@return string|nil
local function sanitizeString(input, maxLen)
    if type(input) ~= 'string' then return nil end
    -- Strip non-printable and trim
    local clean = input:gsub('[%c]', ''):match('^%s*(.-)%s*$')
    if not clean or #clean == 0 then return nil end
    if #clean > maxLen then
        clean = clean:sub(1, maxLen)
    end
    return clean
end

---------------------------------------------------------------------------
-- METADATA INITIALIZATION (ox_inventory item hook)
---------------------------------------------------------------------------

-- When a backpack item is created, ensure it has proper metadata
for itemName, _ in pairs(Config.BackpackItems) do
    ox_inventory:RegisterHook('createItem', function(payload)
        if payload.item.name ~= itemName then return end

        local metadata = payload.metadata or {}

        -- Only assign ID if it doesn't already have one (prevents overwriting on trade)
        if not metadata.backpackId then
            metadata.backpackId = generateBackpackId()
        end

        -- Ensure all metadata fields exist
        if not metadata.backpackType then
            metadata.backpackType = itemName
        end
        if not metadata.customName then
            metadata.customName = Config.Backpacks[itemName] and Config.Backpacks[itemName].label or 'Backpack'
        end
        if metadata.durability == nil then
            metadata.durability = 100
        end
        if not metadata.upgrades then
            metadata.upgrades = {}
        end

        -- Set the item description to show custom name
        metadata.description = ('Type: %s | Durability: %d%%'):format(
            metadata.backpackType,
            metadata.durability
        )

        return metadata
    end, {})
end

---------------------------------------------------------------------------
-- ANTI BAG-IN-BAG: Block backpack items from entering any stash/container
---------------------------------------------------------------------------

-- Hook into swapItems to prevent backpacks going into non-player inventories
ox_inventory:RegisterHook('swapItems', function(payload)
    -- Check if the moved item is a backpack
    local itemName = payload.fromSlot and payload.fromSlot.name
    if not itemName then return true end

    if Config.BackpackItems[itemName] then
        -- Allow if destination is a player inventory
        local toType = payload.toType
        if toType ~= 'player' then
            return false -- Block: backpack cannot go into stash/container/drop
        end

        -- Also block if destination inventory is a backpack stash
        local toInv = payload.toInventory
        if type(toInv) == 'string' and toInv:find('^' .. Config.StashPrefix) then
            return false
        end
    end

    -- Check the reverse direction for swaps
    local toItemName = payload.toSlot and payload.toSlot.name
    if toItemName and Config.BackpackItems[toItemName] then
        local fromType = payload.fromType
        if fromType ~= 'player' then
            return false
        end
        local fromInv = payload.fromInventory
        if type(fromInv) == 'string' and fromInv:find('^' .. Config.StashPrefix) then
            return false
        end
    end

    return true
end, {})

---------------------------------------------------------------------------
-- ITEM USE HANDLER
---------------------------------------------------------------------------

for itemName, backpackCfg in pairs(Config.Backpacks) do
    ox_inventory:RegisterHook('usingItem', function(payload)
        if payload.item.name ~= itemName then return true end
        -- Let the client know which slot was used; actual logic runs via callback
        return true
    end, {})

    exports.ox_inventory:RegisterUsableItem(itemName, function(source, slot, metadata)
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

        local meta = item.metadata
        if not meta or not meta.backpackId then
            return lib.notify(src, { title = 'Backpack', description = 'Invalid backpack.', type = 'error' })
        end

        -- Send to client to open context menu
        TriggerClientEvent('hbs-bags:client:openMenu', src, slot, meta)
    end)
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

    local meta = item.metadata
    if not meta or not meta.backpackId then
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
        -- Block equipping another while one is worn
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

    -- Verify the item still exists in inventory
    local item = findBackpackById(src, current.backpackId)
    if not item then
        -- Item was removed (dropped, traded); clean up
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

    local meta = item.metadata
    if not meta or not meta.backpackId then
        return false, 'Invalid backpack.'
    end

    -- Durability check
    if meta.durability and meta.durability <= 0 then
        return false, 'This backpack is broken. Repair it first.'
    end

    -- Register stash with current stats
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

    -- Update ONLY customName in metadata
    meta.customName = clean
    meta.description = ('Type: %s | Durability: %d%% | Name: %s'):format(
        meta.backpackType or item.name,
        meta.durability or 100,
        clean
    )

    ox_inventory:SetMetadata(src, slot, meta)
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

    -- Check for repair item
    local repairCount = ox_inventory:GetItemCount(src, Config.Repair.item)
    if not repairCount or repairCount < 1 then
        return false, 'You need a ' .. Config.Repair.item .. '.'
    end

    -- Consume repair item
    local removed = ox_inventory:RemoveItem(src, Config.Repair.item, 1)
    if not removed then
        return false, 'Failed to consume repair kit.'
    end

    -- Apply repair
    meta.durability = math.min(100, (meta.durability or 0) + Config.Repair.amount)
    meta.description = ('Type: %s | Durability: %d%%'):format(
        meta.backpackType or item.name,
        meta.durability
    )
    if meta.customName then
        meta.description = meta.description .. (' | Name: %s'):format(meta.customName)
    end

    ox_inventory:SetMetadata(src, slot, meta)
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

    -- Check upgrade cap
    local upgrades = meta.upgrades or {}
    local currentCount = upgrades[upgradeKey] or 0
    if currentCount >= upgradeCfg.maxApplications then
        return false, ('Max upgrades reached (%d/%d).'):format(currentCount, upgradeCfg.maxApplications)
    end

    -- Check for upgrade item
    local upgradeItemCount = ox_inventory:GetItemCount(src, upgradeCfg.item)
    if not upgradeItemCount or upgradeItemCount < 1 then
        return false, ('You need a %s.'):format(upgradeCfg.label)
    end

    -- Consume upgrade item
    local removed = ox_inventory:RemoveItem(src, upgradeCfg.item, 1)
    if not removed then
        return false, 'Failed to consume upgrade item.'
    end

    -- Apply upgrade
    upgrades[upgradeKey] = currentCount + 1
    meta.upgrades = upgrades

    -- Update description
    meta.description = ('Type: %s | Durability: %d%%'):format(
        meta.backpackType or item.name,
        meta.durability or 100
    )
    if meta.customName then
        meta.description = meta.description .. (' | Name: %s'):format(meta.customName)
    end

    -- Append upgrade info
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

    ox_inventory:SetMetadata(src, slot, meta)

    -- Re-register stash with new stats if it's currently equipped
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

    -- Verify the item still exists
    local item = findBackpackById(src, data.backpackId)
    if not item then
        equippedBags[src] = nil
        return nil
    end

    return data
end)

---------------------------------------------------------------------------
-- ITEM REMOVAL DETECTION
---------------------------------------------------------------------------

-- When a backpack item is removed from a player's inventory, auto-unequip
ox_inventory:RegisterHook('swapItems', function(payload)
    -- Already handled bag-in-bag above; here we detect if equipped bag leaves inventory
    local src = payload.source
    if not src or not equippedBags[src] then return true end

    local equipped = equippedBags[src]
    local itemName = payload.fromSlot and payload.fromSlot.name
    local itemMeta = payload.fromSlot and payload.fromSlot.metadata

    if itemName and Config.BackpackItems[itemName] and itemMeta then
        if itemMeta.backpackId == equipped.backpackId then
            -- Check if item is leaving the player's inventory
            local toType = payload.toType
            if toType ~= 'player' or payload.toInventory ~= payload.fromInventory then
                -- Backpack is being moved out of player inventory
                equippedBags[src] = nil
                TriggerClientEvent('hbs-bags:client:forceUnequip', src)
            end
        end
    end

    return true
end, {})

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

-- When a player equips/unequips, broadcast to all clients for visual sync
RegisterNetEvent('hbs-bags:server:syncVisual', function(backpackType, equipped)
    local src = source

    -- Validate: only allow sync if server state agrees
    if equipped then
        if not equippedBags[src] then return end
        if equippedBags[src].backpackType ~= backpackType then return end
    end

    -- Broadcast to all clients (including sender for consistency)
    TriggerClientEvent('hbs-bags:client:applyVisual', -1, src, backpackType, equipped)
end)

-- When a new player loads in, send them all currently equipped backpacks
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
