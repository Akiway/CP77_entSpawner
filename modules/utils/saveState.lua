local config = require("modules/utils/config")
local utils = require("modules/utils/utils")
local logger = require("modules/utils/logger")

---Tracks, per root group, whether it differs from its file on disk, and caches the canonical JSON of
---every node so a re-check only costs the part of the tree that actually changed.
---
---Two ideas carry the whole module:
---
---1. **A rope, not a string.** Each node caches `pieces`, a flat list whose entries are either literal
---   JSON fragments or nested `pieces` tables belonging to children. Concatenating a node's full JSON
---   into its cache would cost O(total bytes x depth); the rope costs O(total bytes) once, and the
---   finished document is never materialised at all -- the writer streams the rope into the file.
---
---2. **A Merkle content hash.** A node's hash is derived from its own fields plus its children's
---   hashes, so the root hash changes if and only if something below it changed. Answering "is this
---   project modified?" therefore never costs more than rebuilding the invalidated chain.
---
---The hash deliberately ignores editor-only state (see `VOLATILE_KEYS`), so clicking a row or folding
---the hierarchy does not make a project look modified.
local saveState = {
    ---Bumped by every tracked mutation. A cheap "is anything worth re-checking?" trigger.
    mutationEpoch = 0,
    ---Per root-child records, keyed by `element.id`. See `getRecord` for why not keyed by reference.
    records = {},
    ---When false, every build ignores cached nodes (escape hatch / reference builds).
    cacheEnabled = true,

    suppressDepth = 0,
    suppressSince = nil,

    ---Assigned once during init, same pattern as `history.spawnedUI`.
    ---@type spawnedUI?
    spawnedUI = nil,

    stats = { built = 0, reused = 0 }
}

---Fields that exist purely as editor UI state, or that are recomputed from the parent on load. They
---are still written to disk, so reopening a project restores the way it looked -- but they must not
---count as content changes.
---
---`headerOpen` is flipped across the entire tree by the Fold/Expand All buttons, which does not go
---through history; `propertyHeaderStates` is rewritten every frame an inspector is open. Without this
---filter, merely looking at a project would mark it modified.
---
---`selected` and `hovered` are no longer serialized at all -- selection is live editor state, and
---restoring it on load left parts of a freshly opened project already selected. They stay listed so
---the filter still holds for any data that predates that change.
---
---`hiddenByParent` and `lockedByParent` are pure derived state: `element:load` restores them, but
---`addChild` immediately overwrites both from the actual parent. Excluding them also means a
---visibility or lock toggle does not have to invalidate the cache of every descendant.
local VOLATILE_KEYS = {
    selected = true,
    hovered = true,
    headerOpen = true,
    propertyHeaderStates = true,
    hiddenByParent = true,
    lockedByParent = true
}

---Shared read-only context handed to `element:serialize`.
local BUILD_CTX = { shallow = true, copyVolatile = true }

---How long suppression may stay up with no pipeline running before it is assumed leaked.
local SUPPRESS_WATCHDOG_SECONDS = 60

local NODE_KIND_SPAWNABLE = 1
local NODE_KIND_GROUP = 2
local NODE_KIND_OTHER = 3

---@param value string
---@return string
local function hashString(value)
    local hash = tostring(FNV1a64(value))
    return (hash:gsub("ULL", ""))
end

--------------------------------------------------------------------------------------------------
-- Suppression
--------------------------------------------------------------------------------------------------

---Stops mutations from marking anything dirty. Used while loading from disk (the tree matches the
---file by definition) and while the engine drives visibility on session start/end.
---Always pair with `popSuppress`, under `pcall` if the body can throw.
function saveState.pushSuppress()
    saveState.suppressDepth = saveState.suppressDepth + 1
    if saveState.suppressDepth == 1 then
        saveState.suppressSince = os.clock()
    end
end

function saveState.popSuppress()
    if saveState.suppressDepth <= 0 then
        saveState.suppressDepth = 0
        saveState.suppressSince = nil
        return
    end

    saveState.suppressDepth = saveState.suppressDepth - 1
    if saveState.suppressDepth == 0 then
        saveState.suppressSince = nil
    end
end

---@return boolean
function saveState.isSuppressed()
    return saveState.suppressDepth > 0
end

---Force-reopens tracking if suppression has been held far too long with nothing running, which can
---only mean a `pushSuppress` leaked. Silently losing all change tracking for a session would be much
---worse than an extra save, so this fails open and complains.
---@param pipelineActive boolean? True while a load/save pipeline legitimately holds suppression.
function saveState.updateWatchdog(pipelineActive)
    if saveState.suppressDepth <= 0 or pipelineActive then return end
    if not saveState.suppressSince then return end

    if (os.clock() - saveState.suppressSince) > SUPPRESS_WATCHDOG_SECONDS then
        logger:error(string.format(
            "[SaveState] Change tracking was suppressed for over %ds with nothing running (depth %d). Forcing it back on.",
            SUPPRESS_WATCHDOG_SECONDS, saveState.suppressDepth))
        saveState.suppressDepth = 0
        saveState.suppressSince = nil
    end
end

--------------------------------------------------------------------------------------------------
-- Records
--------------------------------------------------------------------------------------------------

---Returns the root-level ancestor of an element, i.e. the direct child of the real root.
---@param element element?
---@return element? rootChild `nil` when the element is the real root itself, or detached.
function saveState.getRootChild(element)
    local node = element

    while node do
        local parent = node.parent
        if parent == nil then return nil end
        if parent.parent == nil then return node end
        node = parent
    end

    return nil
end

---Fetches (creating if needed) the record for a root child.
---
---Records are keyed by `element.id` in a side map rather than stored on the element, because undoing
---a deletion builds a brand new element object while preserving its id. Anything attached to the old
---object -- or a table keyed by reference -- would be silently lost by delete-then-undo.
---@param rootChild element
---@return table record
function saveState.getRecord(rootChild)
    local id = rootChild.id
    local record = saveState.records[id]

    if not record then
        record = {
            id = id,
            projectFile = nil,
            dirty = true,
            state = "new",
            mutationCounter = 0,
            lastMutationTime = os.clock(),
            lastSavedContentHash = nil,
            lastSessionContentHash = nil,
            savesSinceVerify = nil,
            lastError = nil
        }
        saveState.records[id] = record
    end

    -- Refreshed on every access so the record follows the current object for this id. The uID is
    -- re-stamped along with it: delete-then-undo hands back a brand new element object that knows
    -- nothing about the binding this record still holds.
    record.ref = rootChild
    rootChild.projectUID = record.projectFile

    return record
end

---@param element element?
---@return table? record
function saveState.getRecordFor(element)
    local rootChild = saveState.getRootChild(element)
    if not rootChild then return nil end
    return saveState.getRecord(rootChild)
end

---Drops records whose element is no longer in the tree, so removed groups do not pin memory.
---@param liveRootChilds element[] Current `spawnedUI.root.childs`.
function saveState.pruneRecords(liveRootChilds)
    local live = {}
    for _, child in ipairs(liveRootChilds) do
        live[child.id] = true
    end

    for id in pairs(saveState.records) do
        if not live[id] then
            saveState.records[id] = nil
        end
    end
end

---Whether a record's element is still a child of the real root.
---
---Records outlive their elements on purpose (delete-then-undo rebuilds an element but keeps its id),
---so "is this record still relevant?" has to be answered by looking at the tree.
---@param record table
---@return boolean
local function isLiveRootChild(record)
    local sUI = saveState.spawnedUI
    if not sUI or not sUI.root or not record.ref then return false end

    for _, child in ipairs(sUI.root.childs) do
        if child == record.ref then return true end
    end

    return false
end

---Whether an element is a root group that owns a project file, i.e. one auto-save may write.
---
---Randomized and scattered groups set `supportsSaving = false` and are deliberately excluded, as is
---anything nested: only a direct child of the real root is a project.
---@param element element?
---@return boolean
function saveState.isSavableRootGroup(element)
    return element ~= nil
        and utils.isA(element, "positionableGroup")
        and element.supportsSaving == true
        and element.parent ~= nil
        and element.parent:isRoot(true)
end

---Mirrors the binding onto the element itself, as `projectUID`.
---
---The record is the authority -- it survives delete-then-undo, which rebuilds the element object --
---but everything that draws a group (hierarchy rows, context menu, Projects tab sync) needs the id
---without reaching into this module's tables, and a live element is what those hold.
---
---Never serialized: the file name *is* the id, so storing it inside the file would only create a
---second copy to keep in sync, and copies/prefabs of a linked group would inherit a claim on a file
---they are not.
---@param record table
---@param projectUID string?
local function mirrorProjectUID(record, projectUID)
    if record.ref then
        record.ref.projectUID = projectUID
    end
end

---Drops a record's binding to its project file, leaving it looking like a group that was never saved.
---@param record table
local function releaseClaim(record)
    record.projectFile = nil
    record.lastSavedContentHash = nil
    record.state = "new"
    mirrorProjectUID(record, nil)
end

---Finds a record still present in the tree that is bound to a file.
---@param projectFile string
---@param exceptId any Record id to ignore, normally the one asking.
---@return table? claimant
local function findLiveClaimant(projectFile, exceptId)
    for id, other in pairs(saveState.records) do
        if id ~= exceptId and other.projectFile == projectFile and isLiveRootChild(other) then
            return other
        end
    end

    return nil
end

---Drops every other record's binding to a file.
---@param projectFile string
---@param exceptId any
---@return integer released
local function releaseOtherClaims(projectFile, exceptId)
    local released = 0

    for id, other in pairs(saveState.records) do
        if id ~= exceptId and other.projectFile == projectFile then
            releaseClaim(other)
            released = released + 1
        end
    end

    return released
end

---Marks a record as matching the file it is bound to, with the baseline hash still to be established.
---
---Shared by "just loaded from disk" and "just saved by hand", which are the same situation from here:
---the tree is the file, but computing the hash to prove it would mean a full-tree walk tacked onto an
---already expensive operation. The next persistence pass adopts whatever it computes instead --
---that is what `needsBaseline` means, and `markDirty` clears it the instant anything is edited.
---@param record table
local function adoptFileBaseline(record)
    record.needsBaseline = true
    record.dirty = true
    record.lastSavedContentHash = nil
    record.state = "clean"
end

---Binds a root group to the project file auto-save is allowed to overwrite, i.e. gives it its uID.
---
---Only a load from `data/objects/`, a successful manual save, or an explicit link action may bind.
---Renaming a group never rebinds: the name is display text, the file name is the identity, and the
---two stopped being the same thing on purpose.
---@param rootChild element
---@param projectFile string? File name including extension, or `nil` to unbind.
---@return boolean ok False when a group already in the tree holds that file.
function saveState.bindProjectFile(rootChild, projectFile)
    local record = saveState.getRecord(rootChild)

    if projectFile then
        local claimant = findLiveClaimant(projectFile, record.id)

        if claimant then
            -- A second copy of the same project is a perfectly normal thing to load. It just must not
            -- auto-save on top of the first one, so it stays unbound and behaves like a group that was
            -- never saved. Saving it by hand takes the file over.
            record.projectFile = nil
            record.state = "new"
            record.duplicateOf = projectFile
            mirrorProjectUID(record, nil)
            return false
        end

        -- Anything still holding this path is gone from the tree, so its claim is meaningless.
        -- Releasing it keeps a removed-then-reloaded group from being locked out of its own file.
        releaseOtherClaims(projectFile, record.id)
    end

    record.projectFile = projectFile
    record.duplicateOf = nil
    mirrorProjectUID(record, projectFile)
    if record.state == "error" then
        record.lastError = nil
    end
    if not projectFile then
        record.state = "new"
    end

    return true
end

---Breaks the link between a live root group and its project file, without touching the file.
---
---The group keeps its content and its name and goes back to behaving like one that was never saved:
---auto-save leaves it alone, and saving it asks for a file name again. The project stays in the
---Projects tab, now owned by nobody.
---@param rootChild element
---@return string? previousUID The file it was linked to, when it was linked at all.
function saveState.unbindProjectFile(rootChild)
    local record = saveState.getRecord(rootChild)
    local previous = record.projectFile

    if not previous then
        return nil
    end

    releaseClaim(record)
    record.duplicateOf = nil
    record.needsBaseline = false
    record.dirty = true

    return previous
end

---Points a root group at a project file it does not match yet.
---
---Unlike `markLoadedFromDisk` and `markManuallySaved`, which both mean "the tree and the file agree",
---this is the "take this file over" case: the group is deliberately left flagged as modified, because
---the file still holds someone else's content until the save that follows actually runs.
---@param rootChild element
---@param projectFile string File name including extension. May not exist yet.
---@return boolean ok False when a group already in the tree holds that file.
function saveState.linkToProjectFile(rootChild, projectFile)
    if not saveState.bindProjectFile(rootChild, projectFile) then
        return false
    end

    local record = saveState.getRecord(rootChild)
    record.needsBaseline = false
    record.lastSavedContentHash = nil
    record.dirty = true
    record.state = "edited"

    return true
end

---@param element element?
---@return string? projectUID
function saveState.getProjectUID(element)
    local record = saveState.getRecordFor(element)
    return record and record.projectFile or nil
end

---Finds the live root group that owns a project file.
---@param projectUID string File name including extension.
---@return element? rootChild
function saveState.findRootChildByUID(projectUID)
    if type(projectUID) ~= "string" or projectUID == "" then
        return nil
    end

    local sUI = saveState.spawnedUI
    if not sUI or not sUI.root then return nil end

    for _, child in ipairs(sUI.root.childs) do
        local record = saveState.records[child.id]
        if record and record.projectFile == projectUID and record.ref == child then
            return child
        end
    end

    return nil
end

---Moves a binding to a new file name, for when the file itself is renamed on disk.
---
---The group is still the same project and still matches what is now stored under the new name, so
---nothing about its modified state changes -- only the id it points at.
---@param oldProjectUID string
---@param newProjectUID string
---@return element? rootChild The live group that was retargeted, if any.
function saveState.retargetProjectUID(oldProjectUID, newProjectUID)
    local rootChild = saveState.findRootChildByUID(oldProjectUID)

    for _, other in pairs(saveState.records) do
        if other.projectFile == oldProjectUID then
            other.projectFile = newProjectUID
            mirrorProjectUID(other, newProjectUID)
        end

        if other.duplicateOf == oldProjectUID then
            other.duplicateOf = newProjectUID
        end
    end

    return rootChild
end

---Marks a root group as matching its file on disk.
---@param rootChild element
---@param contentHash string
function saveState.markSaved(rootChild, contentHash)
    local record = saveState.getRecord(rootChild)
    record.dirty = false
    record.needsBaseline = false
    record.lastSavedContentHash = contentHash
    record.lastError = nil
    record.state = record.projectFile and "clean" or "new"
end

---Records an explicit user save.
---
---Unlike a load this *takes* ownership of the file: if another group was bound to it, that binding is
---dropped rather than this one being refused. The user just overwrote the file, so the other group's
---claim is no longer true and auto-saving it would undo the save that was just made.
---@param rootChild element
---@param projectFile string File name including extension.
function saveState.markManuallySaved(rootChild, projectFile)
    releaseOtherClaims(projectFile, rootChild.id)

    local record = saveState.getRecord(rootChild)
    record.projectFile = projectFile
    mirrorProjectUID(record, projectFile)
    -- Cleared because this group now owns the file outright: it was refused a binding earlier only
    -- because someone else held it, and that is no longer true.
    record.duplicateOf = nil
    record.lastError = nil
    adoptFileBaseline(record)
end

---Records that a group was just loaded from `data/objects/`, so it matches its file by construction.
---Does nothing when the binding was refused, i.e. the file is already open under another group.
---@param rootChild element
---@param projectFile string File name including extension.
function saveState.markLoadedFromDisk(rootChild, projectFile)
    if not saveState.bindProjectFile(rootChild, projectFile) then
        return
    end

    adoptFileBaseline(saveState.getRecord(rootChild))
end

--------------------------------------------------------------------------------------------------
-- Mutation tracking
--------------------------------------------------------------------------------------------------

---Invalidates the cached JSON of an element and every ancestor, and marks the owning root group
---modified.
---
---The upward walk early-exits at the first already-invalid node. That is sound because invalidation
---always runs to the top, so "this node is invalid" implies "everything above it is invalid too" --
---which makes repeated marks (a drag, a multi-select edit) O(1) amortised rather than O(depth).
---@param element element?
function saveState.markDirty(element)
    if not element or saveState.suppressDepth > 0 then return end

    saveState.mutationEpoch = saveState.mutationEpoch + 1

    local node = element
    while node do
        local cache = node.__jsonCache
        if cache then
            if not cache.valid then break end
            cache.valid = false
        end
        node = node.parent
    end

    local rootChild = saveState.getRootChild(element)
    if not rootChild then return end

    local record = saveState.getRecord(rootChild)
    record.dirty = true
    record.lastMutationTime = os.clock()
    -- Per group, so an in-flight save is only abandoned when *this* group changes under it. A global
    -- counter would mean editing any group could starve a large one that takes several seconds.
    record.mutationCounter = (record.mutationCounter or 0) + 1

    -- A pending baseline claims "this already matches the file", which stops the pass after a load
    -- or manual save from rewriting an identical file. An edit makes that untrue, so it must be
    -- dropped here or the next pass would adopt unsaved edits as the on-disk state and skip writing.
    record.needsBaseline = false

    if record.state == "clean" then
        record.state = "edited"
    end
end

---Marks an element, its whole subtree, and every ancestor.
---
---For operations that change every descendant at once. A group transform rewrites the position and
---rotation of every leaf under it, so marking only the group would rebuild the group's own node and
---then splice its children straight back in from cache -- the file would carry the new group rotation
---over the previous save's child transforms.
---
---The downward walk cannot early-exit on an already-invalid node the way `markDirty`'s upward one
---can: invalidity propagates towards the root, never away from it, so an invalid node says nothing
---about its children. It is a plain flag write per node, against callers that already touch every
---leaf, so it costs nothing next to the transform itself.
---@param element element?
function saveState.markSubtreeDirty(element)
    if not element or saveState.suppressDepth > 0 then return end

    -- First, never the other way around: `markDirty` walks up and stops at the first already-invalid
    -- node, so invalidating this element beforehand would leave every ancestor cached. It also does
    -- the record bookkeeping (dirty, quiet window, baseline) the walk below does not repeat.
    saveState.markDirty(element)

    local function invalidate(node)
        for _, child in ipairs(node.childs) do
            local cache = child.__jsonCache
            if cache then
                cache.valid = false
            end

            invalidate(child)
        end
    end

    invalidate(element)
end

---Marks every element in a list.
---@param elements element[]?
function saveState.markDirtyMany(elements)
    if not elements then return end

    for _, element in pairs(elements) do
        saveState.markDirty(element)
    end
end

---Flags every root group as needing a re-check, without claiming any of them actually changed.
---
---This is the safety net behind the precise hooks: it costs one field write per root group, and a
---re-check of a group whose cache is still fully valid is a single cache hit. Deliberately does not
---touch `state`, so the indicator keeps showing what the last completed check established rather than
---lighting up every group whenever anything anywhere is edited.
function saveState.markAllRootsDirty()
    local sUI = saveState.spawnedUI
    if not sUI or not sUI.root then return end

    -- Bumped here too, not just in markDirty: this is reached for actions that carry no element
    -- attribution, and the session snapshot polls this counter to know it has gone stale.
    saveState.mutationEpoch = saveState.mutationEpoch + 1

    for _, child in ipairs(sUI.root.childs) do
        -- Only `dirty`. Deliberately not `lastMutationTime`: that drives the per-group idle window,
        -- and stamping it here would let an edit in one group reset the countdown for every other
        -- group -- continuous work anywhere would then starve the whole pipeline.
        saveState.getRecord(child).dirty = true
    end
end

---Entry point for `history.addAction` and for a completed undo/redo.
---@param action table? History action, possibly carrying `dirtyElements`.
function saveState.onHistoryAction(action)
    if saveState.suppressDepth > 0 then return end

    if action and action.dirtyElements then
        for _, element in ipairs(action.dirtyElements) do
            saveState.markDirty(element)
        end
    end

    saveState.markAllRootsDirty()
end

---Drops all cached JSON under an element. Used when a verification mismatch proves a cache is stale.
---@param element element
function saveState.dropCache(element)
    element.__jsonCache = nil

    for _, child in ipairs(element.childs) do
        saveState.dropCache(child)
    end
end

--------------------------------------------------------------------------------------------------
-- Building
--------------------------------------------------------------------------------------------------

---Encodes one node's own fields and assembles its rope entry and content hash.
---
---Byte-for-byte agreement with `config.saveFile` is a hard requirement here: if this diverges by a
---single escape or float format, a manual save and an auto-save of unchanged data would disagree
---forever. That is why every value goes through `config.encodeStableValueInto` rather than any
---local encoding, and why `childs`/`elementCount` are merged into the sorted key sequence instead of
---being appended -- `encodeStableJSONValue` sorts all object keys together.
---@param frame table
---@param hashSkipKeys table<string, boolean>? Extra keys to keep out of the content hash.
---@return table? pieces
---@return string? contentHashOrErr
local function emitNode(frame, hashSkipKeys)
    local own = frame.own
    local isGroup = utils.isSerializedGroupStrict(own)

    local keys = {}
    for key in pairs(own) do
        keys[#keys + 1] = key
    end
    keys[#keys + 1] = "childs"
    if isGroup then
        keys[#keys + 1] = "elementCount"
    end
    table.sort(keys)

    local pieces = { "{" }
    local contentParts = {}
    local scratch = {}

    for index, key in ipairs(keys) do
        if index > 1 then
            pieces[#pieces + 1] = ","
        end

        local encodedKey = config.encodeJSONString(key)

        if key == "childs" then
            pieces[#pieces + 1] = encodedKey .. ":["
            for childIndex = 1, frame.childCount do
                if childIndex > 1 then
                    pieces[#pieces + 1] = ","
                end
                -- Nested rope link: the child's own piece list, shared by reference.
                pieces[#pieces + 1] = frame.childPieces[childIndex]
            end
            pieces[#pieces + 1] = "]"
        elseif key == "elementCount" then
            pieces[#pieces + 1] = encodedKey .. ":" .. string.format("%.17g", frame.elementCount)
        else
            local ok, err = config.encodeStableValueInto(own[key], scratch, {})
            if not ok then
                return nil, tostring(err)
            end

            local pair = encodedKey .. ":" .. table.concat(scratch)
            for i = #scratch, 1, -1 do
                scratch[i] = nil
            end

            pieces[#pieces + 1] = pair
            if not VOLATILE_KEYS[key] and not (hashSkipKeys and hashSkipKeys[key]) then
                contentParts[#contentParts + 1] = pair
            end
        end
    end

    pieces[#pieces + 1] = "}"

    local contentHash = hashString(
        table.concat(contentParts, ",") .. "|" .. table.concat(frame.childHashes, ",")
    )

    return pieces, contentHash
end

---@param node element
---@return table frame
local function newFrame(node)
    return {
        node = node,
        state = "enter",
        childIndex = 0,
        childCount = 0,
        childPieces = {},
        childHashes = {},
        elementCount = 0
    }
end

---Hands a finished subtree result to the parent frame, or to the job when the stack empties.
---@param job table
---@param pieces table
---@param elementCount integer
---@param contentHash string
---@param kind integer
local function completeFrame(job, pieces, elementCount, contentHash, kind)
    table.remove(job.stack)
    local parent = job.stack[#job.stack]

    if not parent then
        job.result = { pieces = pieces, elementCount = elementCount, contentHash = contentHash }
        job.done = true
        return
    end

    local index = parent.childIndex
    parent.childPieces[index] = pieces
    parent.childHashes[index] = contentHash

    -- Replicates element:serialize's counting exactly, quirks included: only strictly-identified
    -- spawnables and groups contribute, so a scatteredGroup (absent from isSerializedGroupStrict)
    -- adds nothing -- same as the file this has to stay byte-identical to.
    if kind == NODE_KIND_SPAWNABLE then
        parent.elementCount = parent.elementCount + 1
    elseif kind == NODE_KIND_GROUP then
        parent.elementCount = parent.elementCount + elementCount
    end
end

---@param job table
---@param reason string
local function abortJob(job, reason)
    job.aborted = reason
    job.done = true
    job.stack = {}
end

---Starts a resumable build of a subtree's canonical JSON.
---@param root element
---@param options {ignoreCache: boolean?, extraRootFields: table<string, any>?}?
---@return table job
function saveState.beginBuild(root, options)
    options = options or {}

    return {
        root = root,
        stack = { newFrame(root) },
        done = false,
        aborted = nil,
        result = nil,
        nodesVisited = 0,
        ignoreCache = options.ignoreCache or false,
        -- Extra top-level fields merged into the root object only, e.g. `lastEditedAt`. Kept out of
        -- the content hash (a fresh timestamp is not a content change) and out of the root's cache
        -- entry, so the next build re-emits them. Child ropes stay cached.
        extraRootFields = options.extraRootFields
    }
end

---Advances a build for at most `budgetMs` of wall clock.
---@param job table
---@param budgetMs number? Omit or pass <= 0 to run to completion.
---@return string status `"running"`, `"done"`, or `"aborted"`
function saveState.stepBuild(job, budgetMs)
    if job.done then
        return job.aborted and "aborted" or "done"
    end

    local useCache = saveState.cacheEnabled and not job.ignoreCache
    local deadline = (budgetMs and budgetMs > 0) and (os.clock() + budgetMs / 1000) or nil

    while #job.stack > 0 do
        local frame = job.stack[#job.stack]
        local node = frame.node

        if frame.state == "enter" then
            local cache = node.__jsonCache

            if useCache and cache and cache.valid then
                saveState.stats.reused = saveState.stats.reused + 1
                completeFrame(job, cache.pieces, cache.elementCount, cache.contentHash, cache.kind)
            else
                frame.childCount = #node.childs
                frame.guardCount = frame.childCount
                frame.guardFirst = node.childs[1]
                frame.guardLast = node.childs[frame.childCount]
                frame.state = "children"
            end
        elseif frame.state == "children" then
            -- Structural guard. Unlike the mutation hooks this needs no cooperation from the rest of
            -- the codebase: it catches the only mutation class that can actually corrupt the output,
            -- namely children appearing or disappearing while we walk them.
            if #node.childs ~= frame.guardCount
                or node.childs[1] ~= frame.guardFirst
                or node.childs[frame.guardCount] ~= frame.guardLast then
                abortJob(job, "structure_changed")
                return "aborted"
            end

            if frame.childIndex < frame.childCount then
                frame.childIndex = frame.childIndex + 1
                job.stack[#job.stack + 1] = newFrame(node.childs[frame.childIndex])
            else
                frame.state = "emit"
            end
        else
            -- Serialize bottom-up: positionable:serialize reads getPosition(), which walks the
            -- subtree for auto-centered groups. Top-down that would be a full-tree walk in one
            -- frame; bottom-up every descendant is already cached, so each step is O(children).
            -- Manual-origin groups never call getWorldMinMax themselves, so warm them explicitly.
            if node.getWorldMinMax and not node.autoCenterCacheValid then
                pcall(node.getWorldMinMax, node)
            end

            local serializeOk, own = pcall(node.serialize, node, BUILD_CTX)
            if not serializeOk or type(own) ~= "table" then
                abortJob(job, "serialize_failed:" .. tostring(own))
                return "aborted"
            end

            -- serialize(shallow) does not set these; clearing them anyway keeps key ordering correct
            -- even if a future override starts populating them.
            own.childs = nil
            own.elementCount = nil
            frame.own = own

            -- The root frame is the last one left on the stack.
            local isRootFrame = #job.stack == 1
            local hashSkipKeys = nil

            if isRootFrame and job.extraRootFields then
                hashSkipKeys = {}
                for key, value in pairs(job.extraRootFields) do
                    own[key] = value
                    hashSkipKeys[key] = true
                end
            end

            local pieces, contentHashOrErr = emitNode(frame, hashSkipKeys)
            if not pieces then
                abortJob(job, "encode_failed:" .. tostring(contentHashOrErr))
                return "aborted"
            end

            local kind = NODE_KIND_OTHER
            if utils.isSerializedSpawnableStrict(frame.own) then
                kind = NODE_KIND_SPAWNABLE
            elseif utils.isSerializedGroupStrict(frame.own) then
                kind = NODE_KIND_GROUP
            end

            if hashSkipKeys then
                -- This node's bytes carry injected fields (a fresh timestamp), so caching them would
                -- make the next build write a stale value. Only ever the root node, so re-emitting it
                -- next time costs one node.
                node.__jsonCache = nil
            else
                node.__jsonCache = {
                    valid = true,
                    pieces = pieces,
                    elementCount = frame.elementCount,
                    contentHash = contentHashOrErr,
                    kind = kind
                }
            end

            saveState.stats.built = saveState.stats.built + 1
            job.nodesVisited = job.nodesVisited + 1

            completeFrame(job, pieces, frame.elementCount, contentHashOrErr, kind)
        end

        if job.done then
            return job.aborted and "aborted" or "done"
        end

        if deadline and os.clock() >= deadline then
            return "running"
        end
    end

    -- Stack drained without completing: only reachable if the root frame was popped, which sets done.
    job.done = true
    return "done"
end

---Builds a subtree in one go. Used for manual saves and reference/verification builds, where a pause
---is acceptable and a guaranteed-complete result matters more than frame time.
---@param root element
---@param options {ignoreCache: boolean?, extraRootFields: table<string, any>?}?
---@return table? result `{ pieces, elementCount, contentHash }`
---@return string? err
function saveState.buildSync(root, options)
    local job = saveState.beginBuild(root, options)
    local status = saveState.stepBuild(job, nil)

    if status ~= "done" or not job.result then
        return nil, job.aborted or "incomplete"
    end

    return job.result
end

--------------------------------------------------------------------------------------------------
-- Rope traversal
--------------------------------------------------------------------------------------------------

---Creates a resumable iterator over a rope, yielding leaf strings in document order.
---Lets the writer stream a multi-megabyte document into a file across frames without ever
---concatenating it in memory.
---@param pieces table Root piece list from a build result.
---@return fun(): string? next Returns the next fragment, or `nil` when exhausted.
function saveState.ropeIterator(pieces)
    local stack = { { list = pieces, index = 0 } }

    return function()
        while #stack > 0 do
            local frame = stack[#stack]
            frame.index = frame.index + 1

            local entry = frame.list[frame.index]
            if entry == nil then
                table.remove(stack)
            elseif type(entry) == "table" then
                stack[#stack + 1] = { list = entry, index = 0 }
            else
                return entry
            end
        end

        return nil
    end
end

--------------------------------------------------------------------------------------------------
-- Verification
--------------------------------------------------------------------------------------------------

---Compares a rope against a string without ever concatenating the rope.
---
---Materialising it would mean holding a second full copy of the document just to compare it, which
---for a large project is tens of megabytes of pure waste.
---@param pieces table
---@param expected string
---@return boolean equal
---@return integer offset 1-based position of the first difference, or 0 when equal.
local function ropeMatches(pieces, expected)
    local offset = 1

    for fragment in saveState.ropeIterator(pieces) do
        local length = #fragment

        if expected:sub(offset, offset + length - 1) ~= fragment then
            return false, offset
        end

        offset = offset + length
    end

    if offset ~= #expected + 1 then
        return false, offset
    end

    return true, 0
end

---Checks the two things that could silently corrupt a saved project.
---
---1. **Encoder drift.** A cache-free build must be byte-identical to what `config.saveFile` would have
---   written for the same tree. If the two encoders ever disagree, a manual save and an auto-save of
---   unchanged data would each see the other's output as a change and rewrite the file forever.
---2. **Stale cache.** The build using existing caches must match the cache-free one. A mismatch means
---   a mutation slipped past every hook, which is the one failure mode that writes *wrong* data rather
---   than merely late data.
---
---Order matters: the cached build runs first, while the caches under test are still the ones the
---editor built up. The cache-free build then overwrites them, which also repairs the damage.
---@param root element
---@return boolean ok
---@return string detail
function saveState.verify(root)
    local cached, cachedErr = saveState.buildSync(root)
    if not cached then
        return false, "cached build failed: " .. tostring(cachedErr)
    end

    local reference, referenceErr = config.encodeStableJSON(root:serialize())
    if not reference then
        return false, "reference encode failed: " .. tostring(referenceErr)
    end

    -- One comparison covers both failure modes at once: if the cached build already matches what
    -- config.saveFile would write, the encoder agrees *and* no mutation was missed.
    local matches, offset = ropeMatches(cached.pieces, reference)
    if matches then
        return true, string.format("%d bytes, %d nodes, hash %s",
            #reference, cached.elementCount, cached.contentHash)
    end

    -- Something is wrong. Work out which of the two it is -- this costs a second full build, but it
    -- only runs when there is a genuine fault, and it repairs the caches on its way through.
    local fresh = saveState.buildSync(root, { ignoreCache = true })

    if fresh and ropeMatches(fresh.pieces, reference) then
        return false, string.format(
            "stale cache: a mutation was missed. Cached output diverges at byte %d; caches have been rebuilt",
            offset)
    end

    return false, string.format(
        "encoder mismatch: incremental output diverges from config.saveFile's at byte %d", offset)
end

return saveState
