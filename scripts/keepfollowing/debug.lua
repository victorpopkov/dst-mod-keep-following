----
-- Debugging.
--
-- Includes different debugging-related stuff.
--
-- **Source Code:** [https://github.com/victorpopkov/dst-mod-keep-following](https://github.com/victorpopkov/dst-mod-keep-following)
--
-- @classmod Debug
--
-- @author Victor Popkov
-- @copyright 2019
-- @license MIT
-- @release 0.21.0
----
require "class"

--- Constructor.
-- @function _ctor
-- @tparam string modname Mod name
-- @usage local debug = Debug(modname)
local Debug = Class(function(self, modname)
    self:DoInit(modname)
end)

--- General
-- @section general

--- Checks if debugging is enabled.
-- @treturn boolean
function Debug:IsEnabled()
    return self.is_enabled
end

--- Sets debugging state.
-- @tparam boolean enable
function Debug:SetIsEnabled(enable)
    self.is_enabled = enable
end

--- Enables debugging.
function Debug:Enable()
    self.is_enabled = true
end

--- Disables debugging.
function Debug:Disable()
    self.is_enabled = false
end

--- Checks if named debugging is enabled.
-- @tparam string name
-- @treturn boolean
function Debug:IsDebug(name)
    return self.is_debug[name] and true or false
end

--- Adds named debugging state.
-- @tparam string name
-- @tparam boolean enable
function Debug:SetIsDebug(name, enable)
    enable = enable and true or false
    self.is_debug[name] = enable
end

--- Prints
-- @section prints

--- Prints the provided strings.
-- @tparam string ... Strings
function Debug:DebugString(...) -- luacheck: only
    if self.is_enabled then
        local task = scheduler:GetCurrentTask()
        local msg = string.format("[%s]", self.modname)

        if task then
            msg = msg .. " [" .. task.id .. "]"
        end

        for i = 1, arg.n do
            msg = msg .. " " .. tostring(arg[i])
        end

        print(msg)
    end
end

--- Prints the provided strings.
--
-- Unlike the `DebugString` it also starts the timer which later can be stopped using the
-- corresponding `DebugStringStop` method.
--
-- @tparam string ... Strings
function Debug:DebugStringStart(...)
    self.start_time = os.clock()
    self:DebugString(...)
end

--- Prints the provided strings.
--
-- Stops the timer started earlier by the `DebugStringStart` method and prints the provided strings
-- alongside with the time.
--
-- @tparam string ... Strings
function Debug:DebugStringStop(...)
    if self.start_time then
        local arg = { ... }
        local last = string.gsub(arg[#arg], "%.$", "") .. "."
        arg[#arg] = last
        table.insert(arg, string.format("Time: %0.4f", os.clock() - self.start_time))
        self:DebugString(unpack(arg))
        self.start_time = nil
    else
        self:DebugString(...)
    end
end

--- Prints an initialized method name.
-- @tparam string name Method name
function Debug:DebugInit(name)
    self:DebugString("[life_cycle]", "Initialized", name)
end

--- Prints an initialized method name.
-- @tparam string name Method name
function Debug:DebugTerm(name)
    self:DebugString("[life_cycle]", "Terminated", name)
end

--- Prints an error strings.
--
-- Acts just like the `DebugString` but also prepends the "[error]" string.
--
-- @tparam string ... Strings
function Debug:DebugError(...)
    self:DebugString("[error]", ...)
end

--- Prints all mod configurations.
--
-- Should be used to debug mod configurations.
function Debug:DebugModConfigs()
    local config = KnownModIndex:GetModConfigurationOptions_Internal(self.modname, false)
    if config and type(config) == "table" then
        for _, v in pairs(config) do
            if v.name == "" then
                self:DebugString("[config]", "[section]", v.label)
            else
                self:DebugString(
                    "[config]",
                    v.label .. ":",
                    v.saved == nil and v.default or v.saved
                )
            end
        end
    end
end

--- Initialization
-- @section initialization

--- Initializes.
--
-- Sets empty fields and adds debug functions.
--
-- @tparam string modname
function Debug:DoInit(modname)
    -- general
    self.is_debug = {}
    self.is_enabled = false
    self.modname = modname
    self.name = "Debug"
    self.start_time = nil

    -- other
    self:DebugInit(self.name)
end

return Debug
