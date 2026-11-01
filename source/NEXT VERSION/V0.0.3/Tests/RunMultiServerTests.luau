return function(root)
	assert(game:GetService("RunService"):IsStudio() and not game:GetService("RunService"):IsRunning(), "Run the multi-server model in Studio Edit mode")
	local holder = Instance.new("Folder")
	holder.Name = "__KrossSyncV003MultiModel_" .. game:GetService("HttpService"):GenerateGUID(false):sub(1, 8)
	local control = Instance.new("ModuleScript")
	control.Name, control.Source, control.Parent = "Control", "return {}", holder
	local runtimeModule = root.Tests.Runtime:Clone()
	runtimeModule.Parent = holder
	local runId = "Model_" .. game:GetService("HttpService"):GenerateGUID(false):sub(1, 8)
	local runners = {}
	local prefix = 'local environment = require(script.Parent.Parent.Runtime).forServer(script:GetAttribute("MockServer"))\nlocal game, task, os = environment.game, environment.task, environment.os\n'
	for _, server in ipairs({"A", "B"}) do
		local scope = Instance.new("Folder")
		scope.Name, scope.Parent = server, holder
		local core = Instance.new("ModuleScript")
		core.Name, core.Source, core.Parent = "KrossSync", prefix .. root.KrossSync.Source, scope
		core:SetAttribute("MockServer", server)
		local fixture = Instance.new("ModuleScript")
		fixture.Name, fixture.Parent = "Fixture", scope
		fixture:SetAttribute("MockServer", server)
		fixture:SetAttribute("RunTests", true)
		fixture:SetAttribute("RunId", runId)
		fixture.Source = prefix .. [[
local storageGame = game
game = setmetatable({PlaceId = 0, PlaceVersion = 0, GetService = function(_, name)
	if name == "RunService" then return {IsStudio = function() return false end} end
	return storageGame:GetService(name)
end}, {__index = storageGame})
]] .. root.MultiServerTest.Source .. "\nreturn true\n"
		table.insert(runners, fixture)
	end
	holder.Parent = game:GetService("ServerStorage")
	holder:SetAttribute("Status", "Running")
	local runtime = require(runtimeModule)
	require(control).thread = task.spawn(function()
		local threads, finished, failures = {}, 0, {}
		for _, fixture in ipairs(runners) do
			table.insert(threads, task.spawn(function()
				local ok, err = xpcall(function() assert(require(fixture)) end, debug.traceback)
				if not ok then table.insert(failures, err) end
				finished += 1
			end))
		end
		local deadline = os.clock() + 60
		while finished < #runners and #failures == 0 and os.clock() < deadline do task.wait(0.1) end
		for _, thread in ipairs(threads) do
			if coroutine.status(thread) ~= "dead" then task.cancel(thread) end
		end
		runtime.stop()
		local store = runtime.forServer("Verifier").game:GetService("DataStoreService"):GetDataStore("KrossSync_V003_MULTI_RESULTS")
		local results = store:GetAsync(runId)
		local passed = finished == #runners and #failures == 0
		for _, role in ipairs({"first", "second"}) do
			local result = results and results[role]
			passed = passed and result ~= nil and result.passed == true and result.complete == true
				and result.checks.concurrentSet == true and result.checks.concurrentMemory == true
				and result.checks.unSyncLatestData == true and result.checks.removalRace == true
		end
		local output = Instance.new("StringValue")
		output.Name, output.Value = "Result", game:GetService("HttpService"):JSONEncode({
			passed = passed, results = results, failures = failures, finished = finished,
			metrics = runtime.metrics, clockScale = 10, realStorage = false, twoLiveServers = false,
		})
		output.Parent = holder
		holder:SetAttribute("Status", if passed then "Passed" else "Failed")
	end)
	return holder
end
