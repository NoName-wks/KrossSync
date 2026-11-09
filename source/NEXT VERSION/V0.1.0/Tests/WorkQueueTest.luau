return function(service, runtime)
	local task, os = runtime.task, runtime.os
	local sync = service.get("WorkQueue", {coins = 0}, {marker = ""}, 600)
	sync.MaxRetryTime = 1
	local map, store = sync.Map, sync.Store
	local function waitFor(predicate)
		local deadline = os.clock() + 20
		while not predicate() and os.clock() < deadline do task.wait(0.05) end
		assert(predicate(), "Timed out waiting for queued work")
	end
	local function save(amount)
		return function(old)
			old.data.coins += amount
			return old
		end
	end
	local function set(amount)
		return function(old)
			old.coins += amount
			return old
		end
	end
	local function gateMemory(key)
		local state = {entered = false, released = false}
		sync.Map = {
			GetAsync = function(_, ...) return map:GetAsync(...) end,
			UpdateAsync = function(_, target, ...)
				if target == key and not state.entered then
					state.entered = true
					while not state.released do task.wait(0.05) end
				end
				return map:UpdateAsync(target,...)
			end,
		}
		return state
	end

	assert(sync:Get("Ordered",true))
	local gate = gateMemory("Ordered")
	local a = sync:Save("Ordered",save(1),nil,true,false)
	waitFor(function() return gate.entered end)
	local updates = runtime.metrics.dataUpdate
	local b = sync:Save("Ordered",function(old)
		old.data.coins *= 2
		old.memory.marker = "kept"
		return old
	end,nil,true,false)
	local c = sync:Set("Ordered",set(3),nil,true,false)
	assert(sync:Get("Ordered",true) == false, "Get must not queue")
	assert(sync:Set("Independent",{data = {coins = 9}},nil,true), "Other keys must keep running")
	updates = runtime.metrics.dataUpdate
	gate.released = true
	assert(a:Await() and b:Await())
	local durable, shared = c:Await()
	assert(durable and shared and runtime.metrics.dataUpdate - updates == 1, "Save prefix should use one durable Set")
	local value = map:GetAsync("Ordered")
	assert(value.data.coins == 5 and value.memory.marker == "kept", "Expected 3(2(1(old))) with temporary state")
	assert(store:GetAsync("Ordered").coins == 5)
	sync.Map = map

	assert(sync:Get("SaveThenSet",true))
	gate = gateMemory("SaveThenSet")
	a = sync:Save("SaveThenSet",save(7),nil,true,false)
	waitFor(function() return gate.entered end)
	b = sync:Set("SaveThenSet",set(8),nil,true,false)
	gate.released = true
	assert(a:Await() and b:Await())
	assert(store:GetAsync("SaveThenSet").coins == 15, "Queued Set must see the preceding Save without another Save pending")
	sync.Map = map

	assert(sync:Get("Delete",true))
	gate = gateMemory("Delete")
	a = sync:Save("Delete",save(1),nil,true,false)
	waitFor(function() return gate.entered end)
	b = sync:Save("Delete",function() error("Canceled Save ran") end,nil,true,false)
	c = sync:Set("Delete",function() error("Canceled Set ran") end,nil,true,false)
	local remove = sync:Remove("Delete",false)
	gate.released = true
	assert(a:Await() and remove:Await())
	local ok, remaining, reason = b:Await()
	assert(ok == false and remaining == nil and reason == "removed")
	local okSet, _, _, setReason = c:Await()
	assert(okSet == false and setReason == "removed")
	assert(store:GetAsync("Delete").__krossSyncRemoved)
	sync.Map = map

	assert(sync:Get("Retry",true))
	local failures = 0
	sync.Map = {
		GetAsync = function(_, ...) return map:GetAsync(...) end,
		UpdateAsync = function(_, key, ...)
			if key == "Retry" then failures += 1; error("Injected failure before transform") end
			return map:UpdateAsync(key,...)
		end,
	}
	a = sync:Save("Retry",save(1),nil,true,false)
	waitFor(function() return failures == 1 end)
	b = sync:Save("Retry",save(2),nil,true,false)
	ok, remaining = a:Await()
	local bOK, bRemaining = b:Await()
	assert(ok == false and bOK == false and failures == 2, "Known failure must retry one combined batch")
	assert(remaining == bRemaining and remaining({data = {coins = 0}}).data.coins == 3, "Return the uncommitted composition")
	sync.Map = map

	assert(sync:Get("Uncertain",true))
	local commits = 0
	sync.Map = {
		GetAsync = function(_, ...) return map:GetAsync(...) end,
		UpdateAsync = function(_, key, ...)
			local result = map:UpdateAsync(key,...)
			if key == "Uncertain" then commits += 1; error("Injected lost commit response") end
			return result
		end,
	}
	ok, remaining, reason = sync:Save("Uncertain",save(1),nil,true)
	assert(ok == false and remaining == nil and reason == "uncertain" and commits == 1, "Uncertain writes must not replay")
	assert(map:GetAsync("Uncertain").data.coins == 1)
	sync.Map = map

	assert(sync:Get("Publish",true))
	local originalPublish = sync.SetMemory
	local blocked, release = false, false
	sync.SetMemory = function(self, key, ...)
		if not blocked and key == "Publish" then
			blocked = true
			while not release do task.wait(0.05) end
			return false
		end
		return originalPublish(self,key,...)
	end
	a = sync:Set("Publish",set(10),nil,true,false)
	waitFor(function() return blocked end)
	b = sync:Save("Publish",save(5),nil,true,false)
	local reads = runtime.metrics.dataGet
	release = true
	durable, shared = a:Await()
	assert(durable and not shared, "Fixture must lose the initial publication")
	assert(b:Await() and map:GetAsync("Publish").data.coins == 15, "Queued Save must start from the durable Set result")
	assert(runtime.metrics.dataGet == reads, "Pending durable value should be reused without a read")
	sync.SetMemory = originalPublish

	sync.WaitForWorkResult = false
	a = sync:Set("Modes", {data = {coins = 1}},nil,true)
	assert(type(a) == "table" and a:Await(), "Instance default should return a receipt")
	assert(sync:Set("Modes",{data = {coins = 2}},nil,true,true) == true, "Call must override the instance default")
	sync.WaitForWorkResult = true
	assert(next(sync.works) == nil, "Completed queues must be released")
	store:UpdateAsync("LegacyMetadata",function()
		return {coins = 4},{123},{__krossSyncRevision = 88,custom = "keep"}
	end)
	local restored = sync:Get("LegacyMetadata",true)
	assert(restored.dataRevision == 0, "Legacy revision must be ignored")
	assert(sync:Set("LegacyMetadata",set(1),nil,true))
	local saved, info = store:GetAsync("LegacyMetadata")
	local metadata = info:GetMetadata()
	assert(saved.coins == 5 and metadata.__ksRev == 1 and metadata.__ksOp)
	assert(metadata.custom == "keep" and info:GetUserIds()[1] == 123)
	return {passed = true, checks = 8}
end

