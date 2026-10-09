
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
V.0.0.2

DataStore stores raw data for normal keys and permanent markers for deleted keys.
MemoryStore stores the full synchronization wrapper, including temporary memory and server lists.
Servers using the same key share the latest state and connected servers through MemoryStore.

--------------------------------------------------------------------------------

]]

-----------Settings to adjust for the target environment---------

-- Save persists data only when this much time has passed since the last DataStore save.
local SAVE_DATA_TIME = 60
-- Interval for checking changes written to MemoryStore by other servers.
local AUTO_GET_MEMORY_TIME = 15
-- Servers share the durable check schedule and verify each key every five minutes.
local DURABLE_CHECK_INTERVAL = 300
local DURABLE_CHECK_LEASE_TIME = 60
-- Time without further storage errors before error history and Critical state are reset.
local ERROR_RESET_TIME = 30
local CRITICAL_ERROR_COUNT = 5
-- Keep removal markers longer than the polling interval so stale servers cannot restore deleted data.
local REMOVAL_TOMBSTONE_MIN_TIME = AUTO_GET_MEMORY_TIME * 4
local REMOVAL_MARKER = "__krossSyncRemoved"
local VERIFIED_MISSING = {}

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

	-- Check whether the queue still contains items.
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
		-- Remove and return the oldest item.
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
		-- Read the oldest item without removing it.
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
	lastUpdate: number, -- Last MemoryStore synchronization time.
	dataCreateTime: number, -- Last DataStore save time.
	memory: MemTpl, -- Temporary data kept only in MemoryStore.
	data: DataTpl, -- Data persisted in DataStore.
	onlineServers: {[number]:string}, -- JobIds of servers currently synchronizing this key.
	dataRevision: number?, -- Base DataStore revision of this wrapper.
	dataSequence: number?, -- Sequence of MemoryStore data changes since that revision.
	__krossSyncDataCheckAfter: number?,
	__krossSyncDataCheckOwner: string?,
}
-- Synchronization instance and public method types for one StoreName.
export type KrossSync<MemTpl,DataTpl> = {
	-- nil retries until success; a number limits the number of attempts.
	MaxRetryTime:number|nil,
	-- Roblox storage objects and the settings used to create this instance.
	Store: DataStore,
	Map: MemoryStoreHashMap,
	MapName: string,
	DataTemplate: DataTpl,
	MemoryTemplate: MemTpl,
	ExpirationTime:number,
	-- Latest local cache and removal or pending-work state for each key.
	LastData: {[string]:Data<MemTpl, DataTpl>},
	RemovedKeys: {[string]:number},
	PendingDataSave: {[string]:boolean},
	PendingMemoryPublish: {[string]:{revision:number}},
	PendingMemoryRemoval: {[string]:{}},
	-- Local locks that prevent overlapping reads and writes for each key.
	IsGetting: {[string]:boolean},
	IsSaving: {[string]:boolean},
	---- Instance signals----
	OnNewData: signal.Signal<Data<MemTpl, DataTpl> >,
	OnGettingToggle: signal.Signal<boolean> ,
	OnSavingToggle: signal.Signal<boolean>,
	---- Read methods----
	Get: (self:KrossSync<MemTpl, DataTpl>, key:string, force:boolean)-> (Data<MemTpl?, DataTpl> | false, {Data:boolean,Memory:boolean}?),
	GetData: (self:KrossSync<MemTpl, DataTpl>, key:string, force:boolean, expectedData:Data<MemTpl, DataTpl>?, publishOnly:boolean?) -> (Data<nil, DataTpl> | nil | false ),
	GetMemory: (self:KrossSync<MemTpl, DataTpl>, key:string, force:boolean) -> (Data<MemTpl, DataTpl> | nil | false ),
	---- Save methods----
	Save: (self:KrossSync<MemTpl, DataTpl>, key:string, data:Data<MemTpl, DataTpl>|(old:Data<MemTpl, DataTpl>?)->(Data<MemTpl, DataTpl>?), expiration:number, force:boolean) -> (boolean),
	SaveData: (self:KrossSync<MemTpl, DataTpl>, key:string, data:Data<MemTpl, DataTpl>|(old:DataTpl?)->(DataTpl?), force:boolean) -> (boolean),
	SaveMemory: (self:KrossSync<MemTpl, DataTpl>, key:string, data:Data<MemTpl, DataTpl>|(old:Data<MemTpl, DataTpl>?)->(Data<MemTpl ,DataTpl>?), expiration:number, force:boolean, preserveDataVersion: boolean?, verifiedMissing: typeof(VERIFIED_MISSING)?, publishOnly:boolean?) -> (boolean),
	Set: (self:KrossSync<MemTpl, DataTpl>, key:string, data:Data<MemTpl, DataTpl>|(old:DataTpl?)->(DataTpl?), expiration:number?, force:boolean?) -> (boolean,boolean),
	SetMemory: (self:KrossSync<MemTpl, DataTpl>, key:string, data:Data<MemTpl, DataTpl>|(old:Data<MemTpl, DataTpl>?)->(Data<MemTpl, DataTpl>?), expiration:number?, force:boolean?, verifiedMissing: typeof(VERIFIED_MISSING)?, publishOnly:boolean?) -> boolean,
	---- Removal methods: Remove returns DataStore success, then MemoryStore success.----
	Remove: (self:KrossSync<MemTpl, DataTpl>, key:string) -> (boolean, boolean),
	RemoveData: (self:KrossSync<MemTpl, DataTpl>, key:string) -> boolean,
	RemoveMemory: (self:KrossSync<MemTpl, DataTpl>, key:string) -> boolean,
	---- Unsubscribe the current server----
	UnSync: (self:KrossSync<MemTpl, DataTpl>, key:string) -> boolean,
}

local rawError = error
local rawWarn = warn
local rawPrint = print

-- Prefix every log with the module name to distinguish it from other systems.
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

-- Fires when repeated errors change Critical state: overall flag and detailed state.
local OnCriticalToggle = signal()::signal.Signal<boolean,typeof(IsCritical)>
-- Fires when a storage request ultimately fails. Position 1 is DataStore; 2 is MemoryStore.
local OnError  = signal()::signal.Signal<number,string,string,string,any>
-- Internal signal that starts shutdown handling and polling for a new instance.
local OnNewKrossSync = signal()::signal.Signal<KrossSync<any,any>>

local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local HttpService = game:GetService("HttpService")
local uncachedGetOptions = Instance.new("DataStoreGetOptions")
uncachedGetOptions.UseCache = false


-- Keep only recent errors to detect repeated failures within a short window.
local dataErrorQueue = Queue.new()
local memoryErrorQueue = Queue.new()

--[[
	Retry storage requests with exponential backoff and randomized delays.
	nil maxRetries retries until success; a numeric limit still allows at least one attempt.
	action is protected by pcall; the caller must ensure errorAction does not raise an error.
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
	local jitter = (jitterPercent or 50) / 100 -- Convert the percentage to a fraction between 0 and 1.

	if not action then
		warn("[ExponentialJitterBackoff] action is nil")
		return false, "action is nil"
	end

	local attempt = 0
	local success: boolean
	local results: {any}

	while attempt < maxAttempts do

		-- Pack the pcall result to preserve the number of return values.
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

			-- Increase the delay exponentially and spread concurrent retries with jitter.
			local baseWait = math.pow(2,attempt)

			local waitTime = baseWait + (math.random() * baseWait * jitter)
			waitTime = math.min(waitTime, cap or math.huge)
			task.wait(waitTime)
		end
	end

	return false, results[2]
end


-- Deep-copy tables so templates and cached values do not share nested tables.
-- Assumes plain tables without cycles, suitable for DataStore serialization.
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

-- Fill only missing string keys from the template. Preserve existing values and array entries.
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

-- Reconcile the durable data and temporary memory fields with their respective templates.
local function ReconcileDataWithTemplates(data, dataTemplate, memoryTemplate)
	if type(data) ~= "table" then
		return data
	end

	ReconcileValueWithTemplate(data.data, dataTemplate)
	ReconcileValueWithTemplate(data.memory, memoryTemplate)
	return data
end

-- Check availability by obtaining storage objects or performing an actual write.
-- High checks send real requests, so use them only when needed.
local function IsStoreOkay(Type:nil|"Data"|"Memory",lvl:nil|"High" ):{Data:boolean|nil, Memory:boolean|nil}

	local function ChackDataStore(lvl)
		if lvl == "High" then
			-- Perform a write to check both API access and network availability.
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

-- Combine durable data and MemoryStore-only fields into one synchronization wrapper.
local function BuildData<memory,data>(lastUpdate,Data:data,Memory:memory,OnlineServers:{[number]:string},revision:number?,sequence:number?):Data<memory,data>
	return {lastUpdate=lastUpdate,
		dataCreateTime=os.time(),
		memory=Memory,
		data=Data,
		onlineServers=OnlineServers,
		dataRevision=revision or 0,
		dataSequence=sequence or 0,
	}
end

-- Older keys have no revision metadata, so their revision starts at 0.
local function GetDataRevision(keyInfo):number
	local metadata = keyInfo and keyInfo:GetMetadata()
	local revision = metadata and metadata.__krossSyncRevision
	return if type(revision) == "number" then revision else 0
end

-- Return the expiration time when a MemoryStore value is a removal marker.
-- Treat markers without an expiration, including older markers, as permanent removals.
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

-- Check locally cached removal state without making a network request.
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

-- Record a shared tombstone locally and immediately discard the old cache.
local function MarkKeyRemoved(self:KrossSync<unknown,unknown>,key:string,removedUntil:number)
	-- Do not replace a longer-lived removal record with a shorter one.
	local effectiveUntil = math.max(self.RemovedKeys[key] or 0,removedUntil)
	self.RemovedKeys[key] = effectiveUntil
	self.LastData[key] = nil
	self.PendingMemoryPublish[key] = nil

	-- Remove expired local records even when the key is never accessed again.
	if effectiveUntil < math.huge then
		task.delay(math.max(0,effectiveUntil - os.time()),function()
			if self.RemovedKeys[key] == effectiveUntil and effectiveUntil <= os.time() then
				self.RemovedKeys[key] = nil
			end
		end)
	end
end

-- Build a MemoryStore removal marker visible to other servers.
local function BuildRemovalTombstone(expiration:number)
	local removedAt = os.time()
	return {
		[REMOVAL_MARKER] = true,
		removedAt = removedAt,
		removedUntil = removedAt + expiration,
	}
end

-- Normalize the server list by removing invalid entries and duplicate JobIds.
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

-- Register the current server once in the normalized server list.
local function RegisterCurrentServer(onlineServers:{[number]:string}?):{[number]:string}
	local normalized = NormalizeOnlineServers(onlineServers)
	if table.find(normalized,game.JobId) == nil then
		table.insert(normalized,game.JobId)
	end

	return normalized
end

-- Check MemoryStore removal state after reading ordinary data from DataStore.
-- Return read success first, then the expiration time of an active tombstone.
local function ReadSharedRemoval(self:KrossSync<unknown,unknown>,key:string):(boolean,number?,boolean,any)
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
		return false,nil,false,nil
	end

	local removedUntil = GetActiveRemovalExpiration(result)
	if removedUntil then
		MarkKeyRemoved(self,key,removedUntil)
	end

	return true,removedUntil,result == nil or GetRemovalExpiration(result) ~= nil,result
end

-- DataStore removal markers never expire and cannot be overwritten by ordinary saves.
local function WriteDataRemovalTombstone(self:KrossSync<unknown,unknown>,key:string):boolean
	local success, result = ExponentialJitterBackoff(
		30,
		self.MaxRetryTime,
		nil,
		function()
			return self.Store:UpdateAsync(key,function(oldData,keyInfo)
				local userIds = keyInfo and keyInfo:GetUserIds() or {}
				local metadata = keyInfo and keyInfo:GetMetadata() or {}
				if GetRemovalExpiration(oldData) then
					return oldData,userIds,metadata
				end
				return {[REMOVAL_MARKER] = true, removedAt = os.time()},userIds,metadata
			end)
		end,
		function(attempt, errorMessage, cap)
			warn("Data removal marker failed:",key,errorMessage)
		end
	)

	if not success then
		OnError:Fire(1,result,self.Store.Name,key)
	else
		MarkKeyRemoved(self,key,math.huge)
	end

	return success
end

-- Retry durable saves from the latest local value when only the DataStore save failed.
-- Keep one worker per key and use the latest LastData after subsequent MemoryStore changes.
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
			local saved, reason = self:SaveData(key,latestData,true)
			if saved or reason == "stale" then
				self.PendingDataSave[key] = nil
				return
			end

			task.wait(5)
		end
	end)
end

-- Republish the same committed revision when only the shared cache publication failed.
local function PublishDurableData(self:KrossSync<unknown,unknown>,key:string,storedData:any,revision:number,expiration:number?,publishOnly:boolean?):boolean
	return self:SetMemory(key,function(old)
		if (old.dataRevision or 0) >= revision then
			return old
		end
		old.data = if type(storedData) == "table" then DeepCopyTable(storedData) else storedData
		old.dataRevision = revision
		old.dataSequence = 0
		old.dataCreateTime = os.time()
		return old
	end,expiration,true,nil,publishOnly)
end

local function ScheduleMemoryPublish(self:KrossSync<unknown,unknown>,key:string,storedData:any,revision:number,expiration:number?)
	local current = self.PendingMemoryPublish[key]
	if current and current.revision >= revision then
		return
	end
	local pending = {revision = revision}
	self.PendingMemoryPublish[key] = pending
	task.spawn(function()
		local deadline = os.time() + (expiration or self.ExpirationTime)
		while self.PendingMemoryPublish[key] == pending and os.time() < deadline do
			task.wait(5)
			if self.PendingMemoryPublish[key] ~= pending then
				return
			end
			if IsKeyLocallyRemoved(self,key) or PublishDurableData(self,key,storedData,revision,expiration,true) then
				if self.PendingMemoryPublish[key] == pending then
					self.PendingMemoryPublish[key] = nil
				end
				return
			end
		end
		if self.PendingMemoryPublish[key] == pending then
			self.PendingMemoryPublish[key] = nil
			warn("MemoryStore publish retry expired:",key)
		end
	end)
end

-------------------------------------------------------------------KrossSync instance API-------------------------------------


local KrossSync = {} ::KrossSync<unknown,unknown>
KrossSync.__index = KrossSync



-- Change a key's read lock and fire a signal only when its state changes.
function KrossSync:SetGetting(key,value)
	local wasGetting = self.IsGetting[key] == true
	local isGetting = value == true

	-- Remove completed lock entries instead of retaining false values indefinitely.
	self.IsGetting[key] = if isGetting then true else nil
	if wasGetting ~= isGetting then
		self.OnGettingToggle:Fire(isGetting)
	end
end

-- Change a key's write lock and remove completed lock entries.
function KrossSync:SetSaving(key,value)
	local wasSaving = self.IsSaving[key] == true
	local isSaving = value == true

	self.IsSaving[key] = if isSaving then true else nil
	if wasSaving ~= isSaving then
		self.OnSavingToggle:Fire(isSaving)
	end
end


-- Read MemoryStore first; otherwise restore durable data or create a key from the templates.
function KrossSync:Get(key,force)
	-- Prevent overlapping reads and writes for the same key. force does not bypass locks.
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
		-- Restore the full wrapper from durable data when MemoryStore has no value.
		local data2 = self:GetData(key,force)

		if (data2 ~= false) and (data2 ~= nil) then
			-- Return the restored wrapper and the recovery status of each storage service.
			return data2, {Data = true, Memory = data2.memory ~= nil}

		elseif data2 == nil then
			-- Create a new key from the templates when neither storage service contains a value.
			local Time = os.time()
			-- Store only data in DataStore and the full wrapper in MemoryStore.
			local d = self:SaveData(key, BuildData(Time, DeepCopyTable(self.DataTemplate), nil, {game.JobId}), force)
			if not d then
				return false, {Data=false, Memory=false}
			end
			local m = self:SaveMemory(key, BuildData(Time, DeepCopyTable(self.DataTemplate), DeepCopyTable(self.MemoryTemplate), {game.JobId}), self.ExpirationTime, force,nil,VERIFIED_MISSING)
			if IsKeyLocallyRemoved(self,key) then
				return false, {Data=false, Memory=false}
			end

			if m then
				return BuildData(Time, DeepCopyTable(self.DataTemplate), DeepCopyTable(self.MemoryTemplate), {game.JobId})
			else
				-- Return a status table so the caller can distinguish partial success.
				return BuildData(Time, DeepCopyTable(self.DataTemplate), nil, {game.JobId}), {Data=true, Memory=false}
			end

		end
	end

	return false
end


-- DataStore contains only the data field, not the full wrapper.
function KrossSync:GetData(key,force,expectedData,publishOnly)
	-- Check local removal state and per-key locks first.
	if IsKeyLocallyRemoved(self,key) or self.IsGetting[key] or self.IsSaving[key] then
		return false
	end
	-- Durable reads must also check MemoryStore tombstones to prevent deleted keys from returning.
	if force ~= true and (IsCritical.Data or IsCritical.Memory or State.Data ~= "Access" or State.Memory ~= "Access") then
		return false
	end

	self:SetGetting(key,true)

	local function action()
		return self.Store:GetAsync(key,uncachedGetOptions)
	end

	local function errorAction(attempt,result,cap)

		warn("GetData failed:", key, result)
	end

	local success, result, keyInfo = ExponentialJitterBackoff(
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
	if GetRemovalExpiration(result) then
		self:SetGetting(key,false)
		MarkKeyRemoved(self,key,math.huge)
		return false
	end

	local removalCheckSucceeded, removedUntil, memoryMissing, sharedData = ReadSharedRemoval(self,key)
	self:SetGetting(key,false)
	if not removalCheckSucceeded or removedUntil then
		return false
	end
	if expectedData and self.LastData[key] ~= expectedData then
		return false
	end

	if result == nil then
		-- nil means the key has not been created; it is not a request error.
		return nil
	end
	result = ReconcileValueWithTemplate(result, self.DataTemplate)
	local revision = GetDataRevision(keyInfo)
	local metadata = keyInfo and keyInfo:GetMetadata() or {}
	local reconciledData
	local function reconcileMemory(old)
		local oldRevision = old.dataRevision or 0
		local oldSequence = old.dataSequence or 0
		local sourceRevision = metadata.__krossSyncSourceRevision
		local sourceSequence = if sourceRevision == oldRevision then metadata.__krossSyncSourceSequence or 0 else 0
		if oldRevision <= revision
			and not ((oldRevision == revision or sourceRevision == oldRevision) and oldSequence > sourceSequence) then
			old.data = result
			old.dataRevision = revision
			old.dataSequence = if sourceRevision == revision then metadata.__krossSyncSourceSequence or 0 else 0
			old.dataCreateTime = os.time()
		end
		old.memory = old.memory or DeepCopyTable(self.MemoryTemplate)
		old.onlineServers = if publishOnly then NormalizeOnlineServers(old.onlineServers) else RegisterCurrentServer(old.onlineServers)
		reconciledData = ReconcileDataWithTemplates(old, self.DataTemplate, self.MemoryTemplate)
		return reconciledData
	end

	if publishOnly then
		local success = self:SaveMemory(key,reconcileMemory,self.ExpirationTime,force,true,VERIFIED_MISSING,true)
		return if success then reconciledData else false
	elseif self.LastData[key] then
		-- Reuse the shared wrapper read during the removal check to avoid unnecessary requests.
		local current = if memoryMissing then self.LastData[key] else ReconcileDataWithTemplates(sharedData, self.DataTemplate, self.MemoryTemplate)
		local onlineServers = NormalizeOnlineServers(current.onlineServers)
		if memoryMissing or not deepEqual(result,current.data) or revision ~= (current.dataRevision or 0)
			or table.find(onlineServers,game.JobId) == nil or not deepEqual(onlineServers,current.onlineServers) then
			local success = self:SaveMemory(key,reconcileMemory,nil,force,true,VERIFIED_MISSING)
			if not success then
				return false
			end
		else
			current.dataCreateTime = math.max(current.dataCreateTime or 0,self.LastData[key].dataCreateTime or 0)
			self.LastData[key] = current
		end


		return self.LastData[key]
	else
		-- Restore durable data while preserving the latest shared memory.
		local m = self:SaveMemory(key,reconcileMemory,self.ExpirationTime,force,true,VERIFIED_MISSING)
		if m == false then
			return false
		end
		return self.LastData[key]
	end
end


-- Read the shared wrapper and atomically register the current JobId if it is missing.
function KrossSync:GetMemory(key,force)
	-- Prevent other work from overwriting a key while it is being read.
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
		-- Without a local removal record, the MemoryStore value expired or was never created.
		if IsKeyLocallyRemoved(self,key) then
			return false
		end
		return nil
	end

	-- Do not cache an active tombstone; immediately mark the key as removed.
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

	-- Fill new template fields in older data and normalize the server list.
	local data = ReconcileDataWithTemplates(result, self.DataTemplate, self.MemoryTemplate)
	local normalizedServers = NormalizeOnlineServers(data.onlineServers)
	local needsRegistration = table.find(normalizedServers,game.JobId) == nil
	local needsNormalization = not deepEqual(normalizedServers,data.onlineServers)

	if needsRegistration or needsNormalization then
		-- Read the latest value through UpdateAsync so concurrent server registrations are preserved.
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


-- Update MemoryStore normally and persist data once the durable save interval has elapsed.
function KrossSync:Save(key,data,expiration,force)
	-- Accept only update functions or full wrappers.
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
		local snapshot = self.LastData[key]
		local d, reason = self:SaveData(key,snapshot,force)
		if d then
			-- Cancel earlier pending work because the latest value has been saved.
			self.PendingDataSave[key] = nil
			-- Defer the next durable save only for servers still observing this snapshot.
			self:SaveMemory(key,function(old)
				if (old.dataRevision or 0) == (snapshot.dataRevision or 0)
					and (old.dataSequence or 0) == (snapshot.dataSequence or 0) then
					old.dataCreateTime = math.max(old.dataCreateTime or 0,os.time())
				end
				return old
			end,expiration,force)
			return true
		elseif IsKeyLocallyRemoved(self,key) then
			return false
		elseif reason == "stale" then
			-- Do not retry an old snapshot when a newer durable value already exists.
			return true
		end

		-- The callback result is already committed to MemoryStore. Treat the logical save as successful
		-- so the caller does not replay it after false; retry only the durable save in the background.
		ScheduleDataSave(self,key)
		return true
	else
		-- Update only MemoryStore before the durable save interval has elapsed.
		return self:SaveMemory(key,data,expiration,force)
	end
end


-- Table input stores the wrapper's data field; function input receives the current durable data.
-- UpdateAsync callbacks can run repeatedly on conflicts, so they must not mutate external state.
function KrossSync:SaveData(key,data,force) self = self::KrossSync<unknown,unknown>
	if IsKeyLocallyRemoved(self,key) then
		return false
	end

	if self.IsGetting[key] or self.IsSaving[key] or (typeof(data)~="function" and typeof(data)~="table") then
		return false
	end
	if typeof(data) == "table" and data.data == nil then
		return false
	end
	-- Check the removal marker inside UpdateAsync for the same DataStore key.
	if force ~= true and (IsCritical.Data or State.Data ~= "Access") then
		return false
	end

	-- Keep the previous temporary state to restore the full local wrapper after a successful save.
	local oldLastData = self.LastData[key]
	local savedData
	local hasSavedData = false
	local blockedByDataRemoval = false
	local blockedByStaleData = false
	local blockedByConcurrentWrite = false
	local alreadySaved = false
	local committedRevision
	local operationId = if typeof(data) == "function" then HttpService:GenerateGUID(false) else nil
	local observedRevision
	local attempts = 0

	self:SetSaving(key,true)

	local function action()
		attempts += 1
		local retryRevision = if attempts > 1 then observedRevision else nil
		return self.Store:UpdateAsync(key,function(oldData,keyInfo)
			blockedByDataRemoval = GetRemovalExpiration(oldData) ~= nil
			blockedByStaleData = false
			blockedByConcurrentWrite = false
			alreadySaved = false
			hasSavedData = false
			if blockedByDataRemoval then
				return nil
			end

			local metadata = keyInfo and keyInfo:GetMetadata() or {}
			local currentRevision = GetDataRevision(keyInfo)
			if operationId then
				if metadata.__krossSyncOperationId == operationId then
					alreadySaved = true
					savedData = oldData
					hasSavedData = true
					committedRevision = currentRevision
					return nil
				end
				if retryRevision ~= nil and currentRevision ~= retryRevision then
					blockedByConcurrentWrite = true
					return nil
				end
				observedRevision = currentRevision
			end
			if typeof(data) == "table" then
				local baseRevision = data.dataRevision or 0
				local sequence = data.dataSequence or 0
				if metadata.__krossSyncSourceRevision == baseRevision then
					local savedSequence = metadata.__krossSyncSourceSequence or 0
					if sequence == savedSequence and deepEqual(data.data,oldData) then
						alreadySaved = true
						return nil
					elseif sequence <= savedSequence then
						blockedByStaleData = true
						return nil
					end
				elseif currentRevision ~= baseRevision then
					blockedByStaleData = true
					return nil
				end
				savedData = data.data
				metadata.__krossSyncSourceRevision = baseRevision
				metadata.__krossSyncSourceSequence = sequence
			else
				-- Function input transforms the current DataStore data directly.
				savedData = data(oldData)
				metadata.__krossSyncSourceRevision = nil
				metadata.__krossSyncSourceSequence = nil
			end
			if savedData == nil then
				return nil
			end
			hasSavedData = true
			committedRevision = currentRevision + 1
			metadata.__krossSyncRevision = committedRevision
			metadata.__krossSyncOperationId = operationId
			return savedData,keyInfo and keyInfo:GetUserIds() or {},metadata
		end)
	end


	local function errorAction(attempt,result,cap)
		warn("SaveData failed:", key, tostring(data), result)
	end

	local success, result, keyInfo = ExponentialJitterBackoff(
		30,
		self.MaxRetryTime,
		nil,
		action,
		errorAction
	)

	if success and blockedByDataRemoval then
		self:SetSaving(key,false)
		MarkKeyRemoved(self,key,math.huge)
		return false
	end

	self:SetSaving(key,false)
	if success and alreadySaved and operationId then
		result = savedData
	end

	if not success then
		OnError:Fire(1,result,self.Store.Name,key,data)
		return false
	elseif blockedByConcurrentWrite then
		return false,"uncertain"
	elseif blockedByStaleData then
		return false,"stale"
	elseif alreadySaved and not operationId then
		return true
	elseif result == nil or not hasSavedData then
		return false
	else
		-- Replace only data with the save result while preserving temporary fields and server lists.
		local lastData = oldLastData or BuildData(os.time(), DeepCopyTable(self.DataTemplate), nil, {game.JobId})
		local revision = if typeof(data) == "table" then data.dataRevision or 0 else (keyInfo and GetDataRevision(keyInfo) or committedRevision)
		local sequence = if typeof(data) == "table" then data.dataSequence or 0 else 0
		if typeof(data) == "table" and oldLastData and oldLastData.dataRevision == revision
			and (oldLastData.dataSequence or 0) > sequence then
			return true
		end
		self.LastData[key] = BuildData(lastData.dataCreateTime, savedData, lastData.memory, lastData.onlineServers,revision or committedRevision,sequence)

		return true
	end
end


-- Save the full synchronization wrapper to MemoryStore. Callbacks receive the latest wrapper.
function KrossSync:SaveMemory(key,data,expiration,force,preserveDataVersion,verifiedMissing,publishOnly)
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

	-- Keep a local fallback for an expired MemoryStore entry.
	local oldLastData = self.LastData[key]
	local savedMemoryData
	local hasSavedMemoryData = false
	local blockedByRemoval = false
	local blockedByNewerData = false
	local blockedByConcurrentWrite = false
	local missingMemory = false
	local removedUntil
	local operationId = HttpService:GenerateGUID(false)
	local observedMemoryRevision
	local attempts = 0

	self:SetSaving(key,true)

	local function action()
		attempts += 1
		local retryRevision = if attempts > 1 then observedMemoryRevision else nil
		-- Check tombstones and update the value atomically inside UpdateAsync.
		return self.Map:UpdateAsync(key,function(oldData)
			savedMemoryData = nil
			hasSavedMemoryData = false
			blockedByRemoval = false
			blockedByNewerData = false
			blockedByConcurrentWrite = false
			missingMemory = false
			removedUntil = GetActiveRemovalExpiration(oldData)

			if removedUntil then
				-- Never overwrite a removal marker with an ordinary save.
				blockedByRemoval = true
				return oldData
			elseif GetRemovalExpiration(oldData) then
				oldData = nil
			end
			if oldData == nil and verifiedMissing ~= VERIFIED_MISSING then
				missingMemory = true
				return nil
			end
			if oldData and oldData.__krossSyncMemoryOperation == operationId then
				savedMemoryData = oldData
				hasSavedMemoryData = true
				return oldData
			end
			local memoryRevision = oldData and oldData.__krossSyncMemoryRevision or 0
			if retryRevision ~= nil and memoryRevision ~= retryRevision then
				blockedByConcurrentWrite = true
				return nil
			end
			observedMemoryRevision = memoryRevision
			local fallbackData = if oldLastData then DeepCopyTable(oldLastData) else BuildData(os.time(), DeepCopyTable(self.DataTemplate), DeepCopyTable(self.MemoryTemplate), if publishOnly then {} else {game.JobId})
			local currentData = if oldData then DeepCopyTable(oldData) else fallbackData
			local previousData = if type(currentData.data) == "table" then DeepCopyTable(currentData.data) else currentData.data
			local previousRevision = currentData.dataRevision or 0
			local previousSequence = currentData.dataSequence or 0

			if typeof(data)== "function" then
				-- Pass the last local cache or a template wrapper to the callback when the entry is missing.
				savedMemoryData = data(currentData)
			elseif typeof(data)== "table" then
				-- Copy caller-owned tables and merge the latest server list.
				savedMemoryData = DeepCopyTable(data)
				if oldData and ((oldData.dataRevision or 0) > (savedMemoryData.dataRevision or 0)
					or ((oldData.dataRevision or 0) == (savedMemoryData.dataRevision or 0)
						and (oldData.dataSequence or 0) > (savedMemoryData.dataSequence or 0))) then
					blockedByNewerData = true
					return oldData
				end
				local currentServers = oldData and oldData.onlineServers or savedMemoryData.onlineServers
				savedMemoryData.onlineServers = if publishOnly then NormalizeOnlineServers(currentServers) else RegisterCurrentServer(currentServers)
			end

			if savedMemoryData == nil then
				return nil
			end
			-- Durable recovery preserves the revision determined by metadata.
			if preserveDataVersion ~= true then
				if (savedMemoryData.dataRevision or 0) > previousRevision then
					savedMemoryData.dataSequence = 0
				elseif not deepEqual(savedMemoryData.data,previousData) then
					savedMemoryData.dataRevision = previousRevision
					savedMemoryData.dataSequence = previousSequence + 1
				else
					savedMemoryData.dataRevision = previousRevision
					savedMemoryData.dataSequence = previousSequence
				end
			end

			-- Do not let temporary writes or external wrappers erase or postpone the shared check schedule.
			savedMemoryData.__krossSyncDataCheckAfter = oldData and oldData.__krossSyncDataCheckAfter or os.time() + DURABLE_CHECK_INTERVAL
			savedMemoryData.__krossSyncDataCheckOwner = oldData and oldData.__krossSyncDataCheckOwner
			savedMemoryData.__krossSyncMemoryRevision = memoryRevision + 1
			savedMemoryData.__krossSyncMemoryOperation = operationId
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
	elseif missingMemory then
		local recovered = self:GetData(key,force,nil,publishOnly)
		if recovered == false then
			return false
		end
		return self:SaveMemory(key,data,expiration,force,preserveDataVersion,VERIFIED_MISSING,publishOnly)
	elseif blockedByRemoval then
		MarkKeyRemoved(self,key,removedUntil or math.huge)
		return false
	elseif blockedByNewerData then
		return false
	elseif blockedByConcurrentWrite then
		return false
	elseif resultRemovedUntil then
		MarkKeyRemoved(self,key,resultRemovedUntil)
		return false
	elseif result == nil then
		return false
	else
		-- Republish the shared value without resubscribing a key released by UnSync.
		if hasSavedMemoryData and (not publishOnly or (oldLastData and self.LastData[key] == oldLastData)) then
			self.LastData[key] = result
		end

		return true
	end
end


-- Update only the temporary wrapper. The caller decides whether to retry a failure.
function KrossSync:SetMemory(key,data,expiration,force,verifiedMissing,publishOnly)
	return self:SaveMemory(key,data,expiration,force,nil,verifiedMissing,publishOnly)
end


-- Persist data first, then publish the committed value to MemoryStore.
-- Return DataStore success, then MemoryStore success.
function KrossSync:Set(key,data,expiration,force)
	if IsKeyLocallyRemoved(self,key) or self.IsGetting[key] or self.IsSaving[key] then
		return false,false
	end
	if typeof(data) ~= "function" and (typeof(data) ~= "table" or data.data == nil) then
		return false,false
	end
	if force ~= true and (IsCritical.Data or State.Data ~= "Access") then
		return false,false
	end

	local blockedByRemoval = false
	local blockedByStaleData = false
	local blockedByConcurrentWrite = false
	local alreadyApplied = false
	local committedRevision
	local appliedData
	local observedRevision
	local operationId = HttpService:GenerateGUID(false)
	local attempts = 0
	self:SetSaving(key,true)
	local success, storedData, keyInfo = ExponentialJitterBackoff(30,self.MaxRetryTime,nil,function()
		attempts += 1
		local retryRevision = if attempts > 1 then observedRevision else nil
		return self.Store:UpdateAsync(key,function(oldData,oldKeyInfo)
			blockedByRemoval = GetRemovalExpiration(oldData) ~= nil
			blockedByStaleData = false
			blockedByConcurrentWrite = false
			alreadyApplied = false
			if blockedByRemoval then
				return nil
			end
			local metadata = oldKeyInfo and oldKeyInfo:GetMetadata() or {}
			local currentRevision = GetDataRevision(oldKeyInfo)
			if metadata.__krossSyncOperationId == operationId then
				alreadyApplied = true
				appliedData = oldData
				committedRevision = currentRevision
				return nil
			end
			if retryRevision ~= nil and currentRevision ~= retryRevision then
				blockedByConcurrentWrite = true
				return nil
			end
			if typeof(data) == "table" and data.dataRevision ~= nil then
				local baseRevision = data.dataRevision
				local sequence = data.dataSequence or 0
				if metadata.__krossSyncSourceRevision == baseRevision then
					local savedSequence = metadata.__krossSyncSourceSequence or 0
					blockedByStaleData = sequence < savedSequence
						or (sequence == savedSequence and not deepEqual(data.data,oldData))
				else
					blockedByStaleData = baseRevision ~= GetDataRevision(oldKeyInfo)
				end
				if blockedByStaleData then
					return nil
				end
			end
			observedRevision = currentRevision

			local updatedData = if typeof(data) == "function" then data(oldData) else data.data
			if updatedData == nil then
				return nil
			end

			committedRevision = currentRevision + 1
			metadata.__krossSyncRevision = committedRevision
			metadata.__krossSyncOperationId = operationId
			metadata.__krossSyncSourceRevision = nil
			metadata.__krossSyncSourceSequence = nil
			return updatedData,oldKeyInfo and oldKeyInfo:GetUserIds() or {},metadata
		end)
	end,function(_,errorMessage)
		warn("Set failed:",key,errorMessage)
	end)
	self:SetSaving(key,false)

	if blockedByRemoval then
		MarkKeyRemoved(self,key,math.huge)
		return false,false
	end
	if blockedByStaleData then
		return false,false
	end
	if blockedByConcurrentWrite then
		return false,false
	end
	if not success then
		OnError:Fire(1,storedData,self.Store.Name,key,data)
		return false,false
	end
	if alreadyApplied then
		storedData = appliedData
	end
	if storedData == nil then
		return false,false
	end

	local metadata = keyInfo and keyInfo:GetMetadata()
	local revision = if alreadyApplied then committedRevision else metadata and metadata.__krossSyncRevision or committedRevision
	if type(revision) ~= "number" then
		return true,false
	end

	local shared = PublishDurableData(self,key,storedData,revision,expiration)
	if shared then
		local pending = self.PendingMemoryPublish[key]
		if pending and pending.revision <= revision then
			self.PendingMemoryPublish[key] = nil
		end
	else
		ScheduleMemoryPublish(self,key,storedData,revision,expiration)
	end

	return true,shared
end


-- Use UpdateAsync to order the tombstone atomically against other servers' writes.
local function SetRemovalTombstone(self:KrossSync<unknown,unknown>,key:string,expiration:number,retryLimit:number?):boolean
	local tombstone = BuildRemovalTombstone(expiration)
	local success, result = ExponentialJitterBackoff(
		30,
		retryLimit or self.MaxRetryTime,
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

-- Retry shared removal markers while this server is alive if durable removal already succeeded.
local function ScheduleMemoryRemoval(self:KrossSync<unknown,unknown>,key:string,expiration:number)
	if self.PendingMemoryRemoval[key] then
		return
	end

	local pending = {}
	self.PendingMemoryRemoval[key] = pending
	task.spawn(function()
		local deadline = os.time() + expiration
		while self.PendingMemoryRemoval[key] == pending and os.time() < deadline do
			task.wait(5)
			if self.PendingMemoryRemoval[key] ~= pending then
				return
			end
			if SetRemovalTombstone(self,key,expiration,1) then
				self.PendingMemoryRemoval[key] = nil
				return
			end
		end
		if self.PendingMemoryRemoval[key] == pending then
			self.PendingMemoryRemoval[key] = nil
			warn("MemoryStore removal marker retry expired:",key)
		end
	end)
end


-- The standalone DataStore removal API also leaves a permanent tombstone.
local function RemoveDataKey(self:KrossSync<unknown,unknown>, key:string):boolean
	return WriteDataRemovalTombstone(self,key)
end

-- Remove the MemoryStore entry itself without leaving a tombstone.
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

-- Commit the durable tombstone first, then mark the shared cache as removed.
function KrossSync:Remove(key)
	-- Block other local requests for this key during removal.
	if self.IsGetting[key] or self.IsSaving[key] then
		return false, false
	end

	self:SetSaving(key,true)

	-- Do not consider removal complete if the durable tombstone write failed.
	local dataRemoved = WriteDataRemovalTombstone(self,key)
	local memoryRemoved = false
	local tombstoneExpiration = math.max(self.ExpirationTime,REMOVAL_TOMBSTONE_MIN_TIME)
	if dataRemoved then
		memoryRemoved = SetRemovalTombstone(self,key,tombstoneExpiration)
		if memoryRemoved then
			self.PendingMemoryRemoval[key] = nil
		else
			ScheduleMemoryRemoval(self,key,tombstoneExpiration)
		end
	end

	self:SetSaving(key,false)
	self.IsGetting[key] = nil
	self.IsSaving[key] = nil

	return dataRemoved, memoryRemoved
end


-- Leave only a durable tombstone. Use Remove to mark the shared cache as removed too.
function KrossSync:RemoveData(key) local self = self :: KrossSync<unknown,unknown>
	if self.IsGetting[key] or self.IsSaving[key] then
		return false
	end

	self:SetSaving(key,true)
	local success = RemoveDataKey(self,key)

	if success then
		-- Prevent locally cached durable data from being reused after its removal.
		self.LastData[key] = nil
	end

	self:SetSaving(key,false)
	self.IsGetting[key] = nil
	self.IsSaving[key] = nil
	return success
end

-- Remove only MemoryStore. Remaining durable data may recreate the cache on the next Get.
function KrossSync:RemoveMemory(key) local self = self :: KrossSync<unknown,unknown>
	if self.IsGetting[key] or self.IsSaving[key] then
		return false
	end

	self:SetSaving(key,true)
	local success = RemoveMemoryKey(self,key)

	if success then
		-- Standalone MemoryStore removal also clears the local tombstone state.
		self.LastData[key] = nil
		self.RemovedKeys[key] = nil
		self.PendingMemoryPublish[key] = nil
	end

	self:SetSaving(key,false)
	self.IsGetting[key] = nil
	self.IsSaving[key] = nil
	return success
end


-- Remove the current JobId and final-save the latest data if this is the last server.
function KrossSync:UnSync(key)
	-- A key that is not synchronized cannot be unsubscribed.
	if not self.LastData[key] then
		return false
	end

	local LastData
	local function data(old:Data<unknown,unknown>)
		-- Remove every occurrence of the current JobId to normalize the server list.
		old.onlineServers = NormalizeOnlineServers(old.onlineServers)
		for i = #old.onlineServers,1,-1 do
			if old.onlineServers[i] == game.JobId then
				table.remove(old.onlineServers,i)
			end
		end
		LastData = old
		return old
	end
	-- Use force during shutdown to attempt cleanup even when global state is Error.
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
			-- Final-save the latest MemoryStore data when the last server leaves.
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
-- Expose overall and per-service access state and Critical flags.
KrossSyncService.State = State
KrossSyncService.IsCritical = IsCritical

---- Public signals----

-- Fires when repeated storage errors change Critical state.
KrossSyncService.OnCriticalToggle = OnCriticalToggle
-- Report failed requests with their position, error, store name, key, and input.
KrossSyncService.OnError  = OnError

-----------------------Instance creation---------------------

function KrossSyncService.get(StoreName,DataTemplate,MemoryTemplate,NormalExpirationTime)
	-- Share one instance per StoreName. Different template references are not accepted.
	if KrossSyncService.KrossSyncs[StoreName] then
		if KrossSyncService.KrossSyncs[StoreName].DataTemplate ~= DataTemplate or KrossSyncService.KrossSyncs[StoreName].MemoryTemplate ~= MemoryTemplate then
			return false
		end

		return KrossSyncService.KrossSyncs[StoreName]
	end

	-- Give each StoreName its own stores, cache, locks, and signals.
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
		PendingMemoryPublish = {},
		PendingMemoryRemoval = {},
		-- Per-key local locks
		IsGetting = {},
		IsSaving = {},
		---- Instance signals----
		OnNewData = signal(), -- Deliver the full wrapper when polling detects a data or memory change.
		OnGettingToggle = signal(), -- Report the start and end of reads.
		OnSavingToggle = signal(), -- Report the start and end of writes.
		-- TODO: Consider a signal identifying which storage service was overwritten.
	}

	self = setmetatable(self,KrossSync)::KrossSync<typeof(MemoryTemplate),typeof(DataTemplate)>

	-- Connect shutdown handling and polling before caching the service instance.
	OnNewKrossSync:Fire(self)
	KrossSyncService.KrossSyncs[StoreName] = self

	return self

end

-----------------------Internal state management-------------------
-- Either storage service being Critical makes Total Critical.
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

-- Update per-service state and derive the overall state by priority.
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

local function CheckDurableCache(self, key, expectedData)
	local now = os.time()
	local checkAfter = expectedData.__krossSyncDataCheckAfter
	if (checkAfter and checkAfter > now) or self.IsGetting[key] or self.IsSaving[key] then
		return expectedData
	end
	local owner = HttpService:GenerateGUID(false)
	self:SetGetting(key,true)
	local success, claimed = ExponentialJitterBackoff(5,2,nil,function()
		return self.Map:UpdateAsync(key,function(old)
			if not old or GetRemovalExpiration(old) then return nil end
			if old.__krossSyncDataCheckOwner == owner then return old end
			local currentAfter = old.__krossSyncDataCheckAfter
			if currentAfter and currentAfter > os.time() then return nil end
			old = DeepCopyTable(old)
			if not currentAfter then
				old.__krossSyncDataCheckAfter = os.time() + DURABLE_CHECK_INTERVAL
			else
				old.__krossSyncDataCheckOwner = owner
				old.__krossSyncDataCheckAfter = os.time() + DURABLE_CHECK_LEASE_TIME
			end
			return old
		end,self.ExpirationTime)
	end)
	self:SetGetting(key,false)
	if not success then
		OnError:Fire(2,claimed,self.MapName,key)
		return expectedData
	end
	if self.LastData[key] ~= expectedData then return nil end
	if not claimed or claimed.__krossSyncDataCheckOwner ~= owner then return expectedData end

	local refreshed = self:GetData(key,false,expectedData)
	if self.RemovedKeys[key] == math.huge then
		local expiration = math.max(self.ExpirationTime,REMOVAL_TOMBSTONE_MIN_TIME)
		if not SetRemovalTombstone(self,key,expiration,1) then
			ScheduleMemoryRemoval(self,key,expiration)
		end
		return nil
	end
	local finished, result = ExponentialJitterBackoff(5,2,nil,function()
		return self.Map:UpdateAsync(key,function(old)
			if not old or GetRemovalExpiration(old) or old.__krossSyncDataCheckOwner ~= owner then return nil end
			old = DeepCopyTable(old)
			old.__krossSyncDataCheckOwner = nil
			old.__krossSyncDataCheckAfter = os.time() + (if refreshed == false then AUTO_GET_MEMORY_TIME else DURABLE_CHECK_INTERVAL)
			return old
		end,self.ExpirationTime)
	end)
	if not finished then OnError:Fire(2,result,self.MapName,key) end
	return self.LastData[key]
end

OnNewKrossSync:Connect(function(KrossSync)
	-- Unsubscribe this server from every key on shutdown and final-save keys with no other servers.
	game:BindToClose(function()
		-- Finish cleanup within 25 seconds to leave room before Roblox's shutdown deadline.
		local CLOSE_DEADLINE = 25
		local CloseTime = os.time()
		for key,v in pairs(KrossSync.LastData) do
			-- Retry UnSync independently for each key so one failure does not block the others.
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

	-- Read from the latest cache after saves replace it; do not restore unsubscribed keys.
	local function AutoGetMemory(key, previousData)
		local activeData = KrossSync.LastData[key]
		if not activeData or not activeData.memory then
			return
		end
		previousData = activeData

		local memoryData = KrossSync:GetMemory(key,false)

		if memoryData == nil then
			-- Verify durable state before restoring a missing cache entry.
			if KrossSync.LastData[key] == previousData then
				local oldData = if type(previousData.data) == "table" then DeepCopyTable(previousData.data) else previousData.data
				local oldMemory = if type(previousData.memory) == "table" then DeepCopyTable(previousData.memory) else previousData.memory
				local recoveredData = KrossSync:GetData(key,false,previousData)
				if recoveredData and KrossSync.LastData[key] == recoveredData
					and (not deepEqual(oldData,recoveredData.data) or not deepEqual(oldMemory,recoveredData.memory)) then
					KrossSync.OnNewData:Fire(recoveredData)
				end
			end
			return
		elseif memoryData == false then
			return
		end
		-- Discard stale results if UnSync or Remove finished while GetMemory yielded.
		if KrossSync.LastData[key] ~= memoryData then
			return
		end
		memoryData = CheckDurableCache(KrossSync,key,memoryData)
		if not memoryData or KrossSync.LastData[key] ~= memoryData then return end

		-- Fire the change signal only when durable data or temporary memory changed.
		local memoryChanged = not deepEqual(previousData.memory,memoryData.memory)
		local dataChanged = not deepEqual(previousData.data,memoryData.data)
		memoryData.lastUpdate = os.time()
		memoryData.dataCreateTime = math.max(previousData.dataCreateTime or 0,memoryData.dataCreateTime or 0)
		KrossSync.LastData[key] = memoryData

		if memoryChanged or dataChanged then
			KrossSync.OnNewData:Fire(memoryData)
		end
	end

	-- Schedule the first read for keys cached before the instance was created.
	local tasks = {}::{[string]:thread}
	local LastGetTime = {}
	for key, data in pairs(KrossSync.LastData) do
		tasks[key] = task.spawn(function()
			task.wait(math.max(0, data.dataCreateTime+AUTO_GET_MEMORY_TIME - os.time()))
			AutoGetMemory(key,data)
			LastGetTime[key] = os.time()
			tasks[key] = nil
		end)
	end

	-- Use the last automatic read time to enforce a minimum interval per key.
	task.spawn(function()
		-- Wait for the initial scheduled reads before entering the polling loop.
		while task.wait() do
			local i = 0
			for key,thread in pairs(tasks) do
				i+=1 break
			end
			if i == 0 then break end
		end

		while true do

			-- Read all currently active local keys in parallel.
			for key, data in pairs(KrossSync.LastData) do
				tasks[key]  = task.spawn(function()
					task.wait(math.max(0, (LastGetTime[key] or 0) +  AUTO_GET_MEMORY_TIME - os.time()))
					task.wait(math.max(0, data.dataCreateTime + AUTO_GET_MEMORY_TIME - os.time()))
					AutoGetMemory(key,data)

					LastGetTime[key] = os.time()
					tasks[key] = nil
				end)

			end

			-- Wait for every read in this polling cycle to finish.
			while task.wait() do
				local i = 0
				for key,thread in pairs(tasks) do
					i+=1
					break
				end
				if i == 0 then break end
			end

			-- Discard polling timestamps for keys that have not been used for a long time.
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

-- Drop expired errors from the front of the detection queue.
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

-- Clear the corresponding error queue once the storage service recovers.
local function ClearErrorQueue(errorQueue)
	while not errorQueue:isEmpty() do
		errorQueue:dequeue()
	end
end

-- Run only one recovery monitor per storage service.
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

	-- Clear Critical state only after a quiet period without further errors.
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
	-- Select the recent-error queue and timestamp for the affected storage service.
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

	-- Drop expired entries before recording the new error.
	TrimExpiredErrors(errorQueue,now)
	errorQueue:enqueue({
		time = now,
		errorMessage = ErrorMessage,
		name = Name,
		key = Key,
		data = Data,
	})

	-- Keep only enough entries for Critical detection so the queue cannot grow indefinitely.
	while errorQueue:getSize() > CRITICAL_ERROR_COUNT do
		errorQueue:dequeue()
	end

	-- Set Critical and Error when recent errors reach the threshold.
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

-- Check initial storage access and derive the overall service state.
task.spawn(function()
	if RunService:IsStudio() then
		-- Report a Studio API Services 403 failure clearly during initialization.
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
		-- Check both services while starting and slow down checks once access is healthy.
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

-- Temporarily block ordinary requests while the DataStore budget is exhausted.
task.spawn(function()
	while true do task.wait(10)
		if State.Data == "NoAccess" then
			-- Check recovery with an actual write while the service is blocked.
			local storeStatus = IsStoreOkay("Data","High")
			if storeStatus.Data then
				setState("Access",nil)
			end
		elseif dataErrorQueue:getSize() > 0 then
			-- Inspect the request budget only after recent DataStore errors.
			local writeBudget = DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.StandardWrite)
			local readBudget = DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.StandardRead)
			if writeBudget <= 1 or readBudget <= 1 then
				setState("NoAccess",nil)
			end
		end
	end
end)



return KrossSyncService
