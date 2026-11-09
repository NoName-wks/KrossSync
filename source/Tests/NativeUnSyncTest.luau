return function(first, second, runtime)
	local template, memory = {coins = 0}, {marker = ""}
	local reader = first.get("UnSyncNative", template, memory, 600)
	local writer = second.get("UnSyncNative", template, memory, 600)
	reader.MaxRetryTime, writer.MaxRetryTime = 1, 1
	task.wait()
	runtime.stop()
	local options = Instance.new("DataStoreGetOptions")
	options.UseCache = false

	local key = "Latest"
	assert(writer:Get(key, true), "Writer setup failed")
	local durable, shared = writer:Set(key, function(data)
		data.coins = 10
		return data
	end, 600, true)
	assert(durable and shared, "Initial Set failed")
	assert(reader:Get(key, true), "Reader setup failed")
	assert(writer:SaveMemory(key, function(current)
		current.data.coins = 20
		current.memory.marker = "temporary"
		return current
	end, 600, true), "Shared update failed")
	assert(reader.LastData[key].data.coins == 10, "Reader must still hold stale data")
	local updates, reads = runtime.metrics.dataUpdate, runtime.metrics.memoryGet
	assert(reader:UnSync(key), "UnSync failed while another server ID remained")
	local finalSaveRequests = runtime.metrics.dataUpdate - updates
	local separateMemoryReads = runtime.metrics.memoryGet - reads
	assert(finalSaveRequests == 1 and separateMemoryReads == 0, "Unexpected UnSync request count")
	local saved = reader.Store:GetAsync(key, options)
	assert(saved.coins == 20 and saved.data == nil and saved.memory == nil, "UnSync did not persist only the latest raw data")
	assert(reader.LastData[key] == nil, "UnSync did not release local data")
	assert(table.find(reader.Map:GetAsync(key).onlineServers, "B"), "Peer ID should remain")
	reader.Map:RemoveAsync(key)
	local restored = reader:Get(key, true)
	assert(restored and restored.data.coins == 20, "Cache loss did not recover the final saved data")
	assert(restored.memory.marker == "", "Temporary memory was persisted")

	key = "NewerDurable"
	assert(writer:Get(key, true), "Newer durable writer setup failed")
	assert(reader:Get(key, true), "Newer durable reader setup failed")
	local setMemory = writer.SetMemory
	writer.SetMemory = function() return false end
	durable, shared = writer:Set(key, function(data)
		data.coins = 30
		return data
	end, 600, true)
	writer.SetMemory = setMemory
	runtime.stop()
	assert(durable and not shared, "Setup must leave a newer durable version unpublished")
	assert(reader:UnSync(key), "Superseded shared data prevented UnSync")
	local newer = reader.Store:GetAsync(key, options)
	assert(newer.coins == 30, "Old shared data overwrote the newer durable value")
	assert(reader.LastData[key] == nil, "Superseded shared data retained a subscription")
	return {
		passed = true,
		checks = 2,
		finalDurableCoins = saved.coins,
		afterCacheLossCoins = restored.data.coins,
		newerDurableCoins = newer.coins,
		finalSaveRequests = finalSaveRequests,
		separateMemoryReads = separateMemoryReads,
	}
end
