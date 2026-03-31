----------------------------------------------------------------------
-- ProfKnowledge — API.lua
-- Public API for external addons (e.g. VamoosesGuildCraft)
----------------------------------------------------------------------

local ADDON_NAME, PK = ...

----------------------------------------------------------------------
-- Global API table
----------------------------------------------------------------------

ProfKnowledgeAPI = {}

--- Returns addon version string.
function ProfKnowledgeAPI.GetVersion()
    return C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or "unknown"
end

--- Returns true if ProfKnowledge data is loaded and ready.
function ProfKnowledgeAPI.IsReady()
    return PK.db ~= nil
end

--- Returns the profession lookup table (read-only copy).
--- { [baseSkillLineID] = { name = "Leatherworking", icon = 133611, ... }, ... }
function ProfKnowledgeAPI.GetProfessionList()
    if not PK.ProfessionData then return {} end
    return CopyTable(PK.ProfessionData)
end

--- Returns the set of crafting profession IDs.
--- { [baseSkillLineID] = true, ... }
function ProfKnowledgeAPI.GetCraftingProfessions()
    if not PK.CraftingProfessions then return {} end
    return CopyTable(PK.CraftingProfessions)
end

----------------------------------------------------------------------
-- Character queries
----------------------------------------------------------------------

--- Get characters that have a given profession.
--- source: "local" (own alts), "guild" (synced guild data), or "all" (both, deduplicated).
--- Returns: { { charKey, className, classID, level, source,
---             skillLevel, maxSkillLevel, totalKnowledgeSpent, unspentKnowledge,
---             concentration, maxConcentration }, ... }
function ProfKnowledgeAPI.GetCharactersWithProfession(skillLineID, source)
    if not PK.db or not skillLineID then return {} end
    source = source or "all"

    local function flatten(entry, src)
        local pd = entry.profData or {}
        return {
            charKey             = entry.charKey,
            className           = entry.className,
            classID             = entry.classID,
            level               = entry.level,
            source              = src,
            skillLevel          = pd.skillLevel or 0,
            maxSkillLevel       = pd.maxSkillLevel or 0,
            totalKnowledgeSpent = pd.totalKnowledgeSpent or 0,
            unspentKnowledge    = pd.unspentKnowledge or 0,
            concentration       = pd.concentration or 0,
            maxConcentration    = pd.maxConcentration or 0,
        }
    end

    local results = {}
    local seen = {}

    if source == "local" or source == "all" then
        local locals = PK:GetAllCharactersForProfession(skillLineID) or {}
        for _, entry in ipairs(locals) do
            if not seen[entry.charKey] then
                table.insert(results, flatten(entry, "local"))
                seen[entry.charKey] = true
            end
        end
    end

    if source == "guild" or source == "all" then
        local guild = PK:GetGuildCharactersForProfession(skillLineID) or {}
        for _, entry in ipairs(guild) do
            if not seen[entry.charKey] then
                table.insert(results, flatten(entry, "guild"))
                seen[entry.charKey] = true
            end
        end
    end

    return results
end

--- Get specialization tree data for a character and profession.
--- Returns: { tabs = { { name, pointsSpent, maxPoints,
---             nodes = { { name, currentRank, maxRanks }, ... } }, ... } }
--- or nil if not found.
function ProfKnowledgeAPI.GetSpecializations(charKey, skillLineID)
    if not PK.db or not charKey or not skillLineID then return nil end

    local charData = PK:FindCharacterData(charKey)
    if not charData then return nil end

    local profData = charData.professions and charData.professions[skillLineID]
    if not profData or not profData.tabs then return nil end

    -- Return a deep copy so external addons can't corrupt internal state
    return CopyTable(profData.tabs)
end

----------------------------------------------------------------------
-- Recipe / item queries
----------------------------------------------------------------------

--- Find characters that have learned a specific recipe (by recipeID/spellID).
--- Returns: { { charKey, className, recipeName, skillLevel, maxSkillLevel, baseID }, ... }
function ProfKnowledgeAPI.GetCraftersForRecipe(recipeID)
    if not PK.db or not recipeID then return {} end

    local raw = PK:GetCraftersForRecipe(recipeID) or {}
    local results = {}
    for _, entry in ipairs(raw) do
        table.insert(results, {
            charKey    = entry.charKey,
            className  = entry.className,
            recipeName = entry.recipeName,
            baseID     = entry.baseID,
            skillLevel    = entry.profData and entry.profData.skillLevel or 0,
            maxSkillLevel = entry.profData and entry.profData.maxSkillLevel or 0,
        })
    end
    return results
end

--- Find characters that can craft a specific item (by output itemID).
--- Returns: { { charKey, className, recipeName, recipeID, skillLevel, maxSkillLevel, baseID }, ... }
function ProfKnowledgeAPI.GetCraftersForItem(itemID)
    if not PK.db or not itemID then return {} end

    local raw = PK:GetCraftersForItem(itemID) or {}
    local results = {}
    for _, entry in ipairs(raw) do
        table.insert(results, {
            charKey       = entry.charKey,
            className     = entry.className,
            recipeName    = entry.recipeName,
            recipeID      = entry.recipeID,
            baseID        = entry.baseID,
            skillLevel    = entry.profData and entry.profData.skillLevel or 0,
            maxSkillLevel = entry.profData and entry.profData.maxSkillLevel or 0,
        })
    end
    return results
end

--- Get the set of all item IDs craftable by any tracked character.
--- Returns: { [itemID] = true, ... }
function ProfKnowledgeAPI.GetAllCraftableItemIDs()
    if not PK.db then return {} end
    return PK:GetAllCraftableItemIDs()
end

----------------------------------------------------------------------
-- Callback system
----------------------------------------------------------------------

local callbacks = {}  -- { [event] = { [addonName] = callback, ... }, ... }

--- Register a callback for a ProfKnowledge event.
--- Events: "DATA_UPDATED" — fires after any scan or guild sync completes.
function ProfKnowledgeAPI.RegisterCallback(addonName, event, callback)
    if not addonName or not event or not callback then return end
    if not callbacks[event] then callbacks[event] = {} end
    callbacks[event][addonName] = callback
end

--- Unregister a previously registered callback.
function ProfKnowledgeAPI.UnregisterCallback(addonName, event)
    if callbacks[event] then
        callbacks[event][addonName] = nil
    end
end

--- (Internal) Fire all registered callbacks for an event.
function PK:FireAPICallbacks(event, ...)
    if not callbacks[event] then return end
    for name, cb in pairs(callbacks[event]) do
        local ok, err = pcall(cb, ...)
        if not ok then
            PK:Debug("API callback error (" .. name .. "/" .. event .. "): " .. tostring(err))
        end
    end
end
