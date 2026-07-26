local spawnable = require("modules/classes/spawn/spawnable")
local visualized = require("modules/classes/spawn/visualized")
local style = require("modules/ui/style")
local visualizer = require("modules/utils/visualizer")
local utils = require("modules/utils/utils")
local lcHelper = require("modules/utils/lightChannelHelper")
local config = require("modules/utils/config")
local envProbeOptionsCache = nil
local envProbeOptionSetCache = nil
local envProbeLowerCache = nil

---Class for worldReflectionProbeNode
---@class reflection : visualized
---@field public scale {x: number, y: number, z: number}
---@field public edgeScale {x: number, y: number, z: number}
---@field private previewed boolean
---@field private ambientModes table
---@field private neighborModes table
---@field public ambientMode integer
---@field public neighborMode integer
---@field public emissiveScale number
---@field public streamingDistance number
---@field public priority number
---@field public allInShadow boolean
---@field public maxPropertyWidth number
---@field public lightChannels boolean[]
---@field public volumeChannels boolean[]
---@field private envProbeOptions string[]?
---@field private envProbeSearch string
---@field private envProbeFilterCache {query: string, results: string[]}?
local reflection = setmetatable({}, { __index = visualized })

---@param value string?
---@return string
local function normalizeProbePath(value)
    return utils.normalizePath(value, { separator = "backslash" })
end

function reflection:new()
	local o = visualized.new(self)

    o.spawnListType = "list"
    o.dataType = "Reflection Probe"
    o.spawnDataPath = "data/spawnables/meta/reflectionProbe/"
    o.modulePath = "meta/reflectionProbe"
    o.node = "worldReflectionProbeNode"
    o.description = "Places a reflection probe of variable size. Can be used to make indoors have appropriate base lighting."
    o.icon = IconGlyphs.HomeLightbulbOutline

    -- Spawn New shows a single generic entry instead of the envprobe path browser.
    -- The concrete envprobe can be changed later in node properties.
    o.collapseSpawnList = true
    o.collapsedSpawnListLabel = "Reflection Probe - Default"

    o.scale = { x = 5, y = 5, z = 5 }
    o.edgeScale = { x = 0.5, y = 0.5, z = 0.5 }
    o.previewed = true
    o.previewShape = "box"

    o.ambientModes = utils.enumTable("envUtilsReflectionProbeAmbientContributionMode")
    o.neighborModes = utils.enumTable("envUtilsNeighborMode")

    o.ambientMode = 3
    o.neighborMode = 3
    o.emissiveScale = 1
    o.streamingDistance = 50
    o.priority = 25
    o.allInShadow = false
    o.lightChannels = { true, true, true, true, true, true, true, true, true, false, false, false }
    o.volumeChannels = { true, true, true, true, true, true, true, true, true, false, false, false }

    o.maxPropertyWidth = nil
    o.envProbeOptions = nil
    o.envProbeSearch = ""
    o.envProbeFilterCache = nil

    o.uk10 = 1056
    o.uk11 = 512

    setmetatable(o, { __index = self })
   	return o
end

function reflection:loadEnvProbeOptions()
    if self.envProbeOptions then
        return
    end

    if not envProbeOptionsCache or not envProbeOptionSetCache then
        envProbeOptionsCache = {}
        envProbeOptionSetCache = {}
        envProbeLowerCache = {}
        local entries = config.loadLists(self.spawnDataPath) or {}

        for _, entry in ipairs(entries) do
            local path = normalizeProbePath(entry and entry.data and entry.data.spawnData or entry and entry.name)
            if path ~= "" then
                local key = string.lower(path)
                if not envProbeOptionSetCache[key] then
                    envProbeOptionSetCache[key] = true
                    envProbeLowerCache[path] = key
                    table.insert(envProbeOptionsCache, path)
                end
            end
        end
    end
    if not envProbeLowerCache then
        envProbeLowerCache = {}
        for _, option in ipairs(envProbeOptionsCache or {}) do
            envProbeLowerCache[option] = string.lower(option)
        end
    end

    self.envProbeOptions = envProbeOptionsCache
end

---@param searchValue string?
---@return string[]
function reflection:getFilteredEnvProbeOptions(searchValue)
    self:loadEnvProbeOptions()

    local options = self.envProbeOptions or {}
    local query = string.lower(utils.trimString(searchValue))
    if query == "" then
        self.envProbeFilterCache = {
            query = "",
            results = options
        }
        return options
    end

    local source = options
    local filterCache = self.envProbeFilterCache
    if filterCache and filterCache.results then
        local previousQuery = filterCache.query or ""
        if previousQuery ~= "" and query:sub(1, #previousQuery) == previousQuery then
            source = filterCache.results
        end
    end

    local results = {}
    for _, option in ipairs(source) do
        local optionLower = (envProbeLowerCache and envProbeLowerCache[option]) or string.lower(option)
        if string.find(optionLower, query, 1, true) then
            table.insert(results, option)
        end
    end

    self.envProbeFilterCache = {
        query = query,
        results = results
    }

    return results
end

---@return string[]
function reflection:getEnvProbeSelectorOptions()
    self:loadEnvProbeOptions()
    return self.envProbeOptions or {}
end

function reflection:onAssemble(entity)
    spawnable.onAssemble(self, entity)

    visualizer.addBox(entity, { x = self.scale.x / 2, y = self.scale.y / 2, z = self.scale.z / 2 }, "seashell")

    local component = entEnvProbeComponent.new()
    component.name = "probe"
    component.probeDataRef = ResRef.FromString(self.spawnData)
    component.priority = self.priority
    component.allInShadow = self.allInShadow
    component.size = Vector3.new(self.scale.x, self.scale.y, self.scale.z) -- Size is extents, not size
    component.edgeScale = Vector3.new(self.edgeScale.x, self.edgeScale.y, self.edgeScale.z)
    component.ambientMode = Enum.new("envUtilsReflectionProbeAmbientContributionMode", self.ambientMode)
    component.neighborMode = Enum.new("envUtilsNeighborMode", self.neighborMode)
    component.emissiveScale = self.emissiveScale
    component.streamingDistance = self.streamingDistance
    entity:AddComponent(component)

    visualizer.updateScale(entity, self:getArrowSize(), "arrows")
    visualizer.toggleAll(entity, self.previewed)
end

function reflection:spawn()
    local probe = self.spawnData
    self.spawnData = "base\\spawner\\empty_entity.ent"

    spawnable.spawn(self)
    self.spawnData = probe
end

function reflection:save()
    local data = visualized.save(self)

    data.scale = { x = self.scale.x, y = self.scale.y, z = self.scale.z }
    data.edgeScale = { x = self.edgeScale.x, y = self.edgeScale.y, z = self.edgeScale.z }
    data.ambientMode = self.ambientMode
    data.neighborMode = self.neighborMode
    data.emissiveScale = self.emissiveScale
    data.streamingDistance = self.streamingDistance
    data.allInShadow = self.allInShadow
    data.priority = self.priority
    data.lightChannels = utils.deepcopy(self.lightChannels)
    data.volumeChannels = utils.deepcopy(self.volumeChannels)

    return data
end

---@protected
function reflection:updateScale(finished)
    if finished then
        self:respawn()
        return
    end

    local entity = self:getEntity()
    if not entity then return end

    visualizer.updateScale(entity, self:getArrowSize(), "arrows")
    visualizer.updateScale(entity, { x = self.scale.x / 2, y = self.scale.y / 2, z = self.scale.z / 2 }, "box")
end

function reflection:getSize()
    return self.scale
end

function reflection:setPreview(state)
    self.previewed = state
    visualizer.toggleAll(self:getEntity(), self.previewed)
end

function reflection:draw()
    spawnable.draw(self)

    if not self.maxPropertyWidth then
        self.maxPropertyWidth = utils.getTextMaxWidth({ "Env Probe", "Visualize outline", "Ambient Mode", "Neighbor Mode", "Emissive Scale", "Streaming Distance", "Edge Scale", "Priority", "All In Shadow" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
    end

    style.mutedText("Env Probe")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    local selectorWidth = style.getMaxWidth(260)
    local selectorPixelWidth = selectorWidth * style.viewSize
    local itemWidth = math.max(80, selectorPixelWidth - (2 * ImGui.GetStyle().FramePadding.x) - ImGui.GetStyle().ItemSpacing.x)
    local selectorOptions = self:getFilteredEnvProbeOptions(self.envProbeSearch)
    local selectedProbe = normalizeProbePath(self.spawnData)
    local changed
    selectedProbe, self.envProbeSearch, changed = style.trackedSearchDropdown(
        "##envProbePath",
        "Search envprobe...",
        selectedProbe,
        self.envProbeSearch,
        selectorOptions,
        {
            element = self.object,
            width = selectorWidth,
            matchContentWidth = false,
            allowCustom = true,
            optionDisplayFn = function(optionText)
                return utils.shortenPath(optionText, itemWidth, true)
            end,
            optionTooltipFn = function(optionText)
                return optionText
            end,
            optionExistsFn = function(optionText)
                return envProbeOptionSetCache and envProbeOptionSetCache[string.lower(normalizeProbePath(optionText))] == true
            end,
            optionFilterFn = function(optionText, query)
                local optionLower = (envProbeLowerCache and envProbeLowerCache[optionText]) or string.lower(optionText)
                return string.find(optionLower, query, 1, true) ~= nil
            end,
            tooltip = "Select the envprobe resource used by this reflection probe."
        }
    )

    if changed and selectedProbe ~= "" and selectedProbe ~= self.spawnData then
        self.spawnData = selectedProbe
        self:respawn()
    end

    self:drawPreviewCheckbox("Visualize outline", self.maxPropertyWidth)

    style.mutedText("Ambient Mode")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    local value, changed = style.trackedCombo(self.object, "##ambientMode", self.ambientMode - 1, self.ambientModes, 225)
    if changed then
        self.ambientMode = value + 1
        self:respawn()
    end
    ImGui.SameLine()
    ImGui.Text(IconGlyphs.InformationOutline)
    style.tooltip("Not previewed in the editor.")

    style.mutedText("Neighbor Mode")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    local value, changed = style.trackedCombo(self.object, "##neighborMode", self.neighborMode - 1, self.neighborModes, 112)
    if changed then
        self.neighborMode = value + 1
        self:respawn()
    end

    style.mutedText("Priority")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.priority, _, finished = style.trackedIntInput(self.object, "##priority", self.priority, 0, 255, 50)
    if finished then
        self:respawn()
    end

    style.mutedText("All In Shadow")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.allInShadow, changed = style.trackedCheckbox(self.object, "##allInShadow", self.allInShadow)
    if changed then
        self:respawn()
    end

    style.mutedText("Emissive Scale")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.emissiveScale, _, finished = style.trackedDragFloat(self.object, "##emissiveScale", self.emissiveScale, 0.01, 0, 50, "%.2f", 80)
    if finished then
        self:respawn()
    end

    style.mutedText("Streaming Distance")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.streamingDistance, _, finished = style.trackedDragFloat(self.object, "##streamingDistance", self.streamingDistance, 0.1, 0, 9999, "%.1f", 80)
    if finished then
        self:respawn()
    end

    style.mutedText("Edge Scale")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.edgeScale.x, _, finished = style.trackedDragFloat(self.object, "##edgeX", self.edgeScale.x, 0.05, 0, 9999, "%.2f X", 60)
    if finished then
        self:respawn()
    end
    ImGui.SameLine()
    self.edgeScale.y, _, finished = style.trackedDragFloat(self.object, "##edgeY", self.edgeScale.y, 0.05, 0, 9999, "%.2f Y", 60)
    if finished then
        self:respawn()
    end
    ImGui.SameLine()
    self.edgeScale.z, _, finished = style.trackedDragFloat(self.object, "##edgeZ", self.edgeScale.z, 0.05, 0, 9999, "%.2f Z", 60)
    if finished then
        self:respawn()
    end

    if ImGui.TreeNodeEx("Light Channels") then
        self.lightChannels = style.drawLightChannelsSelector(self.object, self.lightChannels)
        ImGui.TreePop()
    end

    if ImGui.TreeNodeEx("Volume Channels") then
        self.volumeChannels = style.drawLightChannelsSelector(self.object, self.volumeChannels)
        ImGui.TreePop()
    end
end

function reflection:getProperties()
    local properties = spawnable.getProperties(self)
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

function reflection:getGroupedProperties()
    local properties = spawnable.getGroupedProperties(self)

    properties["visualization"] = {
		name = "Visualization",
        id = "reflection",
		data = {},
		draw = function(_, entries)
            ImGui.Text("Reflection Probe")

            ImGui.SameLine()

            ImGui.PushID("reflection")

			if ImGui.Button("Off") then
				for _, entry in ipairs(entries) do
                    if entry.spawnable.node == "worldReflectionProbeNode" then
                        entry.spawnable:setPreview(false)
                    end
				end
			end

            ImGui.SameLine()

            if ImGui.Button("On") then
				for _, entry in ipairs(entries) do
                    if entry.spawnable.node == "worldReflectionProbeNode" then
                        entry.spawnable:setPreview(true)
                    end
				end
			end

            ImGui.PopID()
		end,
		entries = { self.object }
	}
    properties["lcGrouped"] = lcHelper.getGroupedProperties(self)

    return properties
end

function reflection:export()
    local data = spawnable.export(self)
    data.type = "worldReflectionProbeNode"
    data.scale = self.scale
    data.data = {
        probeDataRef = {
            DepotPath = {
                ["$storage"] = "string",
                ["$value"] = self.spawnData
            },
        },
        edgeScale = {
			["$type"] = "Vector3",
			["X"] = self.edgeScale.x,
			["Y"] = self.edgeScale.y,
			["Z"] = self.edgeScale.z
		},
        ambientMode = self.ambientModes[self.ambientMode],
        neighborMode = self.neighborModes[self.neighborMode],
        emissiveScale = self.emissiveScale,
        streamingDistance = self.streamingDistance,
        priority = self.priority,
        allInShadow = self.allInShadow and 1 or 0,
        lightChannels = utils.buildBitfieldString(self.lightChannels, style.lightChannelEnum),
        volumeChannels = utils.buildBitfieldString(self.volumeChannels, style.lightChannelEnum)
    }

    return data
end

return reflection
