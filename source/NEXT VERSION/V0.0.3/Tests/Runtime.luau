local nativeTask, nativeOs = task, os
local startedAt, epoch = nativeOs.clock(), nativeOs.time()
local scale = 10
local threads = {}
local serverThreads = {}
local stores, maps = {}, {}
local runtime = {
	metrics = {dataGet = 0, dataUpdate = 0, memoryGet = 0, memoryUpdate = 0},
}

local function copy(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, item in pairs(value) do result[key] = copy(item) end
	return result
end

runtime.os = setmetatable({
	clock = function() return (nativeOs.clock() - startedAt) * scale end,
	time = function() return epoch + math.floor((nativeOs.clock() - startedAt) * scale) end,
}, {__index = nativeOs})
runtime.task = {
	wait = function(seconds) return nativeTask.wait((seconds or 0) / scale) * scale end,
	spawn = function(callback, ...)
		local thread = nativeTask.spawn(callback, ...)
		table.insert(threads, thread)
		return thread
	end,
	defer = function(callback, ...)
		local thread = nativeTask.defer(callback, ...)
		table.insert(threads, thread)
		return thread
	end,
	delay = function(seconds, callback, ...)
		local thread = nativeTask.delay(seconds / scale, callback, ...)
		table.insert(threads, thread)
		return thread
	end,
	cancel = nativeTask.cancel,
}

function runtime.stop()
	for _, thread in ipairs(threads) do
		if coroutine.status(thread) ~= "dead" and thread ~= coroutine.running() then pcall(nativeTask.cancel, thread) end
	end
end

function runtime.stopServer(server)
	local result = {cancelled = 0, remaining = 0}
	for _, thread in ipairs(serverThreads[server] or {}) do
		if coroutine.status(thread) ~= "dead" and thread ~= coroutine.running() then
			local ok = pcall(nativeTask.cancel, thread)
			if ok then result.cancelled += 1 end
		end
		if coroutine.status(thread) ~= "dead" then result.remaining += 1 end
	end
	return result
end

function runtime.forServer(server)
	serverThreads[server] = serverThreads[server] or {}
	local serverTask = {wait = runtime.task.wait, cancel = runtime.task.cancel}
	for _, name in ipairs({"spawn", "defer", "delay"}) do
		serverTask[name] = function(...)
			local thread = runtime.task[name](...)
			table.insert(serverThreads[server], thread)
			return thread
		end
	end
	local function getStore(name)
		stores[name] = stores[name] or {values = {}, metadata = {}, users = {}}
		local state = stores[name]
		local function info(key)
			if state.values[key] == nil then return nil end
			return {
				GetMetadata = function() return copy(state.metadata[key] or {}) end,
				GetUserIds = function() return copy(state.users[key] or {}) end,
			}
		end
		return {
			Name = name,
			GetAsync = function(_, key)
				runtime.metrics.dataGet += 1
				return copy(state.values[key]), info(key)
			end,
			SetAsync = function(_, key, value, users, options)
				state.values[key] = copy(value)
				state.metadata[key] = if options then copy(options:GetMetadata()) else {}
				state.users[key] = copy(users or {})
			end,
			UpdateAsync = function(_, key, transform)
				runtime.metrics.dataUpdate += 1
				local value, users, metadata = transform(copy(state.values[key]), info(key))
				if value == nil then return nil end
				state.values[key], state.metadata[key], state.users[key] = copy(value), copy(metadata or {}), copy(users or {})
				return copy(value), info(key)
			end,
			RemoveAsync = function(_, key)
				local old, keyInfo = copy(state.values[key]), info(key)
				state.values[key], state.metadata[key], state.users[key] = nil, nil, nil
				return old, keyInfo
			end,
		}
	end
	local function getMap(name)
		maps[name] = maps[name] or {}
		local state = maps[name]
		local function read(key)
			local entry = state[key]
			if entry and entry.expires <= runtime.os.clock() then state[key] = nil; entry = nil end
			return if entry then copy(entry.value) else nil
		end
		return {
			GetAsync = function(_, key)
				runtime.metrics.memoryGet += 1
				return read(key)
			end,
			SetAsync = function(_, key, value, expiration)
				state[key] = {value = copy(value), expires = runtime.os.clock() + expiration}
			end,
			UpdateAsync = function(_, key, transform, expiration)
				runtime.metrics.memoryUpdate += 1
				local value = transform(read(key))
				if value == nil then return nil end
				state[key] = {value = copy(value), expires = runtime.os.clock() + expiration}
				return copy(value)
			end,
			RemoveAsync = function(_, key)
				local old = read(key)
				state[key] = nil
				return old
			end,
		}
	end
	local services = {
		DataStoreService = {
			GetDataStore = function(_, name) return getStore(name) end,
			GetGlobalDataStore = function() return getStore("Health") end,
			GetRequestBudgetForRequestType = function() return 1_000_000 end,
		},
		MemoryStoreService = {GetHashMap = function(_, name) return getMap(name) end},
		HttpService = game:GetService("HttpService"),
		RunService = {IsStudio = function() return true end},
	}
	return {
		game = {
			JobId = server,
			ReplicatedStorage = game:GetService("ReplicatedStorage"),
			GetService = function(_, name) assert(services[name], "Unexpected real service: " .. name); return services[name] end,
			BindToClose = function() end,
		},
		task = serverTask,
		os = runtime.os,
	}
end

return runtime
