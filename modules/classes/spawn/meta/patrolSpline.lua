local spline = require("modules/classes/spawn/meta/spline")
local style = require("modules/ui/style")
local utils = require("modules/utils/core/utils")
local history = require("modules/utils/project/history")
local registry = require("modules/utils/game/nodeRefRegistry")
local settings = require("modules/utils/core/settings")
local projectedWireframe = require("modules/utils/editor/projectedWireframe")

-- worldPatrolSplinePointTypes, in engine order. The value doubles as the CEnum member name
-- written on export and as the combo label.
local pointTypes = { "Workspot", "LookAt", "ClearLookAt" }
local pointTypeIndexByValue = {}
for index, value in ipairs(pointTypes) do
    pointTypeIndexByValue[value] = index
end

-- Hierarchy row badge per point type: the AI Spot's own icon for workspots, eyes for the
-- look-at pair.
local pointTypeIcons = {
    Workspot = IconGlyphs.MapMarkerStar,
    LookAt = IconGlyphs.EyeOutline,
    ClearLookAt = IconGlyphs.EyeOffOutline
}

local pointTypeTooltip = "What the patrolling NPC does at this point:\n"
    .. "Workspot - plays the workspot of the referenced AI Spot node.\n"
    .. "LookAt - starts looking at the referenced node, from here on.\n"
    .. "ClearLookAt - stops an earlier LookAt."

---Packs an RGBA color into the IM_COL32 (0xAABBGGRR) integer used by ImGui draw lists.
---@param r number
---@param g number
---@param b number
---@param a number?
---@return integer
local function rgba(r, g, b, a)
    return (a or 255) * 0x1000000 + b * 0x10000 + g * 0x100 + r
end

-- On-screen marker colors per point type, in two variants selected by the global "Wireframe
-- color style" setting: 1 = darker markers + white text, 2 = lighter markers + black text.
local pointLabelColors = {
    [1] = {
        Workspot = rgba(45, 140, 60),     -- dark green
        LookAt = rgba(140, 70, 160),      -- dark purple
        ClearLookAt = rgba(110, 110, 110) -- dark grey
    },
    [2] = {
        Workspot = rgba(95, 220, 95),     -- light green
        LookAt = rgba(215, 150, 235),     -- light purple
        ClearLookAt = rgba(195, 195, 195) -- light grey
    }
}
local pointLabelTextColors = {
    [1] = rgba(220, 216, 209), -- near-white
    [2] = rgba(0, 0, 0)        -- black
}

---Resolves the current point-label palette from the "Wireframe color style" setting.
---@return table colors Marker colors keyed by point type.
---@return integer textColor Badge text color.
local function getPointLabelPalette()
    local styleIndex = tonumber(settings.wireframeColorStyle) == 2 and 2 or 1
    return pointLabelColors[styleIndex], pointLabelTextColors[styleIndex]
end

---Builds the RED-JSON form of a NodeRef property. An empty ref serializes as the engine
---default (`uint64` 0), the way an unset ref is written by the editor.
---@param value string?
---@return table
local function nodeRefValue(value)
    local ref = utils.trimString(value or "")

    if ref ~= "" then
        return {
            ["$type"] = "NodeRef",
            ["$storage"] = "string",
            ["$value"] = ref
        }
    end

    return {
        ["$type"] = "NodeRef",
        ["$storage"] = "uint64",
        ["$value"] = "0"
    }
end

-- Width (unscaled) reserved for the leading index cell of each patrol point row.
local rowIndexColumnWidth = 20

---Class for worldPatrolSplineNode. Reuses the whole basic spline pipeline (path, markers,
---curve / NPC preview) for the route itself and layers the patrol data on top: an ordered
---list of point definitions, each referencing another node by NodeRef.
---
---Where along the route a patrol point sits is not stored on the node - the engine derives it
---from the world position of the referenced node - so a point only carries its type and ref.
---@class patrolSpline : spline
---@field patrolPointDefs table Ordered { pointType, node } entries mirroring `patrolPointDefs`.
local patrolSpline = setmetatable({}, { __index = spline })

function patrolSpline:new()
    local o = spline.new(self)

    o.spawnListType = "files"
    o.dataType = "Patrol Spline"
    o.spawnDataPath = "data/spawnables/meta/patrolSpline/"
    o.modulePath = "meta/patrolSpline"
    o.node = "worldPatrolSplineNode"
    o.description = "Spline describing an NPC patrol route, with an ordered list of patrol points referencing workspot / look-at nodes. Reuses the basic spline for its path and can be referenced using its NodeRef."
    o.icon = IconGlyphs.Walk

    o.previewColor = "lime"

    o.patrolPointDefs = {}

    setmetatable(o, { __index = self })
    return o
end

function patrolSpline:loadSpawnData(data, position, rotation)
    spline.loadSpawnData(self, data, position, rotation)

    self.patrolPointDefs = self:normalizePatrolPointDefs(self.patrolPointDefs)
end

---Copies the loaded point list into fresh tables, repairing anything malformed. The data handed
---to `loadSpawnData` is shared with long-lived payloads (project cache, clipboard), so its
---entries must never be aliased into the spawnable.
---@param defs table?
---@return table
function patrolSpline:normalizePatrolPointDefs(defs)
    local normalized = {}

    for _, def in ipairs(defs or {}) do
        local pointType = def.pointType
        if not pointTypeIndexByValue[pointType] then
            pointType = pointTypes[1]
        end

        table.insert(normalized, {
            pointType = pointType,
            node = utils.trimString(def.node or "")
        })
    end

    return normalized
end

---Snapshots the element for undo before a structural (add / remove / reorder) list change.
function patrolSpline:recordStructuralChange()
    if self.object then
        history.addAction(history.getElementChange(self.object))
    end
end

---Appends a patrol point and returns its new index.
---@param pointType string?
---@param node string?
---@return integer index
function patrolSpline:addPatrolPoint(pointType, node)
    self:recordStructuralChange()
    table.insert(self.patrolPointDefs, {
        pointType = pointTypeIndexByValue[pointType] and pointType or pointTypes[1],
        node = node or ""
    })

    return #self.patrolPointDefs
end

---Resolves the spawnable a patrol point references, within the same root group. Nil while the
---ref is empty or points outside this project (a vanilla node, or a typo).
---@param def table
---@return spawnable|nil
function patrolSpline:getPatrolPointTarget(def)
    local ref = utils.trimString(def and def.node or "")
    if ref == "" or not self.object then return nil end

    return registry.getSpawnableByNodeRef(self.object, ref)
end

---Resolves the world position a patrol point sits at: the position of the node its NodeRef
---points to. Nil while the ref is empty or resolves to nothing.
---@param def table
---@return Vector4|nil
function patrolSpline:getPatrolPointPosition(def)
    local target = self:getPatrolPointTarget(def)
    if not target or not target.position then return nil end

    return ToVector4(target.position)
end

---True when a Workspot point references an AI Spot left on `Is Infinite`. Such a workspot never
---releases the actor, so the NPC stops there and the rest of the route never runs. The export
---blocks on the same condition.
---@param def table
---@param target spawnable? Already-resolved target; resolved on demand when omitted.
---@return boolean
function patrolSpline:isInfiniteWorkspot(def, target)
    if not def or def.pointType ~= "Workspot" then return false end

    target = target or self:getPatrolPointTarget(def)

    return target ~= nil and target.node == "worldAISpotNode" and target.isWorkspotInfinite == true
end

---Hierarchy row summary: one "<count><type icon>" badge per point type actually in use, so the
---make-up of a route is readable without opening the node. Consumed by `spawnedUI.getStateIcons`.
---@return {icon: string, tooltip: string, color: number?}[]
function patrolSpline:getExtraStateIcons()
    local counts = {}
    local infinite = 0

    for _, def in ipairs(self.patrolPointDefs) do
        counts[def.pointType] = (counts[def.pointType] or 0) + 1
        -- Only ever true for Workspot points, so it is safe to tally in the same pass.
        if self:isInfiniteWorkspot(def) then
            infinite = infinite + 1
        end
    end

    local icons = {}
    -- Engine order rather than insertion order, so the badges never reshuffle between rows.
    for _, pointType in ipairs(pointTypes) do
        local count = counts[pointType]

        if count then
            local tooltip = string.format("%d %s patrol point%s", count, pointType, count == 1 and "" or "s")
            local color = style.mutedColor

            -- A single infinite workspot strands the NPC and kills the rest of the route, so the
            -- badge warns for the whole route as soon as one of them has it.
            if pointType == "Workspot" and infinite > 0 then
                tooltip = tooltip .. string.format("\n%d of them ha%s \"Is Infinite\" enabled, which stops the patrol there.",
                    infinite, infinite == 1 and "s" or "ve")
                color = style.warnColor
            end

            table.insert(icons, {
                icon = string.format("%d%s", count, pointTypeIcons[pointType]),
                tooltip = tooltip,
                color = color
            })
        end
    end

    return icons
end

---Whether patrol point labels should currently be drawn: only while the spline is selected or
---its preview is enabled. Used by the editor to skip opening an empty overlay.
---@return boolean
function patrolSpline:wantsViewportOverlay()
    if #self.patrolPointDefs == 0 then return false end

    return self.object ~= nil and (self.object.selected == true or self.previewed == true)
end

---Draws an on-screen label at every patrol point that resolves to a node, showing its order
---along the route and its type. Invoked once per frame by the editor viewport overlay pass.
---@param screen projectedScreenContext Projection context from `projectedWireframe.beginOverlay`.
---@param drawList table ImGui draw list from `projectedWireframe.beginOverlay`.
function patrolSpline:drawViewportOverlay(screen, drawList)
    if not self:wantsViewportOverlay() then return end

    local colors, textColor = getPointLabelPalette()

    for index, def in ipairs(self.patrolPointDefs) do
        local position = self:getPatrolPointPosition(def)

        if position then
            projectedWireframe.drawWorldMarker(drawList, screen, position, {
                color = colors[def.pointType] or colors[pointTypes[1]],
                labelColor = textColor,
                text = string.format("P%d  %s", index, def.pointType),
                radius = 5 * style.viewSize,
                innerRadius = 2.5 * style.viewSize,
                badgeOffsetY = -14 * style.viewSize,
                fontRatio = 0.85,
                clampToScreen = false
            })
        end
    end
end

function patrolSpline:draw()
    -- Reuse the entire basic spline UI (path, length, reverse, looped, previewing options).
    spline.draw(self)

    ImGui.Spacing()
    self:drawPatrolPointsSection()
end

function patrolSpline:drawPatrolPointsSection()
    if not ImGui.TreeNodeEx("Patrol Points (" .. #self.patrolPointDefs .. ")###patrolPoints", ImGuiTreeNodeFlags.SpanFullWidth) then
        return
    end

    style.mutedText("Nodes the patrolling NPC interacts with, in the order they are visited.\nWhere along the route a point sits is taken from the position of the node it references.")
    ImGui.Spacing()

    local fieldStartX = rowIndexColumnWidth * (style.viewSize or 1)
    local removeIndex = nil
    local swap = nil

    for index, def in ipairs(self.patrolPointDefs) do
        ImGui.PushID("patrolPoint" .. index)
        ImGui.AlignTextToFramePadding()
        ImGui.SetCursorPosX(8 * style.viewSize)
        style.mutedText(string.format("%d", index))
        ImGui.SameLine()
        ImGui.SetCursorPosX(fieldStartX)

        local typeIndex = pointTypeIndexByValue[def.pointType] or 1
        local newTypeIndex, typeChanged = style.trackedCombo(self.object, "##pointType", typeIndex - 1, pointTypes, 110, {
            tooltip = pointTypeTooltip
        })
        if typeChanged then
            def.pointType = pointTypes[newTypeIndex + 1] or pointTypes[1]
        end

        ImGui.SameLine()
        def.node = registry.drawNodeRefSelector(math.max(140, style.getMaxWidth(240) - 100), def.node, self.object, true)

        ImGui.SameLine()
        local target = self:getPatrolPointTarget(def)
        if not target then
            style.styledText(IconGlyphs.AlertOutline, style.warnColor)
            style.tooltip(utils.trimString(def.node) == ""
                and "No node referenced. This patrol point will do nothing in game."
                or "No node with this NodeRef exists in this root group.\nFine when the target is a vanilla node, a broken reference otherwise.")
        elseif self:isInfiniteWorkspot(def, target) then
            style.styledText(IconGlyphs.AlertOutline, style.warnColor)
            style.tooltip("This workspot has \"Is Infinite\" enabled, so the NPC never leaves it and\nthe rest of the route never runs. Disable it on the AI Spot.\nThe export blocks on this as well.")
        else
            style.styledText(IconGlyphs.CheckCircleOutline, style.mutedColor)
            style.tooltip("Resolves to a node in this root group.")
        end

        ImGui.SameLine()
        ImGui.BeginDisabled(index == 1)
        if ImGui.Button(IconGlyphs.ArrowUp) and index > 1 then
            swap = { index, index - 1 }
        end
        ImGui.EndDisabled()
        style.tooltip("Visit this point earlier")

        ImGui.SameLine()
        ImGui.BeginDisabled(index == #self.patrolPointDefs)
        if ImGui.Button(IconGlyphs.ArrowDown) and index < #self.patrolPointDefs then
            swap = { index, index + 1 }
        end
        ImGui.EndDisabled()
        style.tooltip("Visit this point later")

        ImGui.SameLine()
        if style.dangerButton(IconGlyphs.DeleteOutline) then
            removeIndex = index
        end
        style.tooltip("Remove this patrol point")

        ImGui.PopID()
    end

    -- Reorder and delete are exclusive: a swap already moved the indices the delete was aimed at.
    if swap then
        self:recordStructuralChange()
        local a, b = swap[1], swap[2]
        self.patrolPointDefs[a], self.patrolPointDefs[b] = self.patrolPointDefs[b], self.patrolPointDefs[a]
    elseif removeIndex then
        self:recordStructuralChange()
        table.remove(self.patrolPointDefs, removeIndex)
    end

    if ImGui.Button(IconGlyphs.Plus .. " Add patrol point") then
        self:addPatrolPoint()
    end

    ImGui.TreePop()
end

function patrolSpline:save()
    local data = spline.save(self)

    data.patrolPointDefs = utils.deepcopy(self.patrolPointDefs)

    return data
end

function patrolSpline:export()
    local data = spline.export(self)
    data.type = "worldPatrolSplineNode"

    local patrolPointDefs = {}
    for _, def in ipairs(self.patrolPointDefs) do
        table.insert(patrolPointDefs, {
            ["Data"] = {
                ["$type"] = "worldPatrolSplinePointDefinition",
                ["pointType"] = def.pointType,
                ["node"] = nodeRefValue(def.node)
            }
        })
    end

    data.data.patrolPointDefs = patrolPointDefs

    return data
end

return patrolSpline
