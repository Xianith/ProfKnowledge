# ProfKnowledge

[Download on CurseForge](https://www.curseforge.com/wow/addons/profknowledge)

A World of Warcraft (Retail) addon that tracks **profession knowledge** across all characters on your account and automatically **syncs data with guild members** who also have the addon installed.

## Features

### Account-Wide Knowledge Tracking
- Automatically scans all professions when you open a crafting window
- Tracks knowledge points spent, unspent, skill levels, and specialization tree progress for every character
- Supports all 11 primary and secondary professions: Alchemy, Blacksmithing, Enchanting, Engineering, Herbalism, Inscription, Jewelcrafting, Leatherworking, Mining, Skinning, Tailoring, Cooking, and Fishing

### Summary Window
- Portrait-style frame (matching Blizzard's `ProfessionsBookFrame` aesthetic) showing all tracked characters in a grid
- Displays knowledge spent and unspent per profession per character
- Filter by profession using the dropdown in the title bar
- Opens as a **PK tab** directly on the Professions Book for quick access
- Import/Export functionality to share data as text strings

### Spec Tree Overlays
Color-coded overlays on profession specialization tree nodes showing your alts' progress at a glance:

- **Purple circle** -- Node is fully maxed on at least one alt
- **Blue circle + rank number** -- At least one alt has partial progress; shows the highest rank across all alts below the node
- **Green circle** -- Node is purchased (first point) on an alt but has no additional ranks
- **Orange rank number** -- The character you're currently viewing is your top-ranked (or tied) character for that node; replaces Blizzard's green number

Hover over any highlighted node to see a tooltip breakdown of every alt's rank on that node.

### Guild Sync
Automatically shares profession data with guild members running ProfKnowledge:

- **Designated Router (DR) / Backup DR (BDR) election** -- Addon users are sorted alphabetically; first becomes DR, second becomes BDR. No negotiation needed.
- **Version vector sync** -- Only transfers data that has actually changed, minimizing bandwidth
- **Compressed wire format** -- Messages over 200 bytes are compressed with LibDeflate before transmission
- **Chunked responses** -- Large sync payloads are split into chunks of 10 members to avoid throttling
- **Delta updates** -- When you scan a profession, the update is broadcast to the guild immediately
- Guild roster data is stored per-guild in SavedVariables so you keep data across sessions

### Slash Commands

| Command | Description |
|---------|-------------|
| `/pk` | Toggle the summary window |
| `/pk help` | Show all available commands |
| `/pk scan` | Force re-scan current character's professions |
| `/pk list` | List all tracked characters in chat |
| `/pk export` | Export all character data to a copyable text window |
| `/pk import` | Import character data from an export string |
| `/pk delete <name>` | Remove a character from tracking |
| `/pk debug` | Toggle debug messages |
| `/pk guild` | Show guild sync status (role, online users, roster size) |
| `/pk sync` | Force a guild sync request |
| `/pk guildsync` | Toggle guild sync on/off |

## Installation

1. Download and extract into your `Interface/AddOns/` folder (or install via CurseForge)
2. The folder should be named `ProfKnowledge`
3. Log in and open any profession window -- your data will be scanned automatically
4. Click the **PK** tab on the Professions Book to view the summary, or type `/pk`

## Requirements

- **World of Warcraft Retail** (The War Within / Midnight) -- Interface version 120000+
- **Guild membership** is required for guild sync features (the rest of the addon works without a guild)

## Libraries Used

ProfKnowledge bundles the following libraries (fetched automatically by the CurseForge packager via `.pkgmeta`):

| Library | Purpose |
|---------|---------|
| [LibStub](https://www.curseforge.com/wow/addons/libstub) | Library versioning and loading |
| [CallbackHandler-1.0](https://www.curseforge.com/wow/addons/ace3) | Event callback registration |
| [ChatThrottleLib](https://www.curseforge.com/wow/addons/chatthrottlelib) | Outbound chat rate limiting to prevent disconnects |
| [AceSerializer-3.0](https://www.curseforge.com/wow/addons/ace3) | Lua table serialization for addon messages |
| [AceComm-3.0](https://www.curseforge.com/wow/addons/ace3) | Addon-to-addon communication over WoW chat channels |
| [LibDeflate](https://github.com/SafeteeWoW/LibDeflate) | DEFLATE/zlib compression for reducing sync bandwidth |

## SavedVariables

ProfKnowledge stores all data in `ProfKnowledgeDB` (a single SavedVariable shared across all characters):

- `characters` -- Per-character profession data (knowledge, skill levels, spec trees)
- `guildRoster` -- Guild sync data keyed by `"GuildName-RealmName"`
- `discoveredVariants` -- Cached expansion-specific variant skill line IDs
- `settings` -- User preferences (overlay toggle, guild sync toggle, debug mode)

## File Structure

```
ProfKnowledge/
  ProfKnowledge.toc    -- Addon metadata and load order
  Core.lua             -- Bootstrap, events, profession scanning
  Data.lua             -- Profession metadata, constants, expansion mappings
  Storage.lua          -- SavedVariables management, data access helpers
  Comm.lua             -- AceComm/AceSerializer/LibDeflate messaging layer
  Sync.lua             -- DR/BDR election, version vectors, sync protocol
  UI.lua               -- Summary window, spec tree overlays, slash commands
  Libs/                -- Embedded libraries
    embeds.xml         -- Library load manifest
```

## License

All rights reserved.
