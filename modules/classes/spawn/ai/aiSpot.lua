local visualized = require("modules/classes/spawn/visualized")
local style = require("modules/ui/style")
local utils = require("modules/utils/utils")
local gameUtils = require("modules/utils/gameUtils")
local history = require("modules/utils/history")
local cache = require("modules/utils/cache")
local builder = require("modules/utils/entityBuilder")
local Cron = require("modules/utils/Cron")
local settings = require("modules/utils/settings")
local config = require("modules/utils/config")

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

local function normalizeRigPath(path)
    if not path or path == "" then
        return nil
    end

    local normalized = tostring(path):gsub("/", "\\")
    normalized = normalized:gsub("^%s+", ""):gsub("%s+$", "")
    if normalized == "" then
        return nil
    end

    return normalized:lower()
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

local function getWorkspotRigsFromStore(workspotPath)
    loadWorkspotRigStore()
    local normalizedPath = normalizeRigPath(workspotPath)
    if not normalizedPath then
        return nil
    end

    local rigs = workspotRigStore.workspots[normalizedPath]
    if type(rigs) ~= "table" then
        return nil
    end

    return utils.deepcopy(rigs)
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
        local record = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", "")
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
local aiSpot = setmetatable({}, { __index = visualized })

function aiSpot:new()
	local o = visualized.new(self)

    o.spawnListType = "list"
    o.dataType = "AI Spot"
    o.spawnDataPath = "data/spawnables/ai/aiSpot/"
    o.modulePath = "ai/aiSpot"
    o.node = "worldAISpotNode"
    o.description = "Defines a spot at which NPCs use a workspot. Must be used together with a community node."
    o.icon = IconGlyphs.MapMarkerStar

    o.previewed = true
    o.previewColor = "fuchsia"

    o.previewNPC = settings.defaultAISpotNPC
    o.previewNPCSearch = ""
    o.spawnNPC = true
    o.workspotSpeed = settings.defaultAISpotSpeed

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

    o.assetPreviewType = "position"

    o.streamingMultiplier = 5

    setmetatable(o, { __index = self })
   	return o
end

function aiSpot:loadSpawnData(data, position, rotation)
    visualized.loadSpawnData(self, data, position, rotation)

    self.previewNPC = string.gsub(self.previewNPC, "[\128-\255]", "")
    self.previewNPCSearch = self.previewNPCSearch or ""
    self.previewNPCSearch = string.gsub(self.previewNPCSearch, "[\128-\255]", "")
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

    npc:SetIndividualTimeDilation("", self.workspotSpeed)
end

function aiSpot:onAssemble(entity)
    visualized.onAssemble(self, entity)

    local component = entity:FindComponentByName("workspot")
    component.workspotResource = ResRef.FromString(self.spawnData)

    if self.spawnNPC then
        local spec = DynamicEntitySpec.new()
        spec.recordID = self.previewNPC
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

        if #previewRigs > 0 and not isRecordSupportedForRigs(self.previewNPC, previewRigs) then
            local compatibleRecords = getCompatibleRecordsForRigs(previewRigs)
            local fallbackRecord = compatibleRecords[1]
            if fallbackRecord and fallbackRecord ~= "" then
                self.previewNPC = fallbackRecord
            end
        end
    end

    self.spawnData = "base\\spawner\\workspot_device.ent"

    visualized.spawn(self)
    self.spawnData = workspot

    local rigCacheKey = self.spawnData .. "_rigs"
    local infiniteCacheKey = self.spawnData .. "_infinite"
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
    end

    local function resolveFromLegacy(task, needsRigs, needsInfinite)
        if not needsRigs and not needsInfinite then
            task:taskCompleted()
            return
        end

        local finished = false
        local function complete(rigs, infinite)
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
                    if isSequence and entry.loopInfinitely then
                        infinite = true
                        break
                    end
                end
            end

            complete(rigs, infinite)
        end

        -- Prevent task deadlock if resource callbacks never arrive.
        Cron.After(2.5, function ()
            complete({}, false)
        end)

        local okLoad = pcall(function ()
            builder.registerLoadResource(self.spawnData, function(resource)
                local okParse = pcall(function ()
                    parseResource(resource)
                end)
                if not okParse then
                    complete({}, false)
                end
            end)
        end)

        if not okLoad then
            complete({}, false)
        end
    end

    if staticRigs then
        -- Infinite priority: cache first, then legacy fallback.
        cache.tryGet(infiniteCacheKey)
        .notFound(function (task)
            resolveFromLegacy(task, false, true)
        end)
        .found(function ()
            applyResolvedValues()
        end)
    else
        -- Rigs priority: cache first only when static entry is missing.
        cache.tryGet(rigCacheKey, infiniteCacheKey)
        .notFound(function (task)
            local needsRigs = cache.getValue(rigCacheKey) == nil
            local needsInfinite = cache.getValue(infiniteCacheKey) == nil
            resolveFromLegacy(task, needsRigs, needsInfinite)
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

    Cron.After(0.1, function ()
        local handle = self:getNPC()
        local ent = self:getEntity()
        if not handle or not ent then return end

        Game.GetWorkspotSystem():PlayInDeviceSimple(ent, handle, false, "workspot", "", "", 0, gameWorkspotSlidingBehaviour.PlayAtResourcePosition)
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
    data.spawnNPC = self.spawnNPC
    data.workspotSpeed = self.workspotSpeed
    data.isWorkspotInfinite = self.isWorkspotInfinite
    data.isWorkspotStatic = self.isWorkspotStatic
    data.markings = utils.deepcopy(self.markings)

    return data
end

function aiSpot:draw()
    visualized.draw(self)

    if not self.maxPropertyWidth then
        self.maxPropertyWidth = utils.getTextMaxWidth({ "Visualize position", "Is Infinite", "Is Static", "Preview NPC", "Preview NPC Record", "Animation Speed"}) + 4 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
    end

    if ImGui.TreeNodeEx("Previewing Options", ImGuiTreeNodeFlags.SpanFullWidth) then
        if ImGui.TreeNodeEx("Supported Rigs", ImGuiTreeNodeFlags.SpanFullWidth) then
            for _, rig in pairs(self.rigs) do
                style.mutedText(rig)
            end

            ImGui.TreePop()
        end

        if ImGui.TreeNodeEx("NPC Appearances", ImGuiTreeNodeFlags.SpanFullWidth) then
            for _, app in pairs(self.apps) do
                style.mutedText(app)
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

        style.mutedText("Preview NPC Record")
        ImGui.SameLine()
        ImGui.SetCursorPosX(self.maxPropertyWidth)
        local finished = false
        self.previewNPC, self.previewNPCSearch, finished = style.trackedSearchDropdown(self.object, "##previewNPCRigPicker", "Character.", self.previewNPC, self.previewNPCSearch, compatibleRecords, 250)
        if finished then
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

        if self.spawnNPC then
            local npc = self:getNPC()
            local isNPC = self.previewNPC:match("^Character.")

            if isNPC then
                style.mutedText("Animation Speed")
                ImGui.SameLine()
                ImGui.SetCursorPosX(self.maxPropertyWidth)
                self.workspotSpeed, changed, _ = style.trackedDragFloat(self.object, "##workspotSpeed", self.workspotSpeed, 0.1, 0, 25, "%.2f", 60)
                style.tooltip("Speed of the animation of the NPC in the workspot. Preview only.")
                if changed then
                    npc:SetIndividualTimeDilation("", self.workspotSpeed)
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
            if ImGui.Button("Forward Workspot") and isNPC then
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
    local properties = visualized.getProperties(self)
    table.insert(properties, {
        id = self.node,
        name = self.dataType,
        defaultHeader = true,
        draw = function()
            self:draw()
        end
    })
    return properties
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
            element.groupOperationData["aiSpotGrouped"].marking, _ = ImGui.InputTextWithHint("##markings", "Marking", element.groupOperationData["aiSpotGrouped"].marking, 100)

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
