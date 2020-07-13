----
-- Component `keepfollowing`.
--
-- Includes following and pushing features/functionality.
--
-- @classmod KeepFollowing
-- @author Victor Popkov
-- @copyright 2019
-- @license MIT
----
local Utils = require "keepfollowing/utils"

local _FOLLOWING_PATH_THREAD_ID = "following_path_thread"
local _FOLLOWING_THREAD_ID = "following_thread"
local _PUSHING_THREAD_ID = "pushing_thread"
local _TENT_FIND_INVISIBLE_PLAYER_RANGE = 50

-- A list of actions that will cause the following thread to pause. The first value represents an
-- action itself and the second (optional) is a sleep time (default: 1.25).
local _PAUSE_ACTIONS = {
    { ACTIONS.ADDFUEL, .5 },
    { ACTIONS.ADDWETFUEL, .5 },
    { ACTIONS.BLINK },
    { ACTIONS.BUILD },
    { ACTIONS.DROP, .5 },
    { ACTIONS.EAT, 1 },
    { ACTIONS.EQUIP, .25 },
    { ACTIONS.HEAL },
    { ACTIONS.LOOKAT, .25 },
    { ACTIONS.READ, 2 },
    { ACTIONS.TEACH },
    { ACTIONS.USEITEM },
}

local KeepFollowing = Class(function(self, inst)
    self:DoInit(inst)
end)

--
-- Helpers
--

local function IsOnPlatform(world, inst)
    if Utils.ChainValidate(world, "Map", "GetPlatformAtPoint")
        and Utils.ChainValidate(inst, "GetPosition")
    then
        return world.Map:GetPlatformAtPoint(Utils.ChainGet(inst:GetPosition(), "Get", true))
            and true
            or false
    end
end

local function IsHUDFocused(player)
    return not Utils.ChainGet(player, "HUD", "HasInputFocus", true)
end

local function IsPassable(world, pos)
    return Utils.ChainValidate(world, "Map", "IsPassableAtPoint")
        and Utils.ChainValidate(pos, "Get")
        and world.Map:IsPassableAtPoint(pos:Get())
        or false
end

local function GetClosestPosition(entity1, entity2)
    local distance = entity1.Physics:GetRadius() + entity2.Physics:GetRadius()
    return entity1:GetPositionAdjacentTo(entity2, distance)
end

local function GetDistSq(x1, y1, z1, x2, y2, z2)
    local dx = x2 - x1
    local dy = y2 - y1
    local dz = z2 - z1
    return dx * dx + dy * dy + dz * dz
end

local function GetDistSqBetweenPositions(p1, p2)
    return GetDistSq(p1.x, p1.y, p1.z, p2.x, p2.y, p2.z)
end

local function GetDistBetweenPositions(p1, p2)
    return math.sqrt(GetDistSqBetweenPositions(p1, p2))
end

local function GetPauseAction(action)
    for _, v in ipairs(_PAUSE_ACTIONS) do
        if v[1] == action then
            if v[2] then
                return v[1], v[2]
            end

            return v[1], 1.25 -- 1.25 is the most optimal so far as a default value
        end
    end

    return nil
end

local function ThreadInterruptOnPauseAction(self, previousbuffered)
    local pauseaction, pauseactiontime

    local buffered = self.inst:GetBufferedAction()

    if buffered and buffered.action ~= ACTIONS.WALKTO then
        if not previousbuffered or buffered ~= previousbuffered then
            self:DebugString("Interrupted by action:", buffered.action.id)
            previousbuffered = buffered
            pauseaction, pauseactiontime = GetPauseAction(buffered.action)
            if pauseaction then
                self.ispaused = true
                self:DebugString(string.format("Pausing (%2.2f)...", pauseactiontime))
                Sleep(FRAMES / FRAMES * pauseactiontime)
            end
        end
    elseif not self:IsMovementPrediction() then
        if not self.inst:HasTag("ignorewalkableplatforms")
            and (self.playercontroller:IsBusy() or self.inst.replica.builder:IsBusy())
            and not self.inst.replica.inventory:GetActiveItem()
        then
            self.ispaused = true
            pauseactiontime = 1.25 -- default
            self:DebugString(string.format("Pausing (%2.2f)...", pauseactiontime))
            Sleep(FRAMES / FRAMES * pauseactiontime)
        end
    end

    if self.ispaused then
        self:DebugString("Unpausing...")
        self.ispaused = false
        return previousbuffered, true
    end

    return previousbuffered, false
end

local function WalkToPosition(self, pos)
    if self.ismastersim or self.playercontroller.locomotor then
        self.playercontroller:DoAction(BufferedAction(self.inst, nil, ACTIONS.WALKTO, nil, pos))
    else
        SendRPCToServer(RPC.LeftClick, ACTIONS.WALKTO.code, pos.x, pos.z)
    end

    if _G.KeepFollowingDebug then
        self.debugrequests = self.debugrequests + 1
    end
end

--
-- General
--

--- Checks if the player is on the platform.
-- @treturn boolean
function KeepFollowing:IsOnPlatform()
    return IsOnPlatform(self.world, self.inst)
end

function KeepFollowing:Stop()
    if IsHUDFocused(self.inst) then
        if self:IsFollowing() then
            self:StopFollowing()
        end

        if self:IsPushing() then
            self:StopPushing()
        end
    end
end

--
-- Movement prediction
--

local function MovementPrediction(inst, enable)
    if enable then
        local x, _, z = inst.Transform:GetWorldPosition()
        SendRPCToServer(RPC.LeftClick, ACTIONS.WALKTO.code, x, z)
        inst:EnableMovementPrediction(true)
        return true
    elseif inst.components and inst.components.locomotor then
        inst.components.locomotor:Stop()
        inst:EnableMovementPrediction(false)
        return false
    end
end

local function MovementPredictionOnPush(self)
    self:DebugString("Checking movement prediction current state...")
    local state = self:IsMovementPrediction()
    self:DebugString("Current state:", state and "enabled" or "disabled")

    if self.movementpredictionstate == nil then
        self:DebugString("Setting movement prediction previous state...")
        self.movementpredictionstate = state
        self:DebugString("Previous state:", state and "enabled" or "disabled")
    end

    if self.movementpredictionstate then
        self:MovementPrediction(false)
    end
end

local function MovementPredictionOnFollow(self)
    local state = self.movementpredictionstate
    if state ~= nil then
        self:MovementPrediction(state)
        self.movementpredictionstate = nil
    end
end

local function MovementPredictionOnStop(self)
    self:MovementPrediction(self.movementpredictionstate)
    self.movementpredictionstate = nil
end

--- Checks if the movement prediction is enabled.
-- @treturn boolean
function KeepFollowing:IsMovementPrediction()
    return Utils.ChainGet(self, "inst", "components", "locomotor") ~= nil
end

--- Enables/Disables the movement prediction.
-- @tparam boolean enable
-- @treturn boolean
function KeepFollowing:MovementPrediction(enable)
    local is_enabled = MovementPrediction(self.inst, enable)
    self:DebugString("Movement prediction:", is_enabled and "enabled" or "disabled")
    return is_enabled
end

--
-- Leader
--

--- Gets the leader.
-- @treturn EntityScript
function KeepFollowing:GetLeader()
    return self.leader
end

--- Checks if a leader is on the platform.
-- @treturn boolean
function KeepFollowing:IsLeaderOnPlatform()
    return IsOnPlatform(self.world, self.leader)
end

--- Checks if a leader can be followed.
--
-- Checks whether an entity is valid and has either a `locomotor` or `balloon` tag.
--
-- @tparam EntityScript entity An entity as a potential leader to follow
-- @treturn boolean
function KeepFollowing:CanBeFollowed(entity) -- luacheck: only
    return Utils.ChainGet(entity, "entity", "IsValid", true)
        and (entity:HasTag("locomotor") or entity:HasTag("balloon"))
        or false
end

--- Checks if a leader can be pushed.
-- @tparam EntityScript entity An entity as a potential leader to push
-- @treturn boolean
function KeepFollowing:CanBePushed(entity)
    if not self.inst or not entity or not entity.Physics then
        return false
    end

    -- Ghosts should be able to push other players and ignore the mass difference checking. The
    -- point is to provide light.
    if self.inst:HasTag("playerghost") and entity:HasTag("player") then
        return true
    end

    local collision_group = Utils.ChainGet(entity, "Physics", "GetCollisionGroup", true)
    if collision_group == COLLISION.FLYERS -- different flyers don't collide with characters
        or collision_group == COLLISION.SANITY -- Shadow Creatures also don't collide
        or entity:HasTag("bird") -- so does birds
    then
        return false
    end

    if not self.config.push_mass_checking then
        return true
    end

    -- Mass is the key factor for pushing. For example, players have a mass of 75 while most bosses
    -- have a mass of 1000. Some entities just act as "unpushable" like Moleworm (99999) and
    -- Gigantic Beehive (999999). However, if Klei's physics is correct then even those entities can
    -- be pushed but it will take an insane amount of time...
    --
    -- So far the only entities with a high mass that still can be useful to be pushed are bosses
    -- like Bearger or Toadstool. They both have a mass of 1000 which makes a perfect ceil value for
    -- us to disable pushing.
    local entity_mass = entity.Physics:GetMass()
    local inst_mass = self.inst.Physics:GetMass()
    local mass_diff = math.abs(entity_mass - inst_mass)

    -- 925 = 1000 (boss) - 75 (player)
    if mass_diff > 925 then
        return false
    end

    -- When the player becomes a ghost his mass becomes 1. In that case, we just set the ceil
    -- difference to 10 (there is no point to push something with a mass higher than that) to allow
    -- pushing Frogs, Saladmanders and Critters as they all have a mass of 1.
    if inst_mass == 1 and mass_diff > 10 then
        return false
    end

    return true
end

--- Checks if an entity can be a leader.
-- @tparam EntityScript entity An entity as a potential leader
-- @treturn boolean
function KeepFollowing:CanBeLeader(entity)
    return entity ~= self.inst and self:CanBeFollowed(entity) or false
end

function KeepFollowing:SetLeader(entity)
    if self:CanBeLeader(entity) then
        self.leader = entity
        self:DebugString(string.format(
            "New leader: %s. Distance: %0.2f",
            self.leader:GetDisplayName(),
            math.sqrt(self.inst:GetDistanceSqToPoint(self.leader:GetPosition()))
        ))
    end
end

--
-- Tent
--

local function FindClosestInvisiblePlayerInRange(x, y, z, range)
    local closestPlayer
    local rangesq = range * range

    for _, v in ipairs(AllPlayers) do
        if not v.entity:IsVisible() then
            local distsq = v:GetDistanceSqToPoint(x, y, z)
            if distsq < rangesq then
                rangesq = distsq
                closestPlayer = v
            end
        end
    end

    return closestPlayer, closestPlayer ~= nil and rangesq or nil
end

function KeepFollowing:GetTentSleeper(entity)
    local player

    if not entity:HasTag("tent") or not entity:HasTag("hassleeper") then
        return nil
    end

    self:DebugString("Attempting to get a", entity:GetDisplayName(), "sleeper...")

    if entity.components.sleepingbag and entity.components.sleepingbag.sleeper then
        player = entity.components.sleepingbag.sleeper
    else
        local x, y, z = entity.Transform:GetWorldPosition()
        player = FindClosestInvisiblePlayerInRange(x, y, z, _TENT_FIND_INVISIBLE_PLAYER_RANGE)
        self:DebugString(
            "Component sleepingbag is not available, looking for sleeping players nearby..."
        )
    end

    if player and player:HasTag("sleeping") then
        self:DebugString("Found sleeping", player:GetDisplayName())
        return player
    end

    return nil
end

--
-- Following
--

local function GetDefaultMethodNextPosition(self, target)
    local pos = self.leaderpositions[1]

    if pos then
        local distinstsq = self.inst:GetDistanceSqToPoint(pos)
        local distinst = math.sqrt(distinstsq)

        -- This represents the distance where the gathered points (leaderpositions) will be
        -- ignored/removed. There is no real point to step on each coordinate and we still need to
        -- remove the past ones. Smaller value gives more precision, especially near the corners.
        -- However, when lag compensation is off the movement becomes less smooth. I don't recommend
        -- using anything < 1 diameter.
        local step = self.inst.Physics:GetRadius() * 3
        local isleadernear = self.inst:IsNear(self.leader, target + step)

        if not self.isleadernear
            and isleadernear
            or (isleadernear and self.config.keep_target_distance)
        then
            self.leaderpositions = {}
            return self.inst:GetPositionAdjacentTo(self.leader, target)
        end

        if not isleadernear and distinst > step then
            return pos
        else
            table.remove(self.leaderpositions, 1)
            pos = GetDefaultMethodNextPosition(self, target)
            return pos
        end
    end

    return nil
end

local function GetClosestMethodNextPosition(self, target, isleadernear)
    if not isleadernear or self.config.keep_target_distance then
        local pos = self.inst:GetPositionAdjacentTo(self.leader, target)

        if IsPassable(self.world, pos) then
            return pos
        end

        if self:IsLeaderOnPlatform() ~= self:IsOnPlatform() then
            pos = GetClosestPosition(self.inst, self.leader)
        end

        return pos
    end

    return nil
end

--- Gets the following state.
-- @treturn boolean
function KeepFollowing:IsFollowing()
    return self.leader and self.isfollowing
end

--- Starts the following thread.
--
-- Starts the thread to follow the leader based on the chosen method in the configurations. When the
-- "default" following method is used it starts the following path thread as well by calling the
-- `StartFollowingPathThread` to gather path coordinates of a leader.
function KeepFollowing:StartFollowingThread()
    local buffered, buffered_prev, interrupted, pos, pos_prev, is_leader_near, stuck

    local stuck_frames = 0
    local radius_inst = self.inst.Physics:GetRadius()
    local radius_leader = self.leader.Physics:GetRadius()
    local target = self.config.target_distance + radius_inst + radius_leader

    self.followingthread = Utils.ThreadStart(_FOLLOWING_THREAD_ID, function()
        if not self.leader or not self.leader.entity:IsValid() then
            self:DebugString("Leader doesn't exist anymore")
            self:StopFollowing()
            return
        end

        buffered = self.inst:GetBufferedAction()
        is_leader_near = self.inst:IsNear(self.leader, target)

        if self.config.following_method == "default" then
            -- default: player follows a leader step-by-step
            pos = GetDefaultMethodNextPosition(self, target)
            if pos then
                buffered_prev, interrupted = ThreadInterruptOnPauseAction(self, buffered_prev)

                if interrupted or (not buffered and self:IsMovementPrediction()) then
                    WalkToPosition(self, pos)
                    pos_prev = pos
                end

                if not self.ispaused then
                    if not pos_prev or pos ~= pos_prev then
                        WalkToPosition(self, pos)
                        pos_prev = pos
                        stuck = false
                        stuck_frames = 0
                    elseif not stuck and pos == pos_prev then
                        stuck_frames = stuck_frames + 1
                        if stuck_frames * FRAMES > .5 then
                            pos_prev = pos
                            stuck = true
                        end
                    elseif stuck and pos == pos_prev and #self.leaderpositions > 1 then
                        table.remove(self.leaderpositions, 1)
                    end
                end
            end
        elseif self.config.following_method == "closest" then
            -- closest: player goes to the closest target point from a leader
            pos = GetClosestMethodNextPosition(self, target, is_leader_near)
            if pos then
                buffered_prev, interrupted = ThreadInterruptOnPauseAction(self, buffered_prev)

                if interrupted then
                    WalkToPosition(self, pos)
                end

                if not self.ispaused
                    and (not pos_prev or GetDistSqBetweenPositions(pos, pos_prev) > .1)
                then
                    WalkToPosition(self, pos)
                    pos_prev = pos
                end
            end
        end

        self.isleadernear = is_leader_near

        Sleep(FRAMES)
    end, function()
        return self.inst and self.inst:IsValid() and self:IsFollowing()
    end, function()
        self.isfollowing = true
        self.starttime = os.clock()

        if self.config.following_method == "default" then
            self:StartFollowingPathThread()
        end
    end, function()
        self.isfollowing = false
        self.starttime = nil
        self:ClearFollowingPathThread()
    end)
end

--- Stops the following thread.
--
-- Stops the thread started earlier by the `StartFollowingThread`.
function KeepFollowing:ClearFollowingThread()
    return Utils.ThreadClear(self.followingthread)
end

--- Starts the following path thread.
--
-- Starts the thread to follow the leader based on the following method in the configurations.
function KeepFollowing:StartFollowingPathThread()
    local pos, pos_prev

    self.followingpaththread = Utils.ThreadStart(_FOLLOWING_PATH_THREAD_ID, function()
        if not self.leader or not self.leader.entity:IsValid() then
            self:DebugString("Leader doesn't exist anymore")
            self:StopFollowing()
            return
        end

        pos = self.leader:GetPosition()

        if self:IsLeaderOnPlatform() ~= self:IsOnPlatform() then
            pos = GetClosestPosition(self.inst, self.leader)
        end

        if not pos_prev then
            table.insert(self.leaderpositions, pos)
            pos_prev = pos
        end

        if IsPassable(self.world, pos) == IsPassable(self.world, pos_prev) then
            -- 1 is the most optimal value so far
            if GetDistBetweenPositions(pos, pos_prev) > 1
                and pos ~= pos_prev
                and self.leaderpositions[#self.leaderpositions] ~= pos
            then
                table.insert(self.leaderpositions, pos)
                pos_prev = pos
            end
        end

        Sleep(FRAMES)
    end, function()
        return self.inst and self.inst:IsValid() and self:IsFollowing()
    end, function()
        self:DebugString("Started gathering path coordinates...")
    end)
end

--- Stops the following path thread.
--
-- Stops the thread started earlier by the `StartFollowingPathThread`.
function KeepFollowing:ClearFollowingPathThread()
    return Utils.ThreadClear(self.followingpaththread)
end

function KeepFollowing:StartFollowing(leader)
    if self.config.push_lag_compensation and not self.ismastersim then
        MovementPredictionOnFollow(self)
    end

    self:SetLeader(leader)
    self:DebugString(string.format("Started following %s...", self.leader:GetDisplayName()))
    self:StartFollowingThread()
end

function KeepFollowing:StopFollowing()
    if self.leader then
        self:DebugString(string.format(
            "Stopped following %s. Requests: %d. Time: %2.4f",
            self.leader:GetDisplayName(),
            self.debugrequests,
            os.clock() - self.starttime
        ))

        self.debugrequests = 0
        self.isfollowing = false
        self.leader = nil
        self.leaderpositions = {}
        self.starttime = nil
        self:ClearFollowingPathThread()
        self:ClearFollowingThread()
    end
end

--
-- Pushing
--

--- Gets the pushing state.
-- @treturn boolean
function KeepFollowing:IsPushing()
    return self.leader and self.ispushing
end

--- Starts the pushing thread.
--
-- Starts the thread to push the leader.
function KeepFollowing:StartPushingThread()
    local buffered, buffered_prev, interrupted, pos

    self.followingthread = Utils.ThreadStart(_PUSHING_THREAD_ID, function()
        if not self.leader or not self.leader.entity:IsValid() then
            self:DebugString("Leader doesn't exist anymore")
            self:StopPushing()
            return
        end

        buffered = self.inst:GetBufferedAction()
        pos = self.leader:GetPosition()

        buffered_prev, interrupted = ThreadInterruptOnPauseAction(self, buffered_prev)
        if interrupted or (not buffered and self:IsMovementPrediction()) then
            WalkToPosition(self, pos)
        end

        WalkToPosition(self, pos)

        Sleep(FRAMES)
    end, function()
        return self.inst and self.inst:IsValid() and self:IsPushing()
    end, function()
        self.ispushing = true
        self.starttime = os.clock()
    end, function()
        self.ispushing = false
        self.starttime = nil
    end)
end

--- Stops the pushing thread.
--
-- Stops the thread started earlier by the `StartPushingThread`.
function KeepFollowing:ClearPushingThread()
    return Utils.ThreadClear(self.pushingthread)
end

function KeepFollowing:StartPushing(leader)
    if self.config.push_lag_compensation and not self.ismastersim then
        MovementPredictionOnPush(self)
    end

    self:SetLeader(leader)
    self:DebugString("Started pushing leader...")
    self:StartPushingThread()
end

function KeepFollowing:StopPushing()
    if self.config.push_lag_compensation and not self.ismastersim then
        MovementPredictionOnStop(self)
    end

    if self.leader then
        self:DebugString(string.format(
            "Stopped pushing %s. Requests: %d. Time: %2.4f",
            self.leader:GetDisplayName(),
            self.debugrequests,
            os.clock() - self.starttime
        ))

        self.debugrequests = 0
        self.ispushing = false
        self.leader = nil
        self.starttime = nil
        self:ClearPushingThread()
    end
end

--- Initializes.
--
-- Sets empty and default fields and adds debug methods.
--
-- @tparam table inst Player instance.
function KeepFollowing:DoInit(inst)
    Utils.AddDebugMethods(self)

    -- general
    self.inst = inst
    self.isclient = false
    self.isdst = false
    self.ismastersim = TheWorld.ismastersim
    self.leader = nil
    self.movementpredictionstate = nil
    self.playercontroller = nil
    self.starttime = nil
    self.world = TheWorld

    -- following
    self.followingpaththread = nil
    self.followingthread = nil
    self.isfollowing = false
    self.isleadernear = false
    self.ispaused = false
    self.leaderpositions = {}

    -- pushing
    self.ispushing = false
    self.pushingthread = nil

    -- debugging
    self.debugrequests = 0

    -- config
    self.config = {
        following_method = "default",
        keep_target_distance = false,
        push_lag_compensation = true,
        push_mass_checking = true,
        target_distance = 2.5,
    }

    -- update
    inst:StartUpdatingComponent(self)

    -- tests
    if _G.TEST then
        self._IsHUDFocused = IsHUDFocused
        self._IsOnPlatform = IsOnPlatform
        self._IsPassable = IsPassable
        self._MovementPrediction = MovementPrediction
    end
end

return KeepFollowing
