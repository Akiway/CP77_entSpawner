local utils = require("modules/utils/utils")
local editor = require("modules/utils/editor/editor")
local settings = require("modules/utils/settings")
local style = require("modules/ui/style")
local history = require("modules/utils/history")
local input = require("modules/utils/input")
local registry = require("modules/utils/nodeRefRegistry")
local perf = require("modules/utils/perf")
local colorUtil = require("modules/utils/color")
local projectTagUtil = require("modules/utils/ui/projectTag")
local visualized = require("modules/classes/spawn/visualized")

---@class spawnedUI
---@field root element
---@field filter string
---@field newGroupName string
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
---@field hoveredEntries element[]
spawnedUI = {
    root = require("modules/classes/editor/element"):new(spawnedUI),
    multiSelectGroup = require("modules/classes/editor/positionableGroup"):new(spawnedUI),
    filter = "",
    newGroupName = "New_Group",
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

    clipboard = {},

    elementCount = 0,
    dividerHovered = false,
    dividerDragging = false,
    filteredWidestName = 0,
    draggingSelected = false,
    infoWindowSize = { x = 0, y = 0 },

    clipper = nil,
    visiblePathIndexById = {},
    hoveredEntries = {},

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

---@param element element?
---@return boolean
function spawnedUI.canToggleVisibility(element)
    return element ~= nil
end

---@param spawnable table?
---@return boolean
local function isVisualizedSpawnable(spawnable)
    if type(spawnable) ~= "table" then
        return false
    end

    local rootMeta = getmetatable(spawnable)
    local current = nil
    if type(rootMeta) == "table" then
        if type(rootMeta.__index) == "table" then
            current = rootMeta.__index
        else
            current = rootMeta
        end
    end

    local guard = 0
    while current ~= nil and guard < 32 do
        if current == visualized then
            return true
        end

        local meta = getmetatable(current)
        if type(meta) == "table" and type(meta.__index) == "table" then
            current = meta.__index
        else
            current = nil
        end
        guard = guard + 1
    end

    return false
end

---@param element element?
---@return boolean
function spawnedUI.canToggleVisualization(element)
    if element == nil or not utils.isA(element, "spawnableElement") or element.spawnable == nil then
        return false
    end

    return isVisualizedSpawnable(element.spawnable) and element.spawnable.setPreview ~= nil and element.spawnable.previewed ~= nil
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

local function hotkeyRunConditionProperties()
    return input.context.hierarchy.hovered or input.context.hierarchy.focused or (editor.active and (input.context.viewport.hovered or input.context.viewport.focused))
end

local function hotkeyRunConditionGlobal()
    return input.context.hierarchy.hovered or input.context.viewport.hovered
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

function spawnedUI.saveAllRootGroups()
    if not hasRootChildren() then return end

    local saved = 0
    local failed = 0
    local updatedInExport = 0

    for _, entry in pairs(spawnedUI.paths) do
        if utils.isA(entry.ref, "positionableGroup") and entry.ref.supportsSaving and entry.ref.parent ~= nil and entry.ref.parent:isRoot(true) then
            local synced = entry.ref:save(false)
            if synced ~= nil then
                updatedInExport = updatedInExport + (synced or 0)
                saved = saved + 1
            else
                failed = failed + 1
            end
        end
    end

    local msg = string.format("Saved %s root group%s", saved, saved == 1 and "" or "s")
    if failed > 0 then
        msg = msg .. string.format(", %s failed", failed)
    end
    if updatedInExport > 0 then
        msg = msg .. string.format(" and updated %s export list entr%s", updatedInExport, updatedInExport == 1 and "y" or "ies")
    end

    local toastType = ImGui.ToastType.Success
    if failed > 0 and ImGui.ToastType and ImGui.ToastType.Error then
        toastType = ImGui.ToastType.Error
    end
    ImGui.ShowToast(ImGui.Toast.new(toastType, 2500, msg))
end

function spawnedUI.registerHotkeys()
    input.registerImGuiHotkey({ ImGuiKey.Z, ImGuiKey.LeftCtrl }, function()
        if hasActiveNameEdit() then return end
        if ImGui.IsKeyDown(ImGuiKey.LeftShift) or ImGui.IsKeyDown(ImGuiKey.RightShift) then return end
        history.requestUndo()
    end, hotkeyRunConditionGlobal)
    input.registerImGuiHotkey({ ImGuiKey.Z, ImGuiKey.RightCtrl }, function()
        if hasActiveNameEdit() then return end
        if ImGui.IsKeyDown(ImGuiKey.LeftShift) or ImGui.IsKeyDown(ImGuiKey.RightShift) then return end
        history.requestUndo()
    end, hotkeyRunConditionGlobal)
    input.registerImGuiHotkey({ ImGuiKey.Y, ImGuiKey.LeftCtrl }, function()
        if hasActiveNameEdit() then return end
        history.requestRedo()
    end, hotkeyRunConditionGlobal)
    input.registerImGuiHotkey({ ImGuiKey.Y, ImGuiKey.RightCtrl }, function()
        if hasActiveNameEdit() then return end
        history.requestRedo()
    end, hotkeyRunConditionGlobal)
    input.registerImGuiHotkey({ ImGuiKey.Z, ImGuiKey.LeftCtrl, ImGuiKey.LeftShift }, function()
        if hasActiveNameEdit() then return end
        history.requestRedo()
    end, hotkeyRunConditionGlobal)
    input.registerImGuiHotkey({ ImGuiKey.Z, ImGuiKey.RightCtrl, ImGuiKey.LeftShift }, function()
        if hasActiveNameEdit() then return end
        history.requestRedo()
    end, hotkeyRunConditionGlobal)
    input.registerImGuiHotkey({ ImGuiKey.Z, ImGuiKey.LeftCtrl, ImGuiKey.RightShift }, function()
        if hasActiveNameEdit() then return end
        history.requestRedo()
    end, hotkeyRunConditionGlobal)
    input.registerImGuiHotkey({ ImGuiKey.Z, ImGuiKey.RightCtrl, ImGuiKey.RightShift }, function()
        if hasActiveNameEdit() then return end
        history.requestRedo()
    end, hotkeyRunConditionGlobal)
    input.registerImGuiHotkey({ ImGuiKey.A, ImGuiKey.LeftCtrl }, function()
        if spawnedUI.nameBeingEdited then return end

        for _, entry in pairs(spawnedUI.paths) do
            if not entry.ref:isLocked() then
                entry.ref:setSelected(true)
            end
        end
    end, hotkeyRunConditionGlobal)
    input.registerImGuiHotkey({ ImGuiKey.S, ImGuiKey.LeftCtrl }, function()
        if not hasRootChildren() then return end

        spawnedUI.saveAllRootGroups()
    end)
    input.registerImGuiHotkey({ ImGuiKey.C, ImGuiKey.LeftCtrl }, function()
        if #spawnedUI.selectedPaths == 0 or spawnedUI.nameBeingEdited then return end

        spawnedUI.clipboard = spawnedUI.copy(true)
    end, hotkeyRunConditionProperties)
    input.registerImGuiHotkey({ ImGuiKey.V, ImGuiKey.LeftCtrl }, function()
        if not hasValidClipboardElements(spawnedUI.clipboard) or spawnedUI.nameBeingEdited then return end

        local target
        if #spawnedUI.selectedPaths > 0 then
            target = spawnedUI.selectedPaths[1].ref
        end

        history.addAction(history.getInsert(spawnedUI.paste(spawnedUI.clipboard, target)))
    end, hotkeyRunConditionProperties)
    input.registerImGuiHotkey({ ImGuiKey.X, ImGuiKey.LeftCtrl }, function ()
        if #spawnedUI.selectedPaths == 0 then return end

        spawnedUI.cut(true)
    end, hotkeyRunConditionProperties)
    input.registerImGuiHotkey({ ImGuiKey.Delete }, function()
        if #spawnedUI.selectedPaths == 0 or hasActiveNameEdit() then return end

        local roots = spawnedUI.getRoots(spawnedUI.selectedPaths)
        history.addAction(history.getRemove(roots))
        for _, entry in ipairs(roots) do
            entry.ref:remove()
        end
    end, hotkeyRunConditionGlobal)
    input.registerImGuiHotkey({ ImGuiKey.D, ImGuiKey.LeftCtrl }, function()
        if #spawnedUI.selectedPaths == 0 then return end

        local data = spawnedUI.copy(true)
        history.addAction(history.getInsert(spawnedUI.paste(data, spawnedUI.selectedPaths[1].ref)))
    end)
    input.registerImGuiHotkey({ ImGuiKey.G, ImGuiKey.LeftCtrl }, function()
        if #spawnedUI.selectedPaths == 0 then return end

        spawnedUI.moveToNewGroup(true)
    end)

    -- Inputs that might get pressed while using properties panel, so use hotkeyRunConditionProperties
    input.registerImGuiHotkey({ ImGuiKey.Backspace }, function()
        if #spawnedUI.selectedPaths == 0 or spawnedUI.nameBeingEdited then return end
        spawnedUI.moveToRoot(true)
    end, hotkeyRunConditionProperties)
    input.registerImGuiHotkey({ ImGuiKey.Escape }, function()
        if #spawnedUI.selectedPaths == 0 or editor.grab or editor.rotate or editor.scale then return end -- Escape is also used for cancling editing
        spawnedUI.unselectAll()
    end, hotkeyRunConditionProperties)
    input.registerImGuiHotkey({ ImGuiKey.H }, function()
        if #spawnedUI.selectedPaths == 0 or spawnedUI.nameBeingEdited then return end

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
    end, hotkeyRunConditionProperties)

    input.registerImGuiHotkey({ ImGuiKey.E, ImGuiKey.LeftCtrl }, function ()
        if #spawnedUI.selectedPaths == 0 then return end

        local isMulti = #spawnedUI.selectedPaths > 1

        if isMulti then
            spawnedUI.multiSelectGroup:dropToSurface(true, Vector4.new(0, 0, -1, 0))
        else
            spawnedUI.selectedPaths[1].ref:dropToSurface(false, Vector4.new(0, 0, -1, 0))
        end
    end)

    input.registerImGuiHotkey({ ImGuiKey.N, ImGuiKey.LeftCtrl }, function ()
        if #spawnedUI.selectedPaths == 0 then
            spawnedUI.spawner.baseUI.spawnUI.selectedGroup = 0
            return
        end

        spawnedUI.setElementSpawnNewTarget(spawnedUI.selectedPaths[1].ref)
    end)

    input.registerImGuiHotkey({ ImGuiKey.F, ImGuiKey.LeftCtrl }, function ()
        if #spawnedUI.selectedPaths ~= 1 then
            return
        end

        local icon = spawnedUI.selectedPaths[1].ref.icon
        if icon == "" then
            icon = IconGlyphs.Group
        end
        spawnedUI.spawner.baseUI.spawnUI.favoritesUI.addNewItem(spawnedUI.selectedPaths[1].ref:serialize(), spawnedUI.selectedPaths[1].ref.name, icon)
    end)

    -- Open context menu for selected from editor mode
    input.registerMouseAction(ImGuiMouseButton.Right, function()
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

    if #spawnedUI.selectedPaths == 1 and spawnedUI.selectedPaths[1].ref == element then -- Select from first to element
        for _, entry in pairs(paths) do
            if entry.ref == element then
                break
            end
            if not entry.ref:isLocked() then
                entry.ref:setSelected(true)
            end
        end
    else
        local inRange = false
        if spawnedUI.selectedPaths[1].ref == element then -- Bottom to top selection
            for i = #paths, 1, -1 do
                if paths[i].ref == spawnedUI.selectedPaths[1].ref then
                    break
                end
                if paths[i].ref.selected then
                    inRange = true
                end
                if inRange then
                    if not paths[i].ref:isLocked() then
                        paths[i].ref:setSelected(true)
                    end
                end
            end
        end

        inRange = false
        for _, entry in pairs(paths) do
            if entry.ref == spawnedUI.selectedPaths[1].ref then -- From first selected down to element
                if inRange then
                    break
                else
                    inRange = true
                end
            end
            if entry.ref == element then -- From element down to first selected
                if not inRange then
                    inRange = true
                else
                    break
                end
            end
            if inRange then
                if not entry.ref:isLocked() then
                    entry.ref:setSelected(true)
                end
            end
        end
    end
end

---@protected
---@param element element
function spawnedUI.handleReorder(element)
    local _, mouseY = ImGui.GetMousePos()
    local _, itemY = ImGui.GetItemRectMin()
    local _ , sizeY = ImGui.GetItemRectSize()
    local shift = ((mouseY - itemY) < sizeY / 2) and 0 or 1

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
function spawnedUI.handleDrag(element)
    if element:isLocked() then
        if ImGui.IsItemHovered() and spawnedUI.draggingSelected then
            ImGui.SetMouseCursor(ImGuiMouseCursor.NotAllowed)
        end
        return
    end

    if ImGui.IsItemHovered() and ImGui.IsMouseDragging(0, style.draggingThreshold) and not spawnedUI.draggingSelected then -- Start dragging
        if not element.selected then
            spawnedUI.unselectAll()
            element:setSelected(true)
        end
        spawnedUI.draggingSelected = true
    elseif not ImGui.IsMouseDragging(0, style.draggingThreshold) and ImGui.IsItemHovered() and spawnedUI.draggingSelected then -- Drop on element
        spawnedUI.draggingSelected = false

        if not element.selected then
            if ImGui.IsKeyDown(ImGuiKey.LeftShift) and element:isValidDropTarget(spawnedUI.selectedPaths, false) then
                spawnedUI.handleReorder(element)
            elseif element:isValidDropTarget(spawnedUI.selectedPaths, true) then
                local roots = spawnedUI.getRoots(spawnedUI.selectedPaths)
                local remove = history.getRemove(roots)
                for _, entry in ipairs(roots) do
                    entry.ref:setParent(element)
                end
                local insert = history.getInsert(roots)
                history.addAction(history.getMove(remove, insert))
            end
        end
    elseif ImGui.IsItemHovered() and spawnedUI.draggingSelected then
        if element.selected then
            ImGui.SetMouseCursor(ImGuiMouseCursor.NotAllowed)
        elseif not ImGui.IsKeyDown(ImGuiKey.LeftShift) and not element:isValidDropTarget(spawnedUI.selectedPaths, true) then
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

    local parent = spawnedUI.root
    local index = #parent.childs + 1

    if element then
        if element:isLocked() then
            return pasted
        end
        parent = element.parent
        index = utils.indexValue(parent.childs, element) + 1
        if element.expandable then
            parent = element
            index = 1
        end
    end

    if settings.moveCloneToParent == 2 then
        parent = parent.parent or parent
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
        if ImGui.Begin("##drag", ImGuiWindowFlags.NoResize + ImGuiWindowFlags.NoMove + ImGuiWindowFlags.NoTitleBar + ImGuiWindowFlags.NoBackground + ImGuiWindowFlags.AlwaysAutoResize) then
            local text = #spawnedUI.selectedPaths == 1 and spawnedUI.selectedPaths[1].ref.name or (#spawnedUI.selectedPaths .. " elements")
            text = (ImGui.IsKeyDown(ImGuiKey.LeftShift) and "Reorder " or "") .. text
            ImGui.Text(text)
            ImGui.End()
        end
    end
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

        style.mutedText(isMulti and #spawnedUI.selectedPaths .. " elements" or element.name)
        if isLocked then
            ImGui.SameLine()
            style.mutedText("(Locked)")
        end
        ImGui.Separator()

        ImGui.BeginDisabled(isLocked)
        if ImGui.MenuItem(IconGlyphs.DeleteOutline .. " Delete", "DEL") then
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

        if ImGui.MenuItem(IconGlyphs.ContentCopy .. " Copy", "CTRL-C") then
            spawnedUI.clipboard = spawnedUI.copy(isMulti, element)
        end

        ImGui.BeginDisabled(isLocked)
        ImGui.BeginDisabled(not canPaste)
        if ImGui.MenuItem(IconGlyphs.ContentPaste .. " Paste", "CTRL-V") then
            history.addAction(history.getInsert(spawnedUI.paste(spawnedUI.clipboard, element)))
        end
        ImGui.EndDisabled()
        if ImGui.MenuItem(IconGlyphs.ContentCut .. " Cut", "CTRL-X") then
            spawnedUI.cut(isMulti, element)
        end
        if ImGui.MenuItem(IconGlyphs.ContentDuplicate .. " Duplicate", "CTRL-D") then
            local data = spawnedUI.copy(isMulti, element)
            history.addAction(history.getInsert(spawnedUI.paste(data, element)))
        end

        ImGui.Separator()
        if ImGui.MenuItem(IconGlyphs.ArrowTopLeftBoldBoxOutline .. " Move to Root", "BACKSPACE") then
            spawnedUI.moveToRoot(isMulti, element)
        end
        if ImGui.MenuItem(IconGlyphs.FolderMultiplePlusOutline .. " Move to new group", "CTRL-G") then
            spawnedUI.moveToNewGroup(isMulti, element)
        end
        if utils.isA(element, "positionableGroup") then
            if ImGui.MenuItem(IconGlyphs.PlusBoxOutline .. " Set as \"Spawn New\" group", "CTRL-N") then
                local idx = 1
                local elementPath = element:getPath()
                for _, entry in pairs(spawnedUI.containerPaths) do
                    if entry.path == elementPath then
                        break
                    end
                    idx = idx + 1
                end
                spawnedUI.spawner.baseUI.spawnUI.selectedGroup = idx
            end
        end

		ImGui.Separator()
        if utils.isA(element, "spawnableElement") then
            if ImGui.MenuItem(IconGlyphs.Download .. " Drop to floor", "CTRL-E") then
                if isMulti then
                    spawnedUI.multiSelectGroup:dropToSurface(true, Vector4.new(0, 0, -1, 0))
                else
                    element:dropToSurface(false, Vector4.new(0, 0, -1, 0))
                end
            end
        end
        if utils.isA(element, "positionableGroup") then
            ImGui.EndDisabled()
            if ImGui.MenuItem(IconGlyphs.EyeOutline .. " Show all children") then
                applyElementChangesBatched({ element }, function(entry)
                    entry:showDescendants(true)
                end)
            end
            if ImGui.MenuItem(IconGlyphs.LockOpenVariantOutline .. " Unlock all children") then
                applyElementChangesBatched({ element }, function(entry)
                    entry:unlockDescendants(true)
                end)
            end
            if ImGui.MenuItem(IconGlyphs.HospitalMarker .. " Show all children visualization helpers") then
                local targets = {}
                collectVisualizationTargetsRecursive(element, targets)
                applyElementChangesBatched(targets, function(entry)
                    if spawnedUI.canToggleVisualization(entry) then
                        entry.spawnable:setPreview(true)
                    end
                end)
            end
            ImGui.BeginDisabled(isLocked)
            
            if ImGui.MenuItem(IconGlyphs.DownloadMultiple .. " Drop Children to Floor") then
                element:dropChildrenToSurface(false, Vector4.new(0, 0, -1, 0))
            end

		    ImGui.Separator()
            if ImGui.MenuItem(IconGlyphs.ImageFilterCenterFocus .. " Set Origin to Center") then
                applyElementChangesBatched({ element }, function(entry)
                    entry:setOriginToCenter()
                end)
            end
            if ImGui.MenuItem(IconGlyphs.AccountBadgeOutline .. " Set Origin to Player Position") then
                applyElementChangesBatched({ element }, function(entry)
                    entry:setOrigin(GetPlayer():GetWorldPosition())
                end)
            end
            if ImGui.MenuItem(IconGlyphs.ContentCopy .. " Copy Origin and Identity") then
                local pos = element:getPosition()
                local rot = element:getRotation()
                utils.insertClipboardValue("position", { x = pos.x, y = pos.y, z = pos.z })
                utils.insertClipboardValue("rotation", { roll = rot.roll, pitch = rot.pitch, yaw = rot.yaw })
            end
            local copiedOrigin = utils.getClipboardValue("position")
            local copiedIdentity = utils.getClipboardValue("rotation")
            ImGui.BeginDisabled(copiedOrigin == nil or copiedIdentity == nil)
            if ImGui.MenuItem(IconGlyphs.ContentPaste .. " Paste Origin and Identity") then
                applyElementChangesBatched({ element }, function(entry)
                    entry:setOrigin(Vector4.new(copiedOrigin.x, copiedOrigin.y, copiedOrigin.z, 0))
                    entry:setIdentity(copiedIdentity)
                end)
            end
            ImGui.EndDisabled()
        end
        if element.parent ~= nil and utils.isA(element.parent, "positionableGroup") and not element.parent:isRoot(true) then
            ImGui.EndDisabled()
            if ImGui.MenuItem(IconGlyphs.SquareRoundedBadgeOutline .. " Set Parent Origin to Element") then
                local selectedPos = element:getPosition()
                applyElementChangesBatched({ element.parent }, function(entry)
                    entry:setOrigin(selectedPos)
                end)
            end
            ImGui.BeginDisabled(isLocked)
        end
        ImGui.EndDisabled()

        if utils.isA(element, "positionable") and not utils.isA(element, "positionableGroup") and ImGui.MenuItem(IconGlyphs.ContentCopy .. " Copy Origin and Identity") then
            local pos = element:getPosition()
            local rot = element:getRotation()
            utils.insertClipboardValue("position", { x = pos.x, y = pos.y, z = pos.z })
            utils.insertClipboardValue("rotation", { roll = rot.roll, pitch = rot.pitch, yaw = rot.yaw })
        end

		ImGui.Separator()
        if ImGui.MenuItem(IconGlyphs.Group .. (not utils.isA(element, "positionableGroup") and " Make Favorite" or " Make Prefab"), "CTRL-F") then
            local icon = element.icon
            if icon == "" then
                icon = IconGlyphs.Group
            end

            spawnedUI.spawner.baseUI.spawnUI.favoritesUI.addNewItem(element:serialize(), element.name, icon)
        end

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

    local visibilityWidth = math.max(getButtonWidth(IconGlyphs.EyeOutline), getButtonWidth(IconGlyphs.EyeOffOutline))
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
            totalX = totalX + getButtonWidth(icon) + ImGui.GetStyle().ItemSpacing.x
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

---@param rawColor table?
---@return string
local function formatColorPreviewTooltip(rawColor)
    local normalized = colorUtil.normalizeRGB(rawColor, { 1, 1, 1 })
    local red = math.floor(normalized[1] * 255 + 0.5)
    local green = math.floor(normalized[2] * 255 + 0.5)
    local blue = math.floor(normalized[3] * 255 + 0.5)

    return string.format(
        "#%02X%02X%02X\nR: %d, G: %d, B: %d\n(%.3f, %.3f, %.3f)",
        red,
        green,
        blue,
        red,
        green,
        blue,
        normalized[1],
        normalized[2],
        normalized[3]
    )
end

---@param count number
---@return string
local function getConnectionCountIcon(count)
    if count >= 10 then
        return IconGlyphs.Numeric9PlusCircleOutline
    end

    return CONNECTION_COUNT_ICONS[math.max(0, math.min(9, count))] or IconGlyphs.Numeric0CircleOutline
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

            if spawnable.modulePath == "meta/spline" then
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

        if spawnable.modulePath == "meta/spline" and spawnable.splineFollower then
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
            addStateIcon(
                stateIcons,
                IconGlyphs.SquareRounded,
                formatColorPreviewTooltip(color),
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

        local isSpline = spawnable.modulePath == "meta/spline"
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
function spawnedUI.drawSideButtons(element)
    -- Right side buttons
    local totalX = spawnedUI.getSideButtonsWidth(element)

    local scrollBarAddition = (ImGui.GetScrollMaxY() > 0 and not spawnedUI.dividerDragging) and ImGui.GetStyle().ScrollbarSize or 0

    local cursorX = ImGui.GetWindowWidth() - totalX - ImGui.GetStyle().CellPadding.x / 2 - scrollBarAddition + ImGui.GetScrollX()
    local rowY = ImGui.GetCursorPosY()
    ImGui.SetCursorPosX(cursorX)
    ImGui.SetCursorPosY(rowY)

    local elementLocked = element:isLocked()
    local hoveredLocked = elementLocked and element.hovered
    local sideButtonPadding = 1 * style.viewSize

    for icon, data in pairs(element.quickOperations) do
        if data.condition(element) then
            ImGui.SetNextItemAllowOverlap()
            local disableQuickOp = elementLocked and icon ~= IconGlyphs.ContentSaveOutline
            local isRootGroupSave = icon == IconGlyphs.ContentSaveOutline
                and utils.isA(element, "positionableGroup")
                and element.parent ~= nil
                and element.parent:isRoot(true)
            if isRootGroupSave and next(element.childs) == nil then
                disableQuickOp = true
            end
            ImGui.BeginDisabled(disableQuickOp)
            ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, sideButtonPadding, sideButtonPadding)
            if ImGui.Button(icon) then
                data.operation(element)
            end
            ImGui.PopStyleVar()
            ImGui.EndDisabled()
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
function spawnedUI.drawElement(entry, dummy, rowIndex)
    spawnedUI.elementCount = spawnedUI.elementCount + 1
    local element = entry and entry.ref or nil
    local elementPath = entry and entry.path or ""
    local rowDepth = entry and (entry.depth or 0) or 0

    local isGettingDragged = element and element.selected and spawnedUI.draggingSelected
    local rowLocked = element and element:isLocked()

    ImGui.PushID(spawnedUI.elementCount)

    ImGui.TableNextRow(ImGuiTableRowFlags.None, spawnedUI.getRowHeight())
    if (rowIndex or spawnedUI.elementCount) % 2 == 0 then
        ImGui.TableSetBgColor(ImGuiTableBgTarget.RowBg0, 0.2, 0.2, 0.2, 0.3)
    else
        ImGui.TableSetBgColor(ImGuiTableBgTarget.RowBg0, 0.3, 0.3, 0.3, 0.3)
    end

    ImGui.TableNextColumn()

    if dummy then
        ImGui.PopID()
        return
    end

    -- Base selectable
    ImGui.SetCursorPosX(rowDepth * 17 * style.viewSize) -- Indent element
    ImGui.PushStyleVar(ImGuiStyleVar.ItemSpacing, 15, spawnedUI.cellPadding * 2 + style.viewSize) -- + style.viewSize is a ugly fix to make the gaps smaller

    -- Grey out if getting dragged
    local suppressHeaderState = isGettingDragged or rowLocked
    style.pushStyleColor(suppressHeaderState, ImGuiCol.HeaderHovered, 0, 0, 0, 0)
    style.pushStyleColor(suppressHeaderState, ImGuiCol.HeaderActive, 0, 0, 0, 0)
    style.pushStyleColor(suppressHeaderState, ImGuiCol.Header, 0, 0, 0, 0)

    local previous = element.selected
    local newState = ImGui.Selectable("##item" .. spawnedUI.elementCount, element.selected, ImGuiSelectableFlags.SpanAllColumns + ImGuiSelectableFlags.AllowOverlap)
    element:setSelected(newState)
    local isHovered = ImGui.IsItemHovered()
    element:setHovered(isHovered)
    if isHovered then
        table.insert(spawnedUI.hoveredEntries, element)
    end
    if element:isLocked() then
        element:setSelected(false)
        newState = false
    end

    if element.selected then
        if spawnedUI.scrollToSelected then
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

    spawnedUI.handleDrag(element)

    spawnedUI.drawContextMenu(element, elementPath)

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

    local leftOffset = 25 * style.viewSize -- Accounts for icon
    local hiddenText = not element.visible
    style.pushStyleColor(hiddenText, ImGuiCol.Text, style.mutedColor)
    local projectTag = projectTagUtil.getRootGroupTag(element)
    local stateIcons = spawnedUI.getStateIcons(element)
    local projectTagWidth = spawnedUI.getProjectTagWidth(projectTag)
    local stateIconsWidth = spawnedUI.getStateIconsWidth(stateIcons)
    local projectTagLeadPad = projectTag and (STATE_ICON_GRID_PADDING * style.viewSize) or 0
    local stateIconLeadPad = (#stateIcons > 0) and (STATE_ICON_GRID_PADDING * style.viewSize) or 0
    local rowMetaWidth = projectTagWidth + stateIconsWidth + projectTagLeadPad + stateIconLeadPad

    -- Icon or expand button
    if not element.expandable and element.icon ~= "" then
        ImGui.AlignTextToFramePadding()
        ImGui.Text(element.icon)
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

        if element.icon ~= "" then
            ImGui.SameLine()
            ImGui.AlignTextToFramePadding()
            ImGui.Text(element.icon)
            leftOffset = 45 * style.viewSize
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

    if element.hovered and ImGui.IsMouseDoubleClicked(ImGuiMouseButton.Left) then
        if not element:isLocked() then
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

    spawnedUI.drawSideButtons(element)

    ImGui.PopStyleColor(2)
    ImGui.PopStyleVar(2)
    style.popStyleColor(isGettingDragged)

    ImGui.PopID()
end

function spawnedUI.drawHierarchy()
    spawnedUI.elementCount = 0
    spawnedUI.cellPadding = 3 * style.viewSize

    for _, entry in pairs(spawnedUI.hoveredEntries) do
        if entry.hovered then
            entry:setHovered(false)
        end
    end
    spawnedUI.hoveredEntries = {}

    local _, ySpace = ImGui.GetContentRegionAvail()

    if ySpace < 0 then return end

    if ySpace - settings.editorBottomSize < 75 * style.viewSize and not spawnedUI.spawner.baseUI.loadTabSize then
        settings.editorBottomSize = ySpace - 75 * style.viewSize
    end
    local rowHeight = spawnedUI.getRowHeight()
    local childHeight = ySpace - settings.editorBottomSize
    local nRows = math.floor(childHeight / rowHeight)
    local entries = spawnedUI.filter == "" and spawnedUI.visiblePaths or spawnedUI.filteredPaths
    spawnedUI.prepareStateIconFrame()

    ImGui.BeginChild("##hierarchy", 0, childHeight, false, ImGuiWindowFlags.NoMove)
    input.updateContext("hierarchy")

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
    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, 7.5 * style.viewSize, spawnedUI.cellPadding)
    ImGui.PushStyleVar(ImGuiStyleVar.ScrollbarSize, 12 * style.viewSize)
    if ImGui.BeginTable("##hierarchyTable", 1, ImGuiTableFlags.ScrollX or ImGuiTableFlags.NoHostExtendX) then
        if forceFullPass then
            for idx, entry in ipairs(entries) do
                spawnedUI.drawElement(entry, false, idx)
            end
        else
            spawnedUI.clipper = ImGuiListClipper.new()
            spawnedUI.clipper:Begin(#entries, rowHeight)

            while spawnedUI.clipper:Step() do
                local startIndex = spawnedUI.clipper.DisplayStart + 1
                local endIndex = spawnedUI.clipper.DisplayEnd

                for idx = startIndex, endIndex do
                    local entry = entries[idx]
                    if entry then
                        spawnedUI.drawElement(entry, false, idx)
                    end
                end
            end
        end

        if spawnedUI.elementCount < nRows then
            for _ = 1, nRows - spawnedUI.elementCount do
                spawnedUI.drawElement(nil, true, #entries + spawnedUI.elementCount + 1)
            end
        end

        ImGui.EndTable()
    end
    ImGui.PopStyleVar(2)

    ImGui.EndChild()
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
    spawnedUI.newGroupName, changed = ImGui.InputTextWithHint('##newG', 'New group name...', spawnedUI.newGroupName, 100)
    if changed then
        spawnedUI.newGroupName = utils.createFileName(spawnedUI.newGroupName)
    end
    ImGui.PopItemWidth()

    ImGui.SameLine()
    if ImGui.Button("Add group") then
        local group = require("modules/classes/editor/positionableGroup"):new(spawnedUI)

        if spawnedUI.newGroupRandomized then
            group = require("modules/classes/editor/randomizedGroup"):new(spawnedUI)
        end

        group.name = spawnedUI.newGroupName
        spawnedUI.addRootElement(group)
        history.addAction(history.getInsert({ group }))
    end
    ImGui.SameLine()
    spawnedUI.newGroupRandomized = style.toggleButton(IconGlyphs.Dice5Outline, spawnedUI.newGroupRandomized)
    style.tooltip("Make new group randomized")

    -- Hierarchy actions
    local nextEditorState, editorToggleChanged = style.toggleButton(IconGlyphs.Rotate3d, editor.active)
    if editorToggleChanged then
        editor.toggle(nextEditorState)
    end
    style.tooltip("Toggle 3D-Editor mode")

    style.pushButtonNoBG(true)
    
    local hasHierarchy = hasRootChildren()
    local rightHierarchyActionIcons = {
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
    if ImGui.Button(IconGlyphs.ContentSaveAllOutline) then
        spawnedUI.saveAllRootGroups()
    end
    style.tooltip("Save all root groups")
    
    ImGui.SameLine()
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

        if ImGui.Begin("WB##shortcuts-popup", ImGuiWindowFlags.NoResize + ImGuiWindowFlags.NoMove + ImGuiWindowFlags.NoTitleBar + ImGuiWindowFlags.AlwaysAutoResize) then
            if ImGui.BeginTable("##shortcutsTable", 2, ImGuiTableFlags.SizingStretchSame) then
                ImGui.TableNextColumn()

                style.mutedText("GENERAL")
                ImGui.Separator()
                ImGui.Spacing()

                ImGui.MenuItem("Undo", "CTRL-Z")
                ImGui.MenuItem("Redo", "CTRL-Y")
                ImGui.MenuItem("Select all", "CTRL-A")
                ImGui.MenuItem("Unselect all", "ESC")
                ImGui.MenuItem("Save all", "CTRL-S")
                
                ImGui.Dummy(0, 8 * style.viewSize)

                style.mutedText("SCENE HIERARCHY")
                ImGui.Separator()
                ImGui.Spacing()

                ImGui.MenuItem("Open context menu on selected", "RMB")
                ImGui.MenuItem("Copy selected", "CTRL-C")
                ImGui.MenuItem("Paste selected", "CTRL-V")
                ImGui.MenuItem("Duplicate selected", "CTRL-D")
                ImGui.MenuItem("Cut selected", "CTRL-X")
                ImGui.MenuItem("Delete selected", "DEL")
                ImGui.MenuItem("Toggle selected visibility", "H")
                ImGui.MenuItem("Multiselect", "Hold CTRL")
                ImGui.MenuItem("Range select", "Hold SHIFT")
                ImGui.MenuItem("Move selected to root", "BACKSPACE")
                ImGui.MenuItem("Move selected to new group", "CTRL-G")
                ImGui.MenuItem("Drop selected to floor", "CTRL-E")
                ImGui.MenuItem("Set as \"Spawn New\" group", "CTRL-N")
                ImGui.MenuItem("Transform (move / rotate / scale)", "Mouse Drag")
                ImGui.MenuItem("Transform slow", "Hold SHIFT + Mouse Drag")
                ImGui.MenuItem("Transform extra-slow", "Hold ALT + Mouse Drag")
                ImGui.MenuItem("Transform fast", "Hold CTRL + Mouse Drag")

                ImGui.TableNextColumn()

                style.mutedText("3D-EDITOR Camera")
                ImGui.Separator()
                ImGui.Spacing()
                ImGui.MenuItem("Rotate camera", "Hold MMB")
                ImGui.MenuItem("Move camera", "SHIFT + Hold MMB")
                ImGui.MenuItem("Zoom", "CTRL + Hold MMB")
                ImGui.MenuItem("Center camera on selected", "TAB")
                
                ImGui.Dummy(0, 8 * style.viewSize)

                style.mutedText("3D-EDITOR")
                ImGui.Separator()
                ImGui.Spacing()

                ImGui.MenuItem("Repeat last spawn under cursor", "CTRL-R")
                ImGui.MenuItem("Open spawn new popup", "SHIFT-A")
                ImGui.MenuItem("Open depth select menu", "SHIFT-D")
                ImGui.MenuItem("Select / Confirm", "LMB")
                ImGui.MenuItem("Box Select", "CTRL + LMB Drag")
                ImGui.MenuItem("Open context menu / Cancel", "RMB")
                ImGui.MenuItem("Move selected on axis", "G -> X/Y/Z")
                ImGui.MenuItem("Move selected, locked on axis", "G -> SHIFT + X/Y/Z")
                ImGui.MenuItem("Rotate selected", "R -> X/Y/Z  -> (Numeric)")
                ImGui.MenuItem("Scale selected on axis", "S -> X/Y/Z -> (Numeric)")
                ImGui.MenuItem("Scale selected, locked on axis", "S -> SHIFT + X/Y/Z  -> (Numeric)")

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
            spawnedUI.root:setVisibleRecursive(true)
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
            spawnedUI.root:setVisibleRecursive(false)
        end
    end
    style.tooltip("Hide all elements (or filtered elements)")
    ImGui.EndDisabled()

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

        -- Dropped on not a valid target
        if spawnedUI.draggingSelected and not ImGui.IsMouseDragging(0, style.draggingThreshold) then
            spawnedUI.draggingSelected = false
        end
    end)

    perf.drawPanel()
end

return spawnedUI
