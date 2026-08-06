local Cron = require("modules/utils/vendor/Cron")

---Simple task runner that executes a queue either:
---1. In parallel (all tasks started immediately), or
---2. Sequentially (next task starts when `taskCompleted()` is called), or
---3. With bounded concurrency (`runConcurrent`).
---
---Each queued task is expected to call `taskCompleted()` exactly once when its work is done.
---`onFinalize()` should be registered before the queue can finish.
---@class tasks
---@field tasksTodo integer Remaining completion count before finalize callback is fired.
---@field tasks fun()[]
---@field finalizeCallback fun()?
---@field synchronous boolean
---@field taskDelay number Delay in seconds before starting the next task in synchronous mode.
---@field concurrencyLimit integer? Maximum active tasks when using bounded concurrency.
---@field activeTasks integer Number of currently active bounded-concurrency tasks.
---@field nextTaskIndex integer Index of the next bounded-concurrency task to start.
local tasks = {}

---Creates a new task runner instance.
---The returned object starts empty and is configured for parallel mode with no delay.
---@return tasks
function tasks:new()
	local o = {}

    o.tasksTodo = 0
    o.tasks = {}
    o.finalizeCallback = nil
    o.synchronous = false
    o.taskDelay = 0
    o.concurrencyLimit = nil
    o.activeTasks = 0
    o.nextTaskIndex = 1

    self.__index = self
   	return setmetatable(o, self)
end

---Adds a task to this runner.
---The callback receives no arguments and should call `self:taskCompleted()` once finished.
---This increments `tasksTodo` by one.
---@param task fun() Task callback to execute when the queue runs.
function tasks:addTask(task)
    self.tasks[#self.tasks + 1] = task
    self.tasksTodo = self.tasksTodo + 1
end

---Starts queued tasks until the configured bounded-concurrency limit is reached.
---@private
function tasks:fillConcurrentSlots()
    while self.concurrencyLimit
        and self.activeTasks < self.concurrencyLimit
        and self.nextTaskIndex <= #self.tasks do
        local taskIndex = self.nextTaskIndex
        self.nextTaskIndex = self.nextTaskIndex + 1
        self.activeTasks = self.activeTasks + 1
        self.tasks[taskIndex]()
    end
end

---Marks one queued task as complete.
---In synchronous mode, this starts the next task (optionally after `taskDelay`).
---When all tasks are completed (`tasksTodo == 0`), the finalize callback is invoked.
function tasks:taskCompleted()
    self.tasksTodo = self.tasksTodo - 1

    if self.concurrencyLimit then
        self.activeTasks = math.max(self.activeTasks - 1, 0)
    end

    if self.tasksTodo == 0 then
        self.finalizeCallback()
        return
    end

    if self.concurrencyLimit then
        self:fillConcurrentSlots()
        return
    end

    if not self.synchronous then return end
    if #self.tasks <= 1 then return end

    table.remove(self.tasks, 1)
    if self.taskDelay > 0 then
        Cron.After(self.taskDelay, function ()
            self.tasks[1]()
        end)
    else
        self.tasks[1]()
    end
end

---Runs queued tasks.
---If `synchronous` is truthy, tasks execute one-by-one and each task must call
---`taskCompleted()` to allow the next task to start.
---If `synchronous` is falsy/nil, all tasks are started immediately.
---When no tasks are queued, finalize callback is called immediately.
---@param synchronous boolean? `true` for sequential execution, `false`/`nil` for parallel start.
function tasks:run(synchronous)
    self.synchronous = synchronous
    self.concurrencyLimit = nil

    if #self.tasks == 0 then
        self.finalizeCallback()
        return
    end

    if not self.synchronous then
        for _, task in ipairs(self.tasks) do
            task()
        end
    else
        self.tasks[1]()
    end
end

---Runs queued tasks with a bounded number active at once.
---Synchronous completions are supported: newly freed slots are filled immediately.
---@param limit integer Maximum number of active tasks. Values below one are clamped to one.
function tasks:runConcurrent(limit)
    self.synchronous = false
    self.concurrencyLimit = math.max(1, math.floor(tonumber(limit) or 1))
    self.activeTasks = 0
    self.nextTaskIndex = 1

    if #self.tasks == 0 then
        self.finalizeCallback()
        return
    end

    self:fillConcurrentSlots()
end

---Registers the callback invoked once all queued tasks have completed.
---Set this before `run()` (or before completion can occur), otherwise finalization may fail.
---@param callback fun() Callback executed when `tasksTodo` reaches zero.
function tasks:onFinalize(callback)
    self.finalizeCallback = callback
end

return tasks
