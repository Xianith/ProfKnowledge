----------------------------------------------------------------------
-- ProfKnowledge — Storage.lua
-- SavedVariables management, cross-character data access
----------------------------------------------------------------------

local ADDON_NAME, PK = ...

----------------------------------------------------------------------
-- Default database structure
----------------------------------------------------------------------

local DB_VERSION = 2

local DB_DEFAULTS = {
    version = DB_VERSION,
    characters = {},
    discoveredVariants = {},  -- Cache: baseSkillLineID → expansion variant ID
    guildRoster = {},         -- { ["GuildName-Realm"] = { ["CharName-Realm"] = entry, ... } }
    settings = {
        showOverlay  = true,   -- Node highlights on spec tree
        showAltPanel = true,   -- Alt Knowledge side panel
        showBadges   = true,
        guildSync    = true,   -- Enable guild sync by default
        debug        = false,  -- /pk debug to toggle
    },
}

----------------------------------------------------------------------
-- Initialize / load saved variables
----------------------------------------------------------------------

function PK:InitStorage()
    if not ProfKnowledgeDB then
        ProfKnowledgeDB = CopyTable(DB_DEFAULTS)
        PK:Debug("Created fresh database")
    end

    self.db = ProfKnowledgeDB

    -- Migration: ensure all default keys exist
    if not self.db.version then
        self.db.version = DB_VERSION
    end
    if not self.db.characters then
        self.db.characters = {}
    end
    if not self.db.discoveredVariants then
        self.db.discoveredVariants = {}
    end
    if not self.db.guildRoster then
        self.db.guildRoster = {}
    end
    if not self.db.settings then
        self.db.settings = CopyTable(DB_DEFAULTS.settings)
    else
        for k, v in pairs(DB_DEFAULTS.settings) do
            if self.db.settings[k] == nil then
                self.db.settings[k] = v
            end
        end
    end

    if self.db.version < DB_VERSION then
        self:MigrateDB(self.db.version, DB_VERSION)
        self.db.version = DB_VERSION
    end
end

----------------------------------------------------------------------
-- Migration
----------------------------------------------------------------------

function PK:MigrateDB(fromVersion, toVersion)
    PK:Debug("Migrating DB from v" .. fromVersion .. " to v" .. toVersion)
    -- v1 → v2: add guildRoster and guildSync setting
    if fromVersion < 2 then
        if not self.db.guildRoster then
            self.db.guildRoster = {}
        end
        if self.db.settings and self.db.settings.guildSync == nil then
            self.db.settings.guildSync = true
        end
    end
end

----------------------------------------------------------------------
-- Settings helpers
----------------------------------------------------------------------

function PK:GetSetting(key)
    return self.db and self.db.settings and self.db.settings[key]
end

function PK:SetSetting(key, value)
    if self.db and self.db.settings then
        self.db.settings[key] = value
    end
end

----------------------------------------------------------------------
-- Character data operations
----------------------------------------------------------------------

--- Returns true if a profession entry has no meaningful data (0/0 skill, no knowledge, no tabs).
function PK:IsEmptyProfession(profData)
    if not profData then return true end
    local level = profData.skillLevel or 0
    local maxLevel = profData.maxSkillLevel or 0
    local spent = profData.totalKnowledgeSpent or 0
    local unspent = profData.unspentKnowledge or 0
    local hasTabs = profData.tabs and next(profData.tabs)
    return level == 0 and maxLevel == 0 and spent == 0 and unspent == 0 and not hasTabs
end

function PK:SaveCharacterData(profData, prof1BaseID, prof2BaseID)
    if not self.db or not self.charKey then return end

    self.db.characters[self.charKey] = {
        className   = self.playerClass,
        classID     = self.playerClassID,
        level       = self.playerLevel,
        lastScanned = time(),
        prof1BaseID = prof1BaseID,
        prof2BaseID = prof2BaseID,
        professions = profData,
    }

    PK:Debug("Saved data for " .. self.charKey)
end

function PK:GetCharacterData(charKey)
    if not self.db or not self.db.characters then return nil end
    return self.db.characters[charKey]
end

--- Look up character data from local characters first, then guild roster.
--- Returns the data table (or nil) so callers don't need to know the source.
function PK:FindCharacterData(charKey)
    -- Try local characters first
    local data = self:GetCharacterData(charKey)
    if data then return data end
    -- Fall back to guild roster
    local roster = self:GetGuildRoster()
    if roster and roster[charKey] then
        return roster[charKey]
    end
    return nil
end

function PK:GetCurrentCharacterData()
    return self:GetCharacterData(self.charKey)
end

----------------------------------------------------------------------
-- Cross-character queries
----------------------------------------------------------------------

--- Get all characters that have a specific profession.
--- If filterVariantID is given, only returns characters whose stored
--- variantID matches (same expansion, e.g. Midnight vs TWW).
--- Returns: { { charKey, className, classID, level, profData }, ... }
function PK:GetAllCharactersForProfession(skillLineID, filterVariantID)
    local results = {}
    if not self.db or not self.db.characters then return results end

    for charKey, charData in pairs(self.db.characters) do
        if charData.professions and charData.professions[skillLineID] then
            local profData = charData.professions[skillLineID]
            -- Filter by expansion variant when requested.
            -- If the stored data has no variantID (legacy / imported), treat as wildcard match.
            local variantMatch = (not filterVariantID)
                or (not profData.variantID)
                or (profData.variantID == filterVariantID)
                or (profData.skillLineID and profData.skillLineID == filterVariantID)
            if variantMatch then
                table.insert(results, {
                    charKey   = charKey,
                    className = charData.className,
                    classID   = charData.classID,
                    level     = charData.level,
                    profData  = profData,
                })
            end
        end
    end

    -- Sort: current character first, then alphabetically
    local currentKey = self.charKey
    table.sort(results, function(a, b)
        if a.charKey == currentKey then return true end
        if b.charKey == currentKey then return false end
        return a.charKey < b.charKey
    end)

    return results
end

--- Get all characters and their professions (for summary window).
--- Automatically excludes professions from old expansions (PK.ExcludedExpansions).
--- filterProfession: if given (a skillLineID), only that profession is included.
--- Returns: { { charKey, className, classID, level, professions = { [skillLineID] = profData, ... } }, ... }
function PK:GetAllCharacters(filterProfession)
    local results = {}
    if not self.db or not self.db.characters then return results end

    for charKey, charData in pairs(self.db.characters) do
        local profs = charData.professions or {}

        -- Always filter out old-expansion professions, empties, and apply profession filter
        local filtered = {}
        for skillLineID, profData in pairs(profs) do
            local keep = true
            -- Exclude professions from old expansions (e.g. Dragon Isles)
            if profData.expansionName and PK.ExcludedExpansions[profData.expansionName] then
                keep = false
            end
            -- Exclude empty placeholder professions (0/0, no knowledge, no tabs)
            if self:IsEmptyProfession(profData) then
                keep = false
            end
            -- Profession filter
            if filterProfession and skillLineID ~= filterProfession then
                keep = false
            end
            if keep then
                filtered[skillLineID] = profData
            end
        end
        profs = filtered

        -- Only include character if they have at least one profession after filtering
        if next(profs) then
            table.insert(results, {
                charKey     = charKey,
                className   = charData.className,
                classID     = charData.classID,
                level       = charData.level,
                lastScanned = charData.lastScanned,
                prof1BaseID = charData.prof1BaseID,
                prof2BaseID = charData.prof2BaseID,
                professions = profs,
            })
        end
    end

    -- Sort: current character first, then alphabetically
    local currentKey = self.charKey
    table.sort(results, function(a, b)
        if a.charKey == currentKey then return true end
        if b.charKey == currentKey then return false end
        return a.charKey < b.charKey
    end)

    return results
end

--- Get a summary of all professions across all characters
--- Returns: { [skillLineID] = { totalChars, totalSpent, totalUnspent }, ... }
function PK:GetProfessionSummary()
    local summary = {}
    if not self.db or not self.db.characters then return summary end

    for _, charData in pairs(self.db.characters) do
        if charData.professions then
            for skillLineID, profData in pairs(charData.professions) do
                if not summary[skillLineID] then
                    summary[skillLineID] = {
                        totalChars   = 0,
                        totalSpent   = 0,
                        totalUnspent = 0,
                    }
                end
                summary[skillLineID].totalChars = summary[skillLineID].totalChars + 1
                summary[skillLineID].totalSpent = summary[skillLineID].totalSpent
                    + (profData.totalKnowledgeSpent or 0)
                summary[skillLineID].totalUnspent = summary[skillLineID].totalUnspent
                    + (profData.unspentKnowledge or 0)
            end
        end
    end

    return summary
end

----------------------------------------------------------------------
-- Delete a character's data
----------------------------------------------------------------------

function PK:DeleteCharacter(charKey)
    if not self.db or not self.db.characters then return false end
    if not self.db.characters[charKey] then
        PK:Print("No data found for: " .. charKey)
        return false
    end

    self.db.characters[charKey] = nil
    PK:Print("Removed data for: " .. charKey)
    return true
end

----------------------------------------------------------------------
-- Get character count
----------------------------------------------------------------------

function PK:GetCharacterCount()
    local count = 0
    if self.db and self.db.characters then
        for _ in pairs(self.db.characters) do
            count = count + 1
        end
    end
    return count
end

----------------------------------------------------------------------
-- Export all character data as a readable string
----------------------------------------------------------------------

function PK:ExportAllData()
    if not self.db or not self.db.characters then
        return "No data to export."
    end

    local lines = {}
    local function add(s) table.insert(lines, s) end

    add("=== ProfKnowledge Export ===")
    add("Exported: " .. date("%Y-%m-%d %H:%M:%S"))
    add("Version: " .. (PK.version or "?"))
    add("")

    local orderMap = {}
    for i, id in ipairs(PK.ProfessionOrder) do
        orderMap[id] = i
    end

    local chars = self:GetAllCharacters()
    if #chars == 0 then
        add("No characters tracked.")
        return table.concat(lines, "\n")
    end

    for _, char in ipairs(chars) do
        local displayName = char.charKey
        local className = char.className or "UNKNOWN"
        local level = char.level or 0

        add("--- " .. displayName .. " ---")
        add("  Class: " .. className .. "  Level: " .. level)

        local charData = self.db.characters[char.charKey]
        local lastScanned = charData and charData.lastScanned
        if lastScanned then
            add("  Last Scanned: " .. date("%Y-%m-%d %H:%M", lastScanned))
        end

        -- Sort professions by display order (skip empties)
        local profKeys = {}
        for skillLineID, profData in pairs(char.professions) do
            if not self:IsEmptyProfession(profData) then
                table.insert(profKeys, skillLineID)
            end
        end
        table.sort(profKeys, function(a, b)
            return (orderMap[a] or 999) < (orderMap[b] or 999)
        end)

        if #profKeys == 0 then
            add("  (no professions)")
        end

        for _, skillLineID in ipairs(profKeys) do
            local profData = char.professions[skillLineID]
            local profInfo = PK.ProfessionData[skillLineID]
            local profName = (profInfo and profInfo.name) or profData.name or tostring(skillLineID)

            local skillStr = ""
            if profData.skillLevel and profData.maxSkillLevel then
                skillStr = "  [" .. profData.skillLevel .. "/" .. profData.maxSkillLevel .. "]"
            end

            if profData.hasSpec == false then
                add("  " .. profName .. skillStr)
            else
                local spent = profData.totalKnowledgeSpent or 0
                local unspent = profData.unspentKnowledge or 0
                add("  " .. profName .. skillStr ..
                    "  Knowledge: " .. spent .. " spent, " .. unspent .. " unspent")

                -- Tabs
                if profData.tabs and next(profData.tabs) then
                    -- Sort tabs by name
                    local sortedTabs = {}
                    for tabID, tabData in pairs(profData.tabs) do
                        table.insert(sortedTabs, { id = tabID, data = tabData })
                    end
                    table.sort(sortedTabs, function(a, b)
                        return (a.data.name or "") < (b.data.name or "")
                    end)

                    for _, tabEntry in ipairs(sortedTabs) do
                        local tabData = tabEntry.data
                        local tabName = tabData.name or ("Tab " .. tabEntry.id)
                        local tSpent = tabData.pointsSpent or 0
                        local tMax = tabData.maxPoints or 0
                        add("    [" .. tabName .. "]  " .. tSpent .. "/" .. tMax)

                        -- Nodes (only invested ones for export brevity)
                        if tabData.nodes then
                            for _, node in ipairs(tabData.nodes) do
                                if node.currentRank and node.currentRank > 0 then
                                    local status = ""
                                    if node.currentRank >= node.maxRanks then
                                        status = " (MAX)"
                                    end
                                    add("      " .. (node.name or "?") ..
                                        "  " .. node.currentRank .. "/" .. node.maxRanks .. status)
                                end
                            end
                        end
                    end
                else
                    add("    (no tree data — open profession in-game to scan)")
                end
            end
        end

        add("")
    end

    -- Guild roster data
    local guildChars = self:GetAllGuildCharacters()
    local localKeys = {}
    for _, c in ipairs(chars) do localKeys[c.charKey] = true end

    local guildEntries = {}
    for _, gc in ipairs(guildChars) do
        if not localKeys[gc.charKey] and not gc.isLocal then
            table.insert(guildEntries, gc)
        end
    end

    if #guildEntries > 0 then
        add("=== Guild Members (" .. #guildEntries .. ") ===")
        add("")

        for _, gc in ipairs(guildEntries) do
            local displayName = gc.charKey
            local className = gc.className or "UNKNOWN"
            local level = gc.level or 0

            add("--- " .. displayName .. " (Guild) ---")
            add("  Class: " .. className .. "  Level: " .. level)

            local profKeys = {}
            for skillLineID, profData in pairs(gc.professions or {}) do
                if not self:IsEmptyProfession(profData) then
                    table.insert(profKeys, skillLineID)
                end
            end
            table.sort(profKeys, function(a, b)
                return (orderMap[a] or 999) < (orderMap[b] or 999)
            end)

            if #profKeys == 0 then
                add("  (no professions)")
            end

            for _, skillLineID in ipairs(profKeys) do
                local profData = gc.professions[skillLineID]
                local profInfo = PK.ProfessionData[skillLineID]
                local profName = (profInfo and profInfo.name) or profData.name or tostring(skillLineID)

                local skillStr = ""
                if profData.skillLevel and profData.maxSkillLevel then
                    skillStr = "  [" .. profData.skillLevel .. "/" .. profData.maxSkillLevel .. "]"
                end

                if profData.hasSpec == false then
                    add("  " .. profName .. skillStr)
                else
                    local spent = profData.totalKnowledgeSpent or 0
                    local unspent = profData.unspentKnowledge or 0
                    add("  " .. profName .. skillStr ..
                        "  Knowledge: " .. spent .. " spent, " .. unspent .. " unspent")

                    if profData.tabs and next(profData.tabs) then
                        local sortedTabs = {}
                        for tabID, tabData in pairs(profData.tabs) do
                            table.insert(sortedTabs, { id = tabID, data = tabData })
                        end
                        table.sort(sortedTabs, function(a, b)
                            return (a.data.name or "") < (b.data.name or "")
                        end)

                        for _, tabEntry in ipairs(sortedTabs) do
                            local tabData = tabEntry.data
                            local tabName = tabData.name or ("Tab " .. tabEntry.id)
                            local tSpent = tabData.pointsSpent or 0
                            local tMax = tabData.maxPoints or 0
                            add("    [" .. tabName .. "]  " .. tSpent .. "/" .. tMax)

                            if tabData.nodes then
                                for _, node in ipairs(tabData.nodes) do
                                    if node.currentRank and node.currentRank > 0 then
                                        local status = ""
                                        if node.currentRank >= node.maxRanks then
                                            status = " (MAX)"
                                        end
                                        add("      " .. (node.name or "?") ..
                                            "  " .. node.currentRank .. "/" .. node.maxRanks .. status)
                                    end
                                end
                            end
                        end
                    else
                        add("    (no tree data)")
                    end
                end
            end

            add("")
        end
    end

    add("=== End Export ===")
    return table.concat(lines, "\n")
end

----------------------------------------------------------------------
-- Import character data from an export string
-- Overwrites existing characters if they match by charKey
----------------------------------------------------------------------

-- Helper: save a parsed character into the database
local function SaveImportedChar(db, currentChar, importedChars, counts)
    if not currentChar then return end
    if db.characters[currentChar.charKey] then
        counts.overwritten = counts.overwritten + 1
    end
    db.characters[currentChar.charKey] = {
        className   = currentChar.className,
        classID     = currentChar.classID,
        level       = currentChar.level,
        lastScanned = currentChar.lastScanned,
        professions = currentChar.professions,
    }
    counts.total = counts.total + 1
    table.insert(importedChars, currentChar.charKey)
end

-- ClassID lookup for import
local IMPORT_CLASS_IDS = {
    WARRIOR = 1, PALADIN = 2, HUNTER = 3, ROGUE = 4,
    PRIEST = 5, DEATHKNIGHT = 6, SHAMAN = 7, MAGE = 8,
    WARLOCK = 9, MONK = 10, DRUID = 11, DEMONHUNTER = 12,
    EVOKER = 13,
}

function PK:ImportData(text)
    if not text or text == "" then
        return false, "No import text provided."
    end

    if not self.db then
        return false, "Database not initialized."
    end
    if not self.db.characters then
        self.db.characters = {}
    end

    -- Build reverse lookup: profession name → skillLineID
    local profNameToID = {}
    for skillLineID, info in pairs(PK.ProfessionData) do
        profNameToID[info.name:lower()] = skillLineID
    end

    -- Parse the export text line by line
    local importedChars = {}
    local currentChar = nil
    local currentProf = nil
    local currentTab  = nil
    local counts = { total = 0, overwritten = 0 }

    for line in text:gmatch("[^\r\n]+") do
        local matched = false

        -- Character header: --- CharName-RealmName ---
        local charKey = line:match("^%-%-%- (.+) %-%-%-$")
        if charKey then
            -- Save previous character if we have one
            SaveImportedChar(self.db, currentChar, importedChars, counts)

            currentChar = {
                charKey     = strtrim(charKey),
                className   = "UNKNOWN",
                classID     = 0,
                level       = 0,
                lastScanned = nil,
                professions = {},
            }
            currentProf = nil
            currentTab  = nil
            matched = true
        end

        -- Everything below requires a currentChar
        if not matched and currentChar then
            -- Class and Level: "  Class: WARRIOR  Level: 80"
            local className, level = line:match("^  Class:%s+(%S+)%s+Level:%s+(%d+)")
            if className then
                currentChar.className = className
                currentChar.level = tonumber(level) or 0
                currentChar.classID = IMPORT_CLASS_IDS[className:upper()] or 0
                matched = true
            end

            -- Last Scanned: "  Last Scanned: 2026-03-05 14:25"
            if not matched then
                local scanDate = line:match("^  Last Scanned:%s+(.+)")
                if scanDate then
                    -- Store current time since we can't reliably parse
                    -- the date back to a timestamp in WoW Lua
                    currentChar.lastScanned = time()
                    matched = true
                end
            end

            -- Profession with spec + skill level:
            -- "  Alchemy  [100/100]  Knowledge: 40 spent, 5 unspent"
            if not matched then
                local profName, skillLvl, maxSkillLvl, spent, unspent =
                    line:match("^  (%S+)%s+%[(%d+)/(%d+)%]%s+Knowledge:%s+(%d+) spent,%s+(%d+) unspent")
                if profName then
                    local skillLineID = profNameToID[profName:lower()]
                    if skillLineID then
                        currentProf = {
                            id = skillLineID,
                            data = {
                                name = profName,
                                skillLevel = tonumber(skillLvl) or 0,
                                maxSkillLevel = tonumber(maxSkillLvl) or 0,
                                totalKnowledgeSpent = tonumber(spent) or 0,
                                unspentKnowledge = tonumber(unspent) or 0,
                                tabs = {},
                            },
                        }
                        currentChar.professions[skillLineID] = currentProf.data
                        currentTab = nil
                    end
                    matched = true
                end
            end

            -- Profession with spec, no skill level:
            -- "  Alchemy  Knowledge: 40 spent, 5 unspent"
            if not matched then
                local profName2, spent2, unspent2 =
                    line:match("^  (%S+)%s+Knowledge:%s+(%d+) spent,%s+(%d+) unspent")
                if profName2 then
                    local skillLineID = profNameToID[profName2:lower()]
                    if skillLineID then
                        currentProf = {
                            id = skillLineID,
                            data = {
                                name = profName2,
                                totalKnowledgeSpent = tonumber(spent2) or 0,
                                unspentKnowledge = tonumber(unspent2) or 0,
                                tabs = {},
                            },
                        }
                        currentChar.professions[skillLineID] = currentProf.data
                        currentTab = nil
                    end
                    matched = true
                end
            end

            -- Profession without spec (gathering): "  Herbalism  [100/100]"
            if not matched then
                local profName3, skillLvl3, maxSkillLvl3 =
                    line:match("^  (%S+)%s+%[(%d+)/(%d+)%]%s*$")
                if profName3 then
                    local skillLineID = profNameToID[profName3:lower()]
                    if skillLineID then
                        currentProf = {
                            id = skillLineID,
                            data = {
                                name = profName3,
                                skillLevel = tonumber(skillLvl3) or 0,
                                maxSkillLevel = tonumber(maxSkillLvl3) or 0,
                                hasSpec = false,
                            },
                        }
                        currentChar.professions[skillLineID] = currentProf.data
                        currentTab = nil
                    end
                    matched = true
                end
            end

            -- Profession without spec, no skill level: "  Herbalism"
            if not matched then
                local profName4 = line:match("^  (%S+)%s*$")
                if profName4 and profNameToID[profName4:lower()] then
                    local skillLineID = profNameToID[profName4:lower()]
                    currentProf = {
                        id = skillLineID,
                        data = {
                            name = profName4,
                            hasSpec = false,
                        },
                    }
                    currentChar.professions[skillLineID] = currentProf.data
                    currentTab = nil
                    matched = true
                end
            end

            -- Tab header: "    [Potion Mastery]  15/40"
            if not matched and currentProf then
                local tabName, tSpent, tMax = line:match("^    %[(.-)%]%s+(%d+)/(%d+)")
                if tabName then
                    currentTab = {
                        name = tabName,
                        pointsSpent = tonumber(tSpent) or 0,
                        maxPoints = tonumber(tMax) or 0,
                        nodes = {},
                    }
                    -- Use tab name as key since we don't have the real tabTreeID
                    local tabKey = "imported_" .. tabName:gsub("%s+", "_"):lower()
                    currentProf.data.tabs[tabKey] = currentTab
                    matched = true
                end
            end

            -- Node line: "      Potion Expertise  5/10" or with " (MAX)"
            if not matched and currentTab then
                local nodeName, curRank, maxRank = line:match("^      (.-)  (%d+)/(%d+)")
                if nodeName then
                    nodeName = strtrim(nodeName)
                    table.insert(currentTab.nodes, {
                        name = nodeName,
                        currentRank = tonumber(curRank) or 0,
                        maxRanks = tonumber(maxRank) or 0,
                    })
                end
            end
        end
    end

    -- Save the last character
    SaveImportedChar(self.db, currentChar, importedChars, counts)

    if counts.total == 0 then
        return false, "No character data found in the import text. Make sure it's a valid ProfKnowledge export."
    end

    local msg = "Imported " .. counts.total .. " character(s)"
    if counts.overwritten > 0 then
        msg = msg .. " (" .. counts.overwritten .. " overwritten)"
    end
    msg = msg .. ": " .. table.concat(importedChars, ", ")

    return true, msg
end

----------------------------------------------------------------------
-- Guild Roster — synced profession data for guild members
----------------------------------------------------------------------

--- Initialize the guild roster for the current guild.
function PK:InitGuildRoster()
    if not self.db or not self.guildKey then return end
    if not self.db.guildRoster then
        self.db.guildRoster = {}
    end
    if not self.db.guildRoster[self.guildKey] then
        self.db.guildRoster[self.guildKey] = {}
    end

    -- Seed our own data into the guild roster
    self:SeedOwnData()
end

--- Get the guild roster table for the current guild.
function PK:GetGuildRoster()
    if not self.db or not self.guildKey then return nil end
    return self.db.guildRoster and self.db.guildRoster[self.guildKey]
end

--- Seed the current character's data into the guild roster,
--- then seed all other local characters too.
--- Local player data is always authoritative.
function PK:SeedOwnData()
    if not self.db or not self.guildKey or not self.charKey then return end

    local roster = self.db.guildRoster[self.guildKey]
    if not roster then return end

    -- Seed current character
    local charData = self:GetCurrentCharacterData()
    if charData then
        roster[self.charKey] = {
            className   = charData.className,
            classID     = charData.classID,
            level       = charData.level,
            lastScanned = charData.lastScanned,
            lastUpdate  = time(),
            prof1BaseID = charData.prof1BaseID,
            prof2BaseID = charData.prof2BaseID,
            professions = charData.professions,
            isLocal     = true,
        }
    end

    -- Seed all other local characters
    self:SeedAllLocalData()
end

--- Seed ALL local characters' data into the guild roster.
--- This ensures we share our entire roster, not just the current character.
function PK:SeedAllLocalData()
    if not self.db or not self.guildKey or not self.db.characters then return end

    local roster = self.db.guildRoster[self.guildKey]
    if not roster then return end

    for charKey, charData in pairs(self.db.characters) do
        roster[charKey] = {
            className   = charData.className,
            classID     = charData.classID,
            level       = charData.level,
            lastScanned = charData.lastScanned,
            lastUpdate  = charData.lastScanned or time(),
            prof1BaseID = charData.prof1BaseID,
            prof2BaseID = charData.prof2BaseID,
            professions = charData.professions,
            isLocal     = true,
        }
    end
end

--- Merge a guild member's data into the roster.
--- Uses timestamp-domination: newer lastUpdate wins.
--- Own data (isLocal) is never overwritten by incoming data.
--- Returns true if the merge resulted in new/updated data.
function PK:MergeGuildMember(charKey, incomingData)
    if not self.db or not self.guildKey or not charKey or not incomingData then
        return false
    end

    local roster = self.db.guildRoster[self.guildKey]
    if not roster then
        self:InitGuildRoster()
        roster = self.db.guildRoster[self.guildKey]
    end

    local existing = roster[charKey]

    -- Never overwrite our own data with sync data
    if existing and existing.isLocal then
        return false
    end

    -- Also don't overwrite if this is our current character
    if charKey == self.charKey then
        return false
    end

    -- Timestamp domination: only accept newer data
    local incomingTs = incomingData.lastScanned or incomingData.lastUpdate or 0
    if existing then
        local existingTs = existing.lastUpdate or existing.lastScanned or 0
        if incomingTs <= existingTs then
            return false  -- we already have newer or equal data
        end
    end

    -- Merge the data
    roster[charKey] = {
        className   = incomingData.className,
        classID     = incomingData.classID,
        level       = incomingData.level,
        lastScanned = incomingData.lastScanned,
        lastUpdate  = incomingTs,
        prof1BaseID = incomingData.prof1BaseID,
        prof2BaseID = incomingData.prof2BaseID,
        professions = incomingData.professions,
        isLocal     = false,
    }

    return true
end

--- Get all guild members with a specific profession.
--- Returns: { { charKey, className, classID, level, profData, lastUpdate }, ... }
function PK:GetGuildCharactersForProfession(skillLineID)
    local results = {}
    local roster = self:GetGuildRoster()
    if not roster then return results end

    for charKey, entry in pairs(roster) do
        if entry.professions and entry.professions[skillLineID] then
            local profData = entry.professions[skillLineID]
            -- Skip excluded expansions
            if not (profData.expansionName and PK.ExcludedExpansions[profData.expansionName]) then
                table.insert(results, {
                    charKey    = charKey,
                    className  = entry.className,
                    classID    = entry.classID,
                    level      = entry.level,
                    profData   = profData,
                    lastUpdate = entry.lastUpdate,
                    isLocal    = entry.isLocal,
                })
            end
        end
    end

    -- Sort: local chars first, then by name
    local currentKey = self.charKey
    table.sort(results, function(a, b)
        if a.charKey == currentKey then return true end
        if b.charKey == currentKey then return false end
        if a.isLocal and not b.isLocal then return true end
        if not a.isLocal and b.isLocal then return false end
        return a.charKey < b.charKey
    end)

    return results
end

--- Get all guild roster entries (for the summary display).
--- Returns: { { charKey, className, classID, level, professions, lastUpdate, isLocal }, ... }
function PK:GetAllGuildCharacters(filterProfession)
    local results = {}
    local roster = self:GetGuildRoster()
    if not roster then return results end

    for charKey, entry in pairs(roster) do
        local profs = entry.professions or {}

        -- Filter out excluded expansions and apply profession filter
        local filtered = {}
        for skillLineID, profData in pairs(profs) do
            local keep = true
            if profData.expansionName and PK.ExcludedExpansions[profData.expansionName] then
                keep = false
            end
            if filterProfession and skillLineID ~= filterProfession then
                keep = false
            end
            if keep then
                filtered[skillLineID] = profData
            end
        end

        if next(filtered) then
            table.insert(results, {
                charKey     = charKey,
                className   = entry.className,
                classID     = entry.classID,
                level       = entry.level,
                lastScanned = entry.lastScanned,
                lastUpdate  = entry.lastUpdate,
                prof1BaseID = entry.prof1BaseID,
                prof2BaseID = entry.prof2BaseID,
                professions = filtered,
                isLocal     = entry.isLocal,
            })
        end
    end

    -- Sort: local chars first, then alphabetically
    local currentKey = self.charKey
    table.sort(results, function(a, b)
        if a.charKey == currentKey then return true end
        if b.charKey == currentKey then return false end
        if a.isLocal and not b.isLocal then return true end
        if not a.isLocal and b.isLocal then return false end
        return a.charKey < b.charKey
    end)

    return results
end

--- Get count of guild roster entries.
function PK:GetGuildRosterCount()
    local count = 0
    local roster = self:GetGuildRoster()
    if roster then
        for _ in pairs(roster) do
            count = count + 1
        end
    end
    return count
end

--- Prune departed guild members after the grace period.
--- Call this periodically (e.g., on GUILD_ROSTER_UPDATE).
function PK:PruneGuildRoster()
    if not self.db or not self.guildKey then return end
    local roster = self.db.guildRoster[self.guildKey]
    if not roster then return end

    -- Get current guild member names
    local guildMembers = {}
    local numMembers = GetNumGuildMembers()
    for i = 1, numMembers do
        local name = GetGuildRosterInfo(i)
        if name then
            -- Strip realm if same-realm
            local shortName = name:match("^([^%-]+)")
            guildMembers[shortName] = true
            guildMembers[name] = true
        end
    end

    local now = time()
    local GRACE_PERIOD = 30 * 24 * 3600  -- 30 days

    for charKey, entry in pairs(roster) do
        if not entry.isLocal then
            local charName = charKey:match("^([^%-]+)")
            if charName and not guildMembers[charName] and not guildMembers[charKey] then
                -- Member not in guild — check grace period
                if not entry._absentSince then
                    entry._absentSince = now
                    PK:Debug("Guild member departed: " .. charKey)
                elseif (now - entry._absentSince) > GRACE_PERIOD then
                    PK:Debug("Pruning departed member: " .. charKey)
                    roster[charKey] = nil
                end
            else
                -- Member is in guild — clear absent flag
                entry._absentSince = nil
            end
        end
    end
end
