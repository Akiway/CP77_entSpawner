local style = require("modules/ui/style")
local settings = require("modules/utils/settings")
local history = require("modules/utils/history")

local groupMeshConverter = {}

local meshConverterTypeDefs = {
    static = {
        id = "static",
        node = "worldMeshNode",
        label = IconGlyphs.CubeOutline .. " Static Mesh",
        plural = "static meshes",
        conversions = {
            { to = "rotating", method = "convertToRotatingMesh", lossy = false }
        }
    },
    rotating = {
        id = "rotating",
        node = "worldRotatingMeshNode",
        label = IconGlyphs.FormatRotate90 .. " Rotating Mesh",
        plural = "rotating meshes",
        warning = "Rotating mesh specific properties will be removed.",
        conversions = {
            { to = "static", method = "convertToStaticMesh", lossy = true }
        }
    },
    cloth = {
        id = "cloth",
        node = "worldClothMeshNode",
        label = IconGlyphs.ReceiptOutline .. " Cloth Mesh",
        plural = "cloth meshes",
        warning = "Cloth mesh specific properties will be removed.",
        conversions = {
            { to = "static", method = "convertToStaticMesh", lossy = true },
            { to = "rotating", method = "convertToRotatingMesh", lossy = true }
        }
    },
    dynamic = {
        id = "dynamic",
        node = "worldDynamicMeshNode",
        label = IconGlyphs.CubeSend .. " Dynamic Mesh",
        plural = "dynamic meshes",
        warning = "Dynamic mesh specific properties will be removed.",
        conversions = {
            { to = "static", method = "convertToStaticMesh", lossy = true },
            { to = "rotating", method = "convertToRotatingMesh", lossy = true }
        }
    }
}

local meshConverterTypeOrder = { "static", "rotating", "cloth", "dynamic" }

local function collectAvailableFromTypeIds(entries)
    local meshTypeCounts = {}

    for _, entry in ipairs(entries) do
        local spawnable = entry.spawnable
        if spawnable and spawnable.node then
            for _, typeId in ipairs(meshConverterTypeOrder) do
                local def = meshConverterTypeDefs[typeId]
                if def.node == spawnable.node then
                    meshTypeCounts[typeId] = (meshTypeCounts[typeId] or 0) + 1
                    break
                end
            end
        end
    end

    local availableFromTypeIds = {}
    for _, typeId in ipairs(meshConverterTypeOrder) do
        if meshTypeCounts[typeId] and meshTypeCounts[typeId] > 0 then
            table.insert(availableFromTypeIds, typeId)
        end
    end

    return availableFromTypeIds
end

local function applyMeshGroupConversion(entries, fromDef, conversion)
    history.addAction(history.getMultiSelectChange(entries))

    local nApplied = 0
    for _, entry in ipairs(entries) do
        if entry.spawnable and entry.spawnable.node == fromDef.node and entry.spawnable[conversion.method] then
            entry.spawnable[conversion.method](entry.spawnable)
            nApplied = nApplied + 1
        end
    end

    local toDef = meshConverterTypeDefs[conversion.to]
    ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, string.format("Converted %s %s to %s", nApplied, fromDef.plural, toDef.plural)))
end

function groupMeshConverter.getGroupedProperty(paths)
    local entries = {}
    for _, child in ipairs(paths) do
        table.insert(entries, child.ref)
    end

    if #collectAvailableFromTypeIds(entries) == 0 then
        return nil
    end

    return {
        name = "Mesh",
        id = "meshConverter",
        entries = entries,
        data = {
            fromIndex = 0,
            toIndex = 0,
            pendingFromTypeId = nil,
            pendingConversionIndex = nil
        },
        draw = function(element, drawEntries)
            local availableFromTypeIds = collectAvailableFromTypeIds(drawEntries)
            if #availableFromTypeIds == 0 then return end

            local converterData = element.groupOperationData["meshConverter"]
            converterData.fromIndex = math.min(converterData.fromIndex, #availableFromTypeIds - 1)
            converterData.fromIndex = math.max(0, converterData.fromIndex)

            local fromOptions = {}
            for _, typeId in ipairs(availableFromTypeIds) do
                table.insert(fromOptions, meshConverterTypeDefs[typeId].label)
            end

            local lineStartX = ImGui.GetCursorPosX()
            local relationLabelX = lineStartX + ImGui.CalcTextSize("Convert") + 4
            local allLabelWidth = ImGui.CalcTextSize("all")
            local toLabelWidth = ImGui.CalcTextSize("to")
            local relationWidth = math.max(allLabelWidth, toLabelWidth) + ImGui.GetStyle().ItemSpacing.x
            local selectorX = relationLabelX + relationWidth
            local selectorWidth = 165 * style.viewSize

            style.mutedText("Convert")
            ImGui.SameLine()
            ImGui.SetCursorPosX(relationLabelX)
            style.mutedText("all")
            ImGui.SameLine()
            ImGui.SetCursorPosX(selectorX)
            ImGui.SetNextItemWidth(selectorWidth)
            local fromIndex, fromChanged = ImGui.Combo("##groupMeshConvertFrom", converterData.fromIndex, fromOptions, #fromOptions)
            if fromChanged then
                converterData.fromIndex = fromIndex
                converterData.toIndex = 0
            end

            local fromTypeId = availableFromTypeIds[converterData.fromIndex + 1]
            local fromDef = meshConverterTypeDefs[fromTypeId]
            local toOptions = {}
            for _, conversion in ipairs(fromDef.conversions) do
                table.insert(toOptions, meshConverterTypeDefs[conversion.to].label)
            end

            ImGui.SetCursorPosX(relationLabelX)
            style.mutedText("to")
            ImGui.SameLine()
            ImGui.SetCursorPosX(selectorX)
            ImGui.SetNextItemWidth(selectorWidth)
            converterData.toIndex = math.min(converterData.toIndex, #toOptions - 1)
            converterData.toIndex = math.max(0, converterData.toIndex)
            converterData.toIndex, _ = ImGui.Combo("##groupMeshConvertTo", converterData.toIndex, toOptions, #toOptions)
            ImGui.SameLine()
            local selectedConversion = fromDef.conversions[converterData.toIndex + 1]
            if ImGui.Button("Convert") then
                if selectedConversion.lossy and not settings.skipLossyConversionWarning then
                    converterData.pendingFromTypeId = fromTypeId
                    converterData.pendingConversionIndex = converterData.toIndex
                    ImGui.OpenPopup("Lossy Conversion##groupMeshConverter")
                else
                    applyMeshGroupConversion(drawEntries, fromDef, selectedConversion)
                end
            end
            style.tooltip("Convert selected mesh subtype entries to the selected target type")

            if ImGui.BeginPopupModal("Lossy Conversion##groupMeshConverter", true, ImGuiWindowFlags.AlwaysAutoResize) then
                local pendingFromTypeId = converterData.pendingFromTypeId
                local pendingFromDef = pendingFromTypeId and meshConverterTypeDefs[pendingFromTypeId] or nil
                local pendingConversion = nil
                if pendingFromDef and converterData.pendingConversionIndex ~= nil then
                    pendingConversion = pendingFromDef.conversions[converterData.pendingConversionIndex + 1]
                end

                local nPending = 0
                if pendingFromDef then
                    for _, entry in ipairs(drawEntries) do
                        if entry.spawnable and entry.spawnable.node == pendingFromDef.node then
                            nPending = nPending + 1
                        end
                    end
                end

                style.mutedText("Warning")
                ImGui.Text("This conversion is lossy.")
                if pendingFromDef and pendingFromDef.warning then
                    ImGui.Text(pendingFromDef.warning)
                end
                ImGui.Text(string.format("Affected %s: %d", pendingFromDef and pendingFromDef.plural or "mesh(es)", nPending))
                ImGui.Text("Do you want to continue?")
                ImGui.Dummy(0, 8 * style.viewSize)
                local skipWarning, changed = ImGui.Checkbox("Do not ask again", settings.skipLossyConversionWarning)
                if changed then
                    settings.skipLossyConversionWarning = skipWarning
                    settings.save()
                end
                ImGui.Dummy(0, 8 * style.viewSize)

                if ImGui.Button("Convert") then
                    if pendingFromDef and pendingConversion then
                        applyMeshGroupConversion(drawEntries, pendingFromDef, pendingConversion)
                    end
                    converterData.pendingFromTypeId = nil
                    converterData.pendingConversionIndex = nil
                    ImGui.CloseCurrentPopup()
                end

                ImGui.SameLine()
                if ImGui.Button("Cancel") then
                    converterData.pendingFromTypeId = nil
                    converterData.pendingConversionIndex = nil
                    ImGui.CloseCurrentPopup()
                end

                ImGui.EndPopup()
            end
        end
    }
end

return groupMeshConverter
