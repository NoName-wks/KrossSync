return function(service, runtime)
	local task, os = runtime.task, runtime.os
	local template, memory = {coins = 0}, {marker = ""}
	local sync = service.get("V010Reliability", template, memory, 90)
	sync.MaxRetryTime = 1
	local map = sync.Map
	local checks = 0
	local function waitFor(predicate, timeout)
		local deadline = os.clock() + timeout
		repeat
			if predicate() then return end
			task.wait(0.2)
		until os.clock() >= deadline
		assert(predicate(), "Timed out waiting for cache maintenance")
	end

	sync.Map = {
		GetAsync = function(_, ...) return map:GetAsync(...) end,
		UpdateAsync = function(_, key, transform, expiration)
			return map:UpdateAsync(key,function(old)
				local updated = transform(old)
				if updated then table.insert(updated.onlineServers,"Remote") end
				return updated
			end,expiration)
		end,
	}
	local created = sync:Get("Created",true)
	assert(created and created == sync.LastData.Created, "Get returned a fabricated template wrapper")
	assert(table.find(created.onlineServers,"Remote"), "Get discarded committed membership")
	sync.Map = map
	sync.LastData.Created = nil
	checks += 1
	local durableOnly = service.get("V010DurableOnly",template,memory,90)
	assert(durableOnly:SaveData("Raw",function() return {coins = 5} end,true))
	local unexpectedReads = 0
	durableOnly.Map = {GetAsync = function() unexpectedReads += 1; return nil end}

	for _, key in ipairs({"Idle", "Race", "Removed", "Missing", "Failure", "LostResponse", "FalseMemory"}) do
		assert(sync:Get(key,true), "Setup failed: " .. key)
		assert(sync:SetMemory(key,function(old)
			old.memory.marker = "keep"
			return old
		end,90,true))
	end
	assert(sync:SetMemory("FalseMemory",function(old) old.memory = false; return old end,90,true))
	local reads, updates = runtime.metrics.dataGet, runtime.metrics.memoryUpdate
	local injectedRace, injectedRemoval, injectedFailure = false, false, false
	local injectedMissing, lostResponse = false, false
	local failures = 0
	sync.Map = {
		GetAsync = function(_, ...) return map:GetAsync(...) end,
		UpdateAsync = function(_, key, transform, expiration)
			if key == "Race" and not injectedRace then
				injectedRace = true
				map:UpdateAsync(key,function(old)
					old.memory.marker = "remote"
					old.__krossSyncMemoryRefreshAfter = os.time() + 45
					old.__krossSyncMemoryRevision += 1
					old.__krossSyncMemoryOperation = "remote"
					return old
				end,90)
			elseif key == "Removed" and not injectedRemoval then
				injectedRemoval = true
				map:SetAsync(key,{__krossSyncRemoved = true,removedUntil = os.time() + 600},600)
			elseif key == "Failure" and failures < 2 then
				failures += 1
				injectedFailure = true
				error("Injected renewal failure")
			elseif key == "Missing" and not injectedMissing then
				injectedMissing = true
				sync.Store:UpdateAsync(key,function(_, info)
					return {__krossSyncRemoved = true},info:GetUserIds(),info:GetMetadata()
				end)
				map:RemoveAsync(key)
			end
			local updated = map:UpdateAsync(key,transform,expiration)
			if key == "LostResponse" and not lostResponse and updated then
				lostResponse = true
				error("Injected lost renewal response")
			end
			return updated
		end,
	}
	waitFor(function()
		return injectedRace and injectedRemoval and injectedFailure
			and sync.LastData.Removed == nil
			and sync.LastData.Race and sync.LastData.Race.memory.marker == "remote"
	end,85)
	assert(map:GetAsync("Removed").__krossSyncRemoved, "Renewal revived a tombstone")
	assert(sync.IsGetting.Removed == nil, "Removal left the read lock held")
	checks += 2
	waitFor(function()
		local value = map:GetAsync("Failure")
		return failures == 2 and value and value.__krossSyncMemoryRefreshAfter > os.time()
			and sync.IsGetting.Failure == nil
	end,40)
	checks += 1
	waitFor(function()
		return injectedMissing and not sync.LastData.Missing and lostResponse
			and not sync.IsGetting.LostResponse
	end,40)
	assert(map:GetAsync("Missing") == nil, "Renewal recreated a missing, durably removed cache")
	assert(map:GetAsync("LostResponse").memory.marker == "keep", "Lost renewal response discarded temporary state")
	checks += 2
	local deadline = os.clock() + 115
	while os.clock() < deadline do
		for _, key in ipairs({"Idle", "Race", "Failure", "LostResponse", "FalseMemory"}) do
			local value = map:GetAsync(key)
			assert(value, "Active cache expired: " .. key)
			if key == "FalseMemory" then
				assert(value.memory == false, "False temporary state was replaced")
			else
				assert(value.memory.marker == (if key == "Race" then "remote" else "keep"), "Renewal replaced temporary state")
			end
		end
		task.wait(1)
	end
	assert(runtime.metrics.dataGet == reads + 1, "Only a missing cache should require a durable read")
	assert(runtime.metrics.memoryUpdate - updates < 50, "Cache renewal wrote on every poll")
	checks += 2
	assert(unexpectedReads == 0, "SaveData-only state started MemoryStore polling")
	durableOnly.LastData.Raw = nil
	checks += 1
	sync.Map = map
	for key in pairs(sync.LastData) do sync.LastData[key] = nil end
	return {passed = true, checks = checks, durableReads = runtime.metrics.dataGet - reads,
		memoryUpdates = runtime.metrics.memoryUpdate - updates, injectedFailures = failures}
end

