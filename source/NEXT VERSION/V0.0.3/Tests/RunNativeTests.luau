return function(root, fixtureName)
	assert(game:GetService("RunService"):IsStudio() and not game:GetService("RunService"):IsRunning(), "Run native API tests from Command Bar or MCP in Edit mode")
	local holder = Instance.new("Folder")
	holder.Name = "__KrossSyncV003Native_" .. game:GetService("HttpService"):GenerateGUID(false):sub(1, 8)
	local control = Instance.new("ModuleScript")
	control.Name, control.Source, control.Parent = "Control", "return {}", holder
	local runtimeModule = root.Tests.Runtime:Clone()
	runtimeModule.Source = runtimeModule.Source:gsub("local scale = 10", "local scale = 1", 1)
	runtimeModule.Parent = holder
	local backend = root.Tests.NativeRuntime:Clone()
	backend.Name, backend.Parent = "Backend", holder
	fixtureName = fixtureName or "StorageTest"
	local fixture = root.Tests[fixtureName]:Clone()
	fixture.Parent = holder
	local prefix = 'local environment = require(script.Parent.Backend).forServer(script:GetAttribute("MockServer"))\nlocal game, task, os = environment.game, environment.task, environment.os\n'
	for _, name in ipairs({"A", "B"}) do
		local module = root.KrossSync:Clone()
		module.Name = name
		module:SetAttribute("MockServer", name)
		module.Source = prefix .. root.KrossSync.Source
		module.Parent = holder
	end
	holder.Parent = game:GetService("ServerStorage")
	local runtime = require(backend)
	holder:SetAttribute("Namespace", runtime.namespace)
	holder:SetAttribute("Status", "Running")
	require(control).thread = task.spawn(function()
		local started = os.clock()
		local ok, result = xpcall(function()
			return require(fixture)(require(holder.A), require(holder.B), runtime)
		end, debug.traceback)
		runtime.stop()
		local cleanup = runtime.cleanup()
		local output = Instance.new("StringValue")
		output.Name = "Result"
		output.Value = game:GetService("HttpService"):JSONEncode({
			passed = ok and #cleanup.errors == 0,
			fixture = fixtureName,
			result = result,
			cleanup = cleanup,
			metrics = runtime.metrics,
			seconds = os.clock() - started,
			namespace = runtime.namespace,
			realStorage = true,
			realServerCrash = false,
			clockScale = 1,
		})
		output.Parent = holder
		holder:SetAttribute("Status", if ok and #cleanup.errors == 0 then "Passed" else "Failed")
	end)
	return holder
end
