
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
V.0.1.0 (Alpha)

DataStore에는 일반 키의 data 필드만 저장하고 삭제된 키에는 영구 표식을 남긴다.
MemoryStore에는 임시 memory와 서버 목록을 포함한 전체 동기화 래퍼를 저장한다.
여러 서버가 같은 키를 사용할 때 MemoryStore를 통해 최신 상태와 접속 서버를 공유한다.

--------------------------------------------------------------------------------

]]

-----------사용 환경에 맞게 조절할 설정값---------

-- Save 호출 시 마지막 DataStore 저장으로부터 이 시간이 지난 경우에만 영구 데이터를 저장한다.
local SAVE_DATA_TIME = 60
-- 다른 서버가 MemoryStore에 반영한 변경을 확인하는 주기다.
local AUTO_GET_MEMORY_TIME = 15
-- 같은 키의 영구 값은 서버들이 검증 시각을 공유해 5분마다 확인한다.
local DURABLE_CHECK_INTERVAL = 300
local DURABLE_CHECK_LEASE_TIME = 60
-- 저장소 오류가 더 발생하지 않았을 때 오류 기록과 Critical 상태를 초기화하기까지의 시간이다.
local ERROR_RESET_TIME = 30
local CRITICAL_ERROR_COUNT = 5
-- 삭제 표식은 자동 조회 주기보다 충분히 오래 유지해 오래된 서버가 데이터를 되살리지 못하게 한다.
local REMOVAL_TOMBSTONE_MIN_TIME = AUTO_GET_MEMORY_TIME * 4
local REMOVAL_MARKER = "__krossSyncRemoved"
local VERIFIED_MISSING = {}

-----------------------------------외부 모듈
-- 값 변경 알림에 사용하는 Signal+ 모듈
---@module signal 
local signal = require(game.ReplicatedStorage.scr.Library.Signal) --Signal+ (v3) by Alexander Lindholt  (https://github.com/AlexanderLindholt/SignalPlus)

-- 저장소 오류 발생 시각을 순서대로 관리하는 간단한 FIFO 큐
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

	-- 큐에 처리할 항목이 남아 있는지 확인한다.
	local function isEmpty(self)
		return self._first > self._last 
	end

	local function enqueue(self, value)
		-- 앞쪽에 사용하지 않는 공간이 많이 쌓이면 배열을 압축한다.
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
		-- 가장 먼저 들어온 값을 제거하고 반환한다.
		-- 빈 큐에서는 꺼낼 항목이 없다.
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
		-- 값을 제거하지 않고 가장 오래된 항목을 확인한다.
		-- 빈 큐에서는 확인할 항목이 없다.
		if self:isEmpty() then
			warn("EmptyQueue")
			return nil
		end

		return self._queue[self._first]
	end

	local function getSize(self)
		return self._last - self._first + 1
	end

	-- 인덱스를 0과 -1로 시작해 빈 큐를 표현한다.
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


------------------------------------공용 타입

-- 저장소 접근 상태. Total은 DataStore와 MemoryStore 상태를 합친 값이다.
type StateType = "NotReady" | "NoInternet" | "NoAccess" | "Access" | "Error"
type State = {Total: StateType, Data: StateType, Memory: StateType}


-- MemoryStore에서 서버 간 공유하는 데이터 래퍼
export type Data<MemTpl,DataTpl> = {
	lastUpdate: number, -- 마지막 MemoryStore 동기화 시각
	dataCreateTime: number, -- 마지막 DataStore 저장 시각
	memory: MemTpl, -- MemoryStore에서만 유지하는 임시 데이터
	data: DataTpl, -- DataStore에 영구 저장하는 데이터
	onlineServers: {[number]:string}, -- 현재 이 키를 동기화 중인 서버 JobId 목록
	dataRevision: number?, -- 이 래퍼가 시작한 DataStore 버전
	dataSequence: number?, -- 해당 버전 이후 MemoryStore의 data 변경 순서
	__krossSyncDataCheckAfter: number?,
	__krossSyncDataCheckOwner: string?,
	__krossSyncMemoryRefreshAfter: number?,
}
-- StoreName 하나에 대응하는 동기화 인스턴스와 공개 메서드 타입
export type WorkReceipt = { Await: (self: WorkReceipt) -> ...any }

export type KrossSync<MemTpl,DataTpl> = {
	WaitForWorkResult: boolean,
	Closing: boolean,
	works: {[string]: any},
	-- nil이면 성공할 때까지 재시도하고, 숫자면 해당 횟수만큼 시도한다.
	MaxRetryTime:number|nil,
	-- 실제 Roblox 저장소 객체와 생성에 사용한 설정
	Store: DataStore,
	Map: MemoryStoreHashMap,
	MapName: string,
	DataTemplate: DataTpl,
	MemoryTemplate: MemTpl,
	ExpirationTime:number,
	-- 키별 최신 로컬 캐시와 삭제/후속 작업 상태
	LastData: {[string]:Data<MemTpl, DataTpl>},
	RemovedKeys: {[string]:number},
	PendingDataSave: {[string]:boolean},
	PendingMemoryPublish: {[string]:{revision:number, data:any, expiration:number?}},
	PendingMemoryRemoval: {[string]:{}},
	-- 키별 중복 조회/저장을 막는 로컬 잠금
	IsGetting: {[string]:boolean}, 
	IsSaving: {[string]:boolean}, 
	---- 인스턴스 신호----
	OnNewData: signal.Signal<Data<MemTpl, DataTpl> >,
	OnGettingToggle: signal.Signal<boolean> ,
	OnSavingToggle: signal.Signal<boolean>,
	---- 조회 함수----
	Get: (self:KrossSync<MemTpl, DataTpl>, key:string, force:boolean)-> (Data<MemTpl?, DataTpl> | false, {Data:boolean,Memory:boolean}?),
	GetData: (self:KrossSync<MemTpl, DataTpl>, key:string, force:boolean, expectedData:Data<MemTpl, DataTpl>?, publishOnly:boolean?) -> (Data<nil, DataTpl> | nil | false ),
	GetMemory: (self:KrossSync<MemTpl, DataTpl>, key:string, force:boolean) -> (Data<MemTpl, DataTpl> | nil | false ),
	---- 저장 함수----
	Save: (self:KrossSync<MemTpl, DataTpl>, key:string, data:Data<MemTpl, DataTpl>|(old:Data<MemTpl, DataTpl>?)->(Data<MemTpl, DataTpl>?), expiration:number?, force:boolean?, waitForResult:boolean?) -> (boolean | WorkReceipt, ((any) -> any)?, string?),
	SaveData: (self:KrossSync<MemTpl, DataTpl>, key:string, data:Data<MemTpl, DataTpl>|(old:DataTpl?)->(DataTpl?), force:boolean) -> (boolean),
	SaveMemory: (self:KrossSync<MemTpl, DataTpl>, key:string, data:Data<MemTpl, DataTpl>|(old:Data<MemTpl, DataTpl>?)->(Data<MemTpl ,DataTpl>?), expiration:number, force:boolean, preserveDataVersion: boolean?, verifiedMissing: typeof(VERIFIED_MISSING)?, publishOnly:boolean?) -> (boolean),
	Set: (self:KrossSync<MemTpl, DataTpl>, key:string, data:Data<MemTpl, DataTpl>|(old:DataTpl?)->(DataTpl?), expiration:number?, force:boolean?, waitForResult:boolean?) -> (boolean | WorkReceipt, boolean?, ((any) -> any)?, string?),
	SetMemory: (self:KrossSync<MemTpl, DataTpl>, key:string, data:Data<MemTpl, DataTpl>|(old:Data<MemTpl, DataTpl>?)->(Data<MemTpl, DataTpl>?), expiration:number?, force:boolean?, verifiedMissing: typeof(VERIFIED_MISSING)?, publishOnly:boolean?) -> boolean,
	---- 삭제 함수: Remove 반환값 순서는 DataStore, MemoryStore 성공 여부다.----
	Remove: (self:KrossSync<MemTpl, DataTpl>, key:string, waitForResult:boolean?) -> (boolean | WorkReceipt, boolean?, ((any) -> any)?, string?),
	RemoveData: (self:KrossSync<MemTpl, DataTpl>, key:string) -> boolean,
	RemoveMemory: (self:KrossSync<MemTpl, DataTpl>, key:string) -> boolean,
	---- 현재 서버 동기화 해제----
	UnSync: (self:KrossSync<MemTpl, DataTpl>, key:string) -> boolean,
}

local rawError = error
local rawWarn = warn
local rawPrint = print

-- 모든 로그 앞에 모듈 이름을 붙여 다른 시스템 로그와 구분한다.
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

-- 반복 오류로 Critical 상태가 바뀔 때 발생한다. (전체 여부, 세부 상태)
local OnCriticalToggle = signal()::signal.Signal<boolean,typeof(IsCritical)>
-- 저장소 요청이 최종 실패할 때 발생한다. 위치는 1=DataStore, 2=MemoryStore다.
local OnError  = signal()::signal.Signal<number,string,string,string,any>
-- 새 KrossSync 인스턴스의 종료 처리와 자동 동기화를 시작하는 내부 신호
local OnNewKrossSync = signal()::signal.Signal<KrossSync<any,any>>

local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local HttpService = game:GetService("HttpService")
local uncachedGetOptions = Instance.new("DataStoreGetOptions")
uncachedGetOptions.UseCache = false


-- 최근 오류만 보관해 짧은 시간에 반복되는 장애를 감지한다.
local dataErrorQueue = Queue.new()
local memoryErrorQueue = Queue.new()

--[[
	지수 백오프와 무작위 지연을 적용해 저장소 요청을 재시도한다.
	maxRetries가 nil이면 성공할 때까지 재시도하며, 숫자라면 최소 한 번은 실행한다.
	action은 내부에서 pcall로 보호되지만 errorAction은 호출자가 오류가 나지 않게 작성해야 한다.
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
	local jitter = (jitterPercent or 50) / 100 -- 백분율을 0~1 범위로 변환한다.

	-- 실행할 작업이 없으면 재시도를 시작하지 않는다.
	if not action then
		warn("[ExponentialJitterBackoff] action is nil")
		return false, "action is nil"
	end

	local attempt = 0
	local success: boolean
	local results: {any}

	while attempt < maxAttempts do

		-- 반환값 개수를 보존하기 위해 pcall 결과를 table.pack으로 받는다.
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

			-- 재시도 한도에 도달하면 마지막 오류를 반환한다.
			if attempt >= maxAttempts then
				return false, errorMessage
			end

			-- 2의 지수 형태로 대기 시간을 늘리고 동시에 몰리는 요청을 jitter로 분산한다.
			local baseWait = math.pow(2,attempt)

			local waitTime = baseWait + (math.random() * baseWait * jitter)
			waitTime = math.min(waitTime, cap or math.huge)
			task.wait(waitTime)
		end
	end

	return false, results[2]
end


-- 템플릿과 캐시가 같은 중첩 테이블을 공유하지 않도록 재귀 복사한다.
-- DataStore에 넣을 수 있는 순환 참조 없는 일반 테이블을 전제로 한다.
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

-- 두 값 또는 중첩 테이블의 내용을 재귀적으로 비교한다.
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

-- 저장 데이터에 템플릿의 누락된 문자열 키만 채운다. 기존 값과 배열 항목은 보존한다.
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

-- 값과 템플릿이 모두 테이블일 때만 구조를 보충한다.
local function ReconcileValueWithTemplate(value, template)
	if type(value) == "table" and type(template) == "table" then
		ReconcileTable(value, template)
	end
	return value
end

-- MemoryStore 래퍼의 영구 데이터와 임시 데이터를 각각의 템플릿으로 보충한다.
local function ReconcileDataWithTemplates(data, dataTemplate, memoryTemplate)
	if type(data) ~= "table" then
		return data
	end

	ReconcileValueWithTemplate(data.data, dataTemplate)
	ReconcileValueWithTemplate(data.memory, memoryTemplate)
	return data
end

-- 저장소 객체 생성 또는 실제 쓰기를 통해 사용 가능 여부를 확인한다.
-- High 검사는 실제 요청을 보내므로 필요한 경우에만 사용한다.
local function IsStoreOkay(Type:nil|"Data"|"Memory",lvl:nil|"High" ):{Data:boolean|nil, Memory:boolean|nil}

	local function ChackDataStore(lvl)
		if lvl == "High" then
			-- 실제 쓰기를 수행해 API 접근 권한과 네트워크 상태를 함께 확인한다.
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
			-- 짧은 만료 시간을 사용해 상태 확인용 값이 오래 남지 않게 한다.
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

-- DataStore 값과 MemoryStore 전용 값을 하나의 동기화 래퍼로 구성한다.
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

-- 저장 이력이 없는 키의 버전은 0이다.
local function GetDataRevision(keyInfo):number
	local metadata = keyInfo and keyInfo:GetMetadata()
	local revision = metadata and metadata.__ksRev
	return if type(revision) == "number" then revision else 0
end

-- MemoryStore 값이 삭제 표식이면 만료 시각을 반환한다.
-- 영구 삭제 표식에는 만료 시각이 없다.
local function GetRemovalExpiration(value:any):number?
	if type(value) ~= "table" or value[REMOVAL_MARKER] ~= true then
		return nil
	end

	if type(value.removedUntil) == "number" then
		return value.removedUntil
	end

	return math.huge
end

-- 아직 만료되지 않은 삭제 표식만 반환한다.
local function GetActiveRemovalExpiration(value:any):number?
	local removedUntil = GetRemovalExpiration(value)
	if removedUntil and removedUntil > os.time() then
		return removedUntil
	end

	return nil
end

-- 네트워크 조회 없이 로컬에 캐시된 삭제 상태를 확인한다.
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

-- 공유 tombstone을 로컬에 기록하고 기존 캐시를 즉시 폐기한다.
local function MarkKeyRemoved(self:KrossSync<unknown,unknown>,key:string,removedUntil:number)
	-- 더 늦게 만료되는 삭제 기록을 짧은 기록으로 덮어쓰지 않는다.
	local effectiveUntil = math.max(self.RemovedKeys[key] or 0,removedUntil)
	self.RemovedKeys[key] = effectiveUntil
	self.LastData[key] = nil
	self.PendingMemoryPublish[key] = nil

	-- 접근이 다시 오지 않는 키도 만료 후 로컬 테이블에서 제거한다.
	if effectiveUntil < math.huge then
		task.delay(math.max(0,effectiveUntil - os.time()),function()
			if self.RemovedKeys[key] == effectiveUntil and effectiveUntil <= os.time() then
				self.RemovedKeys[key] = nil
			end
		end)
	end
end

-- 여러 서버가 확인할 수 있는 MemoryStore 삭제 표식을 만든다.
local function BuildRemovalTombstone(expiration:number)
	local removedAt = os.time()
	return {
		[REMOVAL_MARKER] = true,
		removedAt = removedAt,
		removedUntil = removedAt + expiration,
	}
end

-- 잘못된 값과 중복 JobId를 제거해 서버 목록을 정규화한다.
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

-- 정규화된 서버 목록에 현재 서버를 한 번만 등록한다.
local function RegisterCurrentServer(onlineServers:{[number]:string}?):{[number]:string}
	local normalized = NormalizeOnlineServers(onlineServers)
	if table.find(normalized,game.JobId) == nil then
		table.insert(normalized,game.JobId)
	end

	return normalized
end

-- DataStore에서 일반 데이터를 읽은 뒤 MemoryStore 삭제 상태도 확인한다.
-- 첫 번째 반환값은 조회 성공 여부이며 두 번째 값은 활성 tombstone 만료 시각이다.
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

	-- 공유 삭제 상태를 확인하지 못하면 진행하지 않는다.
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

-- DataStore의 삭제 표식은 만료되지 않으며 일반 저장으로 덮어쓰지 못한다.
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

	-- 영구 저장소가 삭제를 확인한 뒤에만 로컬 삭제 상태를 기록한다.
	if not success then
		OnError:Fire(1,result,self.Store.Name,key)
	else
		MarkKeyRemoved(self,key,math.huge)
	end

	return success
end

-- MemoryStore 저장이 확정된 뒤 DataStore 저장만 실패한 키를 최신 로컬 값으로 다시 저장한다.
-- 키마다 작업을 하나만 유지하며, 후속 MemoryStore 변경이 있으면 재시도 시 최신 LastData를 사용한다.
local function ScheduleDataSave(self:KrossSync<unknown,unknown>,key:string)
	if self.PendingDataSave[key] then
		return
	end

	self.PendingDataSave[key] = true
	task.spawn(function()
		while self.PendingDataSave[key] do
			-- 삭제 또는 UnSync로 로컬 값이 사라지면 재시도를 중단한다.
			if IsKeyLocallyRemoved(self,key) or self.LastData[key] == nil then
				self.PendingDataSave[key] = nil
				return
			end

			local latestData = DeepCopyTable(self.LastData[key])
			local saved, reason = self:SaveData(key,latestData,true)
			-- 더 최신 영구 값이 있으면 이 스냅샷은 다시 저장하지 않는다.
			if saved or reason == "stale" then
				self.PendingDataSave[key] = nil
				return
			end

			task.wait(5)
		end
	end)
end

-- 영구 저장은 끝났지만 공유 캐시 반영만 실패한 값을 같은 버전으로 재전달한다.
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
	local pending = {revision = revision, data = storedData, expiration = expiration}
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
		-- 재시도 시간이 끝나면 보류한 캐시 반영을 정리한다.
		if self.PendingMemoryPublish[key] == pending then
			self.PendingMemoryPublish[key] = nil
			warn("MemoryStore publish retry expired:",key)
		end
	end)
end

-------------------------------------------------------------------KrossSync 인스턴스 API-------------------------------------


local KrossSync = {} ::KrossSync<unknown,unknown>
KrossSync.__index = KrossSync



-- 키의 조회 잠금 상태를 바꾸고 실제 상태가 변했을 때만 신호를 발생시킨다.
function KrossSync:SetGetting(key,value)
	local wasGetting = self.IsGetting[key] == true
	local isGetting = value == true

	-- 완료된 키는 false로 남겨 두지 않아 장시간 실행 서버의 키 누적을 막는다.
	self.IsGetting[key] = if isGetting then true else nil
	if wasGetting ~= isGetting then
		self.OnGettingToggle:Fire(isGetting)
	end
end

-- 키의 저장 잠금 상태를 바꾸고 완료된 잠금 항목은 테이블에서 제거한다.
function KrossSync:SetSaving(key,value)
	local wasSaving = self.IsSaving[key] == true
	local isSaving = value == true

	self.IsSaving[key] = if isSaving then true else nil
	if wasSaving ~= isSaving then
		self.OnSavingToggle:Fire(isSaving)
	end
end


-- MemoryStore를 우선 조회하고, 없으면 DataStore에서 복구하거나 템플릿으로 새 데이터를 만든다.
local function IsWorkBlocked(self, key)
	local work = self.works[key]
	return work ~= nil and work.owner ~= coroutine.running()
end

function KrossSync:Get(key,force)
	-- 같은 키에서 조회와 저장이 겹치지 않게 한다. force도 잠금은 우회하지 않는다.
	if IsWorkBlocked(self,key) or self.IsGetting[key] or self.IsSaving[key] then
		return false
	end
	-- force는 서비스 상태 검사만 건너뛰며 잠금은 유지한다.
	if force ~= true and (IsCritical.Total or State.Total ~= "Access") then
		return false
	end

	-- 가장 최신 서버 간 상태가 있는 MemoryStore를 먼저 확인한다.
	local memory = self:GetMemory(key,force)

	if (memory ~= false) and (memory ~= nil) then
		return memory

	elseif memory == nil then
		-- MemoryStore에 값이 없으면 영구 데이터로 전체 래퍼를 복구한다.
		local data2 = self:GetData(key,force)

		if (data2 ~= false) and (data2 ~= nil) then
			-- GetData가 복구한 래퍼와 각 저장소 복구 여부를 반환한다.
			return data2, {Data = true, Memory = data2.memory ~= nil}

		elseif data2 == nil then
			-- 양쪽 저장소에 값이 전혀 없으면 템플릿으로 새 키를 생성한다.
			local Time = os.time()
			-- DataStore에는 memory 없이 data만, MemoryStore에는 전체 래퍼를 기록한다.
			local d = self:SaveData(key, BuildData(Time, DeepCopyTable(self.DataTemplate), nil, {game.JobId}), force)
			-- 최초 영구 저장에 실패하면 공유 데이터를 생성하지 않는다.
			if not d then
				return false, {Data=false, Memory=false}
			end
			local m = self:SaveMemory(key, BuildData(Time, DeepCopyTable(self.DataTemplate), DeepCopyTable(self.MemoryTemplate), {game.JobId}), self.ExpirationTime, force,nil,VERIFIED_MISSING)
			-- 동시에 삭제되었다면 생성한 값을 반환하지 않는다.
			if IsKeyLocallyRemoved(self,key) then
				return false, {Data=false, Memory=false}
			end

			if m then
				return self.LastData[key]
			else
				-- 부분 성공도 호출자가 구분할 수 있도록 상태 테이블을 함께 반환한다.
				return BuildData(Time, DeepCopyTable(self.DataTemplate), nil, {game.JobId}), {Data=true, Memory=false}
			end	

		end
	end

	return false
end


-- DataStore에는 전체 래퍼가 아니라 data 필드만 저장되어 있다.
function KrossSync:GetData(key,force,expectedData,publishOnly)
	-- 로컬 삭제 상태와 키별 잠금을 먼저 확인한다.
	if IsKeyLocallyRemoved(self,key) or IsWorkBlocked(self,key) or self.IsGetting[key] or self.IsSaving[key] then
		return false
	end
	-- 삭제된 키의 부활을 막기 위해 DataStore 읽기에도 MemoryStore tombstone 확인이 필요하다.
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

	-- 읽기 잠금을 풀고 DataStore의 최종 오류를 알린다.
	if not success then
		self:SetGetting(key,false)
		warn("GetData failed:", key, result)
		OnError:Fire(1,result,self.Store.Name,key)
		return false
	end
	-- 삭제된 데이터를 복구하지 않고 영구 삭제 표식을 기록한다.
	if GetRemovalExpiration(result) then
		self:SetGetting(key,false)
		MarkKeyRemoved(self,key,math.huge)
		return false
	end

	local removalCheckSucceeded, removedUntil, memoryMissing, sharedData = ReadSharedRemoval(self,key)
	self:SetGetting(key,false)
	-- 공유 삭제 확인에 실패하거나 표식이 있으면 복구하지 않는다.
	if not removalCheckSucceeded or removedUntil then
		return false
	end
	-- 기대한 로컬 스냅샷이 바뀌었다면 복구 결과를 사용하지 않는다.
	if expectedData and self.LastData[key] ~= expectedData then
		return false
	end

	if result == nil then
		-- nil은 오류가 아니라 아직 생성되지 않은 키를 뜻한다.
		return nil
	end
	result = ReconcileValueWithTemplate(result, self.DataTemplate)
	local revision = GetDataRevision(keyInfo)
	local metadata = keyInfo and keyInfo:GetMetadata() or {}
	local reconciledData
	local function reconcileMemory(old)
		local oldRevision = old.dataRevision or 0
		local oldSequence = old.dataSequence or 0
		local sourceRevision = metadata.__ksSrcRev
		local sourceSequence = if sourceRevision == oldRevision then metadata.__ksSrcSeq or 0 else 0
		if oldRevision <= revision
			and not ((oldRevision == revision or sourceRevision == oldRevision) and oldSequence > sourceSequence) then
			old.data = result
			old.dataRevision = revision
			old.dataSequence = if sourceRevision == revision then metadata.__ksSrcSeq or 0 else 0
			old.dataCreateTime = os.time()
		end
		if old.memory == nil then old.memory = DeepCopyTable(self.MemoryTemplate) end
		old.onlineServers = if publishOnly then NormalizeOnlineServers(old.onlineServers) else RegisterCurrentServer(old.onlineServers)
		reconciledData = ReconcileDataWithTemplates(old, self.DataTemplate, self.MemoryTemplate)
		return reconciledData
	end

	if publishOnly then
		local success = self:SaveMemory(key,reconcileMemory,self.ExpirationTime,force,true,VERIFIED_MISSING,true)
		return if success then reconciledData else false
	elseif self.LastData[key] then
		-- 삭제 확인에서 읽은 공유 래퍼를 재사용해 불필요한 조회와 쓰기를 피한다.
		local current = if memoryMissing then self.LastData[key] else ReconcileDataWithTemplates(sharedData, self.DataTemplate, self.MemoryTemplate)
		local onlineServers = NormalizeOnlineServers(current.onlineServers)
		if memoryMissing or not deepEqual(result,current.data) or revision ~= (current.dataRevision or 0)
			or table.find(onlineServers,game.JobId) == nil or not deepEqual(onlineServers,current.onlineServers) then
			local success = self:SaveMemory(key,reconcileMemory,nil,force,true,VERIFIED_MISSING)
			-- 캐시 갱신에 실패하면 복구 성공으로 반환하지 않는다.
			if not success then
				return false
			end
		else
			current.dataCreateTime = math.max(current.dataCreateTime or 0,self.LastData[key].dataCreateTime or 0)
			self.LastData[key] = current
		end
		
		
		return self.LastData[key]
	else
		-- 최신 공유 memory를 보존하면서 영구 data를 복구한다.
		local m = self:SaveMemory(key,reconcileMemory,self.ExpirationTime,force,true,VERIFIED_MISSING)
		-- 복구한 값을 캐시에 기록하지 못하면 실패를 반환한다.
		if m == false then
			return false
		end
		return self.LastData[key]
	end
end


-- 서버 간 공유 래퍼를 읽고 현재 서버의 JobId가 빠졌다면 원자적으로 등록한다.
function KrossSync:GetMemory(key,force) 
	-- 조회 중인 키를 다른 작업이 동시에 덮어쓰지 않게 한다.
	if IsWorkBlocked(self,key) or self.IsGetting[key] or self.IsSaving[key] then
		return false
	end
	-- MemoryStore가 사용 불가 또는 위험 상태면 일반 조회를 거부한다.
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

	-- 저장소 오류는 정상적으로 조회한 캐시 누락과 다르다.
	if not success then

		warn("GetMemory failed:", key, result)
		OnError:Fire(2,result,self.MapName,key)
		return false
	end

	if result == nil then
		-- 로컬 삭제 기록이 없다면 MemoryStore 만료 또는 미생성 상태다.
		if IsKeyLocallyRemoved(self,key) then
			return false
		end
		return nil
	end

	-- 활성 tombstone은 캐시에 저장하지 않고 즉시 삭제 상태로 전환한다.
	local removedUntil = GetActiveRemovalExpiration(result)
	if removedUntil then
		MarkKeyRemoved(self,key,removedUntil)
		return false
	-- 만료된 공유 삭제 표식은 유효한 값이 아니라 캐시 누락이다.
	elseif GetRemovalExpiration(result) then
		self.RemovedKeys[key] = nil
		return nil
	elseif IsKeyLocallyRemoved(self,key) then
		return false
	end

	-- 템플릿 필드를 채우고 서버 목록을 정리한다.
	local data = ReconcileDataWithTemplates(result, self.DataTemplate, self.MemoryTemplate)
	local normalizedServers = NormalizeOnlineServers(data.onlineServers)
	local needsRegistration = table.find(normalizedServers,game.JobId) == nil
	local needsNormalization = not deepEqual(normalizedServers,data.onlineServers)

	if needsRegistration or needsNormalization then
		-- UpdateAsync로 최신 값을 다시 받아 다른 서버의 동시 등록을 덮어쓰지 않는다.
		local saved = self:SaveMemory(key,function(oldData)
			local latestData = ReconcileDataWithTemplates(oldData or data, self.DataTemplate, self.MemoryTemplate)
			latestData.onlineServers = RegisterCurrentServer(latestData.onlineServers)
			return latestData
		end,self.ExpirationTime,force)

		-- 서버 등록에 실패하면 등록된 래퍼로 반환하지 않는다.
		if not saved then
			return false
		end

		return self.LastData[key]
	end

	data.onlineServers = normalizedServers
	self.LastData[key] = data
	return data

end


-- 평소에는 MemoryStore를 갱신하고, 영구 저장 주기가 지난 경우 data 필드도 DataStore에 저장한다.
local function SaveNow(self,key,data,expiration,force)
	-- 함수형 갱신과 전체 래퍼 입력만 허용한다.
	if IsWorkBlocked(self,key) or self.IsGetting[key] or self.IsSaving[key] or (typeof(data)~="function" and typeof(data)~="table") then
		return false
	end
	-- 저장소 상태가 준비되지 않으면 일반 저장을 중단한다.
	if force ~= true and (IsCritical.Total == true or State.Total ~= "Access") then
		return false
	end

	expiration = expiration or self.ExpirationTime

	if self.LastData[key] and self.LastData[key].dataCreateTime + SAVE_DATA_TIME <= os.time() then

		-- 공유 메모리를 먼저 갱신한 후 확정된 data 필드를 영구 저장한다.
		local m, reason = self:SaveMemory(key,data,expiration,force)
		-- MemoryStore 저장에 실패하면 영구 저장을 시도하지 않고 실패를 전달한다.
		if not m then
			return false,reason
		end
		local snapshot = self.LastData[key]
		local d, reason = self:SaveData(key,snapshot,force)
		if d then
			-- 이전에 예약된 작업이 있더라도 최신 값이 저장됐으므로 취소한다.
			self.PendingDataSave[key] = nil
			-- 같은 스냅샷을 보는 서버만 다음 영구 저장 시각을 늦춘다.
			self:SaveMemory(key,function(old)
				if (old.dataRevision or 0) == (snapshot.dataRevision or 0)
					and (old.dataSequence or 0) == (snapshot.dataSequence or 0) then
					old.dataCreateTime = math.max(old.dataCreateTime or 0,os.time())
				end
				return old
			end,expiration,force)
			return true
		-- 삭제된 키에는 영구 저장 재시도를 예약하지 않는다.
		elseif IsKeyLocallyRemoved(self,key) then
			return false
		elseif reason == "stale" then
			-- 이미 더 새로운 영구 값이 있으므로 오래된 스냅샷을 재시도하지 않는다.
			return true
		end

		-- MemoryStore에는 이미 함수 결과가 반영됐다. false를 반환해 호출자가 같은 함수를
		-- 다시 실행하지 않도록 논리적 저장은 성공으로 처리하고 영구 저장만 백그라운드에서 재시도한다.
		ScheduleDataSave(self,key)
		return true
	else
		-- 영구 저장 주기 전에는 빠른 MemoryStore 갱신만 수행한다.
		return self:SaveMemory(key,data,expiration,force)
	end
end


-- table 입력은 래퍼의 data 필드만 저장한다. 함수 입력은 DataStore의 기존 data 값을 받는다.
-- UpdateAsync 콜백은 충돌 시 여러 번 호출될 수 있으므로 외부 상태를 변경하지 않는 함수여야 한다.
function KrossSync:SaveData(key,data,force) self = self::KrossSync<unknown,unknown>
	-- 로컬에서 삭제가 확인된 키는 저장하지 않는다.
	if IsKeyLocallyRemoved(self,key) then
		return false
	end

	-- 잠금을 잡기 전에 겹치는 작업과 잘못된 입력을 거부한다.
	if IsWorkBlocked(self,key) or self.IsGetting[key] or self.IsSaving[key] or (typeof(data)~="function" and typeof(data)~="table") then
		return false
	end
	-- 전체 래퍼 입력에는 영구 저장할 data 필드가 있어야 한다.
	if typeof(data) == "table" and data.data == nil then
		return false
	end
	-- 삭제 표식은 같은 DataStore 키의 UpdateAsync 안에서 확인한다.
	-- force 요청만 DataStore 상태 검사를 건너뛸 수 있다.
	if force ~= true and (IsCritical.Data or State.Data ~= "Access") then
		return false
	end

	-- 저장 성공 후 로컬 전체 래퍼를 복원하기 위해 이전 임시 상태를 보관한다.
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
			-- 최신 영구 값이 삭제 표식이면 UpdateAsync를 취소한다.
			if blockedByDataRemoval then
				return nil
			end

			local metadata = keyInfo and keyInfo:GetMetadata() or {}
			local currentRevision = GetDataRevision(keyInfo)
			if operationId then
				-- 응답 유실 뒤에도 같은 작업 ID의 확정 저장을 다시 적용하지 않는다.
				if metadata.__ksOp == operationId then
					alreadySaved = true
					savedData = oldData
					hasSavedData = true
					committedRevision = currentRevision
					return nil
				end
				-- 다른 쓰기가 버전을 올렸다면 이전 요청의 결과를 확정할 수 없다.
				if retryRevision ~= nil and currentRevision ~= retryRevision then
					blockedByConcurrentWrite = true
					return nil
				end
				observedRevision = currentRevision
			end
			if typeof(data) == "table" then
				local baseRevision = data.dataRevision or 0
				local sequence = data.dataSequence or 0
				if metadata.__ksSrcRev == baseRevision then
					local savedSequence = metadata.__ksSrcSeq or 0
					-- 순서와 값이 같으면 다시 저장할 필요가 없다.
					if sequence == savedSequence and deepEqual(data.data,oldData) then
						alreadySaved = true
						return nil
					-- 이전 스냅샷과 같은 순서의 서로 다른 값을 거부한다.
					elseif sequence <= savedSequence then
						blockedByStaleData = true
						return nil
					end
				-- 이미 바뀐 영구 버전을 기준으로 만든 스냅샷은 거부한다.
				elseif currentRevision ~= baseRevision then
					blockedByStaleData = true
					return nil
				end
				savedData = data.data
				metadata.__ksSrcRev = baseRevision
				metadata.__ksSrcSeq = sequence
			else
				-- 함수 입력은 현재 DataStore data를 직접 변환한다.
				savedData = data(oldData)
				metadata.__ksSrcRev = nil
				metadata.__ksSrcSeq = nil
			end
			-- 콜백이 nil을 반환하면 영구 저장을 취소한다.
			if savedData == nil then
				return nil
			end
			hasSavedData = true
			committedRevision = currentRevision + 1
			metadata.__ksRev = committedRevision
			metadata.__ksOp = operationId
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

	-- 대기 중인 변경은 적용하지 않고 확인된 삭제를 기록한다.
	if success and blockedByDataRemoval then
		self:SetSaving(key,false)
		MarkKeyRemoved(self,key,math.huge)
		return false
	end

	self:SetSaving(key,false)
	if success and alreadySaved and operationId then
		result = savedData
	end

	-- 저장소 요청이 재시도까지 실패하면 오류를 알린다.
	if not success then
		OnError:Fire(1,result,self.Store.Name,key,data)
		return false
	-- 반영 여부가 불확실하다고 반환해 같은 변경의 재실행을 막는다.
	elseif blockedByConcurrentWrite then
		return false,"uncertain"
	-- 오래된 스냅샷을 별도로 알려 백그라운드 재시도를 중단할 수 있게 한다.
	elseif blockedByStaleData then
		return false,"stale"
	elseif alreadySaved and not operationId then
		return true
	-- 취소된 변환은 새 값을 저장하지 않았다.
	elseif result == nil or not hasSavedData then
		return false
	else
		-- MemoryStore 전용 필드와 서버 목록은 유지하고 data만 저장 결과로 교체한다.
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


-- 전체 동기화 래퍼를 MemoryStore에 저장한다. 함수 콜백에는 최신 래퍼가 전달된다.
function KrossSync:SaveMemory(key,data,expiration,force,preserveDataVersion,verifiedMissing,publishOnly)
	-- 로컬 삭제가 확인되면 MemoryStore에 쓰지 않는다.
	if IsKeyLocallyRemoved(self,key) then
		return false
	end

	-- 공유 저장 전 겹치는 작업이나 지원하지 않는 입력을 거부한다.
	if IsWorkBlocked(self,key) or self.IsGetting[key] or self.IsSaving[key] or (typeof(data)~="function" and typeof(data)~="table") then
		return false
	end
	-- force만 MemoryStore 상태 검사를 건너뛴다.
	if force ~= true and (IsCritical.Memory == true or State.Memory ~= "Access") then
		return false
	end

	expiration = expiration or self.ExpirationTime

	-- MemoryStore 항목이 만료됐을 때 사용할 로컬 대체값을 보관한다.
	local oldLastData = self.LastData[key]
	local savedMemoryData
	local hasSavedMemoryData = false
	local blockedByRemoval = false
	local blockedByNewerData = false
	local blockedByConcurrentWrite = false
	local missingMemory = false
	local removedUntil
	local operationId = HttpService:GenerateGUID(false)
	local mayHaveCommitted = false
	local observedMemoryRevision
	local attempts = 0

	self:SetSaving(key,true)

	local function action()
		attempts += 1
		local retryRevision = if attempts > 1 then observedMemoryRevision else nil
		-- UpdateAsync 안에서 tombstone 확인과 데이터 갱신을 한 번에 처리한다.
		return self.Map:UpdateAsync(key,function(oldData)
			savedMemoryData = nil
			hasSavedMemoryData = false
			blockedByRemoval = false
			blockedByNewerData = false
			blockedByConcurrentWrite = false
			missingMemory = false
			removedUntil = GetActiveRemovalExpiration(oldData)

			if removedUntil then
				-- 삭제 표식은 어떤 일반 저장으로도 덮어쓰지 않는다.
				blockedByRemoval = true
				return oldData
			-- 만료된 표식은 누락으로 처리하고 영구 상태를 확인한다.
			elseif GetRemovalExpiration(oldData) then
				oldData = nil
			end
			-- 캐시가 비어 있으면 다시 만들기 전에 DataStore를 확인한다.
			if oldData == nil and verifiedMissing ~= VERIFIED_MISSING then
				missingMemory = true
				return nil
			end
			-- 작업 ID가 같으면 공유 갱신이 이미 반영된 것으로 확인한다.
			if oldData and oldData.__krossSyncMemoryOperation == operationId then
				savedMemoryData = oldData
				hasSavedMemoryData = true
				return oldData
			end
			local memoryRevision = oldData and oldData.__krossSyncMemoryRevision or 0
			-- 공유 버전이 바뀌면 결과가 불확실한 갱신을 재실행하지 않는다.
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
				-- 항목이 사라졌다면 마지막 로컬 캐시 또는 템플릿 래퍼를 함수에 전달한다.
				savedMemoryData = data(currentData)
			elseif typeof(data)== "table" then
				-- 외부 테이블을 직접 보관하지 않도록 복사하고 최신 서버 목록을 병합한다.
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

			-- 변환 결과가 nil이면 공유 저장을 취소한다.
			if savedMemoryData == nil then
				return nil
			end
			-- DataStore 복구는 메타데이터에서 결정한 순서를 그대로 사용한다.
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

			-- 임시 쓰기나 외부 래퍼가 공유 검증 예약을 지우거나 연기하지 않게 한다.
			savedMemoryData.__krossSyncDataCheckAfter = oldData and oldData.__krossSyncDataCheckAfter or os.time() + DURABLE_CHECK_INTERVAL
			savedMemoryData.__krossSyncDataCheckOwner = oldData and oldData.__krossSyncDataCheckOwner
			savedMemoryData.__krossSyncMemoryRevision = memoryRevision + 1
			savedMemoryData.__krossSyncMemoryOperation = operationId
			savedMemoryData.__krossSyncMemoryRefreshAfter = os.time() + math.max(1,math.floor(expiration / 2))
			hasSavedMemoryData = true
			mayHaveCommitted = true
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
	-- 커밋할 값이 제출되기 전에 실패한 경우만 대기열에서 재시도한다.
	if not success then
		OnError:Fire(2,result,self.MapName,key,data)
		return false,if mayHaveCommitted then "uncertain" else "retry"
	-- 비어 있는 캐시에 다시 쓰기 전에 영구 상태를 복구한다.
	elseif missingMemory then
		local recovered = self:GetData(key,force,nil,publishOnly)
		if recovered == false then
			return false
		end
		return self:SaveMemory(key,data,expiration,force,preserveDataVersion,VERIFIED_MISSING,publishOnly)
	-- UpdateAsync에서 확인한 삭제 표식을 로컬에 기록한다.
	elseif blockedByRemoval then
		MarkKeyRemoved(self,key,removedUntil or math.huge)
		return false
	-- 더 최신 공유 값을 덮어쓰지 않고 보존한다.
	elseif blockedByNewerData then
		return false
	-- 동시 쓰기로 결과가 불확실하면 같은 갱신을 재실행하지 않는다.
	elseif blockedByConcurrentWrite then
		return false,"uncertain"
	-- 콜백에서 표시하지 않았더라도 공유 저장소가 반환한 삭제 표식을 처리한다.
	elseif resultRemovedUntil then
		MarkKeyRemoved(self,key,resultRemovedUntil)
		return false
	-- 확정 결과가 없으면 공유 저장이 취소된 것이다.
	elseif result == nil then
		return false
	else
		-- 재전달은 공유 값을 복구하되 UnSync한 키를 다시 구독하지 않는다.
		if hasSavedMemoryData and (not publishOnly or (oldLastData and self.LastData[key] == oldLastData)) then
			self.LastData[key] = result
		end

		return true
	end
end


-- 임시 래퍼만 갱신한다. 실패하면 호출자가 재시도 여부를 결정한다.
function KrossSync:SetMemory(key,data,expiration,force,verifiedMissing,publishOnly)
	return self:SaveMemory(key,data,expiration,force,nil,verifiedMissing,publishOnly)
end


-- data를 먼저 영구 저장한 뒤 확정된 값을 MemoryStore에 전달한다.
-- 반환값은 DataStore와 MemoryStore 성공 여부 순서다.
local function SetNow(self,key,data,expiration,force,sourceSnapshot)
	-- 삭제됐거나 사용 중인 키는 영구 Set 전에 거부한다.
	if IsKeyLocallyRemoved(self,key) or IsWorkBlocked(self,key) or self.IsGetting[key] or self.IsSaving[key] then
		return false,false
	end
	-- Set은 변환 함수 또는 data 필드가 있는 래퍼만 받는다.
	if typeof(data) ~= "function" and (typeof(data) ~= "table" or data.data == nil) then
		return false,false
	end
	-- force만 DataStore 상태 검사를 건너뛴다.
	if force ~= true and (IsCritical.Data or State.Data ~= "Access") then
		return false,false
	end

	local blockedByRemoval = false
	local blockedByStaleData = false
	local blockedByConcurrentWrite = false
	local alreadyApplied = false
	local committedRevision
	local appliedData
	local mayHaveCommitted = false
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
			-- 영구 삭제 표식을 덮어쓰지 않는다.
			if blockedByRemoval then
				return nil
			end
			local metadata = oldKeyInfo and oldKeyInfo:GetMetadata() or {}
			-- 콜백을 다시 적용하지 않고 앞서 확정된 결과를 사용한다.
			local currentRevision = GetDataRevision(oldKeyInfo)
			if metadata.__ksOp == operationId then
				alreadyApplied = true
				appliedData = oldData
				committedRevision = currentRevision
				return nil
			end
			-- 동시 영구 저장이 재시도 기준 버전을 바꾸면 재실행을 중단한다.
			if retryRevision ~= nil and currentRevision ~= retryRevision then
				blockedByConcurrentWrite = true
				return nil
			end
			local base = sourceSnapshot or (if typeof(data) == "table" then data else nil)
			if base and base.dataRevision ~= nil then
				local baseRevision = base.dataRevision
				local sequence = base.dataSequence or 0
				if metadata.__ksSrcRev == baseRevision then
					local savedSequence = metadata.__ksSrcSeq or 0
					blockedByStaleData = sequence < savedSequence
						or (sequence == savedSequence and not deepEqual(base.data,oldData))
				else
					blockedByStaleData = baseRevision ~= GetDataRevision(oldKeyInfo)
				end
				-- 오래된 스냅샷에서 계산한 값은 저장하지 않는다.
				if blockedByStaleData then
					return nil
				end
			end
			observedRevision = currentRevision

			local input = if sourceSnapshot then sourceSnapshot.data else oldData
			if sourceSnapshot and type(input) == "table" then input = DeepCopyTable(input) end
			local updatedData = if typeof(data) == "function" then data(input) else data.data
			-- 변환 결과가 nil이면 두 저장소를 바꾸기 전에 Set을 취소한다.
			if updatedData == nil then
				return nil
			end

			committedRevision = currentRevision + 1
			metadata.__ksRev = committedRevision
			metadata.__ksOp = operationId
			metadata.__ksSrcRev = nil
			metadata.__ksSrcSeq = nil
			mayHaveCommitted = true
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
	-- 사이에 다른 쓰기가 반영되면 이전 시도를 재실행할 수 없다.
	if blockedByConcurrentWrite then
		return false,false,"uncertain"
	end
	-- 커밋 후보가 만들어지지 않았을 때만 재시도 가능한 실패로 알린다.
	if not success then
		OnError:Fire(1,storedData,self.Store.Name,key,data)
		return false,false,if mayHaveCommitted then "uncertain" else "retry"
	end
	if alreadyApplied then
		storedData = appliedData
	end
	if storedData == nil then
		return false,false
	end

	local metadata = keyInfo and keyInfo:GetMetadata()
	local revision = if alreadyApplied then committedRevision else metadata and metadata.__ksRev or committedRevision
	if type(revision) ~= "number" then
		-- 확정 버전이 없으면 영구 저장에 성공해도 캐시에 안전하게 반영할 수 없다.
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


-- UpdateAsync로 다른 서버의 저장과 원자적으로 순서를 정하며 tombstone을 기록한다.
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

	-- 공유 삭제 표식 저장 실패를 재시도 처리에 전달한다.
	if not success then
		OnError:Fire(2,result,self.MapName,key)
		return false
	end

	MarkKeyRemoved(self,key,GetRemovalExpiration(result) or tombstone.removedUntil)
	return true
end

-- 영구 삭제 뒤 공유 캐시 표식만 실패했다면 살아 있는 동안 다시 기록한다.
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
		-- 재시도 시간이 지나면 공유 삭제 표식 기록을 중단한다.
		if self.PendingMemoryRemoval[key] == pending then
			self.PendingMemoryRemoval[key] = nil
			warn("MemoryStore removal marker retry expired:",key)
		end
	end)
end


-- tombstone 없이 MemoryStore 항목 자체를 제거한다.
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

-- DataStore에 영구 표식을 확정한 뒤 MemoryStore 캐시도 삭제 상태로 전환한다.
local function RemoveNow(self,key)
	-- 같은 키의 다른 작업과 삭제가 겹치지 않게 한다.
	if IsWorkBlocked(self,key) or self.IsGetting[key] or self.IsSaving[key] then
		return false, false
	end

	self:SetSaving(key,true)

	-- 영구 표식이 실패했다면 삭제 완료로 인정하지 않는다.
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


-- DataStore에만 영구 삭제 표식을 남긴다. 공유 캐시도 지우려면 Remove를 사용한다.
function KrossSync:RemoveData(key)
	local self = self :: KrossSync<unknown,unknown>
	-- 직접 영구 삭제는 대기열을 사용하지 않고 사용 중인 키에서는 실패한다.
	if IsWorkBlocked(self,key) or self.IsGetting[key] or self.IsSaving[key] then
		return false
	end

	self:SetSaving(key,true)
	local success = WriteDataRemovalTombstone(self,key)

	if success then
		-- 삭제한 영구 데이터가 로컬 캐시에서 다시 사용되지 않게 한다.
		self.LastData[key] = nil
	end

	self:SetSaving(key,false)
	self.IsGetting[key] = nil
	self.IsSaving[key] = nil
	return success
end

-- MemoryStore 항목만 삭제한다. DataStore 데이터가 남아 있으면 다음 Get에서 다시 만들어질 수 있다.
function KrossSync:RemoveMemory(key)
	local self = self :: KrossSync<unknown,unknown>
	-- 직접 캐시 삭제는 대기열을 사용하지 않고 사용 중인 키에서는 실패한다.
	if IsWorkBlocked(self,key) or self.IsGetting[key] or self.IsSaving[key] then
		return false
	end

	self:SetSaving(key,true)
	local success = RemoveMemoryKey(self,key)

	if success then
		-- 단독 MemoryStore 삭제는 기존 로컬 tombstone 상태도 해제한다.
		self.LastData[key] = nil
		self.RemovedKeys[key] = nil
		self.PendingMemoryPublish[key] = nil
	end

	self:SetSaving(key,false)
	self.IsGetting[key] = nil
	self.IsSaving[key] = nil
	return success
end


-- 접수 순서대로 변환 함수를 합성한다.
local function ComposeWork(requests)
	local dataFuncs = {}
	for i,request in ipairs(requests) do
		dataFuncs[i] = request.data
	end
	return function(old)
		for _,dataFunc in ipairs(dataFuncs) do
			old = dataFunc(old)
			-- 변환 함수 하나라도 nil을 반환하면 묶음 전체를 취소한다.
			if old == nil then return nil end
		end
		return old
	end
end

local function RemainingWork(requests)
	-- 삭제에는 다시 실행할 데이터 변환 함수가 없다.
	if requests[1].kind == "Remove" then return nil end
	for _,request in ipairs(requests) do
		-- 테이블 스냅샷은 재실행용 콜백으로 반환하지 않는다.
		if type(request.data) ~= "function" then return nil end
	end
	local kind = requests[1].kind
	for _,request in ipairs(requests) do
		if request.kind ~= kind then
			return function(wrapper)
				for _,item in ipairs(requests) do
					if item.kind == "Save" then
						wrapper = item.data(wrapper)
						if wrapper == nil then return nil end
					else
						local data = item.data(wrapper.data)
						if data == nil then return nil end
						wrapper.data = data
					end
				end
				return wrapper
			end
		end
	end
	return ComposeWork(requests)
end

local function CompleteWork(request, result)
	local receipt = request.receipt
	receipt.result = result
	for _,waiter in ipairs(receipt.waiters) do
		if coroutine.status(waiter) == "suspended" then task.defer(waiter) end
	end
	table.clear(receipt.waiters)
end

local function WorkFailure(kind, remaining, reason)
	if kind == "Save" then return table.pack(false,remaining,reason) end
	return table.pack(false,false,remaining,reason)
end

local function ResolveRemoval(self, key)
	local durable, shared = RemoveNow(self,key)
	if durable then return durable,shared end
	-- A lost response can hide a committed tombstone.
	local ok, old = pcall(self.Store.GetAsync,self.Store,key,uncachedGetOptions)
	-- 확인 조회도 실패하면 삭제가 확정됐다고 판단하지 않는다.
	if not ok then return false,false,"uncertain" end
	-- 삭제가 반영되지 않은 것이 확인되면 다시 시도할 수 있다.
	if not GetRemovalExpiration(old) then return false,false,"retry" end
	MarkKeyRemoved(self,key,math.huge)
	ScheduleMemoryRemoval(self,key,math.max(self.ExpirationTime,REMOVAL_TOMBSTONE_MIN_TIME))
	return true,false
end

local function WorkBatch(queue)
	for i,request in ipairs(queue) do
		if request.kind == "Remove" then return {table.remove(queue,i)}, nil end
	end
	local batch = {table.remove(queue,1)}
	local first = batch[1]
	if type(first.data) ~= "function" then return batch,nil end
	local function compatible(nextRequest, kind)
		return nextRequest and nextRequest.kind == kind and type(nextRequest.data) == "function"
			and nextRequest.expiration == first.expiration and nextRequest.force == first.force
	end
	while compatible(queue[1],first.kind) do
		table.insert(batch,table.remove(queue,1))
	end
	if first.kind == "Save" and compatible(queue[1],"Set") then
		local sets = {}
		while compatible(queue[1],"Set") do
			table.insert(sets,table.remove(queue,1))
		end
		return batch,sets
	end
	return batch,nil
end

local function ExecuteWork(self, key, batch, sets)
	local first = batch[1]
	local data = if type(first.data) == "function" then ComposeWork(batch) else first.data
	if first.kind == "Remove" then return ResolveRemoval(self,key) end
	if first.kind == "Set" then return SetNow(self,key,data,first.expiration,first.force,first.sourceSnapshot) end
	local pending = self.PendingMemoryPublish[key]
	if pending then
		-- 영구 Set 결과가 아직 공유되지 않았다면 오래된 값에 Save를 적용하지 않는다.
		if not PublishDurableData(self,key,pending.data,pending.revision,pending.expiration,true) then
			return false,nil,"retry"
		end
		if self.PendingMemoryPublish[key] == pending then self.PendingMemoryPublish[key] = nil end
	end
	if sets then
		if first.force ~= true and (IsCritical.Total or State.Total ~= "Access") then return false,nil,"blocked" end
		local saved, reason = self:SaveMemory(key,data,first.expiration,first.force)
		return saved,if saved then DeepCopyTable(self.LastData[key]) else nil,reason
	end
	local saved, reason = SaveNow(self,key,data,first.expiration,first.force)
	return saved,nil,reason
end

local function DrainWorks(self, key, work)
	while #work.pending > 0 do
		while self.IsGetting[key] or self.IsSaving[key] do
			task.wait(0.1)
		end
		local batch, sets = WorkBatch(work.pending)
		local first = batch[1]
		local ok, a, b, reason = pcall(ExecuteWork,self,key,batch,sets)
		-- 예상 밖 오류가 나면 작업 잠금은 풀되 같은 변경을 무조건 재실행하지 않는다.
		if not ok then
			self.IsGetting[key], self.IsSaving[key] = nil,nil
			warn("Queued work failed:",key,a)
			a,b,reason = false,false,"uncertain"
		end
		if sets and a then
			-- Save is already visible; only Set may be retried from here.
			local snapshot = b
			for _,request in ipairs(batch) do
				CompleteWork(request,table.pack(true))
			end
			for i = #sets,1,-1 do
				sets[i].sourceSnapshot = snapshot
				table.insert(work.pending,1,sets[i])
			end
			continue
		-- 앞선 Save가 실패하면 실행하지 않은 Set 콜백도 같은 실패 묶음에 남긴다.
		elseif sets then
			for _,request in ipairs(sets) do
				table.insert(batch,request)
			end
		end
		if a and first.kind == "Save" then
			local nextRequest = work.pending[1]
			if nextRequest and nextRequest.kind == "Set" and type(nextRequest.data) == "function" and self.LastData[key] then
				nextRequest.sourceSnapshot = DeepCopyTable(self.LastData[key])
			end
		end
		-- 미반영이 확인된 작업만 접수 순서를 유지해 대기열에서 한 번 더 시도한다.
		if not a then
			local canRetry = reason == "retry"
			for _,request in ipairs(batch) do
				if request.retried then
					canRetry = false
					break
				end
			end
			if canRetry then
				for i = #batch,1,-1 do
					batch[i].retried = true
					table.insert(work.pending,1,batch[i])
				end
				task.wait(1)
				continue
			end
		end
		-- 결과가 불확실하거나 삭제된 쓰기를 재실행하지 않도록 안전한 함수만 반환한다.
		local remaining = if not a and reason ~= "uncertain" and not IsKeyLocallyRemoved(self,key) then RemainingWork(batch) else nil
		for _,request in ipairs(batch) do
			local result
			if not a then
				result = WorkFailure(request.kind,remaining,reason or "failed")
			elseif request.kind == "Save" then
				result = table.pack(true)
			else
				result = table.pack(a,b)
			end
			CompleteWork(request,result)
		end
		-- 삭제가 확정됐거나 확인할 수 없으면 대기 중인 쓰기를 종료한다.
		if (first.kind == "Remove" and (a or reason == "uncertain")) or IsKeyLocallyRemoved(self,key) then
			local canceled = if a or IsKeyLocallyRemoved(self,key) then "removed" else "uncertain"
			for _,request in ipairs(work.pending) do
				CompleteWork(request,if request.kind == "Remove" and a then table.pack(a,b) else WorkFailure(request.kind,nil,canceled))
			end
			table.clear(work.pending)
		end
	end
	self.works[key] = nil
end

local function SubmitWork(self, key, kind, data, expiration, force, waitForResult)
	local receipt = {waiters = {}}
	function receipt:Await()
		if not self.result then
			table.insert(self.waiters,coroutine.running())
			coroutine.yield()
		end
		return table.unpack(self.result,1,self.result.n)
	end
	local wait = if waitForResult == nil then self.WaitForWorkResult else waitForResult
	local work = self.works[key]
	local valid = kind == "Remove" or type(data) == "function"
		or (type(data) == "table" and (kind == "Save" or data.data ~= nil))
	-- 종료 중 요청, 잘못된 입력, 작업자 자신의 재진입은 대기시키지 않고 거부한다.
	if self.Closing or not valid or (work and work.owner == coroutine.running()) then
		CompleteWork({receipt = receipt},WorkFailure(kind,nil,"rejected"))
	-- 삭제가 확인된 키는 새 쓰기를 받지 않는다.
	elseif kind ~= "Remove" and IsKeyLocallyRemoved(self,key) then
		CompleteWork({receipt = receipt},WorkFailure(kind,nil,"removed"))
	else
		if not work then
			work = {pending = {}}
			self.works[key] = work
		end
		table.insert(work.pending,{
			kind = kind,
			data = if type(data) == "table" then DeepCopyTable(data) else data,
			expiration = expiration or self.ExpirationTime,
			force = force == true,
			receipt = receipt,
		})
		if not work.owner then
			work.owner = task.defer(DrainWorks,self,key,work)
		end
	end
	if wait then
		return receipt:Await()
	end
	return receipt
end

function KrossSync:Save(key,data,expiration,force,waitForResult)
	return SubmitWork(self,key,"Save",data,expiration,force,waitForResult)
end

function KrossSync:Set(key,data,expiration,force,waitForResult)
	return SubmitWork(self,key,"Set",data,expiration,force,waitForResult)
end

function KrossSync:Remove(key,waitForResult)
	return SubmitWork(self,key,"Remove",nil,nil,nil,waitForResult)
end

-- 현재 서버 JobId를 제거하고 공유 data를 영구 저장한 뒤 동기화를 해제한다.
function KrossSync:UnSync(key)
	-- 대기 중인 쓰기가 있으면 UnSync가 캐시를 먼저 해제하지 않도록 실패를 반환한다.
	if IsWorkBlocked(self,key) then return false end
	-- 동기화하지 않은 키는 해제할 수 없다.
	if not self.LastData[key] then
		return false
	end

	local function data(old:Data<unknown,unknown>)
		-- 중복된 현재 JobId도 모두 제거해 서버 목록을 정상화한다.
		old.onlineServers = NormalizeOnlineServers(old.onlineServers)
		for i = #old.onlineServers,1,-1 do
			if old.onlineServers[i] == game.JobId then
				table.remove(old.onlineServers,i)
			end
		end
		return old
	end
	-- 종료 처리에서는 전역 상태가 Error여도 마지막 정리를 시도하도록 force를 사용한다.
	local success = self:SaveMemory(key,data,self.ExpirationTime,true)
	if not success then
		-- 삭제된 키의 동기화를 끊을 때는 더 저장할 상태가 없다.
		if IsKeyLocallyRemoved(self,key) then
			self.LastData[key] = nil
			return true
		end
		return false
	end

	local LastData = self.LastData[key]
	if not LastData then
		return false
	end
	-- 다른 서버 ID가 남아 있어도 UpdateAsync가 확정한 최신 값을 사용한다.
	local reason
	success, reason = self:SaveData(key,LastData,true)
	-- 더 최신 영구 값이 있으면 마지막 로컬 스냅샷을 저장하지 않아도 된다.
	success = success or reason == "stale"
	if success then
		self.LastData[key] = nil
	elseif not IsKeyLocallyRemoved(self,key) then
		self.LastData[key] = LastData
	end
	return success
end


---------------------------------------------------------KrossSyncService 공개 API
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


-----------------------공개 상태------------------------

KrossSyncService.KrossSyncs = {}
-- 현재 전체/개별 저장소 상태와 Critical 여부를 외부에서 읽을 수 있게 공개한다.
KrossSyncService.State = State
KrossSyncService.IsCritical = IsCritical

---- 공개 신호----

-- 짧은 시간에 오류가 누적되어 Critical 상태가 바뀔 때 발생한다.
KrossSyncService.OnCriticalToggle = OnCriticalToggle
-- 저장소 요청이 최종 실패할 때 위치, 오류, 저장소 이름, 키, 입력값을 전달한다.
KrossSyncService.OnError  = OnError

-----------------------인스턴스 생성---------------------

function KrossSyncService.get(StoreName,DataTemplate,MemoryTemplate,NormalExpirationTime)
	-- 같은 StoreName은 하나의 인스턴스를 공유한다. 기존 인스턴스와 다른 템플릿 참조는 허용하지 않는다.
	if KrossSyncService.KrossSyncs[StoreName] then
		if KrossSyncService.KrossSyncs[StoreName].DataTemplate ~= DataTemplate or KrossSyncService.KrossSyncs[StoreName].MemoryTemplate ~= MemoryTemplate then
			return false
		end

		return KrossSyncService.KrossSyncs[StoreName]
	end

	-- StoreName별 저장소 객체, 캐시, 잠금, Signal은 각 인스턴스가 독립적으로 가진다.
	local self={
		MaxRetryTime=5,
		WaitForWorkResult = true,
		Closing = false,
		works = {},
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
		-- 키별 로컬 잠금
		IsGetting = {},
		IsSaving = {},
		---- 인스턴스별 신호----
		OnNewData = signal(), -- 자동 동기화로 data 또는 memory가 바뀌었을 때 전체 래퍼 전달
		OnGettingToggle = signal(), -- 조회 시작/종료 여부 전달
		OnSavingToggle = signal(), -- 저장 시작/종료 여부 전달
		-- TODO: 덮어쓰기 위치(DataStore/MemoryStore)를 알리는 신호 추가 검토
	}

	self = setmetatable(self,KrossSync)::KrossSync<typeof(MemoryTemplate),typeof(DataTemplate)>

	-- 종료 처리와 자동 동기화 루프를 연결한 뒤 서비스 캐시에 등록한다.
	OnNewKrossSync:Fire(self)
	KrossSyncService.KrossSyncs[StoreName] = self

	return self

end

-----------------------내부 상태 관리------------------- 
-- DataStore/MemoryStore 중 하나라도 Critical이면 Total도 Critical로 설정한다.
local function setCritical(Data,Memory)
	if Data == nil then
		Data = IsCritical.Data
	end
	if Memory == nil then
		Memory = IsCritical.Memory
	end

	if Data == IsCritical.Data and Memory == IsCritical.Memory then
		return
	end

	IsCritical.Data = Data
	IsCritical.Memory = Memory
	IsCritical.Total = Data ~= false or Memory ~= false
	OnCriticalToggle:Fire(IsCritical.Total,IsCritical)
end

-- 개별 저장소 상태를 갱신하고 우선순위에 따라 전체 상태를 계산한다.
local function setState(Data, Memory)
	if State.Total == "NoInternet" or Data == "NotReady" or Memory == "NotReady" then
		return
	elseif State.Total == "NoAccess" and (Data ~= "Access" and Memory ~= "Access") then
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
	if (type(checkAfter) ~= "number" or checkAfter > now) or IsWorkBlocked(self,key) or self.IsGetting[key] or self.IsSaving[key] then
		return expectedData
	end
	local owner = HttpService:GenerateGUID(false)
	self:SetGetting(key,true)
	local success, claimed = ExponentialJitterBackoff(5,2,nil,function()
		return self.Map:UpdateAsync(key,function(old)
			-- 누락되거나 삭제된 항목에는 검증권을 예약하지 않는다.
			if not old or GetRemovalExpiration(old) then return nil end
			if old.__krossSyncDataCheckOwner == owner then return old end
			local currentAfter = old.__krossSyncDataCheckAfter
			-- 검증 시각이 없거나 아직 도래하지 않았으면 검증권을 잡지 않는다.
			if type(currentAfter) ~= "number" or currentAfter > os.time() then return nil end
			old = DeepCopyTable(old)
			old.__krossSyncMemoryRefreshAfter = os.time() + math.max(1,math.floor(self.ExpirationTime / 2))
			old.__krossSyncDataCheckOwner = owner
			old.__krossSyncDataCheckAfter = os.time() + DURABLE_CHECK_LEASE_TIME
			return old
		end,self.ExpirationTime)
	end)
	self:SetGetting(key,false)
	-- 검증권을 잡지 못하면 현재 스냅샷을 유지한다.
	if not success then
		OnError:Fire(2,claimed,self.MapName,key)
		return expectedData
	end
	-- 요청 대기 중 로컬 상태가 바뀌면 검증 결과를 적용하지 않는다.
	if self.LastData[key] ~= expectedData then return nil end
	if not claimed or claimed.__krossSyncDataCheckOwner ~= owner then return expectedData end

	local refreshed = self:GetData(key,false,expectedData)
	-- 영구 삭제 표식을 공유 캐시에도 기록해 다른 서버에 전달한다.
	if self.RemovedKeys[key] == math.huge then
		local expiration = math.max(self.ExpirationTime,REMOVAL_TOMBSTONE_MIN_TIME)
		if not SetRemovalTombstone(self,key,expiration,1) then
			ScheduleMemoryRemoval(self,key,expiration)
		end
		return nil
	end
	local finished, result = ExponentialJitterBackoff(5,2,nil,function()
		return self.Map:UpdateAsync(key,function(old)
			-- 다른 서버가 이미 교체한 검증권은 종료 처리하지 않는다.
			if not old or GetRemovalExpiration(old) or old.__krossSyncDataCheckOwner ~= owner then return nil end
			old = DeepCopyTable(old)
			old.__krossSyncDataCheckOwner = nil
			old.__krossSyncDataCheckAfter = os.time() + (if refreshed == false then AUTO_GET_MEMORY_TIME else DURABLE_CHECK_INTERVAL)
			old.__krossSyncMemoryRefreshAfter = os.time() + math.max(1,math.floor(self.ExpirationTime / 2))
			return old
		end,self.ExpirationTime)
	end)
	if not finished then OnError:Fire(2,result,self.MapName,key) end
	return self.LastData[key]
end

-- 최신 공유 값의 만료만 갱신하며, 사라진 키를 로컬 값으로 복구하지 않는다.
local function RefreshMemoryCache(self, key, expectedData)
	local refreshAfter = expectedData.__krossSyncMemoryRefreshAfter
	if type(refreshAfter) ~= "number" or refreshAfter > os.time() then return expectedData end
	if IsWorkBlocked(self,key) or self.IsGetting[key] or self.IsSaving[key] then return expectedData end

	self:SetGetting(key,true)
	local success, result = ExponentialJitterBackoff(5,2,nil,function()
		local latest
		local updated = self.Map:UpdateAsync(key,function(old)
			latest = old
			-- 갱신이 누락되거나 삭제된 항목을 다시 만들면 안 된다.
			if not old or GetRemovalExpiration(old) then return nil end
			local after = old.__krossSyncMemoryRefreshAfter
			-- 갱신 시각이 없거나 다른 서버가 이미 연장했으면 건너뛴다.
			if type(after) ~= "number" or after > os.time() then return nil end
			old = DeepCopyTable(old)
			old.__krossSyncMemoryRefreshAfter = os.time() + math.max(1,math.floor(self.ExpirationTime / 2))
			return old
		end,self.ExpirationTime)
		return updated or latest
	end)
	self:SetGetting(key,false)
	-- 이미 바뀐 로컬 스냅샷의 갱신 결과는 무시한다.
	if self.LastData[key] ~= expectedData then return nil end
	-- 갱신이 실패하면 로컬 캐시를 유지하고 이후 조회에서 다시 시도한다.
	if not success then
		OnError:Fire(2,result,self.MapName,key)
		return expectedData
	end
	-- 누락된 값은 그대로 두고 로컬 스냅샷을 다시 공유하지 않는다.
	if not result then return nil end
	local removedUntil = GetActiveRemovalExpiration(result)
	-- 동시 삭제가 발생하면 캐시 갱신보다 삭제가 우선한다.
	if removedUntil then
		MarkKeyRemoved(self,key,removedUntil)
		return nil
	elseif GetRemovalExpiration(result) or IsKeyLocallyRemoved(self,key) then
		return nil
	end
	self.LastData[key] = ReconcileDataWithTemplates(result,self.DataTemplate,self.MemoryTemplate)
	return self.LastData[key]
end

OnNewKrossSync:Connect(function(KrossSync)
	-- 서버 종료 시 현재 서버를 모든 키에서 해제하고 마지막 서버인 키는 최종 저장한다.
	game:BindToClose(function()
		KrossSync.Closing = true
		-- Roblox 종료 제한보다 여유 있게 25초 안에서 정리를 마친다.
		local CLOSE_DEADLINE = 25
		local CloseTime = os.time()
		local closingKeys = table.clone(KrossSync.LastData)
		for key in pairs(KrossSync.works) do closingKeys[key] = true end
		for key in pairs(closingKeys) do
			-- 키마다 독립적으로 UnSync를 재시도해 한 키의 실패가 다른 키를 막지 않게 한다.
			task.spawn(function()
				KrossSync:UnSync(key)
				while KrossSync.LastData[key] or KrossSync.works[key] do task.wait(1)
					KrossSync:UnSync(key)
				end
			end)
		end
		while task.wait() do
			-- 모든 로컬 캐시가 해제되면 종료 대기를 끝낸다.
			if next(KrossSync.LastData) == nil and next(KrossSync.works) == nil then break end

			-- 서버 종료를 막지 않도록 제한 시간에 도달하면 대기를 끝낸다.
			if os.time() - CloseTime >= CLOSE_DEADLINE then
				warn("KrossSync: BindToClose took too long to close. ("..(os.time()-CloseTime).."s)")
				break
			end

		end
	end)

	------------------

	-- 대기 중 정상 저장이 캐시를 교체해도 최신 캐시부터 조회한다. 해제된 키는 복구하지 않는다.
	local function AutoGetMemory(key)
		if KrossSync.Closing then return end
		local previousData = KrossSync.LastData[key]
		if not previousData or previousData.memory == nil then
			return
		end

		local memoryData = KrossSync:GetMemory(key,false)

		if memoryData == nil then
			-- 누락된 항목은 영구 상태를 확인한 뒤 복구한다.
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
		-- GetMemory가 양보한 사이 UnSync/Remove가 완료됐다면 오래된 작업의 결과를 폐기한다.
		if KrossSync.LastData[key] ~= memoryData then
			return
		end
		memoryData = CheckDurableCache(KrossSync,key,memoryData)
		if not memoryData or KrossSync.LastData[key] ~= memoryData then return end
		memoryData = RefreshMemoryCache(KrossSync,key,memoryData)
		if not memoryData or KrossSync.LastData[key] ~= memoryData then return end

		-- 영구 data 또는 임시 memory가 달라졌을 때만 변경 신호를 발생시킨다.
		local memoryChanged = not deepEqual(previousData.memory,memoryData.memory)
		local dataChanged = not deepEqual(previousData.data,memoryData.data)
		memoryData.lastUpdate = os.time()
		memoryData.dataCreateTime = math.max(previousData.dataCreateTime or 0,memoryData.dataCreateTime or 0)
		KrossSync.LastData[key] = memoryData

		if memoryChanged or dataChanged then
			KrossSync.OnNewData:Fire(memoryData)
		end
	end

	-- 키별 15초 주기를 유지하며 느리거나 실패한 키가 다른 키의 조회를 막지 않게 한다.
	local tasks = {}::{[string]:thread}
	local LastGetTime = {}
	task.spawn(function()
		while true do
			for key, data in pairs(KrossSync.LastData) do
				if not tasks[key] then
					tasks[key] = task.spawn(function()
						task.wait(math.max(0, (LastGetTime[key] or 0) + AUTO_GET_MEMORY_TIME - os.time()))
						task.wait(math.max(0, data.dataCreateTime + AUTO_GET_MEMORY_TIME - os.time()))
						-- 한 키의 조회 오류가 다른 키나 이후 조회를 막지 않도록 격리한다.
						local success, result = pcall(AutoGetMemory,key)
						LastGetTime[key] = os.time()
						tasks[key] = nil
						if not success then warn("Automatic memory refresh failed:",key,result) end
					end)
				end
			end
			for key in pairs(LastGetTime) do
				if not KrossSync.LastData[key] and not tasks[key] then
					LastGetTime[key] = nil
				end
			end
			task.wait(1)
		end
	end)


end)

local dataLastErrorTime = 0
local memoryLastErrorTime = 0
local dataRecoveryRunning = false
local memoryRecoveryRunning = false

-- 오류 감지 구간보다 오래된 기록을 큐 앞쪽부터 제거한다.
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

-- 저장소가 회복되면 해당 오류 큐를 완전히 비운다.
local function ClearErrorQueue(errorQueue)
	while not errorQueue:isEmpty() do
		errorQueue:dequeue()
	end
end

-- 저장소별로 하나의 회복 감시 작업만 실행한다.
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

	-- 마지막 오류 이후 일정 시간 동안 추가 오류가 없을 때만 Critical 상태를 해제한다.
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
	-- 저장소 종류에 맞는 최근 오류 큐와 마지막 오류 시각을 선택한다.
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

	-- 현재 감지 구간에 포함되는 오류만 남긴 뒤 새 오류를 기록한다.
	TrimExpiredErrors(errorQueue,now)
	errorQueue:enqueue({
		time = now,
		errorMessage = ErrorMessage,
		name = Name,
		key = Key,
		data = Data,
	})

	-- Critical 판정에 필요한 개수만 유지해 큐가 무한히 커지지 않게 한다.
	while errorQueue:getSize() > CRITICAL_ERROR_COUNT do
		errorQueue:dequeue()
	end

	-- 제한 시간 안에 오류가 임계값에 도달하면 해당 저장소를 Critical/Error로 전환한다.
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

-- 최초 저장소 접근 상태를 확인하고 서비스 전체 상태를 구성한다.
task.spawn(function()
	if RunService:IsStudio() then
		-- Studio에서는 API Services 설정이 꺼진 403 오류를 초기에 분명하게 알린다.
		local success,result = pcall(function()
			return game:GetService("DataStoreService"):GetGlobalDataStore():SetAsync("KrossSync_Chack",{Time=os.time(),JobID=game.JobId}) 
		end)

		-- Studio API 권한 오류를 다른 확인 실패와 구분한다.
		if not success then
			if string.find(result,"403") ~= nil then
				setState("NoInternet","NoInternet")
				error(result)
				return
			end
		end

	end

	while true do
		-- 준비 전에는 양쪽 서비스 객체를 확인하고, 정상 상태에서는 검사 주기를 늦춘다.
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

-- DataStore 요청 예산이 고갈된 동안 일반 요청을 잠시 차단한다.
task.spawn(function()
	while true do task.wait(10)
		if State.Data == "NoAccess" then
			-- 차단 상태에서는 실제 쓰기 검사를 통해 회복 여부를 확인한다.
			local storeStatus = IsStoreOkay("Data","High")
			if storeStatus.Data then
				setState("Access",nil)
			end
		elseif dataErrorQueue:getSize() > 0 then
			-- 최근 DataStore 오류가 있을 때만 요청 예산 고갈 여부를 검사한다.
			local writeBudget = DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.StandardWrite)
			local readBudget = DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.StandardRead)
			if writeBudget <= 1 or readBudget <= 1 then
				setState("NoAccess",nil)
			end
		end
	end
end)



return KrossSyncService

