-- _                       __          ___
-- | |                      \ \        / / |
-- | | _____  __ _ _ __  _   \ \  /\  / /| |__   ___  ___ _______
-- | |/ / _ \/ _` | '_ \| | | \ \/  \/ / | '_ \ / _ \/ _ \_  / _ \
-- |   <  __/ (_| | | | | |_| |\  /\  /  | | | |  __/  __// /  __/
-- |_|\_\___|\__,_|_| |_|\__,_| \/  \/   |_| |_|\___|\___/___\___|
-------------------------------------------------------------------------------------------------------------------------------
-- This mod was created by keanuWheeze from CP2077 Modding Tools Discord.
--
-- You are free to use this mod as long as you follow the following license guidelines:
--    * It may not be uploaded to any other site without my express permission.
--    * Using any code contained herein in another mod requires full credits / asking me.
--    * You may not fork this code and make your own competing version of this mod available for download without my permission.
--
-------------------------------------------------------------------------------------------------------------------------------

local settings = require("modules/utils/settings")
local builder = require("modules/utils/entityBuilder")
local Cron = require("modules/utils/Cron")
local groupLoadManager = require("modules/utils/pipeline/groupLoadManager")
local groupExportManager = require("modules/utils/pipeline/groupExportManager")
local cache = require("modules/utils/cache")
local style = require("modules/ui/style")
local history = require("modules/utils/history")
local input = require("modules/utils/input")
local registry = require("modules/utils/nodeRefRegistry")
local rht = require("modules/utils/rhtPlugin")
local preview = require("modules/utils/previewUtils")
local previewSyncManager = require("modules/utils/previewSyncManager")

---@class spawner
---@field runtimeData {cetOpen: boolean, inGame: boolean, inMenu: boolean}
---@field baseUI baseUI
---@field player any
spawner = {
    player = nil,
    runtimeData = {
        cetOpen = false,
        inGame = false,
        inMenu = false
    },

    e = function(data)
        local red = require("modules/utils/redConverter")
        config.saveFile("wkit.json", red.redDataToJSON(data))
    end,

    i = function(data)
        local red = require("modules/utils/redConverter")
        red.JSONToRedData(config.loadFile("wkit.json"), data)
    end,

    baseUI = require("modules/ui/baseUI"),
    editor = require("modules/utils/editor/editor"),
    GameUI = require("modules/utils/GameUI")
}

-- local x = collectgarbage("count")

function spawner:new()
    registerForEvent("onInit", function()
        self.player = Game.GetPlayer()
        settings.load()
        previewSyncManager.reset()
        cache.load()
        cache.generateRecordsList()

        self.baseUI.init()
        self.baseUI.savedUI.spawner = self
        self.baseUI.savedUI.backwardComp()
        self.baseUI.savedUI.filter = settings.savedUIFilter
        self.baseUI.spawnUI.filter = settings.spawnUIFilter
        self.baseUI.spawnUI.loadSpawnData(self)
        self.baseUI.spawnUI.prefabsUI.init(self)
        self.baseUI.spawnUI.favoritesUI.init(self)

        self.baseUI.spawnedUI.spawner = self
        self.baseUI.spawnedUI.cachePaths()
        self.baseUI.spawnedUI.registerHotkeys()
        self.baseUI.savedUI.reload()

        self.baseUI.exportUI.init(self)
        history.spawnedUI = self.baseUI.spawnedUI
        registry.init(self)

        self.editor.init(self)
        rht.init(self)

        Game.GetScriptableServiceContainer():GetService("EntityBuilder"):Initialize()
        builder.init()

        if not ModArchiveExists("scc_collision.archive") then
            print("[WorldBuilder] scc_collision.archive not found. Collision mesh preview will not be available.\nIf you wish to have collision mesh previews, please download the optional \"Collision Mesh Preview\" archive and install it.")
        end

        Observe('RadialWheelController', 'OnIsInMenuChanged', function(_, isInMenu)
            self.runtimeData.inMenu = isInMenu
        end)

        self.GameUI.OnSessionStart(function()
            self.runtimeData.inGame = true
            previewSyncManager.reset()
            self.baseUI.spawnedUI.root:setVisible(true, false)
            preview.addHUD()
        end)

        self.GameUI.OnSessionEnd(function()
            self.runtimeData.inGame = false
            self.baseUI.spawnedUI.root:setVisible(false, false)
            preview.elements = {}
            previewSyncManager.reset()
        end)

        self.runtimeData.inGame = not self.GameUI.IsDetached()

        if self.runtimeData.inGame then
            preview.addHUD()
        end
    end)

    registerForEvent("onUpdate", function (dt)
        if not self.editor then return end

        -- Keep Cron alive while a queued group pipeline is active, even if menu state is reported as open.
        if self.runtimeData.inGame and (not self.runtimeData.inMenu or groupLoadManager.isActive() or groupExportManager.isActive()) then
            Cron.Update(dt)
            previewSyncManager.update(dt)
        end

        if self.editor.camera then
            self.editor.camera.deltaTime = dt
        end
    end)

    registerForEvent("onShutdown", function ()
        if settings.despawnOnReload then
            self.baseUI.spawnedUI.root:remove()
        end
    end)

    registerForEvent("onDraw", function()
        if not self.editor then return end

        style.initialize(true)
        self.editor.suspend(self.runtimeData.cetOpen)

        if self.runtimeData.cetOpen then
            self.editor.onDraw()
            self.baseUI.draw(self)
            input.update()
        else
            self.baseUI.spawnUI.hidden()
        end

        -- if ImGui.Begin("Collect", ImGuiWindowFlags.AlwaysAutoResize) then
        --     ImGui.Text("Memory delta: " .. string.format("%.2f", collectgarbage("count") - x) .. " KB")
        --     x = collectgarbage("count")
        --     ImGui.End()
        -- end
    end)

    registerForEvent("onOverlayOpen", function()
        self.runtimeData.cetOpen = true
    end)

    registerForEvent("onOverlayClose", function()
        self.runtimeData.cetOpen = false

        -- Arrow distance scaling is driven from onDraw, which stops running here. Reset now so no
        -- gizmo is left frozen at the size it had for a far-away camera. (editor.toggle does the same
        -- on its own exit path, this covers closing the overlay without editor mode ever being on.)
        if self.editor and self.editor.resetArrowScale then
            self.editor.resetArrowScale()
        end
    end)

    return self
end

return spawner:new()
