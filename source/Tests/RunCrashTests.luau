return function(root)
	assert(game:GetService("RunService"):IsStudio() and not game:GetService("RunService"):IsRunning(), "Run crash-model tests in Studio Edit mode")
	local holder = Instance.new("Folder")
	holder.Name = "__KrossSyncV003Crash_" .. game:GetService("HttpService"):GenerateGUID(false):sub(1, 8)
	local control = Instance.new("ModuleScript")
	control.Name, control.Source, control.Parent = "Control", "return {}", holder
	local runtimeModule = root.Tests.Runtime:Clone()
	runtimeModule.Parent = holder
	local fixture = root.Tests.CrashTest:Clone()
	fixture.Parent = holder
	local prefix = 'local environment = require(script.Parent.Runtime).forServer(script:GetAttribute("MockServer"))\nlocal game, task, os = environment.game, environment.task, environment.os\n'
	for _, name in ipairs({"A", "B", "C"}) do
		local module = root.KrossSync:Clone()
		module.Name = name
		module:SetAttribute("MockServer", name)
		module.Source = prefix .. root.KrossSync.Source
		module.Parent = holder
	end
	holder.Parent = game:GetService("ServerStorage")
	local runtime = require(runtimeModule)
	holder:SetAttribute("Status", "Running")
	require(control).thread = task.spawn(function()
		local ok, result = xpcall(function()
			return require(fixture)(require(holder.A), require(holder.B), require(holder.C), runtime)
		end, debug.traceback)
		runtime.stop()
		local passed = ok and result.passed == true
		local output = Instance.new("StringValue")
		output.Name = "Result"
		output.Value = game:GetService("HttpService"):JSONEncode({passed = passed, runnerCompleted = ok, result = result, metrics = runtime.metrics, clockScale = 10, realServerCrash = false})
		output.Parent = holder
		holder:SetAttribute("Status", if passed then "Passed" else "Failed")
	end)
	return holder
end
