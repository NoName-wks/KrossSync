return function(first, second, runtime)
	local template, memory = {coins = 0}, {marker = ""}
	local reader = first.get("UnSyncLatest", template, memory, 600)
	local writer = second.get("UnSyncLatest", template, memory, 600)
	reader.MaxRetryTime, writer.MaxRetryTime = 1, 1
	local function setup(key)
		assert(reader:Get(key, true), "Reader setup failed")
		assert(writer:Get(key, true), "Writer setup failed")
		assert(writer:SaveMemory(key, function(current)
			current.data.coins = 20
			current.memory.marker = "temporary"
			return current
		end, 600, true), "Shared update failed")
		assert(reader.LastData[key].data.coins == 0, "Reader must still have stale local data")
	end
	setup("Latest")
	local reads, updates = runtime.metrics.memoryGet, runtime.metrics.dataUpdate
	assert(reader:UnSync("Latest"), "UnSync failed while a peer remains")
	assert(runtime.metrics.memoryGet == reads, "UnSync added a separate memory read")
	assert(runtime.metrics.dataUpdate == updates + 1, "UnSync must request one durable update")
	local saved = reader.Store:GetAsync("Latest")
	assert(saved.coins == 20 and saved.data == nil and saved.memory == nil, "UnSync must persist only the latest raw data")
	assert(reader.LastData.Latest == nil, "Successful UnSync retained local data")
	assert(table.find(reader.Map:GetAsync("Latest").onlineServers, "B"), "UnSync removed the peer")

	setup("MemoryFailure")
	local map = reader.Map
	reader.Map = {UpdateAsync = function() error("Injected UnSync memory failure") end}
	updates = runtime.metrics.dataUpdate
	assert(reader:UnSync("MemoryFailure") == false, "Memory failure must fail UnSync")
	assert(runtime.metrics.dataUpdate == updates, "Memory failure saved a stale local snapshot")
	assert(reader.LastData.MemoryFailure, "Memory failure discarded retry state")
	reader.Map = map
	assert(reader:UnSync("MemoryFailure"), "Memory failure retry failed")
	assert(reader.Store:GetAsync("MemoryFailure").coins == 20, "Retry did not use shared data")

	setup("DurableFailure")
	local store = reader.Store
	reader.Store = {Name = store.Name, UpdateAsync = function() error("Injected UnSync durable failure") end}
	assert(reader:UnSync("DurableFailure") == false, "Durable failure must fail UnSync")
	assert(reader.LastData.DurableFailure.data.coins == 20, "Durable failure discarded the latest retry snapshot")
	reader.Store = store
	assert(reader:UnSync("DurableFailure"), "Durable failure retry failed")
	assert(store:GetAsync("DurableFailure").coins == 20, "Durable retry saved stale data")

	setup("NewerDurable")
	local setMemory = writer.SetMemory
	writer.SetMemory = function() return false end
	local committed, published = writer:Set("NewerDurable", function(data)
		data.coins = 30
		return data
	end, 600, true)
	writer.SetMemory = setMemory
	assert(committed and not published, "Newer durable setup must leave publication pending")
	assert(reader:UnSync("NewerDurable"), "A superseded snapshot must not block UnSync")
	assert(store:GetAsync("NewerDurable").coins == 30, "UnSync overwrote newer durable data")
	assert(reader.LastData.NewerDurable == nil, "Superseded snapshot retained a subscription")
	assert(writer.PendingMemoryPublish.NewerDurable, "UnSync cancelled pending publication")

	setup("Removed")
	local durable, shared = writer:Remove("Removed")
	assert(durable and shared, "Removal setup failed")
	updates = runtime.metrics.dataUpdate
	assert(reader:UnSync("Removed"), "Removed key cleanup failed")
	assert(reader.LastData.Removed == nil, "Removed key retained a local snapshot")
	assert(runtime.metrics.dataUpdate == updates, "UnSync attempted to persist a shared tombstone")
	return {passed = true, checks = 5, separateMemoryReads = 0, latestCoins = saved.coins}
end
