
--[[  LICENSE
--------------------------------------------------------------------------------
MIT License

Copyright (c) 2026 NoName-wks

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
--------------------------------------------------------------------------------
]]

--[[ README
--------------------------------------------------------------------------------

KrossSync
V.0.0.1

DataStore stores only the data field intended for permanent persistence.
MemoryStore stores the complete synchronization wrapper, including temporary memory and the server list.
When multiple servers use the same key, they share the latest state and connected servers through MemoryStore.

--------------------------------------------------------------------------------

]]

-----------Settings to adjust for the target environment---------

-- Save writes persistent data only when this much time has passed since the last DataStore save.
local SAVE_DATA_TIME = 60
-- Interval for checking changes written to MemoryStore by other servers.
local AUTO_GET_MEMORY_TIME = 15
-- Time without additional storage errors before error history and Critical state are reset.
local ERROR_RESET_TIME = 30
local CRITICAL_ERROR_COUNT = 5
-- Keep removal markers longer than the automatic polling interval so stale servers cannot restore deleted data.
local REMOVAL_TOMBSTONE_MIN_TIME = AUTO_GET_MEMORY_TIME * 4
local REMOVAL_MARKER = "__krossSyncRemoved"

-----------------------------------External modules
-- Signal+ module used for change notifications.
---@module signal 
local signal = require(game.ReplicatedStorage.scr.Library.Signal) --Signal+ (v3) by Alexander Lindholt  (https://github.com/AlexanderLindholt/SignalPlus)

-- Simple FIFO queue that tracks storage error timestamps in order.
---@module Queue
local Queue = {} do
	Queue.__index = Queue

	type Queue<T> = typeof(setmetatable(
		{} :: {
			_first: number,
			_last: number,
			_queue: { T },
			new:()->Queue<T>,
			isEmpty:(self:Queue<T>)->(),
			enqueue:(self:Queue<T>,value:T)->(),
			dequeue:(self:Queue<T>)->T|nil,
			peek:(self:Queue<T>)->T|nil,
			getSize:(self:Queue<T>)->number,
		},
		Queue
		))

	-- Check whether the queue still contains items to process.
	local function isEmpty(self)
		return self._first > self._last 
	end

	local function enqueue(self, value)
		-- Compact the array when unused space accumulates at the front.
		if self._first > 50 and self._first > (self._last - self._first) then
			local newQueue = {}
			local newIndex = 0

			for i = self._first, self._last do
				newQueue[newIndex] = self._queue[i]
				newIndex += 1
			end

			self._queue = newQueue
			self._last = newIndex - 1
			self._first = 0
		end

		self._last += 1
		self._queue[self._last] = value
	end

	local function dequeue(self)
		-- Remove and return the oldest value.
		if self:isEmpty() then
			warn("EmptyQueue")
			return nil
		end

		local first = self._first
		local value = self._queue[first]
		self._queue[first] = nil
		self._first = first + 1

		if self:isEmpty() then
			self._first = 0
			self._last = -1
		end

		return value
	end

	local function peek(self)
		-- Inspect the oldest item without removing it.
		if self:isEmpty() then
			warn("EmptyQueue")
			return nil
		end

		return self._queue[self._first]
	end

	local function getSize(self)
		return self._last - self._first + 1
	end

	-- Start the indices at 0 and -1 to represent an empty queue.
	function Queue.new<T>():Queue<T>
		local self = setmetatable({
			_first = 0,
			_last = -1,
			_queue = {},
			isEmpty = isEmpty,
			enqueue = enqueue,
			peek = peek,
			getSize = getSize,
			dequeue = dequeue,
		}, Queue)::Queue<T>

		return self
	end
end


------------------------------------Shared types

-- Storage access state. Total combines the DataStore and MemoryStore states.
type StateType = "NotReady" | "NoInternet" | "NoAccess" | "Access" | "Error"
type State = {Total: StateType, Data: StateType, Memory: StateType}


-- Data wrapper shared between servers through MemoryStore.
export type Data<MemTpl,DataTpl> = {
	lastUpdate: number, -- Time of the latest MemoryStore synchronization.
	dataCreateTime: number, -- Time of the latest DataStore save.
	memory: MemTpl, -- Temporary data kept only in MemoryStore.
	data: DataTpl, -- Data persisted in DataStore.
	onlineServers: {[number]:string}, -- JobIds of servers currently synchronizing this key.
}
-- Synchronization instance and public method type associated with one StoreName.
export type KrossSync<MemTpl,DataTpl> = {	
	-- nil retries until success; a number limits the number of attempts.
	MaxRetryTime:number|nil,
	-- Roblox storage objects and configuration used to create this instance.
	Store: DataStore,
	Map: MemoryStoreHashMap,
	MapName: string,
	DataTemplate: DataTpl,
	MemoryTemplate: MemTpl,
	ExpirationTime:number,
	-- Latest local cache and removal/follow-up task state for each key.
	LastData: {[string]:Data<MemTpl, DataTpl>},
	RemovedKeys: {[string]:number},
	PendingDataSave: {[string]:boolean},
	PendingRemovalCleanup: {[string]:boolean},
	PendingRemovalVerification: {[string]:boolean},
	-- Local locks that prevent overlapping reads and writes for each key.
	IsGetting: {[string]:boolean}, 
	IsSaving: {[string]:boolean}, 
	---- Instance signals ----
	OnNewData: signal.Signal<Data<MemTpl, DataTpl> >,
	OnGettingToggle: signal.Signal<boolean> ,
	OnSavingToggle: signal.Signal<boolean>,
	---- Read methods ----
	Get: (self:KrossSync<MemTpl, DataTpl>, key:string, force:boolean)-> (Data<MemTpl?, DataTpl> | false, {Data:boolean,Memory:boolean}?),
	GetData: (self:KrossSync<MemTpl, DataTpl>, key:string, force:boolean) -> (Data<nil, DataTpl> | nil | false ),
	GetMemory: (self:KrossSync<MemTpl, DataTpl>, key:string, force:boolean) -> (Data<MemTpl, DataTpl> | nil | false ),
	---- Save methods ----
	Save: (self:KrossSync<MemTpl, DataTpl>, key:string, data:Data<MemTpl, DataTpl>|(old:Data<MemTpl, DataTpl>?)->(Data<MemTpl, DataTpl>?), expiration:number, force:boolean) -> (boolean),
	SaveData: (self:KrossSync<MemTpl, DataTpl>, key:string, data:Data<MemTpl, DataTpl>|(old:DataTpl?)->(DataTpl?), force:boolean) -> (boolean),
	SaveMemory: (self:KrossSync<MemTpl, DataTpl>, key:string, data:Data<MemTpl, DataTpl>|(old:Data<MemTpl, DataTpl>?)->(Data<MemTpl ,DataTpl>?), expiration:number, force:boolean) -> (boolean),
	---- Removal methods: Remove returns DataStore success, then MemoryStore success. ----
	Remove: (self:KrossSync<MemTpl, DataTpl>, key:string) -> (boolean, boolean),
	RemoveData: (self:KrossSync<MemTpl, DataTpl>, key:string) -> boolean,
	RemoveMemory: (self:KrossSync<MemTpl, DataTpl>, key:string) -> boolean,
	---- Stop synchronization for the current server ----
	UnSync: (self:KrossSync<MemTpl, DataTpl>, key:string) -> boolean,
}

local rawError = error
local rawWarn = warn
local rawPrint = print

-- Prefix every log with the module name to distinguish it from other system logs.
local function error(str, lvl)
	rawError(`||{script.Name}|| {tostring(str)}`, lvl)
end

local function warn(...)
	rawWarn(`||{script.Name}||`, ...)
end

local function print(...)
	rawPrint(`||{script.Name}||`, ...)
end

local State:State = {Total= "NotReady", Data= "NotReady",Memory= "NotReady"}
local IsCritical = {Data = false,Memory = false,Total = false}

-- Fired when repeated errors change the Critical state. (overall flag, detailed state)
local OnCriticalToggle = signal()::signal.Signal<boolean,typeof(IsCritical)>
-- Fired when a storage request ultimately fails. Position 1=DataStore, 2=MemoryStore.
local OnError  = signal()::signal.Signal<number,string,string,string,any>
-- Internal signal that starts shutdown handling and automatic synchronization for a new KrossSync instance.
local OnNewKrossSync = signal()::signal.Signal<KrossSync<any,any>>

local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")
local MemoryStoreService = game:GetService("MemoryStoreService")


-- Keep only recent errors to detect repeated failures within a short period.
local dataErrorQueue = Queue.new()
local memoryErrorQueue = Queue.new()

--[[
	Retries storage requests using exponential backoff with randomized jitter.
	When maxRetries is nil, retries continue until success; a number always allows at least one attempt.
	action is protected by pcall internally, but callers must ensure errorAction does not throw.
]]
local function ExponentialJitterBackoff(
	cap: number,
	maxRetries: number?, 
	jitterPercent: number?, 
	action: () -> ...any, 
	errorAction: ((attempt: number, result: any, cap: number) -> ())?
) : (boolean, ...any|"action is nil")


	local maxAttempts = math.huge
	if maxRetries ~= nil and maxRetries == maxRetries then
		maxAttempts = math.max(1,math.floor(maxRetries))
	end
	local jitter = (jitterPercent or 50) / 100 -- Convert the percentage to the 0-1 range.

	if not action then
		warn("[ExponentialJitterBackoff] action is nil")
		return false, "action is nil"
	end

	local attempt = 0
	local success: boolean
	local results: {any}

	while attempt < maxAttempts do

		-- Pack pcall results to preserve the exact number of return values.
		results = table.pack(pcall(action))
		success = results[1] 

		if success then 
			return true, table.unpack(results,2,results.n) 
		else
			attempt += 1
			local errorMessage = results[2]

			if errorAction then
				errorAction(attempt, errorMessage, cap)
			end

			if attempt >= maxAttempts then
				return false, errorMessage
			end

			-- Increase wait time exponentially and use jitter to spread simultaneous requests.
			local baseWait = math.pow(2,attempt)

			local waitTime = baseWait + (math.random() * baseWait * jitter)
			waitTime = math.min(waitTime, cap or math.huge)
			task.wait(waitTime)
		end
	end

	return false, results[2]
end


-- Recursively copy tables so templates and caches never share nested table references.
-- Assumes ordinary acyclic tables that are valid for DataStore storage.
local function DeepCopyTable(t)
	local copy = {}
	for key, value in pairs(t) do
		if type(value) == "table" then
			copy[key] = DeepCopyTable(value)
		else
			copy[key] = value
		end
	end
	return copy
end

-- Recursively compare two values or nested table contents.
local function deepEqual(t1, t2)
	if t1 == t2 then return true end
	if type(t1) ~= "table" or type(t2) ~= "table" then return false end
	for k, v in pairs(t1) do
		if not deepEqual(v, t2[k]) then return false end
	end
	for k, v in pairs(t2) do
		if t1[k] == nil then return false end
	end
	return true
end

-- Fill only missing string keys from the template while preserving existing values and array entries.
local function ReconcileTable(target, template)
	for k, v in pairs(template) do
		if type(k) == "string" then
			if target[k] == nil then
				if type(v) == "table" then
					target[k] = DeepCopyTable(v)
				else
					target[k] = v
				end
			elseif type(target[k]) == "table" and type(v) == "table" then
				ReconcileTable(target[k], v)
			end
		end
	end
end

-- Reconcile structure only when both the value and template are tables.
local function ReconcileValueWithTemplate(value, template)
	if type(value) == "table" and type(template) == "table" then
		ReconcileTable(value, template)
	end
	return value
end

-- Reconcile persistent and temporary data in a MemoryStore wrapper with their respective templates.
local function ReconcileDataWithTemplates(data, dataTemplate, memoryTemplate)
	if type(data) ~= "table" then
		return data
	end

	ReconcileValueWithTemplate(data.data, dataTemplate)
	ReconcileValueWithTemplate(data.memory, memoryTemplate)
	return data
end

-- Check availability by creating a storage object or performing a real write.
-- High-level checks send real requests and should be used only when necessary.
local function IsStoreOkay(Type:nil|"Data"|"Memory",lvl:nil|"High" ):{Data:boolean|nil, Memory:boolean|nil}

	local function ChackDataStore(lvl)
		if lvl == "High" then
			-- Perform a real write to verify both API access and network status.
			local success = ExponentialJitterBackoff(2,2,nil,function()
				DataStoreService:GetGlobalDataStore():SetAsync("KrossSync_Chack",{Time=os.time(),JobID=game.JobId})
			end,nil)
			return success

		else
			local success = pcall(function()
				DataStoreService:GetGlobalDataStore()
			end)
			return success

		end

	end

	local function ChackMemoryStore(lvl)
		if lvl == "High" then
			-- Use a short expiration so health-check values do not remain for long.
			local success = ExponentialJitterBackoff(2, 2, nil, function()
				MemoryStoreService:GetHashMap("_tm"):SetAsync("KrossSync_Chack",{Time = os.time(),JobID=game.JobId},10)
			end)
			return success

		else
			local success = pcall(function()
				MemoryStoreService:GetHashMap("_tm")
			end)
			return success
		end

	end

	if Type == "Data"then
		return {Data=ChackDataStore(lvl)}
	elseif Type == "Memory" then
		return {Memory=ChackMemoryStore(lvl)}
	else
		return {Data=ChackDataStore(lvl),Memory=ChackMemoryStore(lvl)}
	end
end

-- Combine a DataStore value and MemoryStore-only value into one synchronization wrapper.
local function BuildData<memory,data>(lastUpdate,Data:data,Memory:memory,OnlineServers:{[number]:string}):Data<memory,data>
	return {lastUpdate=lastUpdate,
		dataCreateTime=os.time(),
		memory=Memory,
		data=Data,
		onlineServers=OnlineServers,
	}
end

-- Return the expiration time when a MemoryStore value is a removal marker.
-- For legacy markers without an expiration, treat the removal as indefinite for safety.
local function GetRemovalExpiration(value:any):number?
	if type(value) ~= "table" or value[REMOVAL_MARKER] ~= true then
		return nil
	end

	if type(value.removedUntil) == "number" then
		return value.removedUntil
	end

	return math.huge
end

-- Return only removal markers that have not expired.
local function GetActiveRemovalExpiration(value:any):number?
	local removedUntil = GetRemovalExpiration(value)
	if removedUntil and removedUntil > os.time() then
		return removedUntil
	end

	return nil
end

-- Check locally cached removal state without a network request.
local function IsKeyLocallyRemoved(self:KrossSync<unknown,unknown>,key:string):boolean
	local removedUntil = self.RemovedKeys[key]
	if not removedUntil then
		return false
	end

	if removedUntil <= os.time() then
		self.RemovedKeys[key] = nil
		return false
	end

	return true
end

-- Cache a shared tombstone locally and immediately discard existing cached data.
local function MarkKeyRemoved(self:KrossSync<unknown,unknown>,key:string,removedUntil:number)
	-- Do not replace a later removal expiration with an earlier one.
	local effectiveUntil = math.max(self.RemovedKeys[key] or 0,removedUntil)
	self.RemovedKeys[key] = effectiveUntil
	self.LastData[key] = nil

	-- Remove expired keys from the local table even if they are never accessed again.
	if effectiveUntil < math.huge then
		task.delay(math.max(0,effectiveUntil - os.time()),function()
			if self.RemovedKeys[key] == effectiveUntil and effectiveUntil <= os.time() then
				self.RemovedKeys[key] = nil
			end
		end)
	end
end

-- Create a MemoryStore removal marker visible to all servers.
local function BuildRemovalTombstone(expiration:number)
	local removedAt = os.time()
	return {
		[REMOVAL_MARKER] = true,
		removedAt = removedAt,
		removedUntil = removedAt + expiration,
	}
end

-- Normalize the server list by removing invalid values and duplicate JobIds.
local function NormalizeOnlineServers(onlineServers:{[number]:string}?):{[number]:string}
	local normalized = {}::{[number]:string}
	local found = {}::{[string]:boolean}

	for _,jobId in ipairs(onlineServers or {}) do
		if type(jobId) == "string" and not found[jobId] then
			found[jobId] = true
			table.insert(normalized,jobId)
		end
	end

	return normalized
end

-- Register the current server exactly once in a normalized server list.
local function RegisterCurrentServer(onlineServers:{[number]:string}?):{[number]:string}
	local normalized = NormalizeOnlineServers(onlineServers)
	if table.find(normalized,game.JobId) == nil then
		table.insert(normalized,game.JobId)
	end

	return normalized
end

-- Read the shared tombstone around DataStore access to prevent deleted data from being restored.
-- The first return value indicates read success; the second is the active tombstone expiration time.
local function ReadSharedRemoval(self:KrossSync<unknown,unknown>,key:string):(boolean,number?)
	local success, result = ExponentialJitterBackoff(
		5,
		2,
		nil,
		function()
			return self.Map:GetAsync(key)
		end,
		function(attempt, errorMessage, cap)
			warn("Removal check failed:",key,errorMessage)
		end
	)

	if not success then
		OnError:Fire(2,result,self.MapName,key)
		return false,nil
	end

	local removedUntil = GetActiveRemovalExpiration(result)
	if removedUntil then
		MarkKeyRemoved(self,key,removedUntil)
	end

	return true,removedUntil
end

-- Remove a DataStore key according to the retry policy. retryLimit overrides the limit for this call only.
local function RemoveDataStoreKey(self:KrossSync<unknown,unknown>,key:string,retryLimit:number?):boolean
	local success, result = ExponentialJitterBackoff(
		30,
		retryLimit or self.MaxRetryTime,
		nil,
		function()
			return self.Store:RemoveAsync(key)
		end,
		function(attempt, errorMessage, cap)
			warn("RemoveData failed:",key,errorMessage)
		end
	)

	if not success then
		OnError:Fire(1,result,self.Store.Name,key)
	end

	return success
end

-- Keep at most one background cleanup task for each key whose immediate removal failed.
local function ScheduleDataRemovalCleanup(self:KrossSync<unknown,unknown>,key:string,removedUntil:number?)
	if self.PendingRemovalCleanup[key] then
		return
	end

	-- Continue cleanup while the tombstone is active even if DataStore removal fails temporarily.
	self.PendingRemovalCleanup[key] = true
	task.spawn(function()
		local fallbackDeadline = os.time() + math.max(self.ExpirationTime,REMOVAL_TOMBSTONE_MIN_TIME)
		local deadline = removedUntil and removedUntil < math.huge and removedUntil or fallbackDeadline
		while os.time() < deadline do
			-- Make one attempt per outer iteration so one retry sequence cannot overrun the deadline.
			if RemoveDataStoreKey(self,key,1) then
				self.PendingRemovalCleanup[key] = nil
				return
			end
			task.wait(5)
		end

		self.PendingRemovalCleanup[key] = nil
		warn("Removal cleanup expired before DataStore deletion succeeded:",key)
	end)
end

-- Attempt immediate removal first, then schedule asynchronous retries while the tombstone is active.
local function EnsureDataStoreRemoved(self:KrossSync<unknown,unknown>,key:string,removedUntil:number?):boolean
	local success = RemoveDataStoreKey(self,key)
	if not success then
		ScheduleDataRemovalCleanup(self,key,removedUntil)
	end
	return success
end

-- Recheck shared removal state when only tombstone verification fails after a DataStore write.
local function ScheduleRemovalVerification(self:KrossSync<unknown,unknown>,key:string)
	if self.PendingRemovalVerification[key] then
		return
	end

	-- When the write completed but MemoryStore verification failed, retry verification separately without requiring another save.
	self.PendingRemovalVerification[key] = true
	task.spawn(function()
		local deadline = os.time() + math.max(self.ExpirationTime,REMOVAL_TOMBSTONE_MIN_TIME)
		local completed = false
		while os.time() < deadline do
			local verificationSucceeded, removedUntil = ReadSharedRemoval(self,key)
			if verificationSucceeded then
				if removedUntil then
					EnsureDataStoreRemoved(self,key,removedUntil)
				end
				completed = true
				break
			end
			task.wait(5)
		end

		self.PendingRemovalVerification[key] = nil
		if not completed then
			warn("Removal verification expired after a committed DataStore write:",key)
		end
	end)
end

-- Retry the DataStore write with the latest local value when MemoryStore committed but DataStore alone failed.
-- Keep one task per key and use the latest LastData if a later MemoryStore change occurs before retry.
local function ScheduleDataSave(self:KrossSync<unknown,unknown>,key:string)
	if self.PendingDataSave[key] then
		return
	end

	self.PendingDataSave[key] = true
	task.spawn(function()
		while self.PendingDataSave[key] do
			if IsKeyLocallyRemoved(self,key) or self.LastData[key] == nil then
				self.PendingDataSave[key] = nil
				return
			end

			local latestData = DeepCopyTable(self.LastData[key])
			if self:SaveData(key,latestData,true) then
				self.PendingDataSave[key] = nil
				return
			end

			task.wait(5)
		end
	end)
end

-------------------------------------------------------------------KrossSync instance API-------------------------------------


local KrossSync = {} ::KrossSync<unknown,unknown>
KrossSync.__index = KrossSync



-- Change a key's read-lock state and fire the signal only when the actual state changes.
function KrossSync:SetGetting(key,value)
	local wasGetting = self.IsGetting[key] == true
	local isGetting = value == true

	-- Remove completed keys instead of retaining false entries, preventing accumulation on long-running servers.
	self.IsGetting[key] = if isGetting then true else nil
	if wasGetting ~= isGetting then
		self.OnGettingToggle:Fire(isGetting)
	end
end

-- Change a key's write-lock state and remove completed lock entries from the table.
function KrossSync:SetSaving(key,value)
	local wasSaving = self.IsSaving[key] == true
	local isSaving = value == true

	self.IsSaving[key] = if isSaving then true else nil
	if wasSaving ~= isSaving then
		self.OnSavingToggle:Fire(isSaving)
	end
end


-- Read MemoryStore first; if missing, recover from DataStore or create new data from the templates.
function KrossSync:Get(key,force)	
	-- Prevent reads and writes from overlapping on the same key. force does not bypass locks.
	if self.IsGetting[key] or self.IsSaving[key] then
		return false
	end
	if force ~= true and (IsCritical.Total or State.Total ~= "Access") then
		return false
	end

	-- Check MemoryStore first because it contains the latest cross-server state.
	local memory = self:GetMemory(key,force)

	if (memory ~= false) and (memory ~= nil) then
		return memory

	elseif memory == nil then
		-- If MemoryStore has no value, rebuild the complete wrapper from persistent data.
		local data2 = self:GetData(key,force)

		if (data2 ~= false) and (data2 ~= nil) then
			-- Return the wrapper recovered by GetData and the recovery status of each storage service.
			return data2, {Data = true, Memory = data2.memory ~= nil}

		elseif data2 == nil then
			-- If neither storage service has a value, create a new key from the templates.

			if force ~= true then
				-- Verify actual DataStore write access before creating new persistent data.
				local StoreStatus = IsStoreOkay("Data","High")
				if StoreStatus.Data == false then
					return false
				end
			end
			local Time = os.time()
			-- Write only data to DataStore and the complete wrapper to MemoryStore.
			local d = self:SaveData(key, BuildData(Time, DeepCopyTable(self.DataTemplate), nil, {game.JobId}), force)
			local m = self:SaveMemory(key, BuildData(Time, DeepCopyTable(self.DataTemplate), DeepCopyTable(self.MemoryTemplate), {game.JobId}), self.ExpirationTime, force)
			if IsKeyLocallyRemoved(self,key) then
				if d then
					EnsureDataStoreRemoved(self,key,self.RemovedKeys[key])
				end
				return false, {Data=false, Memory=false}
			end

			if d and m then
				return BuildData(Time, DeepCopyTable(self.DataTemplate), DeepCopyTable(self.MemoryTemplate), {game.JobId})

			elseif d then
				-- Return a status table so callers can distinguish partial success.
				return BuildData(Time, DeepCopyTable(self.DataTemplate), nil, {game.JobId}), {Data=true, Memory=false}

			elseif m then
				return BuildData(Time, nil, DeepCopyTable(self.MemoryTemplate), {game.JobId}), {Data=false, Memory=true}
			else
				return false, {Data=false, Memory=false}
			end	

		end
	end

	return false
end


-- DataStore contains only the data field, not the complete wrapper.
function KrossSync:GetData(key,force)
	-- Check local removal state and per-key locks first.
	if IsKeyLocallyRemoved(self,key) or self.IsGetting[key] or self.IsSaving[key] then
		return false
	end
	-- DataStore reads must also check the MemoryStore tombstone to prevent deleted keys from being restored.
	if force ~= true and (IsCritical.Data or IsCritical.Memory or State.Data ~= "Access" or State.Memory ~= "Access") then
		return false
	end

	self:SetGetting(key,true)

	local function action()
		return self.Store:GetAsync(key)
	end

	local function errorAction(attempt,result,cap)

		warn("GetData failed:", key, result)
	end

	local success, result = ExponentialJitterBackoff(
		30,
		self.MaxRetryTime,
		nil,
		action,
		errorAction
	)

	if not success then
		self:SetGetting(key,false)
		warn("GetData failed:", key, result)
		OnError:Fire(1,result,self.Store.Name,key)
		return false
	end

	local removalCheckSucceeded, removedUntil = ReadSharedRemoval(self,key)
	self:SetGetting(key,false)
	if not removalCheckSucceeded or removedUntil then
		return false
	end

	if result == nil then
		-- nil is not an error; it means the key has not been created yet.
		return nil
	end

	result = ReconcileValueWithTemplate(result, self.DataTemplate)

	if self.LastData[key] then
		-- If temporary state already exists, merge only the new persistent data to align MemoryStore and cache.
		local data = BuildData(self.LastData[key].dataCreateTime, result, self.LastData[key].memory, self.LastData[key].onlineServers)
		if not deepEqual(data.data,self.LastData[key].data) then
			local success = self:SaveMemory(key,function(old)
				old.data = data.data
				return old
			end,nil,force)
			if not success then
				return false
			end
		else
			self.LastData[key] = data
		end
		
		
		return self.LastData[key]
	else
		-- If no local cache exists, create MemoryStore data from the memory template and current server list.
		local memory = DeepCopyTable(self.MemoryTemplate)
		memory = ReconcileValueWithTemplate(memory, self.MemoryTemplate)
		local m = self:SaveMemory(key, BuildData(os.time(), result, memory, {game.JobId}), self.ExpirationTime, force)
		local data
		if m == false then
			if IsKeyLocallyRemoved(self,key) then
				return false
			end
			data = BuildData(os.time(), result, nil, {game.JobId})
		else
			data = BuildData(os.time(), result, memory, {game.JobId})
		end
		self.LastData[key] = data
		return data
	end
end


-- Read the shared cross-server wrapper and atomically register the current JobId if it is missing.
function KrossSync:GetMemory(key,force) 
	-- Prevent another operation from overwriting the key while it is being read.
	if self.IsGetting[key] or self.IsSaving[key] then
		return false
	end
	if force ~= true and (IsCritical.Memory or State.Memory ~= "Access") then
		return false
	end

	self:SetGetting(key,true)

	local function action()

		return self.Map:GetAsync(key)
	end

	local function errorAction(attempt,result,cap)

		warn("GetMemory failed:", key, result)
	end

	local success, result = ExponentialJitterBackoff(
		30,
		self.MaxRetryTime,
		nil,
		action,
		errorAction
	)

	self:SetGetting(key,false)

	if not success then

		warn("GetMemory failed:", key, result)
		OnError:Fire(2,result,self.MapName,key)
		return false
	end

	if result == nil then
		-- Without a local removal record, nil means the MemoryStore entry expired or was never created.
		if IsKeyLocallyRemoved(self,key) then
			return false
		end
		return nil
	end

	-- Do not cache an active tombstone; immediately transition to removed state.
	local removedUntil = GetActiveRemovalExpiration(result)
	if removedUntil then
		MarkKeyRemoved(self,key,removedUntil)
		return false
	elseif GetRemovalExpiration(result) then
		self.RemovedKeys[key] = nil
		return nil
	elseif IsKeyLocallyRemoved(self,key) then
		return false
	end

	-- Fill new template fields into older data and normalize the server list.
	local data = ReconcileDataWithTemplates(result, self.DataTemplate, self.MemoryTemplate)
	local normalizedServers = NormalizeOnlineServers(data.onlineServers)
	local needsRegistration = table.find(normalizedServers,game.JobId) == nil
	local needsNormalization = not deepEqual(normalizedServers,data.onlineServers)

	if needsRegistration or needsNormalization then
		-- Read the latest value again through UpdateAsync so concurrent registration by another server is preserved.
		local saved = self:SaveMemory(key,function(oldData)
			local latestData = ReconcileDataWithTemplates(oldData or data, self.DataTemplate, self.MemoryTemplate)
			latestData.onlineServers = RegisterCurrentServer(latestData.onlineServers)
			return latestData
		end,self.ExpirationTime,force)

		if not saved then
			return false
		end

		return self.LastData[key]
	end

	data.onlineServers = normalizedServers
	self.LastData[key] = data
	return data

end


-- Normally update MemoryStore; once the persistence interval passes, also write the data field to DataStore.
function KrossSync:Save(key,data,expiration,force)
	-- Accept only functional updates or complete wrapper tables.
	if self.IsGetting[key] or self.IsSaving[key] or (typeof(data)~="function" and typeof(data)~="table") then
		return false
	end
	if force ~= true and (IsCritical.Total == true or State.Total ~= "Access") then
		return false
	end

	expiration = expiration or self.ExpirationTime

	if self.LastData[key] and self.LastData[key].dataCreateTime + SAVE_DATA_TIME <= os.time() then

		-- Update shared memory first, then persist the committed data field.
		local m = self:SaveMemory(key,data,expiration,force)
		if not m then
			return false
		end
		local d = self:SaveData(key,self.LastData[key],force)
		if d then
			-- Cancel any previously scheduled task because the latest value has now been persisted.
			self.PendingDataSave[key] = nil
			return true
		elseif IsKeyLocallyRemoved(self,key) then
			return false
		end

		-- MemoryStore has already committed the function result. Report logical success so the caller does not
		-- execute the same function again, and retry only the persistent write in the background.
		ScheduleDataSave(self,key)
		return true
	else
		-- Before the persistence interval passes, perform only the faster MemoryStore update.
		return self:SaveMemory(key,data,expiration,force)
	end
end


-- A table input stores only the wrapper's data field. A function input receives the existing DataStore data value.
-- UpdateAsync callbacks can run multiple times during conflicts, so they must not mutate external state.
function KrossSync:SaveData(key,data,force) self = self::KrossSync<unknown,unknown>
	if IsKeyLocallyRemoved(self,key) then
		return false
	end

	if self.IsGetting[key] or self.IsSaving[key] or (typeof(data)~="function" and typeof(data)~="table") then
		return false
	end
	-- Check the MemoryStore tombstone before and after writing to prevent deleted keys from being restored.
	if force ~= true and (IsCritical.Data or IsCritical.Memory or State.Data ~= "Access" or State.Memory ~= "Access") then
		return false
	end

	-- Preserve the previous temporary state so the complete local wrapper can be rebuilt after a successful save.
	local oldLastData = self.LastData[key]
	local savedData
	local hasSavedData = false

	self:SetSaving(key,true)
	local removalCheckSucceeded, removedUntil = ReadSharedRemoval(self,key)
	if not removalCheckSucceeded or removedUntil then
		self:SetSaving(key,false)
		return false
	end

	local function action()
		if typeof(data)=="function" then
			-- Pass only the raw data value stored in DataStore to the function.
			return self.Store:UpdateAsync(key,function(oldData)
				savedData = data(oldData)
				hasSavedData = true
				return savedData
			end)

		elseif typeof(data)=="table" then
			-- Extract only the data field intended for persistence from the complete wrapper.
			savedData = data.data
			hasSavedData = true
			return self.Store:SetAsync(key,savedData)
		end
	end


	local function errorAction(attempt,result,cap)
		warn("SaveData failed:", key, tostring(data), result)
	end

	local success, result = ExponentialJitterBackoff(
		30,
		self.MaxRetryTime,
		nil,
		action,
		errorAction
	)

	if success then
		-- Recheck whether the write raced with a removal.
		local verificationSucceeded, removedAfterSave = ReadSharedRemoval(self,key)
		if not verificationSucceeded then
			-- The DataStore write has already committed. Preserve success to prevent duplicate execution
			-- of a functional update, and retry only tombstone verification in the background.
			ScheduleRemovalVerification(self,key)
		elseif removedAfterSave then
			self:SetSaving(key,false)
			EnsureDataStoreRemoved(self,key,removedAfterSave)
			return false
		end
	end

	self:SetSaving(key,false)

	if not success then
		OnError:Fire(1,result,self.Store.Name,key,data)
		return false
	elseif result == nil and typeof(data) == "function" then
		return false
	else
		if hasSavedData then
			-- Preserve MemoryStore-only fields and the server list while replacing only data with the saved result.
			local lastData = oldLastData or BuildData(os.time(), DeepCopyTable(self.DataTemplate), nil, {game.JobId})
			self.LastData[key] = BuildData(lastData.dataCreateTime, savedData, lastData.memory, lastData.onlineServers)
		end

		return true
	end
end


-- Store the complete synchronization wrapper in MemoryStore. Function callbacks receive the latest wrapper.
function KrossSync:SaveMemory(key,data,expiration,force)
	if IsKeyLocallyRemoved(self,key) then
		return false
	end

	if self.IsGetting[key] or self.IsSaving[key] or (typeof(data)~="function" and typeof(data)~="table") then
		return false
	end
	if force ~= true and (IsCritical.Memory == true or State.Memory ~= "Access") then
		return false
	end

	expiration = expiration or self.ExpirationTime

	-- Preserve a local fallback for use when the MemoryStore entry has expired.
	local oldLastData = self.LastData[key]
	local savedMemoryData
	local hasSavedMemoryData = false
	local blockedByRemoval = false
	local removedUntil

	self:SetSaving(key,true)

	local function action()
		-- Check the tombstone and update data atomically inside UpdateAsync.
		return self.Map:UpdateAsync(key,function(oldData)
			savedMemoryData = nil
			hasSavedMemoryData = false
			blockedByRemoval = false
			removedUntil = GetActiveRemovalExpiration(oldData)

			if removedUntil then
				-- Never overwrite a removal marker with a normal save.
				blockedByRemoval = true
				return oldData
			elseif GetRemovalExpiration(oldData) then
				oldData = nil
			end

			if typeof(data)== "function" then
				-- If the entry is missing, pass the latest local cache or a template wrapper to the function.
				local fallbackData = oldLastData or BuildData(os.time(), DeepCopyTable(self.DataTemplate), DeepCopyTable(self.MemoryTemplate), {game.JobId})
				savedMemoryData = data(oldData or fallbackData)
			elseif typeof(data)== "table" then
				-- Copy external tables before storage and merge the latest server list.
				savedMemoryData = DeepCopyTable(data)
				local currentServers = oldData and oldData.onlineServers or savedMemoryData.onlineServers
				savedMemoryData.onlineServers = RegisterCurrentServer(currentServers)
			end

			if savedMemoryData == nil then
				return nil
			end

			hasSavedMemoryData = true
			return savedMemoryData
		end,expiration)
	end

	local function errorAction(attempt,result,cap)
		warn("SaveMemory failed:",key, tostring(data), result)
	end

	local success, result = ExponentialJitterBackoff(
		30,
		self.MaxRetryTime,
		nil,
		action,
		errorAction
	)

	self:SetSaving(key,false)

	local resultRemovedUntil = GetActiveRemovalExpiration(result)
	if not success then
		OnError:Fire(2,result,self.MapName,key,data)
		return false
	elseif blockedByRemoval then
		MarkKeyRemoved(self,key,removedUntil or math.huge)
		return false
	elseif resultRemovedUntil then
		MarkKeyRemoved(self,key,resultRemovedUntil)
		return false
	elseif result == nil then
		return false
	else
		if hasSavedMemoryData then
			self.LastData[key] = savedMemoryData
		end

		return true
	end
end


-- Record a tombstone through UpdateAsync so it is atomically ordered with writes from other servers.
local function SetRemovalTombstone(self:KrossSync<unknown,unknown>,key:string,expiration:number):boolean
	local tombstone = BuildRemovalTombstone(expiration)
	local success, result = ExponentialJitterBackoff(
		30,
		self.MaxRetryTime,
		nil,
		function()
			return self.Map:UpdateAsync(key,function()
				tombstone = BuildRemovalTombstone(expiration)
				return tombstone
			end,expiration)
		end,
		function(attempt, errorMessage, cap)
			warn("RemoveMemory failed:",key,errorMessage)
		end
	)

	if not success then
		OnError:Fire(2,result,self.MapName,key)
		return false
	end

	MarkKeyRemoved(self,key,GetRemovalExpiration(result) or tombstone.removedUntil)
	return true
end


-- Internal wrapper used by the standalone DataStore removal API.
local function RemoveDataKey(self:KrossSync<unknown,unknown>, key:string):boolean
	return RemoveDataStoreKey(self,key)
end

-- Remove the MemoryStore entry itself without creating a tombstone.
local function RemoveMemoryKey(self:KrossSync<unknown,unknown>, key:string):boolean
	local success, result = ExponentialJitterBackoff(
		30,
		self.MaxRetryTime,
		nil,
		function()
			return self.Map:RemoveAsync(key)
		end,
		function(attempt, errorMessage, cap)
			warn("RemoveMemory failed:", key, errorMessage)
		end
	)

	if not success then
		OnError:Fire(2,result,self.MapName,key)
	end

	return success
end

-- Write a tombstone to MemoryStore before deleting DataStore data to block stale writes from other servers.
function KrossSync:Remove(key)
	-- Block other local operations on the same key during removal.
	if self.IsGetting[key] or self.IsSaving[key] then
		return false, false
	end

	self:SetSaving(key,true)

	-- Guarantee a minimum lifetime so pending automatic reads can still observe the removal.
	local tombstoneExpiration = math.max(self.ExpirationTime,REMOVAL_TOMBSTONE_MIN_TIME)
	local memoryRemoved = SetRemovalTombstone(self,key,tombstoneExpiration)
	local dataRemoved = false
	if memoryRemoved then
		-- Delete persistent data only after the shared removal marker is written successfully.
		dataRemoved = EnsureDataStoreRemoved(self,key,self.RemovedKeys[key])
	end

	self:SetSaving(key,false)
	self.IsGetting[key] = nil
	self.IsSaving[key] = nil

	return dataRemoved, memoryRemoved
end


-- Low-level method that immediately removes only the DataStore value.
-- If another server is still synchronizing, its final UnSync may save the value again; use Remove for permanent deletion.
function KrossSync:RemoveData(key) local self = self :: KrossSync<unknown,unknown>
	if self.IsGetting[key] or self.IsSaving[key] then
		return false
	end

	self:SetSaving(key,true)
	local success = RemoveDataKey(self,key)

	if success then
		-- Prevent removed persistent data from being reused through the local cache.
		self.LastData[key] = nil
	end

	self:SetSaving(key,false)
	self.IsGetting[key] = nil
	self.IsSaving[key] = nil
	return success
end

-- Remove only the MemoryStore entry. A later Get may recreate it if DataStore data still exists.
function KrossSync:RemoveMemory(key) local self = self :: KrossSync<unknown,unknown>
	if self.IsGetting[key] or self.IsSaving[key] then
		return false
	end

	self:SetSaving(key,true)
	local success = RemoveMemoryKey(self,key)

	if success then
		-- Standalone MemoryStore removal also clears existing local tombstone state.
		self.LastData[key] = nil
		self.RemovedKeys[key] = nil
	end

	self:SetSaving(key,false)
	self.IsGetting[key] = nil
	self.IsSaving[key] = nil
	return success
end


-- Remove the current server's JobId and, when it is the last server, persist the latest data field to DataStore.
function KrossSync:UnSync(key)
	-- A key that is not locally synchronized cannot be released.
	if not self.LastData[key] then
		return false
	end

	local LastData
	local function data(old:Data<unknown,unknown>)
		-- Normalize the server list by removing every duplicate of the current JobId.
		old.onlineServers = NormalizeOnlineServers(old.onlineServers)
		for i = #old.onlineServers,1,-1 do
			if old.onlineServers[i] == game.JobId then
				table.remove(old.onlineServers,i)
			end
		end
		LastData = old
		return old
	end
	-- Use force during shutdown so final cleanup is attempted even when global state is Error.
	local success = self:SaveMemory(key,data,self.ExpirationTime,true)
	if not success then
		if IsKeyLocallyRemoved(self,key) then
			self.LastData[key] = nil
			return true
		end
		return false
	else
		if not LastData then
			return false
		end
		if #(LastData.onlineServers or {})== 0 then
			-- When the last server leaves, persist the latest MemoryStore data to DataStore one final time.
			success = self:SaveData(key,LastData,true)
			if success then
				self.LastData[key] = nil
			else
				self.LastData[key] = LastData
			end
			return success
		end

		self.LastData[key] = nil

		return true
	end

end


---------------------------------------------------------KrossSyncService public API
---------------------------------------------------------

export type KrossSyncService = {
	get:<DataTemplate,MemoryTemplate>(StoreName:string,DataTemplate:DataTemplate,MemoryTemplate:MemoryTemplate,NormalExpirationTime:number?)->(KrossSync<MemoryTemplate,DataTemplate> | false),
	KrossSyncs: {[string]:KrossSync<unknown,unknown> | nil},
	State: State,
	IsCritical: typeof(IsCritical),
	OnCriticalToggle:signal.Signal<boolean,typeof(IsCritical)>,
	OnError:signal.Signal<number,string,string,string,any>
}

local KrossSyncService:KrossSyncService = {}


-----------------------Public state------------------------

KrossSyncService.KrossSyncs = {}
-- Expose current overall/per-storage state and Critical flags for external inspection.
KrossSyncService.State = State
KrossSyncService.IsCritical = IsCritical

---- Public signals ----

-- Fired when accumulated errors within a short period change the Critical state.
KrossSyncService.OnCriticalToggle = OnCriticalToggle
-- Fired when a storage request ultimately fails, providing location, error, store name, key, and input value.
KrossSyncService.OnError  = OnError

-----------------------Instance creation---------------------

function KrossSyncService.get(StoreName,DataTemplate,MemoryTemplate,NormalExpirationTime)
	-- The same StoreName shares one instance. Different template references are rejected for an existing instance.
	if KrossSyncService.KrossSyncs[StoreName] then
		if KrossSyncService.KrossSyncs[StoreName].DataTemplate ~= DataTemplate or KrossSyncService.KrossSyncs[StoreName].MemoryTemplate ~= MemoryTemplate then
			return false
		end

		return KrossSyncService.KrossSyncs[StoreName]
	end

	-- Each StoreName instance owns independent storage objects, caches, locks, and signals.
	local self={
		MaxRetryTime=5,
		Store = DataStoreService:GetDataStore(StoreName),
		Map = MemoryStoreService:GetHashMap(StoreName),
		MapName = StoreName,
		DataTemplate = DataTemplate,
		MemoryTemplate = MemoryTemplate,
		ExpirationTime = NormalExpirationTime or 600,
		LastData = {},
		RemovedKeys = {},
		PendingDataSave = {},
		PendingRemovalCleanup = {},
		PendingRemovalVerification = {},
		-- Per-key local locks.
		IsGetting = {},
		IsSaving = {},
		---- Per-instance signals ----
		OnNewData = signal(), -- Sends the complete wrapper when automatic synchronization changes memory.
		OnGettingToggle = signal(), -- Sends whether a read operation has started or ended.
		OnSavingToggle = signal(), -- Sends whether a write operation has started or ended.
		-- TODO: Consider a signal that reports which store (DataStore/MemoryStore) was overwritten.
	}

	self = setmetatable(self,KrossSync)::KrossSync<typeof(MemoryTemplate),typeof(DataTemplate)>

	-- Connect shutdown handling and automatic synchronization before registering the instance in the service cache.
	OnNewKrossSync:Fire(self)
	KrossSyncService.KrossSyncs[StoreName] = self

	return self

end

-----------------------Internal state management------------------- 
-- Set Total to Critical when either DataStore or MemoryStore is Critical.
local function setCritical(Data,Memory)
	if Data == nil then
		Data = IsCritical.Data
	end
	if Memory == nil then
		Memory = IsCritical.Memory
	end

	if Data == IsCritical.Data and Memory == IsCritical.Memory then
		return
	else
		IsCritical.Data = Data
		IsCritical.Memory = Memory
		if Data == false and Memory == false then
			IsCritical.Total = false
		else
			IsCritical.Total = true
		end
		OnCriticalToggle:Fire(IsCritical.Total,IsCritical)
	end
end

-- Update individual storage states and calculate the overall state by priority.
local function setState(Data, Memory)
	if State.Total == "NoInternet" or Data == "NotReady" or Memory == "NotReady" then
		return
	elseif State.Total == "NoAccess" and (Data ~= "Access" and Memory ~= "Access") then
		return
	elseif State.Total == "Access" and (Data == "NotReady" or Memory == "NotReady") then
		return
	elseif State.Total == "Error" and (Data == "NoAccess" or Memory == "NoAccess")then
		return
	end
	Data = Data or State.Data
	Memory = Memory or State.Memory

	State.Data = Data
	State.Memory = Memory 

	if Data == "Access" and Memory == "Access" then
		State.Total = "Access"
	elseif Data == "NoInternet" or Memory == "NoInternet" then
		State.Total = "NoInternet"
	elseif Data == "NoAccess" or Memory == "NoAccess" then
		State.Total = "NoAccess"
	elseif Data == "Error" or Memory == "Error" then
		State.Total = "Error"
	end
end

OnNewKrossSync:Connect(function(KrossSync)
	-- On shutdown, release this server from every key and final-save keys for which it is the last server.
	game:BindToClose(function()
		-- Finish cleanup within 25 seconds, leaving margin before Roblox's shutdown limit.
		local CLOSE_DEADLINE = 25
		local CloseTime = os.time()
		for key,v in pairs(KrossSync.LastData) do
			-- Retry UnSync independently for each key so one failure does not block other keys.
			task.spawn(function()
				KrossSync:UnSync(key)
				while KrossSync.LastData[key] do task.wait(1)
					KrossSync:UnSync(key)
				end
			end)
		end
		while task.wait() do
			-- Stop waiting once every local cache entry has been released.
			local keys = 0
			for k,v in pairs(KrossSync.LastData) do
				keys += 1
			end
			if keys == 0 then break end

			if os.time() - CloseTime >= CLOSE_DEADLINE then
				warn("KrossSync: BindToClose took too long to close. ("..(os.time()-CloseTime).."s)")
				break
			end

		end
	end)

	------------------

	-- Fetch changes from other servers only while the cache captured at scheduling time remains active.
	-- Without this check, a stale task could recreate the JobId and LastData immediately after UnSync.
	local function AutoGetMemory(key, previousData)
		local activeData = KrossSync.LastData[key]
		if activeData ~= previousData or not activeData.memory then
			return
		end

		local memoryData = KrossSync:GetMemory(key,false)

		if memoryData == nil then
			-- Even if the entry expired, restore it to MemoryStore only while this server still synchronizes the key.
			local currentData = KrossSync.LastData[key]
			if currentData and currentData.memory then
				KrossSync:SaveMemory(key,currentData,KrossSync.ExpirationTime,false)
			end
			return
		elseif memoryData == false then
			return
		end
		-- Discard stale results if UnSync or Remove completed while GetMemory yielded.
		if KrossSync.LastData[key] ~= memoryData then
			return
		end

		-- Fire OnNewData only when the temporary memory contents actually changed.
		local memoryChanged = not deepEqual(previousData.memory,memoryData.memory)
		memoryData.lastUpdate = os.time()
		memoryData.dataCreateTime = math.max(previousData.dataCreateTime or 0,memoryData.dataCreateTime or 0)
		KrossSync.LastData[key] = memoryData

		if memoryChanged then
			KrossSync.OnNewData:Fire(memoryData)
		end
	end

	-- Schedule an initial read for keys that entered the cache before instance initialization completed.
	local tasks = {}::{[string]:thread}
	for key, data in pairs(KrossSync.LastData) do
		tasks[key] = task.spawn(function() 
			task.wait(math.max(0, data.dataCreateTime+AUTO_GET_MEMORY_TIME - os.time()))
			AutoGetMemory(key,data)
		end)
	end

	-- Enforce the minimum polling interval using the latest automatic read time for each key.
	local LastGetTime = {}
	task.spawn(function()
		-- Enter the repeating synchronization loop after all initially scheduled tasks finish.
		while task.wait() do
			local i = 0
			for key,thread in pairs(tasks) do
				i+=1 break
			end
			if i == 0 then break end
		end

		while true do

			-- Read every key currently in local use in parallel.
			for key, data in pairs(KrossSync.LastData) do
				tasks[key]  = task.spawn(function() 
					task.wait(math.max(0, (LastGetTime[key] or 0) +  AUTO_GET_MEMORY_TIME - os.time()))
					task.wait(math.max(0, data.dataCreateTime + AUTO_GET_MEMORY_TIME - os.time()))
					AutoGetMemory(key,data)

					LastGetTime[key] = os.time()
					tasks[key] = nil
				end)

			end

			-- Wait until all key reads for this cycle finish.
			while task.wait() do
				local i = 0
				for key,thread in pairs(tasks) do
					i+=1
					break
				end
				if i == 0 then break end
			end

			-- Remove polling records for keys that have not been used recently.
			for key,v in pairs(LastGetTime) do
				if os.time() - v >= AUTO_GET_MEMORY_TIME * 10 then
					LastGetTime[key] = nil
				end
			end

		end
	end)


end)

local dataLastErrorTime = 0
local memoryLastErrorTime = 0
local dataRecoveryRunning = false
local memoryRecoveryRunning = false

-- Remove records older than the error-detection window from the front of the queue.
local function TrimExpiredErrors(errorQueue,now)
	while not errorQueue:isEmpty() do
		local oldest = errorQueue:peek()
		if type(oldest) ~= "table" or type(oldest.time) ~= "number" or now - oldest.time >= ERROR_RESET_TIME then
			errorQueue:dequeue()
		else
			break
		end
	end
end

-- Clear the relevant error queue completely after the storage service recovers.
local function ClearErrorQueue(errorQueue)
	while not errorQueue:isEmpty() do
		errorQueue:dequeue()
	end
end

-- Run at most one recovery monitor for each storage service.
local function StartErrorRecovery(pos:number)
	if pos == 1 then
		if dataRecoveryRunning then
			return
		end
		dataRecoveryRunning = true
	elseif pos == 2 then
		if memoryRecoveryRunning then
			return
		end
		memoryRecoveryRunning = true
	else
		return
	end

	-- Clear Critical state only after no additional errors occur for a period following the latest error.
	task.spawn(function()
		while true do
			local lastErrorTime
			if pos == 1 then
				lastErrorTime = dataLastErrorTime
			else
				lastErrorTime = memoryLastErrorTime
			end
			local remaining = ERROR_RESET_TIME - (os.clock() - lastErrorTime)
			if remaining <= 0 then
				break
			end
			task.wait(remaining)
		end

		if pos == 1 then
			ClearErrorQueue(dataErrorQueue)
			if IsCritical.Data then
				setCritical(false,nil)
				if State.Data == "Error" then
					setState("Access",nil)
				end
			end
			dataRecoveryRunning = false
		else
			ClearErrorQueue(memoryErrorQueue)
			if IsCritical.Memory then
				setCritical(nil,false)
				if State.Memory == "Error" then
					setState(nil,"Access")
				end
			end
			memoryRecoveryRunning = false
		end
	end)
end

OnError:Connect(function(pos, ErrorMessage, Name, Key, Data)
	-- Select the recent-error queue and latest error timestamp for the relevant storage type.
	local now = os.clock()
	local errorQueue

	if pos == 1 then
		errorQueue = dataErrorQueue
		dataLastErrorTime = now
	elseif pos == 2 then
		errorQueue = memoryErrorQueue
		memoryLastErrorTime = now
	else
		return
	end

	-- Keep only errors inside the current detection window, then record the new error.
	TrimExpiredErrors(errorQueue,now)
	errorQueue:enqueue({
		time = now,
		errorMessage = ErrorMessage,
		name = Name,
		key = Key,
		data = Data,
	})

	-- Retain only the number of entries needed for Critical detection so the queue cannot grow indefinitely.
	while errorQueue:getSize() > CRITICAL_ERROR_COUNT do
		errorQueue:dequeue()
	end

	-- Transition the storage service to Critical/Error when failures reach the threshold within the time window.
	if errorQueue:getSize() >= CRITICAL_ERROR_COUNT then
		if pos == 1 then
			setCritical(true,nil)
			setState("Error",nil)
		else
			setCritical(nil,true)
			setState(nil,"Error")
		end
	end

	StartErrorRecovery(pos)
end)

-- Check initial storage access and establish the service's overall state.
task.spawn(function()
	if RunService:IsStudio() then
		-- In Studio, report a 403 caused by disabled API Services clearly during initialization.
		local success,result = pcall(function()
			return game:GetService("DataStoreService"):GetGlobalDataStore():SetAsync("KrossSync_Chack",{Time=os.time(),JobID=game.JobId}) 
		end)

		if not success then
			if string.find(result,"403") ~= nil then
				setState("NoInternet","NoInternet")
				error(result)
				return
			end
		end

	end

	while true do
		-- Before readiness, check both service objects; after recovery, reduce the health-check frequency.
		if State.Total == "Access" then
			task.wait(5)
		elseif State.Total == "Error" then
			task.wait(1)
		elseif State.Total == "NotReady" then
			local IsOkay = IsStoreOkay("",nil)
			if IsOkay.Data == true then
				setState("Access",nil)
			end
			if IsOkay.Memory == true then
				setState(nil,"Access")
			end
		end
		task.wait()
	end	
end)

-- Temporarily block ordinary requests while the DataStore request budget is exhausted.
task.spawn(function()
	while true do task.wait(10)
		if State.Data == "NoAccess" then
			-- While blocked, use a real write check to determine whether access has recovered.
			local storeStatus = IsStoreOkay("Data","High")
			if storeStatus.Data then
				setState("Access",nil)
			end
		elseif dataErrorQueue:getSize() > 0 then
			-- Check for request-budget exhaustion only while recent DataStore errors exist.
			local writeBudget = DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.StandardWrite)
			local readBudget = DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.StandardRead)
			if writeBudget <= 1 or readBudget <= 1 then
				setState("NoAccess",nil)
			end
		end
	end
end)



return KrossSyncService
