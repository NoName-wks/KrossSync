-- KrossSync V0.0.2 regression test
-- Place this Script next to the KrossSync ModuleScript and run it on the server.
-- Studio requires: Game Settings > Security > Enable Studio Access to API Services.

local RunService = game:GetService("RunService")
local RUN_TESTS = false
local shouldRunTests = RUN_TESTS or script:GetAttribute("RunTests") == true

if not RunService:IsStudio() then
	warn("[KrossSync Regression] Regression tests can only run in Studio.")
	return
end

if not shouldRunTests then
	warn("[KrossSync Regression] Set RUN_TESTS to true or enable the RunTests attribute to start the regression tests.")
	return
end

local KrossSyncService = require(script.Parent:WaitForChild("KrossSync"))

local STORE_NAME = "KrossSync_V002_REGRESSION_TEST"
local EXPIRATION_TIME = 120
local AUTO_RESTORE_TIMEOUT = 40
local REMOVE_SETTLE_TIME = 20
local AUTO_UNSYNC_SETTLE_TIME = 18

local DataTemplate = {
	coins = 0,
	version = 1,
	inventory = {
		items = {},
	},
}

local MemoryTemplate = {
	restoreToken = "",
	remoteMarker = "",
}

local function log(...)
	print("[KrossSync Regression]", ...)
end

local function fail(message)
	error(`[KrossSync Regression] {message}`, 2)
end

local function assertTrue(condition, message)
	if not condition then
		fail(message)
	end
end

local function runStep(name, callback)
	log(`START {name}`)
	local ok, result = xpcall(callback, debug.traceback)
	if not ok then
		warn(`[KrossSync Regression] FAIL {name}:`, result)
		error(result, 0)
	end
	log(`PASS {name}`)
end

local function waitForReady(timeoutSeconds)
	local deadline = os.clock() + timeoutSeconds
	while KrossSyncService.State.Total == "NotReady" and os.clock() < deadline do
		task.wait(0.25)
	end

	log(
		"State",
		KrossSyncService.State.Total,
		"Data",
		KrossSyncService.State.Data,
		"Memory",
		KrossSyncService.State.Memory
	)
	assertTrue(KrossSyncService.State.Total == "Access", "Storage services must be accessible")
end

local function waitForValue(timeoutSeconds, intervalSeconds, callback)
	local deadline = os.clock() + timeoutSeconds
	local lastError = nil

	repeat
		local ok, result = pcall(callback)
		if ok and result then
			return result
		elseif not ok then
			lastError = result
		end
		task.wait(intervalSeconds)
	until os.clock() >= deadline

	if lastError then
		log("Last polling error", lastError)
	end
	return nil
end

local function makeRawData(coins)
	return {
		coins = coins,
		version = 1,
		inventory = {
			items = {},
		},
	}
end

local runId = `{os.time() % 100000000}_{math.random(1000, 9999)}`
local keyNumber = 0
local activeKeys = {}

local function newKey(label)
	keyNumber += 1
	local shortLabel = string.sub(label, 1, 8)
	local key = `KS_{shortLabel}_{runId}_{keyNumber}`
	assertTrue(#key <= 50, `Generated key is too long: {key}`)
	activeKeys[key] = true
	return key
end

local ks = KrossSyncService.get(STORE_NAME, DataTemplate, MemoryTemplate, EXPIRATION_TIME)
assertTrue(ks ~= false, "KrossSyncService.get should return a service")
ks.MaxRetryTime = 3

local function cleanupKey(key)
	ks.IsSaving[key] = true
	ks.LastData[key] = nil

	pcall(function()
		ks.Store:RemoveAsync(key)
	end)
	pcall(function()
		ks.Map:RemoveAsync(key)
	end)

	ks.IsGetting[key] = nil
	ks.IsSaving[key] = nil
	ks.RemovedKeys[key] = nil
	ks.PendingDataSave[key] = nil
	ks.PendingMemoryPublish[key] = nil
	ks.PendingMemoryRemoval[key] = nil
	activeKeys[key] = nil
end

local function cleanupAll()
	for key in pairs(activeKeys) do
		cleanupKey(key)
	end
end

ks.OnGettingToggle:Connect(function(value)
	log("OnGettingToggle", value)
end)

ks.OnSavingToggle:Connect(function(value)
	log("OnSavingToggle", value)
end)

ks.OnNewData:Connect(function(data)
	log("OnNewData", data and data.memory and data.memory.restoreToken)
end)

local function testGetWritesMemoryOnce()
	local key = newKey("GetSingleMemoryWrite")
	ks.Store:SetAsync(key, makeRawData(10))
	ks.Map:RemoveAsync(key)
	ks.LastData[key] = nil

	local realMap = ks.Map
	local setAsyncCalls = 0
	local updateAsyncCalls = 0
	local proxy = {}

	function proxy:GetAsync(mapKey)
		return realMap:GetAsync(mapKey)
	end

	function proxy:SetAsync(mapKey, value, expiration)
		setAsyncCalls += 1
		return realMap:SetAsync(mapKey, value, expiration)
	end

	function proxy:UpdateAsync(mapKey, transform, expiration)
		updateAsyncCalls += 1
		return realMap:UpdateAsync(mapKey, transform, expiration)
	end

	function proxy:RemoveAsync(mapKey)
		return realMap:RemoveAsync(mapKey)
	end

	ks.Map = proxy
	local result = table.pack(xpcall(function()
		return ks:Get(key, true)
	end, debug.traceback))
	ks.Map = realMap

	assertTrue(result[1], `Get raised an error: {tostring(result[2])}`)
	local data = result[2]
	assertTrue(data ~= false and data ~= nil, "Get should recover DataStore data")
	assertTrue(data.data.coins == 10, "Recovered data should match DataStore")
	assertTrue(setAsyncCalls == 0, `Get should not use MemoryStore SetAsync, got {setAsyncCalls} calls`)
	assertTrue(updateAsyncCalls == 1, `Get should call MemoryStore UpdateAsync once, got {updateAsyncCalls}`)

	cleanupKey(key)
end

local function testGetCreatesMissingKey()
	local key = newKey("GetNewKey")
	local data = ks:Get(key, false)
	assertTrue(data ~= false and data ~= nil, "Get should create a missing key without force")
	assertTrue(ks.Store:GetAsync(key).coins == 0, "Get should create durable data")
	assertTrue(ks.Map:GetAsync(key).data.coins == 0, "Get should publish the created data")
	cleanupKey(key)
end

local function testGetSkipsMemoryWhenDataFails()
	local key = newKey("GetDataFail")
	local realStore = ks.Store
	local oldMaxRetryTime = ks.MaxRetryTime
	local updateAsyncCalls = 0
	local proxy = {Name = realStore.Name}

	function proxy:GetAsync(storeKey)
		return realStore:GetAsync(storeKey)
	end

	function proxy:UpdateAsync()
		updateAsyncCalls += 1
		error("Injected DataStore create failure")
	end

	ks.Store = proxy
	ks.MaxRetryTime = 1
	local result = table.pack(xpcall(function()
		return ks:Get(key, false)
	end, debug.traceback))
	ks.Store = realStore
	ks.MaxRetryTime = oldMaxRetryTime

	assertTrue(result[1], `Get failure test raised an error: {tostring(result[2])}`)
	assertTrue(result[2] == false, "Get should fail when durable creation fails")
	assertTrue(result[3] and result[3].Data == false and result[3].Memory == false, "Get should report no stored key")
	assertTrue(updateAsyncCalls == 1, "Get should attempt one durable write")
	assertTrue(ks.Map:GetAsync(key) == nil, "Get must not create memory-only data")
	assertTrue(realStore:GetAsync(key) == nil, "Get must not create durable data on failure")
	cleanupKey(key)
end

local function testGetDataReturnsSynchronizedCache()
	local key = newKey("GetDataCache")
	local initial = ks:Get(key, true)
	assertTrue(initial ~= false and initial ~= nil, "Initial Get should succeed")

	ks.Store:SetAsync(key, makeRawData(222))
	ks.Map:SetAsync(key, {
		lastUpdate = os.time(),
		dataCreateTime = initial.dataCreateTime,
		data = makeRawData(0),
		memory = {
			restoreToken = "",
			remoteMarker = "latest-from-memory-store",
		},
		onlineServers = {game.JobId, "RemoteServerForTest"},
	}, EXPIRATION_TIME)

	local data = ks:GetData(key, true)
	assertTrue(data ~= false and data ~= nil, "GetData should succeed")
	assertTrue(data == ks.LastData[key], "GetData should return the synchronized LastData wrapper")
	assertTrue(data.data.coins == 222, "GetData should apply the newest persistent data")
	assertTrue(data.dataSequence == 0, "Durable recovery should not create an unsaved data sequence")
	assertTrue(data.memory.remoteMarker == "latest-from-memory-store", "GetData should preserve latest MemoryStore memory")
	assertTrue(table.find(data.onlineServers, "RemoteServerForTest") ~= nil, "GetData should preserve latest onlineServers")

	cleanupKey(key)
end

local function testGetDataFailsWhenMemorySyncFails()
	local key = `KS_ReadFail_{runId}`
	local realStore, realMap, realSaveMemory = ks.Store, ks.Map, ks.SaveMemory
	local reads, syncAttempts = 0, 0
	ks.Store = {Name = "read-failure-store", GetAsync = function()
		reads += 1
		return makeRawData(5)
	end}
	ks.Map = {GetAsync = function() return nil end}
	ks.SaveMemory = function()
		syncAttempts += 1
		return false
	end
	local result = table.pack(xpcall(function()
		local uncached = ks:GetData(key, true)
		assertTrue(uncached == false, "Uncached GetData must fail when shared synchronization fails")
		assertTrue(ks.LastData[key] == nil, "Failed GetData must not cache a durable-only fallback")
		local previous = {
			lastUpdate = os.time(), dataCreateTime = os.time(),
			data = makeRawData(1), memory = {}, onlineServers = {game.JobId},
			dataRevision = 0, dataSequence = 0,
		}
		ks.LastData[key] = previous
		assertTrue(ks:GetData(key, true) == false, "Cached GetData must also report synchronization failure")
		assertTrue(ks.LastData[key] == previous, "Failed GetData must leave the previous cache unchanged")
		assertTrue(reads == 2 and syncAttempts == 2, "Each failed read should attempt one durable read and one synchronization")
	end, debug.traceback))
	ks.Store, ks.Map, ks.SaveMemory = realStore, realMap, realSaveMemory
	ks.LastData[key] = nil
	ks.IsGetting[key] = nil
	ks.IsSaving[key] = nil
	assertTrue(result[1], `GetData synchronization failure test raised: {tostring(result[2])}`)
end

local function testGetDataRefreshesMemoryWithoutExtraWrites()
	local key = newKey("GetFresh")
	assertTrue(ks:Get(key, true) ~= false, "Get should create the key")
	local initial = ks:GetData(key, true)
	assertTrue(initial, "GetData should establish the durable version")
	local shared = table.clone(initial)
	shared.memory = {restoreToken = "", remoteMarker = "remote-only"}
	shared.onlineServers = {game.JobId, "RemoteServerForTest"}
	shared.dataCreateTime = initial.dataCreateTime - 60
	ks.Map:SetAsync(key, shared, EXPIRATION_TIME)

	local realStore, realMap = ks.Store, ks.Map
	local reads, memoryReads, memoryWrites = 0, 0, 0
	ks.Store = {Name = realStore.Name, GetAsync = function(_, ...)
		reads += 1
		return realStore:GetAsync(...)
	end}
	ks.Map = {Name = realMap.Name, GetAsync = function(_, ...)
		memoryReads += 1
		return realMap:GetAsync(...)
	end, UpdateAsync = function(_, ...)
		memoryWrites += 1
		return realMap:UpdateAsync(...)
	end}
	local result = table.pack(xpcall(function() return ks:GetData(key, true) end, debug.traceback))
	ks.Store, ks.Map = realStore, realMap
	assertTrue(result[1], `GetData freshness test raised an error: {tostring(result[2])}`)
	local fresh = result[2]
	assertTrue(fresh and fresh == ks.LastData[key], "GetData should return the refreshed wrapper")
	assertTrue(fresh.memory.remoteMarker == "remote-only", "Unchanged durable data must not hide newer shared memory")
	assertTrue(table.find(fresh.onlineServers, "RemoteServerForTest") ~= nil, "GetData must refresh the shared server list")
	assertTrue(fresh.dataCreateTime == initial.dataCreateTime, "A shared-memory refresh must preserve the durable save time")
	assertTrue(reads == 1 and memoryReads == 1 and memoryWrites == 0, "Freshness check must reuse the existing reads without another write")
	cleanupKey(key)
end

local function testGetDataPreservesSharedMemory()
	local key = newKey("GetMemoryRace")
	ks.Store:SetAsync(key, makeRawData(5))
	ks.Map:SetAsync(key, {
		lastUpdate = os.time(),
		dataCreateTime = os.time(),
		data = makeRawData(5),
		memory = {restoreToken = "", remoteMarker = "remote-change"},
		onlineServers = {"RemoteServerForTest"},
		dataRevision = 0,
		dataSequence = 0,
	}, EXPIRATION_TIME)
	ks.LastData[key] = nil

	local data = ks:GetData(key, true)
	assertTrue(data ~= false and data ~= nil, "GetData should recover a key without a local cache")
	assertTrue(data.memory.remoteMarker == "remote-change", "GetData must preserve newer shared memory")
	assertTrue(ks.Map:GetAsync(key).memory.remoteMarker == "remote-change", "GetData must not overwrite shared memory")
	assertTrue(table.find(data.onlineServers, game.JobId) ~= nil, "GetData should register this server")
	cleanupKey(key)
end

local function testGetDataPreservesUnsavedSharedData()
	local key = newKey("GetDataRace")
	ks.Store:SetAsync(key, makeRawData(5))
	local shared = {
		lastUpdate = os.time(),
		dataCreateTime = os.time(),
		data = makeRawData(7),
		memory = {restoreToken = "", remoteMarker = "remote-change"},
		onlineServers = {"RemoteServerForTest"},
		dataRevision = 0,
		dataSequence = 1,
	}
	ks.Map:SetAsync(key, shared, EXPIRATION_TIME)
	ks.LastData[key] = {
		lastUpdate = shared.lastUpdate,
		dataCreateTime = shared.dataCreateTime,
		data = makeRawData(5),
		memory = {restoreToken = "", remoteMarker = ""},
		onlineServers = {game.JobId},
		dataRevision = 0,
		dataSequence = 0,
	}

	local data = ks:GetData(key, true)
	assertTrue(data ~= false and data ~= nil, "GetData should reconcile a cached key")
	assertTrue(data.data.coins == 7 and data.dataSequence == 1, "GetData must preserve newer unsaved shared data")
	assertTrue(data.memory.remoteMarker == "remote-change", "GetData must preserve newer shared memory")
	local stored = ks.Map:GetAsync(key)
	assertTrue(stored.data.coins == 7 and stored.dataSequence == 1, "GetData must not overwrite the newer shared sequence")
	cleanupKey(key)
end

local function testSaveFunctionPersistsResolvedData()
	local key = newKey("SaveFunction")
	local data = ks:Get(key, true)
	assertTrue(data ~= false and data ~= nil, "Save function setup should succeed")

	assertTrue(ks:SaveMemory(key, function(old)
		old.dataCreateTime = os.time() - 120
		return old
	end, EXPIRATION_TIME, true) == true, "Save setup should age the shared durable-save time")
	local callbackCalls = 0
	local saved = ks:Save(key, function(oldData)
		callbackCalls += 1
		oldData.data.coins = 321
		return oldData
	end, EXPIRATION_TIME, true)

	assertTrue(saved == true, "Save function should persist successfully")
	assertTrue(callbackCalls >= 1, "Save callback should run during the MemoryStore update")
	assertTrue(ks.Store:GetAsync(key).coins == 321, "Resolved memory data should be persisted to DataStore")
	assertTrue(ks.Map:GetAsync(key).dataCreateTime > os.time() - 60, "Save should refresh the shared durable-save time")
	assertTrue(ks:Save(key, function(oldData)
		oldData.data.coins += 1
		return oldData
	end, EXPIRATION_TIME, true) == true, "A later memory update should succeed")
	assertTrue(ks.Store:GetAsync(key).coins == 321, "Save should not persist again before the next interval")

	cleanupKey(key)
end

local function testExplicitDurableSave()
	local key = newKey("ExplicitDurable")
	assertTrue(ks:Get(key, true) ~= false, "Explicit durable save setup should succeed")
	local memorySaved = ks:SaveMemory(key, function(current)
		current.data.coins += 7
		return current
	end, EXPIRATION_TIME, true)
	assertTrue(memorySaved == true, "Important change should update shared memory")
	assertTrue(ks:SaveData(key, ks.LastData[key], true) == true, "Important change should persist on explicit request")
	assertTrue(ks.Store:GetAsync(key).coins == 7, "Explicit durable save should persist the changed data")
	cleanupKey(key)
end

local function testSaveKeepsNewerMemoryDueTime()
	local key = newKey("SaveNewerMemory")
	assertTrue(ks:Get(key, true) ~= false, "Save race setup should create the key")
	assertTrue(ks:SaveMemory(key, function(old)
		old.dataCreateTime = os.time() - 120
		return old
	end, EXPIRATION_TIME, true) == true, "Save race setup should age the shared durable-save time")

	local realStore = ks.Store
	local proxy = {Name = realStore.Name}
	function proxy:UpdateAsync(storeKey, transform)
		local stored, keyInfo = realStore:UpdateAsync(storeKey, transform)
		ks.Map:UpdateAsync(storeKey, function(old)
			old.data.coins = 2
			old.dataSequence += 1
			return old
		end, EXPIRATION_TIME)
		return stored, keyInfo
	end

	ks.Store = proxy
	local result = table.pack(xpcall(function()
		assertTrue(ks:Save(key, function(old)
			old.data.coins = 1
			return old
		end, EXPIRATION_TIME, true) == true, "Save should succeed during a newer memory update")
	end, debug.traceback))
	ks.Store = realStore

	assertTrue(result[1], `Save race test raised an error: {tostring(result[2])}`)
	local shared = ks.Map:GetAsync(key)
	assertTrue(shared.data.coins == 2, "Save must preserve the newer shared data")
	assertTrue(shared.dataCreateTime <= os.time() - 60, "Save must not defer the newer unsaved data")
	assertTrue(realStore:GetAsync(key).coins == 1, "The earlier snapshot should remain durable")
	cleanupKey(key)
end

local function testSaveQueuesDataAfterPartialFailure()
	local key = newKey("SavePartial")
	local data = ks:Get(key, true)
	assertTrue(data ~= false and data ~= nil, "Partial save setup should succeed")

	data.dataCreateTime = os.time() - 120
	ks.LastData[key] = data

	local realStore = ks.Store
	local oldMaxRetryTime = ks.MaxRetryTime
	local updateAsyncCalls = 0
	local callbackCalls = 0
	local proxy = {Name = realStore.Name}

	function proxy:GetAsync(storeKey)
		return realStore:GetAsync(storeKey)
	end

	function proxy:SetAsync(storeKey, value)
		return realStore:SetAsync(storeKey, value)
	end

	function proxy:UpdateAsync(storeKey, transform)
		updateAsyncCalls += 1
		if updateAsyncCalls == 1 then
			error("Injected first DataStore save failure")
		end
		return realStore:UpdateAsync(storeKey, transform)
	end

	function proxy:RemoveAsync(storeKey)
		return realStore:RemoveAsync(storeKey)
	end

	ks.Store = proxy
	ks.MaxRetryTime = 1
	local saved
	local persisted
	local result = table.pack(xpcall(function()
		saved = ks:Save(key, function(oldData)
			callbackCalls += 1
			oldData.data.coins += 1
			return oldData
		end, EXPIRATION_TIME, true)

		persisted = waitForValue(15, 0.5, function()
			local stored = realStore:GetAsync(key)
			if stored and stored.coins == 1 and ks.PendingDataSave[key] == nil then
				return stored
			end
			return nil
		end)
	end, debug.traceback))
	ks.Store = realStore
	ks.MaxRetryTime = oldMaxRetryTime

	assertTrue(result[1], `Partial save recovery must not raise: {tostring(result[2])}`)
	assertTrue(saved == true, "A committed MemoryStore update should report logical Save success")
	assertTrue(callbackCalls >= 1, "Save callback should run during the MemoryStore update")
	assertTrue(ks.LastData[key].data.coins == 1, "The update must not be applied twice")
	assertTrue(persisted ~= nil, "The queued retry should persist the committed value")

	cleanupKey(key)
end

local function testSaveDataIndependentOfMemoryStore()
	local key = newKey("SaveWithoutMemoryRead")
	local data = ks:Get(key, true)
	assertTrue(data ~= false and data ~= nil, "SaveData setup should succeed")

	local realMap = ks.Map
	local proxy = {}

	function proxy:GetAsync(mapKey)
		if mapKey == key then
			error("Injected MemoryStore read failure")
		end
		return realMap:GetAsync(mapKey)
	end

	function proxy:SetAsync(mapKey, value, expiration)
		return realMap:SetAsync(mapKey, value, expiration)
	end

	function proxy:UpdateAsync(mapKey, transform, expiration)
		return realMap:UpdateAsync(mapKey, transform, expiration)
	end

	function proxy:RemoveAsync(mapKey)
		return realMap:RemoveAsync(mapKey)
	end

	ks.Map = proxy
	local result = table.pack(xpcall(function()
		return ks:SaveData(key, function(oldData)
			oldData.coins += 1
			return oldData
		end, true)
	end, debug.traceback))
	ks.Map = realMap

	assertTrue(result[1], `SaveData must not raise: {tostring(result[2])}`)
	assertTrue(result[2] == true, "DataStore update should succeed while MemoryStore reads fail")
	assertTrue(ks.Store:GetAsync(key).coins == 1, "Committed function update must be applied exactly once")
	cleanupKey(key)
end

local function testForceKeepsLocksAndValidation()
	local key = newKey("ForceLocks")
	local data = ks:Get(key, true)
	assertTrue(data ~= false and data ~= nil, "Force lock setup should succeed")

	ks.IsSaving[key] = true
	assertTrue(ks:Get(key, true) == false, "force Get must not bypass a busy key")
	assertTrue(ks:GetData(key, true) == false, "force GetData must not bypass a busy key")
	assertTrue(ks:GetMemory(key, true) == false, "force GetMemory must not bypass a busy key")
	assertTrue(ks:SaveData(key, data, true) == false, "force SaveData must not bypass a busy key")
	assertTrue(ks:SaveMemory(key, data, EXPIRATION_TIME, true) == false, "force SaveMemory must not bypass a busy key")
	ks.IsSaving[key] = nil

	assertTrue(ks:SaveData(key, "invalid", true) == false, "force SaveData must still validate input")
	assertTrue(ks:SaveMemory(key, "invalid", EXPIRATION_TIME, true) == false, "force SaveMemory must still validate input")

	cleanupKey(key)
end

local function testGetDataRejectsRemovalTombstone()
	local key = newKey("GetTombstone")
	local data = ks:Get(key, true)
	assertTrue(data ~= false and data ~= nil, "Tombstone setup should succeed")

	ks.Map:SetAsync(key, {
		__krossSyncRemoved = true,
		removedAt = os.time(),
		removedUntil = os.time() + EXPIRATION_TIME,
	}, EXPIRATION_TIME)
	ks.LastData[key] = nil
	ks.RemovedKeys[key] = nil

	assertTrue(ks:GetData(key, true) == false, "GetData must reject a shared removal tombstone")
	assertTrue(ks.LastData[key] == nil, "GetData must not restore deleted data to LastData")

	cleanupKey(key)
end

local function testAutoGetMemoryRestoresMissingEntry()
	local key = newKey("AutoRestore")
	local data = ks:Get(key, true)
	assertTrue(data ~= false and data ~= nil, "Initial Get should succeed")

	local token = `restore_{runId}`
	data.memory.restoreToken = token
	local saved = ks:SaveMemory(key, data, EXPIRATION_TIME, true)
	assertTrue(saved == true, "Memory seed should save")

	ks.Map:RemoveAsync(key)
	assertTrue(ks.Map:GetAsync(key) == nil, "MemoryStore entry should be absent before automatic restoration")

	local restored = waitForValue(AUTO_RESTORE_TIMEOUT, 2, function()
		local value = ks.Map:GetAsync(key)
		if value and value.memory and value.memory.restoreToken == token then
			return value
		end
		return nil
	end)

	assertTrue(restored ~= nil, "AutoGetMemory should restore a missing MemoryStore entry")
	assertTrue(table.find(restored.onlineServers or {}, game.JobId) ~= nil, "Restored entry should contain this server JobId")

	-- Simulate another server overwriting the membership list without this JobId.
	restored.onlineServers = {"RemoteServerForRepairTest"}
	ks.Map:SetAsync(key, restored, EXPIRATION_TIME)
	local repaired = waitForValue(AUTO_RESTORE_TIMEOUT, 2, function()
		local value = ks.Map:GetAsync(key)
		if value and table.find(value.onlineServers or {}, game.JobId) ~= nil then
			return value
		end
		return nil
	end)

	assertTrue(repaired ~= nil, "AutoGetMemory should restore a missing current-server JobId")
	assertTrue(table.find(repaired.onlineServers or {}, "RemoteServerForRepairTest") ~= nil, "JobId repair should preserve other servers")

	cleanupKey(key)
end

local function testAutoGetMemoryUsesNewerDurableData()
	local key = newKey("AutoNewer")
	local data = ks:Get(key, true)
	assertTrue(data ~= false and data ~= nil, "AutoGet setup should succeed")
	local notifications = 0
	ks.OnNewData:Connect(function(updated)
		if updated == ks.LastData[key] and updated.data.coins == 321 then
			notifications += 1
		end
	end)

	ks.Store:UpdateAsync(key, function(_, keyInfo)
		local metadata = keyInfo:GetMetadata()
		metadata.__krossSyncRevision = (metadata.__krossSyncRevision or 0) + 1
		return makeRawData(321), keyInfo:GetUserIds(), metadata
	end)
	ks.Map:RemoveAsync(key)

	local restored = waitForValue(AUTO_RESTORE_TIMEOUT, 2, function()
		local value = ks.Map:GetAsync(key)
		if value and value.data and value.data.coins == 321 then
			return value
		end
	end)
	assertTrue(restored ~= nil, "AutoGet must restore the newer durable data, not stale LastData")
	assertTrue(ks.LastData[key] and ks.LastData[key].data.coins == 321, "Local cache should receive the durable data")
	assertTrue(waitForValue(5, 0.1, function()
		return notifications > 0
	end), "AutoGet must notify subscribers of the recovered durable data")
	assertTrue(notifications == 1, "AutoGet should notify once for one recovered change")

	cleanupKey(key)
end

local function testAutoGetMemoryRejectsDurableRemoval()
	local key = newKey("AutoDel")
	assertTrue(ks:Get(key, true) ~= false, "AutoGet removal setup should succeed")

	ks.Store:UpdateAsync(key, function(_, keyInfo)
		return {__krossSyncRemoved = true, removedAt = os.time()}, keyInfo:GetUserIds(), keyInfo:GetMetadata()
	end)
	ks.Map:RemoveAsync(key)

	local removed = waitForValue(AUTO_RESTORE_TIMEOUT, 1, function()
		return ks.RemovedKeys[key] == math.huge
	end)
	assertTrue(removed, "AutoGet should notice a durable removal when MemoryStore is missing")
	assertTrue(ks.LastData[key] == nil, "AutoGet must clear stale local data after durable removal")
	assertTrue(ks.Map:GetAsync(key) == nil, "AutoGet must not recreate a removed MemoryStore entry")

	cleanupKey(key)
end

local function testRemoveLocksAndDoesNotRestore()
	local key = newKey("Remove")
	local data = ks:Get(key, true)
	assertTrue(data ~= false and data ~= nil, "Initial Get should succeed")

	ks:SetGetting(key, true)
	local blockedData, blockedMemory = ks:Remove(key)
	ks:SetGetting(key, false)
	assertTrue(blockedData == false and blockedMemory == false, "Remove should reject a busy key")
	assertTrue(ks.Store:GetAsync(key) ~= nil, "Blocked Remove must not delete DataStore")
	assertTrue(ks.Map:GetAsync(key) ~= nil, "Blocked Remove must not delete MemoryStore")

	-- Give the background loop time to capture this key before removing it.
	task.wait(0.5)
	local dataRemoved, memoryRemoved = ks:Remove(key)
	assertTrue(dataRemoved == true, "Remove should mark DataStore as removed")
	assertTrue(memoryRemoved == true, "Remove should mark MemoryStore as removed")
	assertTrue(ks.LastData[key] == nil, "Remove should clear LastData")
	assertTrue(ks.IsGetting[key] == nil, "Remove should clear IsGetting")
	assertTrue(ks.IsSaving[key] == nil, "Remove should clear IsSaving")
	local durableTombstone = ks.Store:GetAsync(key)
	assertTrue(durableTombstone and durableTombstone.__krossSyncRemoved == true, "DataStore should retain a durable removal tombstone")
	local tombstone = ks.Map:GetAsync(key)
	assertTrue(tombstone and tombstone.__krossSyncRemoved == true, "MemoryStore should contain a removal tombstone")

	-- Simulate a server that has not cached the tombstone yet trying to restore stale data.
	ks.RemovedKeys[key] = nil
	assertTrue(ks:SaveMemory(key, data, EXPIRATION_TIME, true) == false, "A removal tombstone should reject stale memory writes")

	log(`Waiting {REMOVE_SETTLE_TIME}s to ensure AutoGetMemory does not recreate the removed key`)
	task.wait(REMOVE_SETTLE_TIME)
	local settledValue = ks.Map:GetAsync(key)
	assertTrue(settledValue and settledValue.__krossSyncRemoved == true, "AutoGetMemory must preserve the removal tombstone")

	cleanupKey(key)
end

local function testRemoveRequiresDurableTombstone()
	local key = newKey("RemoveRetry")
	assertTrue(ks:Get(key, true) ~= false, "Remove retry setup should succeed")

	local realStore = ks.Store
	local oldMaxRetryTime = ks.MaxRetryTime
	local proxy = {Name = realStore.Name}
	local updateAsyncCalls = 0

	function proxy:GetAsync(storeKey)
		return realStore:GetAsync(storeKey)
	end

	function proxy:SetAsync(storeKey, value)
		return realStore:SetAsync(storeKey, value)
	end

	function proxy:UpdateAsync(storeKey, transform)
		updateAsyncCalls += 1
		if updateAsyncCalls <= 2 then
			error("Injected DataStore tombstone failure")
		end
		return realStore:UpdateAsync(storeKey, transform)
	end

	function proxy:RemoveAsync(storeKey)
		return realStore:RemoveAsync(storeKey)
	end

	ks.Store = proxy
	ks.MaxRetryTime = 2
	local dataRemoved, memoryRemoved = ks:Remove(key)

	ks.Store = realStore
	ks.MaxRetryTime = oldMaxRetryTime

	assertTrue(dataRemoved == false and memoryRemoved == false, "MemoryStore must not be marked removed before durable deletion succeeds")
	assertTrue(updateAsyncCalls == 2, `Expected two tombstone attempts, got {updateAsyncCalls}`)
	assertTrue(realStore:GetAsync(key) ~= nil, "Failed removal must preserve the DataStore value")
	assertTrue(ks.Map:GetAsync(key).__krossSyncRemoved ~= true, "Failed removal must preserve the MemoryStore value")
	local retriedData, retriedMemory = ks:Remove(key)
	assertTrue(retriedData and retriedMemory, "A later removal attempt should succeed")
	assertTrue(realStore:GetAsync(key).__krossSyncRemoved == true, "Retry should persist the removal tombstone")

	cleanupKey(key)
end

local function testDurableTombstoneSurvivesMissingMemoryMarker()
	local key = newKey("DurableRemove")
	assertTrue(ks:Get(key, true) ~= false, "Durable removal setup should succeed")
	local realMap = ks.Map
	local oldMaxRetryTime = ks.MaxRetryTime
	local proxy = {}

	function proxy:GetAsync(mapKey)
		return realMap:GetAsync(mapKey)
	end
	function proxy:UpdateAsync(mapKey, transform, expiration)
		error("Injected MemoryStore tombstone failure")
	end
	function proxy:RemoveAsync(mapKey)
		return realMap:RemoveAsync(mapKey)
	end

	ks.Map = proxy
	ks.MaxRetryTime = 1
	local dataRemoved, memoryRemoved = ks:Remove(key)
	ks.Map = realMap
	ks.MaxRetryTime = oldMaxRetryTime
	assertTrue(dataRemoved and not memoryRemoved, "Durable deletion should survive a MemoryStore failure")
	assertTrue(ks.Store:GetAsync(key).__krossSyncRemoved == true, "DataStore tombstone must remain")
	assertTrue(ks.PendingMemoryRemoval[key] ~= nil, "Failed MemoryStore marker should be queued for retry")

	ks.PendingMemoryRemoval[key] = nil -- Simulate a crash before the retry runs.
	ks.Map:RemoveAsync(key)
	ks.RemovedKeys[key] = nil
	assertTrue(ks:Get(key, true) == false, "An expired MemoryStore marker must not recreate deleted data")
	ks.RemovedKeys[key] = nil
	assertTrue(ks:SaveData(key, {data = makeRawData(999)}, true) == false, "A stale save must not overwrite a durable tombstone")
	cleanupKey(key)
end

local function testMemoryRemovalRetriesAfterTransientFailure()
	local key = newKey("MemoryRemoveRetry")
	assertTrue(ks:Get(key, true) ~= false, "Memory removal retry setup should succeed")
	local realMap = ks.Map
	local oldMaxRetryTime = ks.MaxRetryTime
	local attempts = 0
	local proxy = {}

	function proxy:GetAsync(mapKey)
		return realMap:GetAsync(mapKey)
	end
	function proxy:UpdateAsync(mapKey, transform, expiration)
		attempts += 1
		if attempts == 1 then
			error("Injected first MemoryStore tombstone failure")
		end
		return realMap:UpdateAsync(mapKey, transform, expiration)
	end
	function proxy:RemoveAsync(mapKey)
		return realMap:RemoveAsync(mapKey)
	end

	ks.Map = proxy
	ks.MaxRetryTime = 1
	local dataRemoved, memoryRemoved = ks:Remove(key)
	local retried = waitForValue(12, 0.5, function()
		local value = realMap:GetAsync(key)
		return value and value.__krossSyncRemoved == true and ks.PendingMemoryRemoval[key] == nil
	end)
	ks.Map = realMap
	ks.MaxRetryTime = oldMaxRetryTime
	assertTrue(dataRemoved and not memoryRemoved, "Initial MemoryStore marker failure should be reported")
	assertTrue(retried == true, "Background retry should publish the MemoryStore tombstone")
	assertTrue(attempts == 2, `Expected two MemoryStore marker attempts, got {attempts}`)
	cleanupKey(key)
end

local function testStandaloneRemoveMethodsClearCache()
	local dataKey = newKey("RemoveData")
	assertTrue(ks:Get(dataKey, true) ~= false, "RemoveData setup should succeed")
	assertTrue(ks:RemoveData(dataKey) == true, "RemoveData should succeed")
	assertTrue(ks.LastData[dataKey] == nil, "RemoveData should clear LastData")
	assertTrue(ks.Store:GetAsync(dataKey).__krossSyncRemoved == true, "RemoveData should retain a durable tombstone")
	assertTrue(ks:RemoveMemory(dataKey) == true, "RemoveData test cleanup should remove memory")
	cleanupKey(dataKey)

	local memoryKey = newKey("RemoveMemory")
	assertTrue(ks:Get(memoryKey, true) ~= false, "RemoveMemory setup should succeed")
	assertTrue(ks:RemoveMemory(memoryKey) == true, "RemoveMemory should succeed")
	assertTrue(ks.LastData[memoryKey] == nil, "RemoveMemory should clear LastData")
	assertTrue(ks.Map:GetAsync(memoryKey) == nil, "RemoveMemory should delete temporary data")
	assertTrue(ks:RemoveData(memoryKey) == true, "RemoveMemory test cleanup should remove persistent data")
	cleanupKey(memoryKey)
end

local function testUnSyncRemovesDuplicateJobIds()
	local key = newKey("UnSyncDuplicates")
	local data = ks:Get(key, true)
	assertTrue(data ~= false and data ~= nil, "UnSync setup should succeed")

	data.onlineServers = {game.JobId, "RemoteServerForUnSyncTest", game.JobId, game.JobId}
	ks.Map:SetAsync(key, data, EXPIRATION_TIME)
	ks.LastData[key] = data

	assertTrue(ks:UnSync(key) == true, "UnSync should succeed")
	local result = ks.Map:GetAsync(key)
	assertTrue(result ~= nil, "Remote server membership should keep MemoryStore data alive")
	assertTrue(table.find(result.onlineServers or {}, "RemoteServerForUnSyncTest") ~= nil, "UnSync should preserve other servers")

	local ownJobIdCount = 0
	for _,jobId in ipairs(result.onlineServers or {}) do
		if jobId == game.JobId then
			ownJobIdCount += 1
		end
	end
	assertTrue(ownJobIdCount == 0, "UnSync should remove every duplicate current-server JobId")

	cleanupKey(key)
end

local function testUnSyncRetriesFinalSave()
	local key = newKey("UnSyncRetry")
	local data = ks:Get(key, true)
	assertTrue(data ~= false and data ~= nil, "UnSync retry setup should succeed")

	assertTrue(ks:SaveMemory(key, function(old)
		old.data.coins = 777
		old.onlineServers = {game.JobId}
		return old
	end, EXPIRATION_TIME, true) == true, "UnSync retry setup should update shared data")

	local realStore = ks.Store
	local oldMaxRetryTime = ks.MaxRetryTime
	local proxy = {Name = realStore.Name}

	function proxy:GetAsync(storeKey)
		return realStore:GetAsync(storeKey)
	end

	function proxy:SetAsync(storeKey, value)
		return realStore:SetAsync(storeKey, value)
	end

	function proxy:UpdateAsync(storeKey, transform)
		error("Injected final save failure")
	end

	function proxy:RemoveAsync(storeKey)
		return realStore:RemoveAsync(storeKey)
	end

	ks.Store = proxy
	ks.MaxRetryTime = 2
	local firstAttempt = table.pack(xpcall(function()
		return ks:UnSync(key)
	end, debug.traceback))
	ks.Store = realStore
	ks.MaxRetryTime = oldMaxRetryTime

	assertTrue(firstAttempt[1], `Failed UnSync must not raise: {tostring(firstAttempt[2])}`)
	assertTrue(firstAttempt[2] == false, "Failed final save should return false")
	assertTrue(ks.LastData[key] ~= nil, "Failed final save must remain available for retry")
	assertTrue(ks:UnSync(key) == true, "A later UnSync should retry and succeed")
	assertTrue(ks.LastData[key] == nil, "Successful retry should clear LastData")
	assertTrue(ks.Store:GetAsync(key).coins == 777, "Successful retry should persist the latest data")

	cleanupKey(key)
end

local function testAutoGetPreservesDataSaveTime()
	local key = newKey("AutoTime")
	local data = ks:Get(key, true)
	assertTrue(data ~= false and data ~= nil, "AutoGet timestamp setup should succeed")

	data.dataCreateTime = os.time() - 120
	ks.Map:SetAsync(key, data, EXPIRATION_TIME)
	ks.LastData[key] = data
	assertTrue(ks:Save(key, function(oldData)
		oldData.data.coins = 456
		return oldData
	end, EXPIRATION_TIME, true) == true, "Timestamp setup save should succeed")

	local persistedAt = ks.LastData[key].dataCreateTime
	local remoteData = ks.Map:GetAsync(key)
	remoteData.memory.remoteMarker = "timestamp-refresh"
	ks.Map:SetAsync(key, remoteData, EXPIRATION_TIME)

	local refreshed = waitForValue(AUTO_RESTORE_TIMEOUT, 1, function()
		local current = ks.LastData[key]
		if current and current.memory.remoteMarker == "timestamp-refresh" then
			return current
		end
		return nil
	end)
	assertTrue(refreshed ~= nil, "AutoGetMemory should observe the remote memory change")
	assertTrue(refreshed.dataCreateTime >= persistedAt, "AutoGetMemory must preserve the latest DataStore save time")

	cleanupKey(key)
end

local function testInitialCacheDoesNotStopAutoGet()
	local name = STORE_NAME .. "_INITIAL_CACHE"
	local instance = KrossSyncService.get(name, DataTemplate, MemoryTemplate, EXPIRATION_TIME)
	assertTrue(instance ~= false, "Initial-cache instance should be created")
	local realGetMemory = instance.GetMemory
	local queries = 0
	instance.LastData.initial = {
		lastUpdate = 0, dataCreateTime = 0,
		data = makeRawData(0), memory = table.clone(MemoryTemplate),
		onlineServers = {game.JobId}, dataRevision = 0, dataSequence = 0,
	}
	instance.GetMemory = function(self, key)
		queries += 1
		local value = table.clone(self.LastData[key])
		value.data = makeRawData(queries)
		self.LastData[key] = value
		return value
	end
	local continued = waitForValue(25, 0.1, function() return queries >= 2 end)
	instance.LastData.initial = nil
	instance.GetMemory = realGetMemory
	KrossSyncService.KrossSyncs[name] = nil
	assertTrue(continued, "AutoGet must continue after its initial cached-key task finishes")
end

local function testIdleLocksAreReleased()
	local key = newKey("IdleLocks")
	assertTrue(ks:Get(key, true) ~= false, "Lock cleanup setup should succeed")
	assertTrue(ks.IsGetting[key] == nil, "Completed reads must remove the per-key getting lock")
	assertTrue(ks.IsSaving[key] == nil, "Completed writes must remove the per-key saving lock")

	cleanupKey(key)
end

local function testSingleAttemptRetryLimit()
	local key = newKey("RetryOnce")
	local data = ks:Get(key, true)
	assertTrue(data ~= false and data ~= nil, "Single-attempt retry setup should succeed")

	local realMap = ks.Map
	local oldMaxRetryTime = ks.MaxRetryTime
	local updateAsyncCalls = 0
	local proxy = {}

	function proxy:GetAsync(mapKey)
		return realMap:GetAsync(mapKey)
	end

	function proxy:SetAsync(mapKey, value, expiration)
		return realMap:SetAsync(mapKey, value, expiration)
	end

	function proxy:UpdateAsync()
		updateAsyncCalls += 1
		error("Injected single-attempt failure")
	end

	function proxy:RemoveAsync(mapKey)
		return realMap:RemoveAsync(mapKey)
	end

	ks.Map = proxy
	ks.MaxRetryTime = 1
	local result = table.pack(xpcall(function()
		return ks:SaveMemory(key, data, EXPIRATION_TIME, true)
	end, debug.traceback))
	ks.Map = realMap
	ks.MaxRetryTime = oldMaxRetryTime

	assertTrue(result[1], `Single-attempt failure must not raise: {tostring(result[2])}`)
	assertTrue(result[2] == false, "A failed single attempt should return false")
	assertTrue(updateAsyncCalls == 1, `MaxRetryTime = 1 should run once, got {updateAsyncCalls}`)

	cleanupKey(key)
end

local function testRemovedKeyRecordExpires()
	local key = newKey("RemovedExpiry")
	local removedUntil = os.time() + 2
	ks.Map:SetAsync(key, {
		__krossSyncRemoved = true,
		removedAt = os.time(),
		removedUntil = removedUntil,
	}, 5)

	assertTrue(ks:GetMemory(key, true) == false, "Active tombstone should block GetMemory")
	assertTrue(ks.RemovedKeys[key] == removedUntil, "Active tombstone should be cached locally")
	task.wait(3)
	assertTrue(ks.RemovedKeys[key] == nil, "Expired local tombstone should be removed without another access")

	cleanupKey(key)
end

local function testUnSyncIsNotReactivatedByAutoGet()
	local key = newKey("UnSyncAuto")
	local data = ks:Get(key, true)
	assertTrue(data ~= false and data ~= nil, "AutoGet UnSync setup should succeed")

	data.lastUpdate = 0
	data.dataCreateTime = os.time()
	ks.Map:SetAsync(key, data, EXPIRATION_TIME)
	ks.LastData[key] = data

	local refreshed = waitForValue(AUTO_RESTORE_TIMEOUT, 0.5, function()
		local current = ks.LastData[key]
		if current and current.lastUpdate > 0 then
			return current
		end
		return nil
	end)
	assertTrue(refreshed ~= nil, "AutoGet should run before the UnSync race check")

	-- 다음 자동 조회가 예약될 시간을 준 뒤 작업이 깨어나기 전에 UnSync한다.
	task.wait(1)
	assertTrue(ks:UnSync(key) == true, "UnSync should succeed while the next AutoGet is pending")
	assertTrue(ks.LastData[key] == nil, "UnSync should clear the local cache")
	task.wait(AUTO_UNSYNC_SETTLE_TIME)

	assertTrue(ks.LastData[key] == nil, "A stale AutoGet task must not restore an UnSynced key")
	local stored = ks.Map:GetAsync(key)
	for _,jobId in ipairs(stored and stored.onlineServers or {}) do
		assertTrue(jobId ~= game.JobId, "A stale AutoGet task must not register this server again")
	end

	cleanupKey(key)
end

local function testSetPersistsBeforeMemory()
	local key = newKey("SetOrder")
	assertTrue(ks:Get(key, true) ~= false, "Get should create the key")

	local realStore = ks.Store
	local realMap = ks.Map
	local dataSaved = false
	local storeProxy = {}
	local mapProxy = {}

	function storeProxy:UpdateAsync(storeKey, transform)
		local result, info = realStore:UpdateAsync(storeKey, transform)
		dataSaved = true
		return result, info
	end
	function mapProxy:UpdateAsync(mapKey, transform, expiration)
		assertTrue(dataSaved, "Set must persist data before updating memory")
		return realMap:UpdateAsync(mapKey, transform, expiration)
	end

	ks.Store = storeProxy
	ks.Map = mapProxy
	local result = table.pack(xpcall(function()
		return ks:Set(key, function(old)
			old.coins += 5
			return old
		end, EXPIRATION_TIME, true)
	end, debug.traceback))
	ks.Store = realStore
	ks.Map = realMap

	assertTrue(result[1], `Set raised an error: {tostring(result[2])}`)
	assertTrue(result[2] == true and result[3] == true, "Set should succeed in both stores")
	local stored, keyInfo = realStore:GetAsync(key)
	assertTrue(stored.coins == 5, "Set should persist the raw data")
	local shared = realMap:GetAsync(key)
	assertTrue(shared.data.coins == 5 and shared.dataRevision == keyInfo:GetMetadata().__krossSyncRevision, "Set should publish the persisted version")
	cleanupKey(key)
end

local function testSetReportsPartialSuccess()
	local key = newKey("SetPartial")
	assertTrue(ks:Get(key, true) ~= false, "Get should create the key")

	local realMap = ks.Map
	local oldRetryTime = ks.MaxRetryTime
	ks.MaxRetryTime = 1
	ks.Map = {
		UpdateAsync = function()
			error("Injected MemoryStore failure")
		end,
	}
	local result = table.pack(xpcall(function()
		return ks:Set(key, {data = makeRawData(7)}, EXPIRATION_TIME, true)
	end, debug.traceback))
	ks.Map = realMap
	ks.MaxRetryTime = oldRetryTime

	assertTrue(result[1], `Set raised an error: {tostring(result[2])}`)
	assertTrue(result[2] == true and result[3] == false, "Set should expose partial success")
	assertTrue(ks.Store:GetAsync(key).coins == 7, "DataStore value must survive MemoryStore failure")
	local refreshed = ks:GetData(key, true)
	assertTrue(refreshed and refreshed.data.coins == 7, "GetData should recover the durable value after partial Set")
	assertTrue(ks.Map:GetAsync(key).data.coins == 7, "GetData should refresh stale shared data")
	cleanupKey(key)
end

local function testSetMemoryDoesNotUseDataStore()
	local key = newKey("SetMemory")
	assertTrue(ks:Get(key, true) ~= false, "Get should create the key")

	local realStore = ks.Store
	ks.Store = {
		GetAsync = function()
			error("SetMemory read DataStore")
		end,
		UpdateAsync = function()
			error("SetMemory wrote DataStore")
		end,
	}
	local result = table.pack(xpcall(function()
		return ks:SetMemory(key, function(old)
			old.memory.remoteMarker = "sent"
			return old
		end, EXPIRATION_TIME, true)
	end, debug.traceback))
	ks.Store = realStore

	assertTrue(result[1], `SetMemory raised an error: {tostring(result[2])}`)
	assertTrue(result[2] == true, "SetMemory should work without DataStore")
	assertTrue(ks.Map:GetAsync(key).memory.remoteMarker == "sent", "SetMemory should publish the memory field")
	cleanupKey(key)
end

local function testSetMemoryReportsFailure()
	local key = newKey("SetMemoryFail")
	assertTrue(ks:Get(key, true) ~= false, "Get should create the key")

	local realMap = ks.Map
	local oldRetryTime = ks.MaxRetryTime
	ks.Map = {
		Name = realMap.Name,
		UpdateAsync = function()
			error("Injected MemoryStore failure")
		end,
	}
	ks.MaxRetryTime = 1
	local result = table.pack(xpcall(function()
		return ks:SetMemory(key, function(current)
			current.memory.remoteMarker = "sent"
			return current
		end, EXPIRATION_TIME, true)
	end, debug.traceback))
	ks.Map = realMap
	ks.MaxRetryTime = oldRetryTime

	assertTrue(result[1] and result[2] == false, "SetMemory should report failed delivery")
	cleanupKey(key)
end

local function testSetRetriesMemoryPublish()
	local key = newKey("SetRetry")
	assertTrue(ks:Get(key, true) ~= false, "Get should create the key")

	local realStore = ks.Store
	local realMap = ks.Map
	local oldRetryTime = ks.MaxRetryTime
	local dataWrites = 0
	local memoryWrites = 0
	local storeProxy = {Name = realStore.Name}
	local mapProxy = {}

	function storeProxy:UpdateAsync(storeKey, transform)
		dataWrites += 1
		return realStore:UpdateAsync(storeKey, transform)
	end
	function mapProxy:UpdateAsync(mapKey, transform, expiration)
		memoryWrites += 1
		if memoryWrites == 1 then
			error("Injected first MemoryStore publish failure")
		end
		return realMap:UpdateAsync(mapKey, transform, expiration)
	end

	ks.Store = storeProxy
	ks.Map = mapProxy
	ks.MaxRetryTime = 1
	local result = table.pack(xpcall(function()
		local dataSaved, memorySaved = ks:Set(key, {data = makeRawData(9)}, EXPIRATION_TIME, true)
		assertTrue(dataSaved == true and memorySaved == false, "Set should report the first partial result")
		return waitForValue(15, 0.5, function()
			local shared = realMap:GetAsync(key)
			return shared and shared.data.coins == 9 and ks.PendingMemoryPublish[key] == nil
		end)
	end, debug.traceback))
	ks.Store = realStore
	ks.Map = realMap
	ks.MaxRetryTime = oldRetryTime

	assertTrue(result[1], `Set retry raised an error: {tostring(result[2])}`)
	assertTrue(result[2] == true, "Set should eventually publish the durable value")
	assertTrue(dataWrites == 1, "MemoryStore retry must not write DataStore again")
	assertTrue(memoryWrites >= 2, "MemoryStore publish should be retried")
	cleanupKey(key)
end

local function testLateSetCannotOverwriteNewerMemory()
	local key = newKey("SetRace")
	assertTrue(ks:Get(key, true) ~= false, "Get should create the key")

	local realSetMemory = ks.SetMemory
	local firstWaiting = false
	local releaseFirst = false
	local calls = 0
	ks.SetMemory = function(self, ...)
		calls += 1
		if calls == 1 then
			firstWaiting = true
			while not releaseFirst do
				task.wait(0.05)
			end
		end
		return realSetMemory(self, ...)
	end

	local firstResult
	task.spawn(function()
		firstResult = table.pack(ks:Set(key, {data = makeRawData(1)}, EXPIRATION_TIME, true))
	end)
	local waiting = waitForValue(10, 0.05, function()
		return firstWaiting
	end)
	assertTrue(waiting == true, "First Set should wait after DataStore commit")
	local second = table.pack(ks:Set(key, {data = makeRawData(2)}, EXPIRATION_TIME, true))
	releaseFirst = true
	local finished = waitForValue(10, 0.05, function()
		return firstResult ~= nil
	end)
	ks.SetMemory = realSetMemory

	assertTrue(finished == true, "First Set should finish")
	assertTrue(second[1] == true and second[2] == true, "Second Set should succeed")
	assertTrue(firstResult[1] == true and firstResult[2] == true, "Older Set should observe newer cache")
	assertTrue(ks.Store:GetAsync(key).coins == 2, "DataStore should keep the newer Set")
	assertTrue(ks.Map:GetAsync(key).data.coins == 2, "Late Set must not overwrite newer shared data")
	cleanupKey(key)
end

local function testLateSetKeepsNewerPendingPublish()
	local key = newKey("SetPending")
	assertTrue(ks:Get(key, true) ~= false, "Get should create the key")

	local realSetMemory = ks.SetMemory
	local firstWaiting, releaseFirst, calls = false, false, 0
	ks.SetMemory = function()
		calls += 1
		if calls == 1 then
			firstWaiting = true
			while not releaseFirst do task.wait(0.05) end
		end
		return false
	end
	local firstResult
	local result = table.pack(xpcall(function()
		task.spawn(function()
			firstResult = table.pack(pcall(ks.Set, ks, key, {data = makeRawData(1)}, EXPIRATION_TIME, true))
		end)
		assertTrue(waitForValue(10, 0.05, function() return firstWaiting end), "First Set should wait after its commit")
		local dataSaved, memorySaved = ks:Set(key, {data = makeRawData(2)}, EXPIRATION_TIME, true)
		assertTrue(dataSaved and not memorySaved, "Newer Set should queue its committed value")
		local newerPending = ks.PendingMemoryPublish[key]
		assertTrue(newerPending ~= nil, "Newer Set should have a pending publication")
		releaseFirst = true
		assertTrue(waitForValue(10, 0.05, function() return firstResult ~= nil end), "First Set should finish")
		assertTrue(firstResult[1] and firstResult[2] and not firstResult[3], "Older Set should report partial success")
		assertTrue(ks.PendingMemoryPublish[key] == newerPending, "Older Set must not replace the newer pending publication")
		ks.SetMemory = realSetMemory
		assertTrue(waitForValue(15, 0.5, function()
			local shared = ks.Map:GetAsync(key)
			return shared and shared.data.coins == 2 and ks.PendingMemoryPublish[key] == nil
		end), "Retry should publish the newest durable value")
	end, debug.traceback))
	releaseFirst = true
	ks.SetMemory = realSetMemory
	cleanupKey(key)
	assertTrue(result[1], `Pending publication race failed: {tostring(result[2])}`)
end

local function testSetDoesNotPublishAfterDurableRemoval()
	local key = `KS_SetRemove_{runId}`
	local realStore, realMap, realSetMemory = ks.Store, ks.Map, ks.SetMemory
	local metadata = {__krossSyncRevision = 0}
	local removed = false
	local memoryWrites = 0
	local keyInfo = {
		GetMetadata = function() return table.clone(metadata) end,
		GetUserIds = function() return {} end,
	}
	ks.Store = {
		Name = "removal-race-store",
		UpdateAsync = function(_, _, transform)
			local value, _, nextMetadata = transform(makeRawData(0), keyInfo)
			if value then metadata = nextMetadata end
			return value, keyInfo
		end,
		GetAsync = function()
			assertTrue(removed, "Durable read must happen after simulated removal")
			return {__krossSyncRemoved = true, removedAt = os.time()}, keyInfo
		end,
	}
	ks.Map = {
		Name = "empty-map",
		GetAsync = function() return nil end,
		UpdateAsync = function(_, _, transform)
			local value = transform(nil)
			if value then memoryWrites += 1 end
			return value
		end,
	}
	ks.SetMemory = function(self, ...)
		removed = true
		return realSetMemory(self, ...)
	end
	local result = table.pack(xpcall(function()
		return ks:Set(key, function()
			return makeRawData(1)
		end, EXPIRATION_TIME, true)
	end, debug.traceback))
	ks.Store, ks.Map, ks.SetMemory = realStore, realMap, realSetMemory
	ks.LastData[key] = nil
	ks.IsGetting[key] = nil
	ks.IsSaving[key] = nil
	ks.RemovedKeys[key] = nil
	ks.PendingMemoryPublish[key] = nil
	assertTrue(result[1], `Removal race test raised an error: {tostring(result[2])}`)
	assertTrue(result[2] == true and result[3] == false, "Set must report a durable write but no memory publish after removal")
	assertTrue(memoryWrites == 0, "Set must not revive a removed key when memory is missing")
end

local function testSaveDataRejectsOlderSnapshot()
	local key = newKey("SaveRace")
	assertTrue(ks:Get(key, true) ~= false, "Get should create the key")
	assertTrue(ks:SaveMemory(key, function(old)
		old.data.coins = 1
		return old
	end, EXPIRATION_TIME, true) == true, "First memory update should succeed")
	local first = table.clone(ks.LastData[key])
	first.data = makeRawData(1)
	assertTrue(ks:SaveMemory(key, function(old)
		old.data.coins = 2
		return old
	end, EXPIRATION_TIME, true) == true, "Second memory update should succeed")
	local second = ks.LastData[key]
	assertTrue(second.dataSequence > first.dataSequence, "Memory updates must have ordered sequences")
	assertTrue(ks:SaveData(key, second, true) == true, "Newer snapshot should persist")
	local staleSaved, reason = ks:SaveData(key, first, true)
	assertTrue(staleSaved == false and reason == "stale", "Older snapshot must be rejected")
	assertTrue(ks.Store:GetAsync(key).coins == 2, "Older save must not overwrite newer data")
	cleanupKey(key)
end

local function testSaveDataAcceptsNewerSnapshotAfterEarlierSave()
	local key = newKey("SaveOrder")
	assertTrue(ks:Get(key, true) ~= false, "Get should create the key")
	assertTrue(ks:SaveMemory(key, function(old)
		old.data.coins = 1
		return old
	end, EXPIRATION_TIME, true) == true, "First memory update should succeed")
	local first = table.clone(ks.LastData[key])
	first.data = makeRawData(1)
	assertTrue(ks:SaveMemory(key, function(old)
		old.data.coins = 2
		return old
	end, EXPIRATION_TIME, true) == true, "Second memory update should succeed")
	local second = ks.LastData[key]
	assertTrue(ks:SaveData(key, first, true) == true, "Earlier snapshot should persist first")
	assertTrue(ks:SaveData(key, second, true) == true, "Later snapshot should supersede it")
	assertTrue(ks.Store:GetAsync(key).coins == 2, "Latest snapshot should remain durable")
	cleanupKey(key)
end

local function testSaveDataCannotOverwriteSet()
	local key = newKey("SaveVsSet")
	assertTrue(ks:Get(key, true) ~= false, "Get should create the key")
	local stale = table.clone(ks.LastData[key])
	stale.data = makeRawData(3)
	local dataSaved, memorySaved = ks:Set(key, {data = makeRawData(10)}, EXPIRATION_TIME, true)
	assertTrue(dataSaved and memorySaved, "Set should commit and publish the newer data")
	local saved, reason = ks:SaveData(key, stale, true)
	assertTrue(saved == false and reason == "stale", "Old SaveData must not overwrite Set")
	assertTrue(ks:SaveMemory(key, stale, EXPIRATION_TIME, true) == false, "Old memory table must not overwrite Set")
	assertTrue(ks.Store:GetAsync(key).coins == 10, "Set data should remain durable")
	assertTrue(ks.Map:GetAsync(key).data.coins == 10, "Set data should remain shared")
	cleanupKey(key)
end

local function testIndependentInstancesShareData()
	local key = newKey("TwoInstances")
	assertTrue(ks:Get(key, true) ~= false, "Get should create the key")
	local replica = KrossSyncService.get(STORE_NAME .. "_REPLICA", DataTemplate, MemoryTemplate, EXPIRATION_TIME)
	assertTrue(replica ~= false, "A second local instance should be created")
	local originalStore, originalMap, originalMapName = replica.Store, replica.Map, replica.MapName
	replica.Store, replica.Map, replica.MapName = ks.Store, ks.Map, ks.MapName
	local originalGetMemory = ks.GetMemory
	ks.GetMemory = function(self, mapKey, force)
		if mapKey == key then return false end
		return originalGetMemory(self, mapKey, force)
	end
	local observed = false
	local connection = ks.OnNewData:Connect(function(data)
		if data == ks.LastData[key] and data.data.coins == 55 and data.memory.remoteMarker == "latest" then
			observed = true
		end
	end)

	local result = table.pack(xpcall(function()
		assertTrue(replica:GetMemory(key, true) ~= false, "Second instance should read the shared cache")
		assertTrue(replica.LastData[key] ~= ks.LastData[key], "Instances must have separate local caches")
		local oldSnapshot = table.clone(ks.LastData[key])
		oldSnapshot.data = makeRawData(0)
		assertTrue(replica:SaveMemory(key, function(old)
			old.data.coins = 55
			return old
		end, EXPIRATION_TIME, true) == true, "Second instance should update shared data")
		assertTrue(replica:SaveData(key, replica.LastData[key], true) == true, "Second instance should persist its update")
		local staleSaved, reason = ks:SaveData(key, oldSnapshot, true)
		assertTrue(staleSaved == false and reason == "stale", "First instance must not persist stale data")
		for _, marker in ipairs({"first", "latest"}) do
			assertTrue(replica:SetMemory(key, function(old)
				old.memory.remoteMarker = marker
				return old
			end, EXPIRATION_TIME, true) == true, "Second instance should publish each temporary state")
		end
		ks.GetMemory = originalGetMemory
		return waitForValue(30, 0.5, function()
			local latest = ks.LastData[key]
			return observed and latest and latest.data.coins == 55 and latest.memory.remoteMarker == "latest"
		end)
	end, debug.traceback))
	ks.GetMemory = originalGetMemory
	connection:Disconnect()
	replica.LastData[key] = nil
	replica.PendingDataSave[key] = nil
	replica.PendingMemoryPublish[key] = nil
	replica.Store, replica.Map, replica.MapName = originalStore, originalMap, originalMapName

	assertTrue(result[1], `Independent instance test raised an error: {tostring(result[2])}`)
	assertTrue(result[2] == true, "Delayed automatic sync should converge to the latest data and memory state")
	cleanupKey(key)
end

local function clearFaultKey(key)
	ks.LastData[key] = nil
	ks.IsGetting[key] = nil
	ks.IsSaving[key] = nil
	ks.RemovedKeys[key] = nil
	ks.PendingDataSave[key] = nil
	ks.PendingMemoryPublish[key] = nil
	ks.PendingMemoryRemoval[key] = nil
end

local function testPendingPublishAfterUnSync(mode)
	local key = `KS_PubUnSync_{runId}`
	local realStore, realMap, realSetMemory = ks.Store, ks.Map, ks.SetMemory
	local function copy(value)
		if type(value) ~= "table" then return value end
		local result = {}
		for k, v in pairs(value) do result[k] = copy(v) end
		return result
	end
	local shared = {
		data = makeRawData(10), memory = {remoteMarker = "preserve-me"},
		onlineServers = {game.JobId, "RemoteServer"},
		dataRevision = 1, dataSequence = 0, dataCreateTime = os.time(),
		__krossSyncDataCheckAfter = os.time() + 300,
	}
	local durable, metadata, reads = makeRawData(10), {__krossSyncRevision = 1}, 0
	local keyInfo = {
		GetMetadata = function() return copy(metadata) end,
		GetUserIds = function() return {} end,
	}
	ks.Store = {
		Name = "unsync-publish-store",
		GetAsync = function()
			reads += 1
			return copy(durable), keyInfo
		end,
		UpdateAsync = function(_, _, transform)
			local value, _, nextMetadata = transform(copy(durable), keyInfo)
			if value then durable, metadata = copy(value), copy(nextMetadata) end
			return copy(value), keyInfo
		end,
	}
	ks.Map = {
		GetAsync = function() return copy(shared) end,
		UpdateAsync = function(_, _, transform)
			local value = transform(copy(shared))
			if value then shared = copy(value) end
			return copy(value)
		end,
	}
	ks.LastData[key] = copy(shared)
	local result = table.pack(xpcall(function()
		ks.SetMemory = function() return false end
		local saved, published = ks:Set(key, function(old)
			old.coins = 20
			return old
		end, EXPIRATION_TIME, true)
		ks.SetMemory = realSetMemory
		assertTrue(saved and not published, "Set should queue the committed value for publication")
		assertTrue(ks:UnSync(key), "UnSync should succeed while publication is pending")
		assertTrue(ks.LastData[key] == nil, "UnSync should clear the local cache")
		if mode == "missing" or mode == "removed" then shared = nil end
		if mode == "removed" then durable = {__krossSyncRemoved = true, removedAt = os.time()} end
		if mode == "active" then assertTrue(ks:GetMemory(key, true), "Explicit GetMemory should resume synchronization") end
		assertTrue(waitForValue(12, 0.1, function()
			return ks.PendingMemoryPublish[key] == nil
		end), "Pending publication should finish")
		if mode == "removed" then
			assertTrue(shared == nil and ks.LastData[key] == nil, "Pending publication must not revive durable removal")
		else
			assertTrue(shared and shared.data.coins == 20, "UnSync must not cancel shared publication")
			if mode == "active" then
				assertTrue(ks.LastData[key] and ks.LastData[key].data.coins == 20, "An explicitly resumed cache should receive the publication")
				assertTrue(table.find(shared.onlineServers, game.JobId) ~= nil, "Explicit synchronization should retain this server")
			else
				assertTrue(ks.LastData[key] == nil, "Pending publication must not reactivate UnSync")
				assertTrue(table.find(shared.onlineServers, game.JobId) == nil, "Detached publication must not register this server")
			end
			if mode ~= "missing" then
				assertTrue(shared.memory.remoteMarker == "preserve-me", "Publication must preserve shared temporary fields")
				assertTrue(table.find(shared.onlineServers, "RemoteServer") ~= nil, "Publication must preserve other servers")
			end
		end
		assertTrue(reads == (if mode == "missing" or mode == "removed" then 1 else 0), "Only a missing cache should require a durable read")
	end, debug.traceback))
	ks.Store, ks.Map, ks.SetMemory = realStore, realMap, realSetMemory
	clearFaultKey(key)
	assertTrue(result[1], `Pending publication after UnSync failed: {tostring(result[2])}`)
end

local function testSetMemoryDoesNotRepeatCommittedUpdate()
	local key = `KS_MemFault_{runId}`
	local realMap, oldRetryTime = ks.Map, ks.MaxRetryTime
	local committed, calls = {
		lastUpdate = os.time(), dataCreateTime = os.time(),
		data = makeRawData(0), memory = {counter = 0},
		onlineServers = {game.JobId}, dataRevision = 0, dataSequence = 0,
	}, 0
	ks.Map = {Name = "fault-map", UpdateAsync = function(_, _, transform)
		calls += 1
		committed = transform(committed)
		if calls == 1 then error("Injected lost response after MemoryStore commit") end
		return committed
	end}
	ks.MaxRetryTime = 2
	local result = table.pack(xpcall(function()
		return ks:SetMemory(key, function(current)
			current.memory.counter = (current.memory.counter or 0) + 1
			return current
		end, EXPIRATION_TIME, true)
	end, debug.traceback))
	ks.Map, ks.MaxRetryTime = realMap, oldRetryTime
	clearFaultKey(key)
	assertTrue(result[1] and result[2] == true, `SetMemory fault test failed: {tostring(result[2])}`)
	assertTrue(committed and committed.memory.counter == 1, "A committed SetMemory update must not run twice")
end

local function testSetDoesNotRepeatCommittedUpdate()
	local key = `KS_DataFault_{runId}`
	local realStore, realMap, oldRetryTime = ks.Store, ks.Map, ks.MaxRetryTime
	local committed, metadata, calls = makeRawData(0), {__krossSyncRevision = 0}, 0
	local keyInfo = {
		GetMetadata = function() return table.clone(metadata) end,
		GetUserIds = function() return {} end,
	}
	ks.Store = {Name = "fault-store", UpdateAsync = function(_, _, transform)
		calls += 1
		local value, _, nextMetadata = transform(table.clone(committed), keyInfo)
		if value then committed, metadata = value, nextMetadata end
		if calls == 1 then error("Injected lost response after DataStore commit") end
		return committed, keyInfo
	end}
	local shared
	ks.Map = {Name = "fault-map", UpdateAsync = function(_, _, transform)
		shared = transform(shared)
		return shared
	end}
	ks.MaxRetryTime = 2
	local result = table.pack(xpcall(function()
		return ks:Set(key, function(current)
			current.coins += 1
			return current
		end, EXPIRATION_TIME, true)
	end, debug.traceback))
	ks.Store, ks.Map, ks.MaxRetryTime = realStore, realMap, oldRetryTime
	clearFaultKey(key)
	assertTrue(result[1] and result[2] == true, `Set fault test failed: {tostring(result[2])}`)
	assertTrue(committed.coins == 1, "A committed Set update must not run twice")
end

local function testSaveDataDoesNotRepeatCommittedUpdate()
	local key = `KS_SaveFault_{runId}`
	local realStore, oldRetryTime = ks.Store, ks.MaxRetryTime
	local committed, metadata, calls = makeRawData(0), {__krossSyncRevision = 0}, 0
	local keyInfo = {
		GetMetadata = function() return table.clone(metadata) end,
		GetUserIds = function() return {} end,
	}
	ks.Store = {Name = "fault-store", UpdateAsync = function(_, _, transform)
		calls += 1
		local value, _, nextMetadata = transform(table.clone(committed), keyInfo)
		if value then committed, metadata = value, nextMetadata end
		if calls == 1 then error("Injected lost response after SaveData commit") end
		return committed, keyInfo
	end}
	ks.MaxRetryTime = 2
	local result = table.pack(xpcall(function()
		return ks:SaveData(key, function(current)
			current.coins += 1
			return current
		end, true)
	end, debug.traceback))
	local localData = ks.LastData[key]
	ks.Store, ks.MaxRetryTime = realStore, oldRetryTime
	clearFaultKey(key)
	assertTrue(result[1] and result[2] == true, `SaveData fault test failed: {tostring(result[2])}`)
	assertTrue(committed.coins == 1 and localData and localData.data.coins == 1, "A committed SaveData update must not run twice")
end

local function testSetMemoryStopsAfterInterleavedWrite()
	local key = `KS_MemInter_{runId}`
	local realMap, oldRetryTime = ks.Map, ks.MaxRetryTime
	local shared = {
		lastUpdate = os.time(), dataCreateTime = os.time(),
		data = makeRawData(0), memory = {counter = 0},
		onlineServers = {game.JobId}, dataRevision = 0, dataSequence = 0,
		__krossSyncMemoryRevision = 0,
	}
	local calls = 0
	ks.Map = {Name = "interleaved-map", UpdateAsync = function(_, _, transform)
		calls += 1
		local value = transform(shared)
		if value then shared = value end
		if calls == 1 then
			shared.memory = {counter = 10}
			shared.__krossSyncMemoryRevision += 1
			shared.__krossSyncMemoryOperation = "remote"
			error("Injected lost response after another memory write")
		end
		return value
	end}
	ks.MaxRetryTime = 2
	local result = table.pack(xpcall(function()
		return ks:SetMemory(key, function(current)
			current.memory.counter += 1
			return current
		end, EXPIRATION_TIME, true)
	end, debug.traceback))
	ks.Map, ks.MaxRetryTime = realMap, oldRetryTime
	clearFaultKey(key)
	assertTrue(result[1] and result[2] == false, "An ambiguous memory write must fail after another server writes")
	assertTrue(calls == 2 and shared.memory.counter == 10, "The memory callback must not run again after interleaving")
end

local function testSetStopsAfterInterleavedWrite()
	local key = `KS_DataInter_{runId}`
	local realStore, oldRetryTime = ks.Store, ks.MaxRetryTime
	local committed, metadata, calls = makeRawData(0), {__krossSyncRevision = 0}, 0
	local keyInfo = {
		GetMetadata = function() return table.clone(metadata) end,
		GetUserIds = function() return {} end,
	}
	ks.Store = {Name = "interleaved-store", UpdateAsync = function(_, _, transform)
		calls += 1
		local value, _, nextMetadata = transform(table.clone(committed), keyInfo)
		if value then committed, metadata = value, nextMetadata end
		if calls == 1 then
			committed = makeRawData(10)
			metadata.__krossSyncRevision += 1
			metadata.__krossSyncOperationId = "remote"
			error("Injected lost response after another durable write")
		end
		return value, keyInfo
	end}
	ks.MaxRetryTime = 2
	local result = table.pack(xpcall(function()
		return ks:Set(key, function(current)
			current.coins += 1
			return current
		end, EXPIRATION_TIME, true)
	end, debug.traceback))
	ks.Store, ks.MaxRetryTime = realStore, oldRetryTime
	clearFaultKey(key)
	assertTrue(result[1] and result[2] == false and result[3] == false, "An ambiguous durable write must fail after another server writes")
	assertTrue(calls == 2 and committed.coins == 10, "The durable callback must not run again after interleaving")
end

local function testMemoryCallbackConflictUsesLatestValue()
	local key = `KS_MemRace_{runId}`
	local realMap = ks.Map
	local first = {
		lastUpdate = os.time(), dataCreateTime = os.time(),
		data = makeRawData(0), memory = {counter = 0},
		onlineServers = {game.JobId}, dataRevision = 0, dataSequence = 0,
		__krossSyncMemoryRevision = 0,
	}
	local latest = table.clone(first)
	latest.memory = {counter = 5}
	latest.__krossSyncMemoryRevision = 1
	latest.__krossSyncMemoryOperation = "remote"
	local committed
	ks.Map = {Name = "conflict-map", UpdateAsync = function(_, _, transform)
		transform(first)
		committed = transform(latest)
		return committed
	end}
	local result = table.pack(xpcall(function()
		return ks:SetMemory(key, function(current)
			current.memory.counter += 1
			return current
		end, EXPIRATION_TIME, true)
	end, debug.traceback))
	ks.Map = realMap
	clearFaultKey(key)
	assertTrue(result[1] and result[2] == true, `Memory callback conflict failed: {tostring(result[2])}`)
	assertTrue(committed and committed.memory.counter == 6, "Memory callback must use the latest competing value")
end

local function testDataCallbackConflictUsesLatestValue()
	local key = `KS_DataRace_{runId}`
	local realStore, realSetMemory = ks.Store, ks.SetMemory
	local firstMetadata = {__krossSyncRevision = 0}
	local latestMetadata = {__krossSyncRevision = 1}
	local firstInfo = {GetMetadata = function() return table.clone(firstMetadata) end, GetUserIds = function() return {} end}
	local latestInfo = {GetMetadata = function() return table.clone(latestMetadata) end, GetUserIds = function() return {} end}
	local committed
	ks.Store = {Name = "conflict-store", UpdateAsync = function(_, _, transform)
		transform(makeRawData(0), firstInfo)
		local value, _, metadata = transform(makeRawData(5), latestInfo)
		committed, latestMetadata = value, metadata
		return committed, latestInfo
	end}
	ks.SetMemory = function() return true end
	local result = table.pack(xpcall(function()
		return ks:Set(key, function(current)
			current.coins += 1
			return current
		end, EXPIRATION_TIME, true)
	end, debug.traceback))
	ks.Store, ks.SetMemory = realStore, realSetMemory
	clearFaultKey(key)
	assertTrue(result[1] and result[2] == true and result[3] == true, `Data callback conflict failed: {tostring(result[2])}`)
	assertTrue(committed and committed.coins == 6, "Data callback must use the latest competing value")
end

local function testMissingMemoryDoesNotReviveRemovedData()
	local key = `KS_MissFault_{runId}`
	local realStore, realMap = ks.Store, ks.Map
	ks.LastData[key] = {
		lastUpdate = os.time(), dataCreateTime = os.time(),
		data = makeRawData(7), memory = {remoteMarker = "old"},
		onlineServers = {game.JobId}, dataRevision = 1, dataSequence = 0,
	}
	ks.Store = {Name = "removed-store", GetAsync = function()
		return {__krossSyncRemoved = true, removedAt = os.time()}
	end}
	local shared
	ks.Map = {Name = "empty-map", GetAsync = function() return nil end, UpdateAsync = function(_, _, transform)
		shared = transform(shared)
		return shared
	end}
	local result = table.pack(xpcall(function()
		return ks:SetMemory(key, function(current)
			current.memory.remoteMarker = "new"
			return current
		end, EXPIRATION_TIME, true)
	end, debug.traceback))
	ks.Store, ks.Map = realStore, realMap
	clearFaultKey(key)
	assertTrue(result[1], `Missing-memory fault test raised an error: {tostring(result[2])}`)
	assertTrue(result[2] == false and shared == nil, "Missing MemoryStore must not revive durably removed data")
end

local function testSetMemoryRestoresDurableDataOnMiss()
	local key = `KS_MissRest_{runId}`
	local realStore, realMap = ks.Store, ks.Map
	ks.LastData[key] = {
		lastUpdate = os.time(), dataCreateTime = os.time(),
		data = makeRawData(1), memory = {remoteMarker = "old"},
		onlineServers = {game.JobId}, dataRevision = 1, dataSequence = 0,
	}
	local reads, shared = 0, nil
	local keyInfo = {GetMetadata = function() return {__krossSyncRevision = 2} end}
	ks.Store = {Name = "durable-store", GetAsync = function()
		reads += 1
		return makeRawData(5), keyInfo
	end}
	ks.Map = {
		Name = "empty-map",
		GetAsync = function() return shared end,
		UpdateAsync = function(_, _, transform)
			local value = transform(shared)
			if value then shared = value end
			return value
		end,
	}
	local result = table.pack(xpcall(function()
		return ks:SetMemory(key, function(current)
			current.memory.remoteMarker = "new"
			return current
		end, EXPIRATION_TIME, true)
	end, debug.traceback))
	ks.Store, ks.Map = realStore, realMap
	clearFaultKey(key)
	assertTrue(result[1] and result[2] == true, `Missing-memory recovery failed: {tostring(result[2])}`)
	assertTrue(reads == 1 and shared and shared.data.coins == 5 and shared.memory.remoteMarker == "new", "Cache miss must restore durable data before applying memory update")
end

local function testSetMemoryFailsClosedWhenDurableReadFails()
	local key = `KS_MissFail_{runId}`
	local realStore, realMap, oldRetryTime = ks.Store, ks.Map, ks.MaxRetryTime
	local shared
	ks.Store = {Name = "failed-store", GetAsync = function() error("Injected durable read failure") end}
	ks.Map = {
		Name = "empty-map",
		GetAsync = function() return shared end,
		UpdateAsync = function(_, _, transform)
			local value = transform(shared)
			if value then shared = value end
			return value
		end,
	}
	ks.MaxRetryTime = 1
	local result = table.pack(xpcall(function()
		return ks:SetMemory(key, function(current)
			current.memory.remoteMarker = "new"
			return current
		end, EXPIRATION_TIME, true)
	end, debug.traceback))
	ks.Store, ks.Map, ks.MaxRetryTime = realStore, realMap, oldRetryTime
	clearFaultKey(key)
	assertTrue(result[1] and result[2] == false, "Missing cache must fail when durable verification fails")
	assertTrue(shared == nil, "Failed durable verification must not publish local data")
end

local function testMemoryWritesPreserveVerificationReservation()
	local key = `KS_CheckKeep_{runId}`
	local realMap = ks.Map
	local checkAfter = os.time() + 60
	local shared = {
		lastUpdate = os.time(), dataCreateTime = os.time(),
		data = makeRawData(0), memory = {}, onlineServers = {game.JobId},
		dataRevision = 0, dataSequence = 0,
		__krossSyncDataCheckAfter = checkAfter, __krossSyncDataCheckOwner = "reserved",
	}
	ks.Map = {UpdateAsync = function(_, _, transform)
		local updated = transform(shared)
		if updated then shared = updated end
		return updated
	end}
	local result = table.pack(xpcall(function()
		local input = table.clone(shared)
		input.__krossSyncDataCheckAfter = os.time() + 10_000
		input.__krossSyncDataCheckOwner = nil
		assertTrue(ks:SetMemory(key, input, EXPIRATION_TIME, true), "Table update should succeed")
		assertTrue(shared.__krossSyncDataCheckAfter == checkAfter, "Table update must not defer verification")
		assertTrue(shared.__krossSyncDataCheckOwner == "reserved", "Table update must preserve the active owner")
		assertTrue(ks:SetMemory(key, function(old)
			old.__krossSyncDataCheckAfter = nil
			old.__krossSyncDataCheckOwner = nil
			return old
		end, EXPIRATION_TIME, true), "Function update should succeed")
		assertTrue(shared.__krossSyncDataCheckAfter == checkAfter and shared.__krossSyncDataCheckOwner == "reserved", "Function update must preserve the reservation")
	end, debug.traceback))
	ks.Map = realMap
	clearFaultKey(key)
	assertTrue(result[1], `Verification reservation test failed: {tostring(result[2])}`)
end

local function testPeriodicDurableVerification(removed, failFirstRead, busy)
	local key = newKey(if removed then "CheckRemove" else "CheckRecover")
	assertTrue(ks:Get(key, true), "Periodic verification setup should create the key")
	local replica = KrossSyncService.get(STORE_NAME .. "_VERIFY", DataTemplate, MemoryTemplate, EXPIRATION_TIME)
	assertTrue(replica, "Verification replica should be created")
	local realStore, realMap = ks.Store, ks.Map
	local replicaStore, replicaMap, replicaMapName = replica.Store, replica.Map, replica.MapName
	local oldRetryTime, replicaRetryTime = ks.MaxRetryTime, replica.MaxRetryTime
	if failFirstRead then ks.MaxRetryTime, replica.MaxRetryTime = 1, 1 end
	replica.Store, replica.Map, replica.MapName = realStore, realMap, ks.MapName
	assertTrue(replica:GetMemory(key, true), "Replica should start from the same cache")
	local reads, lostResponse, notified = 0, false, false
	local connection = ks.OnNewData:Connect(function(data)
		if data == ks.LastData[key] and data.data.coins == 81 then notified = true end
	end)
	local result = table.pack(xpcall(function()
		realStore:UpdateAsync(key, function(old, info)
			local metadata = info:GetMetadata()
			metadata.__krossSyncRevision = (metadata.__krossSyncRevision or 0) + 1
			metadata.__krossSyncSourceRevision = nil
			metadata.__krossSyncSourceSequence = nil
			return if removed then {__krossSyncRemoved = true, removedAt = os.time()} else makeRawData(81), info:GetUserIds(), metadata
		end)
		realMap:UpdateAsync(key, function(old)
			old.memory.remoteMarker = "preserve-me"
			old.__krossSyncDataCheckAfter = os.time() - 1
			old.__krossSyncDataCheckOwner = "expired-owner"
			return old
		end, EXPIRATION_TIME)
		local store = {Name = realStore.Name, GetAsync = function(_, storeKey, options)
			assertTrue(storeKey == key, "Verification must only read its test key")
			reads += 1
			if failFirstRead and reads == 1 then error("Injected first periodic durable read failure") end
			return realStore:GetAsync(storeKey, options)
		end}
		local map = {
			GetAsync = function(_, mapKey) return realMap:GetAsync(mapKey) end,
			UpdateAsync = function(_, mapKey, transform, expiration)
				local updated = realMap:UpdateAsync(mapKey, transform, expiration)
				if updated and updated.__krossSyncDataCheckOwner and not lostResponse then
					lostResponse = true
					error("Injected lost verification reservation response")
				end
				return updated
			end,
		}
		ks.Store, replica.Store, ks.Map, replica.Map = store, store, map, map
		local nextWrite, temporaryWrites = 0, 0
		assertTrue(waitForValue(if failFirstRead then 90 else 60, 0.5, function()
			if busy and os.clock() >= nextWrite then
				for _, instance in ipairs({ks, replica}) do
					if instance:SetMemory(key, function(old)
						old.memory.restoreToken = tostring(temporaryWrites)
						return old
					end, EXPIRATION_TIME, true) then temporaryWrites += 1 end
				end
				nextWrite = os.clock() + 2
			end
			local shared = realMap:GetAsync(key)
			if removed then
				return shared and shared.__krossSyncRemoved and not ks.LastData[key] and not replica.LastData[key]
			end
			return shared and not shared.__krossSyncDataCheckOwner
				and shared.__krossSyncDataCheckAfter > os.time() + 270
				and ks.LastData[key] and ks.LastData[key].data.coins == 81
				and replica.LastData[key] and replica.LastData[key].data.coins == 81 and (busy or notified)
		end), "Periodic verification should repair both instances without a cache miss")
		if busy then assertTrue(temporaryWrites >= 4, "Both caches should be repeatedly replaced while verification is pending") end
		assertTrue(reads == (if failFirstRead then 2 else 1), `Shared verification performed an unexpected number of durable reads: {reads}`)
		assertTrue(lostResponse, "The reservation response-loss path should be exercised")
		if not removed then
			assertTrue(realMap:GetAsync(key).memory.remoteMarker == "preserve-me", "Verification must preserve temporary fields")
		end
	end, debug.traceback))
	ks.Store, ks.Map = realStore, realMap
	ks.MaxRetryTime, replica.MaxRetryTime = oldRetryTime, replicaRetryTime
	replica.LastData[key] = nil
	replica.RemovedKeys[key] = nil
	replica.Store, replica.Map, replica.MapName = replicaStore, replicaMap, replicaMapName
	connection:Disconnect()
	cleanupKey(key)
	assertTrue(result[1], `Periodic verification test failed: {tostring(result[2])}`)
end

local function runAllTests()
	waitForReady(30)
	log("Using run id", runId)

	runStep("Get performs one MemoryStore write", testGetWritesMemoryOnce)
	runStep("Get creates missing key", testGetCreatesMissingKey)
	runStep("Get skips memory after DataStore failure", testGetSkipsMemoryWhenDataFails)
	runStep("GetData returns synchronized cache", testGetDataReturnsSynchronizedCache)
	runStep("GetData fails when memory synchronization fails", testGetDataFailsWhenMemorySyncFails)
	runStep("GetData refreshes memory without extra writes", testGetDataRefreshesMemoryWithoutExtraWrites)
	runStep("GetData preserves shared memory", testGetDataPreservesSharedMemory)
	runStep("GetData preserves unsaved shared data", testGetDataPreservesUnsavedSharedData)
	runStep("Save function persists resolved data", testSaveFunctionPersistsResolvedData)
	runStep("Save keeps newer memory due time", testSaveKeepsNewerMemoryDueTime)
	runStep("Important change persists on explicit request", testExplicitDurableSave)
	runStep("Save queues DataStore after partial failure", testSaveQueuesDataAfterPartialFailure)
	runStep("SaveData works without MemoryStore read", testSaveDataIndependentOfMemoryStore)
	runStep("force keeps locks and validation", testForceKeepsLocksAndValidation)
	runStep("GetData rejects removal tombstone", testGetDataRejectsRemovalTombstone)
	runStep("AutoGetMemory restores missing entry and JobId", testAutoGetMemoryRestoresMissingEntry)
	runStep("AutoGetMemory uses newer durable data", testAutoGetMemoryUsesNewerDurableData)
	runStep("AutoGetMemory rejects durable removal", testAutoGetMemoryRejectsDurableRemoval)
	runStep("Remove locks, clears cache, and stays removed", testRemoveLocksAndDoesNotRestore)
	runStep("Remove requires a durable tombstone", testRemoveRequiresDurableTombstone)
	runStep("Durable tombstone survives missing memory marker", testDurableTombstoneSurvivesMissingMemoryMarker)
	runStep("MemoryStore removal retries after transient failure", testMemoryRemovalRetriesAfterTransientFailure)
	runStep("Standalone remove methods clear cache", testStandaloneRemoveMethodsClearCache)
	runStep("UnSync removes duplicate JobIds", testUnSyncRemovesDuplicateJobIds)
	runStep("UnSync retries final save", testUnSyncRetriesFinalSave)
	runStep("AutoGet preserves DataStore save time", testAutoGetPreservesDataSaveTime)
	runStep("AutoGet continues after an initial cached key", testInitialCacheDoesNotStopAutoGet)
	runStep("Completed operations release lock keys", testIdleLocksAreReleased)
	runStep("MaxRetryTime one performs one attempt", testSingleAttemptRetryLimit)
	runStep("RemovedKeys expires without another access", testRemovedKeyRecordExpires)
	runStep("AutoGet does not reactivate UnSync", testUnSyncIsNotReactivatedByAutoGet)
	runStep("Set persists before publishing memory", testSetPersistsBeforeMemory)
	runStep("Set reports partial success", testSetReportsPartialSuccess)
	runStep("SetMemory skips DataStore", testSetMemoryDoesNotUseDataStore)
	runStep("SetMemory reports failed delivery", testSetMemoryReportsFailure)
	runStep("Set retries MemoryStore publish", testSetRetriesMemoryPublish)
	runStep("Pending publication does not reactivate UnSync", function() testPendingPublishAfterUnSync("shared") end)
	runStep("Pending publication restores missing cache without subscribing", function() testPendingPublishAfterUnSync("missing") end)
	runStep("Pending publication updates explicitly resumed cache", function() testPendingPublishAfterUnSync("active") end)
	runStep("Detached publication rejects durable removal", function() testPendingPublishAfterUnSync("removed") end)
	runStep("Late Set keeps newer shared data", testLateSetCannotOverwriteNewerMemory)
	runStep("Late Set keeps newer pending publication", testLateSetKeepsNewerPendingPublish)
	runStep("Set cannot republish after durable removal", testSetDoesNotPublishAfterDurableRemoval)
	runStep("SaveData rejects older snapshot", testSaveDataRejectsOlderSnapshot)
	runStep("SaveData accepts newer snapshot", testSaveDataAcceptsNewerSnapshotAfterEarlierSave)
	runStep("SaveData cannot overwrite Set", testSaveDataCannotOverwriteSet)
	runStep("Independent instances share data", testIndependentInstancesShareData)
	runStep("Memory writes preserve verification reservation", testMemoryWritesPreserveVerificationReservation)
	runStep("Periodic verification repairs stale cache", function() testPeriodicDurableVerification(false) end)
	runStep("Periodic verification publishes durable removal", function() testPeriodicDurableVerification(true) end)
	runStep("Periodic verification retries failed durable read", function() testPeriodicDurableVerification(false, true) end)
	runStep("Periodic verification survives continuous writes", function() testPeriodicDurableVerification(false, false, true) end)
	runStep("SetMemory does not repeat an ambiguous commit", testSetMemoryDoesNotRepeatCommittedUpdate)
	runStep("Set does not repeat an ambiguous commit", testSetDoesNotRepeatCommittedUpdate)
	runStep("SaveData does not repeat an ambiguous commit", testSaveDataDoesNotRepeatCommittedUpdate)
	runStep("SetMemory stops after an interleaved write", testSetMemoryStopsAfterInterleavedWrite)
	runStep("Set stops after an interleaved write", testSetStopsAfterInterleavedWrite)
	runStep("Memory callback conflict uses latest value", testMemoryCallbackConflictUsesLatestValue)
	runStep("Data callback conflict uses latest value", testDataCallbackConflictUsesLatestValue)
	runStep("Missing memory cannot revive durable removal", testMissingMemoryDoesNotReviveRemovedData)
	runStep("SetMemory restores durable data on cache miss", testSetMemoryRestoresDurableDataOnMiss)
	runStep("SetMemory fails closed when durable read fails", testSetMemoryFailsClosedWhenDurableReadFails)
end

local ok, result = xpcall(runAllTests, debug.traceback)
cleanupAll()

if not ok then
	warn("[KrossSync Regression] TEST RUN FAILED", result)
	error(result, 0)
end

log("ALL TESTS PASSED", runId)
