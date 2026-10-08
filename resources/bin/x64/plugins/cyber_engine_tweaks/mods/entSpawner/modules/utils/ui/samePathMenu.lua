local utils = require("modules/utils/core/utils")
local settings = require("modules/utils/core/settings")
local style = require("modules/ui/style")
local history = require("modules/utils/project/history")

---"Spawn from same path" list for mesh elements: the meshes sharing the element's asset path,
---previewed on hover and spawned in place of the element with its appearance.
local samePathMenu = {}

local SEARCH_MIN_ENTRIES = 12
local LIST_MIN_WIDTH = 250
local POPUP_ID = "##spawnFromSamePathPopup"

---@type table<table, table<string, table[]>> Spawn list -> lowercase folder -> entries
local folderIndexByList = setmetatable({}, { __mode = "k" })

local search = ""
local hoveredThisFrame = nil
local previewEntry = nil
local previewSpawnUI = nil

---@param path string?
---@return boolean
local function isMeshPath(path)
    local lower = tostring(path or ""):lower()
    return lower:match("%.mesh$") ~= nil or lower:match("%.w2mesh$") ~= nil
end

---@param path string?
---@return string? folder Lowercase, backslash separated, without the trailing separator
local function getFolderKey(path)
    local normalized = tostring(path or ""):gsub("/", "\\"):lower()
    return normalized:match("^(.*)\\[^\\]*$")
end

---@param entry table
---@return string
local function getEntryPath(entry)
    if type(entry.data) == "table" and type(entry.data.spawnData) == "string" then
        return entry.data.spawnData
    end

    return tostring(entry.name or "")
end

---Indexes the spawn list by folder. Entries are copies, so the asset browser's rows, which stop
---the preview of their own entry when it is not hovered, never stop one started here.
---@param spawnList table
---@return table<string, table[]>
local function getFolderIndex(spawnList)
    local index = folderIndexByList[spawnList]
    if index then return index end

    index = {}
    for _, entry in ipairs(spawnList.data) do
        local key = getFolderKey(getEntryPath(entry))
        if key then
            index[key] = index[key] or {}
            table.insert(index[key], {
                data = entry.data,
                name = entry.name,
                fileName = entry.fileName,
                modulePath = entry.modulePath
            })
        end
    end

    folderIndexByList[spawnList] = index
    return index
end

---@param element element
---@return table? spawnUI
local function getSpawnUI(element)
    local sUI = element and element.sUI
    local baseUI = sUI and sUI.spawner and sUI.spawner.baseUI

    return baseUI and baseUI.spawnUI or nil
end

---@param element element?
---@return boolean
function samePathMenu.isSupported(element)
    return utils.isA(element, "spawnableElement")
        and element.spawnable ~= nil
        and isMeshPath(element.spawnable.spawnData)
        and getSpawnUI(element) ~= nil
end

---Meshes in the same folder as the element's asset, excluding the asset itself.
---@param element spawnableElement
---@return table[] entries
---@return table? spawnList
function samePathMenu.getEntries(element)
    if not samePathMenu.isSupported(element) then return {}, nil end

    local spawnUI = getSpawnUI(element)
    local spawnList = spawnUI.getSpawnListByModulePath(element.spawnable.modulePath)
    if not spawnList or not spawnList.isPaths then
        spawnList = spawnUI.getSpawnListByModulePath("mesh/mesh")
    end
    if not spawnList or not spawnList.isPaths then return {}, nil end

    local assetPath = element.spawnable.spawnData
    local folder = getFolderKey(assetPath)
    local siblings = folder and getFolderIndex(spawnList)[folder] or {}
    local current = tostring(assetPath):gsub("/", "\\"):lower()

    local entries = {}
    for _, entry in ipairs(siblings) do
        if getEntryPath(entry):gsub("/", "\\"):lower() ~= current then
            table.insert(entries, entry)
        end
    end

    return entries, spawnList
end

---Spawns `entry` with the element's transform, scale and appearance, next to it in the hierarchy.
---Appearances the new mesh does not have fall back to its first one on load.
---@param element spawnableElement
---@param entry table
---@param spawnList table
---@return spawnableElement?
function samePathMenu.spawn(element, entry, spawnList)
    local spawnUI = getSpawnUI(element)
    if not spawnUI then return nil end

    local class = spawnUI.resolveEntryClass(spawnList, entry)
    local modulePath = class:new().modulePath
    if spawnUI.rejectIncompatibleAsset(modulePath, getEntryPath(entry)) then return nil end

    spawnUI.stopActiveAssetPreview()
    spawnUI.hoveredEntry = nil

    local source = element.spawnable
    local pos = element:getPosition()
    local rot = element:getRotation()

    local data = utils.deepcopy(entry.data)
    data.modulePath = modulePath
    data.position = { x = pos.x, y = pos.y, z = pos.z, w = 0 }
    data.rotation = { roll = rot.roll, pitch = rot.pitch, yaw = rot.yaw }
    data.app = source.app
    if source.scale then
        data.scale = { x = source.scale.x, y = source.scale.y, z = source.scale.z }
    end

    local sUI = element.sUI
    local new = require("modules/classes/editor/spawnableElement"):new(sUI)
    new:load({
        name = utils.getFileName(getEntryPath(entry)),
        modulePath = new.modulePath,
        spawnable = data
    })

    local parent = element.parent or sUI.root
    local index = element.parent and utils.indexValue(parent.childs, element) + 1 or nil
    new:setParent(parent, index)
    new.selected = true
    sUI.unselectAll()
    sUI.scrollToSelected = true

    history.addAction(history.getInsert({ new }))

    return new
end

---Draws the searchable entry list. Hovering a row previews it, clicking one spawns it.
---@param element spawnableElement
---@param id string
local function drawEntryList(element, id)
    local spawnUI = getSpawnUI(element)
    local entries, spawnList = samePathMenu.getEntries(element)
    local folder = tostring(element.spawnable.spawnData):match("^(.*[\\/])") or ""

    if ImGui.IsWindowAppearing() then
        search = ""
        style.clearSearchInput(id .. "Search", false)
    end

    style.mutedText(folder)

    if #entries == 0 then
        style.mutedText("No other mesh at this path")
        return
    end

    if #entries >= SEARCH_MIN_ENTRIES then
        search = style.drawSearchFilterRow(id .. "Search", search, { width = LIST_MIN_WIDTH, hint = "Search..." })
    end

    local filtered = {}
    local maxWidth = LIST_MIN_WIDTH * style.viewSize
    for _, entry in ipairs(entries) do
        if search == "" or utils.matchSearch(entry.fileName or entry.name, search) then
            table.insert(filtered, entry)
            local textWidth, _ = ImGui.CalcTextSize(entry.fileName or entry.name)
            maxWidth = math.max(maxWidth, textWidth)
        end
    end

    if #filtered == 0 then
        style.mutedText("No match")
        return
    end

    local _, screenHeight = GetDisplayResolution()
    local styleData = ImGui.GetStyle()
    local height = math.min(#filtered * ImGui.GetFrameHeightWithSpacing(), screenHeight / 2)
    local width = maxWidth + styleData.ScrollbarSize + styleData.FramePadding.x * 2 + styleData.ItemSpacing.x
    local previewEnabled = settings.assetPreviewEnabled[spawnList.modulePath] ~= false

    if ImGui.BeginChild(id .. "List", width, math.max(height, 1)) then
        local clipper = ImGuiListClipper.new()
        clipper:Begin(#filtered, -1)

        while clipper:Step() do
            for i = clipper.DisplayStart + 1, clipper.DisplayEnd do
                local entry = filtered[i]
                if ImGui.Selectable((entry.fileName or entry.name) .. "##" .. entry.name, false) then
                    samePathMenu.spawn(element, entry, spawnList)
                    ImGui.CloseCurrentPopup()
                elseif ImGui.IsItemHovered() then
                    style.tooltip(getEntryPath(entry))
                    if previewEnabled then
                        hoveredThisFrame = entry
                        previewSpawnUI = spawnUI
                        spawnUI.handleAssetPreviewHovered(entry, false, spawnList)
                    end
                end
            end
        end

        ImGui.EndChild()
    end
end

---Submenu entry for the hierarchy context menu.
---@param element element
function samePathMenu.drawContextMenuItem(element)
    if not samePathMenu.isSupported(element) then return end

    if ImGui.BeginMenu(style.resolveActionLabelNoIconOnly(IconGlyphs.FolderSearchOutline, "Spawn from same path", "spawnFromSamePath")) then
        drawEntryList(element, "##samePathMenu")
        ImGui.EndMenu()
    end
end

---Button opening the list as a popup, drawn at the end of the mesh section.
---@param element element
function samePathMenu.drawButton(element)
    if not samePathMenu.isSupported(element) then return end

    if ImGui.Button(style.resolveActionLabelNoIconOnly(IconGlyphs.FolderSearchOutline, "Spawn from same path", "spawnFromSamePathButton")) then
        ImGui.OpenPopup(POPUP_ID)
    end
    style.tooltip("Spawn another mesh from the same asset path, in place of this one and with its appearance")

    if ImGui.BeginPopup(POPUP_ID) then
        drawEntryList(element, "##samePathPopup")
        ImGui.EndPopup()
    end
end

---Stops the preview once no row of the list is hovered anymore, including when it closed.
---Called once per frame, after every window was drawn.
function samePathMenu.finalizeFrame()
    if hoveredThisFrame then
        previewEntry = hoveredThisFrame
    elseif previewEntry then
        if previewSpawnUI and previewSpawnUI.hoveredEntry == previewEntry then
            previewSpawnUI.hoveredEntry = nil
            previewSpawnUI.stopActiveAssetPreview()
        end

        previewEntry = nil
    end

    hoveredThisFrame = nil
end

return samePathMenu
