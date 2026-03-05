----------------------------------------------------------------------
-- ProfKnowledge — Storage.lua
-- SavedVariables management, cross-character data access
----------------------------------------------------------------------

local ADDON_NAME, PK = ...

----------------------------------------------------------------------
-- Default database structure
----------------------------------------------------------------------

local DB_VERSION = 1

local DB_DEFAULTS = {
    version = DB_VERSION,
    characters = {},
    discoveredVariants = {},  -- Cache: baseSkillLineID → expansion variant ID
    settings = {
        showOverlay  = true,
        showBadges   = true,
        debug        = true,   -- Enable by default during development; /pk debug to toggle
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

function PK:SaveCharacterData(profData)
    if not self.db or not self.charKey then return end

    self.db.characters[self.charKey] = {
        className   = self.playerClass,
        classID     = self.playerClassID,
        level       = self.playerLevel,
        lastScanned = time(),
        professions = profData,
    }

    PK:Debug("Saved data for " .. self.charKey)
end

function PK:GetCharacterData(charKey)
    if not self.db or not self.db.characters then return nil end
    return self.db.characters[charKey]
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
            -- Filter by expansion variant when requested
            local variantMatch = (not filterVariantID)
                or (profData.variantID and profData.variantID == filterVariantID)
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

--- Get all characters and all their professions (for summary window)
--- Returns: { { charKey, className, classID, level, professions = { [skillLineID] = profData, ... } }, ... }
function PK:GetAllCharacters()
    local results = {}
    if not self.db or not self.db.characters then return results end

    for charKey, charData in pairs(self.db.characters) do
        table.insert(results, {
            charKey     = charKey,
            className   = charData.className,
            classID     = charData.classID,
            level       = charData.level,
            lastScanned = charData.lastScanned,
            professions = charData.professions or {},
        })
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

        -- Sort professions by display order
        local profKeys = {}
        for skillLineID in pairs(char.professions) do
            table.insert(profKeys, skillLineID)
        end
        local orderMap = {}
        for i, id in ipairs(PK.ProfessionOrder) do
            orderMap[id] = i
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
