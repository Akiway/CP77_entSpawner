local utils = require("modules/utils/utils")
local settings = require("modules/utils/settings")
local style = require("modules/ui/style")
local history = require("modules/utils/history")

---@class nodeRefRegistryEntry
---@field ref string Full NodeRef string (for example `$/mod/group/#root_name`).
---@field path string Hierarchy path of the owning spawned UI entry.
---@field duplicate boolean True when the same NodeRef exists on multiple entries under the same root.
---@field spawnable spawnable? Spawnable owning this NodeRef (first seen in case of duplicates).

---@class nodeRefRegistry
---@field spawnedUI spawnedUI? Cached reference to the spawned hierarchy used for indexing.
---@field refs table<string, table<string, nodeRefRegistryEntry>> Indexed as `refs[rootName][nodeRef]`.
---@field dirty boolean Whether `refs` must be rebuilt before use.
local registry = {
    spawnedUI = nil,
    refs = {},
    dirty = true
}

---Bind the registry to the active spawned UI tree.
---This should be called once after the main spawner UI is initialized.
---@param spawner spawner Root spawner object containing `baseUI.spawnedUI`.
function registry.init(spawner)
    registry.spawnedUI = spawner.baseUI.spawnedUI
    registry.dirty = true
end

---Mark cached NodeRef index data as outdated.
---Call this whenever an entry's NodeRef, name, parent, or path can change.
function registry.invalidate()
    registry.dirty = true
end

---Rebuild `refs` from the current spawned hierarchy if needed.
---No-op when the registry is clean or the spawned UI is not initialized yet.
function registry.update()
    if not registry.spawnedUI then
        return
    end

    if not registry.dirty then
        return
    end

    registry.refs = {}

    for _, node in pairs(registry.spawnedUI.paths) do
        if utils.isA(node.ref, "spawnableElement") and node.ref.spawnable.nodeRef ~= "" then
            local root = node.ref:getRootParent()

            if not registry.refs[root.name] then
                registry.refs[root.name] = {}
            end
            if registry.refs[root.name][node.ref.spawnable.nodeRef] then
                registry.refs[root.name][node.ref.spawnable.nodeRef].duplicate = true
            else
                registry.refs[root.name][node.ref.spawnable.nodeRef] = {
                    ref = node.ref.spawnable.nodeRef,
                    path = node.path,
                    duplicate = false,
                    spawnable = node.ref.spawnable
                }
            end
        end
    end

    registry.dirty = false
end

---Resolve a spawnable by NodeRef in the same root group as `object`.
---@param object positionable
---@param ref string
---@return spawnable?
function registry.getSpawnableByNodeRef(object, ref)
    if not object or not object.getRootParent then
        return nil
    end

    if not ref or ref == "" then
        return nil
    end

    registry.update()

    local root = object:getRootParent()
    if not root or not root.name then
        return nil
    end

    local rootRefs = registry.refs[root.name]
    local entry = rootRefs and rootRefs[ref]
    return entry and entry.spawnable or nil
end

---Generate a unique NodeRef for one object under its root group.
---Format: `$/<settings.nodeRefPrefix>/<parent>/#<root>_<name>` (prefix omitted when empty).
---When a collision exists in the same root group, a copy suffix is appended until unique.
---@param object positionable Object owning the NodeRef (must provide `name`, `parent`, and `getRootParent()`).
---@return string generated Unique NodeRef candidate.
function registry.generate(object)
    registry.update()

    local generated = "$/"
    if #settings.nodeRefPrefix > 0 then
        generated = generated .. settings.nodeRefPrefix .. "/"
    end
    local rootName = object:getRootParent().name
    local parent = utils.createFileName(string.lower(object.parent.name))
    local root = utils.createFileName(string.lower(rootName))
    local name = utils.createFileName(string.lower(object.name))

    generated = generated .. parent .. "/#" .. root .. "_" .. name

    while registry.refs[rootName] and registry.refs[rootName][generated] do
        generated = utils.generateCopyName(generated)
    end

    return generated
end

---Draw a combo-based NodeRef picker with inline text search/filter.
---Search uses Lua pattern matching (`string.match`) against indexed refs.
---Special case: entering `"0"` shows all refs from the current root group.
---@param width number Control width in unscaled style units (`style.viewSize` is applied internally).
---@param ref string Current NodeRef value and search text.
---@param object positionable Context object used for root scoping and self-ref exclusion.
---@param record boolean? When true, push a history action before user-driven changes (selection/clear).
---@return string ref Updated NodeRef/search value.
---@return boolean finished True when user commits a value (selects, clears, or finishes text edit).
function registry.drawNodeRefSelector(width, ref, object, record)
    local finished = false

    ImGui.SetNextItemWidth(width * style.viewSize)
    if (ImGui.BeginCombo("##nodeRefSelector", ref)) then
        local interiorWidth = width - (2 * ImGui.GetStyle().FramePadding.x) - 30
        ref, _, textFieldFinished = style.trackedTextField(object, "##noderef", ref, "$/#foobar", interiorWidth)
        local x, _ = ImGui.GetItemRectSize()

        ImGui.SameLine()
        style.pushButtonNoBG(true)
        if ImGui.Button(IconGlyphs.Close) then
            if record then
                history.addAction(history.getElementChange(object))
            end
            ref = ""
            finished = true
        end
        style.pushButtonNoBG(false)

        local entryHovered = false
        local xButton, _ = ImGui.GetItemRectSize()
        if ImGui.BeginChild("##list", x + xButton + ImGui.GetStyle().ItemSpacing.x, 100 * style.viewSize) then
            for _, node in pairs(registry.refs[object:getRootParent().name] or {}) do
                -- Show everything when "0" is selected, treat it like a wildcard
                if (ref == "0" or node.ref:match(ref)) and node.ref ~= object.spawnable.nodeRef and ImGui.Selectable(utils.shortenPath(node.ref, ((width - 2 * ImGui.GetStyle().FramePadding.x) * style.viewSize) - (ImGui.GetScrollMaxY() > 0 and ImGui.GetStyle().ScrollbarSize or 0), false)) then
                    if record then
                        history.addAction(history.getElementChange(object))
                    end
                    ref = node.ref
                    finished = true
                    ImGui.CloseCurrentPopup()
                end
                entryHovered = entryHovered or ImGui.IsItemHovered()
            end

            ImGui.EndChild()
        end

        ImGui.EndCombo()

        -- Make sure that if text input is used as search, and entry is clicked, that we do not count the finish event from text input, but wait for the selectable to be clicked on the next frame
        if entryHovered and textFieldFinished then
            finished = false
        else
            finished = finished or textFieldFinished
        end
    end

    return ref, finished
end

return registry
