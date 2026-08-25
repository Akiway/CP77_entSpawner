local visualized = require("modules/classes/spawn/visualized")
local style = require("modules/ui/style")
local utils = require("modules/utils/core/utils")
local gameUtils = require("modules/utils/game/gameUtils")
local history = require("modules/utils/project/history")
local cache = require("modules/utils/game/cache")
local builder = require("modules/utils/game/entityBuilder")
local Cron = require("modules/utils/vendor/Cron")
local settings = require("modules/utils/core/settings")
local config = require("modules/utils/core/config")
local registry = require("modules/utils/game/nodeRefRegistry")

local characterRecords = nil
local recordRigCacheRevision = 0
local compatibleRecordsCache = {}
local recordRigStorePath = "data/static/record_rigs.json"
local recordRigStore = {
    version = 1,
    records = {}
}
local recordRigStoreLoaded = false
local workspotRigStorePath = "data/static/workspot_rigs.json"
local workspotRigStore = {
    version = 1,
    workspots = {}
}
local workspotRigStoreLoaded = false
local COMMUNITY_ATTACH_POPUP_ID = "Add Workspot To Community##wb-communityAttachPopup-wui"
local NO_WORKSPOT_RIG_KEY = "__wb_no_workspot_rig_data__"

local function normalizeRigPath(path)
    return utils.normalizePath(path, {
        separator = "backslash",
        lowercase = true,
        emptyAsNil = true
    })
end

local function normalizeRigList(rigs)
    local normalized = {}
    local dedupe = {}

    for _, rig in ipairs(rigs or {}) do
        local path = normalizeRigPath(rig)
        if path and not dedupe[path] then
            dedupe[path] = true
            table.insert(normalized, path)
        end
    end

    table.sort(normalized)
    return normalized
end

local function areRigListsEqual(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end

    local normalizedA = normalizeRigList(a)
    local normalizedB = normalizeRigList(b)

    if #normalizedA ~= #normalizedB then
        return false
    end

    for i = 1, #normalizedA do
        if normalizedA[i] ~= normalizedB[i] then
            return false
        end
    end

    return true
end

local function loadRecordRigStore()
    if recordRigStoreLoaded then
        return
    end

    local data = config.loadFile(recordRigStorePath)
    if type(data.records) == "table" then
        recordRigStore.records = data.records
    elseif type(data) == "table" and data.version == nil then
        -- Legacy direct-map shape support
        recordRigStore.records = data
    else
        recordRigStore.records = {}
    end

    -- Normalize loaded lists once to keep matching fast and consistent.
    for recordID, rigs in pairs(recordRigStore.records) do
        if type(rigs) == "table" then
            recordRigStore.records[recordID] = normalizeRigList(rigs)
        else
            recordRigStore.records[recordID] = {}
        end
    end

    recordRigStoreLoaded = true
end

local function loadWorkspotRigStore()
    if workspotRigStoreLoaded then
        return
    end

    local data = config.loadFile(workspotRigStorePath)
    if type(data.workspots) == "table" then
        workspotRigStore.workspots = data.workspots
    elseif type(data) == "table" and data.version == nil then
        -- Legacy direct-map shape support
        workspotRigStore.workspots = data
    else
        workspotRigStore.workspots = {}
    end

    local normalizedWorkspots = {}
    for workspotPath, rigs in pairs(workspotRigStore.workspots) do
        local normalizedPath = normalizeRigPath(workspotPath)
        if normalizedPath then
            if type(rigs) == "table" then
                normalizedWorkspots[normalizedPath] = normalizeRigList(rigs)
            else
                normalizedWorkspots[normalizedPath] = {}
            end
        end
    end

    workspotRigStore.workspots = normalizedWorkspots
    workspotRigStoreLoaded = true
end

local function getRecordRigsFromStore(recordID)
    loadRecordRigStore()
    local rigs = recordRigStore.records[recordID]
    if type(rigs) ~= "table" then
        return nil
    end

    return utils.deepcopy(rigs)
end

local function getWorkspotRigsFromStoreRaw(workspotPath)
    loadWorkspotRigStore()
    local normalizedPath = normalizeRigPath(workspotPath)
    if not normalizedPath then
        return nil
    end

    local rigs = workspotRigStore.workspots[normalizedPath]
    if type(rigs) ~= "table" then
        return nil
    end

    return rigs
end

local function getWorkspotRigsFromStore(workspotPath)
    local rigs = getWorkspotRigsFromStoreRaw(workspotPath)
    if type(rigs) ~= "table" then
        return nil
    end

    return utils.deepcopy(rigs)
end

local function getWorkspotRigFilterKeys(workspotPath)
    local rigs = getWorkspotRigsFromStoreRaw(workspotPath)
    if type(rigs) ~= "table" or #rigs == 0 then
        return { NO_WORKSPOT_RIG_KEY }
    end

    return rigs
end

local function getRigDisplayName(rigPath)
    local rig = tostring(rigPath or "")
    if rig == NO_WORKSPOT_RIG_KEY then
        return "No cached rig data"
    end

    local normalized = normalizeRigPath(rig)
    if not normalized then
        return utils.sanitizeText(rig)
    end

    local baseEntity = normalized:match("base\\characters\\base_entities\\([^\\]+)\\[^\\]+%.rig$")
    if baseEntity and baseEntity ~= "" then
        return baseEntity
    end

    local playerRig = normalized:match("base\\characters\\entities\\player\\([^\\]+)%.rig$")
    if playerRig and playerRig ~= "" then
        return playerRig
    end

    local workspotPropRig = normalized:match("workspot_prop_rigs\\(.+)%.rig$")
    if workspotPropRig and workspotPropRig ~= "" then
        return workspotPropRig:gsub("\\", "/")
    end

    local parent, fileName = normalized:match("([^\\]+)\\([^\\]+)%.rig$")
    if parent and fileName then
        return parent .. "/" .. fileName
    end

    return utils.getFileName(normalized)
end

local function getRigIcon(rigPath)
    local rig = tostring(rigPath or "")
    if rig == NO_WORKSPOT_RIG_KEY then
        return IconGlyphs.AlertOutline
    end

    local normalized = rig:lower():gsub("/", "\\")
    if normalized:find("\\characters\\", 1, true) then
        return IconGlyphs.Account
    end

    return IconGlyphs.PackageVariantClosed
end

local function ensureCharacterRecordsLoaded()
    if characterRecords ~= nil then
        return
    end

    characterRecords = {}
    local path = "data/spawnables/entity/records/records.txt"
    local file = io.open(path, "r")
    if not file then
        return
    end

    for line in file:lines() do
        local record = utils.trimString(line)
        if record:match("^Character%.") then
            table.insert(characterRecords, record)
        end
    end

    file:close()
    table.sort(characterRecords)
end

local function getSupportedRigCacheKey(rigs)
    local normalized = {}
    local dedupe = {}

    for _, rig in ipairs(rigs or {}) do
        local path = normalizeRigPath(rig)
        if path and not dedupe[path] then
            dedupe[path] = true
            table.insert(normalized, path)
        end
    end

    table.sort(normalized)
    return table.concat(normalized, "|")
end

local function recordRigsMatch(recordRigs, supportedRigSet)
    if not recordRigs or #recordRigs == 0 then
        return false
    end

    for _, rig in ipairs(recordRigs) do
        local normalized = normalizeRigPath(rig)
        if normalized and supportedRigSet[normalized] then
            return true
        end
    end

    return false
end

local function getCompatibleRecordsForRigs(rigs)
    ensureCharacterRecordsLoaded()
    loadRecordRigStore()

    local rigCacheKey = getSupportedRigCacheKey(rigs)
    local cachedResult = compatibleRecordsCache[rigCacheKey]
    if cachedResult and cachedResult.revision == recordRigCacheRevision then
        return cachedResult.records, cachedResult.cachedCount, cachedResult.totalCount
    end

    local supportedRigSet = {}
    for _, rig in ipairs(rigs or {}) do
        local normalized = normalizeRigPath(rig)
        if normalized then
            supportedRigSet[normalized] = true
        end
    end

    local hasSupportedRigs = next(supportedRigSet) ~= nil
    local compatibleRecords = {}
    local cachedCount = 0
    local totalCount = #(characterRecords or {})

    for _, recordID in ipairs(characterRecords or {}) do
        local recordRigs = recordRigStore.records[recordID]
        if recordRigs ~= nil then
            cachedCount = cachedCount + 1
            if not hasSupportedRigs or recordRigsMatch(recordRigs, supportedRigSet) then
                table.insert(compatibleRecords, recordID)
            end
        elseif not hasSupportedRigs then
            table.insert(compatibleRecords, recordID)
        end
    end

    compatibleRecordsCache[rigCacheKey] = {
        revision = recordRigCacheRevision,
        records = compatibleRecords,
        cachedCount = cachedCount,
        totalCount = totalCount
    }

    return compatibleRecords, cachedCount, totalCount
end

local function isRecordSupportedForRigs(recordID, rigs)
    local record = tostring(recordID or "")
    if record == "" or not record:match("^Character%.") then
        return false
    end

    local supportedRigSet = {}
    for _, rig in ipairs(rigs or {}) do
        local normalized = normalizeRigPath(rig)
        if normalized then
            supportedRigSet[normalized] = true
        end
    end

    if next(supportedRigSet) == nil then
        return true
    end

    local recordRigs = getRecordRigsFromStore(record)
    if type(recordRigs) ~= "table" or #recordRigs == 0 then
        return false
    end

    return recordRigsMatch(recordRigs, supportedRigSet)
end

---Class for worldAISpotNode
---@class aiSpot : visualized
---@field previewNPC string
---@field previewNPCSearch string
---@field previewNPCAppearance string
---@field previewNPCAppearanceSearch string
---@field spawnNPC boolean
---@field isWorkspotInfinite boolean
---@field isWorkspotStatic boolean
---@field markings table
---@field maxPropertyWidth number
---@field npcID entEntityID
---@field npcSpawning boolean
---@field cronID number
---@field workspotSpeed number
---@field rigs table
---@field apps table
---@field workspotDefInfinite boolean
---@field workSequence table
---@field communityAttachCommunity string
---@field communityAttachCommunitySearch string
---@field communityAttachEntry string
---@field communityAttachEntrySearch string
---@field communityAttachPhase string
---@field communityAttachPhaseSearch string
---@field communityAttachPeriod string
---@field communityAttachPeriodSearch string
---@field communityAttachMode string
---@field communityAttachMarking string
---@field communityAttachNodeRef string
---@field communityAttachStatus string
local aiSpot = setmetatable({}, { __index = visualized })

aiSpot.NO_WORKSPOT_RIG_KEY = NO_WORKSPOT_RIG_KEY
aiSpot.getWorkspotRigsFromStore = getWorkspotRigsFromStore
aiSpot.getWorkspotRigFilterKeys = getWorkspotRigFilterKeys
aiSpot.getRigDisplayName = getRigDisplayName
aiSpot.getRigIcon = getRigIcon

local function sanitizePreviewValue(value, fallback)
    return utils.sanitizeText(value, fallback or "")
end

---@param cname any
---@return string
local function getCNameValue(cname)
    if not cname then
        return ""
    end

    if type(cname) == "string" then
        return sanitizePreviewValue(cname, "")
    end

    local value = cname.value
    if type(value) == "string" then
        return sanitizePreviewValue(value, "")
    end

    local okName, nameValue = pcall(function ()
        return NameToString(cname)
    end)
    if okName and type(nameValue) == "string" then
        return sanitizePreviewValue(nameValue, "")
    end

    return ""
end

local function getPreviewAppearanceOptions(apps, selected)
    local options = {}
    local dedupe = {}

    for _, app in ipairs(apps or {}) do
        local clean = sanitizePreviewValue(app)
        if clean ~= "" and not dedupe[clean] then
            dedupe[clean] = true
            table.insert(options, clean)
        end
    end

    local cleanSelected = sanitizePreviewValue(selected, "")
    if cleanSelected ~= "" and not dedupe[cleanSelected] then
        table.insert(options, 1, cleanSelected)
    end

    if #options == 0 then
        table.insert(options, "default")
    end

    return options
end

local function getPreferredPreviewAppearanceOption(options)
    for _, option in ipairs(options or {}) do
        local cleanOption = sanitizePreviewValue(option, "")
        if cleanOption ~= "" and string.find(string.lower(cleanOption), "default", 1, true) then
            return cleanOption
        end
    end

    local firstOption = sanitizePreviewValue(options and options[1] or "", "")
    if firstOption ~= "" then
        return firstOption
    end

    return "default"
end

local function resolvePreferredPreviewAppearance(selected, apps)
    local cleanSelected = sanitizePreviewValue(selected, "")
    local normalizedApps = apps or {}
    local fallbackAppearance = getPreferredPreviewAppearanceOption(normalizedApps)

    if cleanSelected == "" then
        return fallbackAppearance
    end

    if #normalizedApps == 0 or utils.indexValue(normalizedApps, cleanSelected) ~= -1 then
        return cleanSelected
    end

    if string.lower(cleanSelected) == "default" then
        return fallbackAppearance
    end

    return cleanSelected
end

local function containsValue(list, value)
    return utils.indexValue(list or {}, value) ~= -1
end

local function findTargetByLabel(targets, label)
    for _, target in ipairs(targets or {}) do
        if target.label == label then
            return target
        end
    end

    return nil
end

local function ensureSelectedLabel(current, targets)
    if #targets == 0 then
        return ""
    end

    if current ~= "" and findTargetByLabel(targets, current) then
        return current
    end

    return targets[1].label
end

local function drawCommunityAttachModeTabs(currentMode, totalWidth)
    local mode = currentMode == "marking" and "marking" or "nodeRef"
    local spacing = ImGui.GetStyle().ItemSpacing.x / style.viewSize
    local availableWidth = tonumber(totalWidth) or 320
    local tabWidth = math.max(110, ((availableWidth - spacing) / 2) * style.viewSize)

    if style.switchTabButton("NodeRef##communityAttachModeNodeRef", mode == "nodeRef", tabWidth, 0) then
        mode = "nodeRef"
    end

    ImGui.SameLine()

    if style.switchTabButton("Marking##communityAttachModeMarking", mode == "marking", tabWidth, 0) then
        mode = "marking"
    end

    return mode
end

local function getCommunityTargetsForSpot(spot)
    local targets = {}
    local root = spot and spot.object and spot.object:getRootParent()
    if not root then
        return targets
    end

    for _, pathEntry in ipairs(root:getPathsRecursive(true) or {}) do
        local ref = pathEntry.ref
        if ref
            and utils.isA(ref, "spawnableElement")
            and ref.spawnable
            and ref.spawnable.modulePath == "ai/communityArea"
        then
            local label = tostring(pathEntry.path or ref:getPath() or "")
            table.insert(targets, {
                label = label,
                path = pathEntry.path,
                element = ref,
                spawnable = ref.spawnable
            })
        end
    end

    table.sort(targets, function(a, b)
        return tostring(a.label):lower() < tostring(b.label):lower()
    end)

    return targets
end

local function getEntryTargetsForCommunity(communitySpawnable)
    local targets = {}
    local entries = communitySpawnable and communitySpawnable.entries or {}

    for entryIndex, entry in ipairs(entries) do
        local entryName = sanitizePreviewValue(entry.entryName, "entry_" .. tostring(entryIndex))
        table.insert(targets, {
            label = string.format("[%d] %s", entryIndex, entryName),
            entryIndex = entryIndex,
            append = false
        })
    end

    table.insert(targets, {
        label = "+ [Entry]",
        entryIndex = nil,
        append = true
    })

    return targets
end

local function getPhaseTargetsForEntry(communitySpawnable, entrySelection)
    local targets = {}
    local entries = communitySpawnable and communitySpawnable.entries or {}
    if not entrySelection then
        return targets
    end

    if entrySelection.append then
        table.insert(targets, {
            label = "+ [Phase]",
            phaseIndex = nil,
            append = true
        })
        return targets
    end

    local entryIndex = math.max(1, tonumber(entrySelection.entryIndex) or 1)
    local entry = entries[entryIndex]
    if not entry then
        table.insert(targets, {
            label = "+ [Phase]",
            phaseIndex = nil,
            append = true
        })
        return targets
    end

    entry.phases = entry.phases or {}
    for phaseIndex, phase in ipairs(entry.phases) do
        local phaseName = sanitizePreviewValue(phase.phaseName, "phase_" .. tostring(phaseIndex))
        table.insert(targets, {
            label = string.format("[%d] %s", phaseIndex, phaseName),
            phaseIndex = phaseIndex,
            append = false
        })
    end

    table.insert(targets, {
        label = "+ [Phase]",
        phaseIndex = nil,
        append = true
    })

    return targets
end

local function getPeriodTargetsForSelection(communitySpawnable, entrySelection, phaseSelection)
    local targets = {}
    if not communitySpawnable or not entrySelection or not phaseSelection then
        return targets
    end

    if entrySelection.append or phaseSelection.append then
        table.insert(targets, {
            label = "+ [Period]",
            periodIndex = nil,
            append = true
        })
        return targets
    end

    local entry = (communitySpawnable.entries or {})[entrySelection.entryIndex]
    local phase = entry and (entry.phases or {})[phaseSelection.phaseIndex]
    local periods = phase and phase.timePeriods or {}
    local periodEnums = communitySpawnable.periodEnums or {}
    local periodEnumCount = #periodEnums

    for periodIndex, period in ipairs(periods or {}) do
        local hourLabel = tostring(period.hour or 0)
        if periodEnumCount > 0 then
            local hourIndex = math.max(1, math.min(periodEnumCount, (tonumber(period.hour) or 0) + 1))
            hourLabel = periodEnums[hourIndex] or hourLabel
        end
        table.insert(targets, {
            label = string.format("[%d] %s", periodIndex, hourLabel),
            periodIndex = periodIndex,
            append = false
        })
    end

    table.insert(targets, {
        label = "+ [Period]",
        periodIndex = nil,
        append = true
    })

    return targets
end

local function createDefaultCommunityEntry(index)
    return {
        entryName = "entry_" .. tostring(index),
        characterRecordId = "",
        initialPhaseName = "default",
        entryActiveOnStart = true,
        phases = {}
    }
end

function aiSpot:new()
	local o = visualized.new(self)

    o.spawnListType = "list"
    o.dataType = "AI Spot"
    o.spawnDataPath = "data/spawnables/ai/aiSpot/"
    o.modulePath = "ai/aiSpot"
    o.entryFilter = "workspotRig"
    o.node = "worldAISpotNode"
    o.description = "Defines a spot at which NPCs use a workspot. Must be used together with a community node."
    o.icon = IconGlyphs.MapMarkerStar

    o.previewed = true
    o.previewColor = "fuchsia"

    o.previewNPC = settings.defaultAISpotNPC
    o.previewNPCSearch = ""
    o.previewNPCAppearance = settings.defaultAISpotAppearance or "default"
    o.previewNPCAppearanceSearch = ""
    o.spawnNPC = true
    o.workspotSpeed = settings.defaultAISpotSpeed
    o.previewWorkspotFrozen = false

    o.isWorkspotInfinite = true
    o.isWorkspotStatic = false
    o.markings = {}

    o.maxPropertyWidth = nil
    o.npcID = nil
    o.npcSpawning = false
    o.cronID = nil
    o.rigs = {}
    o.apps = {}
    o.workspotDefInfinite = false
    o.workSequence = { idleAnim = "" }
    o.communityAttachCommunity = ""
    o.communityAttachCommunitySearch = ""
    o.communityAttachEntry = ""
    o.communityAttachEntrySearch = ""
    o.communityAttachPhase = ""
    o.communityAttachPhaseSearch = ""
    o.communityAttachPeriod = ""
    o.communityAttachPeriodSearch = ""
    o.communityAttachMode = "nodeRef"
    o.communityAttachMarking = ""
    o.communityAttachNodeRef = ""
    o.communityAttachStatus = ""

    o.assetPreviewType = "position"

    o.streamingMultiplier = 5

    setmetatable(o, { __index = self })
	return o
end

function aiSpot:loadSpawnData(data, position, rotation)
    visualized.loadSpawnData(self, data, position, rotation)

    self.previewNPC = utils.stripNonASCII(self.previewNPC)
    self.previewNPCAppearance = sanitizePreviewValue(self.previewNPCAppearance, settings.defaultAISpotAppearance or "default")
    self.previewNPCSearch = self.previewNPCSearch or ""
    self.previewNPCAppearanceSearch = self.previewNPCAppearanceSearch or ""
    self.previewNPCSearch = utils.stripNonASCII(self.previewNPCSearch)
    self.previewNPCAppearanceSearch = utils.stripNonASCII(self.previewNPCAppearanceSearch)
    self.communityAttachCommunity = self.communityAttachCommunity or ""
    self.communityAttachCommunitySearch = self.communityAttachCommunitySearch or ""
    self.communityAttachEntry = self.communityAttachEntry or ""
    self.communityAttachEntrySearch = self.communityAttachEntrySearch or ""
    self.communityAttachPhase = self.communityAttachPhase or ""
    self.communityAttachPhaseSearch = self.communityAttachPhaseSearch or ""
    self.communityAttachPeriod = self.communityAttachPeriod or ""
    self.communityAttachPeriodSearch = self.communityAttachPeriodSearch or ""
    self.communityAttachMode = self.communityAttachMode == "marking" and "marking" or "nodeRef"
    self.communityAttachMarking = self.communityAttachMarking or ""
    self.communityAttachNodeRef = sanitizePreviewValue(self.communityAttachNodeRef, sanitizePreviewValue(self.nodeRef, ""))
    self.communityAttachStatus = self.communityAttachStatus or ""
    if type(self.workSequence) ~= "table" then
        self.workSequence = { idleAnim = "" }
    end
    self.workSequence.idleAnim = sanitizePreviewValue(self.workSequence.idleAnim, "")
end

function aiSpot:getVisualizerSize()
    return { x = 0.15, y = 0.15, z = 0.15 }
end

function aiSpot:getSize()
    return { x = 0.02, y = 0.2, z = 0.001 }
end

function aiSpot:getBBox()
    return {
        min = { x = -0.01, y = -0.01, z = -0.005 },
        max = { x = 0.01, y = 0.01, z = 0.005 }
    }
end

function aiSpot:onNPCSpawned(npc)
    if not self.previewNPC:match("^Character.") then return end

    Game.GetWorkspotSystem():PlayInDeviceSimple(self:getEntity(), npc, false, "workspot", "", "", 0, gameWorkspotSlidingBehaviour.PlayAtResourcePosition)

    self.cronID = Cron.Every(1.25, function () --TODO: Fix this properly
        if not self.npcID or not self:isSpawned() then return end
        local npc = self:getNPC()

        if Game.GetWorkspotSystem():GetExtendedInfo(npc).exiting or not Game.GetWorkspotSystem():IsActorInWorkspot(npc) then
            Game.GetWorkspotSystem():SendFastExitSignal(npc, Vector3.new(), false, false, true)
            Cron.After(0.5, function ()
                local npc = self:getNPC()
                local ent = self:getEntity()
                if not npc or not ent then return end

                Game.GetWorkspotSystem():PlayInDeviceSimple(ent, npc, false, "workspot", "", "", 0, gameWorkspotSlidingBehaviour.PlayAtResourcePosition)
            end)
        end
    end)

    local previewSpeed = self.previewWorkspotFrozen and 0.0 or self.workspotSpeed
    npc:SetIndividualTimeDilation("", previewSpeed)
end

function aiSpot:onAssemble(entity)
    visualized.onAssemble(self, entity)

    local component = entity:FindComponentByName("workspot")
    component.workspotResource = ResRef.FromString(self.spawnData)

    if self.spawnNPC then
        self.apps = {}

        local spec = DynamicEntitySpec.new()
        spec.recordID = self.previewNPC
        spec.appearanceName = sanitizePreviewValue(self.previewNPCAppearance, "default")
        spec.position = self.position
        spec.orientation = self.rotation:ToQuat()
        spec.alwaysSpawned = true
        self.npcID = Game.GetDynamicEntitySystem():CreateEntity(spec)
        self.npcSpawning = true

        builder.registerAttachCallback(self.npcID, function (entity)
            self:onNPCSpawned(entity)
        end)

        local appCacheKey = self.previewNPC .. "_apps"
        cache.tryGet(appCacheKey)
        .notFound(function (task)
            local finished = false
            local function complete(apps)
                if finished then return end
                finished = true

                cache.addValue(appCacheKey, apps or {})
                task:taskCompleted()
            end

            local templateFlat = TweakDB:GetFlat(self.previewNPC .. ".entityTemplatePath")
            local templateHash = templateFlat and templateFlat.hash
            if not templateHash then
                complete({})
                return
            end

            local templateResRef = ResRef.FromHash(templateHash)
            local depot = Game.GetResourceDepot()
            local exists = false
            if depot then
                pcall(function ()
                    exists = depot:ResourceExists(templateResRef)
                end)
            end
            if not exists then
                complete({})
                return
            end

            local ok = pcall(function ()
                builder.registerLoadResource(templateResRef, function (resource)
                    local apps = {}
                    if resource and resource.appearances then
                        for _, appearance in ipairs(resource.appearances) do
                            if appearance and appearance.name and appearance.name.value then
                                table.insert(apps, appearance.name.value)
                            end
                        end
                    end

                    complete(apps)
                end)
            end)
            if not ok then
                complete({})
            end
        end)
        .found(function ()
            self.apps = cache.getValue(appCacheKey) or {}
            self.previewNPCAppearance = resolvePreferredPreviewAppearance(self.previewNPCAppearance, self.apps)
        end)
    end
end

function aiSpot:spawn()
    local workspot = self.spawnData

    if self.isAssetPreview then
        local previewRigs = getWorkspotRigsFromStore(workspot)
        if previewRigs == nil then
            previewRigs = cache.getValue(workspot .. "_rigs")
        end
        previewRigs = normalizeRigList(previewRigs or {})

        ensureCharacterRecordsLoaded()
        local previewRecord = sanitizePreviewValue(self.previewNPC, "")
        local isKnownRecord = previewRecord ~= "" and utils.indexValue(characterRecords or {}, previewRecord) ~= -1
        if #previewRigs > 0 and isKnownRecord and not isRecordSupportedForRigs(previewRecord, previewRigs) then
            local compatibleRecords = getCompatibleRecordsForRigs(previewRigs)
            local fallbackRecord = compatibleRecords[1]
            if fallbackRecord and fallbackRecord ~= "" then
                self.previewNPC = fallbackRecord
                self.previewNPCAppearance = "default"
                self.previewNPCAppearanceSearch = ""
                self.apps = {}
            end
        end
    end

    self.spawnData = "base\\spawner\\workspot_device.ent"

    visualized.spawn(self)
    self.spawnData = workspot

    local rigCacheKey = self.spawnData .. "_rigs"
    local infiniteCacheKey = self.spawnData .. "_infinite"
    local workSequenceCacheKey = self.spawnData .. "_workSequence"
    local staticRigs = getWorkspotRigsFromStore(self.spawnData)
    if staticRigs then
        local cachedRigs = cache.getValue(rigCacheKey)
        if not areRigListsEqual(cachedRigs, staticRigs) then
            cache.addValue(rigCacheKey, staticRigs)
        end
    end

    local function applyResolvedValues()
        if staticRigs then
            self.rigs = utils.deepcopy(staticRigs)
        else
            self.rigs = cache.getValue(rigCacheKey) or {}
        end
        self.workspotDefInfinite = cache.getValue(infiniteCacheKey) == true
        self.workSequence = cache.getValue(workSequenceCacheKey) or { idleAnim = "" }
        self.workSequence.idleAnim = sanitizePreviewValue(self.workSequence.idleAnim, "")
    end

    local function resolveFromLegacy(task, needsRigs, needsInfinite, needsWorkSequence)
        if not needsRigs and not needsInfinite and not needsWorkSequence then
            task:taskCompleted()
            return
        end

        local finished = false
        local function complete(rigs, infinite, workSequence)
            if finished then
                return
            end
            finished = true

            if needsRigs then
                cache.addValue(rigCacheKey, normalizeRigList(rigs or {}))
            end
            if needsInfinite then
                cache.addValue(infiniteCacheKey, infinite == true)
            end
            if needsWorkSequence then
                cache.addValue(workSequenceCacheKey, workSequence or { idleAnim = "" })
            end
            task:taskCompleted()
        end

        local function parseResource(resource)
            local rigs = {}
            local tree = resource and resource.workspotTree
            if tree and type(tree.finalAnimsets) == "table" then
                for _, set in pairs(tree.finalAnimsets) do
                    local hash = set and set.rig and set.rig.hash
                    if hash then
                        local okPath, path = pcall(function ()
                            return ResRef.FromHash(hash):ToString()
                        end)
                        if okPath and type(path) == "string" and path ~= "" then
                            table.insert(rigs, path)
                        end
                    end
                end
            end

            local infinite = false
            local rootEntry = tree and tree.rootEntry
            local workSequence = {
                idleAnim = getCNameValue(rootEntry and rootEntry.idleAnim)
            }
            local isContainer = false
            if rootEntry then
                pcall(function ()
                    isContainer = rootEntry:IsA("workIContainerEntry")
                end)
            end

            if isContainer and rootEntry and type(rootEntry.list) == "table" then
                for _, entry in pairs(rootEntry.list) do
                    local isSequence = false
                    pcall(function ()
                        isSequence = entry:IsA("workSequence")
                    end)
                    if isSequence then
                        if workSequence.idleAnim == "" then
                            workSequence.idleAnim = getCNameValue(entry.idleAnim)
                        end

                        if entry.loopInfinitely then
                            infinite = true
                        end

                        if infinite and workSequence.idleAnim ~= "" then
                            break
                        end
                    end
                end
            end

            complete(rigs, infinite, workSequence)
        end

        -- Prevent task deadlock if resource callbacks never arrive.
        Cron.After(2.5, function ()
            complete({}, false, { idleAnim = "" })
        end)

        local okLoad = pcall(function ()
            builder.registerLoadResource(self.spawnData, function(resource)
                local okParse = pcall(function ()
                    parseResource(resource)
                end)
                if not okParse then
                    complete({}, false, { idleAnim = "" })
                end
            end)
        end)

        if not okLoad then
            complete({}, false, { idleAnim = "" })
        end
    end

    if staticRigs then
        -- Infinite priority: cache first, then legacy fallback.
        cache.tryGet(infiniteCacheKey, workSequenceCacheKey)
        .notFound(function (task)
            local needsInfinite = cache.getValue(infiniteCacheKey) == nil
            local needsWorkSequence = cache.getValue(workSequenceCacheKey) == nil
            resolveFromLegacy(task, false, needsInfinite, needsWorkSequence)
        end)
        .found(function ()
            applyResolvedValues()
        end)
    else
        -- Rigs priority: cache first only when static entry is missing.
        cache.tryGet(rigCacheKey, infiniteCacheKey, workSequenceCacheKey)
        .notFound(function (task)
            local needsRigs = cache.getValue(rigCacheKey) == nil
            local needsInfinite = cache.getValue(infiniteCacheKey) == nil
            local needsWorkSequence = cache.getValue(workSequenceCacheKey) == nil
            resolveFromLegacy(task, needsRigs, needsInfinite, needsWorkSequence)
        end)
        .found(function ()
            applyResolvedValues()
        end)
    end
end

function aiSpot:despawn()
    visualized.despawn(self)

    if self.cronID then
        Cron.Halt(self.cronID)
        self.cronID = nil
    end

    if not self.npcID then return end

    Game.GetDynamicEntitySystem():DeleteEntity(self.npcID)
    self.npcID = nil
    self.npcSpawning = false
end

function aiSpot:getNPC()
    return gameUtils.getNPC(self.npcID)
end

function aiSpot:onEdited(edited)
    if not self:isSpawned() or not edited then return end

    local handle = self:getNPC()
    if not handle then return end

    if not self.previewNPC:match("^Character.") then
        Game.GetTeleportationFacility():Teleport(handle, self.position,  self.rotation)
        return
    end

    local cmd = AITeleportCommand.new()
    cmd.position = self.position
    cmd.rotation = self.rotation.yaw
    cmd.doNavTest = false

    handle:GetAIControllerComponent():SendCommand(cmd)

    self:playNPCPreview()
end

function aiSpot:playNPCPreview()
    Cron.After(0.1, function ()
        local handle = self:getNPC()
        local ent = self:getEntity()
        if not handle or not ent then return end

        Game.GetWorkspotSystem():PlayInDeviceSimple(ent, handle, false, "workspot", "", "", 0, gameWorkspotSlidingBehaviour.PlayAtResourcePosition)
        local idleAnim = sanitizePreviewValue(self.workSequence and self.workSequence.idleAnim, "")
        if idleAnim ~= "" then
            Game.GetWorkspotSystem():SendJumpToAnimEnt(handle, idleAnim, true)
        else
            Game.GetWorkspotSystem():SendForwardSignal(handle)
        end
    end)
end

---@return boolean
function aiSpot:hasUnsupportedPreviewRecordRig()
    local recordID = tostring(self.previewNPC or "")
    if recordID == "" or not recordID:match("^Character%.") then
        return false
    end

    local supportedRigs = normalizeRigList(self.rigs or {})
    if #supportedRigs == 0 then
        return false
    end

    return not isRecordSupportedForRigs(recordID, supportedRigs)
end

function aiSpot:save()
    local data = visualized.save(self)

    data.previewNPC = self.previewNPC
    data.previewNPCAppearance = self.previewNPCAppearance
    data.spawnNPC = self.spawnNPC
    data.workspotSpeed = self.workspotSpeed
    data.isWorkspotInfinite = self.isWorkspotInfinite
    data.isWorkspotStatic = self.isWorkspotStatic
    data.markings = utils.deepcopy(self.markings)

    return data
end

---@param communityTarget table
---@param entrySelection table
---@param phaseSelection table
---@param periodSelection table
---@return boolean success
---@return string status
function aiSpot:applyCommunityAttachment(communityTarget, entrySelection, phaseSelection, periodSelection)
    local communityElement = communityTarget and communityTarget.element
    local communitySpawnable = communityElement and communityElement.spawnable

    if not communityElement or not communitySpawnable then
        return false, "Community target is invalid."
    end

    if not entrySelection or not phaseSelection or not periodSelection then
        return false, "Entry, phase, or time period selection is invalid."
    end

    local mode = self.communityAttachMode == "marking" and "marking" or "nodeRef"
    local markingValue = sanitizePreviewValue(self.communityAttachMarking, "")
    if mode == "marking" and markingValue == "" then
        return false, "Marking value is required."
    end

    local nodeRefValue = ""
    local currentNodeRef = sanitizePreviewValue(self.nodeRef, "")
    local generatedNodeRef = false
    if mode == "nodeRef" then
        nodeRefValue = sanitizePreviewValue(self.communityAttachNodeRef, "")
        if nodeRefValue == "" then
            nodeRefValue = registry.generate(self.object)
            if nodeRefValue == "" then
                return false, "Failed to generate NodeRef for this workspot."
            end
            generatedNodeRef = true
        end
    end

    local workspotRecord = sanitizePreviewValue(self.previewNPC, "")
    local workspotAppearance = sanitizePreviewValue(self.previewNPCAppearance, "default")
    if not entrySelection.append and workspotRecord ~= "" then
        local selectedEntryIndex = math.max(1, tonumber(entrySelection.entryIndex) or 1)
        local selectedEntry = (communitySpawnable.entries or {})[selectedEntryIndex]
        local selectedEntryRecord = sanitizePreviewValue(selectedEntry and selectedEntry.characterRecordId or "", "")
        if selectedEntryRecord ~= "" and selectedEntryRecord ~= workspotRecord then
            return false, string.format(
                "Selected Community entry uses '%s', but this workspot previews '%s'. Choose a matching or empty entry.",
                selectedEntryRecord,
                workspotRecord
            )
        end
    end

    local actions = { history.getElementChange(communityElement) }
    local requiresNodeRefUpdate = mode == "nodeRef" and nodeRefValue ~= currentNodeRef
    if requiresNodeRefUpdate then
        table.insert(actions, history.getElementChange(self.object))
    end

    if #actions == 1 then
        history.addAction(actions[1])
    else
        history.addAction(history.getComposite(actions))
    end

    communitySpawnable.entries = communitySpawnable.entries or {}
    local entry
    local entryIndex
    if entrySelection.append then
        entryIndex = #communitySpawnable.entries + 1
        entry = createDefaultCommunityEntry(entryIndex)
        table.insert(communitySpawnable.entries, entry)
    else
        entryIndex = math.max(1, tonumber(entrySelection.entryIndex) or 1)
        while #communitySpawnable.entries < entryIndex do
            table.insert(communitySpawnable.entries, createDefaultCommunityEntry(#communitySpawnable.entries + 1))
        end
        entry = communitySpawnable.entries[entryIndex]
    end

    entry.entryName = sanitizePreviewValue(entry.entryName, "entry_" .. tostring(entryIndex))
    entry.characterRecordId = sanitizePreviewValue(entry.characterRecordId, "")
    entry.initialPhaseName = sanitizePreviewValue(entry.initialPhaseName, "")
    entry.entryActiveOnStart = entry.entryActiveOnStart ~= false
    entry.phases = entry.phases or {}

    local phase
    if phaseSelection.append then
        local phaseName = "phase_" .. tostring(#entry.phases + 1)
        phase = {
            phaseName = phaseName,
            appearances = {},
            timePeriods = {}
        }
        table.insert(entry.phases, phase)

        if entry.initialPhaseName == "" then
            entry.initialPhaseName = phaseName
        end
    else
        local phaseIndex = math.max(1, tonumber(phaseSelection.phaseIndex) or 1)
        while #entry.phases < phaseIndex do
            table.insert(entry.phases, {
                phaseName = "phase_" .. tostring(#entry.phases + 1),
                appearances = {},
                timePeriods = {}
            })
        end
        phase = entry.phases[phaseIndex]
    end

    phase.phaseName = sanitizePreviewValue(phase.phaseName, "default")
    phase.appearances = phase.appearances or {}
    phase.timePeriods = phase.timePeriods or {}

    local period
    if periodSelection.append or not periodSelection.periodIndex then
        period = {
            hour = 1,
            isSequence = false,
            markings = {},
            quantity = 1,
            spotNodeRefs = {}
        }
        table.insert(phase.timePeriods, period)
    else
        local periodIndex = math.max(1, tonumber(periodSelection.periodIndex) or 1)
        while #phase.timePeriods < periodIndex do
            table.insert(phase.timePeriods, {
                hour = 1,
                isSequence = false,
                markings = {},
                quantity = 1,
                spotNodeRefs = {}
            })
        end
        period = phase.timePeriods[periodIndex]
    end

    period.markings = period.markings or {}
    period.spotNodeRefs = period.spotNodeRefs or {}
    period.quantity = tonumber(period.quantity) or 1
    period.hour = tonumber(period.hour) or 1
    period.isSequence = period.isSequence == true

    local addedSpotReference = false
    if mode == "nodeRef" then
        self.communityAttachNodeRef = nodeRefValue
        if requiresNodeRefUpdate then
            self.nodeRef = nodeRefValue
            registry.invalidate()
        end

        period.markings = {}
        if not containsValue(period.spotNodeRefs, nodeRefValue) then
            table.insert(period.spotNodeRefs, nodeRefValue)
            addedSpotReference = true
        end
    else
        period.spotNodeRefs = {}
        if not containsValue(period.markings, markingValue) then
            table.insert(period.markings, markingValue)
            addedSpotReference = true
        end
    end

    local addedAppearance = false
    local assignedRecord = false

    if entry.characterRecordId == "" and workspotRecord ~= "" then
        entry.characterRecordId = workspotRecord
        assignedRecord = true
    end

    if workspotRecord ~= "" and entry.characterRecordId == workspotRecord then
        if workspotAppearance ~= "" and not containsValue(phase.appearances, workspotAppearance) then
            table.insert(phase.appearances, workspotAppearance)
            addedAppearance = true
        end
    end

    local status = addedSpotReference and "Workspot linked to selected community target." or "Workspot link already existed."
    if generatedNodeRef then
        status = status .. " NodeRef was generated."
    elseif requiresNodeRefUpdate then
        status = status .. " NodeRef was updated."
    end
    if assignedRecord then
        status = status .. " Entry record was set from the workspot."
    end
    if addedAppearance then
        status = status .. " Phase appearance was synced from the workspot."
    end

    return true, status
end

function aiSpot:drawCommunityAttachPopup()
    if not ImGui.BeginPopupModal(COMMUNITY_ATTACH_POPUP_ID, true, ImGuiWindowFlags.AlwaysAutoResize) then
        return
    end

    local baseWidth = 400
    local contentWidth = tonumber((ImGui.GetContentRegionAvail())) or 0
    local controlWidth = math.max(baseWidth, contentWidth / style.viewSize)
    local itemSpacingUnscaled = ImGui.GetStyle().ItemSpacing.x / style.viewSize
    local inlineSelectorWidth = math.max(90, (controlWidth - 2 * itemSpacingUnscaled) / 3)

    style.mutedText("Community")

    local communityTargets = getCommunityTargetsForSpot(self)
    self.communityAttachCommunity = ensureSelectedLabel(self.communityAttachCommunity, communityTargets)
    local communityOptions = {}
    for _, target in ipairs(communityTargets) do
        table.insert(communityOptions, target.label)
    end
    self.communityAttachCommunity, self.communityAttachCommunitySearch, _ = style.trackedSearchDropdown(
        "##communityAttachCommunity",
        "Search community...",
        self.communityAttachCommunity,
        self.communityAttachCommunitySearch,
        communityOptions,
        {
            width = controlWidth,
            matchContentWidth = true
        }
    )
    
    ImGui.Dummy(0, 8 * style.viewSize)

    local selectedCommunity = findTargetByLabel(communityTargets, self.communityAttachCommunity)
    local entryTargets = getEntryTargetsForCommunity(selectedCommunity and selectedCommunity.spawnable)
    self.communityAttachEntry = ensureSelectedLabel(self.communityAttachEntry, entryTargets)
    local entryOptions = {}
    for _, target in ipairs(entryTargets) do
        table.insert(entryOptions, target.label)
    end
    local selectedEntry = findTargetByLabel(entryTargets, self.communityAttachEntry)
    local phaseTargets = getPhaseTargetsForEntry(selectedCommunity and selectedCommunity.spawnable, selectedEntry)
    self.communityAttachPhase = ensureSelectedLabel(self.communityAttachPhase, phaseTargets)
    local phaseOptions = {}
    for _, target in ipairs(phaseTargets) do
        table.insert(phaseOptions, target.label)
    end
    local selectedPhase = findTargetByLabel(phaseTargets, self.communityAttachPhase)
    local periodTargets = getPeriodTargetsForSelection(selectedCommunity and selectedCommunity.spawnable, selectedEntry, selectedPhase)
    self.communityAttachPeriod = ensureSelectedLabel(self.communityAttachPeriod, periodTargets)
    local periodOptions = {}
    for _, target in ipairs(periodTargets) do
        table.insert(periodOptions, target.label)
    end
    if ImGui.BeginTable("##communityAttachInlineSelectors", 3, ImGuiTableFlags.SizingStretchSame) then
        ImGui.TableNextRow()
        ImGui.TableSetColumnIndex(0)
        style.mutedText("Entry")
        ImGui.TableSetColumnIndex(1)
        style.mutedText("Phase")
        ImGui.TableSetColumnIndex(2)
        style.mutedText("Time Period")

        ImGui.TableNextRow()
        ImGui.TableSetColumnIndex(0)
        self.communityAttachEntry, self.communityAttachEntrySearch, _ = style.trackedSearchDropdown(
            "##communityAttachEntry",
            "Search entry...",
            self.communityAttachEntry,
            self.communityAttachEntrySearch,
            entryOptions,
            {
                width = inlineSelectorWidth,
                matchContentWidth = true
            }
        )

        ImGui.TableSetColumnIndex(1)
        self.communityAttachPhase, self.communityAttachPhaseSearch, _ = style.trackedSearchDropdown(
            "##communityAttachPhase",
            "Search phase...",
            self.communityAttachPhase,
            self.communityAttachPhaseSearch,
            phaseOptions,
            {
                width = inlineSelectorWidth,
                matchContentWidth = true
            }
        )

        ImGui.TableSetColumnIndex(2)
        self.communityAttachPeriod, self.communityAttachPeriodSearch, _ = style.trackedSearchDropdown(
            "##communityAttachPeriod",
            "Search time period...",
            self.communityAttachPeriod,
            self.communityAttachPeriodSearch,
            periodOptions,
            {
                width = inlineSelectorWidth,
                matchContentWidth = true
            }
        )

        ImGui.EndTable()
    end

    selectedEntry = findTargetByLabel(entryTargets, self.communityAttachEntry)
    local effectivePhaseTargets = getPhaseTargetsForEntry(selectedCommunity and selectedCommunity.spawnable, selectedEntry)
    self.communityAttachPhase = ensureSelectedLabel(self.communityAttachPhase, effectivePhaseTargets)
    selectedPhase = findTargetByLabel(effectivePhaseTargets, self.communityAttachPhase)
    local effectivePeriodTargets = getPeriodTargetsForSelection(selectedCommunity and selectedCommunity.spawnable, selectedEntry, selectedPhase)
    self.communityAttachPeriod = ensureSelectedLabel(self.communityAttachPeriod, effectivePeriodTargets)
    local selectedPeriod = findTargetByLabel(effectivePeriodTargets, self.communityAttachPeriod)
    
    ImGui.Dummy(0, 8 * style.viewSize)

    style.mutedText("Link Type")
    self.communityAttachMode = drawCommunityAttachModeTabs(self.communityAttachMode, controlWidth)
    style.tooltip("Choose whether the workspot is added to period by NodeRef or is part of a Marking.")

    if self.communityAttachMode == "marking" then
        if sanitizePreviewValue(self.communityAttachMarking, "") == "" then
            self.communityAttachMarking = sanitizePreviewValue(self.markings and self.markings[1], "")
        end

        style.mutedText("Marking")
        self.communityAttachMarking, _, _ = style.trackedTextField(nil, "##communityAttachMarking", self.communityAttachMarking, "Marking", controlWidth)
    else
        self.communityAttachNodeRef = sanitizePreviewValue(self.communityAttachNodeRef, "")
        style.mutedText("NodeRef")
        self.communityAttachNodeRef, _, _ = style.trackedTextField(nil, "##communityAttachNodeRef", self.communityAttachNodeRef, "$/#foobar", math.max(160, controlWidth - 30))
        ImGui.SameLine()
        style.pushButtonNoBG(true)
        if ImGui.Button(IconGlyphs.ReloadAlert .. "##communityAttachGenerateNodeRef") then
            local generated = registry.generate(self.object)
            if generated ~= "" then
                self.communityAttachNodeRef = generated
            end
        end
        style.pushButtonNoBG(false)
        style.tooltip("Generate a unique NodeRef for this workspot.")

        if sanitizePreviewValue(self.communityAttachNodeRef, "") == "" then
            style.mutedText("NodeRef is empty and will be auto-generated on apply.")
        end
    end

    local canApply = selectedCommunity ~= nil and selectedEntry ~= nil and selectedPhase ~= nil and selectedPeriod ~= nil
    if self.communityAttachMode == "marking" then
        canApply = canApply and sanitizePreviewValue(self.communityAttachMarking, "") ~= ""
    end

    if self.communityAttachStatus ~= "" then
        style.mutedText(self.communityAttachStatus)
    end

    ImGui.Dummy(0, 8 * style.viewSize)
    style.pushGreyedOut(not canApply)
    if ImGui.Button("Add To Community##communityAttachApply") and canApply then
        local success, status = self:applyCommunityAttachment(selectedCommunity, selectedEntry, selectedPhase, selectedPeriod)
        self.communityAttachStatus = status or ""

        if success then
            ImGui.CloseCurrentPopup()
        end
    end
    style.popGreyedOut(not canApply)

    ImGui.SameLine()
    if ImGui.Button("Cancel##communityAttachCancel") then
        ImGui.CloseCurrentPopup()
    end

    ImGui.EndPopup()
end

function aiSpot:draw()
    visualized.draw(self)

    if not self.maxPropertyWidth then
        self.maxPropertyWidth = utils.getTextMaxWidth({ "Visualize position", "Is Infinite", "Is Static", "Preview NPC", "NPC Record", "NPC Appearance", "Animation Speed"}) + 4 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
    end

    if ImGui.TreeNodeEx("Previewing Options", ImGuiTreeNodeFlags.SpanFullWidth) then
        if ImGui.TreeNodeEx("Supported Rigs", ImGuiTreeNodeFlags.SpanFullWidth) then
            for _, rig in pairs(self.rigs) do
                style.mutedText(rig)
            end

            ImGui.TreePop()
        end

        self:drawPreviewCheckbox("Visualize position", self.maxPropertyWidth)

        style.mutedText("Preview NPC")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        self.spawnNPC, changed = style.trackedCheckbox(self.object, "##spawnNPC", self.spawnNPC)
        if changed then
            self:respawn()
        end

        local compatibleRecords, cachedRecords, totalRecords = getCompatibleRecordsForRigs(self.rigs)
        local missingRigs = totalRecords - cachedRecords
        if totalRecords > 0 then
            if #self.rigs > 0 then
                style.mutedText(string.format("Compatible Records: %d", #compatibleRecords))
            end
            if missingRigs > 0 then
                style.mutedText("Some records are missing rig entries in data/static/record_rigs.json")
            end
        end

        style.mutedText("NPC Record")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        local finished = false
        self.previewNPC, self.previewNPCSearch, finished = style.trackedSearchDropdown(
            "##previewNPCRigPicker",
            "Character.",
            self.previewNPC,
            self.previewNPCSearch,
            compatibleRecords,
            {
                element = self.object,
                width = 250,
                matchContentWidth = false,
                allowCustom = true,
                tooltip = "Select a compatible character record, or type one and choose 'Use custom: ...'."
            }
        )
        if finished then
            self.previewNPCAppearance = "default"
            self.previewNPCAppearanceSearch = ""
            self.apps = {}
            self:respawn()
        end
        local unsupportedRig = false
        local missingRecord = self.previewNPC == nil or tostring(self.previewNPC):match("^%s*$") ~= nil
        if not missingRecord then
            local ok, result = pcall(function ()
                return self:hasUnsupportedPreviewRecordRig()
            end)
            unsupportedRig = ok and result == true
        end
        if unsupportedRig then
            ImGui.SameLine()
            style.styledText(IconGlyphs.AlertOutline, 0xFF2525E5)
            style.tooltip("Unsupported rig for this record. Preview may not work correctly.")
        end
        ImGui.SameLine()
        style.pushButtonNoBG(true)
        if ImGui.Button(IconGlyphs.ContentSaveSettingsOutline) then
            settings.defaultAISpotNPC = self.previewNPC
            settings.save()
        end
        style.tooltip("Save this NPC as the default for AI Spots.")
        style.pushButtonNoBG(false)

        local previewAppOptions = getPreviewAppearanceOptions(self.apps, self.previewNPCAppearance)
        self.previewNPCAppearance = resolvePreferredPreviewAppearance(self.previewNPCAppearance, self.apps)

        style.mutedText("NPC Appearance")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        self.previewNPCAppearance, self.previewNPCAppearanceSearch, changed = style.trackedSearchDropdown(
            "##previewNPCAppPicker",
            "Search appearance...",
            self.previewNPCAppearance,
            self.previewNPCAppearanceSearch,
            previewAppOptions,
            {
                element = self.object,
                width = 250,
                matchContentWidth = true,
                allowCustom = true,
                tooltip = #self.apps > 0
                    and "Appearance used when spawning the preview NPC in this workspot. You can also type one and choose 'Use custom: ...'."
                    or "No cached appearances yet for this character record. 'default' will be used until loaded, but you can still use a custom value."
            }
        )
        if changed then
            self:respawn()
        end
        ImGui.SameLine()
        style.pushButtonNoBG(true)
        ImGui.PushID("savePreviewAppearance")
        if ImGui.Button(IconGlyphs.ContentSaveSettingsOutline) then
            settings.defaultAISpotAppearance = self.previewNPCAppearance
            settings.save()
        end
        ImGui.PopID()
        style.tooltip("Save this appearance as the default for AI Spot previews.")
        style.pushButtonNoBG(false)

        if self.spawnNPC then
            local npc = self:getNPC()
            local isNPC = self.previewNPC:match("^Character.")

            if isNPC then
                style.mutedText("Animation Speed")
                ImGui.SameLine()
                ImGui.SetCursorPosX(self.maxPropertyWidth)
                self.workspotSpeed, changed, _ = style.trackedDragFloat(self.object, "##workspotSpeed", self.workspotSpeed, 0.1, 0, 25, "%.2f", 60)
                style.tooltip("Speed of the animation of the NPC in the workspot. Preview only.")
                if changed and npc then
                    local previewSpeed = self.previewWorkspotFrozen and 0.0 or self.workspotSpeed
                    npc:SetIndividualTimeDilation("", previewSpeed)
                end
                ImGui.SameLine()
                style.pushButtonNoBG(true)

                ImGui.PushID("saveSpeed")
                if ImGui.Button(IconGlyphs.ContentSaveSettingsOutline) then
                    settings.defaultAISpotSpeed = self.workspotSpeed
                    settings.save()
                end
                ImGui.PopID()

                style.tooltip("Save this speed as the default for AI Spots.")
                style.pushButtonNoBG(false)
            end

            style.pushGreyedOut(not isNPC)
            local freezeToggleIcon = self.previewWorkspotFrozen and IconGlyphs.Play or IconGlyphs.Pause
            local nextFrozenState, freezeChanged = style.toggleButton(freezeToggleIcon .. "##workspotFreezeToggle", self.previewWorkspotFrozen)
            if freezeChanged and isNPC then
                self.previewWorkspotFrozen = nextFrozenState
                if npc then
                    local previewSpeed = self.previewWorkspotFrozen and 0.0 or self.workspotSpeed
                    npc:SetIndividualTimeDilation("", previewSpeed)
                    if self.previewWorkspotFrozen then
                        Game.GetWorkspotSystem():StopInDevice(npc)
                    else
                        self:playNPCPreview()
                    end
                end
            end
            style.tooltip(self.previewWorkspotFrozen
                and "Unfreeze preview NPC workspot animation."
                or "Freeze preview NPC workspot animation.")
            ImGui.SameLine()
            if ImGui.Button(IconGlyphs.SkipForward .. " Forward Workspot") and isNPC and npc then
                Game.GetWorkspotSystem():SendForwardSignal(npc)
            end
            style.popGreyedOut(not isNPC)
        end

        ImGui.TreePop()
    end

    style.mutedText("Is Infinite")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.isWorkspotInfinite, _ = style.trackedCheckbox(self.object, "##isWorkspotInfinite", self.isWorkspotInfinite, self.workspotDefInfinite)
    style.tooltip("If checked, the NPC will use this spot indefinitely, while streamed in.\nIf unchecked, the NPC will walk to the next spot defined in its community entry.")

    if self.workspotDefInfinite then
        ImGui.SameLine()
        style.styledText(IconGlyphs.AlertOutline, 0xFF2525E5)
        style.tooltip("This workspot file definition is infinite by default.\nSetting would not have any affect.")
    end

    style.mutedText("Is Static")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.isWorkspotStatic, _ = style.trackedCheckbox(self.object, "##isWorkspotStatic", self.isWorkspotStatic)

    if ImGui.Button("Add To Community") then
        self.communityAttachStatus = ""
        self.communityAttachNodeRef = sanitizePreviewValue(self.nodeRef, "")
        if sanitizePreviewValue(self.communityAttachMarking, "") == "" then
            self.communityAttachMarking = sanitizePreviewValue(self.markings and self.markings[1], "")
        end
        ImGui.OpenPopup(COMMUNITY_ATTACH_POPUP_ID)
    end
    style.tooltip("Open a popup to add this workspot to a Community phase/time period.")
    self:drawCommunityAttachPopup()

    if ImGui.TreeNodeEx("Markings", ImGuiTreeNodeFlags.SpanFullWidth) then
        for key, _ in pairs(self.markings) do
            ImGui.PushID(key)

            self.markings[key], _ = style.trackedTextField(self.object, "##marking", self.markings[key], "", 200)
            ImGui.SameLine()
            if ImGui.Button(IconGlyphs.Delete) then
                history.addAction(history.getElementChange(self.object))
                table.remove(self.markings, key)
            end

            ImGui.PopID()
        end

        if ImGui.Button("+") then
            history.addAction(history.getElementChange(self.object))
            table.insert(self.markings, "")
        end

        ImGui.TreePop()
    end
    style.tooltip("Still requires assigning a NodeRef to this spot.")
end

function aiSpot:getProperties()
    return self:addNodeProperty(visualized.getProperties(self))
end

function aiSpot:getGroupedProperties()
    local properties = visualized.getGroupedProperties(self)

    properties["aiSpotGrouped"] = {
		name = "AI Spot",
        id = "aiSpotGrouped",
		data = {
            marking = ""
        },
		draw = function(element, entries)
            if ImGui.Button("Remove all markings") then
                history.addAction(history.getMultiSelectChange(entries))

                for _, entry in ipairs(entries) do
                    if entry.spawnable.node == self.node then
                        entry.spawnable.markings = {}
                    end
                end
            end
            style.tooltip("Clears the markings list of all selected AISpot's.")

            ImGui.SetNextItemWidth(150 * style.viewSize)
            element.groupOperationData["aiSpotGrouped"].marking, _ = style.inputTextWithHint("##markings", "Marking", element.groupOperationData["aiSpotGrouped"].marking, 100)

            ImGui.SameLine()

            if ImGui.Button("Add Marking") then
                history.addAction(history.getMultiSelectChange(entries))

                for _, entry in ipairs(entries) do
                    if entry.spawnable.node == self.node then
                        table.insert(entry.spawnable.markings, element.groupOperationData["aiSpotGrouped"].marking)
                    end
                end

                element.groupOperationData["aiSpotGrouped"].marking = ""
            end
            style.tooltip("Adds the specified marking to the markings list of all selected AISpot's.")
        end,
		entries = { self.object }
	}

    return properties
end

function aiSpot:export()
    local markings = {}
    for _, marking in pairs(self.markings) do
        table.insert(markings, {
            ["$type"] = "CName",
            ["$storage"] = "string",
            ["$value"] = marking
        })
    end

    local data = visualized.export(self)
    data.type = "worldAISpotNode"
    data.data = {
        ["isWorkspotInfinite"] = self.isWorkspotInfinite and 1 or 0,
        ["isWorkspotStatic"] = self.isWorkspotStatic and 1 or 0,
        ["spot"] = {
            ["Data"] = {
                ["$type"] = "AIActionSpot",
                ["resource"] = {
                    ["DepotPath"] = {
                        ["$type"] = "ResourcePath",
                        ["$storage"] = "string",
                        ["$value"] = self.spawnData
                    },
                    ["Flags"] = "Soft"
                }
            }
        },
        ["markings"] = markings
    }

    return data
end

return aiSpot
