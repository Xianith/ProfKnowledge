----------------------------------------------------------------------
-- ProfKnowledge — Data.lua
-- Profession metadata: skill line IDs, names, icons, variant IDs
-- Midnight expansion data
----------------------------------------------------------------------

local ADDON_NAME, PK = ...

----------------------------------------------------------------------
-- Class colors (for character display)
----------------------------------------------------------------------

PK.ClassColors = {
    ["WARRIOR"]     = "|cffc79c6e",
    ["PALADIN"]     = "|cfff58cba",
    ["HUNTER"]      = "|cffabd473",
    ["ROGUE"]       = "|cfffff569",
    ["PRIEST"]      = "|cffffffff",
    ["DEATHKNIGHT"] = "|cffc41f3b",
    ["SHAMAN"]      = "|cff0070de",
    ["MAGE"]        = "|cff69ccf0",
    ["WARLOCK"]     = "|cff9482c9",
    ["MONK"]        = "|cff00ff96",
    ["DRUID"]       = "|cffff7d0a",
    ["DEMONHUNTER"] = "|cffa330c9",
    ["EVOKER"]      = "|cff33937f",
}

----------------------------------------------------------------------
-- Profession metadata
-- skillLineID is the base profession ID that GetProfessionInfo returns
-- These are stable across expansions
----------------------------------------------------------------------

PK.ProfessionData = {
    [171]  = { name = "Alchemy",        icon = "Interface\\Icons\\Trade_Alchemy" },
    [164]  = { name = "Blacksmithing",  icon = "Interface\\Icons\\Trade_BlackSmithing" },
    [333]  = { name = "Enchanting",     icon = "Interface\\Icons\\Trade_Engraving" },
    [202]  = { name = "Engineering",    icon = "Interface\\Icons\\Trade_Engineering" },
    [182]  = { name = "Herbalism",      icon = "Interface\\Icons\\Trade_Herbalism" },
    [773]  = { name = "Inscription",    icon = "Interface\\Icons\\INV_Inscription_Tradeskill01" },
    [755]  = { name = "Jewelcrafting",  icon = "Interface\\Icons\\INV_Misc_Gem_01" },
    [165]  = { name = "Leatherworking", icon = "Interface\\Icons\\Trade_LeatherWorking" },
    [186]  = { name = "Mining",         icon = "Interface\\Icons\\Trade_Mining" },
    [393]  = { name = "Skinning",       icon = "Interface\\Icons\\INV_Misc_Pelt_Wolf_01" },
    [197]  = { name = "Tailoring",      icon = "Interface\\Icons\\Trade_Tailoring" },
    [185]  = { name = "Cooking",        icon = "Interface\\Icons\\INV_Misc_Food_15" },
    [356]  = { name = "Fishing",        icon = "Interface\\Icons\\Trade_Fishing" },
    [794]  = { name = "Archaeology",    icon = "Interface\\Icons\\Trade_Archaeology" },
}

----------------------------------------------------------------------
-- Profession variant IDs for Midnight expansion
-- These are the expansion-specific sub-skill-line IDs used by
-- C_ProfSpecs.GetConfigIDForSkillLine()
--
-- NOTE: These IDs are expansion-specific and may need to be updated.
-- If variant IDs are wrong, the addon falls back to dynamic discovery.
-- The addon will still record basic profession info (skill level)
-- even if variant lookup fails.
----------------------------------------------------------------------

PK.ProfessionVariants = {
    -- Midnight profession variant IDs
    -- These will need to be validated/updated in-game
    -- For now we attempt dynamic discovery in Core.lua as primary approach

    -- Crafting professions (have spec trees in Midnight)
    -- [171]  = 2871,  -- Alchemy (Midnight)
    -- [164]  = 2872,  -- Blacksmithing (Midnight)
    -- [333]  = 2874,  -- Enchanting (Midnight)
    -- [202]  = 2875,  -- Engineering (Midnight)
    -- [773]  = 2878,  -- Inscription (Midnight)
    -- [755]  = 2879,  -- Jewelcrafting (Midnight)
    -- [165]  = 2880,  -- Leatherworking (Midnight)
    -- [197]  = 2883,  -- Tailoring (Midnight)

    -- Gathering professions (may have spec trees in Midnight)
    -- [182]  = 2877,  -- Herbalism (Midnight)
    -- [186]  = 2881,  -- Mining (Midnight)
    -- [393]  = 2882,  -- Skinning (Midnight)
}

----------------------------------------------------------------------
-- Professions that have specialization trees
-- (Gathering profs did NOT have spec trees in TWW,
--  but Midnight may change this — we check dynamically)
----------------------------------------------------------------------

PK.CraftingProfessions = {
    [171]  = true,  -- Alchemy
    [164]  = true,  -- Blacksmithing
    [333]  = true,  -- Enchanting
    [202]  = true,  -- Engineering
    [773]  = true,  -- Inscription
    [755]  = true,  -- Jewelcrafting
    [165]  = true,  -- Leatherworking
    [197]  = true,  -- Tailoring
}

----------------------------------------------------------------------
-- Secondary / universal professions (always get fixed columns in UI)
-- Main professions are any profession NOT in this table.
----------------------------------------------------------------------

PK.SecondaryProfessions = {
    [185]  = true,  -- Cooking
    [356]  = true,  -- Fishing
    [794]  = true,  -- Archaeology
}

----------------------------------------------------------------------
-- Expansion display names
-- Maps the expansion prefix extracted from variant profession names
-- (e.g. "Khaz Algar") to user-friendly expansion names.
----------------------------------------------------------------------

PK.ExpansionDisplayNames = {
    ["Khaz Algar"] = "The War Within",
    -- Midnight prefix will be auto-discovered; add mapping here if needed
}

--- Old expansions to exclude from the summary window.
--- Professions tagged with these expansion names are filtered out.
PK.ExcludedExpansions = {
    ["Dragon Isles"] = true,
}

----------------------------------------------------------------------
-- Display order for professions in the summary window
----------------------------------------------------------------------

PK.ProfessionOrder = {
    171,   -- Alchemy
    164,   -- Blacksmithing
    333,   -- Enchanting
    202,   -- Engineering
    773,   -- Inscription
    755,   -- Jewelcrafting
    165,   -- Leatherworking
    197,   -- Tailoring
    185,   -- Cooking
    182,   -- Herbalism
    186,   -- Mining
    393,   -- Skinning
    356,   -- Fishing
    794,   -- Archaeology
}

----------------------------------------------------------------------
-- Short names for column headers
----------------------------------------------------------------------

PK.ProfessionShortNames = {
    [171]  = "Alch",
    [164]  = "BS",
    [333]  = "Ench",
    [202]  = "Eng",
    [773]  = "Insc",
    [755]  = "JC",
    [165]  = "LW",
    [197]  = "Tail",
    [185]  = "Cook",
    [182]  = "Herb",
    [186]  = "Mine",
    [393]  = "Skin",
    [356]  = "Fish",
    [794]  = "Arch",
}
