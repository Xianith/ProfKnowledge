----------------------------------------------------------------------
-- ProfKnowledge — UI.lua
-- Standalone summary window, detail view, profession overlay,
-- slash commands
----------------------------------------------------------------------

local ADDON_NAME, PK = ...

----------------------------------------------------------------------
-- Slash Commands
----------------------------------------------------------------------

SLASH_PROFKNOWLEDGE1 = "/profknowledge"
SLASH_PROFKNOWLEDGE2 = "/pk"

SlashCmdList["PROFKNOWLEDGE"] = function(msg)
    msg = strtrim(msg or "")
    local cmd, rest = msg:match("^(%S+)%s*(.*)")
    cmd = cmd and cmd:lower() or ""

    if cmd == "" then
        PK:ToggleSummaryWindow()

    elseif cmd == "help" then
        PK:PrintHelp()

    elseif cmd == "scan" then
        PK:ScanAllProfessions()
        PK:Print("Professions scanned.")

    elseif cmd == "delete" or cmd == "remove" then
        rest = strtrim(rest)
        if rest == "" then
            PK:Print("Usage: /pk delete <CharName-RealmName>")
            return
        end
        PK:DeleteCharacter(rest)

    elseif cmd == "list" then
        PK:ListCharacters()

    elseif cmd == "export" then
        PK:ShowExportWindow()

    elseif cmd == "import" then
        PK:ShowImportWindow()

    elseif cmd == "debug" then
        local current = PK:GetSetting("debug")
        PK:SetSetting("debug", not current)
        PK:Print("Debug mode: " .. (not current and "|cff00ff00ON|r" or "|cffff0000OFF|r"))

    elseif cmd == "guild" then
        PK:HandleSyncCommand(strtrim(rest))

    elseif cmd == "sync" then
        PK:HandleSyncCommand("request")

    elseif cmd == "guildsync" then
        local current = PK:GetSetting("guildSync")
        PK:SetSetting("guildSync", not current)
        PK:Print("Guild sync: " .. (not current and "|cff00ff00ON|r" or "|cffff0000OFF|r"))
        if not current and not PK.commReady then
            PK:RegisterSyncHandlers()
            if PK:InitComm() then
                PK:StartSync()
            end
        end

    else
        PK:Print("Unknown command: " .. cmd .. ". Type |cff00ccff/pk help|r for a list.")
    end
end

----------------------------------------------------------------------
-- Help
----------------------------------------------------------------------

function PK:PrintHelp()
    local lines = {
        "|cff00ccffProfKnowledge|r v" .. self.version .. " — Commands:",
        "  |cff00ccff/pk|r — Toggle the knowledge summary window",
        "  |cff00ccff/pk help|r — Show this help",
        "  |cff00ccff/pk scan|r — Force re-scan current character's professions",
        "  |cff00ccff/pk list|r — List all tracked characters",
        "  |cff00ccff/pk export|r — Export all character data to a copyable text window",
        "  |cff00ccff/pk import|r — Import character data from an export string",
        "  |cff00ccff/pk delete <name>|r — Remove a character from tracking",
        "  |cff00ccff/pk debug|r — Toggle debug messages",
        "  |cff00ccff/pk guild|r — Show guild sync status",
        "  |cff00ccff/pk sync|r — Force a guild sync request",
        "  |cff00ccff/pk guildsync|r — Toggle guild sync on/off",
    }
    for _, line in ipairs(lines) do
        DEFAULT_CHAT_FRAME:AddMessage(line)
    end
end

----------------------------------------------------------------------
-- List characters (chat output)
----------------------------------------------------------------------

function PK:ListCharacters()
    local chars = self:GetAllCharacters()
    if #chars == 0 then
        PK:Print("No characters tracked yet. Log in and open a profession to start scanning.")
        return
    end

    PK:Print("Tracked characters:")
    for i, char in ipairs(chars) do
        local classColor = PK.ClassColors[char.className] or "|cffffffff"
        local profNames = {}
        for skillLineID, profData in pairs(char.professions) do
            local info = PK.ProfessionData[skillLineID]
            local name = info and info.name or profData.name or tostring(skillLineID)
            local spent = profData.totalKnowledgeSpent or 0
            local unspent = profData.unspentKnowledge or 0
            if profData.hasSpec ~= false then
                table.insert(profNames, string.format("%s(%d/%d)", name, spent, spent + unspent))
            else
                table.insert(profNames, name)
            end
        end
        local profStr = #profNames > 0 and table.concat(profNames, ", ") or "(no professions)"
        PK:Print(string.format("  %d. %s%s|r — %s", i, classColor, char.charKey, profStr))
    end
end

----------------------------------------------------------------------
-- Summary Window
----------------------------------------------------------------------

local summaryFrame = nil
local detailFrame  = nil

function PK:ToggleSummaryWindow()
    if summaryFrame and summaryFrame:IsShown() then
        summaryFrame:Hide()
    else
        self:ShowSummaryWindow()
    end
end

function PK:ShowSummaryWindow()
    if not summaryFrame then
        summaryFrame = self:CreateSummaryWindow()
    end
    self:RefreshSummaryWindow()
    summaryFrame:Show()
end

function PK:CreateSummaryWindow()
    -- ── Portrait-style frame (like ProfessionsBookFrame) ──
    local frame = CreateFrame("Frame", "ProfKnowledgeSummaryFrame", UIParent, "ButtonFrameTemplate")
    frame:SetSize(660, 450)
    frame:SetPoint("CENTER")
    frame:EnableMouse(true)
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)

    -- Portrait: blacksmith icon
    if frame.PortraitContainer and frame.PortraitContainer.portrait then
        frame.PortraitContainer.portrait:SetTexture("Interface\\Icons\\ui_profession_blacksmithing")
    elseif frame.portrait then
        SetPortraitToTexture(frame.portrait, "Interface\\Icons\\ui_profession_blacksmithing")
    end

    -- Title (provided by ButtonFrameTemplate)
    frame:SetTitle("|cff00ccffProf|r|cffffffffKnowledge|r")

    -- Hide the bottom button bar (we use our own sync bar)
    ButtonFrameTemplate_HideButtonBar(frame)

    -- ── Profession filter dropdown (in the title bar area) ──
    frame.selectedProfession = nil   -- nil = "All Professions"

    local profLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    profLabel:SetPoint("LEFT", frame, "TOPLEFT", 64, -38)
    profLabel:SetTextColor(0.7, 0.7, 0.7)
    profLabel:SetText("Filter:")

    local profDropdown = CreateFrame("Frame", nil, frame, "UIDropDownMenuTemplate")
    profDropdown:SetPoint("LEFT", profLabel, "RIGHT", -12, -2)
    profDropdown:SetFrameStrata("DIALOG")
    profDropdown:SetFrameLevel(frame:GetFrameLevel() + 10)
    UIDropDownMenu_SetWidth(profDropdown, 120)
    frame.professionDropdown = profDropdown

    UIDropDownMenu_Initialize(profDropdown, function(self, level, menuList)
        local info = UIDropDownMenu_CreateInfo()
        -- "All Professions" entry
        info.text = "All Professions"
        info.func = function()
            frame.selectedProfession = nil
            UIDropDownMenu_SetText(profDropdown, "All Professions")
            PK:RefreshSummaryWindow()
        end
        info.checked = (frame.selectedProfession == nil)
        UIDropDownMenu_AddButton(info, level)

        -- List all 13 professions in display order
        for _, skillLineID in ipairs(PK.ProfessionOrder) do
            local profInfo = PK.ProfessionData[skillLineID]
            if profInfo then
                info = UIDropDownMenu_CreateInfo()
                info.text = profInfo.name
                info.func = function()
                    frame.selectedProfession = skillLineID
                    UIDropDownMenu_SetText(profDropdown, profInfo.name)
                    PK:RefreshSummaryWindow()
                end
                info.checked = (frame.selectedProfession == skillLineID)
                UIDropDownMenu_AddButton(info, level)
            end
        end
    end)
    UIDropDownMenu_SetText(profDropdown, "All Professions")

    -- Adjust the Inset: top below title bar, bottom leaves room for sync bar
    frame.Inset:ClearAllPoints()
    frame.Inset:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -60)
    frame.Inset:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -6, 30)

    -- -- Book/parchment background texture inside the Inset
    -- local bookBg = frame.Inset:CreateTexture(nil, "BACKGROUND", nil, 1)
    -- bookBg:SetAllPoints()
    -- bookBg:SetTexture("Interface\\QuestFrame\\QuestBG")
    -- bookBg:SetTexCoord(0, 1, 0.02, 1)
    -- frame.bookBg = bookBg

    -- Subtitle (character count) — inside the Inset
    local subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    subtitle:SetPoint("TOPLEFT", frame.Inset, "TOPLEFT", 8, -4)
    subtitle:SetTextColor(0.6, 0.6, 0.6)
    frame.subtitle = subtitle

    -- Hint text
    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("LEFT", subtitle, "RIGHT", 10, 0)
    hint:SetTextColor(0.45, 0.45, 0.45)
    hint:SetText("Click a cell for details")
    frame.hint = hint

    -- ESC to close (standard WoW mechanism)
    tinsert(UISpecialFrames, "ProfKnowledgeSummaryFrame")

    -- Column headers area (inside the Inset)
    local headerFrame = CreateFrame("Frame", nil, frame.Inset)
    headerFrame:SetPoint("TOPLEFT", frame.Inset, "TOPLEFT", 4, -18)
    headerFrame:SetPoint("TOPRIGHT", frame.Inset, "TOPRIGHT", -4, -18)
    headerFrame:SetHeight(24)
    frame.headerFrame = headerFrame

    -- Scroll frame for grid rows (inside the Inset)
    local scrollFrame = CreateFrame("ScrollFrame", nil, frame.Inset, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", frame.Inset, "TOPLEFT", 4, -42)
    scrollFrame:SetPoint("BOTTOMRIGHT", frame.Inset, "BOTTOMRIGHT", -24, 4)
    frame.scrollFrame = scrollFrame

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(1, 1)
    scrollFrame:SetScrollChild(scrollChild)
    frame.scrollChild = scrollChild

    -- ── Sync status bar with inline Import/Export (very bottom) ──
    local syncBar = CreateFrame("Button", nil, frame)
    syncBar:SetHeight(22)
    syncBar:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 8, 6)
    syncBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -8, 6)
    frame.syncBar = syncBar

    -- (no colored background — blends with the frame)

    -- Import / Export buttons (right side of sync bar)
    local exportBtn = CreateFrame("Button", nil, syncBar, "UIPanelButtonTemplate")
    exportBtn:SetSize(60, 20)
    exportBtn:SetPoint("RIGHT", syncBar, "RIGHT", -2, 0)
    exportBtn:SetText("Export")
    exportBtn:SetScript("OnClick", function()
        PK:ShowExportWindow()
    end)

    local importBtn = CreateFrame("Button", nil, syncBar, "UIPanelButtonTemplate")
    importBtn:SetSize(60, 20)
    importBtn:SetPoint("RIGHT", exportBtn, "LEFT", -4, 0)
    importBtn:SetText("Import")
    importBtn:SetScript("OnClick", function()
        PK:ShowImportWindow()
    end)

    -- Sync icon (left side)
    local syncIcon = syncBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    syncIcon:SetPoint("LEFT", 6, 0)
    frame.syncIcon = syncIcon

    -- Sync text (between icon and import button)
    local syncText = syncBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    syncText:SetPoint("LEFT", syncIcon, "RIGHT", 4, 0)
    syncText:SetPoint("RIGHT", importBtn, "LEFT", -8, 0)
    syncText:SetJustifyH("LEFT")
    frame.syncText = syncText

    -- Click to force sync
    syncBar:SetScript("OnClick", function()
        if PK.commReady then
            PK.syncPending = false
            PK:RequestSync()
            PK:Print("Sync requested.")
            PK:RefreshSyncStatus()
        else
            PK:Print("Guild sync is not active.")
        end
    end)

    syncBar:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("|cff00ccffGuild Sync|r")
        if PK.commReady then
            GameTooltip:AddLine("Click to force sync with guild", 1, 1, 1, true)
            local count = PK.GetAddonUserCount and PK:GetAddonUserCount() or 0
            if count > 0 then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Online addon users:", 0.7, 0.7, 0.7)
                local sorted = {}
                for name in pairs(PK.addonUsers or {}) do
                    table.insert(sorted, name)
                end
                table.sort(sorted)
                for i, name in ipairs(sorted) do
                    local role = ""
                    if i == 1 then role = " |cffffd700(DR)|r" end
                    if i == 2 then role = " |cffaaaaaa(BDR)|r" end
                    local isMe = (name == UnitName("player"))
                    local color = isMe and "|cff00ff00" or "|cffffffff"
                    GameTooltip:AddLine("  " .. color .. name .. "|r" .. role)
                end
            end
            local rosterCount = PK.GetGuildRosterCount and PK:GetGuildRosterCount() or 0
            if rosterCount > 0 then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Guild roster: " .. rosterCount .. " characters tracked", 0.5, 0.5, 0.5)
            end
        else
            GameTooltip:AddLine("Not connected — sync is disabled", 1, 0.3, 0.3, true)
        end
        GameTooltip:Show()
    end)
    syncBar:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    frame:Hide()
    return frame
end

----------------------------------------------------------------------
-- Refresh the sync status bar in the summary window
----------------------------------------------------------------------

function PK:RefreshSyncStatus()
    if not summaryFrame then return end

    local syncIcon = summaryFrame.syncIcon
    local syncText = summaryFrame.syncText

    if not syncIcon or not syncText then return end

    if PK.commReady then
        local count = PK.GetAddonUserCount and PK:GetAddonUserCount() or 0
        local rosterCount = PK.GetGuildRosterCount and PK:GetGuildRosterCount() or 0
        local role = PK.syncRole or "—"

        if count > 0 then
            syncIcon:SetText("|TInterface\\COMMON\\Indicator-Green:0|t")
            local userLabel = count == 1 and "user" or "users"
            syncText:SetText("|cff00ff00" .. count .. "|r addon " .. userLabel .. " online"
                .. "  |cff888888·|r  "
                .. rosterCount .. " guild chars tracked"
                .. "  |cff888888·|r  "
                .. "|cff888888" .. role .. "|r")
        else
            syncIcon:SetText("|TInterface\\COMMON\\Indicator-Yellow:0|t")
            syncText:SetText("Waiting for guild members...")
        end
    else
        local guildSync = PK:GetSetting("guildSync")
        if guildSync then
            syncIcon:SetText("|TInterface\\COMMON\\Indicator-Gray:0|t")
            syncText:SetText("|cff888888Sync initializing...|r")
        else
            syncIcon:SetText("|TInterface\\COMMON\\Indicator-Red:0|t")
            syncText:SetText("|cff888888Guild sync disabled|r |cff555555(/pk guildsync)|r")
        end
    end
end

----------------------------------------------------------------------
-- Refresh the summary grid
----------------------------------------------------------------------

----------------------------------------------------------------------
-- Helper: format a profession cell's knowledge text
----------------------------------------------------------------------
local function FormatProfCell(profData, showShortName)
    if not profData then
        return "|cff333333—|r"
    end

    local prefix = ""
    if showShortName then
        local shortName = PK.ProfessionShortNames[profData.baseSkillLineID or 0]
            or PK.ProfessionShortNames[profData.skillLineID or 0]
        if not shortName then
            -- Try to derive short name from the full name
            local name = profData.name or ""
            shortName = name:sub(1, 4)
        end
        if shortName and shortName ~= "" then
            prefix = "|cffaaaaaa" .. shortName .. "|r "
        end
    end

    if profData.hasSpec == false then
        return prefix .. "|cff888888" .. (profData.skillLevel or 0) .. "|r"
    end

    local spent = profData.totalKnowledgeSpent or 0
    local unspent = profData.unspentKnowledge or 0

    if unspent > 0 then
        return prefix .. string.format("|cff00ff00%d|r/|cffffd700%d|r", spent, spent + unspent)
    elseif spent > 0 then
        return prefix .. "|cffffffff" .. spent .. "|r"
    else
        return prefix .. "|cff5555550|r"
    end
end

----------------------------------------------------------------------
-- Helper: create a clickable cell button in the grid
----------------------------------------------------------------------
local function CreateGridCell(parent, xPos, yOffset, width, height, cellTextStr, charKey, skillLineID, profData)
    local cellBtn = CreateFrame("Button", nil, parent)
    cellBtn:SetPoint("TOPLEFT", xPos, yOffset)
    cellBtn:SetSize(width, height)
    table.insert(parent.children, cellBtn)

    local cellText = cellBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    cellText:SetAllPoints()
    cellText:SetJustifyH("CENTER")
    cellText:SetJustifyV("MIDDLE")
    cellText:SetText(cellTextStr)

    if profData then
        -- Highlight on hover
        local highlight = cellBtn:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        highlight:SetColorTexture(1, 1, 1, 0.1)

        -- Click to show detail
        cellBtn:SetScript("OnClick", function()
            PK:ShowDetailPanel(charKey, skillLineID)
        end)

        -- Tooltip on hover showing tab summary
        cellBtn:SetScript("OnEnter", function(btn)
            PK:ShowCellTooltip(btn, charKey, skillLineID, profData)
        end)
        cellBtn:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
    end

    return cellBtn
end

function PK:RefreshSummaryWindow()
    if not summaryFrame then return end

    local filterProfession = summaryFrame.selectedProfession

    -- Get all characters (old expansions like Dragon Isles are auto-excluded)
    local chars = self:GetAllCharacters()

    -- Apply profession filter: only show characters that have the selected profession
    if filterProfession then
        local filtered = {}
        for _, char in ipairs(chars) do
            if char.professions[filterProfession] then
                table.insert(filtered, char)
            end
        end
        chars = filtered
    end

    local localCount = #chars

    -- Merge guild roster entries (non-local only, to avoid duplicates)
    local guildChars = self:GetAllGuildCharacters(filterProfession)
    local localKeys = {}
    for _, c in ipairs(chars) do localKeys[c.charKey] = true end
    local guildCount = 0
    for _, gc in ipairs(guildChars) do
        if not localKeys[gc.charKey] and not gc.isLocal then
            gc.isGuild = true
            table.insert(chars, gc)
            guildCount = guildCount + 1
        end
    end

    local charCount = #chars

    local subtitleText = localCount .. " local"
    if guildCount > 0 then
        subtitleText = subtitleText .. ", " .. guildCount .. " guild"
    end
    if filterProfession then
        local profInfo = PK.ProfessionData[filterProfession]
        local profName = profInfo and profInfo.name or "?"
        subtitleText = subtitleText .. "  |cff00ccff" .. profName .. "|r"
    end
    summaryFrame.subtitle:SetText(subtitleText)

    -- Sort professions by display order (for fallback prof slot ordering)
    local orderMap = {}
    for i, id in ipairs(PK.ProfessionOrder) do
        orderMap[id] = i
    end

    -- Fixed 4-column layout:
    -- Col 1: Prof 1 (first main profession slot)
    -- Col 2: Prof 2 (second main profession slot)
    -- Col 3: Cooking (185)
    -- Col 4: Fishing (356)
    local NAME_COL_WIDTH   = 130
    local MAIN_COL_WIDTH   = 110   -- wider to fit "Ench 40/45"
    local SEC_COL_WIDTH    = 70
    local DEL_COL_WIDTH    = 22
    local ROW_HEIGHT       = 22

    local COOKING_ID       = 185
    local FISHING_ID       = 356

    local totalWidth = NAME_COL_WIDTH + (2 * MAIN_COL_WIDTH) + (2 * SEC_COL_WIDTH) + DEL_COL_WIDTH
    summaryFrame:SetWidth(math.max(540, totalWidth + 70))

    -- Clear old content
    local headerFrame = summaryFrame.headerFrame
    local scrollChild = summaryFrame.scrollChild

    if headerFrame.children then
        for _, child in ipairs(headerFrame.children) do
            child:Hide()
            child:SetParent(nil)
        end
    end
    headerFrame.children = {}

    if scrollChild.children then
        for _, child in ipairs(scrollChild.children) do
            child:Hide()
            child:SetParent(nil)
        end
    end
    scrollChild.children = {}

    -- Column headers — fixed 4-column layout + delete
    local headers = {
        { text = "Character", width = NAME_COL_WIDTH, justify = "LEFT" },
        { text = "Prof 1",    width = MAIN_COL_WIDTH, justify = "CENTER" },
        { text = "Prof 2",    width = MAIN_COL_WIDTH, justify = "CENTER" },
        { text = "Cook",      width = SEC_COL_WIDTH,  justify = "CENTER" },
        { text = "Fish",      width = SEC_COL_WIDTH,  justify = "CENTER" },
        { text = "",           width = DEL_COL_WIDTH,  justify = "CENTER" },
    }

    local xCursor = 4
    for _, hdr in ipairs(headers) do
        local colHeader = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        colHeader:SetPoint("TOPLEFT", xCursor, 0)
        colHeader:SetWidth(hdr.width)
        colHeader:SetJustifyH(hdr.justify)
        colHeader:SetText(hdr.text)
        table.insert(headerFrame.children, colHeader)
        xCursor = xCursor + hdr.width
    end

    -- Divider line
    local divider = scrollChild:CreateTexture(nil, "ARTWORK")
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", 0, 0)
    divider:SetPoint("TOPRIGHT", 0, 0)
    divider:SetColorTexture(0.4, 0.4, 0.4, 0.5)
    table.insert(scrollChild.children, divider)

    -- Empty state
    if charCount == 0 then
        local emptyText = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        emptyText:SetPoint("TOPLEFT", 4, -12)
        emptyText:SetText("No characters tracked yet.\nLog in and open a profession to start scanning.")
        emptyText:SetTextColor(0.5, 0.5, 0.5)
        table.insert(scrollChild.children, emptyText)
        scrollChild:SetHeight(60)
        return
    end

    local yOffset = -4

    for rowIdx, char in ipairs(chars) do
        local classColor = PK.ClassColors[char.className] or "|cffffffff"
        local isCurrentChar = (char.charKey == self.charKey)
        local isGuild = char.isGuild

        -- Character name
        local nameText = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        nameText:SetPoint("TOPLEFT", 4, yOffset)
        nameText:SetWidth(NAME_COL_WIDTH)
        nameText:SetJustifyH("LEFT")
        local displayName = char.charKey:match("^(.-)%-") or char.charKey
        local nameStr
        if isGuild then
            nameStr = "|cff999999" .. displayName .. "|r |cff666666(G)|r"
        else
            nameStr = classColor .. displayName .. "|r"
            if isCurrentChar then
                nameStr = nameStr .. " |cff888888*|r"
            end
        end
        nameText:SetText(nameStr)
        table.insert(scrollChild.children, nameText)

        -- Determine Prof 1 and Prof 2 using stored slot assignments
        local prof1ID = char.prof1BaseID
        local prof2ID = char.prof2BaseID

        -- Fallback for characters scanned before slot tracking was added:
        -- extract main professions and sort by display order
        if not prof1ID and not prof2ID then
            local mainProfs = {}
            for skillLineID in pairs(char.professions) do
                if not PK.SecondaryProfessions[skillLineID] then
                    table.insert(mainProfs, skillLineID)
                end
            end
            table.sort(mainProfs, function(a, b)
                return (orderMap[a] or 999) < (orderMap[b] or 999)
            end)
            prof1ID = mainProfs[1]
            prof2ID = mainProfs[2]
        end

        local xPos = 4 + NAME_COL_WIDTH

        -- Prof 1
        local prof1Data = prof1ID and char.professions[prof1ID] or nil
        local prof1Text = prof1Data
            and FormatProfCell(prof1Data, true)
            or "|cff333333—|r"
        CreateGridCell(scrollChild, xPos, yOffset, MAIN_COL_WIDTH, ROW_HEIGHT,
            prof1Text, char.charKey, prof1ID or 0, prof1Data)
        xPos = xPos + MAIN_COL_WIDTH

        -- Prof 2
        local prof2Data = prof2ID and char.professions[prof2ID] or nil
        local prof2Text = prof2Data
            and FormatProfCell(prof2Data, true)
            or "|cff333333—|r"
        CreateGridCell(scrollChild, xPos, yOffset, MAIN_COL_WIDTH, ROW_HEIGHT,
            prof2Text, char.charKey, prof2ID or 0, prof2Data)
        xPos = xPos + MAIN_COL_WIDTH

        -- Cooking
        local cookData = char.professions[COOKING_ID]
        CreateGridCell(scrollChild, xPos, yOffset, SEC_COL_WIDTH, ROW_HEIGHT,
            FormatProfCell(cookData, false), char.charKey, COOKING_ID, cookData)
        xPos = xPos + SEC_COL_WIDTH

        -- Fishing
        local fishData = char.professions[FISHING_ID]
        CreateGridCell(scrollChild, xPos, yOffset, SEC_COL_WIDTH, ROW_HEIGHT,
            FormatProfCell(fishData, false), char.charKey, FISHING_ID, fishData)
        xPos = xPos + SEC_COL_WIDTH

        -- Delete (X) button — don't show for current character or guild members
        if not isCurrentChar and not isGuild then
            local delBtn = CreateFrame("Button", nil, scrollChild)
            delBtn:SetPoint("TOPLEFT", xPos, yOffset)
            delBtn:SetSize(DEL_COL_WIDTH, ROW_HEIGHT)
            table.insert(scrollChild.children, delBtn)

            local delText = delBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            delText:SetAllPoints()
            delText:SetJustifyH("CENTER")
            delText:SetJustifyV("MIDDLE")
            delText:SetText("|cff555555\195\151|r")  -- × symbol, dim

            -- Hover highlight
            delBtn:SetScript("OnEnter", function(self)
                delText:SetText("|cffff4444\195\151|r")  -- red on hover
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine("Remove " .. char.charKey)
                GameTooltip:AddLine("Click to delete this character's data", 0.7, 0.7, 0.7, true)
                GameTooltip:Show()
            end)
            delBtn:SetScript("OnLeave", function()
                delText:SetText("|cff555555\195\151|r")  -- back to dim
                GameTooltip:Hide()
            end)

            local capturedCharKey = char.charKey
            delBtn:SetScript("OnClick", function()
                -- Confirm deletion via StaticPopup
                StaticPopupDialogs["PK_DELETE_CHAR"] = {
                    text = "Remove profession data for\n|cffffffff" .. capturedCharKey .. "|r?",
                    button1 = "Delete",
                    button2 = "Cancel",
                    OnAccept = function()
                        PK:DeleteCharacter(capturedCharKey)
                        PK:RefreshSummaryWindow()
                    end,
                    timeout = 0,
                    whileDead = true,
                    hideOnEscape = true,
                    preferredIndex = 3,
                }
                StaticPopup_Show("PK_DELETE_CHAR")
            end)
        end

        yOffset = yOffset - ROW_HEIGHT
    end

    -- Legend
    yOffset = yOffset - 10
    local legend = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    legend:SetPoint("TOPLEFT", 4, yOffset)
    legend:SetTextColor(0.5, 0.5, 0.5)
    -- legend:SetText("|cff00ff00Green|r = spent  |cffffd700Gold|r = total (spent+unspent)  |cff888888*|r = current char  Click cell for details")
    table.insert(scrollChild.children, legend)

    yOffset = yOffset - ROW_HEIGHT
    scrollChild:SetHeight(math.abs(yOffset) + 10)

    -- Refresh the sync status bar
    self:RefreshSyncStatus()
end

----------------------------------------------------------------------
-- Cell tooltip — shows tab-level summary on hover
----------------------------------------------------------------------

function PK:ShowCellTooltip(btn, charKey, skillLineID, profData)
    GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")

    local classColor = "|cffffffff"
    local charData = self:FindCharacterData(charKey)
    if charData then
        classColor = PK.ClassColors[charData.className] or classColor
    end

    local profInfo = PK.ProfessionData[skillLineID]
    local profName = (profInfo and profInfo.name) or (profData and profData.name) or "Profession"

    GameTooltip:AddLine(classColor .. charKey .. "|r — " .. profName)
    GameTooltip:AddLine(" ")

    if profData and profData.tabs then
        local spent = profData.totalKnowledgeSpent or 0
        local unspent = profData.unspentKnowledge or 0
        GameTooltip:AddDoubleLine("Total Spent:", "|cffffffff" .. spent .. "|r", 0.7, 0.7, 0.7)
        if unspent > 0 then
            GameTooltip:AddDoubleLine("Unspent:", "|cff00ff00" .. unspent .. "|r", 0.7, 0.7, 0.7)
        end
        GameTooltip:AddLine(" ")

        -- Tab summary
        local tabCount = 0
        for tabTreeID, tabData in pairs(profData.tabs) do
            tabCount = tabCount + 1
            local tabName = tabData.name or ("Tab " .. tabTreeID)
            local tSpent = tabData.pointsSpent or 0
            local tMax = tabData.maxPoints or 0
            local color = tSpent > 0 and "|cffffffff" or "|cff555555"
            GameTooltip:AddDoubleLine(
                "  " .. tabName,
                color .. tSpent .. "/" .. tMax .. "|r",
                0.8, 0.8, 0.6
            )
        end

        if tabCount == 0 then
            GameTooltip:AddLine("  No specialization data", 0.5, 0.5, 0.5)
        end
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cff888888Click for full tree details|r", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

----------------------------------------------------------------------
-- Detail Panel — shows full knowledge tree for one char + profession
----------------------------------------------------------------------

function PK:ShowDetailPanel(charKey, skillLineID)
    if not detailFrame then
        detailFrame = self:CreateDetailPanel()
    end
    self:RefreshDetailPanel(charKey, skillLineID)
    detailFrame:Show()
end

function PK:CreateDetailPanel()
    local frame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    frame:SetSize(360, 500)
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)

    frame:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true,
        tileSize = 32,
        edgeSize = 32,
        insets   = { left = 8, right = 8, top = 8, bottom = 8 },
    })

    -- Position next to summary window if it's open
    if summaryFrame and summaryFrame:IsShown() then
        frame:SetPoint("TOPLEFT", summaryFrame, "TOPRIGHT", 4, 0)
    else
        frame:SetPoint("CENTER", 200, 0)
    end

    -- Title
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -14)
    frame.title = title

    -- Subtitle (profession name)
    local subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    subtitle:SetPoint("TOP", title, "BOTTOM", 0, -4)
    frame.subtitle = subtitle

    -- Close button
    local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -4, -4)

    -- Scroll frame for tree content
    local scrollFrame = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 14, -56)
    scrollFrame:SetPoint("BOTTOMRIGHT", -34, 14)
    frame.scrollFrame = scrollFrame

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(1, 1)
    scrollFrame:SetScrollChild(scrollChild)
    frame.scrollChild = scrollChild

    -- ESC to close
    frame:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            self:Hide()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)

    frame:Hide()
    return frame
end

function PK:RefreshDetailPanel(charKey, skillLineID)
    if not detailFrame then return end

    local scrollChild = detailFrame.scrollChild

    -- Clear old content
    if scrollChild.children then
        for _, child in ipairs(scrollChild.children) do
            child:Hide()
            child:SetParent(nil)
        end
    end
    scrollChild.children = {}

    -- Get character data (local or guild roster)
    local charData = self:FindCharacterData(charKey)
    if not charData then
        detailFrame.title:SetText("|cffff0000Character Not Found|r")
        detailFrame.subtitle:SetText("")
        return
    end

    local classColor = PK.ClassColors[charData.className] or "|cffffffff"
    local displayName = charKey:match("^(.-)%-") or charKey
    detailFrame.title:SetText(classColor .. displayName .. "|r")

    local profData = charData.professions and charData.professions[skillLineID]
    if not profData then
        detailFrame.subtitle:SetText("|cffff0000No profession data|r")
        return
    end

    local profInfo = PK.ProfessionData[skillLineID]
    local profName = (profInfo and profInfo.name) or profData.name or "Profession"
    local spent = profData.totalKnowledgeSpent or 0
    local unspent = profData.unspentKnowledge or 0

    local subText = profName .. "  |cffffffff" .. spent .. "|r spent"
    if unspent > 0 then
        subText = subText .. "  |cff00ff00+" .. unspent .. " unspent|r"
    end
    detailFrame.subtitle:SetText(subText)

    -- Build tree content
    local yOffset = 0
    local INDENT = 16
    local TAB_ROW_HEIGHT = 22
    local NODE_ROW_HEIGHT = 16

    if not profData.tabs or next(profData.tabs) == nil then
        local noData = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        noData:SetPoint("TOPLEFT", 4, yOffset)
        noData:SetText("No specialization tree data available.\nOpen this profession in-game to scan.")
        noData:SetTextColor(0.5, 0.5, 0.5)
        table.insert(scrollChild.children, noData)
        scrollChild:SetHeight(60)
        return
    end

    -- Sort tabs by name for consistent display
    local sortedTabs = {}
    for tabTreeID, tabData in pairs(profData.tabs) do
        table.insert(sortedTabs, { id = tabTreeID, data = tabData })
    end
    table.sort(sortedTabs, function(a, b)
        return (a.data.name or "") < (b.data.name or "")
    end)

    for _, tabEntry in ipairs(sortedTabs) do
        local tabData = tabEntry.data
        local tabName = tabData.name or ("Tab " .. tabEntry.id)
        local tSpent = tabData.pointsSpent or 0
        local tMax = tabData.maxPoints or 0

        -- Tab header with background bar
        local tabBg = scrollChild:CreateTexture(nil, "BACKGROUND")
        tabBg:SetPoint("TOPLEFT", 0, yOffset)
        tabBg:SetSize(310, TAB_ROW_HEIGHT)
        tabBg:SetColorTexture(0.15, 0.15, 0.2, 0.8)
        table.insert(scrollChild.children, tabBg)

        -- Progress bar behind tab header
        if tMax > 0 and tSpent > 0 then
            local pctWidth = math.min((tSpent / tMax) * 310, 310)
            local progressBar = scrollChild:CreateTexture(nil, "BACKGROUND", nil, 1)
            progressBar:SetPoint("TOPLEFT", 0, yOffset)
            progressBar:SetSize(pctWidth, TAB_ROW_HEIGHT)
            progressBar:SetColorTexture(0.0, 0.35, 0.15, 0.5)
            table.insert(scrollChild.children, progressBar)
        end

        -- Tab name + points
        local tabText = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        tabText:SetPoint("TOPLEFT", 6, yOffset - 3)
        tabText:SetWidth(200)
        tabText:SetJustifyH("LEFT")
        local tabColor = tSpent > 0 and "|cffffd700" or "|cff888888"
        tabText:SetText(tabColor .. tabName .. "|r")
        table.insert(scrollChild.children, tabText)

        local tabPoints = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        tabPoints:SetPoint("TOPRIGHT", 310, yOffset - 3)
        tabPoints:SetJustifyH("RIGHT")
        local ptsColor = tSpent > 0 and "|cffffffff" or "|cff555555"
        tabPoints:SetText(ptsColor .. tSpent .. "/" .. tMax .. "|r")
        table.insert(scrollChild.children, tabPoints)

        yOffset = yOffset - TAB_ROW_HEIGHT - 2

        -- Individual nodes within this tab
        local nodes = tabData.nodes
        if nodes and #nodes > 0 then
            for _, node in ipairs(nodes) do
                local nodeName = node.name or "Unknown"
                local curRank = node.currentRank or 0
                local maxRank = node.maxRanks or 0

                -- Only show invested nodes + a few uninvested ones
                -- (Skip nodes with 0/0 which are likely structural)
                if maxRank > 0 then
                    local nodeText = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                    nodeText:SetPoint("TOPLEFT", INDENT + 4, yOffset)
                    nodeText:SetWidth(220)
                    nodeText:SetJustifyH("LEFT")

                    local nodePoints = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                    nodePoints:SetPoint("TOPRIGHT", 310, yOffset)
                    nodePoints:SetJustifyH("RIGHT")

                    if curRank > 0 then
                        -- Invested — show in white/green
                        if curRank >= maxRank then
                            -- Maxed out
                            nodeText:SetText("|cff00ff00" .. nodeName .. "|r")
                            nodePoints:SetText("|cff00ff00" .. curRank .. "/" .. maxRank .. "|r")
                        else
                            -- Partially invested
                            nodeText:SetText("|cffffffff" .. nodeName .. "|r")
                            nodePoints:SetText("|cffffd700" .. curRank .. "/" .. maxRank .. "|r")
                        end
                    else
                        -- Not invested — dim
                        nodeText:SetText("|cff555555" .. nodeName .. "|r")
                        nodePoints:SetText("|cff3333330/" .. maxRank .. "|r")
                    end

                    table.insert(scrollChild.children, nodeText)
                    table.insert(scrollChild.children, nodePoints)

                    yOffset = yOffset - NODE_ROW_HEIGHT
                end
            end
        else
            local noNodes = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            noNodes:SetPoint("TOPLEFT", INDENT + 4, yOffset)
            noNodes:SetText("|cff555555(no node data — rescan in-game)|r")
            table.insert(scrollChild.children, noNodes)
            yOffset = yOffset - NODE_ROW_HEIGHT
        end

        -- Spacer between tabs
        yOffset = yOffset - 6
    end

    -- Scan timestamp
    yOffset = yOffset - 4
    local scanTime = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    scanTime:SetPoint("TOPLEFT", 4, yOffset)
    scanTime:SetTextColor(0.4, 0.4, 0.4)
    if charData.lastScanned then
        scanTime:SetText("Last scanned: " .. date("%Y-%m-%d %H:%M", charData.lastScanned))
    else
        scanTime:SetText("Last scanned: unknown")
    end
    table.insert(scrollChild.children, scanTime)
    yOffset = yOffset - 20

    scrollChild:SetHeight(math.abs(yOffset) + 10)
end

----------------------------------------------------------------------
-- Profession Overlay (shows alt data on the profession spec tab)
----------------------------------------------------------------------

local overlayFrame = nil

function PK:InitOverlay()
    if overlayFrame then return end

    local profFrame = ProfessionsFrame
    if not profFrame then return end

    local specPage = profFrame.SpecPage
    if not specPage then return end

    -- Parent to SpecPage so the overlay auto-hides when switching tabs
    overlayFrame = CreateFrame("Frame", nil, specPage, "BackdropTemplate")
    overlayFrame:SetSize(300, 200)
    overlayFrame:SetFrameStrata("HIGH")

    -- Profession-UI-matching dark panel with gold-tinted border
    overlayFrame:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile     = true,
        tileSize = 16,
        edgeSize = 16,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    overlayFrame:SetBackdropColor(0.08, 0.08, 0.08, 0.92)
    overlayFrame:SetBackdropBorderColor(0.6, 0.5, 0.15, 0.9)

    -- Position: sidebar anchored to the right edge of the SpecPage
    overlayFrame:SetPoint("TOPLEFT", specPage, "TOPRIGHT", 3, -2)

    -- Make it draggable
    overlayFrame:SetMovable(true)
    overlayFrame:EnableMouse(true)
    overlayFrame:RegisterForDrag("LeftButton")
    overlayFrame:SetScript("OnDragStart", overlayFrame.StartMoving)
    overlayFrame:SetScript("OnDragStop", overlayFrame.StopMovingOrSizing)

    -- Header background strip (dark inset look)
    local headerBg = overlayFrame:CreateTexture(nil, "ARTWORK")
    headerBg:SetPoint("TOPLEFT", 5, -5)
    headerBg:SetPoint("TOPRIGHT", -5, -5)
    headerBg:SetHeight(20)
    headerBg:SetColorTexture(0, 0, 0, 0.4)

    -- Title text (profession-panel style)
    local title = overlayFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -7)
    title:SetText("|cff00ccffAlt Knowledge|r")
    overlayFrame.title = title

    -- Gold divider line under header
    local divider = overlayFrame:CreateTexture(nil, "ARTWORK")
    divider:SetPoint("TOPLEFT", 6, -27)
    divider:SetPoint("TOPRIGHT", -6, -27)
    divider:SetHeight(1)
    divider:SetColorTexture(0.6, 0.5, 0.2, 0.5)

    -- Scroll area for content (in case of many alts)
    local scrollFrame = CreateFrame("ScrollFrame", nil, overlayFrame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 8, -30)
    scrollFrame:SetPoint("BOTTOMRIGHT", -28, 8)
    overlayFrame.scrollFrame = scrollFrame

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(1, 1)
    scrollFrame:SetScrollChild(scrollChild)
    overlayFrame.scrollChild = scrollChild
    overlayFrame.contentChildren = {}

    -- Hook SpecPage show to refresh overlay content
    specPage:HookScript("OnShow", function()
        C_Timer.After(0.5, function()
            PK:RefreshOverlay()
        end)
    end)

    PK:Debug("Overlay created and hooked to SpecPage")
end

function PK:RefreshOverlay()
    if not overlayFrame then return end

    local scrollChild = overlayFrame.scrollChild

    -- Clean up old content
    for _, child in ipairs(overlayFrame.contentChildren) do
        child:Hide()
        child:SetParent(nil)
    end
    overlayFrame.contentChildren = {}

    -- Only show on the Specializations tab
    local profFrame = ProfessionsFrame
    local specPage = profFrame and profFrame.SpecPage
    if not profFrame or not profFrame:IsShown() or not specPage or not specPage:IsShown() then
        overlayFrame:Hide()
        return
    end

    -- Determine the current profession's BASE skillLineID and expansion variant ID.
    -- Our data is keyed by base ID, but we filter by variant so only alts
    -- with the same expansion specializations are shown.
    local skillLineID = nil
    local currentVariantID = nil
    local profName = nil

    if profFrame.professionInfo then
        -- parentProfessionID is the base ID (e.g., 171 for Alchemy)
        skillLineID = profFrame.professionInfo.parentProfessionID
            or profFrame.professionInfo.professionID
            or profFrame.professionInfo.skillLineID
        -- professionID is the expansion-specific variant (e.g., Midnight Alchemy)
        currentVariantID = profFrame.professionInfo.professionID
        profName = profFrame.professionInfo.parentProfessionName
            or profFrame.professionInfo.professionName
    end

    if not skillLineID then
        local ok, info = pcall(function()
            return C_TradeSkillUI and C_TradeSkillUI.GetBaseProfessionInfo
                and C_TradeSkillUI.GetBaseProfessionInfo()
        end)
        if ok and info then
            skillLineID = info.professionID or info.skillLineID
            profName = info.professionName
        end
    end

    -- Also try to get the variant via child profession info
    if not currentVariantID then
        pcall(function()
            local childInfo = C_TradeSkillUI.GetChildProfessionInfo()
            if childInfo then
                currentVariantID = childInfo.professionID
            end
        end)
    end

    if not skillLineID then
        overlayFrame:Hide()
        return
    end

    -- Try to find characters with this profession, filtered to the current expansion
    local chars = self:GetAllCharactersForProfession(skillLineID, currentVariantID)

    -- If no results, the frame may have given us a variant ID instead of a base ID.
    -- Try looking up the base ID from our variant cache.
    if #chars == 0 and self.db and self.db.discoveredVariants then
        for baseID, variantID in pairs(self.db.discoveredVariants) do
            if variantID == skillLineID then
                chars = self:GetAllCharactersForProfession(baseID, currentVariantID)
                if #chars > 0 then
                    skillLineID = baseID
                    break
                end
            end
        end
    end

    -- Merge guild roster characters (non-local, deduplicated)
    local guildChars = self:GetGuildCharactersForProfession(skillLineID)
    local seen = {}
    for _, c in ipairs(chars) do seen[c.charKey] = true end
    for _, gc in ipairs(guildChars) do
        if not seen[gc.charKey] and not gc.isLocal then
            table.insert(chars, gc)
            seen[gc.charKey] = true
        end
    end

    -- Also try guild roster with the variant ID as key (in case professions
    -- were stored keyed by variant rather than base ID)
    if currentVariantID and currentVariantID ~= skillLineID then
        local guildVarChars = self:GetGuildCharactersForProfession(currentVariantID)
        for _, gc in ipairs(guildVarChars) do
            if not seen[gc.charKey] and not gc.isLocal then
                table.insert(chars, gc)
                seen[gc.charKey] = true
            end
        end
    end

    PK:Debug("RefreshOverlay: " .. #chars .. " chars for skillLine=" .. tostring(skillLineID)
        .. " variant=" .. tostring(currentVariantID))

    -- Filter out characters with 0 points spent (skip current char from filter)
    local filtered = {}
    for _, entry in ipairs(chars) do
        local spent = entry.profData.totalKnowledgeSpent or 0
        local unspent = entry.profData.unspentKnowledge or 0
        if spent > 0 or unspent > 0 then
            table.insert(filtered, entry)
        end
    end
    chars = filtered

    if #chars == 0 then
        overlayFrame:Hide()
        return
    end

    -- Update title
    local displayName = profName
        or (PK.ProfessionData[skillLineID] and PK.ProfessionData[skillLineID].name)
        or "Profession"
    overlayFrame.title:SetText("|cff00ccffAlt Knowledge:|r " .. displayName)

    local yOffset = 0
    local ROW_HEIGHT = 16
    local TAB_ROW_HEIGHT = 14
    local currentKey = self.charKey

    for charIdx, entry in ipairs(chars) do
        local classColor = PK.ClassColors[entry.className] or "|cffffffff"
        local isCurrentChar = (entry.charKey == currentKey)
        local displayCharName = entry.charKey:match("^(.-)%-") or entry.charKey

        -- Character header
        local nameText = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        nameText:SetPoint("TOPLEFT", 0, yOffset)
        nameText:SetWidth(140)
        nameText:SetJustifyH("LEFT")
        if isCurrentChar then
            nameText:SetText(classColor .. displayCharName .. "|r |cff666666*|r")
        else
            nameText:SetText(classColor .. displayCharName .. "|r")
        end
        table.insert(overlayFrame.contentChildren, nameText)

        -- Overall spent/unspent on same row
        local spent = entry.profData.totalKnowledgeSpent or 0
        local unspent = entry.profData.unspentKnowledge or 0
        local summaryText = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        summaryText:SetPoint("TOPLEFT", 140, yOffset)
        summaryText:SetWidth(120)
        summaryText:SetJustifyH("RIGHT")
        local summaryStr = "|cffffffff" .. spent .. " spent|r"
        if unspent > 0 then
            summaryStr = summaryStr .. "  |cff00ff00+" .. unspent .. "|r"
        end
        summaryText:SetText(summaryStr)
        table.insert(overlayFrame.contentChildren, summaryText)

        yOffset = yOffset - ROW_HEIGHT

        -- Tab breakdown (indented)
        if entry.profData.tabs then
            local sortedTabs = {}
            for tabID, tabData in pairs(entry.profData.tabs) do
                table.insert(sortedTabs, { id = tabID, data = tabData })
            end
            table.sort(sortedTabs, function(a, b)
                return (a.data.name or "") < (b.data.name or "")
            end)

            for _, tabEntry in ipairs(sortedTabs) do
                local tabData = tabEntry.data
                local tSpent = tabData.pointsSpent or 0
                local tMax = tabData.maxPoints or 0

                -- Only show tabs with points spent (to save space)
                if tSpent > 0 then
                    local tabText = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                    tabText:SetPoint("TOPLEFT", 12, yOffset)
                    tabText:SetWidth(160)
                    tabText:SetJustifyH("LEFT")
                    tabText:SetText("|cffaaaaaa" .. (tabData.name or "?") .. "|r")
                    table.insert(overlayFrame.contentChildren, tabText)

                    local tabPts = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                    tabPts:SetPoint("TOPLEFT", 180, yOffset)
                    tabPts:SetWidth(80)
                    tabPts:SetJustifyH("RIGHT")
                    tabPts:SetText("|cffffffff" .. tSpent .. "/" .. tMax .. "|r")
                    table.insert(overlayFrame.contentChildren, tabPts)

                    yOffset = yOffset - TAB_ROW_HEIGHT
                end
            end
        end

        -- Spacer between characters
        if charIdx < #chars then
            yOffset = yOffset - 4
            local sep = scrollChild:CreateTexture(nil, "ARTWORK")
            sep:SetPoint("TOPLEFT", 0, yOffset)
            sep:SetSize(260, 1)
            sep:SetColorTexture(0.3, 0.3, 0.3, 0.3)
            table.insert(overlayFrame.contentChildren, sep)
            yOffset = yOffset - 4
        end
    end

    -- Resize overlay to fit
    local totalHeight = math.abs(yOffset) + 40
    overlayFrame:SetHeight(math.max(math.min(totalHeight, 400), 80))
    scrollChild:SetHeight(math.abs(yOffset) + 10)
    overlayFrame:Show()
end

----------------------------------------------------------------------
-- Spec Tree Node Highlights
-- Green-tint nodes that alts have invested in, and append alt data
-- to each node's tooltip on hover.
----------------------------------------------------------------------

local specTreeHooked      = false
local cachedAltNodeData   = nil   -- { [lowerNodeName] = { {charKey,className,rank,maxRanks}, ... } }
local cachedProfBaseID    = nil
local cachedProfVariantID = nil

--- Build a table of every node that ANY other character has points in
--- for a given base profession, optionally filtered to a specific expansion variant.
function PK:BuildAltNodeLookup(baseSkillLineID, filterVariantID)
    local lookup = {}
    if not self.db then return lookup end

    -- Helper to process one character's data into the lookup
    local seen = {}
    local function processChar(charKey, charData)
        if seen[charKey] then return end
        seen[charKey] = true
        local profData = charData.professions and charData.professions[baseSkillLineID]
        if profData and profData.tabs then
            local variantMatch = (not filterVariantID)
                or (not profData.variantID)
                or (profData.variantID == filterVariantID)
                or (profData.skillLineID and profData.skillLineID == filterVariantID)
            if not variantMatch then
                PK:Debug("BuildAltNodeLookup: skipping " .. charKey
                    .. " variant=" .. tostring(profData.variantID)
                    .. " (want " .. tostring(filterVariantID) .. ")")
            end
            if variantMatch then
                for _, tabData in pairs(profData.tabs) do
                    if tabData.nodes then
                        for _, node in ipairs(tabData.nodes) do
                            if node.name and node.currentRank and node.currentRank > 0 then
                                local key = node.name:lower()
                                if not lookup[key] then
                                    lookup[key] = {}
                                end
                                table.insert(lookup[key], {
                                    charKey   = charKey,
                                    className = charData.className,
                                    rank      = node.currentRank,
                                    maxRanks  = node.maxRanks,
                                })
                            end
                        end
                    end
                end
            end
        end
    end

    -- Scan local characters
    if self.db.characters then
        for charKey, charData in pairs(self.db.characters) do
            processChar(charKey, charData)
        end
    end

    -- Scan guild roster characters
    local roster = self:GetGuildRoster()
    if roster then
        for charKey, entry in pairs(roster) do
            if not entry.isLocal then
                processChar(charKey, entry)
            end
        end
    end

    return lookup
end

--- Determine the base and variant profession IDs from the currently
--- open profession frame / spec page.
function PK:GetSpecPageProfessionIDs()
    local profFrame = ProfessionsFrame
    if not profFrame then return nil, nil end

    local baseID    = nil
    local variantID = nil

    if profFrame.professionInfo then
        baseID    = profFrame.professionInfo.parentProfessionID
                    or profFrame.professionInfo.professionID
        variantID = profFrame.professionInfo.professionID
    end

    -- Fallback via C_TradeSkillUI
    if not variantID then
        pcall(function()
            local info = C_TradeSkillUI.GetChildProfessionInfo()
            if info then
                variantID = info.professionID
                baseID    = info.parentProfessionID or variantID
            end
        end)
    end

    return baseID, variantID
end

--- Collect every visible node button inside the spec page.
local function CollectNodeButtons()
    local specPage = ProfessionsFrame and ProfessionsFrame.SpecPage
    if not specPage then return {} end

    local buttons = {}

    -- Method 1: TalentButtonCollection (used by the talent-tree mixin)
    if specPage.TalentButtonCollection then
        pcall(function()
            for button in specPage.TalentButtonCollection:EnumerateActive() do
                if button.GetNodeID then
                    table.insert(buttons, button)
                end
            end
        end)
    end

    -- Method 2: walk immediate children
    if #buttons == 0 then
        local children = { specPage:GetChildren() }
        for _, child in ipairs(children) do
            if child.GetNodeID then
                table.insert(buttons, child)
            end
        end
    end

    -- Method 3: walk deeper — some frames nest the buttons
    if #buttons == 0 then
        local children = { specPage:GetChildren() }
        for _, child in ipairs(children) do
            if child.GetChildren then
                local grandchildren = { child:GetChildren() }
                for _, gc in ipairs(grandchildren) do
                    if gc.GetNodeID then
                        table.insert(buttons, gc)
                    end
                end
            end
        end
    end

    return buttons
end

--- Apply / refresh green highlights on every node button.
function PK:UpdateSpecTreeHighlights()
    local specPage = ProfessionsFrame and ProfessionsFrame.SpecPage
    if not specPage or not specPage:IsShown() then return end

    local baseID, variantID = self:GetSpecPageProfessionIDs()
    if not baseID or not variantID then
        PK:Debug("Spec highlights: no profession IDs found")
        return
    end

    -- Rebuild the cache when the profession or expansion variant changes
    if baseID ~= cachedProfBaseID or variantID ~= cachedProfVariantID then
        cachedAltNodeData   = self:BuildAltNodeLookup(baseID, variantID)
        cachedProfBaseID    = baseID
        cachedProfVariantID = variantID
        PK:Debug("Spec highlights: rebuilt cache for baseID "
            .. tostring(baseID) .. " variant " .. tostring(variantID))
    end

    -- Obtain the configID for this variant so we can resolve node names
    local configID = nil
    pcall(function()
        configID = C_ProfSpecs.GetConfigIDForSkillLine(variantID)
    end)
    if not configID then
        PK:Debug("Spec highlights: no configID for variant " .. tostring(variantID))
        return
    end

    local buttons = CollectNodeButtons()
    PK:Debug("Spec highlights: processing " .. #buttons .. " node buttons")

    for _, button in ipairs(buttons) do
        local nodeID = button:GetNodeID()
        if nodeID then
            local nodeInfo = nil
            pcall(function()
                nodeInfo = C_Traits.GetNodeInfo(configID, nodeID)
            end)

            if nodeInfo then
                local nodeName = self:ResolveNodeName(configID, nodeInfo)

                if nodeName then
                    local altData = cachedAltNodeData[nodeName:lower()]

                    if altData and #altData > 0 then
                        -- Determine best state across all alts for this node
                        -- and find the current character's rank + highest alt rank
                        local bestState = "green"
                        local highestRank = 0
                        local currentCharRank = 0
                        local currentKey = PK.charKey
                        for _, alt in ipairs(altData) do
                            local dMax = alt.maxRanks or 0
                            local dRank = alt.rank or 0
                            if dMax % 5 ~= 0 then
                                dMax = dMax - 1
                                dRank = math.max(dRank - 1, 0)
                            end
                            if alt.charKey == currentKey then
                                currentCharRank = dRank
                            end
                            if dRank > highestRank then
                                highestRank = dRank
                            end
                            if dRank >= dMax and dMax > 0 then
                                bestState = "purple"
                            elseif dRank > 0 and bestState ~= "purple" then
                                bestState = "blue"
                            end
                        end

                        -- Find Blizzard's green rank FontString (cache on button)
                        if not button.pkBlizzRankText then
                            local found = button.SpendText or button.PointSpendText or button.RankText
                            if not found then
                                for _, region in ipairs({ button:GetRegions() }) do
                                    if region:IsObjectType("FontString") then
                                        local txt = region:GetText()
                                        if txt and txt:match("^%d+$") then
                                            found = region
                                            break
                                        end
                                    end
                                end
                            end
                            button.pkBlizzRankText = found or false
                        end

                        -- Show orange overlay number if current char has top rank
                        if currentCharRank > 0 and currentCharRank >= highestRank then
                            if not button.pkOrangeText then
                                -- Black outline shadows (same technique as blue)
                                local offsets = {
                                    {-1,0}, {1,0}, {0,-1}, {0,1},
                                    {-1,-1}, {1,-1}, {-1,1}, {1,1},
                                }
                                button.pkOrangeShadows = {}
                                local fontPath, fontSize, fontFlags = GameFontNormal:GetFont()
                                for _, off in ipairs(offsets) do
                                    local shadow = button:CreateFontString(nil, "OVERLAY", nil, 7)
                                    shadow:SetFont(fontPath, fontSize + 3, fontFlags)
                                    shadow:SetPoint("BOTTOM", button, "BOTTOM", off[1], -2 + off[2])
                                    shadow:SetTextColor(0, 0, 0, 1)
                                    table.insert(button.pkOrangeShadows, shadow)
                                end
                                local orangeText = button:CreateFontString(nil, "OVERLAY", nil, 7)
                                orangeText:SetFont(fontPath, fontSize + 3, fontFlags)
                                orangeText:SetPoint("BOTTOM", button, "BOTTOM", 0, -2)
                                button.pkOrangeText = orangeText
                            end
                            local label = tostring(currentCharRank)
                            button.pkOrangeText:SetText(label)
                            button.pkOrangeText:SetTextColor(1.0, 0.5, 0.0, 1)
                            button.pkOrangeText:Show()
                            for _, shadow in ipairs(button.pkOrangeShadows) do
                                shadow:SetText(label)
                                shadow:Show()
                            end
                            -- Hide Blizzard's green rank text so orange replaces it cleanly
                            if button.pkBlizzRankText then
                                button.pkBlizzRankText:Hide()
                            end
                        else
                            if button.pkOrangeText then
                                button.pkOrangeText:Hide()
                                for _, shadow in ipairs(button.pkOrangeShadows) do
                                    shadow:Hide()
                                end
                            end
                            -- Restore Blizzard's green rank text
                            if button.pkBlizzRankText then
                                button.pkBlizzRankText:Show()
                            end
                        end

                        -- ── Color circle overlay (all three states) ──
                        local cr, cg, cb, ca
                        if bestState == "purple" then
                            cr, cg, cb, ca = 0.64, 0.21, 0.93, 0.35
                        elseif bestState == "blue" then
                            cr, cg, cb, ca = 0.0, 0.44, 0.87, 0.35
                        else
                            cr, cg, cb, ca = 0.12, 0.75, 0.12, 0.30
                        end
                        if not button.pkHighlight then
                            local glow = button:CreateTexture(nil, "OVERLAY", nil, 7)
                            glow:SetPoint("CENTER", 0, 0)
                            local size = math.min(button:GetWidth(), button:GetHeight()) * 0.95
                            glow:SetSize(size, size)
                            glow:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
                            glow:SetBlendMode("ADD")
                            button.pkHighlight = glow
                        end
                        button.pkHighlight:SetVertexColor(cr, cg, cb, ca)
                        button.pkHighlight:Show()

                        -- ── Blue rank number (only for partial/blue nodes, hidden when orange is showing) ──
                        local showingOrange = currentCharRank > 0 and currentCharRank >= highestRank
                        if bestState == "blue" and not showingOrange then
                            if not button.pkRankText then
                                local offsets = {
                                    {-1,0}, {1,0}, {0,-1}, {0,1},
                                    {-1,-1}, {1,-1}, {-1,1}, {1,1},
                                }
                                button.pkRankShadows = {}
                                for _, off in ipairs(offsets) do
                                    local shadow = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                                    shadow:SetPoint("CENTER", button, "CENTER", off[1], -37 + off[2])
                                    shadow:SetTextColor(0, 0, 0, 1)
                                    table.insert(button.pkRankShadows, shadow)
                                end
                                local rankText = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                                rankText:SetPoint("CENTER", button, "CENTER", 0, -37)
                                button.pkRankText = rankText
                            end
                            local label = tostring(highestRank)
                            button.pkRankText:SetText(label)
                            button.pkRankText:SetTextColor(0.3, 0.6, 1.0, 1)
                            button.pkRankText:Show()
                            for _, shadow in ipairs(button.pkRankShadows) do
                                shadow:SetText(label)
                                shadow:Show()
                            end
                        else
                            if button.pkRankText then
                                button.pkRankText:Hide()
                                for _, shadow in ipairs(button.pkRankShadows) do
                                    shadow:Hide()
                                end
                            end
                        end

                        -- Store lookup data on the button for the tooltip
                        button.pkAltData  = altData
                        button.pkNodeName = nodeName

                        -- Hook the tooltip (once per button)
                        if not button.pkTooltipHooked then
                            button.pkTooltipHooked = true
                            button:HookScript("OnEnter", function(self)
                                if not self.pkAltData then return end
                                if not GameTooltip:IsShown() then return end

                                GameTooltip:AddLine(" ")
                                GameTooltip:AddLine("|cff00ccffAlt Knowledge:|r")
                                local currentKey = PK.charKey
                                for _, alt in ipairs(self.pkAltData) do
                                    -- Skip the current character
                                    if alt.charKey ~= currentKey then
                                    local cc = PK.ClassColors[alt.className] or "|cffffffff"
                                    local name = alt.charKey:match("^(.-)%-") or alt.charKey
                                    -- Adjust for free unlock rank so displayed values
                                    -- are divisible by 5 (Blizzard reports maxRanks+1)
                                    local displayMax = alt.maxRanks
                                    local displayRank = alt.rank
                                    if displayMax % 5 ~= 0 then
                                        displayMax = displayMax - 1
                                        displayRank = math.max(displayRank - 1, 0)
                                    end
                                    local rankColor
                                    if displayRank >= displayMax then
                                        rankColor = "|cff00ff00"   -- green = maxed
                                    elseif displayRank > 0 then
                                        rankColor = "|cffffd700"   -- gold  = partial
                                    else
                                        rankColor = "|cff555555"
                                    end
                                    GameTooltip:AddDoubleLine(
                                        cc .. name .. "|r",
                                        rankColor .. displayRank .. "/" .. displayMax .. "|r",
                                        1, 1, 1
                                    )
                                    end  -- if not current char
                                end
                                GameTooltip:Show()
                            end)
                        end

                    else
                        -- No alt data — hide any previous overlay and reset colors
                        if button.pkHighlight then
                            button.pkHighlight:Hide()
                        end
                        if button.pkRankText then
                            button.pkRankText:Hide()
                            for _, shadow in ipairs(button.pkRankShadows) do
                                shadow:Hide()
                            end
                        end
                        if button.pkOrangeText then
                            button.pkOrangeText:Hide()
                            for _, shadow in ipairs(button.pkOrangeShadows) do
                                shadow:Hide()
                            end
                        end
                        button.pkAltData = nil
                    end
                end
            end
        end
    end
end

--- One-time hook installation on the spec page.
function PK:SetupSpecTreeOverlay()
    if specTreeHooked then return end

    local specPage = ProfessionsFrame and ProfessionsFrame.SpecPage
    if not specPage then
        PK:Debug("Spec tree overlay: SpecPage not found")
        return
    end

    specTreeHooked = true

    -- When the Specializations tab is shown
    specPage:HookScript("OnShow", function()
        cachedProfBaseID    = nil       -- force cache refresh
        cachedProfVariantID = nil
        C_Timer.After(0.5, function()
            PK:UpdateSpecTreeHighlights()
        end)
    end)

    -- When a different spec tab is selected (SetTalentTreeID)
    if specPage.SetTalentTreeID then
        hooksecurefunc(specPage, "SetTalentTreeID", function()
            cachedProfBaseID    = nil
            cachedProfVariantID = nil
            C_Timer.After(0.3, function()
                PK:UpdateSpecTreeHighlights()
            end)
        end)
    end

    -- When tree currency / points update
    if specPage.UpdateTreeCurrencyInfo then
        hooksecurefunc(specPage, "UpdateTreeCurrencyInfo", function()
            C_Timer.After(0.2, function()
                PK:UpdateSpecTreeHighlights()
            end)
        end)
    end

    -- When individual buttons are refreshed
    if specPage.UpdateButton then
        hooksecurefunc(specPage, "UpdateButton", function()
            C_Timer.After(0.2, function()
                PK:UpdateSpecTreeHighlights()
            end)
        end)
    end

    PK:Debug("Spec tree overlay hooks installed")
end

----------------------------------------------------------------------
-- Button on Blizzard Profession Frame
----------------------------------------------------------------------

function PK:CreateProfessionButton()
    -- Attach to the Professions overview pane (opened with K key)
    local spellsFrame = PlayerSpellsFrame
    if not spellsFrame then return end

    local btn = CreateFrame("Button", nil, spellsFrame, "UIPanelButtonTemplate")
    btn:SetSize(60, 20)
    btn:SetText("|cff00ccffPK|r")
    -- Anchor to the left of the close button
    local closeBtn = spellsFrame.CloseButton or spellsFrame.ClosePanelButton
    if closeBtn then
        btn:SetPoint("RIGHT", closeBtn, "LEFT", -4, 0)
    else
        btn:SetPoint("TOPRIGHT", spellsFrame, "TOPRIGHT", -60, -2)
    end
    btn:SetFrameStrata("HIGH")

    btn:SetScript("OnClick", function()
        PK:ShowSummaryWindowAnchored(spellsFrame)
    end)

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("|cff00ccffProfKnowledge|r")
        GameTooltip:AddLine("View profession knowledge across all characters", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    PK:Debug("PK button added to professions overview pane")
end

--- Tab on ProfessionsBookFrame (matching Recipes / Specializations tab style)
function PK:CreateProfessionsBookButton()
    local bookFrame = ProfessionsBookFrame
    if not bookFrame then return end
    if bookFrame.pkTab then return end  -- already created

    -- Create a tab button styled like the Blizzard profession tabs
    local tab = CreateFrame("Button", "ProfKnowledgeTab", bookFrame)
    tab:SetSize(80, 32)
    tab:SetFrameStrata("HIGH")

    -- Tab background textures (mimic the Blizzard bottom-tab look)
    -- Left cap
    local leftTex = tab:CreateTexture(nil, "BACKGROUND")
    leftTex:SetTexture("Interface\\PaperDollInfoFrame\\UI-Character-ActiveTab")
    leftTex:SetTexCoord(0, 0.15625, 0, 1)
    leftTex:SetSize(12, 45)
    leftTex:SetPoint("TOPLEFT", 0, 0)
    tab.leftTex = leftTex

    -- Center stretch
    local midTex = tab:CreateTexture(nil, "BACKGROUND")
    midTex:SetTexture("Interface\\PaperDollInfoFrame\\UI-Character-ActiveTab")
    midTex:SetTexCoord(0.15625, 0.84375, 0, 1)
    midTex:SetPoint("LEFT", leftTex, "RIGHT", 0, 0)
    midTex:SetPoint("RIGHT", tab, "RIGHT", -12, 0)
    midTex:SetHeight(45)
    tab.midTex = midTex

    -- Right cap
    local rightTex = tab:CreateTexture(nil, "BACKGROUND")
    rightTex:SetTexture("Interface\\PaperDollInfoFrame\\UI-Character-ActiveTab")
    rightTex:SetTexCoord(0.84375, 1, 0, 1)
    rightTex:SetSize(12, 45)
    rightTex:SetPoint("TOPRIGHT", 0, 0)
    tab.rightTex = rightTex

    -- Tab label text
    local label = tab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER", 0, 2)
    label:SetText("|cff00ccffPK|r")
    tab.label = label

    -- Highlight on hover
    local highlight = tab:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetTexture("Interface\\PaperDollInfoFrame\\UI-Character-Tab-Highlight")
    highlight:SetTexCoord(0.15625, 0.84375, 0, 1)
    highlight:SetPoint("TOPLEFT", 12, 0)
    highlight:SetPoint("BOTTOMRIGHT", -12, 0)
    highlight:SetBlendMode("ADD")
    highlight:SetAlpha(0.4)

    -- Position: bottom of the book frame, next to existing tabs
    -- Find the last existing tab at the bottom to anchor after it
    local anchored = false
    -- Try common tab children of ProfessionsBookFrame
    local children = { bookFrame:GetChildren() }
    local rightmostTab = nil
    local rightmostX = -9999
    for _, child in ipairs(children) do
        -- Look for tab-like buttons at the bottom of the frame
        if child ~= tab and child.GetText and child:IsShown() then
            local _, _, _, x = child:GetPoint()
            if x and x > rightmostX then
                rightmostX = x
                rightmostTab = child
            end
        end
    end

    -- Anchor at the bottom-left of the book frame (tabs extend below the frame)
    tab:SetPoint("BOTTOMLEFT", bookFrame, "BOTTOMLEFT", 4, -30)
    tab.defaultAnchor = true

    -- Helper to swap between active / inactive visual states
    local TAB_TEX = "Interface\\PaperDollInfoFrame\\UI-Character-ActiveTab"
    local function SetTabActive(active)
        if active then
            -- Bright, fully saturated active tab
            leftTex:SetVertexColor(1, 1, 1)
            midTex:SetVertexColor(1, 1, 1)
            rightTex:SetVertexColor(1, 1, 1)
            leftTex:SetDesaturated(false)
            midTex:SetDesaturated(false)
            rightTex:SetDesaturated(false)
            label:SetFontObject("GameFontNormalSmall")
            label:SetText("|cff00ccffPK|r")
        else
            -- Dimmed, desaturated inactive tab
            leftTex:SetDesaturated(true)
            midTex:SetDesaturated(true)
            rightTex:SetDesaturated(true)
            leftTex:SetVertexColor(0.6, 0.6, 0.6)
            midTex:SetVertexColor(0.6, 0.6, 0.6)
            rightTex:SetVertexColor(0.6, 0.6, 0.6)
            label:SetFontObject("GameFontDisableSmall")
            label:SetText("|cff88bbddPK|r")
        end
        tab.isActive = active
    end
    tab.SetTabActive = SetTabActive

    -- Start inactive
    SetTabActive(false)

    -- Click handler (toggle)
    tab:SetScript("OnClick", function()
        PK:ToggleSummaryWindowAnchored(bookFrame)
    end)

    -- Tooltip
    tab:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("|cff00ccffProfKnowledge|r")
        GameTooltip:AddLine("View profession knowledge across all characters", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    tab:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    bookFrame.pkTab = tab
    PK:Debug("PK tab added to ProfessionsBookFrame")
end

function PK:UpdatePKTabState()
    local bookFrame = ProfessionsBookFrame
    if not bookFrame or not bookFrame.pkTab then return end
    local active = summaryFrame and summaryFrame:IsShown()
    bookFrame.pkTab.SetTabActive(active)
end

function PK:ShowSummaryWindowAnchored(anchorFrame)
    if not summaryFrame then
        summaryFrame = self:CreateSummaryWindow()
        -- Update tab state when the panel is closed by ESC or close button
        summaryFrame:HookScript("OnHide", function()
            PK:UpdatePKTabState()
        end)
    end
    self:RefreshSummaryWindow()

    -- Anchor on top of the book frame (same position, 5px taller)
    summaryFrame:ClearAllPoints()
    summaryFrame:SetPoint("TOPLEFT", anchorFrame, "TOPLEFT", 0, 5)
    summaryFrame:SetPoint("BOTTOMRIGHT", anchorFrame, "BOTTOMRIGHT", 0, 0)
    summaryFrame:Show()
    self:UpdatePKTabState()
end

function PK:ToggleSummaryWindowAnchored(anchorFrame)
    if summaryFrame and summaryFrame:IsShown() then
        summaryFrame:Hide()
    else
        self:ShowSummaryWindowAnchored(anchorFrame)
    end
end

----------------------------------------------------------------------
-- Export Window — copyable text box with all character data
----------------------------------------------------------------------

local exportFrame = nil

function PK:ShowExportWindow()
    local exportText = self:ExportAllData()
    if not exportText or exportText == "" then
        PK:Print("No data to export.")
        return
    end

    if not exportFrame then
        exportFrame = self:CreateExportWindow()
    end

    exportFrame.editBox:SetText(exportText)
    exportFrame:Show()

    -- Select all text so the user can Ctrl+C immediately
    exportFrame.editBox:HighlightText()
    exportFrame.editBox:SetFocus()
end

function PK:CreateExportWindow()
    local frame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    frame:SetSize(550, 500)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetClampedToScreen(true)

    frame:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true,
        tileSize = 32,
        edgeSize = 32,
        insets   = { left = 8, right = 8, top = 8, bottom = 8 },
    })

    -- Title
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("|cff00ccffProfKnowledge|r — Export")

    -- Instructions
    local instructions = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    instructions:SetPoint("TOP", title, "BOTTOM", 0, -4)
    instructions:SetTextColor(0.7, 0.7, 0.7)
    instructions:SetText("Press Ctrl+A to select all, then Ctrl+C to copy")

    -- Close button
    local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -4, -4)

    -- Scroll frame for the edit box
    local scrollFrame = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 16, -56)
    scrollFrame:SetPoint("BOTTOMRIGHT", -36, 48)

    -- EditBox (multiline, read-only-ish)
    local editBox = CreateFrame("EditBox", nil, scrollFrame)
    editBox:SetMultiLine(true)
    editBox:SetAutoFocus(false)
    editBox:SetFontObject(GameFontHighlightSmall)
    editBox:SetWidth(scrollFrame:GetWidth() or 480)
    editBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        frame:Hide()
    end)

    -- Keep the edit box width matching the scroll frame
    scrollFrame:SetScript("OnSizeChanged", function(self, width)
        editBox:SetWidth(width)
    end)

    scrollFrame:SetScrollChild(editBox)
    frame.editBox = editBox

    -- "Select All" button
    local selectBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    selectBtn:SetSize(100, 24)
    selectBtn:SetPoint("BOTTOMLEFT", 16, 14)
    selectBtn:SetText("Select All")
    selectBtn:SetScript("OnClick", function()
        editBox:HighlightText()
        editBox:SetFocus()
    end)

    -- "Close" button (export window)
    local closeBtnBottom = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    closeBtnBottom:SetSize(80, 24)
    closeBtnBottom:SetPoint("BOTTOMRIGHT", -16, 14)
    closeBtnBottom:SetText("Close")
    closeBtnBottom:SetScript("OnClick", function()
        frame:Hide()
    end)

    -- ESC to close (export window)
    frame:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            self:Hide()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)

    frame:Hide()
    return frame
end

----------------------------------------------------------------------
-- Import Window — paste export text to import character data
----------------------------------------------------------------------

local importFrame = nil

function PK:ShowImportWindow()
    if not importFrame then
        importFrame = self:CreateImportWindow()
    end

    importFrame.editBox:SetText("")
    importFrame.statusText:SetText("")
    importFrame:Show()
    importFrame.editBox:SetFocus()
end

function PK:CreateImportWindow()
    local frame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    frame:SetSize(550, 500)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetClampedToScreen(true)

    frame:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile     = true,
        tileSize = 32,
        edgeSize = 32,
        insets   = { left = 8, right = 8, top = 8, bottom = 8 },
    })

    -- Title
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("|cff00ccffProfKnowledge|r — Import")

    -- Instructions
    local instructions = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    instructions:SetPoint("TOP", title, "BOTTOM", 0, -4)
    instructions:SetTextColor(0.7, 0.7, 0.7)
    instructions:SetText("Paste a ProfKnowledge export string below, then click Import")

    -- Close button
    local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -4, -4)

    -- Scroll frame for the edit box
    local scrollFrame = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 16, -56)
    scrollFrame:SetPoint("BOTTOMRIGHT", -36, 72)

    -- EditBox (multiline, user pastes into this)
    local editBox = CreateFrame("EditBox", nil, scrollFrame)
    editBox:SetMultiLine(true)
    editBox:SetAutoFocus(false)
    editBox:SetFontObject(GameFontHighlightSmall)
    editBox:SetWidth(scrollFrame:GetWidth() or 480)
    editBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        frame:Hide()
    end)

    -- Keep the edit box width matching the scroll frame
    scrollFrame:SetScript("OnSizeChanged", function(self, width)
        editBox:SetWidth(width)
    end)

    scrollFrame:SetScrollChild(editBox)
    frame.editBox = editBox

    -- Status text (shows result of import)
    local statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    statusText:SetPoint("BOTTOMLEFT", 16, 44)
    statusText:SetPoint("BOTTOMRIGHT", -16, 44)
    statusText:SetJustifyH("LEFT")
    statusText:SetHeight(20)
    frame.statusText = statusText

    -- "Import" button
    local importBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    importBtn:SetSize(100, 24)
    importBtn:SetPoint("BOTTOMLEFT", 16, 14)
    importBtn:SetText("Import")
    importBtn:SetScript("OnClick", function()
        local text = editBox:GetText()
        if not text or strtrim(text) == "" then
            statusText:SetText("|cffff4444No text to import. Paste an export string first.|r")
            return
        end

        local success, msg = PK:ImportData(text)
        if success then
            statusText:SetText("|cff00ff00" .. msg .. "|r")
            PK:Print(msg)
            -- Refresh the summary window if it's open
            if summaryFrame and summaryFrame:IsShown() then
                PK:RefreshSummaryWindow()
            end
        else
            statusText:SetText("|cffff4444" .. msg .. "|r")
            PK:Print("|cffff4444Import failed:|r " .. msg)
        end
    end)

    -- "Clear" button
    local clearBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    clearBtn:SetSize(80, 24)
    clearBtn:SetPoint("BOTTOM", 0, 14)
    clearBtn:SetText("Clear")
    clearBtn:SetScript("OnClick", function()
        editBox:SetText("")
        statusText:SetText("")
        editBox:SetFocus()
    end)

    -- "Close" button (import window)
    local closeBtnBottom = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    closeBtnBottom:SetSize(80, 24)
    closeBtnBottom:SetPoint("BOTTOMRIGHT", -16, 14)
    closeBtnBottom:SetText("Close")
    closeBtnBottom:SetScript("OnClick", function()
        frame:Hide()
    end)

    -- ESC to close (import window)
    frame:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            self:Hide()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)

    frame:Hide()
    return frame
end
