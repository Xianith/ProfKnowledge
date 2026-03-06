----------------------------------------------------------------------
-- ProfKnowledge — Sync.lua
-- Guild sync protocol: DR/BDR election, version vectors, full &
-- incremental sync.
--
-- Inspired by GuildCrafts' OSPF-style Designated Router pattern.
-- All addon users independently elect the same DR by sorting
-- names lexicographically — no negotiation needed.
----------------------------------------------------------------------

local ADDON_NAME, PK = ...

----------------------------------------------------------------------
-- Timing constants
----------------------------------------------------------------------

local HELLO_DELAY        = 3      -- seconds before broadcasting HELLO
local SYNC_DELAY         = 5      -- seconds after HELLO before SYNC_REQ
local HEARTBEAT_INTERVAL = 60     -- DR broadcasts heartbeat every 60s
local HEARTBEAT_TIMEOUT  = 180    -- DR declared dead after 3 missed beats
local SYNC_TIMEOUT       = 30     -- first sync response timeout
local SYNC_RETRY_TIMEOUT = 15     -- subsequent retry timeout
local SYNC_MAX_RETRIES   = 3      -- max sync retries before giving up
local STALE_THRESHOLD    = 30 * 24 * 3600  -- 30 days

----------------------------------------------------------------------
-- Sync state
----------------------------------------------------------------------

PK.addonUsers    = {}     -- { [playerName] = lastSeenTime }
PK.syncRole      = nil    -- "DR", "BDR", or "OTHER"
PK.syncPending   = false  -- waiting for sync response
PK.syncRetryCount = 0
PK.heartbeatTimer = nil
PK.heartbeatCheckTimer = nil
PK.syncTimer     = nil
PK.guildName     = nil
PK.guildKey      = nil    -- "GuildName-Realm"

----------------------------------------------------------------------
-- Guild identity
----------------------------------------------------------------------

function PK:UpdateGuildInfo()
    if not IsInGuild() then
        self.guildName = nil
        self.guildKey = nil
        return false
    end

    local guildName, _, _, realmName = GetGuildInfo("player")
    if not guildName then return false end

    -- realmName from GetGuildInfo is often nil for same-realm
    realmName = realmName or GetRealmName()
    self.guildName = guildName
    self.guildKey = guildName .. "-" .. realmName
    return true
end

----------------------------------------------------------------------
-- DR/BDR Election
----------------------------------------------------------------------

--- Recalculate roles based on known addon users.
--- Deterministic: sort alphabetically, first = DR, second = BDR.
function PK:ElectRoles()
    local sorted = {}
    for name in pairs(self.addonUsers) do
        table.insert(sorted, name)
    end
    table.sort(sorted)

    local myName = UnitName("player")
    local oldRole = self.syncRole

    if #sorted == 0 then
        self.syncRole = nil
    elseif sorted[1] == myName then
        self.syncRole = "DR"
    elseif sorted[2] == myName then
        self.syncRole = "BDR"
    else
        self.syncRole = "OTHER"
    end

    if self.syncRole ~= oldRole then
        PK:Debug("Role changed: " .. tostring(oldRole) .. " → " .. tostring(self.syncRole)
            .. " (" .. #sorted .. " users)")

        -- Start/stop heartbeat based on role
        if self.syncRole == "DR" then
            self:StartHeartbeat()
        else
            self:StopHeartbeat()
        end
    end
end

----------------------------------------------------------------------
-- Heartbeat (DR only)
----------------------------------------------------------------------

function PK:StartHeartbeat()
    self:StopHeartbeat()
    self.heartbeatTimer = C_Timer.NewTicker(HEARTBEAT_INTERVAL, function()
        PK:SendGuildMessage(PK.MSG_HEARTBEAT, {
            users = PK:GetAddonUserCount(),
        })
    end)
    PK:Debug("Heartbeat started (interval=" .. HEARTBEAT_INTERVAL .. "s)")
end

function PK:StopHeartbeat()
    if self.heartbeatTimer then
        self.heartbeatTimer:Cancel()
        self.heartbeatTimer = nil
    end
end

--- Start monitoring for DR heartbeat loss (non-DR nodes).
function PK:StartHeartbeatMonitor()
    self:StopHeartbeatMonitor()
    self.heartbeatCheckTimer = C_Timer.NewTicker(HEARTBEAT_TIMEOUT, function()
        PK:CheckHeartbeat()
    end)
end

function PK:StopHeartbeatMonitor()
    if self.heartbeatCheckTimer then
        self.heartbeatCheckTimer:Cancel()
        self.heartbeatCheckTimer = nil
    end
end

function PK:CheckHeartbeat()
    -- Evict addon users not seen within the timeout
    local now = time()
    local evicted = false
    for name, lastSeen in pairs(self.addonUsers) do
        if name ~= UnitName("player") and (now - lastSeen) > HEARTBEAT_TIMEOUT then
            PK:Debug("Evicting " .. name .. " (no heartbeat for " .. (now - lastSeen) .. "s)")
            self.addonUsers[name] = nil
            evicted = true
        end
    end
    if evicted then
        self:ElectRoles()
    end
end

function PK:GetAddonUserCount()
    local count = 0
    for _ in pairs(self.addonUsers) do
        count = count + 1
    end
    return count
end

----------------------------------------------------------------------
-- Login / initialization flow
----------------------------------------------------------------------

--- Called after PLAYER_LOGIN + InitComm succeeds.
--- Kicks off the HELLO → SYNC_REQ flow.
function PK:StartSync()
    if not self.commReady then return end
    if not self:UpdateGuildInfo() then
        PK:Debug("Not in a guild — sync disabled")
        return
    end

    -- Ensure guild data storage exists
    self:InitGuildRoster()

    -- Register ourselves as an addon user
    local myName = UnitName("player")
    self.addonUsers[myName] = time()

    -- Broadcast HELLO after a short delay
    C_Timer.After(HELLO_DELAY, function()
        PK:BroadcastHello()

        -- Request sync after another delay (let HELLOs settle)
        C_Timer.After(SYNC_DELAY, function()
            PK:RequestSync()
        end)
    end)

    -- Start heartbeat monitoring
    self:StartHeartbeatMonitor()
    self:ElectRoles()
end

----------------------------------------------------------------------
-- HELLO — announce presence
----------------------------------------------------------------------

function PK:BroadcastHello()
    if not self.commReady then return end
    self:SendGuildMessage(PK.MSG_HELLO, {
        charKey = self.charKey,
    })
end

----------------------------------------------------------------------
-- SYNC_REQ — request sync with version vector
----------------------------------------------------------------------

function PK:RequestSync()
    if not self.commReady then return end
    if self.syncPending then return end

    self.syncPending = true
    self.syncRetryCount = 0

    local vector = self:BuildVersionVector()
    self:SendGuildMessage(PK.MSG_SYNC_REQ, {
        vector = vector,
        charKey = self.charKey,
    })

    -- Set timeout for response
    self:ScheduleSyncTimeout()
end

function PK:ScheduleSyncTimeout()
    if self.syncTimer then
        self.syncTimer:Cancel()
    end

    local timeout = (self.syncRetryCount == 0) and SYNC_TIMEOUT or SYNC_RETRY_TIMEOUT
    self.syncTimer = C_Timer.NewTimer(timeout, function()
        PK:OnSyncTimeout()
    end)
end

function PK:OnSyncTimeout()
    if not self.syncPending then return end

    self.syncRetryCount = self.syncRetryCount + 1
    PK:Debug("Sync timeout (retry " .. self.syncRetryCount .. "/" .. SYNC_MAX_RETRIES .. ")")

    if self.syncRetryCount >= SYNC_MAX_RETRIES then
        PK:Debug("Sync failed after " .. SYNC_MAX_RETRIES .. " retries")
        self.syncPending = false
        return
    end

    -- Retry: if first retry failed, evict unresponsive DR candidates
    if self.syncRetryCount >= 2 then
        -- Evict the current DR from our addon users list
        local sorted = {}
        for name in pairs(self.addonUsers) do
            table.insert(sorted, name)
        end
        table.sort(sorted)
        if sorted[1] and sorted[1] ~= UnitName("player") then
            PK:Debug("Evicting unresponsive DR: " .. sorted[1])
            self.addonUsers[sorted[1]] = nil
            self:ElectRoles()
        end
    end

    -- Re-send sync request
    local vector = self:BuildVersionVector()
    self:SendGuildMessage(PK.MSG_SYNC_REQ, {
        vector = vector,
        charKey = self.charKey,
    })
    self:ScheduleSyncTimeout()
end

----------------------------------------------------------------------
-- DELTA — broadcast incremental update after local scan
----------------------------------------------------------------------

--- Called after a local profession scan completes.
--- Broadcasts the current character's data as a delta update.
function PK:BroadcastDelta()
    if not self.commReady then return end
    if not self.guildKey then return end

    local charData = self:GetCurrentCharacterData()
    if not charData then return end

    -- Build a stripped-down copy for transmission
    local stripped = self:StripForSync(charData)

    self:SendGuildMessage(PK.MSG_DELTA, {
        charKey  = self.charKey,
        data     = stripped,
        guildKey = self.guildKey,
    })
end

----------------------------------------------------------------------
-- Version vector
----------------------------------------------------------------------

--- Build a version vector from our guild roster data.
--- Returns: { [charKey] = lastUpdate, ... }
function PK:BuildVersionVector()
    local vector = {}
    local roster = self:GetGuildRoster()
    if roster then
        for charKey, entry in pairs(roster) do
            vector[charKey] = entry.lastUpdate or 0
        end
    end
    return vector
end

----------------------------------------------------------------------
-- Data stripping for transmission
----------------------------------------------------------------------

--- Strip local-only fields from character data for sync.
--- Returns a clean copy safe for transmission.
function PK:StripForSync(charData)
    if not charData then return nil end

    local stripped = {
        className   = charData.className,
        classID     = charData.classID,
        level       = charData.level,
        lastScanned = charData.lastScanned,
        prof1BaseID = charData.prof1BaseID,
        prof2BaseID = charData.prof2BaseID,
    }

    -- Copy professions but strip node-level detail to save bandwidth
    -- We keep tab summaries (name, pointsSpent, maxPoints) but omit
    -- individual node data which is very large
    if charData.professions then
        stripped.professions = {}
        for skillLineID, profData in pairs(charData.professions) do
            -- Skip empty placeholder professions
            if PK:IsEmptyProfession(profData) then
                -- do nothing, skip this entry
            else
            local profCopy = {
                skillLineID         = profData.skillLineID,
                baseSkillLineID     = profData.baseSkillLineID,
                variantID           = profData.variantID,
                expansionName       = profData.expansionName,
                name                = profData.name,
                icon                = profData.icon,
                skillLevel          = profData.skillLevel,
                maxSkillLevel       = profData.maxSkillLevel,
                hasSpec             = profData.hasSpec,
                unspentKnowledge    = profData.unspentKnowledge,
                totalKnowledgeSpent = profData.totalKnowledgeSpent,
            }

            -- Include tab summaries and node data
            if profData.tabs then
                profCopy.tabs = {}
                for tabID, tabData in pairs(profData.tabs) do
                    local tabCopy = {
                        name        = tabData.name,
                        pointsSpent = tabData.pointsSpent,
                        maxPoints   = tabData.maxPoints,
                    }
                    -- Include node data (name, rank, maxRanks) for spec overlay
                    if tabData.nodes then
                        tabCopy.nodes = {}
                        for _, node in ipairs(tabData.nodes) do
                            if node.currentRank and node.currentRank > 0 then
                                table.insert(tabCopy.nodes, {
                                    name        = node.name,
                                    currentRank = node.currentRank,
                                    maxRanks    = node.maxRanks,
                                })
                            end
                        end
                    end
                    profCopy.tabs[tabID] = tabCopy
                end
            end

            stripped.professions[skillLineID] = profCopy
            end -- else (not empty)
        end
    end

    return stripped
end

----------------------------------------------------------------------
-- Message handlers — registered with the dispatch table in Comm.lua
----------------------------------------------------------------------

--- HELLO handler: a guild member announced their presence.
local HELLO_COOLDOWN = 30  -- don't reply to HELLO more than once per 30s
local lastHelloReply = 0
local function OnHello(self, sender, payload, distribution)
    self.addonUsers[sender] = time()
    self:ElectRoles()

    -- Reply with our own HELLO, but only if we haven't recently (avoid ping-pong)
    local now = time()
    if (now - lastHelloReply) >= HELLO_COOLDOWN then
        lastHelloReply = now
        local jitter = 0.5 + math.random() * 3.5
        C_Timer.After(jitter, function()
            if PK.commReady then
                PK:SendGuildMessage(PK.MSG_HELLO, {
                    charKey = PK.charKey,
                })
            end
        end)
    end
end

--- HEARTBEAT handler: DR is alive.
local function OnHeartbeat(self, sender, payload, distribution)
    self.addonUsers[sender] = time()
end

--- SYNC_REQ handler: someone wants to sync (DR/BDR responds).
local function OnSyncReq(self, sender, payload, distribution)
    -- Only DR responds (or BDR on retry)
    if self.syncRole ~= "DR" and self.syncRole ~= "BDR" then
        return
    end

    -- BDR only responds if DR seems to be missing
    if self.syncRole == "BDR" then
        -- Check if DR is still alive
        local sorted = {}
        for name in pairs(self.addonUsers) do
            table.insert(sorted, name)
        end
        table.sort(sorted)
        if sorted[1] and sorted[1] ~= UnitName("player") then
            -- DR exists and it's not us — let the DR handle it
            -- (BDR responds after a delay to act as fallback)
            C_Timer.After(SYNC_TIMEOUT * 0.5, function()
                if PK.commReady then
                    PK:ProcessSyncRequest(sender, payload)
                end
            end)
            return
        end
    end

    self:ProcessSyncRequest(sender, payload)
end

--- Process a sync request (called by DR or BDR).
function PK:ProcessSyncRequest(sender, payload)
    local incomingVector = payload.vector or {}
    local roster = self:GetGuildRoster() or {}

    -- Compare version vectors
    local toSend = {}  -- data we have that requester needs
    local toPull = {}  -- member keys we need from the requester

    -- Check our local data vs incoming vector
    for charKey, entry in pairs(roster) do
        local localTs = entry.lastUpdate or 0
        local remoteTs = incomingVector[charKey] or 0

        if localTs > remoteTs then
            -- We have newer data — send it
            toSend[charKey] = self:StripForSync(entry)
        elseif remoteTs > localTs then
            -- They have newer data — request it
            table.insert(toPull, charKey)
        end
    end

    -- Check for members the requester has that we don't
    for charKey, ts in pairs(incomingVector) do
        if not roster[charKey] and ts > 0 then
            table.insert(toPull, charKey)
        end
    end

    -- Send data the requester needs
    if next(toSend) then
        self:SendChunked(PK.MSG_SYNC_RESP, toSend, sender)
    end

    -- Request data we need from the requester
    if #toPull > 0 then
        self:SendWhisperMessage(PK.MSG_SYNC_PULL, {
            keys = toPull,
        }, sender)
    end

    -- If we had nothing to send, still send an empty SYNC_RESP so
    -- the requester knows sync is acknowledged and won't time out
    if not next(toSend) then
        self:SendWhisperMessage(PK.MSG_SYNC_RESP, {
            data       = {},
            chunkIndex = 1,
            chunkTotal = 1,
        }, sender)
    end
end

--- SYNC_RESP handler: DR sent us data we were missing.
local function OnSyncResp(self, sender, payload, distribution)
    if not self.syncPending then return end

    local data = payload.data or {}
    local chunkIndex = payload.chunkIndex or 1
    local chunkTotal = payload.chunkTotal or 1

    -- Merge the received data into our guild roster
    local merged = 0
    for charKey, entry in pairs(data) do
        if self:MergeGuildMember(charKey, entry) then
            merged = merged + 1
        end
    end

    PK:Debug("Sync response chunk " .. chunkIndex .. "/" .. chunkTotal
        .. " from " .. sender .. " (merged " .. merged .. ")")

    -- If this is the last chunk, sync is complete
    if chunkIndex >= chunkTotal then
        self.syncPending = false
        if self.syncTimer then
            self.syncTimer:Cancel()
            self.syncTimer = nil
        end
        PK:Debug("Sync complete")
    end
end

--- SYNC_PULL handler: DR wants data from us.
local function OnSyncPull(self, sender, payload, distribution)
    local keys = payload.keys or {}
    if #keys == 0 then return end

    local roster = self:GetGuildRoster() or {}
    local toSend = {}

    for _, charKey in ipairs(keys) do
        local entry = roster[charKey]
        if entry then
            toSend[charKey] = self:StripForSync(entry)
        end
    end

    if next(toSend) then
        self:SendChunked(PK.MSG_SYNC_PUSH, toSend, sender)
    end
end

--- SYNC_PUSH handler: requester sent data we asked for.
local function OnSyncPush(self, sender, payload, distribution)
    local data = payload.data or {}
    local merged = 0

    for charKey, entry in pairs(data) do
        if self:MergeGuildMember(charKey, entry) then
            merged = merged + 1
        end
    end

    PK:Debug("Sync push from " .. sender .. " (merged " .. merged .. ")")

    -- As DR, rebroadcast this data as a DELTA so all nodes get it
    if self.syncRole == "DR" and merged > 0 then
        for charKey, entry in pairs(data) do
            self:SendGuildMessage(PK.MSG_DELTA, {
                charKey  = charKey,
                data     = entry,
                guildKey = self.guildKey,
            })
        end
    end
end

--- DELTA handler: incremental update from a guild member.
local function OnDelta(self, sender, payload, distribution)
    local charKey = payload.charKey
    local data = payload.data
    local guildKey = payload.guildKey

    if not charKey or not data then return end

    -- Only accept data for our guild
    if guildKey and self.guildKey and guildKey ~= self.guildKey then
        return
    end

    if self:MergeGuildMember(charKey, data) then
        PK:Debug("Delta update: merged " .. charKey .. " from " .. sender)
    end
end

----------------------------------------------------------------------
-- Register all message handlers
----------------------------------------------------------------------

function PK:RegisterSyncHandlers()
    self:RegisterMessageHandler(PK.MSG_HELLO,     OnHello)
    self:RegisterMessageHandler(PK.MSG_HEARTBEAT,  OnHeartbeat)
    self:RegisterMessageHandler(PK.MSG_SYNC_REQ,   OnSyncReq)
    self:RegisterMessageHandler(PK.MSG_SYNC_RESP,  OnSyncResp)
    self:RegisterMessageHandler(PK.MSG_SYNC_PULL,  OnSyncPull)
    self:RegisterMessageHandler(PK.MSG_SYNC_PUSH,  OnSyncPush)
    self:RegisterMessageHandler(PK.MSG_DELTA,      OnDelta)
end

----------------------------------------------------------------------
-- Slash commands for sync
----------------------------------------------------------------------

function PK:HandleSyncCommand(args)
    if args == "status" or args == "" then
        self:PrintSyncStatus()
    elseif args == "request" or args == "force" then
        self.syncPending = false
        self:RequestSync()
        PK:Print("Force sync requested.")
    end
end

function PK:PrintSyncStatus()
    PK:Print("--- Guild Sync Status ---")

    if not self.guildKey then
        PK:Print("  Not in a guild.")
        return
    end

    PK:Print("  Guild: " .. self.guildKey)
    PK:Print("  Role: " .. tostring(self.syncRole))
    PK:Print("  Comm ready: " .. tostring(self.commReady or false))
    PK:Print("  Sync pending: " .. tostring(self.syncPending))

    local count = self:GetAddonUserCount()
    PK:Print("  Addon users online: " .. count)
    for name in pairs(self.addonUsers) do
        local role = ""
        local sorted = {}
        for n in pairs(self.addonUsers) do table.insert(sorted, n) end
        table.sort(sorted)
        if sorted[1] == name then role = " (DR)" end
        if sorted[2] == name then role = " (BDR)" end
        PK:Print("    " .. name .. role)
    end

    local roster = self:GetGuildRoster()
    if roster then
        local rosterCount = 0
        for _ in pairs(roster) do rosterCount = rosterCount + 1 end
        PK:Print("  Guild roster entries: " .. rosterCount)
    end
end

----------------------------------------------------------------------
-- Staleness helpers
----------------------------------------------------------------------

function PK:GetStalenessTag(lastUpdate)
    if not lastUpdate or lastUpdate == 0 then return "never" end
    local age = time() - lastUpdate
    if age < 3600 then
        return math.floor(age / 60) .. "m ago"
    elseif age < 86400 then
        return math.floor(age / 3600) .. "h ago"
    elseif age < STALE_THRESHOLD then
        return math.floor(age / 86400) .. "d ago"
    else
        return math.floor(age / 86400) .. "d ago (stale)"
    end
end

function PK:IsStale(lastUpdate)
    if not lastUpdate or lastUpdate == 0 then return true end
    return (time() - lastUpdate) > STALE_THRESHOLD
end
