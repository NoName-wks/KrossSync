-- Opt-in live-server test. Place beside KrossSync, set RunTests=true and a unique RunId.
local RunService = game:GetService("RunService")
if RunService:IsStudio() or script:GetAttribute("RunTests") ~= true then
	return
end

local runId = script:GetAttribute("RunId")
assert(type(runId) == "string" and #runId > 0 and #runId <= 24 and runId:match("^[%w_-]+$"), "Set a unique RunId (1-24 letters, numbers, _ or -)")
assert(game.JobId ~= "", "The test needs a live server JobId")

local combined = script:GetAttribute("CombinedTests") == true
local coordinationTTL = if combined then 1_800 else 300
local cacheTTL = 900
local loadCount = script:GetAttribute("LoadKeys") or 4
local loadInterval = script:GetAttribute("LoadInterval") or 2
local exitMode = script:GetAttribute("ExitMode") or "Normal"
if combined then
	assert(type(loadCount) == "number" and loadCount % 1 == 0 and loadCount >= 1 and loadCount <= 32, "LoadKeys must be 1-32")
	assert(type(loadInterval) == "number" and loadInterval >= 1 and loadInterval <= 30, "LoadInterval must be 1-30 seconds")
	assert(exitMode == "Normal" or exitMode == "Abrupt", "ExitMode must be Normal or Abrupt")
end

local MemoryStoreService = game:GetService("MemoryStoreService")
local coordination = MemoryStoreService:GetHashMap("KrossSync_V002_MULTI_COORD")
local results = game:GetService("DataStoreService"):GetDataStore("KrossSync_V002_MULTI_RESULTS")
local KrossSyncService = require(script.Parent:WaitForChild("KrossSync"))
local dataTemplate = {coins = 0}
local memoryTemplate = {remoteMarker = "", writers = {}}
local sync = KrossSyncService.get("KrossSync_V002_MULTI_TEST", dataTemplate, memoryTemplate, if combined then cacheTTL else 180)
assert(sync ~= false, "KrossSync initialization failed")
local getOptions = Instance.new("DataStoreGetOptions")
getOptions.UseCache = false
local key = "K2_" .. runId
local checks = {}
local metrics = {requests = {}, requestErrors = 0, injectedFailures = 0, writes = 0, writesByKey = {}, writeFailures = 0, latencyTotal = 0, latencyMax = 0, remoteObserved = false, remoteAgeMax = 0, durableChecks = {}}
local loadKeys, loadKeySet = {}, {}
local recoveryKeys = {key .. "_R", key .. "_D", key .. "_H"}
local loadRunning, faultArmed, recoveryArmed = false, false, false
local loadWorker, loadError
local heartbeatAt = 0
local originalStore, originalMap = sync.Store, sync.Map

local function log(...)
	print("[KrossSync Multi]", runId, game.JobId, ...)
end

local function waitFor(label, timeout, predicate)
	local deadline = os.clock() + timeout
	local lastError
	repeat
		local ok, value = pcall(predicate)
		if ok and value then
			return value
		end
		if not ok then lastError = tostring(value) end
		task.wait(if combined then 2 else 0.5)
	until os.clock() >= deadline
	error("Timed out: " .. label .. (if lastError then "\n" .. lastError else ""))
end

local function readCoordination()
	metrics.requests.coordinationGet = (metrics.requests.coordinationGet or 0) + 1
	return coordination:GetAsync(runId)
end

local function updateCoordination(transform)
	metrics.requests.coordinationUpdate = (metrics.requests.coordinationUpdate or 0) + 1
	return coordination:UpdateAsync(runId, transform, coordinationTTL)
end

local joined = updateCoordination(function(state)
	state = state or {phase = 0}
	if combined then
		local config = {loadCount = loadCount, loadInterval = loadInterval, exitMode = exitMode, injectFailures = script:GetAttribute("InjectFailures") ~= false, placeVersion = game.PlaceVersion}
		state.config = state.config or config
		for name, value in pairs(config) do assert(state.config[name] == value, "Both servers need the same combined test settings") end
	end
	if not state.first then
		state.first = game.JobId
	elseif state.first ~= game.JobId and not state.second then
		state.second = game.JobId
	end
	return state
end)

local role = if joined.first == game.JobId then "first" elseif joined.second == game.JobId then "second" else nil
if not role then
	log("SKIP: two other servers already joined")
	return
end

local function recordResult(stage, passed, message, close)
	local snapshot = table.clone(metrics)
	snapshot.requests = table.clone(metrics.requests)
	snapshot.durableChecks = table.clone(metrics.durableChecks)
	snapshot.writesByKey = table.clone(metrics.writesByKey)
	snapshot.latencyMean = if metrics.writes + metrics.writeFailures > 0 then metrics.latencyTotal / (metrics.writes + metrics.writeFailures) else 0
	local result = {
		jobId = game.JobId, placeId = game.PlaceId, placeVersion = game.PlaceVersion,
		passed = passed, checks = table.clone(checks), at = os.time(), stage = stage,
		combined = combined, metrics = if combined then snapshot else nil,
		exitMode = if combined then exitMode else nil, close = close,
		complete = passed == true and (not combined or (role == "second" and exitMode == "Normal")),
		requiresExitConfirmation = combined and exitMode == "Abrupt",
		error = if message then tostring(message):sub(1, 500) else nil,
	}
	for attempt = 1, 3 do
		local recorded = pcall(function()
			results:UpdateAsync(runId, function(previous)
				previous = if previous then table.clone(previous) else {}
				previous[role] = result
				return previous
			end)
		end)
		if recorded then return end
		task.wait(attempt)
	end
	error("Could not record live-server test result")
end

if combined then
	sync.MaxRetryTime = 3
	local injected = {}
	for _, kind in ipairs({"data", "memory"}) do
		local target = if kind == "data" then originalStore else originalMap
		local proxy = {Name = if kind == "data" then originalStore.Name else sync.MapName}
		for _, method in ipairs({"GetAsync", "UpdateAsync", "RemoveAsync"}) do
			proxy[method] = function(_, storeKey, ...)
				if kind == "memory" and method == "UpdateAsync" and faultArmed and loadKeySet[storeKey]
					and script:GetAttribute("InjectFailures") ~= false and not injected[storeKey] then
					injected[storeKey] = true
					metrics.injectedFailures += 1
					error("Injected load-key MemoryStore failure before commit")
				end
				local counter = kind .. method
				metrics.requests[counter] = (metrics.requests[counter] or 0) + 1
				if kind == "data" and method == "GetAsync" and recoveryArmed then
					for _, recoveryKey in ipairs(recoveryKeys) do
						if storeKey == recoveryKey then metrics.durableChecks[storeKey] = (metrics.durableChecks[storeKey] or 0) + 1 end
					end
				end
				local response = table.pack(pcall(target[method], target, storeKey, ...))
				if not response[1] then
					metrics.requestErrors += 1
					error(response[2], 0)
				end
				return table.unpack(response, 2, response.n)
			end
		end
		if kind == "data" then sync.Store = proxy else sync.Map = proxy end
	end

	game:BindToClose(function()
		loadRunning = false
		if role ~= "first" then return end
		local deadline = os.clock() + 22
		while next(sync.LastData) and os.clock() < deadline do task.wait(0.1) end
		local close = {completed = next(sync.LastData) == nil, at = os.time(), loadError = loadError}
		pcall(function()
			updateCoordination(function(state)
				if not state then return nil end
				close.ready = state.phase >= 12 and state.readyAt ~= nil
				state.firstClose = close
				return state
			end)
		end)
		pcall(recordResult, "normalClose", nil, loadError, close)
	end)
end

local function startLoad()
	if not combined then return end
	for index = 1, loadCount do
		local loadKey = key .. "_L" .. index
		table.insert(loadKeys, loadKey)
		loadKeySet[loadKey] = true
		assert(waitFor("load key setup", 30, function() return sync:Get(loadKey, true) end), "Load key setup failed")
	end
	loadRunning, faultArmed = true, true
	metrics.startedAt = os.time()
	loadWorker = task.spawn(function()
		local ok, message = xpcall(function()
			local index = 1
			while loadRunning do
				if os.time() - heartbeatAt >= 10 then
					updateCoordination(function(state)
						assert(state, "Coordination expired")
						assert(not state.failure, state.failure)
						state[role .. "Heartbeat"] = os.time()
						return state
					end)
					heartbeatAt = os.time()
				end
				local loadKey = loadKeys[index]
				if not sync.IsGetting[loadKey] and not sync.IsSaving[loadKey] then
					local started = os.clock()
					local saved = sync:SetMemory(loadKey, function(old)
						local other = old.memory.writers[if role == "first" then "second" else "first"]
						if type(other) == "table" then
							metrics.remoteObserved = true
							metrics.remoteAgeMax = math.max(metrics.remoteAgeMax, os.time() - other.at)
						end
						local previous = old.memory.writers[role]
						old.memory.writers[role] = {jobId = game.JobId, sequence = (previous and previous.sequence or 0) + 1, at = os.time()}
						return old
					end, cacheTTL, true)
					local elapsed = os.clock() - started
					metrics.latencyTotal += elapsed
					metrics.latencyMax = math.max(metrics.latencyMax, elapsed)
					if saved then
						metrics.writes += 1
						metrics.writesByKey[loadKey] = (metrics.writesByKey[loadKey] or 0) + 1
					else
						metrics.writeFailures += 1
						error("Load write failed; not blindly replaying it")
					end
				end
				index = index % loadCount + 1
				task.wait(loadInterval)
			end
		end, debug.traceback)
		if not ok then
			loadError = tostring(message)
			loadRunning = false
			pcall(function()
				updateCoordination(function(state)
					if not state then return nil end
					state.failure = loadError:sub(1, 500)
					return state
				end)
			end)
		end
	end)
end

local function stopLoad()
	loadRunning = false
	if loadWorker then
		waitFor("load worker stopped", 40, function() return coroutine.status(loadWorker) == "dead" end)
	end
	metrics.stoppedAt = os.time()
end

local function checkLoad()
	assert(not loadError, loadError)
	assert(metrics.writes >= loadCount and metrics.remoteObserved, "Load must write each key and observe the other server")
	for _, loadKey in ipairs(loadKeys) do assert(metrics.writesByKey[loadKey], "Every load key needs a successful write") end
	checks.load = true
	if script:GetAttribute("InjectFailures") ~= false then
		assert(metrics.injectedFailures >= loadCount, "Each load key must recover from its injected failure")
		checks.failureRetry = true
	end
end

local function waitPhase(phase)
	return waitFor("phase " .. phase, 120, function()
		local state = readCoordination()
		return state and state.first and state.second and state.phase >= phase
	end)
end

local function advance(phase)
	updateCoordination(function(state)
		assert(state and state.first and state.second, "Both servers must be present")
		state.phase = math.max(state.phase, phase)
		return state
	end)
end

local function waitStart(name)
	updateCoordination(function(state)
		assert(state and state.first and state.second, "Both servers must be present")
		state[name] = state[name] or {}
		local ready = state[name]
		ready[role] = true
		if ready.first and ready.second and not ready.at then
			ready.at = os.time() + 2
		end
		return state
	end)
	local startAt = waitFor(name, 120, function()
		local state = readCoordination()
		local ready = state and state[name]
		return ready and ready.at
	end)
	task.wait(math.max(0, startAt - os.time()))
	waitFor("idle key", 10, function()
		return not sync.IsGetting[key] and not sync.IsSaving[key]
	end)
end

local function runConcurrentUpdates()
	waitStart("durableReady")
	local saved = sync:Set(key, function(old)
		old.coins += 1
		return old
	end, 180, true)
	assert(saved, "Concurrent Set must commit each increment")
	waitFor("both durable increments", 40, function()
		local data = sync:GetMemory(key, true)
		return data and data.data.coins == 4
	end)
	local stored = sync.Store:GetAsync(key, getOptions)
	assert(stored and stored.coins == 4, "Concurrent Set must preserve both durable increments")
	checks.concurrentSet = true
	log("CHECK concurrent Set")

	waitStart("memoryReady")
	assert(sync:SetMemory(key, function(old)
		old.memory.writers[role] = game.JobId
		return old
	end, 180, true), "Concurrent SetMemory must publish each writer")
	waitFor("both memory writers", 40, function()
		local data = sync:GetMemory(key, true)
		local writers = data and data.memory and data.memory.writers
		return writers and writers.first and writers.second
			and writers.first ~= writers.second and writers[role] == game.JobId
	end)
	checks.concurrentMemory = true
	log("CHECK concurrent SetMemory")
end

local sawMarker = false
local sawCoins = false
sync.OnNewData:Connect(function(data)
	if data.memory and data.memory.remoteMarker == runId then
		sawMarker = true
	end
	if data.data and data.data.coins == 2 then
		sawCoins = true
	end
end)

local function runFirst()
	waitPhase(0)
	local initial = sync:Get(key, true)
	assert(initial and initial.data, "First server must create the key")
	local dataSaved, memorySaved = sync:Set(key, function(old)
		old.coins = 1
		return old
	end, 180, true)
	assert(dataSaved and memorySaved, "First Set must reach both stores")
	startLoad()
	advance(1)

	waitPhase(2)
	waitFor("remote memory change", 40, function()
		return sawMarker and sync.LastData[key] and sync.LastData[key].memory.remoteMarker == runId
	end)
	local stale = table.clone(sync.LastData[key])
	stale.data = {coins = 1}
	advance(3)

	waitPhase(4)
	local saved, reason = sync:SaveData(key, stale, true)
	assert(saved == false and reason == "stale", "Old server snapshot must not overwrite Set")
	waitFor("remote data change", 40, function()
		return sawCoins and sync.LastData[key] and sync.LastData[key].data.coins == 2
	end)
	runConcurrentUpdates()
	assert(sync:UnSync(key), "First UnSync failed")
	advance(5)

	waitPhase(6)
	local originalSetMemory = sync.SetMemory
	sync.SetMemory = function(self, storeKey, ...)
		if storeKey ~= key then return originalSetMemory(self, storeKey, ...) end
		advance(7)
		waitPhase(8)
		return originalSetMemory(self, storeKey, ...)
	end
	local delayed = table.pack(pcall(sync.Set, sync, key, function(old)
		old.coins += 1
		return old
	end, 180, true))
	sync.SetMemory = originalSetMemory
	assert(delayed[1], tostring(delayed[2]))
	assert(delayed[2] == true and delayed[3] == false, "Late Set must not publish after removal")
	assert(sync:Get(key, true) == false, "Removed key must stay removed on the first server")
	assert(sync:SaveMemory(key, stale, 180, true) == false, "Stale memory must not revive a removed key")
	local removedData = sync.Store:GetAsync(key, getOptions)
	local removedMemory = sync.Map:GetAsync(key)
	assert(removedData and removedData.__krossSyncRemoved == true, "Late Set must preserve the durable tombstone")
	assert(removedMemory and removedMemory.__krossSyncRemoved == true, "Late Set must preserve the memory tombstone")
	checks.removalRace = true
	log("CHECK Set/Remove race")
	advance(9)
end

local function runSecond()
	waitPhase(1)
	local initial = sync:Get(key, true)
	assert(initial and initial.data and initial.data.coins == 1, "Second server must see the first Set")
	startLoad()
	assert(sync:SetMemory(key, function(old)
		old.memory.remoteMarker = runId
		return old
	end, 180, true), "Second server memory update failed")
	advance(2)

	waitPhase(3)
	local dataSaved, memorySaved = sync:Set(key, function(old)
		old.coins = 2
		return old
	end, 180, true)
	assert(dataSaved and memorySaved, "Second Set must reach both stores")
	advance(4)
	runConcurrentUpdates()

	waitPhase(5)
	assert(sync:UnSync(key), "Second UnSync failed")
	local stored = sync.Store:GetAsync(key, getOptions)
	assert(stored and stored.coins == 4, "Final durable data must include both concurrent increments")
	advance(6)
	waitPhase(7)
	local dataRemoved, memoryRemoved = sync:Remove(key)
	assert(dataRemoved and memoryRemoved, "Remove must mark both stores")
	advance(8)
	waitPhase(9)
	checks.removalRace = true
	log("CHECK Set/Remove race")

	if not combined then
		sync.Store:RemoveAsync(key)
		sync.Map:RemoveAsync(key)
		coordination:RemoveAsync(runId)
	end
end

local function runCombined()
	if role == "first" then
		for _, recoveryKey in ipairs(recoveryKeys) do
			waitFor("recovery key setup", 30, function() return sync:Get(recoveryKey, true) end)
			local dataSaved, memorySaved = sync:Set(recoveryKey, function(old) old.coins = 10; return old end, cacheTTL, true)
			assert(dataSaved and memorySaved, "Recovery fixture setup failed")
			assert(sync:UnSync(recoveryKey), "Fixture owner must unsubscribe before the durable-only change")
		end
		advance(10)
		waitPhase(11)
		local originalSetMemory = sync.SetMemory
		sync.SetMemory = function(self, storeKey, ...)
			if storeKey == recoveryKeys[1] or storeKey == recoveryKeys[3] then return false end
			return originalSetMemory(self, storeKey, ...)
		end
		for _, index in ipairs({1, 3}) do
			local dataSaved, memorySaved = sync:Set(recoveryKeys[index], function(old) old.coins = 20; return old end, cacheTTL, true)
			assert(dataSaved and not memorySaved, "Recovery fixture needs a durable commit without publication")
		end
		assert(sync:RemoveData(recoveryKeys[2]), "Durable-only removal failed")
		originalMap:UpdateAsync(recoveryKeys[3], function(old)
			assert(old and old.data.coins == 10, "Lease fixture must still have the old shared value")
			old.__krossSyncDataCheckOwner = game.JobId
			old.__krossSyncDataCheckAfter = os.time() + 60
			return old
		end, cacheTTL)
		waitFor("both load writers", 60, function()
			assert(not loadError, loadError)
			for _, loadKey in ipairs(loadKeys) do if not metrics.writesByKey[loadKey] then return false end end
			return metrics.writes >= loadCount and metrics.remoteObserved and metrics.injectedFailures >= (if script:GetAttribute("InjectFailures") ~= false then loadCount else 0)
		end)
		checkLoad()
		updateCoordination(function(state)
			state.readyAt = os.time()
			state.phase = 12
			return state
		end)
		recordResult("readyToExit", nil)
		log("READY_CLOSE_FIRST", exitMode, "Close this test server now; JobId:", game.JobId)
		local deadline = os.clock() + 420
		while os.clock() < deadline do
			assert(not loadError, loadError)
			task.wait(2)
		end
		error("The first test server was not closed within 420 seconds")
	end

	waitPhase(10)
	for _, recoveryKey in ipairs(recoveryKeys) do
		local data = waitFor("observer cache setup", 30, function() return sync:GetMemory(recoveryKey, true) end)
		assert(data.data.coins == 10, "Observer must start from the stale shared value")
	end
	recoveryArmed = true
	advance(11)
	waitPhase(12)
	local observed = {}
	local closed
	waitFor("publisher exit and durable recovery", 420, function()
		assert(not loadError, loadError)
		local state = readCoordination()
		assert(state and not state.failure, state and state.failure or "Coordination disappeared")
		closed = state.firstClose
		for _, index in ipairs({1, 3}) do
			local recoveryKey = recoveryKeys[index]
			local data = sync.LastData[recoveryKey]
			if not observed[recoveryKey] and data and data.data.coins == 20 then
				waitFor("recovered key idle", 30, function() return not sync.IsGetting[recoveryKey] and not sync.IsSaving[recoveryKey] end)
				assert(sync:UnSync(recoveryKey), "Observer recovery key UnSync failed")
				observed[recoveryKey] = os.time() - state.readyAt
			end
		end
		if sync.RemovedKeys[recoveryKeys[2]] == math.huge and not sync.LastData[recoveryKeys[2]] then
			observed[recoveryKeys[2]] = observed[recoveryKeys[2]] or os.time() - state.readyAt
		end
		local quiet = state.firstHeartbeat and os.time() - state.firstHeartbeat >= math.max(25, loadInterval + 15)
		if exitMode == "Normal" then
			quiet = quiet and closed and closed.ready and closed.completed and closed.at >= state.readyAt and not closed.loadError
		else
			assert(not closed or closed.at < state.readyAt, "Normal close hook ran; this was not an abrupt exit")
		end
		return quiet and observed[recoveryKeys[1]] and observed[recoveryKeys[2]] and observed[recoveryKeys[3]]
	end)
	metrics.recoverySeconds = observed
	for index, recoveryKey in ipairs(recoveryKeys) do
		assert(metrics.durableChecks[recoveryKey] == 1, "Observer must perform exactly one durable recovery read per fixture")
		local stored = originalStore:GetAsync(recoveryKey, getOptions)
		local shared = originalMap:GetAsync(recoveryKey)
		if index == 2 then
			assert(stored and shared and stored.__krossSyncRemoved == true and shared.__krossSyncRemoved == true, "Durable deletion must reach the shared cache")
		else
			assert(stored and stored.coins == 20 and shared and shared.data.coins == 20, "Recovered latest state must match both stores")
		end
	end
	checks.durableRecovery, checks.removalRecovery, checks.leaseRecovery = true, true, true
	checks.normalClose = if exitMode == "Normal" then true else nil
	checkLoad()
	stopLoad()
	for _, loadKey in ipairs(loadKeys) do
		waitFor("load key idle", 30, function() return not sync.IsGetting[loadKey] and not sync.IsSaving[loadKey] end)
		local shared = originalMap:GetAsync(loadKey)
		if exitMode == "Normal" then
			assert(shared and not table.find(shared.onlineServers or {}, joined.first), "Normal close must remove the first JobId from load keys")
		end
		if sync.LastData[loadKey] then assert(sync:UnSync(loadKey), "Observer load key UnSync failed") end
	end
	if exitMode == "Normal" then
		local cleanupKeys = {key}
		for _, storeKey in ipairs(loadKeys) do table.insert(cleanupKeys, storeKey) end
		for _, storeKey in ipairs(recoveryKeys) do table.insert(cleanupKeys, storeKey) end
		for _, storeKey in ipairs(cleanupKeys) do
			originalStore:RemoveAsync(storeKey)
			originalMap:RemoveAsync(storeKey)
		end
		coordination:RemoveAsync(runId)
	end
end

log("START", role, if combined then "combined" else "functional")
local ok, err = xpcall(function()
	if role == "first" then runFirst() else runSecond() end
	if combined then runCombined() end
end, debug.traceback)
if combined then
	local stopped, stopError = pcall(stopLoad)
	if not stopped then
		if loadWorker and coroutine.status(loadWorker) ~= "dead" then task.cancel(loadWorker) end
		ok, err = false, tostring(err or "") .. "\n" .. tostring(stopError)
	end
	if not ok then
		pcall(function()
			updateCoordination(function(state)
				if not state then return nil end
				state.failure = tostring(err):sub(1, 500)
				return state
			end)
		end)
		-- Stop test-only retry and polling work without deleting failure evidence.
		sync.PendingMemoryPublish = {}
		for storeKey in pairs(table.clone(sync.LastData)) do pcall(sync.UnSync, sync, storeKey) end
		sync.LastData = {}
	end
end
recordResult(if ok then "finished" else "failed", ok, if ok then nil else err)
if not ok then
	warn("[KrossSync Multi] FAIL", runId, game.JobId, err)
	error(err, 0)
end
log(if combined and exitMode == "Abrupt" then "CHECKS PASSED; actual abrupt exit still needs confirmation" else "PASS")
