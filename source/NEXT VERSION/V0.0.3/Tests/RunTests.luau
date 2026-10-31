return function(root)
	assert(game:GetService("RunService"):IsStudio() and not game:GetService("RunService"):IsRunning(), "Run from Studio Command Bar or MCP in Edit mode")
	local holder = Instance.new("Folder")
	holder.Name = "__KrossSyncV003Tests_" .. game:GetService("HttpService"):GenerateGUID(false):sub(1, 8)
	holder:SetAttribute("Status", "Running")
	local control = Instance.new("ModuleScript")
	control.Name, control.Source, control.Parent = "Control", "return {}", holder
	holder.Parent = game:GetService("ServerStorage")
	local results = {}
	local prefix = 'local environment = require(script.Parent.Runtime).forServer(script:GetAttribute("MockServer"))\nlocal game, task, os = environment.game, environment.task, environment.os\n'
	local function phase(name, callback)
		local scope = Instance.new("Folder")
		scope.Name, scope.Parent = name, holder
		local mock = root.Tests.Runtime:Clone()
		mock.Parent = scope
		local runtime = require(mock)
		local function core(server)
			local module = Instance.new("ModuleScript")
			module.Name = server
			module:SetAttribute("MockServer", server)
			module.Source = prefix .. root.KrossSync.Source
			module.Parent = scope
			return require(module)
		end
		local ok, result = xpcall(function() return callback(scope, runtime, core) end, debug.traceback)
		runtime.stop()
		table.insert(results, {name = name, passed = ok, result = result, metrics = runtime.metrics})
		assert(ok, result)
	end
	require(control).thread = task.spawn(function()
		local ok, err = xpcall(function()
			phase("UnSync", function(scope, runtime, core)
				local fixture = root.Tests.UnSyncTest:Clone()
				fixture.Parent = scope
				return require(fixture)(core("A"), core("B"), runtime)
			end)
			phase("Storage", function(scope, runtime, core)
				local fixture = root.Tests.StorageTest:Clone()
				fixture.Parent = scope
				return require(fixture)(core("A"), core("B"), runtime)
			end)
			phase("Regression", function(scope, _, core)
				core("KrossSync")
				local tests = Instance.new("ModuleScript")
				tests.Name = "Regression"
				tests:SetAttribute("MockServer", "KrossSync")
				tests:SetAttribute("RunTests", true)
				tests.Source = prefix .. [[
local function print(...)
	local values = table.pack(...)
	if values[1] == "[KrossSync Regression]" and type(values[2]) == "string" then
		script.Parent.Parent:SetAttribute("Step", values[2])
		if values[2]:sub(1,5) == "PASS " then
			script.Parent:SetAttribute("PassedCount", (script.Parent:GetAttribute("PassedCount") or 0) + 1)
		end
	end
end
]] .. root.Script.Source .. "\nreturn true\n"
				tests.Parent = scope
				assert(require(tests))
				return {checks = scope:GetAttribute("PassedCount")}
			end)
		end, debug.traceback)
		local output = Instance.new("StringValue")
		output.Name = "Result"
		output.Value = game:GetService("HttpService"):JSONEncode({passed = ok, error = if ok then nil else err, phases = results})
		output.Parent = holder
		holder:SetAttribute("Status", if ok then "Passed" else "Failed")
	end)
	return holder
end
