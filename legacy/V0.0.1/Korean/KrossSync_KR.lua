
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

DataStore에는 영구 보관할 data 필드만 저장하고,
MemoryStore에는 임시 memory와 서버 목록을 포함한 전체 동기화 래퍼를 저장한다.
여러 서버가 같은 키를 사용할 때 MemoryStore를 통해 최신 상태와 접속 서버를 공유한다.

--------------------------------------------------------------------------------

]]

-----------사용 환경에 맞게 조절할 설정값---------

-- Save 호출 시 마지막 DataStore 저장으로부터 이 시간이 지난 경우에만 영구 데이터를 저장한다.
local SAVE_DATA_TIME = 60
-- 다른 서버가 MemoryStore에 반영한 변경을 확인하는 주기다.
local AUTO_GET_MEMORY_TIME = 15
-- 저장소 오류가 더 발생하지 않았을 때 오류 기록과 Critical 상태를 초기화하기까지의 시간이다.
local ERROR_RESET_TIME = 30
local CRITICAL_ERROR_COUNT = 5
-- 삭제 표식은 자동 조회 주기보다 충분히 오래 유지해 오래된 서버가 데이터를 되살리지 못하게 한다.
local REMOVAL_TOMBSTONE_MIN_TIME = AUTO_GET_MEMORY_TIME * 4
local REMOVAL_MARKER = "__krossSyncRemoved"

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
}
-- StoreName 하나에 대응하는 동기화 인스턴스와 공개 메서드 타입
export type KrossSync<MemTpl,DataTpl> = {	
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
	PendingRemovalCleanup: {[string]:boolean},
	PendingRemovalVerification: {[string]:boolean},
	-- 키별 중복 조회/저장을 막는 로컬 잠금
	IsGetting: {[string]:boolean}, 
	IsSaving: {[string]:boolean}, 
	---- 인스턴스 신호----
	OnNewData: signal.Signal<Data<MemTpl, DataTpl> >,
	OnGettingToggle: signal.Signal<boolean> ,
	OnSavingToggle: signal.Signal<boolean>,
	---- 조회 함수----
	Get: (self:KrossSync<MemTpl, DataTpl>, key:string, force:boolean)-> (Data<MemTpl?, DataTpl> | false, {Data:boolean,Memory:boolean}?),
	GetData: (self:KrossSync<MemTpl, DataTpl>, key:string, force:boolean) -> (Data<nil, DataTpl> | nil | false ),
	GetMemory: (self:KrossSync<MemTpl, DataTpl>, key:string, force:boolean) -> (Data<MemTpl, DataTpl> | nil | false ),
	---- 저장 함수----
	Save: (self:KrossSync<MemTpl, DataTpl>, key:string, data:Data<MemTpl, DataTpl>|(old:Data<MemTpl, DataTpl>?)->(Data<MemTpl, DataTpl>?), expiration:number, force:boolean) -> (boolean),
	SaveData: (self:KrossSync<MemTpl, DataTpl>, key:string, data:Data<MemTpl, DataTpl>|(old:DataTpl?)->(DataTpl?), force:boolean) -> (boolean),
	SaveMemory: (self:KrossSync<MemTpl, DataTpl>, key:string, data:Data<MemTpl, DataTpl>|(old:Data<MemTpl, DataTpl>?)->(Data<MemTpl ,DataTpl>?), expiration:number, force:boolean) -> (boolean),
	---- 삭제 함수: Remove 반환값 순서는 DataStore, MemoryStore 성공 여부다.----
	Remove: (self:KrossSync<MemTpl, DataTpl>, key:string) -> (boolean, boolean),
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
local function BuildData<memory,data>(lastUpdate,Data:data,Memory:memory,OnlineServers:{[number]:string}):Data<memory,data>
	return {lastUpdate=lastUpdate,
		dataCreateTime=os.time(),
		memory=Memory,
		data=Data,
		onlineServers=OnlineServers,
	}
end

-- MemoryStore 값이 삭제 표식이면 만료 시각을 반환한다.
-- 구버전 표식처럼 만료 시각이 없다면 안전하게 무기한 삭제로 취급한다.
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

-- DataStore 접근 전후에 공유 tombstone을 읽어 삭제된 데이터의 부활을 막는다.
-- 첫 번째 반환값은 조회 성공 여부이며 두 번째 값은 활성 tombstone 만료 시각이다.
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

-- DataStore 키를 재시도 정책에 따라 삭제한다. retryLimit이 있으면 해당 호출에만 별도 제한을 적용한다.
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

-- 즉시 삭제가 실패한 키마다 백그라운드 정리 작업을 하나만 유지한다.
local function ScheduleDataRemovalCleanup(self:KrossSync<unknown,unknown>,key:string,removedUntil:number?)
	if self.PendingRemovalCleanup[key] then
		return
	end

	-- DataStore 삭제가 일시적으로 실패해도 tombstone이 살아 있는 동안 계속 정리한다.
	self.PendingRemovalCleanup[key] = true
	task.spawn(function()
		local fallbackDeadline = os.time() + math.max(self.ExpirationTime,REMOVAL_TOMBSTONE_MIN_TIME)
		local deadline = removedUntil and removedUntil < math.huge and removedUntil or fallbackDeadline
		while os.time() < deadline do
			-- 한 번의 삭제 호출이 deadline을 넘기지 않도록 바깥 반복마다 한 번만 시도한다.
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

-- 우선 즉시 삭제하고 실패하면 tombstone 유효 시간 안에서 비동기 재시도를 예약한다.
local function EnsureDataStoreRemoved(self:KrossSync<unknown,unknown>,key:string,removedUntil:number?):boolean
	local success = RemoveDataStoreKey(self,key)
	if not success then
		ScheduleDataRemovalCleanup(self,key,removedUntil)
	end
	return success
end

-- DataStore 쓰기 후 tombstone 확인만 실패했을 때 공유 삭제 상태를 다시 확인한다.
local function ScheduleRemovalVerification(self:KrossSync<unknown,unknown>,key:string)
	if self.PendingRemovalVerification[key] then
		return
	end

	-- 저장은 완료됐지만 MemoryStore 확인만 실패한 경우 호출자에게 재저장을 요구하지 않고 별도로 확인한다.
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

-- MemoryStore 저장이 확정된 뒤 DataStore 저장만 실패한 키를 최신 로컬 값으로 다시 저장한다.
-- 키마다 작업을 하나만 유지하며, 후속 MemoryStore 변경이 있으면 재시도 시 최신 LastData를 사용한다.
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
function KrossSync:Get(key,force)	
	-- 같은 키에서 조회와 저장이 겹치지 않게 한다. force도 잠금은 우회하지 않는다.
	if self.IsGetting[key] or self.IsSaving[key] then
		return false
	end
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

			if force ~= true then
				-- 새 영구 데이터를 만들기 전에 실제 DataStore 쓰기 가능 여부를 확인한다.
				local StoreStatus = IsStoreOkay("Data","High")
				if StoreStatus.Data == false then
					return false
				end
			end
			local Time = os.time()
			-- DataStore에는 memory 없이 data만, MemoryStore에는 전체 래퍼를 기록한다.
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
				-- 부분 성공도 호출자가 구분할 수 있도록 상태 테이블을 함께 반환한다.
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


-- DataStore에는 전체 래퍼가 아니라 data 필드만 저장되어 있다.
function KrossSync:GetData(key,force)
	-- 로컬 삭제 상태와 키별 잠금을 먼저 확인한다.
	if IsKeyLocallyRemoved(self,key) or self.IsGetting[key] or self.IsSaving[key] then
		return false
	end
	-- 삭제된 키의 부활을 막기 위해 DataStore 읽기에도 MemoryStore tombstone 확인이 필요하다.
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
		-- nil은 오류가 아니라 아직 생성되지 않은 키를 뜻한다.
		return nil
	end

	result = ReconcileValueWithTemplate(result, self.DataTemplate)

	if self.LastData[key] then
		-- 이미 임시 상태가 있으면 새 영구 데이터만 합쳐 MemoryStore와 캐시를 맞춘다.
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
		-- 로컬 캐시가 없으면 템플릿 memory와 현재 서버 목록으로 MemoryStore를 새로 만든다.
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


-- 서버 간 공유 래퍼를 읽고 현재 서버의 JobId가 빠졌다면 원자적으로 등록한다.
function KrossSync:GetMemory(key,force) 
	-- 조회 중인 키를 다른 작업이 동시에 덮어쓰지 않게 한다.
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
	elseif GetRemovalExpiration(result) then
		self.RemovedKeys[key] = nil
		return nil
	elseif IsKeyLocallyRemoved(self,key) then
		return false
	end

	-- 이전 버전 데이터에 새 템플릿 필드를 채우고 서버 목록을 정리한다.
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
function KrossSync:Save(key,data,expiration,force)
	-- 함수형 갱신과 전체 래퍼 입력만 허용한다.
	if self.IsGetting[key] or self.IsSaving[key] or (typeof(data)~="function" and typeof(data)~="table") then
		return false
	end
	if force ~= true and (IsCritical.Total == true or State.Total ~= "Access") then
		return false
	end

	expiration = expiration or self.ExpirationTime

	if self.LastData[key] and self.LastData[key].dataCreateTime + SAVE_DATA_TIME <= os.time() then

		-- 공유 메모리를 먼저 갱신한 후 확정된 data 필드를 영구 저장한다.
		local m = self:SaveMemory(key,data,expiration,force)
		if not m then
			return false
		end
		local d = self:SaveData(key,self.LastData[key],force)
		if d then
			-- 이전에 예약된 작업이 있더라도 최신 값이 저장됐으므로 취소한다.
			self.PendingDataSave[key] = nil
			return true
		elseif IsKeyLocallyRemoved(self,key) then
			return false
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
	if IsKeyLocallyRemoved(self,key) then
		return false
	end

	if self.IsGetting[key] or self.IsSaving[key] or (typeof(data)~="function" and typeof(data)~="table") then
		return false
	end
	-- 삭제된 키의 부활을 막기 위해 쓰기 직전과 직후에 MemoryStore tombstone을 확인한다.
	if force ~= true and (IsCritical.Data or IsCritical.Memory or State.Data ~= "Access" or State.Memory ~= "Access") then
		return false
	end

	-- 저장 성공 후 로컬 전체 래퍼를 복원하기 위해 이전 임시 상태를 보관한다.
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
			-- 함수에는 DataStore에 저장된 순수 data 값만 전달한다.
			return self.Store:UpdateAsync(key,function(oldData)
				savedData = data(oldData)
				hasSavedData = true
				return savedData
			end)

		elseif typeof(data)=="table" then
			-- 전체 래퍼 중 영구 저장 대상인 data 필드만 분리한다.
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
		-- 쓰기와 삭제가 교차했는지 다시 확인한다.
		local verificationSucceeded, removedAfterSave = ReadSharedRemoval(self,key)
		if not verificationSucceeded then
			-- DataStore 쓰기는 이미 완료됐다. 함수형 저장의 중복 실행을 막기 위해
			-- 성공을 유지하고 tombstone 확인만 백그라운드에서 다시 수행한다.
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
			-- MemoryStore 전용 필드와 서버 목록은 유지하고 data만 저장 결과로 교체한다.
			local lastData = oldLastData or BuildData(os.time(), DeepCopyTable(self.DataTemplate), nil, {game.JobId})
			self.LastData[key] = BuildData(lastData.dataCreateTime, savedData, lastData.memory, lastData.onlineServers)
		end

		return true
	end
end


-- 전체 동기화 래퍼를 MemoryStore에 저장한다. 함수 콜백에는 최신 래퍼가 전달된다.
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

	-- MemoryStore 항목이 만료됐을 때 사용할 로컬 대체값을 보관한다.
	local oldLastData = self.LastData[key]
	local savedMemoryData
	local hasSavedMemoryData = false
	local blockedByRemoval = false
	local removedUntil

	self:SetSaving(key,true)

	local function action()
		-- UpdateAsync 안에서 tombstone 확인과 데이터 갱신을 한 번에 처리한다.
		return self.Map:UpdateAsync(key,function(oldData)
			savedMemoryData = nil
			hasSavedMemoryData = false
			blockedByRemoval = false
			removedUntil = GetActiveRemovalExpiration(oldData)

			if removedUntil then
				-- 삭제 표식은 어떤 일반 저장으로도 덮어쓰지 않는다.
				blockedByRemoval = true
				return oldData
			elseif GetRemovalExpiration(oldData) then
				oldData = nil
			end

			if typeof(data)== "function" then
				-- 항목이 사라졌다면 마지막 로컬 캐시 또는 템플릿 래퍼를 함수에 전달한다.
				local fallbackData = oldLastData or BuildData(os.time(), DeepCopyTable(self.DataTemplate), DeepCopyTable(self.MemoryTemplate), {game.JobId})
				savedMemoryData = data(oldData or fallbackData)
			elseif typeof(data)== "table" then
				-- 외부 테이블을 직접 보관하지 않도록 복사하고 최신 서버 목록을 병합한다.
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


-- UpdateAsync로 다른 서버의 저장과 원자적으로 순서를 정하며 tombstone을 기록한다.
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


-- 단독 DataStore 삭제 API가 사용하는 내부 래퍼
local function RemoveDataKey(self:KrossSync<unknown,unknown>, key:string):boolean
	return RemoveDataStoreKey(self,key)
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

-- MemoryStore에 tombstone을 먼저 기록한 뒤 DataStore를 삭제해 다른 서버의 재저장을 차단한다.
function KrossSync:Remove(key)
	-- 삭제 중에는 같은 키의 다른 로컬 요청을 차단한다.
	if self.IsGetting[key] or self.IsSaving[key] then
		return false, false
	end

	self:SetSaving(key,true)

	-- 자동 조회 작업이 남아 있어도 삭제를 확인할 수 있도록 최소 유지 시간을 보장한다.
	local tombstoneExpiration = math.max(self.ExpirationTime,REMOVAL_TOMBSTONE_MIN_TIME)
	local memoryRemoved = SetRemovalTombstone(self,key,tombstoneExpiration)
	local dataRemoved = false
	if memoryRemoved then
		-- 공유 삭제 표식 기록에 성공한 경우에만 영구 데이터를 삭제한다.
		dataRemoved = EnsureDataStoreRemoved(self,key,self.RemovedKeys[key])
	end

	self:SetSaving(key,false)
	self.IsGetting[key] = nil
	self.IsSaving[key] = nil

	return dataRemoved, memoryRemoved
end


-- DataStore만 즉시 삭제하는 저수준 함수다.
-- 다른 서버가 아직 동기화 중이면 마지막 UnSync에서 다시 저장될 수 있으므로 영구 삭제에는 Remove를 사용한다.
function KrossSync:RemoveData(key) local self = self :: KrossSync<unknown,unknown>
	if self.IsGetting[key] or self.IsSaving[key] then
		return false
	end

	self:SetSaving(key,true)
	local success = RemoveDataKey(self,key)

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
function KrossSync:RemoveMemory(key) local self = self :: KrossSync<unknown,unknown>
	if self.IsGetting[key] or self.IsSaving[key] then
		return false
	end

	self:SetSaving(key,true)
	local success = RemoveMemoryKey(self,key)

	if success then
		-- 단독 MemoryStore 삭제는 기존 로컬 tombstone 상태도 해제한다.
		self.LastData[key] = nil
		self.RemovedKeys[key] = nil
	end

	self:SetSaving(key,false)
	self.IsGetting[key] = nil
	self.IsSaving[key] = nil
	return success
end


-- 현재 서버의 JobId를 제거하고, 마지막 서버라면 최신 data 필드를 DataStore에 최종 저장한다.
function KrossSync:UnSync(key)
	-- 동기화하지 않은 키는 해제할 수 없다.
	if not self.LastData[key] then
		return false
	end

	local LastData
	local function data(old:Data<unknown,unknown>)
		-- 중복된 현재 JobId도 모두 제거해 서버 목록을 정상화한다.
		old.onlineServers = NormalizeOnlineServers(old.onlineServers)
		for i = #old.onlineServers,1,-1 do
			if old.onlineServers[i] == game.JobId then
				table.remove(old.onlineServers,i)
			end
		end
		LastData = old
		return old
	end
	-- 종료 처리에서는 전역 상태가 Error여도 마지막 정리를 시도하도록 force를 사용한다.
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
			-- 마지막 서버가 나갈 때 MemoryStore의 최신 data를 DataStore에 최종 반영한다.
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
		-- 키별 로컬 잠금
		IsGetting = {},
		IsSaving = {},
		---- 인스턴스별 신호----
		OnNewData = signal(), -- 자동 동기화로 memory 내용이 바뀌었을 때 전체 래퍼 전달
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

-- 개별 저장소 상태를 갱신하고 우선순위에 따라 전체 상태를 계산한다.
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
	-- 서버 종료 시 현재 서버를 모든 키에서 해제하고 마지막 서버인 키는 최종 저장한다.
	game:BindToClose(function()
		-- Roblox 종료 제한보다 여유 있게 25초 안에서 정리를 마친다.
		local CLOSE_DEADLINE = 25
		local CloseTime = os.time()
		for key,v in pairs(KrossSync.LastData) do
			-- 키마다 독립적으로 UnSync를 재시도해 한 키의 실패가 다른 키를 막지 않게 한다.
			task.spawn(function()
				KrossSync:UnSync(key)
				while KrossSync.LastData[key] do task.wait(1)
					KrossSync:UnSync(key)
				end
			end)
		end
		while task.wait() do
			-- 모든 로컬 캐시가 해제되면 종료 대기를 끝낸다.
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

	-- 예약 당시의 캐시가 여전히 활성 상태일 때만 다른 서버의 변경을 가져온다.
	-- 이 검사가 없으면 오래된 작업이 UnSync 직후 JobId와 LastData를 다시 만들 수 있다.
	local function AutoGetMemory(key, previousData)
		local activeData = KrossSync.LastData[key]
		if activeData ~= previousData or not activeData.memory then
			return
		end

		local memoryData = KrossSync:GetMemory(key,false)

		if memoryData == nil then
			-- 항목이 만료됐더라도 이 서버가 계속 동기화 중인 키만 MemoryStore에 복구한다.
			local currentData = KrossSync.LastData[key]
			if currentData and currentData.memory then
				KrossSync:SaveMemory(key,currentData,KrossSync.ExpirationTime,false)
			end
			return
		elseif memoryData == false then
			return
		end
		-- GetMemory가 양보한 사이 UnSync/Remove가 완료됐다면 오래된 작업의 결과를 폐기한다.
		if KrossSync.LastData[key] ~= memoryData then
			return
		end

		-- 임시 memory 내용이 실제로 달라진 경우에만 OnNewData를 발생시킨다.
		local memoryChanged = not deepEqual(previousData.memory,memoryData.memory)
		memoryData.lastUpdate = os.time()
		memoryData.dataCreateTime = math.max(previousData.dataCreateTime or 0,memoryData.dataCreateTime or 0)
		KrossSync.LastData[key] = memoryData

		if memoryChanged then
			KrossSync.OnNewData:Fire(memoryData)
		end
	end

	-- 인스턴스 생성 전에 캐시에 들어온 키가 있다면 첫 조회를 예약한다.
	local tasks = {}::{[string]:thread}
	for key, data in pairs(KrossSync.LastData) do
		tasks[key] = task.spawn(function() 
			task.wait(math.max(0, data.dataCreateTime+AUTO_GET_MEMORY_TIME - os.time()))
			AutoGetMemory(key,data)
		end)
	end

	-- 키별 마지막 자동 조회 시각으로 최소 조회 간격을 보장한다.
	local LastGetTime = {}
	task.spawn(function()
		-- 초기 예약 작업이 모두 끝난 뒤 반복 동기화 루프로 진입한다.
		while task.wait() do
			local i = 0
			for key,thread in pairs(tasks) do
				i+=1 break
			end
			if i == 0 then break end
		end

		while true do

			-- 현재 로컬에서 사용 중인 모든 키를 병렬로 조회한다.
			for key, data in pairs(KrossSync.LastData) do
				tasks[key]  = task.spawn(function() 
					task.wait(math.max(0, (LastGetTime[key] or 0) +  AUTO_GET_MEMORY_TIME - os.time()))
					task.wait(math.max(0, data.dataCreateTime + AUTO_GET_MEMORY_TIME - os.time()))
					AutoGetMemory(key,data)

					LastGetTime[key] = os.time()
					tasks[key] = nil
				end)

			end

			-- 이번 주기의 모든 키 조회가 끝날 때까지 기다린다.
			while task.wait() do
				local i = 0
				for key,thread in pairs(tasks) do
					i+=1
					break
				end
				if i == 0 then break end
			end

			-- 오래 사용하지 않은 키의 조회 기록을 정리한다.
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
