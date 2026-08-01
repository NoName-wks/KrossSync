
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

--[[ 안내
--------------------------------------------------------------------------------
AI를 이용하여 주석을 작성해서 번역이 없어도 알아 볼 수 있는 단어도 번역되었습니다 (ex: README -> 안내)

NoRemove 버전 (이 모듈 대신 V.0.0.1을 사용하세요.) [테스트 모듈]
V.0.0.0

--------------------------------------------------------------------------------

]]

-----------조정 가능한 설정값---------

local SAVE_DATA_TIME = 60 -- Save 호출 시 영구 데이터까지 갱신하는 최소 간격(초)
local AUTO_GET_MEMORY_TIME = 15 -- MemoryStore를 자동 확인하는 간격(초)
local ERROR_RESET_TIME = 30 -- 치명적 오류 상태를 다시 검사하기까지의 대기 시간(초)
local CRITICAL_ERROR_COUNT = 5 -- 이 횟수 이상 오류가 쌓이면 해당 저장소를 치명적 상태로 전환

-----------------------------------의존 모듈
---@module Signal
local signal = require(game.ReplicatedStorage.scr.Library.Signal)

-- 최근 저장소 오류를 순서대로 관리하는 내부 큐입니다.
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

	local function isEmpty(self)
		return self._first > self._last 
	end

	local function enqueue(self, value)
		-- 앞쪽의 비어 있는 공간이 커지면 배열을 압축해 인덱스가 계속 증가하지 않게 합니다.
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
		if self:isEmpty() then
			warn("EmptyQueue")
			return nil
		end

		return self._queue[self._first]
	end

	local function getSize(self)
		return self._last - self._first + 1
	end

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


------------------------------------

type StateType = "NotReady" | "NoInternet" | "NoAccess" | "Access" | "Error"
type State = {Total: StateType, Data: StateType, Memory: StateType}

-- DataStore의 영구 데이터와 MemoryStore의 임시 상태를 함께 표현하는 래퍼입니다.
export type Data<MemTpl,DataTpl> = {
	lastUpdate: number, -- 직전 동기화 기준 시각
	dataCreateTime: number, -- 현재 래퍼를 만든 시각
	memory: MemTpl,
	data: DataTpl,
	onlineServers: {[number]:string}, -- 이 키를 사용 중인 서버의 JobId 목록
}
-- KrossSyncService.get이 반환하는 저장소별 동기화 객체의 공개 형식입니다.
export type KrossSync<MemTpl,DataTpl> = {
	MaxRetryTime:number|nil,
	Store: DataStore,
	Map: MemoryStoreHashMap,
	MapName: string,
	DataTemplate: DataTpl,
	MemoryTemplate: MemTpl,
	ExpirationTime:number,
	LastData: {[string]:Data<MemTpl, DataTpl>},
	--
	IsGetting: {[string]:boolean}, 
	IsSaving: {[string]:boolean}, 
	----.signal----
	OnNewData: signal.Signal<Data<MemTpl, DataTpl> >,
	OnGettingToggle: signal.Signal<boolean> ,
	OnSavingToggle: signal.Signal<boolean>,
	----:func----
	Get: (self:KrossSync<MemTpl, DataTpl>, key:string, force:boolean)-> (Data<MemTpl?, DataTpl> | false, {Data:boolean,Memory:boolean}?),
	GetData: (self:KrossSync<MemTpl, DataTpl>, key:string, force:boolean) -> (Data<nil, DataTpl> | nil | false ),
	GetMemory: (self:KrossSync<MemTpl, DataTpl>, key:string, force:boolean) -> (Data<MemTpl, DataTpl> | nil | false ),
	--
	Save: (self:KrossSync<MemTpl, DataTpl>, key:string, data:Data<MemTpl, DataTpl>|(old:Data<MemTpl, DataTpl>?)->(Data<MemTpl, DataTpl>?), expiration:number, force:boolean) -> (boolean),
	SaveData: (self:KrossSync<MemTpl, DataTpl>, key:string, data:Data<MemTpl, DataTpl>|(old:DataTpl?)->(DataTpl?), force:boolean) -> (boolean),
	SaveMemory: (self:KrossSync<MemTpl, DataTpl>, key:string, data:Data<MemTpl, DataTpl>|(old:Data<MemTpl, DataTpl>?)->(Data<MemTpl ,DataTpl>?), expiration:number, force:boolean) -> (boolean),
	---
	UnSync: (self:KrossSync<MemTpl, DataTpl>, key:string) -> boolean,
}

local rawError = error
local rawWarn = warn
local rawPrint = print

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

-- 치명적 상태 변경: (전체 치명 여부, 저장소별 치명 상태)
local OnCriticalToggle = signal()::signal.Signal<boolean,typeof(IsCritical)>
-- 저장 오류: (위치[1=DataStore, 2=MemoryStore], 오류, 저장소 이름, 키, 입력값/함수)
local OnError  = signal()::signal.Signal<number,string,string,string,any>
-- 새 동기화 객체의 백그라운드 작업을 연결하기 위한 내부 신호입니다.
local OnNewKrossSync = signal()::signal.Signal<KrossSync<any,any>>

local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")
local MemoryStoreService = game:GetService("MemoryStoreService")


local dataErrorQueue = Queue.new()
local memoryErrorQueue = Queue.new()

--[[
지수 백오프와 지터를 적용해 action을 재시도합니다.
`jitterPercent` 범위는 0~100이며 기본값은 50입니다.
`action`은 내부에서 pcall로 감싸므로 호출자가 따로 pcall할 필요가 없습니다.
`errorAction`에서 발생한 오류는 보호되지 않습니다.

]]
local function ExponentialJitterBackoff(
	cap: number,
	maxRetries: number?, 
	jitterPercent: number?, 
	action: () -> ...any, 
	errorAction: ((attempt: number, result: any, cap: number) -> ())?
) : (boolean, ...any|"action is nil")


	local maxAttempts = (maxRetries and maxRetries >= 2) and maxRetries or math.huge -- nil 또는 2 미만이면 제한 없이 재시도
	local jitter = (jitterPercent or 50) / 100 -- 백분율을 0~1 범위로 정규화

	if not action then
		warn("[ExponentialJitterBackoff] action is nil")
		return false, "action is nil"
	end

	local attempt = 0
	local success: boolean
	local results: {any}

	while attempt < maxAttempts do

		results = table.pack(pcall(action)) -- 여러 반환값을 잃지 않도록 pack으로 보관
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

			local baseWait = math.pow(2,attempt) -- 지터를 적용하기 전의 지수 대기 시간

			local waitTime = baseWait + (math.random() * baseWait * jitter)
			waitTime = math.min(waitTime, cap or math.huge)
			task.wait(waitTime)
		end
	end

	return false, results[2]
end


-- 템플릿과 실제 데이터가 같은 중첩 테이블을 공유하지 않도록 깊은 복사합니다.
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

-- MemoryStore 변경 감지에 사용하는 재귀 비교입니다.
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

-- 기존 값은 유지하고 템플릿에 새로 추가된 문자열 키만 채웁니다.
-- 배열의 숫자 인덱스는 사용자 데이터로 간주하여 자동 추가하지 않습니다.
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

local function ReconcileValueWithTemplate(value, template)
	if type(value) == "table" and type(template) == "table" then
		ReconcileTable(value, template)
	end
	return value
end

-- 래퍼 안의 영구 데이터와 메모리 데이터를 각각의 템플릿에 맞춰 보정합니다.
local function ReconcileDataWithTemplates(data, dataTemplate, memoryTemplate)
	if type(data) ~= "table" then
		return data
	end

	ReconcileValueWithTemplate(data.data, dataTemplate)
	ReconcileValueWithTemplate(data.memory, memoryTemplate)
	return data
end

-- 저장소 접근 가능 여부를 검사합니다. High는 실제 쓰기 요청까지 수행합니다.
local function IsStoreOkay(Type:nil|"Data"|"Memory",lvl:nil|"High" ):{Data:boolean|nil, Memory:boolean|nil}

	local function ChackDataStore(lvl)
		if lvl == "High" then
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

-- 두 저장소의 값을 KrossSync 공통 래퍼 형태로 조립합니다.
local function BuildData<memory,data>(lastUpdate,Data:data,Memory:memory,OnlineServers:{[number]:string}):Data<data,memory>
	return {lastUpdate=lastUpdate,
		dataCreateTime=os.time(),
		memory=Memory,
		data=Data,
		onlineServers=OnlineServers,
	}
end

-------------------------------------------------------------------공개 객체-------------------------------------


local KrossSync = {} ::KrossSync<unknown,unknown>
	KrossSync.__index = KrossSync



-- 키별 읽기 상태를 갱신하고 실제로 값이 바뀐 경우에만 신호를 보냅니다.
function KrossSync:SetGetting(key,value)
	if self.IsGetting[key] ~= value then
		self.IsGetting[key] = value
		self.OnGettingToggle:Fire(value)
	end
end

-- 키별 쓰기 상태를 갱신하고 실제로 값이 바뀐 경우에만 신호를 보냅니다.
function KrossSync:SetSaving(key,value)
	if self.IsSaving[key] ~= value then
		self.IsSaving[key] = value
		self.OnSavingToggle:Fire(value)
	end
end


-- MemoryStore를 우선 조회하고, 없으면 DataStore에서 복구하거나 템플릿으로 새 데이터를 만듭니다.
-- 성공 시 래퍼를, 데이터가 없거나 요청할 수 없는 상태이면 false/nil을 하위 메서드 규칙에 따라 반환합니다.
function KrossSync:Get(key,force)	
	if force ~= true and (self.IsGetting[key] or self.IsSaving[key] or IsCritical.Total or State.Total ~= "Access") then
		return false
	end

	local memory = self:GetMemory(key,force)

	if (memory ~= false) and (memory ~= nil) then -- MemoryStore에서 찾았으면 즉시 반환
		return memory

	elseif memory == nil then -- MemoryStore에 키가 없으므로 DataStore에서 복구
		local data2 = self:GetData(key,force)

		if (data2 ~= false) and (data2 ~= nil) then -- 영구 데이터가 있으면 메모리 래퍼도 다시 생성
			local m = self:SaveMemory(key, BuildData(os.time(), DeepCopyTable(data2.data), DeepCopyTable(self.MemoryTemplate), {game.JobId}, false, false), self.ExpirationTime, force)
			return data2, {Data = true,Memory=((m~=false) and (m~=nil)) }

		elseif data2 == nil then -- 어느 저장소에도 없으면 템플릿으로 최초 생성

			if force ~= true then -- 새 키를 만들기 전 DataStore 실제 쓰기 가능 여부 확인
				local StoreStatus = IsStoreOkay("Data","High")
				if StoreStatus.Data == false then
					return false
				end
			end
				--print("Data is nil, make data | key:",key) 

			local Time = os.time()
			local d = self:SaveData(key, BuildData(Time, DeepCopyTable(self.DataTemplate), nil, {game.JobId}, false, false), force)
			local m = self:SaveMemory(key, BuildData(Time, DeepCopyTable(self.DataTemplate), DeepCopyTable(self.MemoryTemplate), {game.JobId}, false, false), self.ExpirationTime, force)

			if d and m then -- 두 저장소 모두 생성 성공
				return BuildData(Time, DeepCopyTable(self.DataTemplate), DeepCopyTable(self.MemoryTemplate), {game.JobId}, false, false)

			elseif d then	-- DataStore만 생성 성공
				return BuildData(Time, DeepCopyTable(self.DataTemplate), nil, {game.JobId}, false, false), {Data=true, Memory=false}
					
			elseif m then	-- MemoryStore만 생성 성공
				return BuildData(Time, nil, DeepCopyTable(self.MemoryTemplate), {game.JobId}, false, false), {Data=false, Memory=true}
			else -- 두 저장소 모두 실패
				return false, {Data=false, Memory=false}
			end	

		end
	end

	return false
end
	
	
-- DataStore에서 영구 데이터만 읽습니다. nil은 키 없음, false는 요청 실패/차단을 뜻합니다.
function KrossSync:GetData(key,force)
	if force ~= true and (self.IsGetting[key] or self.IsSaving[key]or IsCritical.Data or State.Data ~= "Access") then
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
		40,
		self.MaxRetryTime,
		nil,
		action,
		errorAction
	)

	self:SetGetting(key,false)

	if not success then

		warn("GetData failed:", key, result)
		return false
	end
		
	if result == nil then
		return nil
	end

	-- 오래된 저장 데이터에 템플릿의 새 필드를 추가합니다.
	result = ReconcileValueWithTemplate(result, self.DataTemplate)

	if self.LastData[key] then
		local data = BuildData(self.LastData[key].dataCreateTime, result, self.LastData[key].memory, self.LastData[key].onlineServers)
		self.LastData[key] = data
		return data
	else
		local memory = DeepCopyTable(self.MemoryTemplate)
		memory = ReconcileValueWithTemplate(memory, self.MemoryTemplate)
		local m = self:SaveMemory(key, BuildData(os.time(), result, memory, {game.JobId}, false, false), self.ExpirationTime, force)
		local data
		if m == false then
			data = BuildData(os.time(), result, nil, {game.JobId}, false, false)
		else
			data = BuildData(os.time(), result, memory, {game.JobId}, false, false)
		end
		self.LastData[key] = data
		return data
	end
end


-- MemoryStore의 전체 래퍼를 읽고 현재 서버를 onlineServers에 한 번만 등록합니다.
-- nil은 키 없음, false는 요청 실패/차단을 뜻합니다.
function KrossSync:GetMemory(key,force,retryTime) 
	if force ~= true and (self.IsGetting[key] or self.IsSaving[key] or IsCritical.Memory or State.Memory ~= "Access") then
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
		return false
	end

	if result == nil then
		return nil
	end


	local data = ReconcileDataWithTemplates(result, self.DataTemplate, self.MemoryTemplate)
	data.onlineServers = data.onlineServers or {}

	local found = false
	for _, id in pairs(data.onlineServers) do
		if id == game.JobId then
			found = true
		end
	end
	if not found then
		table.insert(data.onlineServers, game.JobId)
		self:SaveMemory(key, data, self.ExpirationTime, force)
	end
		
	self.LastData[key] = data
	return data

end


-- 평소에는 빠른 MemoryStore만 갱신하고, SAVE_DATA_TIME이 지나면 DataStore도 함께 저장합니다.
function KrossSync:Save(key,data,expiration,force)
	if force ~= true and (self.IsSaving[key] or (typeof(data)~="function" and typeof(data)~="table") or IsCritical.Total == true or State.Total ~= "Access") then
		return false
	end
		
	expiration = expiration or self.ExpirationTime
		
	if self.LastData[key] and self.LastData[key].dataCreateTime + SAVE_DATA_TIME <= os.time() then

		local m = self:SaveMemory(key,data,expiration,force)
		local d = self:SaveData(key,data,force)

		return m and d
	else

		return self:SaveMemory(key,data,expiration,force)
	end
end


-- DataStore에는 래퍼가 아닌 data 필드만 저장하여 영구 저장 공간을 절약합니다.
-- 함수형 입력은 UpdateAsync의 기존 영구 데이터를 받고, nil을 반환하면 저장을 취소합니다.
function KrossSync:SaveData(key,data,force) self = self::KrossSync<{},{}>
	if force ~= true and (self.IsSaving[key] or (typeof(data)~="function" and typeof(data)~="table") or IsCritical.Data == true or State.Data ~= "Access") then
		return false
	end

	local oldLastData = self.LastData[key]
	local savedData
	local hasSavedData = false

	self:SetSaving(key,true)

	local function action()
		if typeof(data)=="function" then
			-- 동시 쓰기 충돌을 줄이기 위해 함수형 갱신은 UpdateAsync를 사용합니다.
			return self.Store:UpdateAsync(key,function(oldData)
				savedData = data(oldData)
				hasSavedData = true
				return savedData
			end)

		elseif typeof(data)=="table" then
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

	self:SetSaving(key,false)
	
	if not success then
		OnError:Fire(1,result,self.Store.Name,key,data)
		return false
	elseif result == nil and typeof(data) == "function" then
		return false
	else
		if hasSavedData then
			local lastData = oldLastData or BuildData(os.time(), DeepCopyTable(self.DataTemplate), nil, {game.JobId}, false, false)
			self.LastData[key] = BuildData(lastData.dataCreateTime, savedData, lastData.memory, lastData.onlineServers)
		end
			
		return true
	end
end


-- MemoryStore에는 memory, data, onlineServers를 포함한 전체 래퍼를 저장합니다.
-- 함수형 입력은 최신 MemoryStore 값(없으면 로컬 캐시/템플릿)을 받아 원자적으로 갱신합니다.
function KrossSync:SaveMemory(key,data,expiration,force)
	if force ~= true and (self.IsSaving[key] or (typeof(data)~="function" and typeof(data)~="table") or IsCritical.Memory == true or State.Memory ~= "Access") then
		return false
	end
		
	expiration = expiration or self.ExpirationTime

	local oldLastData = self.LastData[key]
	local savedMemoryData
	local hasSavedMemoryData = false

	self:SetSaving(key,true)

	local function action()
		if typeof(data)=="function" then
			return self.Map:UpdateAsync(key,function(oldData)
				savedMemoryData = data(oldData or oldLastData  or BuildData(os.time(), DeepCopyTable(self.DataTemplate), DeepCopyTable(self.MemoryTemplate), {game.JobId}))
				hasSavedMemoryData = true
				return savedMemoryData
			end,expiration)

		elseif typeof(data)=="table" then
			savedMemoryData = data
			hasSavedMemoryData = true
			return self.Map:SetAsync(key,savedMemoryData,expiration)
		end
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
	
	if not success then
		OnError:Fire(2,result,self.Store.Name,key,data)
		return false
	elseif result == nil and typeof(data) == "function" then
		return false
	else
		if hasSavedMemoryData then
			self.LastData[key] = savedMemoryData
		end

		return true
	end
end
	

-- 현재 서버의 JobId를 제거합니다. 마지막 서버라면 최신 data를 DataStore에 최종 저장합니다.
function KrossSync:UnSync(key)
	local LastData
	local function data(old:Data<{},{}>)
		for i,v in pairs(old.onlineServers or {}) do
			if v == game.JobId then
				table.remove(old.onlineServers, i)
				LastData = old
				break
			end
		end
		return old
	end
	local success = self:SaveMemory(key,data,self.ExpirationTime,true)
	if not success then
		return false
	else
		if not LastData then
			self.LastData[key] = nil
			return false
		end
		if #(LastData.onlineServers or {})== 0 then
			-- 이 키를 사용하는 서버가 더 없으므로 메모리 상태를 영구 데이터에 반영합니다.
			success = self:SaveData(key,LastData,true)
			self.LastData[key] = nil
			return success
		end

		self.LastData[key] = nil

		return true
	end

end


---------------------------------------------------------
---------------------------------------------------------

export type KrossSyncService = {
	get:<DataTemplate,MemoryTemplate>(StoreName:string,DataTemplate:DataTemplate,MemoryTemplate:MemoryTemplate,NormalExpirationTime:number?)->(KrossSync<DataTemplate,MemoryTemplate> | false),
	KrossSyncs: {[string]:KrossSync<unknown,unknown> | nil},
	State: State,
	IsCritical: typeof(IsCritical),
	OnCriticalToggle:signal.Signal<boolean,typeof(IsCritical)>,
	OnError:signal.Signal<number,string,string,string,any>
}

local KrossSyncService:KrossSyncService = {}


-----------------------공개 값------------------------

KrossSyncService.KrossSyncs = {}
-- 전체/DataStore/MemoryStore의 현재 접근 상태
KrossSyncService.State = State
KrossSyncService.IsCritical = IsCritical

----공개 신호----

-- 반복 오류로 치명적 상태가 바뀔 때 발생
KrossSyncService.OnCriticalToggle = OnCriticalToggle
-- 저장 요청 오류가 발생할 때 위치와 요청 정보를 전달
KrossSyncService.OnError  = OnError

-----------------------공개 함수---------------------

-- StoreName마다 하나의 KrossSync 객체를 만들고 캐시합니다.
-- 같은 이름으로 다시 요청할 때 템플릿 테이블 참조가 다르면 false를 반환합니다.
function KrossSyncService.get(StoreName,DataTemplate,MemoryTemplate,NormalExpirationTime)
	if KrossSyncService.KrossSyncs[StoreName] then
		if KrossSyncService.KrossSyncs[StoreName].DataTemplate ~= DataTemplate or KrossSyncService.KrossSyncs[StoreName].MemoryTemplate ~= MemoryTemplate then
			return false
		end
		
		return KrossSyncService.KrossSyncs[StoreName]
	end
	
	local self={
		MaxRetryTime=nil,
		Store = DataStoreService:GetDataStore(StoreName),
		Map = MemoryStoreService:GetHashMap(StoreName),
		MapName = StoreName,
		DataTemplate = DataTemplate,
		MemoryTemplate = MemoryTemplate,
		ExpirationTime = NormalExpirationTime or 600,
		LastData = {},
		--
		IsGetting = {},
		IsSaving = {},
		----.signal----
		OnNewData = signal(), -- 다른 서버가 바꾼 메모리 데이터가 감지될 때 새 래퍼 전달
		OnGettingToggle = signal(), -- 읽기 진행 여부(boolean) 전달
		OnSavingToggle = signal(), -- 쓰기 진행 여부(boolean) 전달
		-- TODO: 덮어쓰기 위치와 키를 알리는 OnOverwrite 신호 추가
	}

	self = setmetatable(self,KrossSync)::KrossSync<typeof(DataTemplate),typeof(MemoryTemplate)>

	OnNewKrossSync:Fire(self)
	KrossSyncService.KrossSyncs[StoreName] = self

	return self

end

-----------------------내부 상태 관리------------------- 
-- DataStore/MemoryStore의 치명 여부를 합산하고 변경 신호를 보냅니다.
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

-- 개별 저장소 상태를 갱신하고 우선순위에 따라 전체 상태를 계산합니다.
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
	-- 서버 종료 시 모든 활성 키에서 이 서버를 제거합니다. 마지막 서버인 키는 UnSync가 최종 저장합니다.
	game:BindToClose(function()
		local CLOSE_DEADLINE = 25
		local CloseTime = os.time()
		for key,v in pairs(KrossSync.LastData) do
			task.spawn(function()
				KrossSync:UnSync(key)
				while KrossSync.LastData[key] do task.wait(1)
					KrossSync:UnSync(key)
				end
			end)
		end
		while task.wait() do
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
	
	-- 객체 생성 시 이미 캐시된 키가 있다면 첫 MemoryStore 확인 작업을 예약합니다.
	local tasks = {}::{[string]:thread}
	for key, data in pairs(KrossSync.LastData) do
		tasks[key] = task.spawn(function() 
			task.wait(data.dataCreateTime+AUTO_GET_MEMORY_TIME - os.time())
			if data.memory then
				local m = KrossSync:GetMemory(key,false)
				if m ~= false and m ~= nil then
					data.lastUpdate = data.dataCreateTime
					data.dataCreateTime = os.time()
					if not deepEqual(data.memory,m.memory) then
						data.memory = m.memory
						KrossSync.OnNewData:Fire(m)
					end
				end
			end
		end)
	end

	local LastGetTime = {}
	-- 활성 키의 MemoryStore를 주기적으로 확인하여 다른 서버의 변경을 감지합니다.
	local Getting = task.spawn(function()
		while task.wait() do -- 최초 확인 작업이 모두 끝날 때까지 대기
			local i = 0
			for key,thread in pairs(tasks) do
				i+=1 break
			end
			if i == 0 then break end
		end

		while true do

	
			for key, data in pairs(KrossSync.LastData) do
				tasks[key]  = task.spawn(function() 
					task.wait(math.max(0, (LastGetTime[key] or 0) +  AUTO_GET_MEMORY_TIME - os.time()))
					task.wait(math.max(0, data.dataCreateTime + AUTO_GET_MEMORY_TIME - os.time()))
					if data.memory then 
						
						local m = KrossSync:GetMemory(key,false)
						if m ~= false and m ~= nil then
							
							data.lastUpdate = data.dataCreateTime
							data.dataCreateTime = os.time()
							
							if not deepEqual(data.memory,m.memory) then
								
								data.memory = m.memory
								KrossSync.OnNewData:Fire(m)
							end
						end
					end
					
					LastGetTime[key] = os.time()
					tasks[key] = nil
				end)

			end

			while task.wait() do -- 이번 주기의 확인 작업이 모두 끝날 때까지 대기
				local i = 0
				for key,thread in pairs(tasks) do
					i+=1
					break
				end
				if i == 0 then break end
			end
			
			for key,v in pairs(LastGetTime) do
				if os.time() - v >= AUTO_GET_MEMORY_TIME * 10 then
					LastGetTime[key] = nil
				end
			end

		end
	end)
	
end)

-- 최근 오류가 임계값에 도달하면 잠시 해당 저장소를 치명적 상태로 표시합니다.
OnError:Connect(function(pos, ErrorMessage, Name, Key, Data)
	if pos == 1 then
		dataErrorQueue:enqueue({ErrorMessage,Name,Key,Data})
		if dataErrorQueue:getSize() >= CRITICAL_ERROR_COUNT then
			if IsCritical.Data == true then
				return
			end
			setCritical(true,nil)
			setState("Error",nil)
			task.wait(ERROR_RESET_TIME)
			dataErrorQueue:dequeue()
			if dataErrorQueue:getSize() < CRITICAL_ERROR_COUNT then
				setCritical(false,nil)
				setState("Access",nil)
			end
		end

	elseif pos == 2 then
		memoryErrorQueue:enqueue({ErrorMessage,Name,Key,Data})
		if memoryErrorQueue:getSize() >= CRITICAL_ERROR_COUNT then
			if IsCritical.Memory == true then
				return
			end
			setCritical(nil,true)
			setState(nil,"Error")
			task.wait(ERROR_RESET_TIME)
			memoryErrorQueue:dequeue()
			if memoryErrorQueue:getSize() < CRITICAL_ERROR_COUNT then
				setCritical(nil,false)
				setState(nil,"Access")
			end
		end
	end

end)

-- 시작 시 저장소 접근 권한을 확인하고 서비스 상태를 계속 유지합니다.
task.spawn(function() -- 상태 감시
	if RunService:IsStudio() then
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

-- DataStore 요청 예산이 부족하면 새 요청을 잠시 막도록 NoAccess 상태로 전환합니다.
task.spawn(function() -- 접근 예산 감시
	while true do task.wait(15)
		if dataErrorQueue:getSize() > 0 then
			local writeBudget = DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.StandardWrite)
			local readBudget = DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.StandardRead)
			if writeBudget <= 1 then
				setState("NoAccess",nil)
			elseif readBudget <= 1 then
				setState("NoAccess",nil)
			elseif State.Total == "NoAccess" then
				setState("Access",nil)
			end
		end
	end
end)



return KrossSyncService
