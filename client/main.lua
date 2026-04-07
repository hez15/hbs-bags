---------------------------------------------------------------------------
-- CLIENT STATE
---------------------------------------------------------------------------

local equippedBackpack = nil     -- { slot = n, backpackId = "...", backpackType = "..." }
local previousClothing = nil     -- { drawable = n, texture = n } saved before equip
local lastAction = 0             -- anti-spam timestamp

---------------------------------------------------------------------------
-- HELPERS
---------------------------------------------------------------------------

--- Check client-side cooldown
---@return boolean
local function onCooldown()
    local now = GetGameTimer()
    if (now - lastAction) < Config.ActionCooldown then
        return true
    end
    lastAction = now
    return false
end

--- Get player gender string
---@return string 'male'|'female'
local function getGender()
    local model = GetEntityModel(cache.ped)
    if model == `mp_m_freemode_01` then
        return 'male'
    else
        return 'female'
    end
end

--- Save current bag component clothing
local function saveClothing()
    local ped = cache.ped
    previousClothing = {
        drawable = GetPedDrawableVariation(ped, Config.BagComponent),
        texture = GetPedTextureVariation(ped, Config.BagComponent),
    }
end

--- Apply bag clothing visually using illenium-appearance compatible method
---@param backpackType string
local function applyBagClothing(backpackType)
    local cfg = Config.Backpacks[backpackType]
    if not cfg then return end

    local gender = getGender()
    local clothes = gender == 'male' and cfg.male or cfg.female

    -- Use illenium-appearance's setPedAppearance for networked sync
    -- This ensures ALL players see the change, not just local
    local ped = cache.ped

    -- Set the component variation (component 5 = bags)
    SetPedComponentVariation(ped, Config.BagComponent, clothes.drawable, clothes.texture, 0)

    -- Use illenium-appearance export to persist and network the change
    -- This triggers a full appearance update that syncs to all clients
    local currentAppearance = exports['illenium-appearance']:getPedAppearance(ped)
    if currentAppearance then
        if currentAppearance.components then
            -- Update the bag component in the appearance data
            for _, comp in ipairs(currentAppearance.components) do
                if comp.component_id == Config.BagComponent then
                    comp.drawable = clothes.drawable
                    comp.texture = clothes.texture
                    break
                end
            end
        end
        -- Apply the full appearance which networks automatically via illenium-appearance
        exports['illenium-appearance']:setPedAppearance(ped, currentAppearance)
    end
end

--- Remove bag clothing and restore previous
local function removeBagClothing()
    local ped = cache.ped
    local gender = getGender()
    local defaults = Config.DefaultClothing[gender]

    local restore = previousClothing or defaults

    SetPedComponentVariation(ped, Config.BagComponent, restore.drawable, restore.texture, 0)

    -- Sync via illenium-appearance
    local currentAppearance = exports['illenium-appearance']:getPedAppearance(ped)
    if currentAppearance then
        if currentAppearance.components then
            for _, comp in ipairs(currentAppearance.components) do
                if comp.component_id == Config.BagComponent then
                    comp.drawable = restore.drawable
                    comp.texture = restore.texture
                    break
                end
            end
        end
        exports['illenium-appearance']:setPedAppearance(ped, currentAppearance)
    end

    previousClothing = nil
end

---------------------------------------------------------------------------
-- EQUIP / UNEQUIP
---------------------------------------------------------------------------

--- Equip a backpack
---@param slot number
local function equipBackpack(slot)
    if onCooldown() then return end

    local success, result = lib.callback.await('hbs-bags:server:equip', false, slot)
    if not success then
        return lib.notify({ title = 'Backpack', description = result or 'Failed to equip.', type = 'error' })
    end

    local backpackType = result
    saveClothing()
    applyBagClothing(backpackType)

    equippedBackpack = { slot = slot, backpackType = backpackType }

    -- Broadcast visual to all players via server
    TriggerServerEvent('hbs-bags:server:syncVisual', backpackType, true)

    lib.notify({ title = 'Backpack', description = 'Backpack equipped.', type = 'success' })
end

--- Unequip the current backpack
local function unequipBackpack()
    if onCooldown() then return end
    if not equippedBackpack then
        return lib.notify({ title = 'Backpack', description = 'No backpack equipped.', type = 'error' })
    end

    local success, result = lib.callback.await('hbs-bags:server:unequip', false)
    if not success then
        return lib.notify({ title = 'Backpack', description = result or 'Failed to unequip.', type = 'error' })
    end

    local prevType = equippedBackpack.backpackType
    removeBagClothing()
    equippedBackpack = nil

    -- Broadcast visual removal to all players
    TriggerServerEvent('hbs-bags:server:syncVisual', prevType, false)

    lib.notify({ title = 'Backpack', description = 'Backpack unequipped.', type = 'success' })
end

--- Force unequip (triggered by server when item is removed)
RegisterNetEvent('hbs-bags:client:forceUnequip', function()
    if equippedBackpack then
        local prevType = equippedBackpack.backpackType
        removeBagClothing()
        equippedBackpack = nil
        TriggerServerEvent('hbs-bags:server:syncVisual', prevType, false)
        lib.notify({ title = 'Backpack', description = 'Backpack automatically unequipped.', type = 'inform' })
    end
end)

---------------------------------------------------------------------------
-- STASH
---------------------------------------------------------------------------

--- Open the backpack stash
---@param slot number
local function openStash(slot)
    if onCooldown() then return end

    local success, result = lib.callback.await('hbs-bags:server:openStash', false, slot)
    if not success then
        return lib.notify({ title = 'Backpack', description = result or 'Failed to open stash.', type = 'error' })
    end

    -- result = stashId
    exports.ox_inventory:openInventory('stash', result)
end

---------------------------------------------------------------------------
-- RENAME
---------------------------------------------------------------------------

---@param slot number
local function renameBackpack(slot)
    if not Config.Rename.enabled then
        return lib.notify({ title = 'Backpack', description = 'Renaming is disabled.', type = 'error' })
    end

    local input = lib.inputDialog('Rename Backpack', {
        { type = 'input', label = 'New Name', placeholder = 'Enter new name...', max = Config.Rename.maxLength, required = true },
    })

    if not input or not input[1] then return end

    local success, result = lib.callback.await('hbs-bags:server:rename', false, slot, input[1])
    if not success then
        return lib.notify({ title = 'Backpack', description = result or 'Failed to rename.', type = 'error' })
    end

    lib.notify({ title = 'Backpack', description = ('Renamed to: %s'):format(result), type = 'success' })
end

---------------------------------------------------------------------------
-- REPAIR
---------------------------------------------------------------------------

---@param slot number
local function repairBackpack(slot)
    if not Config.Repair.enabled then
        return lib.notify({ title = 'Backpack', description = 'Repair is disabled.', type = 'error' })
    end
    if onCooldown() then return end

    local success, result = lib.callback.await('hbs-bags:server:repair', false, slot)
    if not success then
        return lib.notify({ title = 'Backpack', description = result or 'Failed to repair.', type = 'error' })
    end

    lib.notify({ title = 'Backpack', description = ('Durability restored to %d%%.'):format(result), type = 'success' })
end

---------------------------------------------------------------------------
-- UPGRADE
---------------------------------------------------------------------------

---@param slot number
local function upgradeBackpack(slot)
    if onCooldown() then return end

    -- Build upgrade options from config
    local options = {}
    for key, cfg in pairs(Config.Upgrades) do
        options[#options + 1] = { value = key, label = cfg.label }
    end

    if #options == 0 then
        return lib.notify({ title = 'Backpack', description = 'No upgrades available.', type = 'error' })
    end

    -- If only one upgrade type, use it directly
    local upgradeKey
    if #options == 1 then
        upgradeKey = options[1].value
    else
        local input = lib.inputDialog('Upgrade Backpack', {
            { type = 'select', label = 'Select Upgrade', options = options, required = true },
        })
        if not input or not input[1] then return end
        upgradeKey = input[1]
    end

    local success, result = lib.callback.await('hbs-bags:server:upgrade', false, slot, upgradeKey)
    if not success then
        return lib.notify({ title = 'Backpack', description = result or 'Failed to upgrade.', type = 'error' })
    end

    local upgCfg = Config.Upgrades[upgradeKey]
    lib.notify({
        title = 'Backpack',
        description = ('Upgrade applied! (%d/%d)'):format(result, upgCfg.maxApplications),
        type = 'success',
    })
end

---------------------------------------------------------------------------
-- INSPECT
---------------------------------------------------------------------------

---@param slot number
local function inspectBackpack(slot)
    local info, err = lib.callback.await('hbs-bags:server:inspect', false, slot)
    if not info then
        return lib.notify({ title = 'Backpack', description = err or 'Failed to inspect.', type = 'error' })
    end

    -- Build upgrade text
    local upgradeLines = {}
    for key, count in pairs(info.upgrades or {}) do
        local cfg = Config.Upgrades[key]
        if cfg then
            upgradeLines[#upgradeLines + 1] = ('  %s: %d/%d'):format(cfg.label, count, cfg.maxApplications)
        end
    end

    local upgradeText = #upgradeLines > 0 and table.concat(upgradeLines, '\n') or '  None'

    lib.alertDialog({
        header = info.customName or 'Backpack',
        content = ('**ID:** %s  \n**Type:** %s  \n**Durability:** %d%%  \n**Slots:** %d  \n**Max Weight:** %dg  \n**Upgrades:**  \n%s'):format(
            info.backpackId,
            info.backpackType,
            info.durability,
            info.slots,
            info.weight,
            upgradeText
        ),
        centered = true,
    })
end

---------------------------------------------------------------------------
-- CONTEXT MENU (ox_lib)
---------------------------------------------------------------------------

--- Open the backpack interaction menu
---@param slot number
---@param metadata table
local function openBackpackMenu(slot, metadata)
    local isEquipped = equippedBackpack and equippedBackpack.backpackType ~= nil
    local isThisEquipped = equippedBackpack and metadata.backpackId and equippedBackpack.slot == slot

    local menuOptions = {}

    -- Open Backpack (stash)
    menuOptions[#menuOptions + 1] = {
        title = 'Open Backpack',
        description = 'Access backpack storage',
        icon = 'box-open',
        onSelect = function()
            openStash(slot)
        end,
    }

    -- Equip / Unequip
    if isThisEquipped then
        menuOptions[#menuOptions + 1] = {
            title = 'Unequip Backpack',
            description = 'Remove backpack from your back',
            icon = 'arrow-down',
            onSelect = function()
                unequipBackpack()
            end,
        }
    else
        menuOptions[#menuOptions + 1] = {
            title = 'Equip Backpack',
            description = 'Wear this backpack',
            icon = 'arrow-up',
            onSelect = function()
                equipBackpack(slot)
            end,
        }
    end

    -- Rename
    if Config.Rename.enabled then
        menuOptions[#menuOptions + 1] = {
            title = 'Rename Backpack',
            description = ('Current: %s'):format(metadata.customName or 'Unnamed'),
            icon = 'pen',
            onSelect = function()
                renameBackpack(slot)
            end,
        }
    end

    -- Repair
    if Config.Repair.enabled then
        menuOptions[#menuOptions + 1] = {
            title = 'Repair Backpack',
            description = ('Durability: %d%%'):format(metadata.durability or 100),
            icon = 'wrench',
            onSelect = function()
                repairBackpack(slot)
            end,
        }
    end

    -- Upgrade
    local hasUpgrades = false
    for _ in pairs(Config.Upgrades) do hasUpgrades = true break end
    if hasUpgrades then
        menuOptions[#menuOptions + 1] = {
            title = 'Upgrade Backpack',
            description = 'Enhance backpack capacity',
            icon = 'arrow-up-right-dots',
            onSelect = function()
                upgradeBackpack(slot)
            end,
        }
    end

    -- Inspect
    menuOptions[#menuOptions + 1] = {
        title = 'Inspect Backpack',
        description = 'View backpack details',
        icon = 'magnifying-glass',
        onSelect = function()
            inspectBackpack(slot)
        end,
    }

    lib.registerContext({
        id = 'hbs_bags_menu',
        title = metadata.customName or 'Backpack',
        options = menuOptions,
    })

    lib.showContext('hbs_bags_menu')
end

---------------------------------------------------------------------------
-- EVENT: Server triggers menu open after item use
---------------------------------------------------------------------------

RegisterNetEvent('hbs-bags:client:openMenu', function(slot, metadata)
    openBackpackMenu(slot, metadata)
end)

---------------------------------------------------------------------------
-- NETWORKED VISUAL SYNC: Apply visual for any player
---------------------------------------------------------------------------

RegisterNetEvent('hbs-bags:client:applyVisual', function(playerId, backpackType, equipped)
    local targetPed = GetPlayerPed(GetPlayerFromServerId(playerId))
    if not targetPed or targetPed == 0 then return end

    local cfg = Config.Backpacks[backpackType]
    if not cfg then return end

    if equipped then
        local gender
        local model = GetEntityModel(targetPed)
        if model == `mp_m_freemode_01` then
            gender = 'male'
        else
            gender = 'female'
        end

        local clothes = gender == 'male' and cfg.male or cfg.female
        SetPedComponentVariation(targetPed, Config.BagComponent, clothes.drawable, clothes.texture, 0)
    else
        -- Remove bag: set to default
        local gender
        local model = GetEntityModel(targetPed)
        if model == `mp_m_freemode_01` then
            gender = 'male'
        else
            gender = 'female'
        end

        local defaults = Config.DefaultClothing[gender]
        SetPedComponentVariation(targetPed, Config.BagComponent, defaults.drawable, defaults.texture, 0)
    end
end)

---------------------------------------------------------------------------
-- PLAYER LOAD: Restore equipped state and request other players' visuals
---------------------------------------------------------------------------

local function onPlayerLoaded()
    -- Wait for server callbacks to be registered
    Wait(2000)

    -- Safely attempt to restore equipped state
    local ok, data = pcall(lib.callback.await, 'hbs-bags:server:getEquipped', false)
    if ok and data then
        equippedBackpack = {
            slot = data.slot,
            backpackType = data.backpackType,
        }
        saveClothing()
        applyBagClothing(data.backpackType)
    end

    -- Request all other players' visuals
    TriggerServerEvent('hbs-bags:server:requestAllVisuals')
end

-- QBX Core player loaded event
RegisterNetEvent('QBCore:Client:OnPlayerLoaded', onPlayerLoaded)

-- Also handle resource restart
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    Wait(3000) -- Wait for server to fully initialize
    onPlayerLoaded()
end)

---------------------------------------------------------------------------
-- OX_TARGET: Optional interaction for nearby players wearing backpacks
---------------------------------------------------------------------------

-- Players can look at someone wearing a backpack
-- This is optional; uncomment below to enable target interaction on other players

--[[
exports.ox_target:addGlobalPlayer({
    {
        name = 'hbs_bags_look',
        label = 'Look at Backpack',
        icon = 'fas fa-eye',
        distance = 2.5,
        onSelect = function(data)
            lib.notify({ title = 'Backpack', description = 'This player is wearing a backpack.', type = 'inform' })
        end,
    },
})
--]]

---------------------------------------------------------------------------
-- CLEANUP ON RESOURCE STOP
---------------------------------------------------------------------------

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    if equippedBackpack then
        removeBagClothing()
        equippedBackpack = nil
    end
end)

print('^2[hbs-bags]^0 Client loaded.')
