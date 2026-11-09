return function(first, second, runtime)
	local template, memory = {coins = 0}, {marker = ""}
	local reader = first.get("CacheNative",template,memory,60)
	local writer = second.get("CacheNative",template,memory,60)
	reader.MaxRetryTime, writer.MaxRetryTime = 1, 1
	local map = reader.Map
	for _, key in ipairs({"Idle", "FalseMemory", "Removed"}) do
		assert(writer:Get(key,true), "Writer setup failed: " .. key)
		assert(reader:Get(key,true), "Reader setup failed: " .. key)
		assert(writer:SetMemory(key,function(old)
			old.memory = if key == "FalseMemory" then false else {marker = "keep"}
			return old
		end,60,true))
	end
	local durableReads = runtime.metrics.dataGet
	local renewalCommits, lostResponse, removals = 0, false, 0
	local proxy = {
		GetAsync = function(_, ...) return map:GetAsync(...) end,
		UpdateAsync = function(_, key, transform, expiration)
			local updated = map:UpdateAsync(key,transform,expiration)
			if key == "Idle" and updated then
				renewalCommits += 1
				if not lostResponse then
					lostResponse = true
					error("Injected lost response after real cache renewal")
				end
			end
			return updated
		end,
	}
	reader.Map, writer.Map = proxy, proxy
	local started = os.clock()
	local deadline = started + 100
	local maxRemoteAge, observedFalse, removedAt = 0, false, nil
	while os.clock() < deadline do
		local idle = map:GetAsync("Idle")
		local temporary = map:GetAsync("FalseMemory")
		assert(idle and idle.memory.marker == "keep", "Active temporary state expired or changed")
		assert(temporary and temporary.memory == false, "False temporary state expired or changed")
		if reader.LastData.FalseMemory and reader.LastData.FalseMemory.memory == false and not observedFalse then
			observedFalse = true
			maxRemoteAge = os.clock() - started
		end
		if not removedAt and os.clock() - started >= 45 then
			local durable, shared = writer:Remove("Removed")
			if durable and shared then
				removedAt = os.clock()
				removals += 1
			end
		end
		task.wait(5)
	end
	assert(observedFalse, "Reader did not observe remote temporary state")
	assert(lostResponse and renewalCommits >= 2, "Real renewal retry path was not exercised")
	assert(removedAt and not reader.LastData.Removed and not writer.LastData.Removed, "Removed key retained a local cache")
	local removed = map:GetAsync("Removed")
	assert(removed and removed.__krossSyncRemoved, "Removed key was revived")
	assert(runtime.metrics.dataGet == durableReads, "Healthy cache maintenance added DataStore reads")
	local waitUntil = os.clock() + 10
	while (reader.IsGetting.Idle or writer.IsGetting.Idle
		or reader.IsGetting.FalseMemory or writer.IsGetting.FalseMemory) and os.clock() < waitUntil do
		task.wait(0.1)
	end
	assert(not reader.IsGetting.Idle and not writer.IsGetting.Idle
		and not reader.IsGetting.FalseMemory and not writer.IsGetting.FalseMemory, "Cache maintenance left a read lock held")
	reader.Map, writer.Map = map, map
	return {passed = true, checks = 4, duration = os.clock() - started,
		idleTTL = 60, renewalCommits = renewalCommits, lostRenewalResponse = lostResponse,
		additionalDurableReads = runtime.metrics.dataGet - durableReads,
		remoteObservedAfter = maxRemoteAge, removals = removals,
		twoLiveServers = false, realStorage = true}
end

