return function(first, crashed, restarted, runtime)
	local template, memory = {coins = 0}, {marker = ""}
	local survivor = first.get("CrashMembership", template, memory, 600)
	local peer = crashed.get("CrashMembership", template, memory, 600)
	local key = "Shared"
	assert(survivor:Get(key, true), "Survivor setup failed")
	assert(peer:Get(key, true), "Peer setup failed")
	local durable, shared = survivor:Set(key, function(data) data.coins = 10; return data end, 600, true)
	assert(durable and shared, "Initial durable write failed")
	runtime.task.wait(1)
	local stopped = runtime.stopServer("B")
	assert(stopped.cancelled > 0 and stopped.remaining == 0, "Peer workers did not stop")
	assert(survivor:Save(key, function(current)
		current.data.coins = 20
		return current
	end, 600, true), "Temporary data write failed")
	local cached = survivor.Map:GetAsync(key)
	assert(cached.data.coins == 20, "Temporary change was not committed")
	assert(survivor.Store:GetAsync(key).coins == 10, "Save unexpectedly persisted before its interval")
	local updatesBefore = runtime.metrics.dataUpdate
	assert(survivor:UnSync(key), "Survivor could not close")
	local finalSaveRequests = runtime.metrics.dataUpdate - updatesBefore
	local remaining = survivor.Map:GetAsync(key)
	local deadPeerRetained = table.find(remaining.onlineServers, "B") ~= nil
	local finalDurable = survivor.Store:GetAsync(key)
	survivor.Map:RemoveAsync(key)
	local reader = restarted.get("CrashMembership", template, memory, 600)
	local restored = reader:Get(key, true)
	assert(restored, "Restarted reader could not load durable data")
	return {
		passed = finalDurable.coins == 20 and restored.data.coins == 20,
		checks = 1,
		expectedCoins = 20,
		finalDurableCoins = finalDurable.coins,
		afterCacheLossCoins = restored.data.coins,
		deadPeerRetained = deadPeerRetained,
		finalSaveRequests = finalSaveRequests,
		durableSetPreserved = finalDurable.coins >= 10,
		stoppedWorkers = stopped.cancelled,
		realServerCrash = false,
	}
end
