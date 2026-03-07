----------------------------------------------------------------------
-- ProfKnowledge — Core.lua
-- Addon bootstrap, event handling, profession scanning
--
-- KEY INSIGHT: All C_ProfSpecs functions require the expansion-specific
-- "variant" skill line ID (e.g., 2871 = Khaz Algar Alchemy), NOT the
-- base profession ID (e.g., 171 = Alchemy). GetProfessionInfo() returns
-- the base ID, which is useless for spec tree scanning.
--
-- The correct API to discover variant IDs is:
--   C_TradeSkillUI.GetAllProfessionTradeSkillLines()
-- This returns every variant the player knows in one call.
----------------------------------------------------------------------

local ADDON_NAME, PK = ...

-- Public namespace
PK.name    = ADDON_NAME
PK.version = (C_AddOns and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")) or "1.0.0"

-- Internal state
PK.playerName    = nil
PK.playerRealm   = nil
PK.playerClass    = nil
PK.playerClassID  = nil
PK.playerLevel    = nil
PK.charKey        = nil
PK.profFrameReady = false

----------------------------------------------------------------------
-- Broadcast debounce — coalesces rapid events into a single sync
----------------------------------------------------------------------

local pendingBroadcast = nil   -- timer handle
local BROADCAST_COOLDOWN = 5   -- seconds to wait after last event

--- Schedule a SeedOwnData + BroadcastDelta, debounced.
--- Multiple calls within BROADCAST_COOLDOWN collapse into one.
--- Only broadcasts when PK summary or the profession spec page is open.
function PK:ScheduleBroadcast()
    -- Only sync when relevant UI is visible
    local pkFrame = ProfKnowledgeSummaryFrame
    local pkOpen = pkFrame and pkFrame:IsShown()
    local specOpen = ProfessionsFrame and ProfessionsFrame:IsShown()
    if not pkOpen and not specOpen then return end

    if pendingBroadcast then
        pendingBroadcast:Cancel()
    end
    pendingBroadcast = C_Timer.NewTimer(BROADCAST_COOLDOWN, function()
        pendingBroadcast = nil
        PK:SeedOwnData()
        PK:BroadcastDelta()
        PK:Debug("Debounced broadcast fired")
    end)
end

----------------------------------------------------------------------
-- Debug / Print helpers
----------------------------------------------------------------------

function PK:Print(...)
    print("|cff00ccffProfKnowledge|r:", ...)
end

function PK:Debug(...)
    if PK.db and PK.db.settings and PK.db.settings.debug then
        print("|cff888888PK Debug|r:", ...)
    end
end

----------------------------------------------------------------------
-- Player info helpers
----------------------------------------------------------------------

function PK:UpdatePlayerInfo()
    self.playerName  = UnitName("player")
    self.playerRealm = GetRealmName()
    self.charKey     = self.playerName .. "-" .. self.playerRealm

    local _, classFile, classID = UnitClass("player")
    self.playerClass   = classFile
    self.playerClassID = classID
    self.playerLevel   = UnitLevel("player")
end

function PK:GetCurrentCharacterKey()
    return self.charKey
end

----------------------------------------------------------------------
-- Node name resolution
-- Chain: nodeInfo → entryID → definitionID → spellID → name
----------------------------------------------------------------------

function PK:ResolveNodeName(configID, nodeInfo)
    if not nodeInfo or not nodeInfo.entryIDs then return nil end

    for _, entryID in ipairs(nodeInfo.entryIDs) do
        local entryOK, entryInfo = pcall(C_Traits.GetEntryInfo, configID, entryID)
        if entryOK and entryInfo and entryInfo.definitionID then
            local defOK, defInfo = pcall(C_Traits.GetDefinitionInfo, entryInfo.definitionID)
            if defOK and defInfo then
                if defInfo.spellID then
                    local spellName
                    if C_Spell and C_Spell.GetSpellName then
                        spellName = C_Spell.GetSpellName(defInfo.spellID)
                    elseif GetSpellInfo then
                        spellName = GetSpellInfo(defInfo.spellID)
                    end
                    if spellName and spellName ~= "" then
                        return spellName
                    end
                end
                if defInfo.overrideName and defInfo.overrideName ~= "" then
                    return defInfo.overrideName
                end
            end
        end
    end

    return nil
end

----------------------------------------------------------------------
-- Profession scanning — THE CORRECT APPROACH
--
-- Step 1: C_TradeSkillUI.GetAllProfessionTradeSkillLines()
--         → returns all expansion-specific variant IDs the player knows
--
-- Step 2: For each variant:
--         C_TradeSkillUI.GetProfessionInfoBySkillLineID(variantID)
--         → gives us name, parentProfessionID (base ID), skill level
--
-- Step 3: C_ProfSpecs.SkillLineHasSpecialization(variantID)
--         → check if this expansion variant has a spec tree
--
-- Step 4: C_ProfSpecs.GetConfigIDForSkillLine(variantID)
--         → get the trait config for scanning nodes
--
-- Step 5: C_ProfSpecs.GetSpecTabIDsForSkillLine(variantID)
--         → get tab tree IDs for each specialization category
--
-- Step 6: C_Traits.GetTreeNodes(tabTreeID) + GetNodeInfo(configID, nodeID)
--         → enumerate nodes and their ranks
----------------------------------------------------------------------

function PK:ScanAllProfessions()
    if not self.charKey then
        self:UpdatePlayerInfo()
    end

    -- Get basic profession info first (always works)
    -- GetProfessions() returns: prof1, prof2, archaeology, fishing, cooking
    local prof1, prof2, archaeology, fishing, cooking = GetProfessions()
    local basicInfo = {}  -- baseSkillLineID → { name, icon, skillLevel, maxSkillLevel }
    for _, profIndex in ipairs({ prof1, prof2, archaeology, fishing, cooking }) do
        if profIndex then
            local name, icon, skillLevel, maxSkillLevel, _, _, skillLineID = GetProfessionInfo(profIndex)
            if skillLineID and name then
                basicInfo[skillLineID] = {
                    name          = name,
                    icon          = icon,
                    skillLevel    = skillLevel,
                    maxSkillLevel = maxSkillLevel,
                }
            end
        end
    end

    -- Track which base skillLineIDs are in the main profession slots
    local prof1BaseID, prof2BaseID = nil, nil
    if prof1 then
        local _, _, _, _, _, _, sid = GetProfessionInfo(prof1)
        prof1BaseID = sid
    end
    if prof2 then
        local _, _, _, _, _, _, sid = GetProfessionInfo(prof2)
        prof2BaseID = sid
    end

    -- Now discover variant IDs and scan spec trees
    local profData = {}
    local scannedBaseIDs = {}

    -- THE KEY API: Get all expansion-specific variant skill line IDs
    local allVariants = {}
    if C_TradeSkillUI and C_TradeSkillUI.GetAllProfessionTradeSkillLines then
        local ok, result = pcall(C_TradeSkillUI.GetAllProfessionTradeSkillLines)
        if ok and result then
            allVariants = result
            PK:Debug("GetAllProfessionTradeSkillLines returned " .. #allVariants .. " variants")
        else
            PK:Debug("GetAllProfessionTradeSkillLines failed: " .. tostring(result))
        end
    else
        PK:Debug("C_TradeSkillUI.GetAllProfessionTradeSkillLines not available")
    end

    -- Scan each variant
    for _, variantID in ipairs(allVariants) do
        local scanResult = self:ScanVariant(variantID, basicInfo)
        if scanResult then
            local baseID = scanResult.baseSkillLineID or scanResult.skillLineID
            -- Keep the variant with the most data (or most recent expansion)
            if not profData[baseID] or self:IsBetterScan(scanResult, profData[baseID]) then
                profData[baseID] = scanResult
                scannedBaseIDs[baseID] = true
            end
        end
    end

    -- Fill in any basic professions that weren't covered by variants
    for baseID, info in pairs(basicInfo) do
        if not scannedBaseIDs[baseID] then
            profData[baseID] = {
                skillLineID         = baseID,
                baseSkillLineID     = baseID,
                variantID           = nil,
                name                = info.name,
                icon                = info.icon,
                skillLevel          = info.skillLevel,
                maxSkillLevel       = info.maxSkillLevel,
                hasSpec             = false,
                unspentKnowledge    = 0,
                totalKnowledgeSpent = 0,
                tabs                = {},
            }
        end
    end

    -- Merge: preserve cached tree data from previous deep scans
    if self.db and self.db.characters and self.db.characters[self.charKey] then
        local existing = self.db.characters[self.charKey].professions or {}
        for baseID, newData in pairs(profData) do
            local cached = existing[baseID]
            if cached then
                -- Preserve variant/expansion info from earlier scans if missing
                if not newData.variantID and cached.variantID then
                    newData.variantID = cached.variantID
                end
                if not newData.expansionName and cached.expansionName then
                    newData.expansionName = cached.expansionName
                end
                -- Preserve tree data when the new scan came up empty
                if newData.hasSpec and (not newData.tabs or next(newData.tabs) == nil) then
                    if cached.tabs and next(cached.tabs) ~= nil then
                        PK:Debug("Preserving cached tree data for " .. (newData.name or "?"))
                        newData.tabs = cached.tabs
                        newData.totalKnowledgeSpent = cached.totalKnowledgeSpent or 0
                        newData.unspentKnowledge = cached.unspentKnowledge or 0
                    end
                end
            end
        end
    end

    -- Save (include prof slot assignments)
    self:SaveCharacterData(profData, prof1BaseID, prof2BaseID)

    local count = 0
    for _ in pairs(profData) do count = count + 1 end
    PK:Debug("Scanned " .. count .. " profession(s) for " .. self.charKey
        .. " (prof1=" .. tostring(prof1BaseID) .. " prof2=" .. tostring(prof2BaseID) .. ")")
end

function PK:IsBetterScan(newScan, oldScan)
    -- Prefer higher variant IDs — newer expansions always have higher IDs.
    -- This ensures Midnight variants beat TWW, which beats Dragon Isles, etc.
    local newVID = newScan.variantID or newScan.skillLineID or 0
    local oldVID = oldScan.variantID or oldScan.skillLineID or 0
    if newVID ~= oldVID then
        return newVID > oldVID
    end
    -- Same variant: prefer scans with actual tree data
    local newHasTabs = newScan.tabs and next(newScan.tabs) ~= nil
    local oldHasTabs = oldScan.tabs and next(oldScan.tabs) ~= nil
    if newHasTabs and not oldHasTabs then return true end
    if not newHasTabs and oldHasTabs then return false end
    -- Same variant, same tab status: prefer higher skill level
    return (newScan.skillLevel or 0) > (oldScan.skillLevel or 0)
end

----------------------------------------------------------------------
-- Scan a single variant skill line ID
----------------------------------------------------------------------

function PK:ScanVariant(variantID, basicInfo)
    -- Get profession info for this variant
    local profInfo = nil
    if C_TradeSkillUI and C_TradeSkillUI.GetProfessionInfoBySkillLineID then
        local ok, result = pcall(C_TradeSkillUI.GetProfessionInfoBySkillLineID, variantID)
        if ok and result then
            profInfo = result
        end
    end

    local profName = profInfo and (profInfo.professionName or profInfo.parentProfessionName) or ("Profession " .. variantID)
    local parentID = profInfo and profInfo.parentProfessionID
    local baseID = parentID or variantID

    -- Get skill level from profInfo or fall back to basicInfo
    local skillLevel = profInfo and profInfo.skillLevel or 0
    local maxSkillLevel = profInfo and profInfo.maxSkillLevel or 0
    local icon = profInfo and profInfo.icon

    -- Override with basic info if we have it (more reliable for display name)
    if parentID and basicInfo[parentID] then
        local base = basicInfo[parentID]
        profName = base.name or profName
        icon = icon or base.icon
        -- Use the basic info's skill level if the variant reports 0
        if skillLevel == 0 then
            skillLevel = base.skillLevel or 0
            maxSkillLevel = base.maxSkillLevel or 0
        end
    end

    -- Determine expansion name from the variant profession name.
    -- e.g., professionName = "Khaz Algar Alchemy" and parentProfessionName = "Alchemy"
    -- expansion prefix = "Khaz Algar" → display name "The War Within"
    local expansionName = nil
    if profInfo then
        local variantFullName = profInfo.professionName or ""
        local baseName = profInfo.parentProfessionName or profName or ""
        -- Strip the base name from the end of the variant name to get the expansion prefix
        if baseName ~= "" and variantFullName ~= "" and variantFullName ~= baseName then
            local pattern = "%s*" .. baseName:gsub("([%(%)%.%%%+%-%*%?%[%^%$])", "%%%1") .. "$"
            local prefix = variantFullName:gsub(pattern, "")
            if prefix ~= "" and prefix ~= variantFullName then
                prefix = strtrim(prefix)
                -- Map raw prefix (e.g. "Khaz Algar") → display name ("The War Within")
                expansionName = PK.ExpansionDisplayNames[prefix] or prefix
            end
        end
    end

    PK:Debug("Scanning variant " .. variantID .. " (" .. profName .. ") parent=" .. tostring(parentID)
        .. " expansion=" .. tostring(expansionName))

    -- Check if this variant has a specialization tree
    local hasSpec = false
    if C_ProfSpecs and C_ProfSpecs.SkillLineHasSpecialization then
        local ok, result = pcall(C_ProfSpecs.SkillLineHasSpecialization, variantID)
        if ok then hasSpec = result end
    end

    if not hasSpec then
        PK:Debug("  No specialization tree for variant " .. variantID)
        return {
            skillLineID         = variantID,
            baseSkillLineID     = baseID,
            variantID           = variantID,
            expansionName       = expansionName,
            name                = profName,
            icon                = icon,
            skillLevel          = skillLevel,
            maxSkillLevel       = maxSkillLevel,
            hasSpec             = false,
            unspentKnowledge    = 0,
            totalKnowledgeSpent = 0,
            tabs                = {},
        }
    end

    -- Get the trait config ID (using the variant ID!)
    local configID = nil
    local configOK, configResult = pcall(C_ProfSpecs.GetConfigIDForSkillLine, variantID)
    if configOK and configResult and configResult ~= 0 then
        configID = configResult
    end

    if not configID then
        PK:Debug("  No configID for variant " .. variantID .. " (has spec but no config)")
        return {
            skillLineID         = variantID,
            baseSkillLineID     = baseID,
            variantID           = variantID,
            expansionName       = expansionName,
            name                = profName,
            icon                = icon,
            skillLevel          = skillLevel,
            maxSkillLevel       = maxSkillLevel,
            hasSpec             = true,
            unspentKnowledge    = 0,
            totalKnowledgeSpent = 0,
            tabs                = {},
        }
    end

    PK:Debug("  Got configID " .. configID .. " for variant " .. variantID)

    -- Cache the variant ID for this base profession
    self:CacheVariantID(baseID, variantID)

    -- Get unspent knowledge (using variant ID!)
    local unspent = 0
    local currOK, currencyInfo = pcall(C_ProfSpecs.GetCurrencyInfoForSkillLine, variantID)
    if currOK and currencyInfo then
        unspent = currencyInfo.numAvailable or 0
    end

    -- Get specialization tab tree IDs (using variant ID!)
    local tabTreeIDs = {}
    local tabOK, tabResult = pcall(C_ProfSpecs.GetSpecTabIDsForSkillLine, variantID)
    if tabOK and tabResult and #tabResult > 0 then
        tabTreeIDs = tabResult
    end

    -- Fallback: try getting tree IDs from the config itself
    if #tabTreeIDs == 0 then
        local ciOK, ciResult = pcall(C_Traits.GetConfigInfo, configID)
        if ciOK and ciResult and ciResult.treeIDs then
            tabTreeIDs = ciResult.treeIDs
            PK:Debug("  Got " .. #tabTreeIDs .. " tree(s) from config info fallback")
        end
    end

    PK:Debug("  Found " .. #tabTreeIDs .. " spec tab(s)")

    -- Scan each tab
    local tabs = {}
    local totalSpent = 0

    for _, tabTreeID in ipairs(tabTreeIDs) do
        local tabData = self:ScanSpecTab(tabTreeID, configID)
        tabs[tabTreeID] = tabData
        totalSpent = totalSpent + (tabData.pointsSpent or 0)
    end

    PK:Debug(string.format("  %s: %d spent, %d unspent, %d tabs",
        profName, totalSpent, unspent, #tabTreeIDs))

    return {
        skillLineID         = variantID,
        baseSkillLineID     = baseID,
        variantID           = variantID,
        expansionName       = expansionName,
        name                = profName,
        icon                = icon,
        skillLevel          = skillLevel,
        maxSkillLevel       = maxSkillLevel,
        hasSpec             = true,
        unspentKnowledge    = unspent,
        totalKnowledgeSpent = totalSpent,
        tabs                = tabs,
    }
end

----------------------------------------------------------------------
-- Scan a single specialization tab
----------------------------------------------------------------------

function PK:ScanSpecTab(tabTreeID, configID)
    -- Get tab name
    local tabName = "Tab " .. tabTreeID
    local tabInfoOK, tabInfo = pcall(C_ProfSpecs.GetTabInfo, tabTreeID)
    if tabInfoOK and tabInfo and tabInfo.name then
        tabName = tabInfo.name
    end

    -- Iterate all nodes in this tab's tree
    local tabSpent = 0
    local tabMaxPoints = 0
    local nodeDetails = {}

    local nodesOK, nodes = pcall(C_Traits.GetTreeNodes, tabTreeID)
    if nodesOK and nodes then
        PK:Debug("    Tab '" .. tabName .. "': " .. #nodes .. " nodes")
        for _, nodeID in ipairs(nodes) do
            local nodeOK, nodeInfo = pcall(C_Traits.GetNodeInfo, configID, nodeID)
            if nodeOK and nodeInfo then
                local maxRanks = nodeInfo.maxRanks or 0
                local currentRank = nodeInfo.currentRank or 0
                local ranksPurchased = nodeInfo.ranksPurchased or 0

                if maxRanks > 0 then
                    tabMaxPoints = tabMaxPoints + maxRanks
                    -- Knowledge spent = currentRank - 1 for unlocked nodes
                    -- (rank 1 is the free unlock, ranks 2+ cost knowledge)
                    -- BUT: using ranksPurchased if available, else currentRank
                    if ranksPurchased > 0 then
                        tabSpent = tabSpent + ranksPurchased
                    elseif currentRank > 0 then
                        tabSpent = tabSpent + currentRank
                    end

                    -- Resolve node name
                    local nodeName = self:ResolveNodeName(configID, nodeInfo)

                    if nodeName then
                        table.insert(nodeDetails, {
                            name        = nodeName,
                            currentRank = currentRank,
                            maxRanks    = maxRanks,
                            nodeID      = nodeID,
                        })
                    end
                end
            end
        end
    else
        PK:Debug("    Tab '" .. tabName .. "': GetTreeNodes failed")
    end

    -- Sort: invested first (desc by rank), then uninvested alphabetically
    table.sort(nodeDetails, function(a, b)
        if a.currentRank > 0 and b.currentRank == 0 then return true end
        if a.currentRank == 0 and b.currentRank > 0 then return false end
        if a.currentRank > 0 and b.currentRank > 0 then
            return a.currentRank > b.currentRank
        end
        return a.name < b.name
    end)

    return {
        name        = tabName,
        pointsSpent = tabSpent,
        maxPoints   = tabMaxPoints,
        nodes       = nodeDetails,
    }
end

----------------------------------------------------------------------
-- Cache variant ID in SavedVariables
----------------------------------------------------------------------

function PK:CacheVariantID(baseSkillLineID, variantID)
    if not self.db then return end
    if not self.db.discoveredVariants then
        self.db.discoveredVariants = {}
    end
    self.db.discoveredVariants[baseSkillLineID] = variantID
end

----------------------------------------------------------------------
-- Deep scan: called when the profession window is open.
-- Uses C_TradeSkillUI.GetProfessionChildSkillLineID() for the
-- currently-viewed profession, which is the most reliable API.
----------------------------------------------------------------------

function PK:DeepScanCurrentProfession()
    if not self.charKey then return end

    -- When the profession window is open, try to get the child skill line
    if C_TradeSkillUI and C_TradeSkillUI.GetProfessionChildSkillLineID then
        local ok, childID = pcall(C_TradeSkillUI.GetProfessionChildSkillLineID)
        if ok and childID and childID ~= 0 then
            PK:Debug("Deep scan: child skill line ID = " .. childID)
            -- This is the variant ID — scan it directly
            local scanResult = self:ScanVariant(childID, {})
            if scanResult and scanResult.tabs and next(scanResult.tabs) then
                local baseID = scanResult.baseSkillLineID or childID
                -- Merge into existing data
                if self.db and self.db.characters and self.db.characters[self.charKey] then
                    local existing = self.db.characters[self.charKey].professions or {}
                    existing[baseID] = scanResult
                    self.db.characters[self.charKey].professions = existing
                    self.db.characters[self.charKey].lastScanned = time()
                    PK:Debug("Deep scan: updated " .. (scanResult.name or "?") .. " with tree data")
                end
            end
        end
    end

    -- Also do a full re-scan (variant IDs may have become available)
    self:ScanAllProfessions()
end

----------------------------------------------------------------------
-- Profession frame hook (overlay on Blizzard profession UI)
----------------------------------------------------------------------

local function SetupProfessionUI()
    if PK.profFrameReady then return end

    local profFrame = ProfessionsFrame
    if not profFrame then return end

    PK.profFrameReady = true
    PK:Debug("Profession frame detected — setting up overlay")

    if PK.InitOverlay then
        PK:InitOverlay()
    end

    if PK.SetupSpecTreeOverlay then
        PK:SetupSpecTreeOverlay()
    end

end

local function SetupProfessionsBookButton()
    if PK.profBookButtonReady then return end
    if not ProfessionsBookFrame then return end

    PK.profBookButtonReady = true
    if PK.CreateProfessionsBookButton then
        PK:CreateProfessionsBookButton()
    end
end

local function SetupProfessionButton()
    if PK.profButtonReady then return end
    if not PlayerSpellsFrame then return end

    PK.profButtonReady = true
    if PK.CreateProfessionButton then
        PK:CreateProfessionButton()
    end
end

----------------------------------------------------------------------
-- Event Frame
----------------------------------------------------------------------

local f = CreateFrame("Frame")

f:SetScript("OnEvent", function(_, event, name)
    if event == "PLAYER_LOGIN" then
        PK:UpdatePlayerInfo()
        PK:InitStorage()
        PK:Print("v" .. PK.version .. " loaded. Type |cff00ccff/pk|r for help.")

        -- Defer scan to let profession data load
        C_Timer.After(4, function()
            PK:ScanAllProfessions()
        end)

        -- Initialize guild sync (deferred to let guild data load)
        C_Timer.After(6, function()
            if PK:GetSetting("guildSync") then
                PK:RegisterSyncHandlers()
                if PK:InitComm() then
                    PK:StartSync()
                    PK:Print("Guild sync |cff00ff00enabled|r.")
                end
            end
        end)

    elseif event == "ADDON_LOADED" then
        if name == "Blizzard_Professions" then
            C_Timer.After(1, SetupProfessionUI)
        elseif name == "Blizzard_PlayerSpells" then
            C_Timer.After(1, SetupProfessionButton)
        elseif name == "Blizzard_ProfessionsBook" or name == "Blizzard_ProfessionBook" then
            C_Timer.After(1, SetupProfessionsBookButton)
        end

        -- Fallback: try to attach PK button whenever any profession addon loads
        if ProfessionsBookFrame and not PK.profBookButtonReady then
            C_Timer.After(1, SetupProfessionsBookButton)
        end

    elseif event == "TRADE_SKILL_SHOW" then
        -- Also try ProfessionsBookFrame button here as a fallback
        if not PK.profBookButtonReady then
            SetupProfessionsBookButton()
        end
        -- Profession window opened -- best time to scan
        C_Timer.After(0.5, function()
            PK:DeepScanCurrentProfession()
            if PK.profFrameReady and PK.RefreshOverlay then
                PK:RefreshOverlay()
            end
            if PK.profFrameReady and PK.UpdateSpecTreeHighlights then
                C_Timer.After(0.5, function()
                    PK:UpdateSpecTreeHighlights()
                end)
            end
            PK:ScheduleBroadcast()
        end)

    elseif event == "TRADE_SKILL_LIST_UPDATE" then
        -- Profession data has fully loaded -- good time for deep scan
        C_Timer.After(0.5, function()
            PK:DeepScanCurrentProfession()
            if PK.profFrameReady and PK.RefreshOverlay then
                PK:RefreshOverlay()
            end
            if PK.profFrameReady and PK.UpdateSpecTreeHighlights then
                C_Timer.After(0.5, function()
                    PK:UpdateSpecTreeHighlights()
                end)
            end
            PK:ScheduleBroadcast()
        end)

    elseif event == "TRAIT_CONFIG_UPDATED" then
        -- Spec points changed
        C_Timer.After(1, function()
            PK:ScanAllProfessions()
            if PK.profFrameReady and PK.RefreshOverlay then
                PK:RefreshOverlay()
            end
            if PK.profFrameReady and PK.UpdateSpecTreeHighlights then
                C_Timer.After(0.5, function()
                    PK:UpdateSpecTreeHighlights()
                end)
            end
            PK:ScheduleBroadcast()
        end)

    elseif event == "SKILL_LINES_CHANGED" then
        -- Profession data loaded/changed
        C_Timer.After(2, function()
            PK:ScanAllProfessions()
            PK:ScheduleBroadcast()
        end)

    elseif event == "GUILD_ROSTER_UPDATE" then
        -- Guild roster changed — prune departed members
        if PK.guildKey then
            PK:PruneGuildRoster()
        end
    end
end)

-- Register events
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("TRADE_SKILL_SHOW")

pcall(f.RegisterEvent, f, "TRADE_SKILL_LIST_UPDATE")
pcall(f.RegisterEvent, f, "TRAIT_CONFIG_UPDATED")
pcall(f.RegisterEvent, f, "SKILL_LINES_CHANGED")
pcall(f.RegisterEvent, f, "GUILD_ROSTER_UPDATE")
