local entity = require("modules/classes/spawn/entity/entity")
local style = require("modules/ui/style")
local utils = require("modules/utils/utils")
local registry = require("modules/utils/nodeRefRegistry")
local history = require("modules/utils/history")
local visualizer = require("modules/utils/visualizer")

local POSITION_MARKER_COMPONENT = "sphere"
local POSITION_MARKER_SCALE = { x = 0.05, y = 0.05, z = 0.05 }
local POSITION_MARKER_COLOR = "blue"

local propertyNames = {
    "Device Class Name",
    "Persistent"
}

---Class for worldDeviceNode
---@class device : entity
---@field public deviceConnections {deviceClassName : string, nodeRef : string}[]
---@field public connectionNodeRefSearch table<string, string>
---@field public connectionsHeaderState boolean
---@field public persistent boolean
---@field private maxPropertyWidth number?
---@field public controllerComponent string
local device = setmetatable({}, { __index = entity })

---@param value any
---@return string
local function sanitizeConnectionValue(value)
    local sanitized = tostring(value or "")
    sanitized = sanitized:gsub("^%s+", ""):gsub("%s+$", "")
    sanitized = sanitized:gsub("[\128-\255]", "")
    return sanitized
end

function device:new()
	local o = entity.new(self)

    o.dataType = "Device"
    o.modulePath = "entity/device"
    o.spawnDataPath = "data/spawnables/entity/device/"
    o.node = "worldDeviceNode"
    o.description = "Spawns an entity (.ent), as a worldDeviceNode. This allows it to be connected to other worldDeviceNodes."
    o.previewNote = "Device connections / functionality is not previewed."

    o.icon = IconGlyphs.DesktopClassic

    o.deviceConnections = {}
    o.connectionNodeRefSearch = {}
    o.connectionsHeaderState = false
    o.persistent = false

    o.maxPropertyWidth = nil
    o.controllerComponent = ""
    o.showPositionMarker = false
    o.showDoorsHelper = true

    setmetatable(o, { __index = self })
   	return o
end

function device:updatePositionMarker()
    local entityRef = self:getEntity()
    if not entityRef then return end

    local marker = entityRef:FindComponentByName(POSITION_MARKER_COMPONENT)

    if self.showPositionMarker then
        if not marker then
            visualizer.addSphere(entityRef, POSITION_MARKER_SCALE, POSITION_MARKER_COLOR)
        else
            visualizer.updateScale(entityRef, POSITION_MARKER_SCALE, POSITION_MARKER_COMPONENT)
            marker:Toggle(true)
        end
    elseif marker then
        marker:Toggle(false)
    end
end

function device:setPositionMarkerVisible(state)
    self.showPositionMarker = state
    self:updatePositionMarker()
end

function device:onAssemble(entRef)
    entity.onAssemble(self, entRef)

    for _, component in pairs(entRef:GetComponents()) do
        if component:IsA("gameDeviceComponent") then
            -- Is used to identify the correct component for the device, which is required for loading the persistent state of the device properly.
            -- The component name is used as part of the key when storing the persistent state in the .psrep file, so it needs to be consistent and correctly set.
            -- Otherwise the game will look for the wrong component in the .psrep file and fail to load it.
            self.controllerComponent = component.name.value
        end
    end

    self:updatePositionMarker()
end

function device:save()
    local data = entity.save(self)
    data.deviceConnections = utils.deepcopy(self.deviceConnections)
    data.persistent = self.persistent
    data.controllerComponent = self.controllerComponent
    data.showPositionMarker = self.showPositionMarker
    data.showDoorsHelper = self.showDoorsHelper

    return data
end

---@param currentValue string
---@return table
function device:getConnectionNodeRefOptions(currentValue)
    registry.update()

    local options = {}
    local root = self.object and self.object:getRootParent()
    local rootRefs = root and registry.refs[root.name] or nil

    if rootRefs then
        for ref, _ in pairs(rootRefs) do
            if ref ~= self.nodeRef then
                table.insert(options, ref)
            end
        end
    end

    table.sort(options)

    local cleanCurrentValue = sanitizeConnectionValue(currentValue)
    if cleanCurrentValue ~= "" and utils.indexValue(options, cleanCurrentValue) == -1 then
        table.insert(options, 1, cleanCurrentValue)
    end

    return options
end

---@param nodeRef string
---@return string?
function device:resolveConnectionClassName(nodeRef)
    local spawnable = registry.getSpawnableByNodeRef(self.object, nodeRef)
    local className = spawnable and sanitizeConnectionValue(spawnable.deviceClassName) or ""

    if className ~= "" then
        return className
    end

    return nil
end

function device:draw()
    self:drawEntityBaseProperties()

    if not self.maxPropertyWidth then
        self.maxPropertyWidth = utils.getTextMaxWidth(propertyNames) + 4 * ImGui.GetStyle().ItemSpacing.x
    end

    style.mutedText("Persistent")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.persistent, _, _ = style.trackedCheckbox(self.object, "##persistent", self.persistent)
    if self.nodeRef == "" then
        self.persistent = false
        style.tooltip("Requires NodeRef to be set.")
    else
        style.tooltip("If true, the device will get an entry in the .psrep file. Not all devices need this, still subject to more testing.")
    end
    ImGui.SameLine()
    style.pushButtonNoBG(true)
    if ImGui.Button(IconGlyphs.Reload) then
        Game.GetPersistencySystem():ForgetObject(PersistentID.ForComponent(entEntityID.new({ hash = loadstring("return " .. utils.nodeRefStringToHashString(self.nodeRef) .. "ULL", "")() }), self.controllerComponent), true)
    end
    style.pushButtonNoBG(false)
    style.tooltip("Reloads the devices persistent state.\nApplies to the actual device in the world (Imported), not the editor.")

    self.connectionsHeaderState = ImGui.TreeNodeEx("Device Connections")

    if self.connectionsHeaderState then
        for index, connection in ipairs(self.deviceConnections) do
            ImGui.PushID(index)

            connection.deviceClassName = sanitizeConnectionValue(connection.deviceClassName)
            connection.nodeRef = sanitizeConnectionValue(connection.nodeRef)

            connection.deviceClassName, _, _ = style.trackedTextField(self.object, "##className", connection.deviceClassName, "gameDeviceComponentPS", 150)
            style.tooltip("Device class name of the connected device. Name of the gameDeviceComponentPS used in the devices gameDeviceComponent")

            ImGui.SameLine()
            local searchKey = tostring(connection)
            local searchValue = sanitizeConnectionValue(self.connectionNodeRefSearch[searchKey] or "")
            local nodeRefOptions = self:getConnectionNodeRefOptions(connection.nodeRef)
            local nodeRefChanged
            connection.nodeRef, searchValue, nodeRefChanged = style.trackedSearchDropdown(
                self.object,
                "##nodeRef",
                "Search node ref...",
                connection.nodeRef,
                searchValue,
                nodeRefOptions,
                style.getMaxWidth(250) - 30,
                true,
                true
            )
            connection.nodeRef = sanitizeConnectionValue(connection.nodeRef)
            self.connectionNodeRefSearch[searchKey] = searchValue
            style.tooltip("NodeRef of the connected device. Select one from this root group, or type and choose 'Use custom: ...'.")
            if nodeRefChanged then
                local resolvedClassName = self:resolveConnectionClassName(connection.nodeRef)
                if resolvedClassName and resolvedClassName ~= connection.deviceClassName then
                    connection.deviceClassName = resolvedClassName
                end
            end

            ImGui.SameLine()
            if style.dangerButton(IconGlyphs.DeleteOutline .. "##deleteDeviceConnection") then
                history.addAction(history.getElementChange(self.object))
                self.connectionNodeRefSearch[searchKey] = nil
                table.remove(self.deviceConnections, index)
                ImGui.PopID()
                break
            end
            style.tooltip("Delete")

            ImGui.PopID()
        end

        if ImGui.Button("+") then
            history.addAction(history.getElementChange(self.object))
            table.insert(self.deviceConnections, { deviceClassName = "", nodeRef = "" })
        end

        ImGui.TreePop()
    end

    self:drawRescaleEntityAction()
end

function device:getPSData()
    for _, data in pairs(self.instanceDataChanges) do
        if data.persistentState and data.persistentState.Data then
            self:prepareInstanceData(data.persistentState.Data)
            return data.persistentState.Data
        end
    end
end

function device:getProperties()
    local properties = entity.getProperties(self)
    table.insert(properties, {
        id = self.node .. "Visualization",
        name = "Visualization",
        defaultHeader = false,
        draw = function()
            style.mutedText("Show Position Marker")
            ImGui.SameLine()
            local changed
            self.showPositionMarker, changed = style.trackedCheckbox(self.object, "##showPositionMarkerDevice", self.showPositionMarker)
            if changed then
                self:setPositionMarkerVisible(self.showPositionMarker)
                self:respawn()
            end
            style.tooltip("Draw a sphere marker at the entity position.")

            if self.deviceClassName == "LiftControllerPS" then
                style.mutedText("Show doors helper")
                ImGui.SameLine()
                self.showDoorsHelper, _ = style.trackedCheckbox(self.object, "##showDoorsHelperDevice", self.showDoorsHelper)
                style.tooltip("Draw numbered door helper markers around the lift.")
            end
        end
    })
    return properties
end

function device:export(index, length)
    local data = entity.export(self, index, length)

    data.type = "worldDeviceNode"
    data.data.deviceConnections = {}

    local connections = {}

    -- Group by deviceClassName
    for _, connection in pairs(self.deviceConnections) do
        if not connections[connection.deviceClassName] then
            connections[connection.deviceClassName] = {}
        end

        table.insert(connections[connection.deviceClassName], connection.nodeRef)
    end

    for className, connection in pairs(connections) do
        local nodeRefs = {}

        for _, nodeRef in pairs(connection) do
            table.insert(nodeRefs, {
                ["$type"] = "NodeRef",
                ["$storage"] = "string",
                ["$value"] = nodeRef
            })
        end

        table.insert(data.data.deviceConnections, {
            ["$type"] = "worldDeviceConnections",
            ["deviceClassName"] = {
                ["$type"] = "CName",
                ["$storage"] = "string",
                ["$value"] = className
            },
            ["nodeRefs"] = nodeRefs
        })
    end

    return data
end

return device
