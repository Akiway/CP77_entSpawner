local style = require("modules/ui/style")
local utils = require("modules/utils/core/utils")
local cache = require("modules/utils/game/cache")
local builder = require("modules/utils/game/entityBuilder")
local componentUI = require("modules/utils/ui/componentUI")

---The styled panels for entity components in Entity Instance Data, registered with componentUI.
---Each panel styles some fields; componentUI draws the rest under "Other".
local componentPanels = {}

local meshAppearances = {}
local meshAppearancesLoading = {}

---Appearance names of a mesh, from the mesh cache or loaded once in the background.
---@param path string
---@return string[]? apps Nil until loaded, or when the path is not a mesh
local function getMeshAppearances(path)
    if type(path) ~= "string" or path == "" or path == "0" then
        return nil
    end

    if meshAppearances[path] then
        return meshAppearances[path]
    end

    local cached = cache.getMeshResource(path)
    if cached and cached.apps then
        meshAppearances[path] = cached.apps
        return cached.apps
    end

    if not meshAppearancesLoading[path] then
        meshAppearancesLoading[path] = true
        builder.registerLoadResource(path, function(resource)
            if not resource or not resource.appearances then return end

            local apps = {}
            for _, appearance in ipairs(resource.appearances) do
                table.insert(apps, appearance.name.value)
            end
            meshAppearances[path] = apps
        end)
    end

    return nil
end

---Mesh appearance as a dropdown of the appearances the mesh has; the text field until they are loaded.
local function drawMeshAppearance(entity, componentID, component, componentChanges, max)
    local path = { "meshAppearance", "$value" }
    local meshPath = componentUI.getValue(component, componentChanges, { "mesh", "DepotPath", "$value" })
    local apps = getMeshAppearances(tostring(meshPath or ""))

    if not apps then
        entity:drawComponentPropertyRow(componentID, component, componentChanges, "meshAppearance", max - ImGui.GetCursorPosX())
        return
    end

    local current = tostring(componentUI.getValue(component, componentChanges, path) or "")
    local options = utils.deepcopy(apps)
    if utils.indexValue(options, current) < 1 then
        table.insert(options, 1, current)
    end

    local modified = componentUI.isPathModified(component, componentChanges, path)
    componentUI.drawLabelRow("Appearance", max, modified)

    style.pushStyleColor(modified, ImGuiCol.Text, style.regularColor)
    local selected, changed = style.trackedCombo(
        entity.object,
        componentUI.getWidgetID(componentID, path),
        utils.indexValue(options, current) - 1,
        options,
        200,
        { tooltip = "Appearances of the mesh" }
    )
    entity:drawComponentReset(componentID, path, "CName")
    style.popStyleColor(modified)

    if changed then
        entity:updatePropValue(componentID, path, options[selected + 1])
    end
end

local meshPanel = componentUI.dataPanel({
    sections = {
        {
            rows = {
                { path = { "mesh" }, kind = "property" },
                { path = { "meshAppearance" }, label = "Appearance", kind = "custom", draw = drawMeshAppearance },
                { path = { "isEnabled" }, label = "Enabled", kind = "bool" }
            }
        },
        {
            title = "Shadows",
            rows = {
                { path = { "castShadows" }, label = "Shadows", kind = "enum", enum = "shadowsShadowCastingMode" },
                { path = { "castLocalShadows" }, label = "Local Shadows", kind = "enum", enum = "shadowsShadowCastingMode" },
                { path = { "castRayTracedGlobalShadows" }, label = "RT Global Shadows", kind = "enum", enum = "shadowsShadowCastingMode" },
                { path = { "castRayTracedLocalShadows" }, label = "RT Local Shadows", kind = "enum", enum = "shadowsShadowCastingMode" }
            }
        },
        {
            title = "Rendering",
            rows = {
                { path = { "autoHideDistance" }, label = "Auto Hide Distance", kind = "float", opts = { step = 0.05, min = 0, maxValue = 9999, format = "%.1f", width = 90 } },
                { path = { "LODMode" }, label = "LOD Mode", kind = "enum", enum = "entMeshComponentLODMode" },
                { path = { "forceLODLevel" }, kind = "property" },
                { path = { "renderingPlane" }, label = "Rendering Plane", kind = "enum", enum = "ERenderingPlane" },
                { path = { "objectTypeID" }, label = "Object Type", kind = "enum", enum = "ERenderObjectType" },
                { path = { "motionBlurScale" }, label = "Motion Blur Scale", kind = "float", opts = { step = 0.01, min = 0, maxValue = 9999, format = "%.2f", width = 90 } }
            }
        },
        {
            title = "Navigation",
            rows = {
                { path = { "overrideMeshNavigationImpact" }, label = "Override Navigation Impact", kind = "bool" },
                { path = { "navigationImpact" }, kind = "property" }
            }
        }
    }
})

local soundPanel = componentUI.dataPanel({
    sections = {
        {
            rows = {
                { path = { "audioName" }, kind = "property" },
                { path = { "maxPlayDistance" }, label = "Max Play Distance", kind = "float", radiusPreview = true, opts = { step = 0.1, min = 0, maxValue = 9999, format = "%.1fm", width = 90 } },
                { path = { "streamingDistance" }, label = "Streaming Distance", kind = "float", opts = { step = 0.1, min = 0, maxValue = 9999, format = "%.1fm", width = 90 } }
            }
        },
        {
            title = "Occlusion",
            rows = {
                { path = { "applyObstruction" }, label = "Obstruction", kind = "bool" },
                { path = { "applyAcousticOcclusion" }, label = "Acoustic Occlusion", kind = "bool" },
                { path = { "applyAcousticRepositioning" }, label = "Acoustic Repositioning", kind = "bool" },
                { path = { "obstructionChangeTime" }, label = "Obstruction Change Time", kind = "float", opts = { step = 0.01, min = 0, maxValue = 9999, format = "%.2fs", width = 90 } }
            }
        },
        {
            title = "Voice",
            rows = {
                { path = { "voEventOverride" }, kind = "property" },
                { path = { "minVocalizationRepeatTime" }, label = "Min. Vocalization Repeat", kind = "float", opts = { step = 0.1, min = 0, maxValue = 9999, format = "%.1fs", width = 90 } }
            }
        }
    }
})

local emitterPanel = componentUI.dataPanel({
    sections = {
        {
            rows = {
                { path = { "EmitterName" }, kind = "property" },
                { path = { "EmitterType" }, label = "Emitter Type", kind = "enum", enum = "audioEntityEmitterContextType", opts = { width = 175 } },
                { path = { "emitterMetadataName" }, kind = "property" },
                { path = { "updateDistance" }, label = "Update Distance", kind = "float", opts = { step = 0.1, min = 0, maxValue = 9999, format = "%.1fm", width = 90 } }
            }
        },
        {
            title = "Events",
            rows = {
                { path = { "OnAttach" }, kind = "property" },
                { path = { "OnDetach" }, kind = "property" }
            }
        }
    }
})

local function isObjectTypeMode(component, componentChanges)
    return componentUI.getValue(component, componentChanges, { "decalRenderMode" }) == "DRM_ObjectType"
end

local decalPanel = componentUI.dataPanel({
    sections = {
        {
            rows = {
                { path = { "material" }, kind = "property" },
                { path = { "isEnabled" }, label = "Enabled", kind = "bool" },
                { path = { "alpha" }, label = "Alpha", kind = "float", opts = { step = 0.01, min = 0, maxValue = 100, format = "%.2f", width = 85 } },
                { path = { "verticalFlip" }, label = "Vertical Flip", kind = "bool" },
                { path = { "horizontalFlip" }, label = "Horizontal Flip", kind = "bool" },
                { path = { "isStretchingEnabled" }, label = "Stretching Enabled", kind = "bool", opts = { tooltip = "If enabled, the decal will stretch to fit the surface it is projected onto." } },
                { path = { "autoHideDistance" }, label = "Auto Hide Distance", kind = "float", opts = { step = 0.05, min = 0, maxValue = 9999, format = "%.2f", width = 85 } },
                { path = { "orderNo" }, kind = "property" },
                { path = { "normalThreshold" }, label = "Normal Threshold", kind = "float", opts = { step = 0.05, min = 0, maxValue = 90, format = "%.2f", width = 85, tooltip = "Maximum angle, in degrees, between the decal and a surface for it to project onto it." } },
                { path = { "roughnessScale" }, label = "Roughness Scale", kind = "float", opts = { step = 0.01, min = 0, maxValue = 100, format = "%.2f", width = 85, tooltip = "Multiplier applied to the roughness of the surface underneath the decal." } },
                { path = { "decalRenderMode" }, label = "Render Mode", kind = "enum", enum = "EDecalRenderMode", opts = { tooltip = "Which surfaces the decal draws on.\nDRM_AllStatic: world geometry such as ground, walls and props.\nDRM_ObjectType: only meshes of the type set in Surface Type, such as Road, Vehicle or Character.\nDRM_AllDynamic: entities such as vehicles and bodies.\nDRM_All: almost unused in vanilla, and did not draw in testing." } },
                { path = { "surfaceType" }, label = "Surface Type", kind = "enum", enum = "ERenderObjectType", visible = isObjectTypeMode, opts = { tooltip = "The decal draws only on meshes whose render object type matches this.\nThe type is set in the .mesh file: vehicles are ROT_Vehicle, characters ROT_Character, most world meshes ROT_Static." } }
            }
        }
    }
})

---Registers every panel. Lights come from lightComponentUI, installed on the entity class.
function componentPanels.register()
    componentUI.registerPanel({ "entLightComponent" }, function(entity, componentID, component, propertySearch)
        entity:drawLightComponentInstanceData(componentID, component, propertySearch)
    end)
    componentUI.registerPanel({ "entMeshComponent", "entSkinnedMeshComponent", "entPhysicalDestructionComponent" }, meshPanel)
    componentUI.registerPanel({ "entDecalComponent" }, decalPanel)
    componentUI.registerPanel({ "gameaudioSoundComponentBase" }, soundPanel)
    componentUI.registerPanel({ "gameAudioEmitterComponent" }, emitterPanel)
end

return componentPanels
