---------------------------------------------------------------------------
-- CLIENT STATE
---------------------------------------------------------------------------

local equippedBackpack = nil     -- { slot = n, backpackId = "...", backpackType = "..." }
local previousClothing = nil     -- { drawable = n, texture = n } saved before equip

---------------------------------------------------------------------------
-- HELPERS
---------------------------------------------------------------------------

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

--- Apply bag clothing visually
---@param backpackType string
local function applyBagClothing(backpackType)
    local cfg = Config.Backpacks[backpackType]
    if not cfg then return end

    local gender = getGender()
    local clothes = gender == 'male' and cfg.male or cfg.female
    local ped = cache.ped

    -- SetPedComponentVariation on the owning player's ped is automatically
    -- networked to other clients by GTA.
    SetPedComponentVariation(ped, Config.BagComponent, clothes.drawable, clothes.texture, 0)

    -- Also try illenium-appearance to persist across clothing changes/respawns
    pcall(function()
        local appearance = exports['illenium-appearance']:getPedAppearance(ped)
        if appearance and appearance.components then
            for _, comp in ipairs(appearance.components) do
                if comp.component_id == Config.BagComponent then
                    comp.drawable = clothes.drawable
                    comp.texture = clothes.texture
                    break
                end
            end
            exports['illenium-appearance']:setPedAppearance(ped, appearance)
        end
    end)
end

--- Remove bag clothing and restore previous
local function removeBagClothing()
    local ped = cache.ped
    local gender = getGender()
    local defaults = Config.DefaultClothing[gender]
    local restore = previousClothing or defaults

    SetPedComponentVariation(ped, Config.BagComponent, restore.drawable, restore.texture, 0)

    pcall(function()
        local appearance = exports['illenium-appearance']:getPedAppearance(ped)
        if appearance and appearance.components then
            for _, comp in ipairs(appearance.components) do
                if comp.component_id == Config.BagComponent then
                    comp.drawable = restore.drawable
                    comp.texture = restore.texture
                    break
                end
            end
            exports['illenium-appearance']:setPedAppearance(ped, appearance)
        end
    end)

    previousClothing = nil
end

---------------------------------------------------------------------------
-- EQUIP / UNEQUIP
---------------------------------------------------------------------------

--- Unequip the current backpack
local function unequipBackpack()
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
-- STASH / EQUIP EVENTS
---------------------------------------------------------------------------

-- Forward declaration (defined further below after menu helper functions)
local openBackpackMenu

--- Equip visuals + open menu in one action (called on first use)
RegisterNetEvent('hbs-bags:client:equipAndMenu', function(slot, backpackType, metadata)
    saveClothing()
    applyBagClothing(backpackType)

    equippedBackpack = { slot = slot, backpackType = backpackType }

    TriggerServerEvent('hbs-bags:server:syncVisual', backpackType, true)
    lib.notify({ title = 'Backpack', description = 'Backpack equipped.', type = 'success' })

    Wait(300)
    openBackpackMenu(slot, metadata)
end)

--- Open stash from menu
---@param slot number
local function openStash(slot)
    local success, result = lib.callback.await('hbs-bags:server:openStash', false, slot)
    if not success then
        return lib.notify({ title = 'Backpack', description = result or 'Failed to open stash.', type = 'error' })
    end

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
    local options = {}
    for key, cfg in pairs(Config.Upgrades) do
        options[#options + 1] = { value = key, label = cfg.label }
    end

    if #options == 0 then
        return lib.notify({ title = 'Backpack', description = 'No upgrades available.', type = 'error' })
    end

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
-- Only shown when player is wearing a DIFFERENT bag and uses another one.
-- Normal flow: use item → auto equip + open stash (no menu needed).
---------------------------------------------------------------------------

---@param slot number
---@param metadata table
openBackpackMenu = function(slot, metadata)
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

    -- Unequip current bag
    if equippedBackpack then
        menuOptions[#menuOptions + 1] = {
            title = 'Unequip Current Backpack',
            description = 'Remove your currently equipped backpack',
            icon = 'arrow-down',
            onSelect = function()
                unequipBackpack()
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
-- EVENT: Server triggers menu (only when wearing a different bag)
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
    Wait(2000)

    local ok, data = pcall(lib.callback.await, 'hbs-bags:server:getEquipped', false)
    if ok and data then
        equippedBackpack = {
            slot = data.slot,
            backpackType = data.backpackType,
        }
        saveClothing()
        applyBagClothing(data.backpackType)
    end

    TriggerServerEvent('hbs-bags:server:requestAllVisuals')
end

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', onPlayerLoaded)

AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    Wait(3000)
    onPlayerLoaded()
end)

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
