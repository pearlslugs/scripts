-- trigger commands when custom reactions complete
-- author expwnent
-- replaces autoSyndrome
--@ module = true
local usage = [====[

modtools/reaction-trigger
=========================
Triggers dfhack commands when custom reactions complete, regardless of whether
it produced anything, once per completion.  Arguments::

    -clear
        unregister all reaction hooks
    -reactionName name
        specify the name of the reaction
    -syndrome name
        specify the name of the syndrome to be applied to the targets
    -allowNonworkerTargets
        allow other units in the same building to be targetted by
        either the script or the syndrome
    -allowMultipleTargets
        allow multiple targets to the script or syndrome
        if absent:
            if running a script, only one target will be used
            if applying a syndrome, then only one target will be infected
    -resetPolicy policy
        the policy in the case that the syndrome is already present
        policy
            NewInstance (default)
            DoNothing
            ResetDuration
            AddDuration
    -command [ commandStrs ]
        specify the command to be run on the target(s)
        special args
            \\WORKER_ID
            \\TARGET_ID
            \\BUILDING_ID
            \\LOCATION
            \\REACTION_NAME
            \\anything -> \anything
            anything -> anything

]====]
local eventful = require 'plugins.eventful'
local syndromeUtil = require 'syndrome-util'
local utils = require 'utils'

--luacheck: global
reactionHooks = reactionHooks or {} --as:{reactionName:__arg,syndrome:__arg,allowNonworkerTargets:__arg,allowMultipleTargets:__arg,resetPolicy:__arg,command:__arg}[][]

eventful.enableEvent(eventful.eventType.UNLOAD,1)
eventful.onUnload.reactionTrigger = function()
 reactionHooks = {}
end

local function findSyndrome(name)
 for _,syndrome in ipairs(df.global.world.raws.syndromes.all) do
  if syndrome.syn_name == name then
   return syndrome
  end
 end
end

function getWorkerAndBuilding(job)
 local workerId = -1
 local buildingId = -1
 for _,generalRef in ipairs(job.general_refs) do
  if generalRef:getType() == df.general_ref_type.UNIT_WORKER then
   if workerId ~= -1 then
    print(job)
    printall(job)
    error('reaction-trigger: two workers on same job: ' .. workerId .. ', ' .. generalRef.unit_id) --hint:df.general_ref_unit_workerst
   else
    workerId = generalRef.unit_id --hint:df.general_ref_unit_workerst
    if workerId == -1 then
     print(job)
     printall(job)
     error('reaction-trigger: invalid worker')
    end
   end
  elseif generalRef:getType() == df.general_ref_type.BUILDING_HOLDER then
   if buildingId ~= -1 then
    print(job)
    printall(job)
    error('reaction-trigger: two buildings same job: ' .. buildingId .. ', ' .. generalRef.building_id) --hint:df.general_ref_building_holderst
   else
    buildingId = generalRef.building_id --hint:df.general_ref_building_holderst
    if buildingId == -1 then
     print(job)
     printall(job)
     error('reaction-trigger: invalid building')
    end
   end
  end
 end
 return workerId,buildingId
end

local function processCommand(job, worker, target, building, command)
 local result = {}
 for _,arg in ipairs(command) do
  if arg == '\\WORKER_ID' then
   table.insert(result,''..worker.id)
  elseif arg == '\\TARGET_ID' then
   table.insert(result,''..target.id)
  elseif arg == '\\BUILDING_ID' then
   table.insert(result,''..building.id)
  elseif arg == '\\LOCATION' then
   table.insert(result,''..job.pos.x)
   table.insert(result,''..job.pos.y)
   table.insert(result,''..job.pos.z)
  elseif arg == '\\REACTION_NAME' then
   table.insert(result,''..job.reaction_name)
  elseif string.sub(arg,1,1) == '\\' then
   table.insert(result,string.sub(arg,2))
  else
   table.insert(result,arg)
  end
 end
 return result
end

eventful.onJobCompleted.reactionTrigger = function(job)
 if job.completion_timer > 0 then
  return
 end

-- if job.job_type ~= df.job_type.CustomReaction then
--  --TODO: support builtin reaction triggers if someone asks
--  return
-- end

 if not job.reaction_name or job.reaction_name == '' then
  return
 end
-- print('reaction name: ' .. job.reaction_name)
 if not job.reaction_name or not reactionHooks[job.reaction_name] then
  return
 end

 local worker_id,building_id = getWorkerAndBuilding(job)
 local worker = df.unit.find(worker_id)
 local building = df.building.find(building_id)
 if not worker or not building then
  --this probably means that it finished before EventManager could get a copy of the job while the job was running
  --TODO: consider printing a warning once
  return
 end

 local function doAction(action)
  local didSomething
  if action.command then
   local processed = processCommand(job, worker, worker, building, action.command)
   dfhack.run_command(table.unpack(processed))
  end
  if action.syndrome then
   local syndrome = findSyndrome(action.syndrome)
   if syndome then
    didSomething = syndromeUtil.infectWithSyndromeIfValidTarget(worker, syndrome, action.resetPolicy) or didSomething
   end
  end
  if not action.allowNonworkerTargets then
   return
  end
  if didSomething and not action.allowMultipleTargets then
   return
  end
  local function foreach(unit)
   if unit == worker then
    return false
   elseif unit.pos.z ~= building.z then
    return false
   elseif unit.pos.x < building.x1 or unit.pos.x > building.x2 then
    return false
   elseif unit.pos.y < building.y1 or unit.pos.y > building.y2 then
    return false
   else
    if action.command then
     processCommand(job, worker, unit, building, action.command)
    end
    if action.syndrome then
     local syndrome = findSyndrome(action.syndrome)
     if syndrome then
      didSomething = syndromeUtil.infectWithSyndromeIfValidTarget(unit,syndrome,action.resetPolicy) or didSomething
     end
    end
    if didSomething and not action.allowMultipleTargets then
     return true
    end
    return false
   end
  end
  for _,unit in ipairs(df.global.world.units.all) do
   if foreach(unit) then
    break
   end
  end
 end
 for _,action in ipairs(reactionHooks[job.reaction_name]) do
  doAction(action)
 end
end
eventful.enableEvent(eventful.eventType.JOB_COMPLETED,0) --0 is necessary to catch cancelled jobs and not trigger them

local validArgs = utils.invert({
 'help',
 'clear',
 'reactionName',
 'syndrome',
 'command',
 'allowNonworkerTargets',
 'allowMultipleTargets'
})

if moduleMode then
 return
end
local args = utils.processArgs({...}, validArgs)

if args.help then
 print(usage)
 return
end

if args.clear then
 reactionHooks = {}
end

if not args.reactionName then
 return
end

if not reactionHooks[args.reactionName] then
 reactionHooks[args.reactionName] = {}
end

if args.syndrome and not findSyndrome(args.syndrome) then
 error('Could not find syndrome ' .. args.syndrome)
end

table.insert(reactionHooks[args.reactionName], args)

