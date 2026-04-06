local style = require("modules/ui/style")
local utils = require("modules/utils/utils")
local area = require("modules/classes/spawn/area/area")

---Class for dummy area, useful for getting outline
---@class dummyArea : area
local dummyArea = setmetatable({}, { __index = area })

function dummyArea:new()
	local o = area.new(self)

    o.spawnListType = "files"
    o.dataType = "Dummy Area"
    o.spawnDataPath = "data/spawnables/area/dummy/"
    o.modulePath = "area/dummyArea"
    o.node = "---"
    o.description = "Spawns a dummy area, which can be used for getting an outline for a gameStaticAreaShapeComponent."
    o.previewNote = "Does not do anything or get exported."
    o.icon = IconGlyphs.SelectionOff

    o.noExport = true

    setmetatable(o, { __index = self })
   	return o
end

function dummyArea:draw()
    area.draw(self)
    style.mutedText("This area does not do anything and is not exported.")

    if ImGui.Button("Copy outline to clipboard") then
        local paths = self:loadOutlinePaths()
        local markers = {}
        local height = 0

        if utils.indexValue(paths, self.outlinePath) ~= -1 then
            local sUI = self.object and self.object.sUI or nil
            local outline = sUI and sUI.getElementByPath and sUI.getElementByPath(self.outlinePath) or nil

            if outline and outline.childs then
                for _, child in pairs(outline.childs) do
                    local spawnable = child and child.spawnable or nil
                    if utils.isA(child, "spawnableElement") and spawnable and spawnable.modulePath == "area/outlineMarker" and spawnable.position then
                        local offset = utils.subVector(spawnable.position, self.position)

                        table.insert(markers, {
                            ["$type"] = "Vector3",
                            ["X"] = offset.x,
                            ["Y"] = offset.y,
                            ["Z"] = offset.z
                        })
                        height = tonumber(spawnable.height) or height
                    end
                end
            end
        end

        utils.insertClipboardValue("outline", {
            height = height,
            points = markers
        })

        ImGui.ShowToast(ImGui.Toast.new(ImGui.ToastType.Success, 2500, string.format("Copied outline containing %s points to the clipboard", #markers)))
    end
end

return dummyArea
