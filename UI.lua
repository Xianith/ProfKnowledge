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
    local frame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    frame:SetSize(750, 450)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetFrameStrata("DIALOG")
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
    title:SetText("|cff00ccffProf|r|cffffffffKnowledge|r")
    frame.title = title

    -- Subtitle
    local subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    subtitle:SetPoint("TOP", title, "BOTTOM", 0, -2)
    subtitle:SetTextColor(0.6, 0.6, 0.6)
    frame.subtitle = subtitle

    -- Hint text
    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOP", subtitle, "BOTTOM", 0, -1)
    hint:SetTextColor(0.45, 0.45, 0.45)
    hint:SetText("Click a cell to see knowledge tree details")
    frame.hint = hint

    -- Close button
    local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -4, -4)

    -- Column headers area
    local headerFrame = CreateFrame("Frame", nil, frame)
    headerFrame:SetPoint("TOPLEFT", 16, -60)
    headerFrame:SetPoint("TOPRIGHT", -16, -60)
    headerFrame:SetHeight(24)
    frame.headerFrame = headerFrame

    -- Scroll frame for grid rows
    local scrollFrame = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 16, -86)
    scrollFrame:SetPoint("BOTTOMRIGHT", -36, 16)
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

----------------------------------------------------------------------
-- Refresh the summary grid
----------------------------------------------------------------------

function PK:RefreshSummaryWindow()
    if not summaryFrame then return end

    local chars = self:GetAllCharacters()
    local charCount = #chars

    summaryFrame.subtitle:SetText(charCount .. " character(s) tracked")

    -- Determine which professions exist across all characters
    local activeProfessions = {}
    local profSet = {}
    for _, char in ipairs(chars) do
        for skillLineID, _ in pairs(char.professions) do
            if not profSet[skillLineID] then
                profSet[skillLineID] = true
                table.insert(activeProfessions, skillLineID)
            end
        end
    end

    -- Sort professions by display order
    local orderMap = {}
    for i, id in ipairs(PK.ProfessionOrder) do
        orderMap[id] = i
    end
    table.sort(activeProfessions, function(a, b)
        return (orderMap[a] or 999) < (orderMap[b] or 999)
    end)

    -- Layout constants
    local NAME_COL_WIDTH = 140
    local PROF_COL_WIDTH = 72
    local ROW_HEIGHT = 22
    local totalWidth = NAME_COL_WIDTH + (#activeProfessions * PROF_COL_WIDTH)

    local minWidth = math.max(420, totalWidth + 60)
    summaryFrame:SetWidth(math.min(minWidth, 950))

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

    -- "Character" header
    local nameHeader = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameHeader:SetPoint("TOPLEFT", 4, 0)
    nameHeader:SetWidth(NAME_COL_WIDTH)
    nameHeader:SetJustifyH("LEFT")
    nameHeader:SetText("Character")
    table.insert(headerFrame.children, nameHeader)

    -- Profession column headers
    for colIdx, skillLineID in ipairs(activeProfessions) do
        local shortName = PK.ProfessionShortNames[skillLineID] or "?"
        local colHeader = headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        colHeader:SetPoint("TOPLEFT", NAME_COL_WIDTH + ((colIdx - 1) * PROF_COL_WIDTH), 0)
        colHeader:SetWidth(PROF_COL_WIDTH)
        colHeader:SetJustifyH("CENTER")
        colHeader:SetText(shortName)
        table.insert(headerFrame.children, colHeader)
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

        -- Character name
        local nameText = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        nameText:SetPoint("TOPLEFT", 4, yOffset)
        nameText:SetWidth(NAME_COL_WIDTH)
        nameText:SetJustifyH("LEFT")
        local displayName = char.charKey:match("^(.-)%-") or char.charKey
        local nameStr = classColor .. displayName .. "|r"
        if isCurrentChar then
            nameStr = nameStr .. " |cff888888*|r"
        end
        nameText:SetText(nameStr)
        table.insert(scrollChild.children, nameText)

        -- Profession data cells (clickable buttons)
        for colIdx, skillLineID in ipairs(activeProfessions) do
            local profData = char.professions[skillLineID]
            local xPos = NAME_COL_WIDTH + ((colIdx - 1) * PROF_COL_WIDTH)

            -- Create a clickable button for this cell
            local cellBtn = CreateFrame("Button", nil, scrollChild)
            cellBtn:SetPoint("TOPLEFT", xPos, yOffset)
            cellBtn:SetSize(PROF_COL_WIDTH, ROW_HEIGHT)
            table.insert(scrollChild.children, cellBtn)

            local cellText = cellBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            cellText:SetAllPoints()
            cellText:SetJustifyH("CENTER")
            cellText:SetJustifyV("MIDDLE")

            if profData then
                if profData.hasSpec == false then
                    cellText:SetText("|cff888888" .. (profData.skillLevel or 0) .. "|r")
                else
                    local spent = profData.totalKnowledgeSpent or 0
                    local unspent = profData.unspentKnowledge or 0

                    if unspent > 0 then
                        cellText:SetText(string.format("|cff00ff00%d|r/|cffffd700%d|r",
                            spent, spent + unspent))
                    elseif spent > 0 then
                        cellText:SetText("|cffffffff" .. spent .. "|r")
                    else
                        cellText:SetText("|cff5555550|r")
                    end
                end

                -- Highlight on hover
                local highlight = cellBtn:CreateTexture(nil, "HIGHLIGHT")
                highlight:SetAllPoints()
                highlight:SetColorTexture(1, 1, 1, 0.1)

                -- Click to show detail
                local charKey = char.charKey
                local profID = skillLineID
                cellBtn:SetScript("OnClick", function()
                    PK:ShowDetailPanel(charKey, profID)
                end)

                -- Tooltip on hover showing tab summary
                cellBtn:SetScript("OnEnter", function(btn)
                    PK:ShowCellTooltip(btn, charKey, profID, profData)
                end)
                cellBtn:SetScript("OnLeave", function()
                    GameTooltip:Hide()
                end)
            else
                cellText:SetText("|cff333333—|r")
            end
        end

        yOffset = yOffset - ROW_HEIGHT
    end

    -- Legend
    yOffset = yOffset - 10
    local legend = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    legend:SetPoint("TOPLEFT", 4, yOffset)
    legend:SetTextColor(0.5, 0.5, 0.5)
    legend:SetText("|cff00ff00Green|r = spent  |cffffd700Gold|r = total (spent+unspent)  |cff888888*|r = current char  Click cell for tree details")
    table.insert(scrollChild.children, legend)

    yOffset = yOffset - ROW_HEIGHT
    scrollChild:SetHeight(math.abs(yOffset) + 10)
end

----------------------------------------------------------------------
-- Cell tooltip — shows tab-level summary on hover
----------------------------------------------------------------------

function PK:ShowCellTooltip(btn, charKey, skillLineID, profData)
    GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")

    local classColor = "|cffffffff"
    local charData = self.db and self.db.characters and self.db.characters[charKey]
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

    -- Get character data
    local charData = self.db and self.db.characters and self.db.characters[charKey]
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

    -- Create the overlay panel
    overlayFrame = CreateFrame("Frame", nil, profFrame, "BackdropTemplate")
    overlayFrame:SetSize(320, 200)
    overlayFrame:SetFrameStrata("DIALOG")

    overlayFrame:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile     = true,
        tileSize = 16,
        edgeSize = 16,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 },
    })

    -- Position: top-right of the profession frame
    overlayFrame:SetPoint("TOPRIGHT", profFrame, "TOPRIGHT", -20, -60)

    -- Make it draggable within the profession frame
    overlayFrame:SetMovable(true)
    overlayFrame:EnableMouse(true)
    overlayFrame:RegisterForDrag("LeftButton")
    overlayFrame:SetScript("OnDragStart", overlayFrame.StartMoving)
    overlayFrame:SetScript("OnDragStop", overlayFrame.StopMovingOrSizing)

    -- Title
    local title = overlayFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -8)
    title:SetText("|cff00ccffAlt Knowledge|r")
    overlayFrame.title = title

    -- Scroll area for content (in case of many alts)
    local scrollFrame = CreateFrame("ScrollFrame", nil, overlayFrame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 8, -28)
    scrollFrame:SetPoint("BOTTOMRIGHT", -28, 8)
    overlayFrame.scrollFrame = scrollFrame

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(1, 1)
    scrollFrame:SetScrollChild(scrollChild)
    overlayFrame.scrollChild = scrollChild
    overlayFrame.contentChildren = {}

    -- Hook the profession frame show/hide
    profFrame:HookScript("OnShow", function()
        C_Timer.After(0.5, function()
            PK:RefreshOverlay()
        end)
    end)

    profFrame:HookScript("OnHide", function()
        if overlayFrame then
            overlayFrame:Hide()
        end
    end)

    -- Hook tab changes
    if profFrame.TabSystem then
        hooksecurefunc(profFrame.TabSystem, "SetTab", function()
            C_Timer.After(0.3, function()
                PK:RefreshOverlay()
            end)
        end)
    end

    PK:Debug("Overlay created and hooked")
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

    -- Get the currently viewed profession
    local profFrame = ProfessionsFrame
    if not profFrame or not profFrame:IsShown() then
        overlayFrame:Hide()
        return
    end

    -- Try to determine the current profession's BASE skillLineID
    -- (our data is keyed by base ID, but the frame may report the variant ID)
    local skillLineID = nil
    local profName = nil

    if profFrame.professionInfo then
        -- parentProfessionID is the base ID (e.g., 171 for Alchemy)
        skillLineID = profFrame.professionInfo.parentProfessionID
            or profFrame.professionInfo.professionID
            or profFrame.professionInfo.skillLineID
        profName = profFrame.professionInfo.parentProfessionName
            or profFrame.professionInfo.professionName
    end

    if not skillLineID then
        local ok, info = pcall(function()
            return C_TradeSkillUI and C_TradeSkillUI.GetBaseProfessionInfo
                and C_TradeSkillUI.GetBaseProfessionInfo()
        end)
        if ok and info then
            -- GetBaseProfessionInfo should return the base ID
            skillLineID = info.professionID or info.skillLineID
            profName = info.professionName
        end
    end

    if not skillLineID then
        overlayFrame:Hide()
        return
    end

    -- Try to find characters with this profession
    -- First try the ID we found (should be base ID)
    local chars = self:GetAllCharactersForProfession(skillLineID)

    -- If no results, the frame may have given us a variant ID instead
    -- Try looking up the base ID from our variant cache
    if #chars == 0 and self.db and self.db.discoveredVariants then
        for baseID, variantID in pairs(self.db.discoveredVariants) do
            if variantID == skillLineID then
                chars = self:GetAllCharactersForProfession(baseID)
                if #chars > 0 then
                    skillLineID = baseID
                    break
                end
            end
        end
    end

    if #chars <= 1 then
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
        summaryText:SetWidth(130)
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
                    tabText:SetWidth(170)
                    tabText:SetJustifyH("LEFT")
                    tabText:SetText("|cffaaaaaa" .. (tabData.name or "?") .. "|r")
                    table.insert(overlayFrame.contentChildren, tabText)

                    local tabPts = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                    tabPts:SetPoint("TOPLEFT", 190, yOffset)
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
            sep:SetSize(270, 1)
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

local specTreeHooked    = false
local cachedAltNodeData = nil   -- { [lowerNodeName] = { {charKey,className,rank,maxRanks}, ... } }
local cachedProfBaseID  = nil

--- Build a table of every node that ANY other character has points in
--- for a given base profession.
function PK:BuildAltNodeLookup(baseSkillLineID)
    local lookup = {}
    if not self.db or not self.db.characters then return lookup end

    for charKey, charData in pairs(self.db.characters) do
        local profData = charData.professions and charData.professions[baseSkillLineID]
        if profData and profData.tabs then
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

    -- Rebuild the cache when the profession changes
    if baseID ~= cachedProfBaseID then
        cachedAltNodeData = self:BuildAltNodeLookup(baseID)
        cachedProfBaseID  = baseID
        PK:Debug("Spec highlights: rebuilt cache for baseID " .. tostring(baseID))
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
                        -- ---- green highlight ----
                        if not button.pkHighlight then
                            local glow = button:CreateTexture(nil, "OVERLAY", nil, 7)
                            glow:SetPoint("TOPLEFT", -3, 3)
                            glow:SetPoint("BOTTOMRIGHT", 3, -3)
                            glow:SetColorTexture(0, 1, 0, 0.3)
                            glow:SetBlendMode("ADD")
                            button.pkHighlight = glow
                        end
                        button.pkHighlight:Show()

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
                                for _, alt in ipairs(self.pkAltData) do
                                    local cc = PK.ClassColors[alt.className] or "|cffffffff"
                                    local name = alt.charKey:match("^(.-)%-") or alt.charKey
                                    local rankColor
                                    if alt.rank >= alt.maxRanks then
                                        rankColor = "|cff00ff00"   -- green = maxed
                                    elseif alt.rank > 0 then
                                        rankColor = "|cffffd700"   -- gold  = partial
                                    else
                                        rankColor = "|cff555555"
                                    end
                                    GameTooltip:AddDoubleLine(
                                        cc .. name .. "|r",
                                        rankColor .. alt.rank .. "/" .. alt.maxRanks .. "|r",
                                        1, 1, 1
                                    )
                                end
                                GameTooltip:Show()
                            end)
                        end

                    else
                        -- No alt data — hide any previous highlight
                        if button.pkHighlight then
                            button.pkHighlight:Hide()
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
        cachedProfBaseID = nil          -- force cache refresh
        C_Timer.After(0.5, function()
            PK:UpdateSpecTreeHighlights()
        end)
    end)

    -- When a different spec tab is selected (SetTalentTreeID)
    if specPage.SetTalentTreeID then
        hooksecurefunc(specPage, "SetTalentTreeID", function()
            cachedProfBaseID = nil
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
