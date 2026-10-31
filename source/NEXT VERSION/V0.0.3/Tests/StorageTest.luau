return function(first, second, runtime)
	local task, os = runtime.task, runtime.os
	local template, memory = {coins = 0}, {marker = ""}
	local reader = first.get("SlowKeyTest", template, memory, 600)
	local writer = second.get("SlowKeyTest", template, memory, 600)
	reader.MaxRetryTime, writer.MaxRetryTime = 1, 1
	for _, key in ipairs({"Slow", "Healthy"}) do
		assert(writer:Get(key, true), "Writer setup failed")
		assert(reader:Get(key, true), "Reader setup failed")
	end
	local map = reader.Map
	local slowStarted, slowFinished, healthyReads = false, false, 0
	reader.Map = {
		GetAsync = function(_, key)
			if key == "Slow" and not slowStarted then
				slowStarted = true
				task.wait(45)
			end
			local value = map:GetAsync(key)
			if key == "Healthy" then healthyReads += 1 end
			if key == "Slow" then slowFinished = true end
			return value
		end,
		UpdateAsync = function(_, ...) return map:UpdateAsync(...) end,
	}
	local deadline = os.clock() + 25
	while (not slowStarted or healthyReads == 0) and os.clock() < deadline do task.wait(0.1) end
	assert(slowStarted, "Slow request was not exercised")
	assert(healthyReads > 0, "Initial healthy read did not finish")
	task.wait(2)
	local durableReads, writtenAt = runtime.metrics.dataGet, os.clock()
	assert(writer:SetMemory("Healthy", function(current)
		current.memory.marker = "latest"
		return current
	end, 600, true), "Healthy write failed")
	deadline = os.clock() + 23
	while reader.LastData.Healthy.memory.marker ~= "latest" and os.clock() < deadline do task.wait(0.1) end
	local observed = reader.LastData.Healthy.memory.marker == "latest"
	assert(observed, "One slow key blocked healthy-key polling")
	assert(not slowFinished, "Healthy refresh waited until the slow request finished")
	assert(runtime.metrics.dataGet == durableReads, "Healthy cache polling added durable reads")
	assert(healthyReads <= 3, "Healthy polling exceeded the 15-second cadence")
	local observedAfter = os.clock() - writtenAt
	reader.Map = map
	local getMemory, threw = reader.GetMemory, false
	reader.GetMemory = function(self, key, force)
		if key == "Healthy" and not threw then
			threw = true
			error("Injected unexpected poll exception")
		end
		return getMemory(self, key, force)
	end
	assert(writer:SetMemory("Healthy", function(current)
		current.memory.marker = "after-error"
		return current
	end, 600, true))
	deadline = os.clock() + 40
	while reader.LastData.Healthy.memory.marker ~= "after-error" and os.clock() < deadline do task.wait(0.1) end
	assert(threw, "Unexpected poll exception was not exercised")
	assert(reader.LastData.Healthy.memory.marker == "after-error", "Automatic polling did not recover after an exception")
	assert(runtime.metrics.dataGet == durableReads, "Exception recovery added durable reads")
	reader.GetMemory = getMemory
	return {
		passed = true,
		checks = 2,
		slowRequestPendingAtObservation = true,
		healthyReads = healthyReads,
		observedAfter = observedAfter,
		exceptionRecovered = threw,
		durableReads = runtime.metrics.dataGet - durableReads,
	}
end
