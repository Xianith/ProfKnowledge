----------------------------------------------------------------------
-- ProfKnowledge — Comm.lua
-- Low-level communication layer for guild sync
--
-- Uses AceComm-3.0 for transport, AceSerializer-3.0 for serialization,
-- and LibDeflate for compression. Messages are sent over the GUILD
-- channel (broadcast) or WHISPER (point-to-point).
--
-- Message envelope: { t = msgType, v = protocolVersion, p = payload }
-- Wire format: "Z" prefix = compressed, "U" prefix = uncompressed
----------------------------------------------------------------------

local ADDON_NAME, PK = ...

----------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------

local PROTOCOL_VERSION  = 1
local ADDON_PREFIX      = "PKSync"
local COMPRESS_THRESHOLD = 200  -- only compress payloads > 200 bytes
local SYNC_CHUNK_SIZE   = 10   -- members per sync response chunk

-- Message types
local MSG_HELLO      = "HELLO"
local MSG_HEARTBEAT  = "HB"
local MSG_SYNC_REQ   = "SREQ"
local MSG_SYNC_RESP  = "SRESP"
local MSG_SYNC_PULL  = "SPULL"
local MSG_SYNC_PUSH  = "SPUSH"
local MSG_DELTA      = "DELTA"

-- Priorities (ChatThrottleLib)
local PRIO_NORMAL = "NORMAL"
local PRIO_BULK   = "BULK"

-- Export constants to PK namespace for Sync.lua
PK.PROTOCOL_VERSION  = PROTOCOL_VERSION
PK.ADDON_PREFIX      = ADDON_PREFIX
PK.SYNC_CHUNK_SIZE   = SYNC_CHUNK_SIZE
PK.MSG_HELLO         = MSG_HELLO
PK.MSG_HEARTBEAT     = MSG_HEARTBEAT
PK.MSG_SYNC_REQ      = MSG_SYNC_REQ
PK.MSG_SYNC_RESP     = MSG_SYNC_RESP
PK.MSG_SYNC_PULL     = MSG_SYNC_PULL
PK.MSG_SYNC_PUSH     = MSG_SYNC_PUSH
PK.MSG_DELTA         = MSG_DELTA
PK.PRIO_NORMAL       = PRIO_NORMAL
PK.PRIO_BULK         = PRIO_BULK

----------------------------------------------------------------------
-- Library references (resolved at init time)
----------------------------------------------------------------------

local AceComm       -- AceComm-3.0
local AceSerializer -- AceSerializer-3.0
local LibDeflate    -- LibDeflate

----------------------------------------------------------------------
-- Message dispatch table: msgType → handler function
-- Populated by Sync.lua via PK:RegisterMessageHandler()
----------------------------------------------------------------------

local messageHandlers = {}

function PK:RegisterMessageHandler(msgType, handler)
    messageHandlers[msgType] = handler
end

----------------------------------------------------------------------
-- Initialize the comm system
----------------------------------------------------------------------

function PK:InitComm()
    -- Grab library references
    AceSerializer = LibStub:GetLibrary("AceSerializer-3.0")
    AceComm = LibStub:GetLibrary("AceComm-3.0")
    LibDeflate = LibStub:GetLibrary("LibDeflate", true)  -- optional

    if not AceSerializer then
        PK:Print("ERROR: AceSerializer-3.0 not found. Guild sync disabled.")
        return false
    end
    if not AceComm then
        PK:Print("ERROR: AceComm-3.0 not found. Guild sync disabled.")
        return false
    end

    -- Register our addon message prefix
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(ADDON_PREFIX)
    end

    -- Register AceComm callback for incoming messages
    AceComm.RegisterComm(PK, ADDON_PREFIX, function(prefix, message, distribution, sender)
        PK:OnCommReceived(prefix, message, distribution, sender)
    end)

    PK:Debug("Comm layer initialized (prefix=" .. ADDON_PREFIX .. ")")
    PK.commReady = true
    return true
end

----------------------------------------------------------------------
-- Serialization & compression pipeline
----------------------------------------------------------------------

--- Serialize and optionally compress a message envelope.
--- Returns the wire-format string ready for AceComm.
local function EncodeMessage(envelope)
    local serialized = AceSerializer:Serialize(envelope)

    -- Try to compress if LibDeflate is available and payload is large enough
    if LibDeflate and #serialized > COMPRESS_THRESHOLD then
        local compressed = LibDeflate:CompressDeflate(serialized)
        if compressed then
            local encoded = LibDeflate:EncodeForWoWAddonChannel(compressed)
            if encoded and #encoded < #serialized then
                return "Z" .. encoded
            end
        end
    end

    return "U" .. serialized
end

--- Decode a wire-format string back into the message envelope.
local function DecodeMessage(wireData)
    if not wireData or #wireData < 2 then
        return nil, "Message too short"
    end

    local prefix = wireData:sub(1, 1)
    local payload = wireData:sub(2)

    local serialized
    if prefix == "Z" then
        -- Compressed
        if not LibDeflate then
            return nil, "LibDeflate not available for decompression"
        end
        local decoded = LibDeflate:DecodeForWoWAddonChannel(payload)
        if not decoded then
            return nil, "Failed to decode compressed message"
        end
        serialized = LibDeflate:DecompressDeflate(decoded)
        if not serialized then
            return nil, "Failed to decompress message"
        end
    elseif prefix == "U" then
        -- Uncompressed
        serialized = payload
    else
        return nil, "Unknown message prefix: " .. prefix
    end

    local ok, envelope = AceSerializer:Deserialize(serialized)
    if not ok then
        return nil, "Deserialization failed: " .. tostring(envelope)
    end

    return envelope
end

----------------------------------------------------------------------
-- Send messages
----------------------------------------------------------------------

--- Send a message to the guild channel (broadcast).
function PK:SendGuildMessage(msgType, payload, priority)
    if not self.commReady then return end

    local envelope = {
        t = msgType,
        v = PROTOCOL_VERSION,
        p = payload or {},
    }

    local wireData = EncodeMessage(envelope)
    AceComm:SendCommMessage(ADDON_PREFIX, wireData, "GUILD", nil, priority or PRIO_NORMAL)
    PK:Debug("Sent " .. msgType .. " to GUILD (" .. #wireData .. " bytes)")
end

--- Send a message to a specific player (point-to-point).
function PK:SendWhisperMessage(msgType, payload, target, priority)
    if not self.commReady then return end
    if not target then return end

    local envelope = {
        t = msgType,
        v = PROTOCOL_VERSION,
        p = payload or {},
    }

    local wireData = EncodeMessage(envelope)
    AceComm:SendCommMessage(ADDON_PREFIX, wireData, "WHISPER", target, priority or PRIO_NORMAL)
    PK:Debug("Sent " .. msgType .. " to " .. target .. " (" .. #wireData .. " bytes)")
end

--- Send chunked data to a specific player (for large sync responses).
--- memberData: { [memberKey] = entryData, ... }
--- Splits into batches of SYNC_CHUNK_SIZE and sends at BULK priority.
function PK:SendChunked(msgType, memberData, target)
    if not self.commReady then return end
    if not target then return end

    -- Collect and sort member keys for deterministic chunking
    local keys = {}
    for k in pairs(memberData) do
        table.insert(keys, k)
    end
    table.sort(keys)

    local totalMembers = #keys
    local totalChunks = math.ceil(totalMembers / SYNC_CHUNK_SIZE)

    for i = 1, totalMembers, SYNC_CHUNK_SIZE do
        local chunk = {}
        local chunkEnd = math.min(i + SYNC_CHUNK_SIZE - 1, totalMembers)
        for j = i, chunkEnd do
            chunk[keys[j]] = memberData[keys[j]]
        end

        local chunkIndex = math.ceil(i / SYNC_CHUNK_SIZE)
        local payload = {
            data       = chunk,
            chunkIndex = chunkIndex,
            chunkTotal = totalChunks,
        }

        self:SendWhisperMessage(msgType, payload, target, PRIO_BULK)
    end

    PK:Debug("Sent " .. totalChunks .. " chunk(s) of " .. msgType .. " to " .. target
        .. " (" .. totalMembers .. " members)")
end

----------------------------------------------------------------------
-- Receive messages
----------------------------------------------------------------------

function PK:OnCommReceived(prefix, message, distribution, sender)
    if prefix ~= ADDON_PREFIX then return end

    -- Ignore messages from ourselves
    local myName = UnitName("player")
    if sender == myName then return end

    -- Decode the message
    local envelope, err = DecodeMessage(message)
    if not envelope then
        PK:Debug("Failed to decode message from " .. sender .. ": " .. tostring(err))
        return
    end

    -- Version check
    if envelope.v and envelope.v > PROTOCOL_VERSION then
        -- Newer protocol — we may not understand all messages
        PK:Debug("Received message with newer protocol v" .. envelope.v .. " from " .. sender)
    end

    local msgType = envelope.t
    local payload = envelope.p or {}

    PK:Debug("Received " .. tostring(msgType) .. " from " .. sender .. " via " .. distribution)

    -- Dispatch to registered handler
    local handler = messageHandlers[msgType]
    if handler then
        handler(self, sender, payload, distribution)
    else
        PK:Debug("No handler for message type: " .. tostring(msgType))
    end
end

----------------------------------------------------------------------
-- Utility: get the player's short name (without realm for same-realm)
----------------------------------------------------------------------

function PK:GetShortName(fullName)
    if not fullName then return nil end
    local name = fullName:match("^([^%-]+)")
    return name or fullName
end

--- Get the full Name-Realm for sending whispers
function PK:GetFullName(name)
    if not name then return nil end
    if name:find("-") then return name end
    return name .. "-" .. GetRealmName()
end
