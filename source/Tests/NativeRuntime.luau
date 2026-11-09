local runtime = require(script.Parent.Runtime)
local dataService = game:GetService("DataStoreService")
local memoryService = game:GetService("MemoryStoreService")
local resources = {}
runtime.namespace = "KV3Native_" .. game:GetService("HttpService"):GenerateGUID(false):gsub("-", ""):sub(1, 12)

local function backend(name, memory)
	local actualName = runtime.namespace .. "_" .. name
	assert(#actualName <= 50, "Test backend name is too long")
	local identifier = (if memory then "M:" else "D:") .. actualName
	if resources[identifier] then return resources[identifier].proxy end
	local target = if memory then memoryService:GetHashMap(actualName) else dataService:GetDataStore(actualName)
	local resource = {target = target, name = actualName, memory = memory, keys = {}, proxy = {Name = actualName}}
	resources[identifier] = resource
	local metrics = if memory then {
		GetAsync = "memoryGet", UpdateAsync = "memoryUpdate", SetAsync = "memorySet", RemoveAsync = "memoryRemove",
	} else {
		GetAsync = "dataGet", UpdateAsync = "dataUpdate", SetAsync = "dataSet", RemoveAsync = "dataRemove",
	}
	for method, metric in pairs(metrics) do
		resource.proxy[method] = function(_, key, ...)
			runtime.metrics[metric] = (runtime.metrics[metric] or 0) + 1
			if method ~= "GetAsync" then resource.keys[key] = true end
			return target[method](target, key, ...)
		end
	end
	return resource.proxy
end

function runtime.cleanup()
	local result = {removed = 0, verified = 0, errors = {}}
	local options = Instance.new("DataStoreGetOptions")
	options.UseCache = false
	for _, resource in pairs(resources) do
		assert(resource.name:sub(1, #runtime.namespace + 1) == runtime.namespace .. "_", "Unsafe cleanup namespace")
		for key in pairs(resource.keys) do
			local success, err = pcall(function()
				resource.target:RemoveAsync(key)
				result.removed += 1
				local value
				if resource.memory then value = resource.target:GetAsync(key)
				else value = resource.target:GetAsync(key, options) end
				assert(value == nil, "Test key still exists after cleanup")
				result.verified += 1
			end)
			if success then resource.keys[key] = nil
			else table.insert(result.errors, {store = resource.name, key = key, error = tostring(err)}) end
		end
	end
	return result
end

function runtime.forServer(server)
	local services = {
		DataStoreService = {
			GetDataStore = function(_, name) return backend(name, false) end,
			GetGlobalDataStore = function() return backend("Health", false) end,
			GetRequestBudgetForRequestType = function(_, kind) return dataService:GetRequestBudgetForRequestType(kind) end,
		},
		MemoryStoreService = {GetHashMap = function(_, name) return backend(name, true) end},
		HttpService = game:GetService("HttpService"),
		RunService = {IsStudio = function() return false end},
	}
	return {
		game = {
			JobId = server,
			ReplicatedStorage = game:GetService("ReplicatedStorage"),
			GetService = function(_, name) assert(services[name], "Unexpected service: " .. name); return services[name] end,
			BindToClose = function() end,
		},
		task = runtime.task,
		os = runtime.os,
	}
end

return runtime
