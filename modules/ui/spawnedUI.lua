local utils = require("modules/utils/utils")
local editor = require("modules/utils/editor/editor")
local settings = require("modules/utils/settings")
local style = require("modules/ui/style")
local field = require("modules/utils/field")
local history = require("modules/utils/history")
local input = require("modules/utils/input")
local registry = require("modules/utils/nodeRefRegistry")
local perf = require("modules/utils/perf")
local colorUtil = require("modules/utils/color")
local projectTagUtil = require("modules/utils/ui/projectTag")
local saveState = require("modules/utils/saveState")
-- Named `elementClass` because two dozen functions in this file take a parameter called
-- `element`, which would shadow it.
local elementClass = require("modules/classes/editor/element")
local projectLinkPopup = require("modules/utils/ui/projectLinkPopup")
local persistenceManager = require("modules/utils/pipeline/persistenceManager")
local sessionSnapshot = require("modules/utils/pipeline/sessionSnapshot")
local sessionRestorePopup = require("modules/utils/ui/sessionRestorePopup")

local wu

---@class spawnedUI
---@field root element
---@field filter string
---@field newGroupName string
---@field groupTypes string[]
---@field groupTypeIcons string[]
---@field newGroupTypeIndex number
---@field newGroupRandomized boolean
---@field spawner spawner?
---@field paths {path : string, ref : element}[]
---@field containerPaths {path : string, ref : element}[]
---@field selectedPaths {path : string, ref : element}[]
---@field filteredPaths {path : string, ref : element}[]
---@field visiblePaths {path : string, ref : element, depth : number}[]
---@field scrollToSelected boolean
---@field openContextMenu {state : boolean, path : string}
---@field clipboard table Serialized elements
---@field elementCount number
---@field dividerHovered boolean
---@field dividerDragging boolean
---@field filteredWidestName number
---@field draggingSelected boolean
---@field infoWindowSize table
---@field nameBeingEdited boolean
---@field clipper any
---@field visiblePathIndexById table<number, number>
---@field hierarchyFirstVisibleIndexById table<string, number>
---@field stickyRowCountById table<string, number>
---@field stickyRowPendingById table<string, {count: number, streak: number}>
---@field hoveredEntries element[]
---@field pinnedHierarchy {open: boolean, groupId: number?}
---@field reorderPreview {x1: number, x2: number, y: number}?
spawnedUI = {
    root = require("modules/classes/editor/element"):new(spawnedUI),
    multiSelectGroup = require("modules/classes/editor/positionableGroup"):new(spawnedUI),
    filter = "",
    newGroupName = "New_Group",
    groupTypes = { "Normal", "Randomized", "Scattered" },
    groupTypeIcons = { IconGlyphs.FolderOutline, IconGlyphs.Dice5Outline, IconGlyphs.DiceMultipleOutline },
    newGroupTypeIndex = 1,
    newGroupRandomized = false,
    spawner = nil,

    paths = {},
    containerPaths = {},
    selectedPaths = {},
    filteredPaths = {},
    visiblePaths = {},
    scrollToSelected = false,
    openContextMenu = {
        state = false,
        path = ""
    },
    nameBeingEdited = false,
    hierarchyPickRequest = nil,
    pinnedHierarchy = {
        open = false,
        groupId = nil
    },

    clipboard = {},

    elementCount = 0,
    dividerHovered = false,
    dividerDragging = false,
    filteredWidestName = 0,
    draggingSelected = false,
    infoWindowSize = { x = 0, y = 0 },

    clipper = nil,
    visiblePathIndexById = {},
    hierarchyFirstVisibleIndexById = {},
    stickyRowCountById = {},
    stickyRowPendingById = {},
    hoveredEntries = {},
    reorderPreview = nil,

    lockedChildrenCache = {},
    cacheDirty = true,
    lastCachedFilter = nil,
    cacheEpoch = 0,
    wireframeEpoch = 0,
    boundaryOrientationEpoch = 0,
    stateIconCacheEpoch = -1,
    stateIconWireframeEpoch = -1,
    stateIconGroupMarkerStateById = {},
    stateIconValidSplinePathsByRoot = {},
    stateIconValidOutlinePathsByRoot = {},
    stateIconConnectionCountByRoot = {},
    stateIconSelectedGroupRef = nil,
    stateIconPlayerPosition = nil,
    stateIconIconWidthByGlyph = {},
    stateIconWidthCacheViewSize = nil,
    modifierState = {
        ctrl = false,
        shift = false
    }
}

-- spawnedUI is assigned after the table literal is evaluated, so objects created
-- inside it receive a nil sUI during construction. Rebind them explicitly.
spawnedUI.root.sUI = spawnedUI
spawnedUI.multiSelectGroup.sUI = spawnedUI

local HIERARCHY_PICK_ELIGIBLE_BG = 0x5F007F00
local HIERARCHY_PICK_ELIGIBLE_HOVER = 0xAA50FF50
local HIERARCHY_PICK_ELIGIBLE_ACTIVE = 0xCC50FF50
local HIERARCHY_REORDER_PREVIEW_SHADOW = 0x88000000
local MAX_STICKY_PARENT_ROWS = 5
-- How many consecutive frames a new sticky-row count must be observed before it's
-- committed to spawnedUI.stickyRowCountById (which resizes the scrollable child next
-- frame). Resizing that child changes its own scrollbar geometry, which can perturb
-- ImGui's scroll offset while the user is actively dragging the scrollbar thumb; requiring
-- a stable reading first (and never committing at all while a mouse button is held, see
-- below) prevents that resize from feeding back into the very position that triggered it.
local STICKY_RESERVE_CONFIRM_FRAMES = 2

---@param index number
---@param stableId string?
---@return string
local function getGroupTypeLabel(index, stableId)
    local name = spawnedUI.groupTypes[index] or ""
    local icon = spawnedUI.groupTypeIcons[index] or ""
    local label = style.resolveActionLabelNoIconOnly(icon, name, stableId)
    return label
end

---@return string[]
local function getGroupTypeLabels()
    local labels = {}
    for index = 1, #spawnedUI.groupTypes do
        labels[index] = getGroupTypeLabel(index)
    end
    return labels
end

---@param element element?
---@return boolean
function spawnedUI.canToggleVisibility(element)
    return element ~= nil
end

---@param element element?
---@return boolean
function spawnedUI.canToggleVisualization(element)
    if element == nil or not utils.isA(element, "spawnableElement") or element.spawnable == nil then
        return false
    end

    return type(element.spawnable.setPreview) == "function" and element.spawnable.previewed ~= nil
end

---@param element element?
---@return boolean
function spawnedUI.canMutateLockedState(element)
    return element ~= nil and not element.lockedByParent
end

---@param elements element[]
---@param apply fun(PARAM: element)
---@return boolean
local function applyElementChangesBatched(elements, apply)
    local normalized = history.normalizeElements(elements)
    local allChanges = history.getElementChanges(normalized)
    local changedActions = {}

    for idx, entry in ipairs(normalized) do
        local before = entry:serialize()
        apply(entry)
        local after = entry:serialize()

        if not utils.deepcompare(before, after, true) then
            table.insert(changedActions, allChanges[idx])
        end
    end

    if #changedActions == 0 then
        return false
    end

    history.addAction(history.getComposite(changedActions))

    return true
end

---@return boolean
local function selectedVisualizersEnabled()
    return settings.selectedVisualizersEnabled ~= false
end

local function refreshSelectedVisualizers()
    spawnedUI.ensureCache()
    local selectedCount = #spawnedUI.selectedPaths
    local keepSelectedVisualizers = selectedVisualizersEnabled()

    for _, entry in ipairs(spawnedUI.selectedPaths) do
        local element = entry.ref

        if utils.isA(element, "positionable") then
            local showOnHover = settings.gizmoOnHover and (element.hovered or element.controlsHovered)
            local showOnSelected = keepSelectedVisualizers and settings.gizmoOnSelected and selectedCount == 1
            local keepVisible = showOnHover or showOnSelected

            element:setVisualizerState(keepVisible)
            if not element.visualizerState then
                element:setVisualizerDirection("none")
            end
        end

        if utils.isA(element, "spawnableElement") and element.spawnable and element.spawnable:isSpawned() then
            local outline = settings.outlineSelected and keepSelectedVisualizers and element.selected and (settings.outlineColor + 1) or 0
            element.spawnable:setOutline(outline)
        end
    end
end

---@return {arrowValue: string, arrowColor: number, outlineValue: string, outlineColor: number}
local function getSelectedVisualizerToggleTooltip()
    local keepSelectedVisualizers = selectedVisualizersEnabled()
    local colorGreen = 0xFF00FF00
    local colorRed = 0xFF0000FF

    local arrowValue, arrowColor
    if not keepSelectedVisualizers then
        arrowValue = "disabled"
        arrowColor = colorRed
    elseif settings.gizmoOnHover and settings.gizmoOnSelected then
        arrowValue = "on hover + when selected"
        arrowColor = colorGreen
    elseif settings.gizmoOnHover then
        arrowValue = "on hover only"
        arrowColor = style.warnColor
    elseif settings.gizmoOnSelected then
        arrowValue = "when selected only"
        arrowColor = style.warnColor
    else
        arrowValue = "disabled"
        arrowColor = colorRed
    end

    local outlineValue, outlineColor
    if not keepSelectedVisualizers or not settings.outlineSelected then
        outlineValue = "disabled"
        outlineColor = colorRed
    else
        outlineValue = "when selected"
        outlineColor = colorGreen
    end

    return {
        arrowValue = arrowValue,
        arrowColor = arrowColor,
        outlineValue = outlineValue,
        outlineColor = outlineColor
    }
end

local function drawSelectedVisualizerToggleTooltip()
    if not ImGui.IsItemHovered() then
        return
    end

    local tooltip = getSelectedVisualizerToggleTooltip()
    local onColor = 0xFF00FF00
    local offColor = 0xFF0000FF
    local scale = style.viewSize or 1
    local screenWidth, screenHeight = GetDisplayResolution()
    local margin = 8 * scale
    local maxTooltipWidth = math.max(300 * scale, math.min(620 * scale, screenWidth - margin * 2))
    local maxTooltipHeight = math.max(180 * scale, screenHeight - margin * 2)

    local function drawSettingStateRow(label, enabled)
        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.TextWrapped(label)
        ImGui.TableNextColumn()
        style.styledText(enabled and "ON" or "OFF", enabled and onColor or offColor)
    end

    local function drawExpectationRow(label, value, color)
        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text(label)
        ImGui.TableNextColumn()
        style.styledText(value, color)
    end

    ImGui.SetNextWindowSizeConstraints(220 * scale, 1, maxTooltipWidth, maxTooltipHeight)
    ImGui.BeginTooltip()
    ImGui.PushStyleColor(ImGuiCol.Text, style.regularColor)
    ImGui.Text("Show or hide positioning helpers.")
    ImGui.Spacing()
    style.mutedText("Hiding the helpers will override your settings.")
    ImGui.Spacing()
    ImGui.Text("Current expectation:")

    if ImGui.BeginTable("##selectedVisualizerExpectations", 2, ImGuiTableFlags.SizingStretchSame + ImGuiTableFlags.BordersInnerV) then
        ImGui.TableSetupColumn("Positioning helper")
        ImGui.TableSetupColumn("Visibility")
        ImGui.TableHeadersRow()

        drawExpectationRow("Arrows", tooltip.arrowValue, tooltip.arrowColor)
        drawExpectationRow("Outline", tooltip.outlineValue, tooltip.outlineColor)

        ImGui.EndTable()
    end
    
    ImGui.Dummy(0, 8 * style.viewSize)

    style.mutedText("Helpers visibility depends on the following settings:")
    if ImGui.BeginTable("##selectedVisualizerStates", 2, ImGuiTableFlags.SizingStretchSame + ImGuiTableFlags.BordersInnerV) then
        local settingColumnLabel = style.resolveActionLabelNoIconOnly(IconGlyphs.CogOutline, "Setting", nil)
        ImGui.TableSetupColumn(settingColumnLabel)
        ImGui.TableSetupColumn("Value")
        ImGui.TableHeadersRow()

        drawSettingStateRow("Arrows on hover", settings.gizmoOnHover == true)
        drawSettingStateRow("Arrows when selected", settings.gizmoOnSelected == true)
        drawSettingStateRow("Outline when selected", settings.outlineSelected == true)

        ImGui.EndTable()
    end
    local settingsTabLabel = style.resolveActionLabelNoIconOnly(IconGlyphs.CogOutline, "Settings tab", nil)
    style.styledTextWrapped("These settings are configurable in the " .. settingsTabLabel .. ", under Visualizers section.", style.mutedColor)
    ImGui.PopStyleColor()
    ImGui.EndTooltip()
end

---@param root element
---@return boolean
local function cacheLockedChildrenRecursive(root)
    local hasLockedDescendant = false

    for _, child in pairs(root.childs) do
        local childSubtreeHasLocked = cacheLockedChildrenRecursive(child)
        if child:isLocked() or childSubtreeHasLocked then
            hasLockedDescendant = true
        end
    end

    spawnedUI.lockedChildrenCache[root.id] = hasLockedDescendant
    return hasLockedDescendant
end

---@param parent element
---@param depth number
---@param pathById table<number, string>
local function cacheVisiblePathsRecursive(parent, depth, pathById)
    for _, child in pairs(parent.childs) do
        local entryPath = pathById[child.id] or child:getPath()
        table.insert(spawnedUI.visiblePaths, {
            path = entryPath,
            ref = child,
            depth = depth
        })
        spawnedUI.visiblePathIndexById[child.id] = #spawnedUI.visiblePaths

        if child.expandable and child.headerOpen then
            cacheVisiblePathsRecursive(child, depth + 1, pathById)
        end
    end
end

---Rebuilds hierarchy cache state (paths, selections, filters, lock-descendant cache).
function spawnedUI.cachePaths()
    spawnedUI.paths = {}
    spawnedUI.containerPaths = {}
    spawnedUI.selectedPaths = {}
    spawnedUI.filteredPaths = {}
    spawnedUI.visiblePaths = {}
    spawnedUI.visiblePathIndexById = {}
    spawnedUI.lockedChildrenCache = {}
    spawnedUI.filteredWidestName = 0
    spawnedUI.nameBeingEdited = false
    local pathById = {}

    for _, path in pairs(spawnedUI.root:getPathsRecursive(true)) do
        table.insert(spawnedUI.paths, {
            path = path.path,
            ref = path.ref
        })
        pathById[path.ref.id] = path.path

        if path.ref.expandable then
            table.insert(spawnedUI.containerPaths, {
                path = path.path,
                ref = path.ref
            })
        end
        if path.ref.selected then
            table.insert(spawnedUI.selectedPaths, {
                path = path.path,
                ref = path.ref
            })
        end
        if spawnedUI.filter ~= "" and not path.ref.expandable and utils.matchSearch(path.ref.name, spawnedUI.filter) then
            table.insert(spawnedUI.filteredPaths, {
                path = path.path,
                ref = path.ref,
                depth = 0
            })
            spawnedUI.filteredWidestName = math.max(spawnedUI.filteredWidestName, ImGui.CalcTextSize(path.ref.name))
        end
        if path.ref.editName then
            spawnedUI.nameBeingEdited = true
        end
    end

    cacheVisiblePathsRecursive(spawnedUI.root, 0, pathById)
    cacheLockedChildrenRecursive(spawnedUI.root)

    spawnedUI.cacheDirty = false
    spawnedUI.lastCachedFilter = spawnedUI.filter
    spawnedUI.cacheEpoch = spawnedUI.cacheEpoch + 1
end

---@param registryAffected boolean?
function spawnedUI.invalidateCache(registryAffected)
    spawnedUI.cacheDirty = true

    if registryAffected then
        registry.invalidate()
    end
end

function spawnedUI.bumpWireframeEpoch()
    spawnedUI.wireframeEpoch = (spawnedUI.wireframeEpoch or 0) + 1
end

---@return boolean rebuilt
function spawnedUI.ensureCache()
    if spawnedUI.filter ~= spawnedUI.lastCachedFilter then
        spawnedUI.cacheDirty = true
    end

    if not spawnedUI.cacheDirty then
        return false
    end

    spawnedUI.cachePaths()

    return true
end

---@param path string
---@return element?
function spawnedUI.getElementByPath(path)
    if path == "" then return spawnedUI.root end
    spawnedUI.ensureCache()

    for _, element in pairs(spawnedUI.paths) do
        if element.path == path then
            return element.ref
        end
    end
end

---@param owner element?
---@param onPick fun(PARAM: element, PARAM: element?): boolean?
---@param opts table?
---@return boolean
function spawnedUI.beginHierarchyPick(owner, onPick, opts)
    if type(onPick) ~= "function" then
        return false
    end

    opts = opts or {}
    spawnedUI.hierarchyPickRequest = {
        owner = owner,
        ownerId = owner and owner.id or nil,
        allowOwner = opts.allowOwner == true,
        restoreOwnerSelection = opts.restoreOwnerSelection ~= false,
        canPick = type(opts.canPick) == "function" and opts.canPick or nil,
        onPick = onPick
    }

    return true
end

---@param owner element?
function spawnedUI.cancelHierarchyPick(owner)
    if not spawnedUI.hierarchyPickRequest then
        return
    end

    if owner and spawnedUI.hierarchyPickRequest.owner ~= owner and spawnedUI.hierarchyPickRequest.ownerId ~= owner.id then
        return
    end

    spawnedUI.hierarchyPickRequest = nil
end

---@param owner element?
---@return boolean
function spawnedUI.isHierarchyPickActive(owner)
    local request = spawnedUI.hierarchyPickRequest
    if not request then
        return false
    end

    if not owner then
        return true
    end

    return request.owner == owner or request.ownerId == owner.id
end

---@param element element?
---@return boolean
function spawnedUI.isHierarchyPickEligible(element)
    local request = spawnedUI.hierarchyPickRequest
    if not request or not element then
        return false
    end

    local owner = request.owner
    if owner and not request.allowOwner and owner == element then
        return false
    end

    if type(request.canPick) == "function" then
        local ok, canPick = pcall(request.canPick, element, owner)
        if not ok or canPick == false then
            return false
        end
    end

    return true
end

---@param element element
---@return boolean handled
function spawnedUI.resolveHierarchyPick(element)
    local request = spawnedUI.hierarchyPickRequest
    if not request or not element then
        return false
    end

    local owner = request.owner
    if owner and owner.parent == nil then
        spawnedUI.hierarchyPickRequest = nil
        return false
    end

    if not spawnedUI.isHierarchyPickEligible(element) then
        return false
    end

    local handled = false
    local consumeRequest = true
    local ok, result = pcall(request.onPick, element, owner)
    if ok then
        handled = result ~= false
        consumeRequest = handled
    else
        consumeRequest = true
    end

    if consumeRequest then
        spawnedUI.hierarchyPickRequest = nil
    end

    if request.restoreOwnerSelection and owner and owner.parent ~= nil then
        spawnedUI.unselectAll()
        owner:setSelected(true)
        spawnedUI.scrollToSelected = true
    end

    return handled
end

---Adds an element to the root
---@param element element
function spawnedUI.addRootElement(element)
    element:setParent(spawnedUI.root)
end

---Returns all the elements that are not children of any selected element
---@param elements {path : string, ref : element}[]
---@return {path : string, ref : element}[]
function spawnedUI.getRoots(elements)
    local roots = {}

    for _, entry in ipairs(elements) do
        if entry.ref.parent ~= nil and not entry.ref.parent:isParentOrSelfSelected() and not entry.ref:isLocked() then -- Check on parent
            table.insert(roots, entry)
        end
    end

    table.sort(roots, function(a, b)
        local parentA = a.ref.parent and a.ref.parent:getPath() or ""
        local parentB = b.ref.parent and b.ref.parent:getPath() or ""
        if parentA ~= parentB then
            return parentA < parentB
        end

        local indexA = a.ref.parent and utils.indexValue(a.ref.parent.childs, a.ref) or -1
        local indexB = b.ref.parent and utils.indexValue(b.ref.parent.childs, b.ref) or -1
        if indexA ~= indexB then
            if indexA == -1 then return false end
            if indexB == -1 then return true end
            return indexA < indexB
        end

        return a.path < b.path
    end)

    return roots
end

---Returns the total number of elements which should be rendered in the hierarchy
---@return number
function spawnedUI.getNumVisibleElements()
    return #spawnedUI.visiblePaths
end

---@protected
---@param elements {path : string, tempPath: string, ref : element}[]
---@return element
function spawnedUI.findCommonParent(elements)
    if #elements == 0 then return spawnedUI.root end
    if #elements == 1 then return elements[1].ref.parent end

    local commonPath = ""

    -- Avoid modifying original paths
    for _, entry in ipairs(elements) do
        entry.tempPath = entry.path
    end

    local found = false -- Break condition
    while not found do
        local canidate = string.match(elements[1].tempPath, "^/[^/]+") -- All paths must match with this
        for _, entry in ipairs(elements) do
            if not (string.match(entry.tempPath, "^/[^/]+") == canidate) then found = true break end

            entry.tempPath = string.gsub(entry.tempPath, "^/[^/]+", "")
        end
        if not found then
            commonPath = commonPath .. canidate
        end
    end

    if commonPath == "" then return spawnedUI.root end
    return spawnedUI.getElementByPath(commonPath)
end

---Sets the specified element as the new target for spawning
---@param element element
function spawnedUI.setElementSpawnNewTarget(element)
    local elementPath = element:getPath()
    if not element.expandable then
        elementPath = element.parent:getPath()
    end

    local idx = 1
    for _, entry in pairs(spawnedUI.containerPaths) do
        if entry.path == elementPath then
            break
        end
        idx = idx + 1
    end

    spawnedUI.spawner.baseUI.spawnUI.selectedGroup = idx
end

---Pins a group to the focused hierarchy window.
---@param element element?
function spawnedUI.openPinnedHierarchy(element)
    if not element or not utils.isA(element, "positionableGroup") then
        return
    end

    spawnedUI.pinnedHierarchy.groupId = element.id
    spawnedUI.pinnedHierarchy.open = true
end

---Clears hovered markers from the previous frame.
function spawnedUI.resetHoveredEntries()
    for _, entry in pairs(spawnedUI.hoveredEntries) do
        if entry.hovered then
            entry:setHovered(false)
        end
    end
    spawnedUI.hoveredEntries = {}
end

---@return {path: string, ref: element}?
local function getPinnedHierarchyGroupEntry()
    local pinnedId = spawnedUI.pinnedHierarchy.groupId
    if not pinnedId then
        return nil
    end

    for _, entry in pairs(spawnedUI.containerPaths) do
        if entry.ref and entry.ref.id == pinnedId then
            return entry
        end
    end

    return nil
end

---@param rootEntry {path: string, ref: element}
---@return {path: string, ref: element, depth: number}[]
local function collectPinnedHierarchyEntries(rootEntry)
    local entries = {
        {
            path = rootEntry.path,
            ref = rootEntry.ref,
            depth = 0
        }
    }

    local function appendChildren(parent, depth)
        for _, child in pairs(parent.childs) do
            table.insert(entries, {
                path = child:getPath(),
                ref = child,
                depth = depth
            })

            if child.expandable and child.headerOpen then
                appendChildren(child, depth + 1)
            end
        end
    end

    if rootEntry.ref.expandable and rootEntry.ref.headerOpen then
        appendChildren(rootEntry.ref, 1)
    end

    return entries
end

local function hotkeyRunCondition()
    return input.context.spawned.hovered
        or input.context.spawned.focused
        or input.context.hierarchy.hovered
        or input.context.hierarchy.focused
        or (editor.active and (input.context.viewport.hovered or input.context.viewport.focused))
end

---@return boolean
local function hasRootChildren()
    return spawnedUI.root ~= nil and spawnedUI.root.childs ~= nil and next(spawnedUI.root.childs) ~= nil
end

---@param entry table?
---@return boolean
local function isValidClipboardEntry(entry)
    return type(entry) == "table" and type(entry.modulePath) == "string" and entry.modulePath ~= ""
end

---@param elements table?
---@return boolean
local function hasValidClipboardElements(elements)
    if type(elements) ~= "table" then
        return false
    end

    for _, entry in ipairs(elements) do
        if isValidClipboardEntry(entry) then
            return true
        end
    end

    return false
end

---@param source {ref: element}[]
---@return element[]
local function collectVisualizationTargets(source)
    local targets = {}

    for _, entry in pairs(source) do
        local target = entry and entry.ref or nil
        if spawnedUI.canToggleVisualization(target) then
            table.insert(targets, target)
        end
    end

    return targets
end

---@param node element?
---@param targets element[]
local function collectVisualizationTargetsRecursive(node, targets)
    if node == nil then
        return
    end

    if spawnedUI.canToggleVisualization(node) then
        table.insert(targets, node)
    end

    for _, child in pairs(node.childs or {}) do
        collectVisualizationTargetsRecursive(child, targets)
    end
end

---@param node element?
---@return boolean
local function hasActiveNameEditRecursive(node)
    if not node then
        return false
    end

    if node.editName then
        return true
    end

    for _, child in pairs(node.childs or {}) do
        if hasActiveNameEditRecursive(child) then
            return true
        end
    end

    return false
end

---@return boolean
local function hasActiveNameEdit()
    if spawnedUI.nameBeingEdited then
        return true
    end

    return hasActiveNameEditRecursive(spawnedUI.root)
end

---@return boolean
function spawnedUI.isNameEditActive()
    return hasActiveNameEdit()
end

---@param seconds number
---@return string
local function formatDuration(seconds)
    if seconds < 60 then
        return string.format("%ds", math.floor(seconds))
    end

    return string.format("%dm %02ds", math.floor(seconds / 60), math.floor(seconds % 60))
end

---Tooltip for the auto-save toggle: what it does now, and when it next runs.
---@return string
function spawnedUI.getAutoSaveTooltip()
    if settings.autoSaveEnabled ~= true then
        return "Auto-save is off\nOnly groups that were already saved once are ever auto-saved;\nnew groups always need an explicit save."
    end

    local lines = {
        string.format("Auto-save is on (every %s)", formatDuration(math.max(30, (settings.autoSaveIntervalMinutes or 5) * 60))),
        "Only saved projects are written; new groups are left alone."
    }

    local progress = persistenceManager.getProgressLabel()
    if progress then
        lines[#lines + 1] = progress
    else
        lines[#lines + 1] = "Next check in " .. formatDuration(persistenceManager.secondsUntilNextPass())
    end

    if persistenceManager.lastAutoSaveName then
        lines[#lines + 1] = string.format("Last: \"%s\" %s ago",
            persistenceManager.lastAutoSaveName,
            formatDuration(os.clock() - (persistenceManager.lastAutoSaveAt or 0)))
    end

    return table.concat(lines, "\n")
end

---Compact save state for the toolbar: what is happening now, or how much is unsaved.
---@return string? label nil when there is nothing worth saying.
function spawnedUI.getSaveStatusLabel()
    local progress = persistenceManager.getProgressLabel()
    if progress then
        return progress
    end

    local unsaved, unnamed = 0, 0

    for _, child in ipairs(spawnedUI.root.childs) do
        if saveState.isSavableRootGroup(child) then
            local record = saveState.getRecord(child)
            if record.state == "edited" or record.state == "error" then
                unsaved = unsaved + 1
            elseif record.state == "new" then
                unnamed = unnamed + 1
            end
        end
    end

    if unsaved == 0 and unnamed == 0 then
        return nil
    end

    local parts = {}

    -- Say when the next pass is due. Without this the only feedback between enabling auto-save and
    -- the first write is silence, which reads exactly like a broken feature.
    if unsaved > 0 and settings.autoSaveEnabled then
        local blocked, reason = persistenceManager.isBlocked()
        if blocked then
            parts[#parts + 1] = "waiting (" .. tostring(reason) .. ")"
        else
            parts[#parts + 1] = formatDuration(persistenceManager.secondsUntilNextPass())
        end
    end
    
    if unsaved > 0 then
        parts[#parts + 1] = string.format("%d unsaved", unsaved)
    end
    if unnamed > 0 then
        parts[#parts + 1] = string.format("%d never saved", unnamed)
    end

    return table.concat(parts, " | ")
end

---Saves one root group.
---
---Queued onto the persistence pipeline, which builds and writes a few milliseconds per frame instead
---of blocking until done -- on a large project the synchronous path froze the game for seconds. The
---pipeline also reuses the cached JSON of untouched nodes, so a save costs roughly what changed.
---
---Falls back to the synchronous path if the pipeline declines the group: a save the user asked for
---must happen, even if that means a pause.
---@param rootGroup element
---@return boolean queued False when it was saved synchronously instead.
function spawnedUI.saveRootGroup(rootGroup)
    if persistenceManager.enqueueManualSave(rootGroup) then
        return true
    end

    rootGroup:save(true)
    return false
end

function spawnedUI.saveAllRootGroups()
    if not hasRootChildren() then return end

    for _, entry in pairs(spawnedUI.paths) do
        if saveState.isSavableRootGroup(entry.ref) then
            spawnedUI.saveRootGroup(entry.ref)
        end
    end
end

function spawnedUI.registerHotkeys()
    input.registerImGuiHotkey({ ImGuiKey.Z, ImGuiKey.LeftCtrl }, function()
        if hasActiveNameEdit() then return end
        if ImGui.IsKeyDown(ImGuiKey.LeftShift) or ImGui.IsKeyDown(ImGuiKey.RightShift) then return end
        history.requestUndo()
    end, hotkeyRunCondition)
    input.registerImGuiHotkey({ ImGuiKey.Z, ImGuiKey.RightCtrl }, function()
        if hasActiveNameEdit() then return end
        if ImGui.IsKeyDown(ImGuiKey.LeftShift) or ImGui.IsKeyDown(ImGuiKey.RightShift) then return end
        history.requestUndo()
    end, hotkeyRunCondition)
    input.registerImGuiHotkey({ ImGuiKey.Y, ImGuiKey.LeftCtrl }, function()
        if hasActiveNameEdit() then return end
        history.requestRedo()
    end, hotkeyRunCondition)
    input.registerImGuiHotkey({ ImGuiKey.Y, ImGuiKey.RightCtrl }, function()
        if hasActiveNameEdit() then return end
        history.requestRedo()
    end, hotkeyRunCondition)
    input.registerImGuiHotkey({ ImGuiKey.Z, ImGuiKey.LeftCtrl, ImGuiKey.LeftShift }, function()
        if hasActiveNameEdit() then return end
        history.requestRedo()
    end, hotkeyRunCondition)
    input.registerImGuiHotkey({ ImGuiKey.Z, ImGuiKey.RightCtrl, ImGuiKey.LeftShift }, function()
        if hasActiveNameEdit() then return end
        history.requestRedo()
    end, hotkeyRunCondition)
    input.registerImGuiHotkey({ ImGuiKey.Z, ImGuiKey.LeftCtrl, ImGuiKey.RightShift }, function()
        if hasActiveNameEdit() then return end
        history.requestRedo()
    end, hotkeyRunCondition)
    input.registerImGuiHotkey({ ImGuiKey.Z, ImGuiKey.RightCtrl, ImGuiKey.RightShift }, function()
        if hasActiveNameEdit() then return end
        history.requestRedo()
    end, hotkeyRunCondition)
    input.registerImGuiHotkey({ ImGuiKey.A, ImGuiKey.LeftCtrl }, function()
        if hasActiveNameEdit() then return end

        for _, entry in pairs(spawnedUI.paths) do
            if not entry.ref:isLocked() then
                entry.ref:setSelected(true)
            end
        end
    end, hotkeyRunCondition)
    input.registerImGuiHotkey({ ImGuiKey.S, ImGuiKey.LeftCtrl }, function()
        if hasActiveNameEdit() then return end
        if not hasRootChildren() then return end

        spawnedUI.saveAllRootGroups()
    end, hotkeyRunCondition)
    input.registerImGuiHotkey({ ImGuiKey.C, ImGuiKey.LeftCtrl }, function()
        if #spawnedUI.selectedPaths == 0 or hasActiveNameEdit() then return end

        spawnedUI.clipboard = spawnedUI.copy(true)
    end, hotkeyRunCondition)
    input.registerImGuiHotkey({ ImGuiKey.V, ImGuiKey.LeftCtrl }, function()
        if not hasValidClipboardElements(spawnedUI.clipboard) or hasActiveNameEdit() then return end

        local target
        if #spawnedUI.selectedPaths > 0 then
            target = spawnedUI.selectedPaths[1].ref
        end

        history.addAction(history.getInsert(spawnedUI.paste(spawnedUI.clipboard, target)))
    end, hotkeyRunCondition)
    input.registerImGuiHotkey({ ImGuiKey.X, ImGuiKey.LeftCtrl }, function ()
        if hasActiveNameEdit() then return end
        if #spawnedUI.selectedPaths == 0 then return end

        spawnedUI.cut(true)
    end, hotkeyRunCondition)
    input.registerImGuiHotkey({ ImGuiKey.Delete }, function()
        if #spawnedUI.selectedPaths == 0 or hasActiveNameEdit() then return end

        local roots = spawnedUI.getRoots(spawnedUI.selectedPaths)
        history.addAction(history.getRemove(roots))
        for _, entry in ipairs(roots) do
            entry.ref:remove()
        end
    end, hotkeyRunCondition)
    input.registerImGuiHotkey({ ImGuiKey.D, ImGuiKey.LeftCtrl }, function()
        if hasActiveNameEdit() then return end
        if #spawnedUI.selectedPaths == 0 then return end

        local data = spawnedUI.copy(true)
        history.addAction(history.getInsert(spawnedUI.paste(data, spawnedUI.selectedPaths[1].ref)))
    end, hotkeyRunCondition)
    input.registerImGuiHotkey({ ImGuiKey.G, ImGuiKey.LeftCtrl }, function()
        if hasActiveNameEdit() then return end
        if #spawnedUI.selectedPaths == 0 then return end

        spawnedUI.moveToNewGroup(true)
    end, hotkeyRunCondition)

    -- These remain available throughout the Spawned interface, including the properties panel.
    input.registerImGuiHotkey({ ImGuiKey.Backspace }, function()
        if #spawnedUI.selectedPaths == 0 or hasActiveNameEdit() then return end
        if ImGui.IsKeyDown(ImGuiKey.LeftCtrl) or ImGui.IsKeyDown(ImGuiKey.RightCtrl) then return end
        spawnedUI.moveToParent(true)
    end, hotkeyRunCondition)
    input.registerImGuiHotkey({ ImGuiKey.Backspace, ImGuiKey.LeftCtrl }, function()
        if #spawnedUI.selectedPaths == 0 or hasActiveNameEdit() then return end
        spawnedUI.moveToRoot(true)
    end, hotkeyRunCondition)
    input.registerImGuiHotkey({ ImGuiKey.Backspace, ImGuiKey.RightCtrl }, function()
        if #spawnedUI.selectedPaths == 0 or hasActiveNameEdit() then return end
        spawnedUI.moveToRoot(true)
    end, hotkeyRunCondition)
    input.registerImGuiHotkey({ ImGuiKey.Escape }, function()
        if hasActiveNameEdit() then return end
        if spawnedUI.hierarchyPickRequest then
            spawnedUI.cancelHierarchyPick()
            return
        end
        if #spawnedUI.selectedPaths == 0 or editor.grab or editor.rotate or editor.scale then return end -- Escape is also used for cancling editing
        spawnedUI.unselectAll()
    end, hotkeyRunCondition)
    input.registerImGuiHotkey({ ImGuiKey.H }, function()
        if #spawnedUI.selectedPaths == 0 or hasActiveNameEdit() then return end

        local changes = {}
        for _, entry in pairs(spawnedUI.selectedPaths) do
            if not spawnedUI.canToggleVisibility(entry.ref) then goto continue end
		    table.insert(changes, history.getElementChange(entry.ref))
            entry.ref:setVisible(not entry.ref.visible, true)
            ::continue::
        end

        if #changes == 0 then return end

        history.addAction({
            undo = function()
                for _, change in ipairs(changes) do
                    change.undo()
                end
            end,
            redo = function()
                for _, change in ipairs(changes) do
                    change.redo()
                end
            end
        })
    end, hotkeyRunCondition)

    input.registerImGuiHotkey({ ImGuiKey.E, ImGuiKey.LeftCtrl }, function ()
        if hasActiveNameEdit() then return end
        if #spawnedUI.selectedPaths == 0 then return end

        local isMulti = #spawnedUI.selectedPaths > 1

        if isMulti then
            spawnedUI.multiSelectGroup:dropToSurface(true, Vector4.new(0, 0, -1, 0))
        else
            spawnedUI.selectedPaths[1].ref:dropToSurface(false, Vector4.new(0, 0, -1, 0))
        end
    end, hotkeyRunCondition)

    input.registerImGuiHotkey({ ImGuiKey.N, ImGuiKey.LeftCtrl }, function ()
        if hasActiveNameEdit() then return end
        if #spawnedUI.selectedPaths == 0 then
            spawnedUI.spawner.baseUI.spawnUI.selectedGroup = 0
            return
        end

        spawnedUI.setElementSpawnNewTarget(spawnedUI.selectedPaths[1].ref)
    end, hotkeyRunCondition)

    input.registerImGuiHotkey({ ImGuiKey.F, ImGuiKey.LeftCtrl }, function ()
        if hasActiveNameEdit() then return end
        if #spawnedUI.selectedPaths ~= 1 then
            return
        end

        local icon = spawnedUI.selectedPaths[1].ref.icon
        if icon == "" then
            icon = IconGlyphs.Group
        end
        spawnedUI.spawner.baseUI.spawnUI.prefabsUI.addNewItem(spawnedUI.selectedPaths[1].ref:serialize(), spawnedUI.selectedPaths[1].ref.name, icon)
    end, hotkeyRunCondition)

    -- Open context menu for selected from editor mode
    input.registerMouseAction(ImGuiMouseButton.Right, function()
        if hasActiveNameEdit() then return end
        if #spawnedUI.selectedPaths == 0 or editor.grab or editor.rotate or editor.scale then return end

        spawnedUI.openContextMenu.state = true
        spawnedUI.openContextMenu.path = spawnedUI.selectedPaths[1].path
    end,
    function ()
        return editor.active and (input.context.viewport.hovered or input.context.hierarchy.hovered)
    end)
end

function spawnedUI.multiSelectActive()
    return spawnedUI.modifierState and spawnedUI.modifierState.ctrl or false
end

---@protected
function spawnedUI.rangeSelectActive()
    return spawnedUI.modifierState and spawnedUI.modifierState.shift or false
end

---Updates cached modifier state while in draw context.
function spawnedUI.updateModifierState()
    spawnedUI.modifierState.ctrl = ImGui.IsKeyDown(ImGuiKey.LeftCtrl) or ImGui.IsKeyDown(ImGuiKey.RightCtrl)
    spawnedUI.modifierState.shift = ImGui.IsKeyDown(ImGuiKey.LeftShift) or ImGui.IsKeyDown(ImGuiKey.RightShift)
end

function spawnedUI.unselectAll()
    for _, entry in pairs(spawnedUI.selectedPaths) do
        entry.ref:setSelected(false)
    end
end

---@protected
---@param element element The element that was clicked on with range select active
function spawnedUI.handleRangeSelect(element)
    local paths = spawnedUI.filter ~= "" and spawnedUI.filteredPaths or spawnedUI.paths
    local firstSelected = spawnedUI.selectedPaths[1]
    local anchor = firstSelected and firstSelected.ref or nil

    -- Selection cache is refreshed per frame; a click can happen before selectedPaths is updated.
    -- If we have no anchor yet, there is no valid range to select.
    if not anchor or not element then
        return
    end

    if #spawnedUI.selectedPaths == 1 and anchor == element then -- Select from first to element
        for _, entry in pairs(paths) do
            local ref = entry and entry.ref or nil
            if ref then
                if ref == element then
                    break
                end
                if not ref:isLocked() then
                    ref:setSelected(true)
                end
            end
        end
    else
        local inRange = false
        if anchor == element then -- Bottom to top selection
            for i = #paths, 1, -1 do
                local ref = paths[i] and paths[i].ref or nil
                if ref then
                    if ref == anchor then
                        break
                    end
                    if ref.selected then
                        inRange = true
                    end
                    if inRange and not ref:isLocked() then
                        ref:setSelected(true)
                    end
                end
            end
        end

        inRange = false
        for _, entry in pairs(paths) do
            local ref = entry and entry.ref or nil
            if ref then
                if ref == anchor then -- From first selected down to element
                    if inRange then
                        break
                    else
                        inRange = true
                    end
                end
                if ref == element then -- From element down to first selected
                    if not inRange then
                        inRange = true
                    else
                        break
                    end
                end
                if inRange and not ref:isLocked() then
                    ref:setSelected(true)
                end

            end
        end
    end
end

---@protected
---@return number
local function getReorderShiftFromHoveredItem()
    local _, mouseY = ImGui.GetMousePos()
    local _, itemY = ImGui.GetItemRectMin()
    local _, sizeY = ImGui.GetItemRectSize()
    if sizeY <= 0 then
        return 1
    end

    return ((mouseY - itemY) < sizeY / 2) and 0 or 1
end

---@protected
---@param indentX number?
function spawnedUI.captureReorderPreview(indentX)
    local shift = getReorderShiftFromHoveredItem()
    local minX, minY = ImGui.GetItemRectMin()
    local maxX, maxY = ImGui.GetItemRectMax()
    local padX = 6 * style.viewSize
    local markerY = shift == 0 and minY or maxY
    local markerX1 = indentX or minX
    markerX1 = math.max(minX, math.min(maxX, markerX1))

    spawnedUI.reorderPreview = {
        x1 = markerX1,
        x2 = math.max(markerX1, maxX - padX),
        y = markerY
    }
end

---@protected
---@param element element
function spawnedUI.handleReorder(element)
    local shift = getReorderShiftFromHoveredItem()

    local adjust = 0

    local roots = spawnedUI.getRoots(spawnedUI.selectedPaths)
    local remove = history.getRemove(roots)
    for _, entry in ipairs(roots) do
        if entry.ref.parent == element.parent and utils.indexValue(element.parent.childs, element) > utils.indexValue(element.parent.childs, entry.ref) then
            adjust = 1
        end
        entry.ref:setParent(element.parent, utils.indexValue(element.parent.childs, element) + shift - adjust)
    end
    local insert = history.getInsert(roots)
    history.addAction(history.getMove(remove, insert))
end

---@protected
---@param element element
---@param indentX number?
function spawnedUI.handleDrag(element, indentX)
    local itemHovered = ImGui.IsItemHovered()
    local reorderMode = spawnedUI.rangeSelectActive()

    if element:isLocked() then
        if itemHovered and spawnedUI.draggingSelected then
            ImGui.SetMouseCursor(ImGuiMouseCursor.NotAllowed)
        end
        return
    end

    if itemHovered and ImGui.IsMouseDragging(0, style.draggingThreshold) and not spawnedUI.draggingSelected then -- Start dragging
        if not element.selected then
            spawnedUI.unselectAll()
            element:setSelected(true)
        end
        spawnedUI.draggingSelected = true
    elseif not ImGui.IsMouseDragging(0, style.draggingThreshold) and itemHovered and spawnedUI.draggingSelected then -- Drop on element
        spawnedUI.draggingSelected = false

        if not element.selected then
            if reorderMode and element:isValidDropTarget(spawnedUI.selectedPaths, false) then
                spawnedUI.handleReorder(element)
            elseif element:isValidDropTarget(spawnedUI.selectedPaths, true) then
                local roots = spawnedUI.getRoots(spawnedUI.selectedPaths)
                local remove = history.getRemove(roots)
                for _, entry in ipairs(roots) do
                    entry.ref:setParent(element)
                end
                local insert = history.getInsert(roots)
                history.addAction(history.getMove(remove, insert))
            else
                -- The cursor already said no while hovering, but a refused drop with no explanation
                -- reads as the drag having missed. Only linked projects get a message; every other
                -- rejection (dropping a group into itself) is self-evident.
                local prospectiveParent = reorderMode and element.parent or element
                local blocked = {}

                for _, entry in ipairs(spawnedUI.getRoots(spawnedUI.selectedPaths)) do
                    if entry.ref:wouldUnlinkFromProject(prospectiveParent) then
                        blocked[#blocked + 1] = entry
                    end
                end

                spawnedUI.warnIfLinkedProjects(blocked)
            end
        end
    elseif itemHovered and spawnedUI.draggingSelected then
        if element.selected then
            ImGui.SetMouseCursor(ImGuiMouseCursor.NotAllowed)
        elseif reorderMode then
            if element:isValidDropTarget(spawnedUI.selectedPaths, false) then
                spawnedUI.captureReorderPreview(indentX)
                ImGui.SetMouseCursor(ImGuiMouseCursor.Hand)
            else
                ImGui.SetMouseCursor(ImGuiMouseCursor.NotAllowed)
            end
        elseif not element:isValidDropTarget(spawnedUI.selectedPaths, true) then
            ImGui.SetMouseCursor(ImGuiMouseCursor.NotAllowed)
        else
            ImGui.SetMouseCursor(ImGuiMouseCursor.Hand)
        end
    end
end

---@protected
---@param isMulti boolean
---@param element element?
---@return table
function spawnedUI.copy(isMulti, element)
    local copied = {}

    if element and (not element.selected or not isMulti) then
        table.insert(copied, element:serialize())
    elseif isMulti then
        for _, entry in ipairs(spawnedUI.selectedPaths) do
            if not entry.ref.parent:isParentOrSelfSelected() then
                table.insert(copied, entry.ref:serialize())
            end
        end
    end

    return copied
end

---@protected
---@param elements table Serialized elements
---@param element element? The element to paste to
---@return element[]
function spawnedUI.paste(elements, element)
    spawnedUI.unselectAll()

    local pasted = {}
    if not hasValidClipboardElements(elements) then
        return pasted
    end

    sessionSnapshot.consume("pasted elements")

    local parent = spawnedUI.root
    local index = #parent.childs + 1

    if element then
        if element:isLocked() then
            return pasted
        end
        parent = element.parent
        index = utils.indexValue(parent.childs, element) + 1
        if element.expandable then
            -- This setting is meant for group cloning only. Keep non-group paste behavior unchanged.
            if settings.moveCloneToParent == 2 then
                parent = element.parent
                index = utils.indexValue(parent.childs, element) + 1
            else
                parent = element
                index = 1
            end
        end
    end

    for _, entry in ipairs(elements) do
        if isValidClipboardEntry(entry) then
            local new = require(entry.modulePath):new(spawnedUI)

            if entry.modulePath == "modules/classes/editor/randomizedGroup" then
                entry.seed = -1
            end

            new:load(entry)
            new:setParent(parent, index)
            new:setSelected(true)
            index = index + 1
            table.insert(pasted, new)
        end
    end

    return pasted
end

---@param isMulti boolean
---@param element element?
function spawnedUI.moveToParent(isMulti, element)
    if isMulti then
        local roots = spawnedUI.getRoots(spawnedUI.selectedPaths)
        if #roots == 0 then return end

        local elements = {}
        for _, entry in ipairs(roots) do
            local ref = entry.ref
            if not ref:isLocked() and ref.parent ~= nil and not ref:isRootChild() then
                table.insert(elements, ref)
            end
        end

        if #elements == 0 then return end
        local remove = history.getRemove(elements)
        local nextInsertByParentId = {}

        for _, ref in ipairs(elements) do
            local parent = ref.parent
            local grandParent = parent and parent.parent or nil
            if grandParent ~= nil then
                local key = parent.id
                local insertIndex = nextInsertByParentId[key]
                if insertIndex == nil then
                    insertIndex = utils.indexValue(grandParent.childs, parent) + 1
                end

                ref:setParent(grandParent, insertIndex)
                nextInsertByParentId[key] = insertIndex + 1
            end
        end

        local insert = history.getInsert(elements)
        history.addAction(history.getMove(remove, insert))
    elseif element and not element:isLocked() and element.parent ~= nil and not element:isRootChild() then
        spawnedUI.unselectAll()

        local parent = element.parent
        local grandParent = parent and parent.parent or nil
        if grandParent == nil then return end

        local remove = history.getRemove({ element })
        local insertIndex = utils.indexValue(grandParent.childs, parent) + 1
        element:setParent(grandParent, insertIndex)
        local insert = history.getInsert({ element })
        history.addAction(history.getMove(remove, insert))

        element:setSelected(true)
        spawnedUI.scrollToSelected = true
    end
end

---@param isMulti boolean
---@param element element?
function spawnedUI.moveToRoot(isMulti, element)
    if isMulti then
        local elements = {}
        for _, entry in ipairs(spawnedUI.selectedPaths) do
            if not entry.ref:isRoot(false) and not entry.ref.parent:isParentOrSelfSelected() and not entry.ref:isLocked() then
                table.insert(elements, entry.ref)
            end
        end
        if #elements == 0 then return end
        local remove = history.getRemove(elements)
        for _, entry in ipairs(elements) do
            entry:setParent(spawnedUI.root)
        end
        local insert = history.getInsert(elements)
        history.addAction(history.getMove(remove, insert))
    elseif element and not element:isLocked() then
        spawnedUI.unselectAll()

        local remove = history.getRemove({ element })
        element:setParent(spawnedUI.root)
        local insert = history.getInsert({ element })
        history.addAction(history.getMove(remove, insert))

        element:setSelected(true)
        spawnedUI.scrollToSelected = true
    end
end

---@param isMulti boolean
---@param element element?
function spawnedUI.moveToNewGroup(isMulti, element)
    -- Checked before anything is created: the new group would otherwise be inserted and then left
    -- behind empty when the move is refused.
    if isMulti then
        if spawnedUI.warnIfLinkedProjects(spawnedUI.getRoots(spawnedUI.selectedPaths)) then return end
    elseif element and spawnedUI.warnIfLinkedProjects({ element }) then
        return
    end

    local group = require("modules/classes/editor/positionableGroup"):new(spawnedUI)
    group.name = "New Group"

    if isMulti then
        local parents = spawnedUI.getRoots(spawnedUI.selectedPaths)
        if #parents == 0 then return end
        local common = spawnedUI.findCommonParent(parents)

        -- Find lowest index of element in common parent
        local index = nil
        for _, entry in ipairs(parents) do
            local indexInCommon = utils.indexValue(common.childs, entry.ref)

            if indexInCommon ~= -1 then
                if not index then index = indexInCommon end
                index = math.min(index, indexInCommon)
            end
        end

        if not index then index = 1 end

        group:setParent(common, index)
        local insert = history.getInsert({ group })
        local remove = history.getRemove(parents)

        for _, entry in ipairs(parents) do
            entry.ref:setParent(group)
        end

        local insertElements = history.getInsert(parents)
        history.addAction(history.getMoveToNewGroup(insert, remove, insertElements))
    elseif element and not element:isLocked() then
        group:setParent(element.parent, utils.indexValue(element.parent.childs, element))
        local insert = history.getInsert({ group }) -- Insertion of group
        local remove = history.getRemove({ element }) -- Removal of element
        element:setParent(group)
        local insertElement = history.getInsert({ element }) -- Insertion of element into group

        history.addAction(history.getMoveToNewGroup(insert, remove, insertElement))
    end

    spawnedUI.unselectAll()
    group:setSelected(true)
    group.editName = true
    group.focusNameEdit = 2
    spawnedUI.scrollToSelected = true
end

---@param isMulti boolean
---@param element element?
function spawnedUI.cut(isMulti, element)
    spawnedUI.clipboard = {}

    if isMulti then
        local roots = spawnedUI.getRoots(spawnedUI.selectedPaths)
        if #roots == 0 then return end
        history.addAction(history.getRemove(roots))
        for _, entry in ipairs(roots) do
            table.insert(spawnedUI.clipboard, entry.ref:serialize())
            entry.ref:remove()
        end
    elseif element and not element:isLocked() then
        history.addAction(history.getRemove({ element }))
        table.insert(spawnedUI.clipboard, element:serialize())
        element:remove()
    end
end

function spawnedUI.drawDragWindow()
    if spawnedUI.draggingSelected then
        ImGui.SetMouseCursor(ImGuiMouseCursor.Hand)

        local x, y = ImGui.GetMousePos()
        ImGui.SetNextWindowPos(x + 10 * style.viewSize, y + 10 * style.viewSize, ImGuiCond.Always)
        if ImGui.Begin("##wb-drag-wui", ImGuiWindowFlags.NoResize + ImGuiWindowFlags.NoMove + ImGuiWindowFlags.NoTitleBar + ImGuiWindowFlags.NoBackground + ImGuiWindowFlags.AlwaysAutoResize) then
            local text = #spawnedUI.selectedPaths == 1 and spawnedUI.selectedPaths[1].ref.name or (#spawnedUI.selectedPaths .. " elements")
            text = (spawnedUI.rangeSelectActive() and "Reorder " or "") .. text
            ImGui.Text(text)
            ImGui.End()
        end
    end
end

---Draws the "Add to / Remove from favorites" context menu entry for one element.
---Only spawnable elements referencing an asset of a path based spawn list qualify,
---since favorites are pure asset bookmarks without any configuration.
---@protected
---@param element element
function spawnedUI.drawAssetFavoriteMenuItem(element)
    if not utils.isA(element, "spawnableElement") or not element.spawnable then
        return
    end

    local spawnUI = spawnedUI.spawner and spawnedUI.spawner.baseUI.spawnUI or nil
    if not spawnUI then
        return
    end

    local modulePath = element.spawnable.modulePath
    local assetPath = tostring(element.spawnable.spawnData or "")
    local spawnList = spawnUI.getSpawnListByModulePath(modulePath)

    if not spawnList or not spawnList.isPaths or assetPath == "" then
        return
    end

    spawnUI.favoritesUI.drawContextMenuItem(
        modulePath,
        assetPath,
        utils.getFileName(assetPath),
        { spawnData = assetPath },
        "Spawned"
    )
end

---Draws the two project-link actions, at the very top of the context menu because they decide what
---every save below them will do.
---
---A group either owns a project file or does not, so only one of them is ever offered.
---@protected
---@param element element
function spawnedUI.drawProjectLinkMenuItems(element)
    if not saveState.isSavableRootGroup(element) then
        return
    end

    if element.projectUID then
        if ImGui.MenuItem(style.resolveActionLabelNoIconOnly(IconGlyphs.LinkVariantOff, "Unlink from project file")) then
            local previous = saveState.unbindProjectFile(element)

            if previous then
                ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 4000,
                    string.format("\"%s\" no longer writes to \"%s\"", element.name, previous)))
            end
        end
        style.tooltip("Keep the group, but stop it from writing to its project file.\nThe saved project itself is left untouched.")
    else
        if ImGui.MenuItem(style.resolveActionLabelNoIconOnly(IconGlyphs.ContentSaveMoveOutline, "Save as existing project...")) then
            projectLinkPopup.requestLink(element)
        end
        style.tooltip("Pick a saved project for this group to replace and be linked to.")
    end

    ImGui.Separator()
end

---Refuses an action that would take a linked project out of the root level, and says why.
---@protected
---@param elements element[] Elements about to be moved.
---@return boolean blocked
function spawnedUI.warnIfLinkedProjects(elements)
    local blocked = {}

    for _, entry in ipairs(elements) do
        local ref = entry.ref or entry
        if ref and ref.projectUID then
            blocked[#blocked + 1] = ref.name
        end
    end

    if #blocked == 0 then
        return false
    end

    local subject = #blocked == 1
        and string.format("\"%s\"", blocked[1])
        or string.format("%d groups", #blocked)

    ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Warning, 5000, string.format(
        "%s %s linked to a project file and must stay at root level.\nUnlink %s first to nest %s.",
        subject,
        #blocked == 1 and "is" or "are",
        #blocked == 1 and "it" or "them",
        #blocked == 1 and "it" or "them")))

    return true
end

---@protected
---@param element element
function spawnedUI.drawContextMenu(element, path)
    local x, y = ImGui.GetMousePos()
    ImGui.SetNextWindowPos(x + 10 * style.viewSize, y + 10 * style.viewSize, ImGuiCond.Appearing)

    if ImGui.BeginPopupContextItem("##contextMenu" .. path, ImGuiPopupFlags.MouseButtonRight) then
        local isMulti = #spawnedUI.selectedPaths > 1 and element.selected
        local isLocked = element:isLocked()
        local canPaste = hasValidClipboardElements(spawnedUI.clipboard)
        local isDirectRootChild = element:isRootChild()
        local activeSpawnUI = spawnedUI.spawner.baseUI.spawnUI
        local isSpawnTarget = activeSpawnUI.getSpawnTargetParent() == element
        local isEmptyGroup = utils.isA(element, "positionableGroup") and #element.childs == 0

        style.mutedText(isMulti and #spawnedUI.selectedPaths .. " elements" or element.name)
        if isLocked then
            ImGui.SameLine()
            style.mutedText("(Locked)")
        end

        -- The uID is what the Projects tab, auto-save and "Restore previous save" all address this
        -- group by, and it is deliberately no longer derivable from the name shown above it.
        if not isMulti and element.projectUID then
            style.mutedText(element.projectUID)
            style.tooltip("Project file this group is linked to")
        end

        ImGui.Separator()

        if not isMulti then
            spawnedUI.drawProjectLinkMenuItems(element)
        end

        ImGui.BeginDisabled(isLocked)
        if not element.lockedRemove and ImGui.MenuItem(style.resolveActionLabelNoIconOnly(IconGlyphs.DeleteOutline, "Delete"), "DEL") then
            if isMulti then
                local roots = spawnedUI.getRoots(spawnedUI.selectedPaths)
                history.addAction(history.getRemove(roots))
                for _, entry in ipairs(roots) do
                    entry.ref:remove()
                end
            else
                history.addAction(history.getRemove({ element }))
                element:remove()
            end
        end
        ImGui.EndDisabled()

        if ImGui.MenuItem(style.resolveActionLabelNoIconOnly(IconGlyphs.ContentCopy, "Copy"), "CTRL-C") then
            spawnedUI.clipboard = spawnedUI.copy(isMulti, element)
        end

        ImGui.BeginDisabled(isLocked)
        ImGui.BeginDisabled(not canPaste)
        if ImGui.MenuItem(style.resolveActionLabelNoIconOnly(IconGlyphs.ContentPaste, "Paste"), "CTRL-V") then
            history.addAction(history.getInsert(spawnedUI.paste(spawnedUI.clipboard, element)))
        end
        ImGui.EndDisabled()
        if not element.lockedRemove and ImGui.MenuItem(style.resolveActionLabelNoIconOnly(IconGlyphs.ContentCut, "Cut"), "CTRL-X") then
            spawnedUI.cut(isMulti, element)
        end
        if ImGui.MenuItem(style.resolveActionLabelNoIconOnly(IconGlyphs.ContentDuplicate, "Duplicate"), "CTRL-D") then
            local data = spawnedUI.copy(isMulti, element)
            history.addAction(history.getInsert(spawnedUI.paste(data, element)))
        end

        ImGui.Separator()
        ImGui.BeginDisabled(isDirectRootChild)
        if ImGui.MenuItem(style.resolveActionLabelNoIconOnly(IconGlyphs.ArrowUpLeftBold, "Move to parent level"), "BACKSPACE") then
            spawnedUI.moveToParent(isMulti, element)
        end
        if ImGui.MenuItem(style.resolveActionLabelNoIconOnly(IconGlyphs.ArrowTopLeftBoldBoxOutline, "Move to Root"), "CTRL-BACKSPACE") then
            spawnedUI.moveToRoot(isMulti, element)
        end
        ImGui.EndDisabled()
        if ImGui.MenuItem(style.resolveActionLabelNoIconOnly(IconGlyphs.FolderMultiplePlusOutline, "Move to new group"), "CTRL-G") then
            spawnedUI.moveToNewGroup(isMulti, element)
        end
        if utils.isA(element, "positionableGroup") then
            ImGui.BeginDisabled(isSpawnTarget)
            if ImGui.MenuItem(style.resolveActionLabelNoIconOnly(IconGlyphs.PlusBoxOutline, "Set as \"Spawn New\" group"), "CTRL-N") then
                spawnedUI.setElementSpawnNewTarget(element)
            end
            ImGui.EndDisabled()
            if ImGui.MenuItem(style.resolveActionLabelNoIconOnly(IconGlyphs.PinOutline, "Open in new window")) then
                spawnedUI.openPinnedHierarchy(element)
            end
        end

		ImGui.Separator()
        if utils.isA(element, "spawnableElement") then
            if ImGui.MenuItem(style.resolveActionLabelNoIconOnly(IconGlyphs.Download, "Drop to floor"), "CTRL-E") then
                if isMulti then
                    spawnedUI.multiSelectGroup:dropToSurface(true, Vector4.new(0, 0, -1, 0))
                else
                    element:dropToSurface(false, Vector4.new(0, 0, -1, 0))
                end
            end
        end
        if utils.isA(element, "positionableGroup") then
            ImGui.EndDisabled()
            ImGui.BeginDisabled(isEmptyGroup)
            if ImGui.MenuItem(style.resolveActionLabelNoIconOnly(IconGlyphs.EyeOutline, "Show all children")) then
                applyElementChangesBatched({ element }, function(entry)
                    entry:showDescendants(true)
                end)
            end
            if ImGui.MenuItem(style.resolveActionLabelNoIconOnly(IconGlyphs.LockOpenVariantOutline, "Unlock all children")) then
                applyElementChangesBatched({ element }, function(entry)
                    entry:unlockDescendants(true)
                end)
            end
            if ImGui.MenuItem(style.resolveActionLabelNoIconOnly(IconGlyphs.HospitalMarker, "Show all children visualization helpers")) then
                local targets = {}
                collectVisualizationTargetsRecursive(element, targets)
                applyElementChangesBatched(targets, function(entry)
                    if spawnedUI.canToggleVisualization(entry) then
                        entry.spawnable:setPreview(true)
                    end
                end)
            end
            ImGui.EndDisabled()
            ImGui.BeginDisabled(isLocked)

            ImGui.BeginDisabled(isEmptyGroup)
            if ImGui.MenuItem(style.resolveActionLabelNoIconOnly(IconGlyphs.DownloadMultiple, "Drop Children to Floor")) then
                element:dropChildrenToSurface(false, Vector4.new(0, 0, -1, 0))
            end
            ImGui.EndDisabled()

		    ImGui.Separator()
            if ImGui.MenuItem(style.resolveActionLabelNoIconOnly(IconGlyphs.ImageFilterCenterFocus, "Set Origin to Center")) then
                applyElementChangesBatched({ element }, function(entry)
                    entry:setOriginToCenter()
                end)
            end
            if ImGui.MenuItem(style.resolveActionLabelNoIconOnly(IconGlyphs.AccountBadgeOutline, "Set Origin to Player Position")) then
                applyElementChangesBatched({ element }, function(entry)
                    entry:setOrigin(GetPlayer():GetWorldPosition())
                end)
            end
            if ImGui.MenuItem(style.resolveActionLabelNoIconOnly(IconGlyphs.ContentCopy, "Copy Origin and Identity")) then
                local pos = element:getPosition()
                local rot = element:getRotation()
                utils.insertClipboardValue("position", { x = pos.x, y = pos.y, z = pos.z })
                utils.insertClipboardValue("rotation", { roll = rot.roll, pitch = rot.pitch, yaw = rot.yaw })
            end
            local copiedOrigin = utils.getClipboardValue("position")
            local copiedIdentity = utils.getClipboardValue("rotation")
            ImGui.BeginDisabled(copiedOrigin == nil or copiedIdentity == nil)
            if ImGui.MenuItem(style.resolveActionLabelNoIconOnly(IconGlyphs.ContentPaste, "Paste Origin and Identity")) then
                applyElementChangesBatched({ element }, function(entry)
                    entry:setOrigin(Vector4.new(copiedOrigin.x, copiedOrigin.y, copiedOrigin.z, 0))
                    entry:setIdentity(copiedIdentity)
                end)
            end
            ImGui.EndDisabled()
        end
        if element.parent ~= nil and utils.isA(element.parent, "positionableGroup") and not element.parent:isRoot(true) then
            ImGui.EndDisabled()
            if ImGui.MenuItem(style.resolveActionLabelNoIconOnly(IconGlyphs.SquareRoundedBadgeOutline, "Set Parent Origin to Element")) then
                local selectedPos = element:getPosition()
                applyElementChangesBatched({ element.parent }, function(entry)
                    entry:setOrigin(selectedPos)
                end)
            end
            ImGui.BeginDisabled(isLocked)
        end
        ImGui.EndDisabled()

        if utils.isA(element, "positionable") and not utils.isA(element, "positionableGroup") and ImGui.MenuItem(style.resolveActionLabelNoIconOnly(IconGlyphs.ContentCopy, "Copy Origin and Identity")) then
            local pos = element:getPosition()
            local rot = element:getRotation()
            utils.insertClipboardValue("position", { x = pos.x, y = pos.y, z = pos.z })
            utils.insertClipboardValue("rotation", { roll = rot.roll, pitch = rot.pitch, yaw = rot.yaw })
        end

		ImGui.Separator()
        if ImGui.MenuItem(style.resolveActionLabelNoIconOnly(IconGlyphs.Group, "Save as prefab"), "CTRL-F") then
            local icon = element.icon
            if icon == "" then
                icon = IconGlyphs.Group
            end

            spawnedUI.spawner.baseUI.spawnUI.prefabsUI.addNewItem(element:serialize(), element.name, icon)
        end

        spawnedUI.drawAssetFavoriteMenuItem(element)

        ImGui.EndPopup()
    end

    if spawnedUI.openContextMenu.state and spawnedUI.openContextMenu.path == path then
        spawnedUI.openContextMenu.state = false

        ImGui.OpenPopup("##contextMenu" .. spawnedUI.openContextMenu.path)
    end
end

---@protected
---@param element element
---@return number
function spawnedUI.getSideButtonsWidth(element)
    local sideButtonPadding = 1 * style.viewSize
    local function getButtonWidth(icon)
        local iconWidth, _ = ImGui.CalcTextSize(icon)
        return iconWidth + sideButtonPadding * 2
    end

    local lockWidth = math.max(
        getButtonWidth(IconGlyphs.LockOutline),
        getButtonWidth(IconGlyphs.LockOpenVariantOutline),
        getButtonWidth(IconGlyphs.LockOpenAlertOutline)
    )

    local visibilityWidth = math.max(
        getButtonWidth(IconGlyphs.EyeOutline),
        getButtonWidth(IconGlyphs.EyeOffOutline),
        getButtonWidth(IconGlyphs.EyeRemoveOutline)
    )
    local totalX = visibilityWidth + lockWidth + ImGui.GetStyle().ItemSpacing.x
    if spawnedUI.canToggleVisualization(element) then
        local visualizationWidth = math.max(getButtonWidth(IconGlyphs.HospitalMarker), getButtonWidth(IconGlyphs.MapMarkerOffOutline))
        totalX = totalX + visualizationWidth + ImGui.GetStyle().ItemSpacing.x
    end
    local gotoX = getButtonWidth(IconGlyphs.ArrowTopRight)

    if spawnedUI.filter ~= "" then
        totalX = totalX + gotoX + ImGui.GetStyle().ItemSpacing.x
    end

    for icon, data in pairs(element.quickOperations) do
        if data.condition(element) then
            -- Reserve the widest glyph the operation can show, not just the current one, so a state
            -- change does not shift the whole row.
            local width = getButtonWidth(icon)
            if data.iconVariants then
                for _, variant in pairs(data.iconVariants) do
                    width = math.max(width, getButtonWidth(variant))
                end
            end
            totalX = totalX + width + ImGui.GetStyle().ItemSpacing.x
        end
    end

    return totalX
end

---@protected
---@param text string
---@param maxWidth number
---@return string, boolean
function spawnedUI.fitTextWithEllipsis(text, maxWidth)
    local textWidth, _ = ImGui.CalcTextSize(text)
    if textWidth <= maxWidth then
        return text, false
    end

    local ellipsis = "..."
    local ellipsisWidth, _ = ImGui.CalcTextSize(ellipsis)
    if ellipsisWidth >= maxWidth then
        return ellipsis, true
    end

    local low = 0
    local high = #text

    while low < high do
        local mid = math.floor((low + high + 1) / 2)
        local candidate = string.sub(text, 1, mid) .. ellipsis
        local candidateWidth, _ = ImGui.CalcTextSize(candidate)

        if candidateWidth <= maxWidth then
            low = mid
        else
            high = mid - 1
        end
    end

    return string.sub(text, 1, low) .. ellipsis, true
end

local STATE_COLOR_GREEN = 0xFF00B200
local STATE_COLOR_RED = 0xFF2525E5
local STATE_COLOR_ORANGE = 0xFF0099FF
local STATE_COLOR_DEFAULT = style.mutedColor
local STATE_ICON_GRID_STEP = 22
local STATE_ICON_GRID_PADDING = 16
local PROJECT_TAG_FRAME_PADDING_X = 6
local PROJECT_TAG_FRAME_PADDING_Y = 2
local PROJECT_TAG_FONT_SCALE = 0.75
local LIFT_CONTROLLER_CLASS = "LiftControllerPS"
local ELEVATOR_FLOOR_CONTROLLER_CLASS = "ElevatorFloorTerminalControllerPS"
local DOOR_CONTROLLER_CLASS = "DoorControllerPS"
local CONNECTION_COUNT_ICONS = {
    [0] = IconGlyphs.Numeric0CircleOutline,
    [1] = IconGlyphs.Numeric1CircleOutline,
    [2] = IconGlyphs.Numeric2CircleOutline,
    [3] = IconGlyphs.Numeric3CircleOutline,
    [4] = IconGlyphs.Numeric4CircleOutline,
    [5] = IconGlyphs.Numeric5CircleOutline,
    [6] = IconGlyphs.Numeric6CircleOutline,
    [7] = IconGlyphs.Numeric7CircleOutline,
    [8] = IconGlyphs.Numeric8CircleOutline,
    [9] = IconGlyphs.Numeric9CircleOutline
}
local LIFT_FLOOR_COUNT_ICONS = {
    [0] = IconGlyphs.Numeric0BoxOutline,
    [1] = IconGlyphs.Numeric1BoxOutline,
    [2] = IconGlyphs.Numeric2BoxOutline,
    [3] = IconGlyphs.Numeric3BoxOutline,
    [4] = IconGlyphs.Numeric4BoxOutline,
    [5] = IconGlyphs.Numeric5BoxOutline,
    [6] = IconGlyphs.Numeric6BoxOutline,
    [7] = IconGlyphs.Numeric7BoxOutline,
    [8] = IconGlyphs.Numeric8BoxOutline,
    [9] = IconGlyphs.Numeric9BoxOutline
}

---@param x number
---@return number
local function snapStateIconXToGrid(x)
    local step = STATE_ICON_GRID_STEP * style.viewSize
    local snapped = math.floor((x + step * 0.5) / step) * step
    if snapped < x then
        snapped = snapped + step
    end

    return snapped
end

---@param target table
---@param icon string
---@param tooltip string
---@param color number?
---@param onClick fun()?
---@param drawPopup fun()?
local function addStateIcon(target, icon, tooltip, color, onClick, drawPopup)
    table.insert(target, {
        icon = icon,
        tooltip = tooltip,
        color = color,
        onClick = onClick,
        drawPopup = drawPopup
    })
end

---@param count number
---@return string
local function getConnectionCountIcon(count)
    if count >= 10 then
        return IconGlyphs.Numeric9PlusCircleOutline
    end

    return CONNECTION_COUNT_ICONS[math.max(0, math.min(9, count))] or IconGlyphs.Numeric0CircleOutline
end

---@param count number
---@return string
local function getLiftFloorCountIcon(count)
    if count >= 10 then
        return IconGlyphs.Numeric9PlusBoxOutline
    end

    return LIFT_FLOOR_COUNT_ICONS[math.max(0, math.min(9, count))] or IconGlyphs.Numeric0BoxOutline
end

---@param connections table[]?
---@return number
local function getLiftFloorConnectionCount(connections)
    local totalConnections = 0
    local floorConnections = 0

    for _, connection in ipairs(connections or {}) do
        if type(connection) == "table" then
            totalConnections = totalConnections + 1
            if tostring(connection.deviceClassName or "") == ELEVATOR_FLOOR_CONTROLLER_CLASS then
                floorConnections = floorConnections + 1
            end
        end
    end

    if floorConnections > 0 then
        return floorConnections
    end

    return totalConnections
end

---@param connections table[]?
---@param className string
---@return boolean
local function hasDeviceConnectionClass(connections, className)
    local targetClassName = string.lower(tostring(className or ""))
    if targetClassName == "" then
        return false
    end

    for _, connection in ipairs(connections or {}) do
        if type(connection) == "table" and string.lower(tostring(connection.deviceClassName or "")) == targetClassName then
            return true
        end
    end

    return false
end

local function getRootId(element)
    local root = element and element.getRootParent and element:getRootParent() or nil
    return root and root.id or -1
end

function spawnedUI.refreshStateIconCaches()
    if spawnedUI.stateIconCacheEpoch == spawnedUI.cacheEpoch and spawnedUI.stateIconWireframeEpoch == spawnedUI.wireframeEpoch then
        return
    end

    spawnedUI.stateIconGroupMarkerStateById = {}
    spawnedUI.stateIconValidSplinePathsByRoot = {}
    spawnedUI.stateIconValidOutlinePathsByRoot = {}
    spawnedUI.stateIconConnectionCountByRoot = {}

    for _, container in pairs(spawnedUI.containerPaths) do
        local rootId = getRootId(container.ref)
        local nOutlineMarkers = 0
        local nSplineMarkers = 0

        for _, child in pairs(container.ref.childs) do
            if utils.isA(child, "spawnableElement") and child.spawnable then
                local modulePath = child.spawnable.modulePath
                if modulePath == "area/outlineMarker" then
                    nOutlineMarkers = nOutlineMarkers + 1
                elseif modulePath == "meta/splineMarker" then
                    nSplineMarkers = nSplineMarkers + 1
                end
            end

            if nOutlineMarkers >= 3 and nSplineMarkers >= 2 then
                break
            end
        end

        if nSplineMarkers >= 2 then
            if spawnedUI.stateIconValidSplinePathsByRoot[rootId] == nil then
                spawnedUI.stateIconValidSplinePathsByRoot[rootId] = {}
            end
            spawnedUI.stateIconValidSplinePathsByRoot[rootId][container.path] = true
        end

        if nOutlineMarkers >= 3 then
            if spawnedUI.stateIconValidOutlinePathsByRoot[rootId] == nil then
                spawnedUI.stateIconValidOutlinePathsByRoot[rootId] = {}
            end
            spawnedUI.stateIconValidOutlinePathsByRoot[rootId][container.path] = true
        end
    end

    for _, entry in pairs(spawnedUI.paths) do
        local ref = entry.ref
        if utils.isA(ref, "spawnableElement") and ref.spawnable then
            local spawnable = ref.spawnable
            local path = nil

            if spawnable.isSplineNode then
                path = spawnable.splinePath
            elseif spawnable.outlinePath ~= nil and spawnable.loadOutlinePaths ~= nil then
                path = spawnable.outlinePath
            end

            if path ~= nil and path ~= "" and path ~= "None" then
                local rootId = getRootId(ref)
                if spawnedUI.stateIconConnectionCountByRoot[rootId] == nil then
                    spawnedUI.stateIconConnectionCountByRoot[rootId] = {}
                end

                local current = spawnedUI.stateIconConnectionCountByRoot[rootId][path] or 0
                spawnedUI.stateIconConnectionCountByRoot[rootId][path] = current + 1
            end
        end
    end

    spawnedUI.stateIconCacheEpoch = spawnedUI.cacheEpoch
    spawnedUI.stateIconWireframeEpoch = spawnedUI.wireframeEpoch
end

function spawnedUI.prepareStateIconFrame()
    spawnedUI.refreshStateIconCaches()

    local player = GetPlayer()
    spawnedUI.stateIconPlayerPosition = player and player:GetWorldPosition() or nil

    local spawnUI = spawnedUI.spawner and spawnedUI.spawner.baseUI and spawnedUI.spawner.baseUI.spawnUI or nil
    local selectedGroup = spawnUI and spawnUI.selectedGroup or 0
    spawnedUI.stateIconSelectedGroupRef = selectedGroup ~= 0 and spawnedUI.containerPaths[selectedGroup] and spawnedUI.containerPaths[selectedGroup].ref or nil
end

---@param element element
---@return boolean, boolean, boolean
function spawnedUI.getDirectChildMarkerState(element)
    if not utils.isA(element, "positionableGroup") then
        return false, false, false
    end

    local cached = spawnedUI.stateIconGroupMarkerStateById[element.id]
    if cached then
        return cached.hasOutlineMarker, cached.hasSplinePoint, cached.hasOtherChildren
    end

    local hasOutlineMarker = false
    local hasSplinePoint = false
    local hasOtherChildren = false

    for _, child in pairs(element.childs) do
        local isOutline = false
        local isSplinePoint = false

        if utils.isA(child, "spawnableElement") and child.spawnable then
            local modulePath = child.spawnable.modulePath
            isOutline = modulePath == "area/outlineMarker"
            isSplinePoint = modulePath == "meta/splineMarker"
        end

        if isOutline then
            hasOutlineMarker = true
        elseif isSplinePoint then
            hasSplinePoint = true
        else
            hasOtherChildren = true
        end

        if hasOutlineMarker and hasSplinePoint and hasOtherChildren then
            break
        end
    end

    spawnedUI.stateIconGroupMarkerStateById[element.id] = {
        hasOutlineMarker = hasOutlineMarker,
        hasSplinePoint = hasSplinePoint,
        hasOtherChildren = hasOtherChildren
    }

    return hasOutlineMarker, hasSplinePoint, hasOtherChildren
end

---@param element element
---@return {icon: string, tooltip: string, color: number?}[]
function spawnedUI.getStateIcons(element)
    spawnedUI.refreshStateIconCaches()

    local stateIcons = {}

    if utils.isA(element, "spawnableElement") and element.spawnable then
        local spawnable = element.spawnable
        local text = ""

        if spawnable.modulePath == "entity/device" and tostring(spawnable.deviceClassName or "") == LIFT_CONTROLLER_CLASS then
            local floorCount = getLiftFloorConnectionCount(spawnable.deviceConnections)
            addStateIcon(
                stateIcons,
                getLiftFloorCountIcon(floorCount),
                string.format("%d floor connection%s", floorCount, floorCount == 1 and "" or "s"),
                floorCount == 0 and style.warnColor or style.mutedColor
            )
        end

        if spawnable.modulePath == "entity/device"
            and tostring(spawnable.deviceClassName or "") == ELEVATOR_FLOOR_CONTROLLER_CLASS
            and hasDeviceConnectionClass(spawnable.deviceConnections, DOOR_CONTROLLER_CLASS) then
            addStateIcon(
                stateIcons,
                IconGlyphs.DoorSliding,
                "Terminal has a door connected to it",
                style.mutedColor
            )
        end

        if spawnable.visualizeStreamingRange then
            local playerPosition = spawnedUI.stateIconPlayerPosition
            if not playerPosition then
                local player = GetPlayer()
                playerPosition = player and player:GetWorldPosition() or nil
                spawnedUI.stateIconPlayerPosition = playerPosition
            end

            local inside = false
            if playerPosition and spawnable.getStreamingReferencePoint then
                local distance = utils.distanceVector(spawnable:getStreamingReferencePoint(), playerPosition)
                inside = distance <= (spawnable.primaryRange or 0)
                text = string.format("Distance to from %s: %.2f %s", spawnable.streamingRefPointOverride and "reference point" or "node position", distance, inside and "(inside)" or "(outside)")
            end

            addStateIcon(
                stateIcons,
                IconGlyphs.AxisArrowInfo,
                text,
                inside and STATE_COLOR_GREEN or STATE_COLOR_RED
            )
        end

        if spawnable.isSplineNode and spawnable.splineFollower then
            local missingRecord = spawnable.previewCharacter == nil or tostring(spawnable.previewCharacter):match("^%s*$") ~= nil
            local tooltip = "Preview NPC is enabled"
            if missingRecord then
                tooltip = tooltip .. ", but Record is missing"
            end

            addStateIcon(stateIcons, IconGlyphs.Walk, tooltip, missingRecord and STATE_COLOR_ORANGE or nil)
        end

        if spawnable.modulePath == "ai/aiSpot" and spawnable.spawnNPC then
            local missingRecord = spawnable.previewNPC == nil or tostring(spawnable.previewNPC):match("^%s*$") ~= nil
            local unsupportedRig = false
            if not missingRecord and spawnable.hasUnsupportedPreviewRecordRig then
                local ok, result = pcall(function ()
                    return spawnable:hasUnsupportedPreviewRecordRig()
                end)
                unsupportedRig = ok and result == true
            end

            local tooltip = "Preview NPC is enabled"
            if missingRecord then
                tooltip = tooltip .. ", but Record is missing"
            end
            if unsupportedRig then
                tooltip = tooltip .. ", but Record uses an unsupported rig"
            end

            addStateIcon(stateIcons, IconGlyphs.Human, tooltip, (missingRecord or unsupportedRig) and STATE_COLOR_ORANGE or nil)
        end

        if spawnable.modulePath == "light/light" then
            local color = colorUtil.normalizeRGB(spawnable.color, { 1, 1, 1 })
            local popupId = "##lightColorPickerState" .. tostring(element.id or "")
            if spawnedUI.isHierarchyPickActive and spawnedUI.isHierarchyPickActive(element) then
                addStateIcon(
                    stateIcons,
                    IconGlyphs.Target,
                    "Aim At Element target mode is active",
                    style.regularColor
                )
            end
            if spawnable.cameraFollowEnabled then
                addStateIcon(
                    stateIcons,
                    IconGlyphs.CameraLockOutline,
                    "Follow Camera is enabled",
                    style.warnColor
                )
            end
            addStateIcon(
                stateIcons,
                IconGlyphs.SquareRounded,
                colorUtil.formatPreviewTooltip(color),
                colorUtil.packAABBGGRR(color, 1.0),
                function()
                    ImGui.OpenPopup(popupId)
                end,
                function()
                    if ImGui.BeginPopup(popupId) then
                        local newColor, changed = style.trackedColorPicker(spawnable.object, "##stateLightColorPicker", spawnable.color)
                        if changed then
                            spawnable.color = newColor
                            if spawnable.updateParameters then
                                spawnable:updateParameters()
                            end
                        end
                        ImGui.EndPopup()
                    end
                end
            )
        end

        local isSpline = spawnable.isSplineNode == true
        local isAreaNode = spawnable.outlinePath ~= nil and spawnable.loadOutlinePaths ~= nil
        if isSpline or isAreaNode then
            local linked = false
            local rootId = getRootId(spawnable.object)

            if isSpline then
                local path = spawnable.splinePath
                linked = path ~= nil
                    and path ~= ""
                    and path ~= "None"
                    and spawnedUI.stateIconValidSplinePathsByRoot[rootId] ~= nil
                    and spawnedUI.stateIconValidSplinePathsByRoot[rootId][path] == true
            else
                local path = spawnable.outlinePath
                linked = path ~= nil
                    and path ~= ""
                    and path ~= "None"
                    and spawnedUI.stateIconValidOutlinePathsByRoot[rootId] ~= nil
                    and spawnedUI.stateIconValidOutlinePathsByRoot[rootId][path] == true
            end

            if linked then
                addStateIcon(stateIcons, IconGlyphs.LanConnect, "Linked path is valid", STATE_COLOR_GREEN)
            else
                addStateIcon(stateIcons, IconGlyphs.LanDisconnect, "No linked path", STATE_COLOR_RED)
            end
        end
    end

    if utils.isA(element, "positionableGroup") then
        -- Which file a group belongs to is no longer readable from its name, so linked projects say
        -- so on the row itself. Muted and tooltip-only: it is context, not a control.
        if element.projectUID then
            addStateIcon(
                stateIcons,
                IconGlyphs.ContentSaveSettingsOutline,
                string.format("Linked to project file \"%s\"", element.projectUID),
                style.mutedColor
            )
        end

        local selectedGroupRef = spawnedUI.stateIconSelectedGroupRef
        if not selectedGroupRef then
            local spawnUI = spawnedUI.spawner and spawnedUI.spawner.baseUI and spawnedUI.spawner.baseUI.spawnUI or nil
            local selectedGroup = spawnUI and spawnUI.selectedGroup or 0
            selectedGroupRef = selectedGroup ~= 0 and spawnedUI.containerPaths[selectedGroup] and spawnedUI.containerPaths[selectedGroup].ref or nil
            spawnedUI.stateIconSelectedGroupRef = selectedGroupRef
        end

        if selectedGroupRef == element then
            addStateIcon(stateIcons, IconGlyphs.PlusBoxOutline, "This group is the Spawn New target")
        end

        local brushSourceGroupId = editor.getBrushSourceGroupId and editor.getBrushSourceGroupId() or nil
        if brushSourceGroupId and brushSourceGroupId == element.id then
            addStateIcon(stateIcons, IconGlyphs.Brush, "This group is the Brush source group", style.regularColor)
        end

        local hasOutlineMarker, hasSplinePoint, hasOtherChildren = spawnedUI.getDirectChildMarkerState(element)
        if hasOutlineMarker then
            addStateIcon(stateIcons, IconGlyphs.SelectMarker, "Area shape outline")
        end
        if hasSplinePoint then
            addStateIcon(stateIcons, IconGlyphs.MapMarkerPath, "Spline path")
        end
        if hasOutlineMarker or hasSplinePoint then
            local rootId = getRootId(element)
            local path = element:getPath()
            local connectionCount = 0
            if spawnedUI.stateIconConnectionCountByRoot[rootId] ~= nil then
                connectionCount = spawnedUI.stateIconConnectionCountByRoot[rootId][path] or 0
            end

            if connectionCount > 0 then
                addStateIcon(
                    stateIcons,
                    getConnectionCountIcon(connectionCount),
                    string.format("Used as Path by %d Area/Spline node%s", connectionCount, connectionCount == 1 and "" or "s")
                )
            else
                addStateIcon(
                    stateIcons,
                    getConnectionCountIcon(0),
                    "This group is not used as Path by any Area/Spline node",
                    STATE_COLOR_ORANGE
                )
            end
        end

        if (hasOutlineMarker or hasSplinePoint) and hasOtherChildren or hasOutlineMarker and hasSplinePoint then
            addStateIcon(stateIcons, IconGlyphs.FolderAlertOutline, "Area/Spline group mixed with other elements", STATE_COLOR_ORANGE)
        end
    end

    return stateIcons
end

---@param stateIcons {icon: string, tooltip: string, color: number?}[]
---@return number
function spawnedUI.getStateIconsWidth(stateIcons)
    if #stateIcons == 0 then
        return 0
    end

    local step = STATE_ICON_GRID_STEP * style.viewSize
    return (#stateIcons + 1) * step
end

---@param projectTag table?
---@return number
function spawnedUI.getProjectTagWidth(projectTag)
    if projectTag == nil then
        return 0
    end

    local labelWidth = projectTagUtil.getLabelSize(projectTag.label, PROJECT_TAG_FONT_SCALE)
    local padX = PROJECT_TAG_FRAME_PADDING_X * style.viewSize

    return labelWidth + padX * 2
end

---@param projectTag table?
function spawnedUI.drawProjectTag(projectTag)
    if projectTag == nil then
        return
    end

    ImGui.SameLine()
    local cursorX = ImGui.GetCursorPosX() + STATE_ICON_GRID_PADDING * style.viewSize
    local baselineY = ImGui.GetCursorPosY() + 1 * style.viewSize
    local labelWidth, labelHeight = projectTagUtil.getLabelSize(projectTag.label, PROJECT_TAG_FONT_SCALE)
    local padX = PROJECT_TAG_FRAME_PADDING_X * style.viewSize
    local padY = PROJECT_TAG_FRAME_PADDING_Y * style.viewSize
    local frameWidth = labelWidth + padX * 2
    local frameHeight = labelHeight + padY * 2

    ImGui.SetCursorPosX(cursorX)
    ImGui.SetCursorPosY(baselineY)
    local frameX, frameY = ImGui.GetCursorScreenPos()
    ImGui.Dummy(frameWidth, frameHeight)

    local backgroundColor = colorUtil.packAABBGGRR(projectTag.color, 1.0)
    local textColor = colorUtil.packAABBGGRR(projectTag.textColor, 1.0)
    local drawList = ImGui.GetWindowDrawList()
    ImGui.ImDrawListAddRectFilled(drawList, frameX, frameY, frameX + frameWidth, frameY + frameHeight, backgroundColor, 3 * style.viewSize)
    ImGui.ImDrawListAddText(drawList, ImGui.GetFontSize() * PROJECT_TAG_FONT_SCALE, frameX + padX, frameY + padY, textColor, projectTag.label)
end

---@param stateIcons {icon: string, tooltip: string, color: number?, onClick: fun()?, drawPopup: fun()?}[]
function spawnedUI.drawStateIcons(stateIcons)
    if #stateIcons == 0 then
        return
    end

    ImGui.SameLine()
    local cursorX = ImGui.GetCursorPosX() + STATE_ICON_GRID_PADDING * style.viewSize
    local baselineY = ImGui.GetCursorPosY() + 1 * style.viewSize
    local step = STATE_ICON_GRID_STEP * style.viewSize

    for idx, iconData in ipairs(stateIcons) do
        local snappedX = snapStateIconXToGrid(cursorX)
        ImGui.SetCursorPosX(snappedX)
        ImGui.SetCursorPosY(baselineY)

        if iconData.onClick then
            style.pushStyleColor(true, ImGuiCol.Text, iconData.color or STATE_COLOR_DEFAULT)
            style.pushButtonNoBG(true)
            ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, 0, 0)
            if ImGui.Button(iconData.icon .. "##stateIcon" .. tostring(idx)) then
                iconData.onClick()
            end
            ImGui.PopStyleVar()
            style.pushButtonNoBG(false)
            style.popStyleColor(true)
        else
            style.styledText(iconData.icon, iconData.color or STATE_COLOR_DEFAULT)
        end

        style.tooltip(iconData.tooltip)
        if iconData.drawPopup then
            iconData.drawPopup()
        end
        cursorX = snappedX + step
    end
end

---@protected
---@param element element
---@return boolean
function spawnedUI.hasLockedChildren(element)
    if not utils.isA(element, "positionableGroup") then return false end
    return spawnedUI.lockedChildrenCache[element.id] == true
end

---@protected
---@param element element
---@param rowHovered boolean?
function spawnedUI.drawSideButtons(element, rowHovered)
    -- Right side buttons
    local totalX = spawnedUI.getSideButtonsWidth(element)

    local scrollBarAddition = (ImGui.GetScrollMaxY() > 0 and not spawnedUI.dividerDragging) and ImGui.GetStyle().ScrollbarSize or 0

    local cursorX = ImGui.GetWindowWidth() - totalX - ImGui.GetStyle().CellPadding.x / 2 - scrollBarAddition + ImGui.GetScrollX()
    local rowY = ImGui.GetCursorPosY()
    ImGui.SetCursorPosX(cursorX)
    ImGui.SetCursorPosY(rowY)

    local elementLocked = element:isLocked()
    local hoveredLocked = elementLocked and (rowHovered == true)
    local sideButtonPadding = 1 * style.viewSize

    for icon, data in pairs(element.quickOperations) do
        if data.condition(element) then
            ImGui.SetNextItemAllowOverlap()
            local disableQuickOp = elementLocked and not data.allowWhenLocked
            if data.disableWhenEmpty and utils.isA(element, "positionableGroup") and next(element.childs) == nil then
                disableQuickOp = true
            end

            -- An operation may render itself from live state instead of the fixed table key, which is
            -- how the save button reflects whether the group is modified, saving, or already saved.
            local displayIcon = icon
            local tooltip = data.tooltip
            local color = nil
            if data.getDisplay then
                local ok, resolvedIcon, resolvedColor, resolvedTooltip = pcall(data.getDisplay, element)
                if ok and resolvedIcon then
                    displayIcon = resolvedIcon
                    color = resolvedColor
                    tooltip = resolvedTooltip or tooltip
                end
            end

            ImGui.BeginDisabled(disableQuickOp)
            ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, sideButtonPadding, sideButtonPadding)
            if color then
                ImGui.PushStyleColor(ImGuiCol.Text, color[1], color[2], color[3], color[4])
            end
            if ImGui.Button(displayIcon .. "##quickOp" .. icon) then
                data.operation(element)
            end
            if color then
                ImGui.PopStyleColor()
            end
            ImGui.PopStyleVar()
            ImGui.EndDisabled()
            if tooltip then
                style.tooltip(tooltip)
            end
            ImGui.SameLine()
        end
    end

    if spawnedUI.filter ~= "" then
        ImGui.SetNextItemAllowOverlap()
        ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, sideButtonPadding, sideButtonPadding)
        if ImGui.Button(IconGlyphs.ArrowTopRight) then
            spawnedUI.unselectAll()
            element:setSelected(true)
            element:expandAllParents()
            spawnedUI.scrollToSelected = true
            spawnedUI.filter = ""
        end
        ImGui.PopStyleVar()
        ImGui.SameLine()
    end

    if spawnedUI.canToggleVisualization(element) then
        local previewed = element.spawnable.previewed == true
        local visualizationIcon = previewed and IconGlyphs.HospitalMarker or IconGlyphs.MapMarkerOffOutline
        style.pushStyleColor(not previewed, ImGuiCol.Text, style.mutedColor)

        ImGui.SetNextItemAllowOverlap()
        ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, sideButtonPadding, sideButtonPadding)
        if ImGui.Button(visualizationIcon) then
            local targets = { element }
            if spawnedUI.multiSelectActive() then
                targets = {}
                collectVisualizationTargetsRecursive(element, targets)
            end

            applyElementChangesBatched(targets, function(entry)
                if spawnedUI.canToggleVisualization(entry) then
                    entry.spawnable:setPreview(not previewed)
                end
            end)
        end
        ImGui.PopStyleVar()
        style.popStyleColor(not previewed)
        style.tooltip(previewed and "Disable visualization helpers" or "Enable visualization helpers")
        ImGui.SameLine()
    end

    local icon = elementLocked and IconGlyphs.LockOutline or IconGlyphs.LockOpenVariantOutline
    local canToggleLock = spawnedUI.canMutateLockedState(element)
    local hasLockedChildren = spawnedUI.hasLockedChildren(element) and not elementLocked
    if hasLockedChildren then
        icon = IconGlyphs.LockOpenAlertOutline
    end
    style.pushStyleColor(not elementLocked, ImGuiCol.Text, style.mutedColor)
    style.pushStyleColor(hasLockedChildren, ImGuiCol.Text, 1.0, 0.55, 0.0, 0.6)
    style.pushStyleColor(hoveredLocked, ImGuiCol.Text, 1.0, 0.84, 0.2, 1.0)
    ImGui.SetNextItemAllowOverlap()
    ImGui.BeginDisabled(not canToggleLock)
    ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, sideButtonPadding, sideButtonPadding)
    if ImGui.Button(icon) then
        if spawnedUI.multiSelectActive() then
            element:setLockedRecursive(not element.locked, false)
        else
            element:setLocked(not element.locked, false)
        end
    end
    ImGui.PopStyleVar()
    ImGui.EndDisabled()
    style.popStyleColor(hoveredLocked)
    style.popStyleColor(hasLockedChildren)
    style.popStyleColor(not elementLocked)
    if element.lockedByParent then
        style.tooltip("Locked by parent")
    elseif hasLockedChildren then
        style.tooltip("Contains locked children")
    else
        style.tooltip(elementLocked and "Unlock element" or "Lock element")
    end
    ImGui.SameLine()

    local visible = element.visible
    local visibilityIcon = visible and IconGlyphs.EyeOutline or IconGlyphs.EyeOffOutline
    if visible and element.hiddenByParent then
        visibilityIcon = IconGlyphs.EyeRemoveOutline
    end
    style.pushStyleColor(not visible, ImGuiCol.Text, style.mutedColor)

    ImGui.SetNextItemAllowOverlap()
    ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, sideButtonPadding, sideButtonPadding)
    if ImGui.Button(visibilityIcon) then
        if spawnedUI.multiSelectActive() and spawnedUI.canToggleVisibility(element) then
            element:setVisibleRecursive(not element.visible)
        elseif spawnedUI.canToggleVisibility(element) then
            element:setVisible(not element.visible)
        end
    end
    ImGui.PopStyleVar()
    style.popStyleColor(not visible)

end

---@protected
---@param element element
function spawnedUI.drawElementChilds(element)
    -- Legacy hook kept for compatibility with older call sites.
end

---@protected
---@return number
function spawnedUI.getRowHeight()
    return ImGui.GetFrameHeight() + (spawnedUI.cellPadding - style.viewSize) * 2
end

---@protected
---@param entry {path : string, ref : element, depth : number}?
---@param dummy boolean
---@param rowIndex number?
---@param sticky boolean?
function spawnedUI.drawElement(entry, dummy, rowIndex, sticky)
    spawnedUI.elementCount = spawnedUI.elementCount + 1
    local element = entry and entry.ref or nil
    local elementPath = entry and entry.path or ""
    local rowDepth = entry and (entry.depth or 0) or 0

    local isGettingDragged = element and element.selected and spawnedUI.draggingSelected
    local rowLocked = element and element:isLocked()

    ImGui.PushID(spawnedUI.elementCount)

    ImGui.TableNextRow(ImGuiTableRowFlags.None, spawnedUI.getRowHeight())
    local isEvenRow = (rowIndex or spawnedUI.elementCount) % 2 == 0
    if sticky and isEvenRow then
        ImGui.TableSetBgColor(ImGuiTableBgTarget.RowBg0, 0.08, 0.08, 0.08, 0.9)
    elseif sticky then
        ImGui.TableSetBgColor(ImGuiTableBgTarget.RowBg0, 0.13, 0.13, 0.13, 0.9)
    elseif isEvenRow then
        ImGui.TableSetBgColor(ImGuiTableBgTarget.RowBg0, 0.2, 0.2, 0.2, 0.3)
    else
        ImGui.TableSetBgColor(ImGuiTableBgTarget.RowBg0, 0.3, 0.3, 0.3, 0.3)
    end

    local brushSourceGroupId = editor.getBrushSourceGroupId and editor.getBrushSourceGroupId() or nil
    if brushSourceGroupId and element and element.id == brushSourceGroupId then
        ImGui.TableSetBgColor(ImGuiTableBgTarget.RowBg0, 0.16, 0.45, 0.16, 0.6)
    end

    ImGui.TableNextColumn()

    if dummy then
        ImGui.PopID()
        return
    end

    -- Base selectable
    ImGui.SetCursorPosX(rowDepth * 17 * style.viewSize) -- Indent element
    local indentX = ImGui.GetCursorScreenPos()
    ImGui.PushStyleVar(ImGuiStyleVar.ItemSpacing, 15, spawnedUI.cellPadding * 2 + style.viewSize) -- + style.viewSize is a ugly fix to make the gaps smaller

    -- Grey out if getting dragged
    local suppressHeaderState = isGettingDragged or rowLocked
    local suppressReorderHoverState = spawnedUI.draggingSelected and spawnedUI.rangeSelectActive()
    style.pushStyleColor(suppressHeaderState, ImGuiCol.HeaderHovered, 0, 0, 0, 0)
    style.pushStyleColor(suppressHeaderState, ImGuiCol.HeaderActive, 0, 0, 0, 0)
    style.pushStyleColor(suppressHeaderState, ImGuiCol.Header, 0, 0, 0, 0)
    style.pushStyleColor(suppressReorderHoverState, ImGuiCol.HeaderHovered, 0, 0, 0, 0)
    style.pushStyleColor(suppressReorderHoverState, ImGuiCol.HeaderActive, 0, 0, 0, 0)
    local hierarchyPickEligible = spawnedUI.isHierarchyPickEligible and spawnedUI.isHierarchyPickEligible(element)
    local highlightHierarchyPickEligible = hierarchyPickEligible and not suppressHeaderState
    style.pushStyleColor(highlightHierarchyPickEligible, ImGuiCol.Header, HIERARCHY_PICK_ELIGIBLE_BG)
    style.pushStyleColor(highlightHierarchyPickEligible, ImGuiCol.HeaderHovered, HIERARCHY_PICK_ELIGIBLE_HOVER)
    style.pushStyleColor(highlightHierarchyPickEligible, ImGuiCol.HeaderActive, HIERARCHY_PICK_ELIGIBLE_ACTIVE)

    local previous = element.selected
    local newState = ImGui.Selectable("##item" .. spawnedUI.elementCount, element.selected, ImGuiSelectableFlags.SpanAllColumns + ImGuiSelectableFlags.AllowOverlap)
    local rowClicked = ImGui.IsItemClicked(ImGuiMouseButton.Left)
    element:setSelected(newState)
    local isHovered = ImGui.IsItemHovered()
    if isHovered and not element.hovered then
        element:setHovered(true)
    end
    if isHovered then
        table.insert(spawnedUI.hoveredEntries, element)
    end
    if element:isLocked() then
        element:setSelected(false)
        newState = false
    end

    if element.selected then
        if spawnedUI.scrollToSelected and not sticky then
            ImGui.SetScrollHereY(0.5)
            spawnedUI.scrollToSelected = false
        elseif element.selected ~= previous and spawnedUI.rangeSelectActive() then
            spawnedUI.handleRangeSelect(element)
        end
    end

    if not spawnedUI.multiSelectActive() and not spawnedUI.rangeSelectActive() and previous ~= element.selected and not spawnedUI.draggingSelected then
        for _, selectedEntry in pairs(spawnedUI.selectedPaths) do
            if selectedEntry.ref ~= element then
                selectedEntry.ref:setSelected(false)
            end
        end
        if previous == true and #spawnedUI.selectedPaths > 1 then element:setSelected(true) end
    elseif spawnedUI.draggingSelected and previous ~= element.selected then -- Disregard any changes due to dragging
        element:setSelected(previous)
    end

    if rowClicked and not spawnedUI.draggingSelected and spawnedUI.hierarchyPickRequest then
        spawnedUI.resolveHierarchyPick(element)
    end

    if rowClicked and editor.isBrushActive and editor.isBrushActive() and editor.captureBrushSourceFromSelection then
        editor.captureBrushSourceFromSelection(false)
    end

    spawnedUI.handleDrag(element, indentX)

    spawnedUI.drawContextMenu(element, elementPath)

    style.popStyleColor(highlightHierarchyPickEligible, 3)
    style.popStyleColor(suppressReorderHoverState, 2)
    style.popStyleColor(suppressHeaderState, 3)
    ImGui.PopStyleVar()

    -- Styles
    ImGui.SameLine()
    ImGui.PushStyleColor(ImGuiCol.Button, 0)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 1, 1, 1, 0.2)
    ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, 0, 0)
    ImGui.SetCursorPosY(ImGui.GetCursorPosY() + 1 * style.viewSize)
    ImGui.PushStyleVar(ImGuiStyleVar.ButtonTextAlign, 0.5, 0.5)
    style.pushStyleColor(isGettingDragged, ImGuiCol.Text, style.extraMutedColor)

    local primaryIcon = element.icon or ""
    local secondaryIcon = element.secondaryIcon or ""
    local leftOffset = 25 * style.viewSize -- Accounts for primary icon and/or expand button
    local hiddenText = not element.visible
    style.pushStyleColor(hiddenText, ImGuiCol.Text, style.mutedColor)
    local projectTag = projectTagUtil.getRootGroupTag(element)
    local stateIcons = spawnedUI.getStateIcons(element)
    local projectTagWidth = spawnedUI.getProjectTagWidth(projectTag)
    local stateIconsWidth = spawnedUI.getStateIconsWidth(stateIcons)
    local projectTagLeadPad = projectTag and (STATE_ICON_GRID_PADDING * style.viewSize) or 0
    local stateIconLeadPad = (#stateIcons > 0) and (STATE_ICON_GRID_PADDING * style.viewSize) or 0
    local rowMetaWidth = projectTagWidth + stateIconsWidth + projectTagLeadPad + stateIconLeadPad

    local function drawRowIcon(icon, drawSameLine)
        if icon == "" then
            return false
        end

        if drawSameLine then
            ImGui.SameLine()
        end

        ImGui.AlignTextToFramePadding()
        ImGui.Text(icon)

        return true
    end

    -- Icon or expand button
    if not element.expandable then
        local drewPrimary = drawRowIcon(primaryIcon, false)
        local drewSecondary = drawRowIcon(secondaryIcon, drewPrimary)
        if drewSecondary then
            leftOffset = leftOffset + 20 * style.viewSize
        end
    elseif element.expandable then
        ImGui.PushID(element.name)
        local text = element.headerOpen and IconGlyphs.MenuDownOutline or IconGlyphs.MenuRightOutline
        ImGui.SetNextItemAllowOverlap()
        if ImGui.Button(text) then
            if spawnedUI.multiSelectActive() then
                element:setHeaderStateRecursive(not element.headerOpen)
            else
                element.headerOpen = not element.headerOpen
                spawnedUI.invalidateCache(false)
            end
        end

        local drewPrimary = drawRowIcon(primaryIcon, true)
        local drewSecondary = drawRowIcon(secondaryIcon, true)

        if drewPrimary then
            leftOffset = 45 * style.viewSize
        end
        if drewSecondary then
            leftOffset = drewPrimary and (leftOffset + 20 * style.viewSize) or (45 * style.viewSize)
        end

        ImGui.PopID()
    end

    ImGui.SameLine()

    local nameStartX = rowDepth * 17 * style.viewSize + leftOffset
    ImGui.SetCursorPosX(nameStartX)
    ImGui.AlignTextToFramePadding()
    if element.editName then
        input.windowHovered = false
        if element.focusNameEdit > 0 then
            ImGui.SetKeyboardFocusHere()
            element.focusNameEdit = element.focusNameEdit - 1
        end
        element:drawName()
    else
        local sideButtonsWidth = spawnedUI.getSideButtonsWidth(element)
        local scrollBarAddition = (ImGui.GetScrollMaxY() > 0 and not spawnedUI.dividerDragging) and ImGui.GetStyle().ScrollbarSize or 0
        local rightButtonsStartX = ImGui.GetWindowWidth() - sideButtonsWidth - ImGui.GetStyle().CellPadding.x / 2 - scrollBarAddition + ImGui.GetScrollX()
        local maxNameWidth = math.max(20 * style.viewSize, rightButtonsStartX - nameStartX - ImGui.GetStyle().ItemSpacing.x - rowMetaWidth)

        local fittedName, wasClipped = spawnedUI.fitTextWithEllipsis(element.name, maxNameWidth)
        ImGui.SetNextItemAllowOverlap()
        ImGui.Text(fittedName)
        if wasClipped then
            style.tooltip(element.name)
        end
    end
    if not element.editName then
        spawnedUI.drawStateIcons(stateIcons)
        spawnedUI.drawProjectTag(projectTag)
    end
    style.popStyleColor(hiddenText)

    if isHovered and ImGui.IsMouseDoubleClicked(ImGuiMouseButton.Left) then
        if not element:isLocked() and not element.lockedRename then
            element.editName = true
            element.focusNameEdit = 1
            element:setSelected(true)
        end
    end

    if spawnedUI.filter ~= "" then
        ImGui.SameLine()
        local pathColumnX = spawnedUI.filteredWidestName + 25 * style.viewSize + 5 * style.viewSize
        ImGui.SetCursorPosX(math.max(pathColumnX, ImGui.GetCursorPosX()))
        style.mutedText("[" .. elementPath .. "]")
    end

    ImGui.SameLine()

    spawnedUI.drawSideButtons(element, isHovered)

    ImGui.PopStyleColor(2)
    ImGui.PopStyleVar(2)
    style.popStyleColor(isGettingDragged)

    ImGui.PopID()
end

---Collects the open parent chain for the first visible hierarchy entry.
---Depth is used as the boundary so focused hierarchy windows never pin groups
---from outside their own root.
---@param entries {path: string, ref: element, depth: number}[]
---@param firstVisibleIndex number
---@param maxRows number
---@return {path: string, ref: element, depth: number}[]
local function collectStickyParentEntries(entries, firstVisibleIndex, maxRows)
    local firstVisible = entries[firstVisibleIndex]
    local depth = firstVisible and (firstVisible.depth or 0) or 0
    if depth <= 0 or maxRows <= 0 then
        return {}
    end

    local parents = {}
    local parent = firstVisible.ref and firstVisible.ref.parent or nil
    while parent and depth > 0 do
        table.insert(parents, 1, {
            path = parent:getPath(),
            ref = parent,
            depth = depth - 1
        })
        parent = parent.parent
        depth = depth - 1
    end

    -- Extremely deep trees should still leave room for at least one regular row.
    -- Keep the nearest parents when the full chain cannot fit in the viewport.
    if #parents > maxRows then
        local nearestParents = {}
        for index = #parents - maxRows + 1, #parents do
            table.insert(nearestParents, parents[index])
        end
        return nearestParents
    end

    return parents
end

---@protected
function spawnedUI.drawReorderPreview()
    local preview = spawnedUI.reorderPreview
    if not preview then
        return
    end

    local drawList = ImGui.GetWindowDrawList()
    local thickness = math.max(1, 2 * style.viewSize)
    ImGui.ImDrawListAddLine(drawList, preview.x1, preview.y + 1, preview.x2, preview.y + 1, HIERARCHY_REORDER_PREVIEW_SHADOW, thickness + 1)
    ImGui.ImDrawListAddLine(drawList, preview.x1, preview.y, preview.x2, preview.y, style.regularColor, thickness)
end

---@param options {entries: {path: string, ref: element, depth: number}[]?, childId: string?, tableId: string?, childHeight: number?}?
function spawnedUI.drawHierarchy(options)
    options = options or {}
    spawnedUI.reorderPreview = nil

    spawnedUI.elementCount = 0
    spawnedUI.cellPadding = 3 * style.viewSize

    local _, ySpace = ImGui.GetContentRegionAvail()

    if ySpace < 0 then return end

    local childHeight = options.childHeight
    if childHeight == nil then
        if ySpace - settings.editorBottomSize < 75 * style.viewSize and not spawnedUI.spawner.baseUI.loadTabSize then
            settings.editorBottomSize = ySpace - 75 * style.viewSize
        end
        childHeight = ySpace - settings.editorBottomSize
    end

    if childHeight < 0 then return end

    local rowHeight = spawnedUI.getRowHeight()
    local totalRows = math.max(0, math.floor(childHeight / rowHeight))
    local entries = options.entries or (spawnedUI.filter == "" and spawnedUI.visiblePaths or spawnedUI.filteredPaths)
    spawnedUI.prepareStateIconFrame()

    local childId = options.childId or "##hierarchy"
    local tableId = options.tableId or "##hierarchyTable"
    local firstVisibleIndex = math.min(#entries, spawnedUI.hierarchyFirstVisibleIndexById[childId] or 1)

    -- Sticky rows are pinned above the scrollable content rather than drawn over it, so the
    -- scrollable child needs to be shrunk (and pushed down) by however many rows were pinned.
    -- The count for *this* frame is only known after we've scrolled the table below, so we seed
    -- the reserved space from last frame's result (one-frame lag, self-corrects immediately after).
    local maxStickyRows = settings.stickyRowsEnabled and math.min(MAX_STICKY_PARENT_ROWS, math.max(0, totalRows - 1)) or 0
    local reservedStickyRows = math.min(spawnedUI.stickyRowCountById[childId] or 0, maxStickyRows)
    local reservedHeight = reservedStickyRows * rowHeight
    local scrollableHeight = math.max(0, childHeight - reservedHeight)
    local scrollRows = math.max(0, math.floor(scrollableHeight / rowHeight))

    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, 7.5 * style.viewSize, spawnedUI.cellPadding)
    ImGui.PushStyleVar(ImGuiStyleVar.ScrollbarSize, 12 * style.viewSize)

    local containerFlags = ImGuiWindowFlags.NoMove + ImGuiWindowFlags.NoScrollbar + ImGuiWindowFlags.NoScrollWithMouse
    ImGui.BeginChild(childId .. "StickyContainer", 0, childHeight, false, containerFlags)
    local _, reservedTopY = ImGui.GetCursorScreenPos()
    if reservedHeight > 0 then
        ImGui.SetCursorPosY(ImGui.GetCursorPosY() + reservedHeight)
    end
    ImGui.BeginChild(childId, 0, scrollableHeight, false, ImGuiWindowFlags.NoMove)
    input.updateContext("hierarchy")
    local hierarchyScrollY = math.max(0, ImGui.GetScrollY())

    local windowX, windowY = ImGui.GetWindowPos()
    local contentMinX, contentMinY = ImGui.GetWindowContentRegionMin()
    local contentMaxX, _ = ImGui.GetWindowContentRegionMax()
    local viewportX = windowX + contentMinX
    local viewportY = reservedTopY
    local viewportWidth = math.max(0, contentMaxX - contentMinX)

    local forceFullPass = false
    if spawnedUI.scrollToSelected and #spawnedUI.selectedPaths > 0 then
        local selectedRef = spawnedUI.selectedPaths[1].ref
        for _, entry in ipairs(entries) do
            if entry.ref == selectedRef then
                forceFullPass = true
                break
            end
        end

        if not forceFullPass then
            -- Selected entry is not in current list (e.g. transient states);
            -- clear request to avoid forcing full render indefinitely.
            spawnedUI.scrollToSelected = false
        end
    end

    -- Start the table
    local hasVerticalScrollbar = false
    if ImGui.BeginTable(tableId, 1, ImGuiTableFlags.ScrollX) then
        local effectiveScrollY = math.max(hierarchyScrollY, math.max(0, ImGui.GetScrollY()))
        firstVisibleIndex = math.min(#entries, math.floor(effectiveScrollY / rowHeight) + 1)
        spawnedUI.hierarchyFirstVisibleIndexById[childId] = firstVisibleIndex

        local lastRenderedRowIndex = 0
        if forceFullPass then
            for idx, entry in ipairs(entries) do
                spawnedUI.drawElement(entry, false, idx)
                lastRenderedRowIndex = idx
            end
        else
            spawnedUI.clipper = ImGuiListClipper.new()
            spawnedUI.clipper:Begin(#entries, rowHeight)
            local capturedFirstVisibleIndex = false

            while spawnedUI.clipper:Step() do
                local startIndex = spawnedUI.clipper.DisplayStart + 1
                local endIndex = spawnedUI.clipper.DisplayEnd

                if not capturedFirstVisibleIndex then
                    firstVisibleIndex = math.max(firstVisibleIndex, startIndex)
                    spawnedUI.hierarchyFirstVisibleIndexById[childId] = firstVisibleIndex
                    capturedFirstVisibleIndex = true
                end

                for idx = startIndex, endIndex do
                    local entry = entries[idx]
                    if entry then
                        spawnedUI.drawElement(entry, false, idx)
                        lastRenderedRowIndex = idx
                    end
                end
            end
        end

        local fillerRows = math.max(0, scrollRows - #entries)
        if fillerRows > 0 then
            for fillerOffset = 1, fillerRows do
                spawnedUI.drawElement(nil, true, lastRenderedRowIndex + fillerOffset)
            end
        end
        spawnedUI.drawReorderPreview()
        spawnedUI.reorderPreview = nil

        hasVerticalScrollbar = ImGui.GetScrollMaxY() > 0
        ImGui.EndTable()
    end

    hasVerticalScrollbar = hasVerticalScrollbar or ImGui.GetScrollMaxY() > 0
    ImGui.EndChild()

    if hasVerticalScrollbar then
        viewportWidth = math.max(0, viewportWidth - ImGui.GetStyle().ScrollbarSize)
    end

    local stickyEntries = collectStickyParentEntries(entries, firstVisibleIndex, maxStickyRows)

    -- Commit the reservation used for *next* frame's layout, but only once it's settled.
    -- While a mouse button is held (e.g. dragging the scrollbar thumb) we don't touch it at
    -- all, since resizing mid-drag is exactly what can make the scroll offset (and thus this
    -- very count) flip-flop from frame to frame.
    if not ImGui.IsMouseDown(ImGuiMouseButton.Left) then
        local rawStickyCount = #stickyEntries
        local pending = spawnedUI.stickyRowPendingById[childId]
        if pending and pending.count == rawStickyCount then
            pending.streak = pending.streak + 1
        else
            pending = { count = rawStickyCount, streak = 1 }
            spawnedUI.stickyRowPendingById[childId] = pending
        end
        if pending.streak >= STICKY_RESERVE_CONFIRM_FRAMES then
            spawnedUI.stickyRowCountById[childId] = rawStickyCount
        end
    end

    if #stickyEntries > 0 and viewportWidth > 0 then
        local containerCursorX, containerCursorY = ImGui.GetCursorScreenPos()
        local overlayHeight = #stickyEntries * rowHeight
        local backgroundR, backgroundG, backgroundB, _ = ImGui.GetStyleColorVec4(ImGuiCol.WindowBg)

        ImGui.SetCursorScreenPos(viewportX, viewportY)
        ImGui.PushStyleColor(ImGuiCol.ChildBg, backgroundR, backgroundG, backgroundB, 1)
        local overlayFlags = ImGuiWindowFlags.NoMove + ImGuiWindowFlags.NoScrollbar + ImGuiWindowFlags.NoScrollWithMouse
        ImGui.BeginChild(tableId .. "StickyOverlay", viewportWidth, overlayHeight, false, overlayFlags)
        input.updateContext("hierarchy")

        if ImGui.BeginTable(tableId .. "StickyParents", 1, ImGuiTableFlags.NoHostExtendX) then
            spawnedUI.elementCount = 0
            ImGui.PushID("stickyHierarchyParents")
            for _, entry in ipairs(stickyEntries) do
                spawnedUI.drawElement(entry, false, nil, true)
            end
            ImGui.PopID()
            ImGui.EndTable()
        end

        local stickyBorderThickness = math.max(1, 2 * style.viewSize)
        local stickyBorderX = viewportX + stickyBorderThickness * 0.5
        ImGui.ImDrawListAddLine(
            ImGui.GetWindowDrawList(),
            stickyBorderX,
            viewportY,
            stickyBorderX,
            viewportY + overlayHeight,
            0xFFFFFFFF,
            stickyBorderThickness
        )

        spawnedUI.drawReorderPreview()
        spawnedUI.reorderPreview = nil
        ImGui.EndChild()
        ImGui.PopStyleColor()
        ImGui.SetCursorScreenPos(containerCursorX, containerCursorY)
    end

    ImGui.EndChild()
    ImGui.PopStyleVar(2)
end

function spawnedUI.drawPinnedHierarchyWindow()
    if not spawnedUI.pinnedHierarchy.open then
        return
    end

    wu = wu or GetMod("WindowUtils") or ImGui

    spawnedUI.ensureCache()

    local groupEntry = getPinnedHierarchyGroupEntry()
    if not groupEntry then
        spawnedUI.pinnedHierarchy.open = false
        spawnedUI.pinnedHierarchy.groupId = nil
        return
    end

    local title = style.resolveActionLabelNoIconOnly(IconGlyphs.PinOutline, groupEntry.ref.name, "focusedHierarchyWindow")
    ImGui.SetNextWindowSize(400 * style.viewSize, 500 * style.viewSize, ImGuiCond.FirstUseEver)
    spawnedUI.pinnedHierarchy.open = wu.Begin(title, true, ImGuiWindowFlags.NoCollapse)

    if spawnedUI.pinnedHierarchy.open then
        input.updateContext("main")

        local focusedEntries = collectPinnedHierarchyEntries(groupEntry)
        local _, ySpace = ImGui.GetContentRegionAvail()
        if ySpace > 0 then
            spawnedUI.drawHierarchy({
                entries = focusedEntries,
                childId = "##focusedHierarchy",
                tableId = "##focusedHierarchyTable",
                childHeight = ySpace
            })
        end

        wu.End()
    end
end

function spawnedUI.drawDivider()
    local minSize = 200 * style.viewSize

    if spawnedUI.dividerHovered then
        ImGui.PushStyleColor(ImGuiCol.ChildBg, 0.4, 0.4, 0.4, 1.0) -- RGBA values
    else
        ImGui.PushStyleColor(ImGuiCol.ChildBg, 0.2, 0.2, 0.2, 1.0) -- RGBA values
    end

    ImGui.BeginChild("##verticalDividor", 0, 7.5 * style.viewSize, false, ImGuiWindowFlags.NoMove )
    local wx, wy = ImGui.GetContentRegionAvail()
    local textWidth, textHeight = ImGui.CalcTextSize(IconGlyphs.DragHorizontalVariant)

    ImGui.SetCursorPosX((wx - textWidth) / 2)
    ImGui.SetCursorPosY(1 * style.viewSize + (wy - textHeight) / 2)
    ImGui.Text(IconGlyphs.DragHorizontalVariant)

    ImGui.EndChild()
    if spawnedUI.dividerHovered and ImGui.IsMouseDoubleClicked(ImGuiMouseButton.Left) then
        settings.editorBottomSize = minSize
        settings.save()
    end
    spawnedUI.dividerHovered = ImGui.IsItemHovered()
    if spawnedUI.dividerHovered and ImGui.IsMouseDragging(0, 0) then
        spawnedUI.dividerDragging = true
    end
    if spawnedUI.dividerDragging and not ImGui.IsMouseDragging(0, 0) then
        spawnedUI.dividerDragging = false
    end
    if spawnedUI.dividerDragging then
        local _, dy = ImGui.GetMouseDragDelta(0, 0)
        settings.editorBottomSize = settings.editorBottomSize - dy
        settings.editorBottomSize = math.max(settings.editorBottomSize, minSize)
        ImGui.ResetMouseDragDelta()

        settings.save()
    end
    if spawnedUI.dividerHovered or spawnedUI.dividerDragging then
        ImGui.SetMouseCursor(ImGuiMouseCursor.ResizeNS)
    end
    ImGui.PopStyleColor()
end

---@param width number
local function sameLineDummy(width)
    ImGui.SameLine()
    ImGui.Dummy((width or 0) * style.viewSize, 0)
    ImGui.SameLine()
end

---@param id number?
---@return string?
local function getGroupNameById(id)
    if not id then
        return nil
    end

    for _, entry in pairs(spawnedUI.containerPaths or {}) do
        if entry and entry.ref and entry.ref.id == id then
            return entry.ref.name
        end
    end

    return nil
end

---@param ready boolean
---@param sourceName string
---@param targetName string
---@param issues string[]
local function drawBrushStatusTooltip(ready, sourceName, targetName, issues)
    if not ImGui.IsItemHovered() then
        return
    end

    local function isAvailableName(name)
        return type(name) == "string" and name ~= "" and name ~= "None"
    end

    ImGui.BeginTooltip()

    style.mutedText("Source group:")
    ImGui.SameLine()
    if isAvailableName(sourceName) then
        ImGui.Text(sourceName)
    else
        style.styledText("None", style.warnColor)
    end

    style.mutedText("Target group:")
    ImGui.SameLine()
    if isAvailableName(targetName) then
        ImGui.Text(targetName)
    else
        style.styledText("None", style.warnColor)
    end

    if issues and #issues > 0 then
        ImGui.Spacing()
        style.mutedText("Issues:")
        for _, issue in ipairs(issues) do
            style.styledText("- " .. issue, style.warnColor)
        end
    end

    ImGui.EndTooltip()
end

---@protected
function spawnedUI.drawTop()
    local previousFilter = spawnedUI.filter
    ImGui.PushItemWidth(200 * style.viewSize)
    spawnedUI.filter = ImGui.InputTextWithHint('##Filter', 'Search for element...', spawnedUI.filter, 100)
    ImGui.PopItemWidth()
    if spawnedUI.filter ~= previousFilter then
        spawnedUI.invalidateCache(false)
    end

    if spawnedUI.filter ~= '' then
        ImGui.SameLine()
        style.pushButtonNoBG(true)
        if ImGui.Button(IconGlyphs.Close) then
            spawnedUI.filter = ''
            spawnedUI.invalidateCache(false)
            if #spawnedUI.selectedPaths == 1 then
                spawnedUI.selectedPaths[1].ref:expandAllParents()
                spawnedUI.scrollToSelected = true
            end
        end
        style.pushButtonNoBG(false)
    end

    ImGui.PushItemWidth(200 * style.viewSize)
    -- Left as typed: group names are free-form now, and are only cleaned up (of path separators)
    -- when the group is actually created.
    spawnedUI.newGroupName, changed = ImGui.InputTextWithHint('##newG', 'New group name...', spawnedUI.newGroupName, 100)
    ImGui.PopItemWidth()

    ImGui.SameLine()
    local groupTypeLabels = getGroupTypeLabels()
    ImGui.SetNextItemWidth(utils.getTextMaxWidth(groupTypeLabels) + 60)
    if ImGui.BeginCombo("##groupType", getGroupTypeLabel(spawnedUI.newGroupTypeIndex)) then
        for index, _ in ipairs(spawnedUI.groupTypes) do
            local selected = spawnedUI.newGroupTypeIndex == index
            if ImGui.Selectable(getGroupTypeLabel(index, "groupTypeOption" .. tostring(index)), selected) then
                spawnedUI.newGroupTypeIndex = index
            end
            if selected then
                ImGui.SetItemDefaultFocus()
            end
        end
        ImGui.EndCombo()
    end

    ImGui.SameLine()
    if ImGui.Button("Add group") then
        sessionSnapshot.consume("added a group")
        local group = require("modules/classes/editor/positionableGroup"):new(spawnedUI)
        local selectedType = spawnedUI.groupTypes[spawnedUI.newGroupTypeIndex]

        if selectedType == "Randomized" then
            group = require("modules/classes/editor/randomizedGroup"):new(spawnedUI)
        elseif selectedType == "Scattered" then
            group = require("modules/classes/editor/scatteredGroup"):new(spawnedUI)
        end

        local cleanedName = elementClass.sanitizeDisplayName(spawnedUI.newGroupName)
        group.name = cleanedName ~= "" and cleanedName or "New Group"
        group:setParent(spawnedUI.spawner.baseUI.spawnUI.getSpawnTargetParent())
        history.addAction(history.getInsert({ group }))
    end

    local hasHierarchy = hasRootChildren()

    -- Saving row. Kept on a line of its own because the status text next to it grows and shrinks
    -- ("2 unsaved | auto-save in 4m 12s", "Saving \"X\"... 340 KB"), which on a shared row would keep
    -- shoving the hierarchy actions sideways.
    style.pushButtonNoBG(true)

    ImGui.BeginDisabled(not hasHierarchy)
    if ImGui.Button(IconGlyphs.ContentSaveAllOutline) then
        spawnedUI.saveAllRootGroups()
    end
    style.tooltip("Save all root groups")
    ImGui.EndDisabled()

    ImGui.SameLine()
    -- Not gated on hasHierarchy: this is a setting, and it stays meaningful with an empty tab.
    local nextAutoSave, autoSaveToggled = style.toggleButton(IconGlyphs.TimerRefreshOutline, settings.autoSaveEnabled == true)
    if autoSaveToggled then
        settings.autoSaveEnabled = nextAutoSave
        settings.save()
    end
    style.tooltip(spawnedUI.getAutoSaveTooltip())

    -- Offered only until the user starts working: restoring on top of a session already in progress
    -- would mix two sessions. Still reachable afterwards from the Projects tab.
    --
    -- Deliberately not gated on hasHierarchy: an empty Spawned tab is precisely when restoring a
    -- previous session is most useful.
    if sessionSnapshot.canOffer() then
        ImGui.SameLine()
        if ImGui.Button(IconGlyphs.BackupRestore) then
            sessionRestorePopup.requestOpen()
        end
        local snapshotIndex = sessionSnapshot.available
        style.tooltip(string.format(
            "Restore previous session\n\n%d root item%s from %s.\nThis disappears once you start spawning; it stays available in the Projects tab.",
            #snapshotIndex.entries,
            #snapshotIndex.entries == 1 and "" or "s",
            tostring(snapshotIndex.savedAt)))
    end

    style.pushButtonNoBG(false)

    local saveStatus = spawnedUI.getSaveStatusLabel()
    if saveStatus then
        ImGui.SameLine()
        style.mutedText(saveStatus)
    end

    -- Hierarchy actions
    local nextEditorState, editorToggleChanged = style.toggleButton(IconGlyphs.Rotate3d, editor.active)
    if editorToggleChanged then
        editor.toggle(nextEditorState)
    end
    style.tooltip("Toggle 3D-Editor mode")

    if editor.isBrushActive and editor.setBrushActive then
        ImGui.SameLine()
        local brushDisabled = not editor.active
        if brushDisabled then
            style.pushGreyedOut(true)
            ImGui.Button(IconGlyphs.Brush)
            style.popGreyedOut(true)
        else
            local nextBrushState, brushToggleChanged = style.toggleButton(IconGlyphs.Brush, editor.isBrushActive())
            if brushToggleChanged then
                editor.setBrushActive(nextBrushState)
            end
        end

        if editor.active then
            style.tooltip("Toggle Brush paint mode\nWorks with Randomized group\nHold LMB to Paint\nHold Shift + LMB to Erase")
        else
            style.tooltip("Brush is only available in 3D-Editor mode")
        end
    end

    style.pushButtonNoBG(true)

    local rightHierarchyActionIcons = {
        IconGlyphs.AxisArrow,
        IconGlyphs.MapMarkerPlusOutline,
        IconGlyphs.MapMarkerMinusOutline,
        IconGlyphs.LockPlusOutline,
        IconGlyphs.LockOpenMinusOutline,
        IconGlyphs.EyePlusOutline,
        IconGlyphs.EyeMinusOutline
    }
    local rightGroupWidth = 0
    local framePaddingX = ImGui.GetStyle().FramePadding.x
    for idx, icon in ipairs(rightHierarchyActionIcons) do
        local iconWidth, _ = ImGui.CalcTextSize(icon)
        rightGroupWidth = rightGroupWidth + iconWidth + framePaddingX * 2
        if idx < #rightHierarchyActionIcons then
            rightGroupWidth = rightGroupWidth + ImGui.GetStyle().ItemSpacing.x
        end
    end

    ImGui.SameLine()
    ImGui.BeginDisabled(not hasHierarchy)
    if ImGui.Button(IconGlyphs.CollapseAllOutline) then
        for _, child in pairs(spawnedUI.root.childs) do
            child:setHeaderStateRecursive(false)
        end
    end
    style.tooltip("Fold all groups")

    ImGui.SameLine()
    if ImGui.Button(IconGlyphs.ExpandAllOutline) then
        spawnedUI.root:setHeaderStateRecursive(true)
    end
    style.tooltip("Expand all groups")
    ImGui.EndDisabled()

    ImGui.SameLine()
    if ImGui.Button(IconGlyphs.Undo) then
        history.requestUndo()
    end
    if ImGui.IsItemHovered() then style.setCursorRelative(10, 10) end
    style.tooltip(tostring(history.index) .. " actions left")
    ImGui.SameLine()
    if ImGui.Button(IconGlyphs.Redo) then
        history.requestRedo()
    end
    if ImGui.IsItemHovered() then style.setCursorRelative(10, 10) end
    style.tooltip(tostring(#history.actions - history.index) .. " actions left")

    local pendingCount = history.getPendingCount and history.getPendingCount() or 0
    if pendingCount > 0 then
        ImGui.SameLine()
        style.mutedText("Applying " .. tostring(pendingCount) .. "...")
    end

    ImGui.SameLine()

    style.mutedText(IconGlyphs.InformationOutline)
    if ImGui.IsItemHovered() then
        local screenWidth, screenHeight = GetDisplayResolution()
        ImGui.SetNextWindowPos(screenWidth * 0.5, screenHeight * 0.5, ImGuiCond.Always, 0.5, 0.5)
        local function shortcutMenuItem(icon, text, shortcut, idSuffix)
            if icon == nil then
                ImGui.MenuItem(text, shortcut)
                return
            end

            local itemId = idSuffix and ("spawnedShortcuts:" .. tostring(idSuffix)) or nil
            local label = style.resolveActionLabelNoIconOnly(icon, text, itemId)
            ImGui.MenuItem(label, shortcut)
        end

        if ImGui.Begin("##wb-shortcuts-popup-wui", ImGuiWindowFlags.NoResize + ImGuiWindowFlags.NoMove + ImGuiWindowFlags.NoTitleBar + ImGuiWindowFlags.AlwaysAutoResize) then
            if ImGui.BeginTable("##shortcutsTable", 2, ImGuiTableFlags.SizingStretchSame) then
                ImGui.TableNextColumn()

                style.mutedText("GENERAL")
                ImGui.Separator()
                ImGui.Spacing()

                shortcutMenuItem(IconGlyphs.Undo, "Undo", "CTRL + Z", "generalUndo")
                shortcutMenuItem(IconGlyphs.Redo, "Redo", "CTRL + Y", "generalRedo")
                shortcutMenuItem(nil, "Select all", "CTRL + A")
                shortcutMenuItem(nil, "Unselect all", "ESC")
                shortcutMenuItem(IconGlyphs.ContentSaveAllOutline, "Save all", "CTRL + S", "generalSaveAll")
                
                ImGui.Dummy(0, 8 * style.viewSize)

                style.mutedText("SCENE HIERARCHY")
                ImGui.Separator()
                ImGui.Spacing()

                shortcutMenuItem(nil, "Open context menu on selected", "RMB")
                shortcutMenuItem(IconGlyphs.ContentCopy, "Copy selected", "CTRL + C", "hierCopy")
                shortcutMenuItem(IconGlyphs.ContentPaste, "Paste selected", "CTRL + V", "hierPaste")
                shortcutMenuItem(IconGlyphs.ContentDuplicate, "Duplicate selected", "CTRL + D", "hierDuplicate")
                shortcutMenuItem(IconGlyphs.ContentCut, "Cut selected", "CTRL + X", "hierCut")
                shortcutMenuItem(IconGlyphs.DeleteOutline, "Delete selected", "DEL", "hierDelete")
                shortcutMenuItem(IconGlyphs.EyeOutline, "Toggle selected visibility", "H", "hierToggleVisible")
                shortcutMenuItem(nil, "Multiselect", "Hold CTRL")
                shortcutMenuItem(nil, "Range select", "Hold SHIFT")
                shortcutMenuItem(IconGlyphs.ArrowUpLeftBold, "Move selected to parent level", "BACKSPACE", "hierMoveParent")
                shortcutMenuItem(IconGlyphs.ArrowTopLeftBoldBoxOutline, "Move selected to root", "CTRL + BACKSPACE", "hierMoveRoot")
                shortcutMenuItem(IconGlyphs.FolderMultiplePlusOutline, "Move selected to new group", "CTRL + G", "hierMoveNewGroup")
                shortcutMenuItem(IconGlyphs.Download, "Drop selected to floor", "CTRL + E", "hierDropToFloor")
                shortcutMenuItem(IconGlyphs.PlusBoxOutline, "Set as \"Spawn New\" group", "CTRL + N", "hierSetSpawnNewGroup")
                shortcutMenuItem(nil, "Transform (move / rotate / scale)", "LMB Drag")
                shortcutMenuItem(nil, "Transform slow", "Hold SHIFT + LMB Drag")
                shortcutMenuItem(nil, "Transform extra-slow", "Hold ALT + LMB Drag")
                shortcutMenuItem(nil, "Transform fast", "Hold CTRL + LMB Drag")

                ImGui.TableNextColumn()

                style.mutedText("3D-EDITOR Camera")
                ImGui.Separator()
                ImGui.Spacing()

                shortcutMenuItem(IconGlyphs.AxisZRotateClockwise, "Rotate camera", "Hold MMB", "cameraRotate")
                shortcutMenuItem(IconGlyphs.CameraControl, "Move camera", "SHIFT + Hold MMB", "cameraMove")
                shortcutMenuItem(IconGlyphs.Magnify, "Zoom", "CTRL + Hold MMB", "cameraZoom")
                shortcutMenuItem(IconGlyphs.Target, "Center camera on selected", "TAB", "cameraCenter")
                
                ImGui.Dummy(0, 8 * style.viewSize)

                style.mutedText("3D-EDITOR")
                ImGui.Separator()
                ImGui.Spacing()

                shortcutMenuItem(IconGlyphs.RepeatOnce, "Repeat last spawn under cursor", "CTRL + R", "editorRepeatSpawn")
                shortcutMenuItem(nil, "Open spawn new popup", "SHIFT + A")
                shortcutMenuItem(nil, "Open depth select menu", "SHIFT + D")
                shortcutMenuItem(IconGlyphs.Brush, "Brush paint", "Hold LMB", "editorBrushPaint")
                shortcutMenuItem(IconGlyphs.Eraser, "Brush erase", "Hold SHIFT + LMB", "editorBrushErase")
                shortcutMenuItem(nil, "Select / Confirm", "LMB")
                shortcutMenuItem(nil, "Open context menu / Cancel", "RMB")
                shortcutMenuItem(IconGlyphs.SelectDrag, "Box Select", "CTRL + LMB Drag", "editorBoxSelect")
                shortcutMenuItem(IconGlyphs.AxisArrow, "Move selected on axis", "G -> X/Y/Z", "editorMoveAxis")
                shortcutMenuItem(IconGlyphs.AxisXArrowLock, "Move selected, locked on axis", "G -> SHIFT + X/Y/Z", "editorMoveAxisLocked")
                shortcutMenuItem(IconGlyphs.RotateOrbit, "Rotate selected", "R -> X/Y/Z  -> (Numeric)", "editorRotate")
                shortcutMenuItem(IconGlyphs.RulerSquare, "Scale selected on axis", "S -> X/Y/Z -> (Numeric)", "editorScale")
                shortcutMenuItem(IconGlyphs.Ruler, "Scale selected, locked on axis", "S -> SHIFT + X/Y/Z  -> (Numeric)", "editorScaleLocked")

                ImGui.EndTable()
            end

            ImGui.End()
        end

        local x, y = ImGui.GetWindowSize()
        spawnedUI.infoWindowSize = { x = x, y = y }
    end

    local rightGroupStartX = ImGui.GetWindowWidth() - ImGui.GetStyle().WindowPadding.x - rightGroupWidth
    ImGui.SameLine()
    ImGui.SetCursorPosX(math.max(ImGui.GetCursorPosX(), rightGroupStartX))

    local nextSelectedVisualizerState, selectedVisualizerChanged = style.toggleButton(IconGlyphs.AxisArrow, selectedVisualizersEnabled())
    if selectedVisualizerChanged then
        settings.selectedVisualizersEnabled = nextSelectedVisualizerState
        settings.save()
        refreshSelectedVisualizers()
    end
    drawSelectedVisualizerToggleTooltip()

    ImGui.SameLine()
    ImGui.BeginDisabled(not hasHierarchy)
    if ImGui.Button(IconGlyphs.MapMarkerPlusOutline) then
        local targets = spawnedUI.filter ~= "" and collectVisualizationTargets(spawnedUI.filteredPaths) or collectVisualizationTargets(spawnedUI.paths)
        applyElementChangesBatched(targets, function(entry)
            if spawnedUI.canToggleVisualization(entry) then
                entry.spawnable:setPreview(true)
            end
        end)
    end
    style.tooltip("Enable visualization helpers for all elements (or filtered elements)")

    ImGui.SameLine()
    if ImGui.Button(IconGlyphs.MapMarkerMinusOutline) then
        local targets = spawnedUI.filter ~= "" and collectVisualizationTargets(spawnedUI.filteredPaths) or collectVisualizationTargets(spawnedUI.paths)
        applyElementChangesBatched(targets, function(entry)
            if spawnedUI.canToggleVisualization(entry) then
                entry.spawnable:setPreview(false)
            end
        end)
    end
    style.tooltip("Disable visualization helpers for all elements (or filtered elements)")

    ImGui.SameLine()
    if ImGui.Button(IconGlyphs.LockPlusOutline) then
        if spawnedUI.filter ~= "" then
            local targets = {}
            for _, entry in pairs(spawnedUI.filteredPaths) do
                if spawnedUI.canMutateLockedState(entry.ref) then
                    table.insert(targets, entry.ref)
                end
            end
            applyElementChangesBatched(targets, function(entry)
                entry:setLocked(true, true)
            end)
        else
            local targets = {}
            for _, child in pairs(spawnedUI.root.childs) do
                if spawnedUI.canMutateLockedState(child) then
                    table.insert(targets, child)
                end
            end
            applyElementChangesBatched(targets, function(entry)
                entry:setLockedRecursive(true, true)
            end)
        end
    end
    style.tooltip("Lock all elements (or filtered elements)")

    ImGui.SameLine()
    if ImGui.Button(IconGlyphs.LockOpenMinusOutline) then
        if spawnedUI.filter ~= "" then
            local targets = {}
            for _, entry in pairs(spawnedUI.filteredPaths) do
                if spawnedUI.canMutateLockedState(entry.ref) then
                    table.insert(targets, entry.ref)
                end
            end
            applyElementChangesBatched(targets, function(entry)
                entry:setLocked(false, true)
            end)
        else
            local targets = {}
            for _, child in pairs(spawnedUI.root.childs) do
                if spawnedUI.canMutateLockedState(child) then
                    table.insert(targets, child)
                end
            end
            applyElementChangesBatched(targets, function(entry)
                entry:setLockedRecursive(false, true)
            end)
        end
    end
    style.tooltip("Unlock all elements (or filtered elements)")

    ImGui.SameLine()
    if ImGui.Button(IconGlyphs.EyePlusOutline) then
        if spawnedUI.filter ~= "" then
            local targets = {}
            for _, entry in pairs(spawnedUI.filteredPaths) do
                if spawnedUI.canToggleVisibility(entry.ref) then
                    table.insert(targets, entry.ref)
                end
            end
            applyElementChangesBatched(targets, function(entry)
                entry:setVisible(true, true)
            end)
        else
            local targets = {}
            for _, child in pairs(spawnedUI.root.childs) do
                if spawnedUI.canToggleVisibility(child) then
                    table.insert(targets, child)
                end
            end
            applyElementChangesBatched(targets, function(entry)
                entry:setVisibleRecursive(true, true)
            end)
        end
    end
    style.tooltip("Show all elements (or filtered elements)")

    ImGui.SameLine()
    if ImGui.Button(IconGlyphs.EyeMinusOutline) then
        if spawnedUI.filter ~= "" then
            local targets = {}
            for _, entry in pairs(spawnedUI.filteredPaths) do
                if spawnedUI.canToggleVisibility(entry.ref) then
                    table.insert(targets, entry.ref)
                end
            end
            applyElementChangesBatched(targets, function(entry)
                entry:setVisible(false, true)
            end)
        else
            local targets = {}
            for _, child in pairs(spawnedUI.root.childs) do
                if spawnedUI.canToggleVisibility(child) then
                    table.insert(targets, child)
                end
            end
            applyElementChangesBatched(targets, function(entry)
                entry:setVisibleRecursive(false, true)
            end)
        end
    end
    style.tooltip("Hide all elements (or filtered elements)")
    ImGui.EndDisabled()

    if editor.active and editor.isBrushActive and editor.isBrushActive() then
        ImGui.Dummy(0, 4 * style.viewSize)

        local brushSourceGroupId = editor.getBrushSourceGroupId and editor.getBrushSourceGroupId() or nil
        local brushSourceEntryCount = editor.getBrushSourceEntryCount and editor.getBrushSourceEntryCount() or 0
        local brushTargetGroupId = editor.getBrushTargetGroupId and editor.getBrushTargetGroupId() or nil
        local activeSpawnUI = spawnedUI.spawner and spawnedUI.spawner.baseUI and spawnedUI.spawner.baseUI.spawnUI or nil
        local selectedGroupIndex = activeSpawnUI and activeSpawnUI.selectedGroup or 0
        local selectedTargetRef = selectedGroupIndex ~= 0
            and spawnedUI.containerPaths[selectedGroupIndex]
            and spawnedUI.containerPaths[selectedGroupIndex].ref
            or nil
        local hasBrushSourceGroup = brushSourceGroupId ~= nil
        local hasBrushSourceEntries = brushSourceEntryCount > 0
        local hasBrushTargetGroup = brushTargetGroupId ~= nil
        local brushTargetMatchesSource = hasBrushSourceGroup
            and selectedTargetRef ~= nil
            and selectedTargetRef ~= spawnedUI.root
            and selectedTargetRef.id == brushSourceGroupId
        local brushReady = hasBrushSourceGroup and hasBrushSourceEntries and hasBrushTargetGroup and not brushTargetMatchesSource
        local brushIssues = {}

        local sourceGroupName = getGroupNameById(brushSourceGroupId) or "None"
        local targetGroupName = getGroupNameById(brushTargetGroupId)
        if not targetGroupName then
            if selectedTargetRef == spawnedUI.root then
                targetGroupName = "Root (invalid)"
            elseif selectedTargetRef and selectedTargetRef.name then
                targetGroupName = selectedTargetRef.name
            else
                targetGroupName = "None"
            end
        end

        if not hasBrushSourceGroup then
            table.insert(brushIssues, "No randomized source group selected.")
        elseif not hasBrushSourceEntries then
            table.insert(brushIssues, "Selected randomized group is empty, add elements to paint.")
        end

        if brushTargetMatchesSource then
            table.insert(brushIssues, "Target group cannot be the same as source group.")
        elseif not hasBrushTargetGroup then
            table.insert(brushIssues, "No valid target group, set a normal group as \"Spawn New\" target (root is invalid).")
        end

        if brushReady then
            local readyLabel = style.resolveActionLabelNoIconOnly(IconGlyphs.Brush, "Ready", nil)
            style.styledText(readyLabel, style.successColor)
        else
            local notReadyLabel = style.resolveActionLabelNoIconOnly(IconGlyphs.Brush, "Not ready", nil)
            style.styledText(notReadyLabel, style.warnColor)
        end
        drawBrushStatusTooltip(brushReady, sourceGroupName, targetGroupName, brushIssues)
        sameLineDummy(8)
        style.mutedText("Size")
        ImGui.SameLine()

        local radius = editor.getBrushRadius and editor.getBrushRadius() or 10
        local nextRadius, radiusChanged = field.advancedTrackedFloat(nil, "##brushRadiusControl", radius, {
            step = 0.25,
            shiftStep = 0.25,
            min = 1,
            max = 200,
            format = "%.1f",
            shiftFormat = "%.1f",
            suffix = " m",
            width = 70
        })

        if radiusChanged and editor.setBrushRadius then
            editor.setBrushRadius(nextRadius)
        end

        sameLineDummy(8)
        style.mutedText("Intensity")
        ImGui.SameLine()

        local intensity = editor.getBrushIntensity and editor.getBrushIntensity() or 12.5
        local nextIntensity, intensityChanged = field.advancedTrackedFloat(nil, "##brushIntensityControl", intensity, {
            step = 0.2,
            shiftStep = 0.2,
            min = 1,
            max = 40,
            format = "%.1f",
            shiftFormat = "%.1f",
            suffix = " /s",
            width = 70
        })

        if intensityChanged and editor.setBrushIntensity then
            editor.setBrushIntensity(nextIntensity)
        end
        style.tooltip("Brush paint frequency (strokes per second)")

        sameLineDummy(8)
        local paintHidden = editor.getBrushPaintHidden and editor.getBrushPaintHidden() or false
        local hiddenPaintLabel, hiddenPaintHiddenText = style.resolveActionLabel(IconGlyphs.DotsHexagon, "Dot painting", "brushPaintHidden", nil, true)
        local nextHiddenPaint, hiddenPaintChanged = style.toggleButton(hiddenPaintLabel, paintHidden)
        if hiddenPaintChanged and editor.setBrushPaintHidden then
            editor.setBrushPaintHidden(nextHiddenPaint)
        end
        style.tooltipActionLabel(hiddenPaintHiddenText,
            (hiddenPaintHiddenText and hiddenPaintHiddenText ~= "" and (hiddenPaintHiddenText .. "\n") or "")
            .. "Paint hidden objects instead of rendering them, to help with performances.\nEach hidden spawn is shown as a dot marker.\nDots are cleared when Brush mode is disabled.")

        local effectiveHiddenPaint = hiddenPaintChanged and nextHiddenPaint or paintHidden
        if effectiveHiddenPaint then
            ImGui.SameLine()
            local dotColor = editor.getBrushHiddenDotColor and editor.getBrushHiddenDotColor() or { 0.0, 0.6, 1.0 }
            local colorFlags = nil
            if ImGuiColorEditFlags then
                colorFlags = (ImGuiColorEditFlags.NoInputs or 0) + (ImGuiColorEditFlags.NoLabel or 0) + (ImGuiColorEditFlags.NoAlpha or 0)
            end

            local nextDotColor, dotColorChanged = style.trackedColor(nil, "##brushDotColor", dotColor, 14, colorFlags)
            if dotColorChanged and editor.setBrushHiddenDotColor then
                editor.setBrushHiddenDotColor(nextDotColor)
            end
            local dotColorPreview = dotColorChanged and nextDotColor or dotColor
            style.tooltip("Dot color")
        end

        ImGui.Dummy(0, 2 * style.viewSize)
        style.mutedText("Rotation variations")

        ImGui.SameLine()
        local randomRotX = editor.getBrushRandomizeRotationAxis and editor.getBrushRandomizeRotationAxis("x") or false
        local nextRotX, rotXChanged = ImGui.Checkbox("Pitch##brushRandomRotX", randomRotX)
        if rotXChanged and editor.setBrushRandomizeRotationAxis then
            editor.setBrushRandomizeRotationAxis("x", nextRotX)
        end
        style.tooltip("Randomize rotation around X axis (Pitch).")

        sameLineDummy(2)
        local randomRotY = editor.getBrushRandomizeRotationAxis and editor.getBrushRandomizeRotationAxis("y") or false
        local nextRotY, rotYChanged = ImGui.Checkbox("Roll##brushRandomRotY", randomRotY)
        if rotYChanged and editor.setBrushRandomizeRotationAxis then
            editor.setBrushRandomizeRotationAxis("y", nextRotY)
        end
        style.tooltip("Randomize rotation around Y axis (Roll).")

        sameLineDummy(2)
        local randomRotZ = editor.getBrushRandomizeRotationAxis and editor.getBrushRandomizeRotationAxis("z") or false
        local nextRotZ, rotZChanged = ImGui.Checkbox("Yaw##brushRandomRotZ", randomRotZ)
        if rotZChanged and editor.setBrushRandomizeRotationAxis then
            editor.setBrushRandomizeRotationAxis("z", nextRotZ)
        end
        style.tooltip("Randomize rotation around Z axis (Yaw).")

        sameLineDummy(8)
        style.mutedText("Scale variations")
        ImGui.SameLine()
        local scaleVariation = editor.getBrushScaleVariation and editor.getBrushScaleVariation() or 0
        local nextScaleVariation, scaleVariationChanged = field.advancedTrackedFloat(nil, "##brushScaleVariation", scaleVariation, {
            step = 0.01,
            shiftStep = 0.01,
            min = 0,
            max = 2,
            format = "%.2f",
            shiftFormat = "%.2f",
            prefix = "+/- ",
            width = 70
        })
        if scaleVariationChanged and editor.setBrushScaleVariation then
            editor.setBrushScaleVariation(nextScaleVariation)
        end
        style.tooltip("Uniform scale variation range.\nExample: +/-0.20 => random scale factor between 0.80x and 1.20x.")
    end

    style.pushButtonNoBG(false)
end

function spawnedUI.drawProperties()
    -- Selection can change while drawing hierarchy in the same frame.
    -- Refresh cache now so grouped-property panels use up-to-date selectedPaths.
    spawnedUI.ensureCache()

    local _, wy = ImGui.GetContentRegionAvail()
    ImGui.BeginChild("##properties", 0, wy, false, ImGuiWindowFlags.HorizontalScrollbar)

    local nSelected = #spawnedUI.selectedPaths
    spawnedUI.multiSelectGroup.childs = {}

    if nSelected == 0 then
        style.mutedText("Nothing selected.")
    elseif nSelected == 1 then
        spawnedUI.selectedPaths[1].ref:drawProperties()
    else
        style.mutedText("Selection (" .. nSelected .. " elements)")
        style.spacedSeparator()
        for _, entry in pairs(spawnedUI.getRoots(spawnedUI.selectedPaths)) do
            table.insert(spawnedUI.multiSelectGroup.childs, entry.ref)
        end
        spawnedUI.multiSelectGroup:drawProperties()
    end

    ImGui.EndChild()
end

function spawnedUI.draw()
    perf.measure("spawned.total", function ()
        input.updateContext("spawned")
        spawnedUI.updateModifierState()
        
        perf.measure("spawned.cachePaths", function ()
            spawnedUI.ensureCache()
        end)
        perf.measure("spawned.registryUpdate", function ()
            registry.update()
        end)

        perf.measure("spawned.drawTop", function ()
            spawnedUI.drawTop()
        end)

        ImGui.Separator()
        ImGui.Spacing()

        ImGui.AlignTextToFramePadding()

        perf.measure("spawned.cachePathsPostTop", function ()
            spawnedUI.ensureCache()
        end)
        perf.measure("spawned.registryUpdatePostTop", function ()
            registry.update()
        end)

        perf.measure("spawned.drawDragWindow", function ()
            spawnedUI.drawDragWindow()
        end)
        perf.measure("spawned.drawHierarchy", function ()
            spawnedUI.drawHierarchy()
        end)
        perf.measure("spawned.drawDivider", function ()
            spawnedUI.drawDivider()
        end)
        perf.measure("spawned.drawProperties", function ()
            spawnedUI.drawProperties()
        end)
    end)

    perf.drawPanel()
end

---Runs end-of-frame cleanup that must happen after all hierarchy windows are drawn.
function spawnedUI.finalizeFrame()
    -- Dropped on not a valid target
    if spawnedUI.draggingSelected and not ImGui.IsMouseDragging(0, style.draggingThreshold) then
        spawnedUI.draggingSelected = false
    end
end

return spawnedUI
