local M = {}

local DEFAULT_HOST = "127.0.0.1"
local DEFAULT_PORT = 8081
local DEFAULT_ADAPTER = "pwa-node"

local DEFAULT_SKIP_FILES = {
	"<node_internals>/**",
	"node_modules/**",
	"**/node_modules/undici/**",
	"**/node_modules/typescript/**",
	"**/node_modules/@expo/**",
	"**/*.bundle.js",
	"**/*.min.js",
}

local DEFAULT_RESOLVE_SOURCE_MAP_LOCATIONS = {
	"**",
	"!**/node_modules/!(expo)/**",
}

local pending_thread_stop = setmetatable({}, { __mode = "k" })
local active_proxies = {}
local next_proxy_id = 0
local hooks_registered = false

local PROXY_LOG_PREFIX = {
	stdout = "dap-react-native proxy stdout: ",
	stderr = "dap-react-native proxy stderr: ",
}

local function fail(message)
	error("dap-react-native: " .. message, 0)
end

local function non_empty(value)
	return type(value) == "string" and value ~= ""
end

local function as_lower(value)
	return tostring(value or ""):lower()
end

local function dirname(path)
	return path:match("^(.*)/[^/]*$") or "."
end

local function join_path(...)
	local path = table.concat({ ... }, "/")
	local normalized = path:gsub("/+", "/")
	return normalized
end

local function plugin_root()
	local source = debug.getinfo(1, "S").source
	if source:sub(1, 1) == "@" then
		source = source:sub(2)
	end

	return dirname(dirname(dirname(source)))
end

local function default_proxy_script_path()
	return join_path(plugin_root(), "scripts", "react-native-hermes-cdp-proxy.js")
end

local function default_setup_options()
	return {
		adapter = DEFAULT_ADAPTER,
		proxy = {
			host = "127.0.0.1",
			node_command = "node",
			script_path = default_proxy_script_path(),
			log = false,
			start_timeout_ms = 5000,
		},
	}
end

local function normalize_options(opts)
	return vim.tbl_deep_extend("force", default_setup_options(), opts or {})
end

local function command_result(cmd)
	if vim.system then
		return vim.system(cmd, { text = true }):wait()
	end

	local output = vim.fn.system(cmd)
	return {
		code = vim.v.shell_error,
		stdout = output,
		stderr = output,
	}
end

local function get_option(config, opts, ...)
	for _, key in ipairs({ ... }) do
		local value = config and config[key]
		if (type(value) == "string" or type(value) == "number") and value ~= "" then
			return value
		end
	end

	for _, key in ipairs({ ... }) do
		local value = opts and opts[key]
		if (type(value) == "string" or type(value) == "number") and value ~= "" then
			return value
		end
	end
end

local function metro_endpoint(config)
	local env_host = os.getenv("REACT_NATIVE_PACKAGER_HOSTNAME")
	local env_port = os.getenv("RCT_METRO_PORT")

	local host = get_option(config, nil, "address", "host") or env_host or DEFAULT_HOST
	local port = get_option(config, nil, "port") or env_port or DEFAULT_PORT

	return tostring(host), tostring(port)
end

local function http_origin(host, port)
	if host:find(":", 1, true) and not host:match("^%[.*%]$") then
		host = "[" .. host .. "]"
	end

	return ("http://%s:%s"):format(host, port)
end

local function http_get(url)
	local result = command_result({ "curl", "-fsSL", url })

	if result.code == 0 then
		return result.stdout
	end

	fail(
		("Could not reach Metro at %s. Start Metro for the app or configure address/port. %s"):format(
			url,
			vim.trim(result.stderr or "")
		)
	)
end

local function target_score(target)
	local title = as_lower(target.title)
	local description = as_lower(target.description)
	local vm = tostring(target.vm or "")
	local ws = tostring(target.webSocketDebuggerUrl or "")
	local score = 0

	if vm == "Hermes" then
		score = score + 100
	end
	if title:find("hermes", 1, true) or description:find("hermes", 1, true) then
		score = score + 40
	end
	if ws:find("/inspector/debug", 1, true) then
		score = score + 20
	end
	if target.type == "node" then
		score = score + 10
	end
	if title:find("devtools", 1, true) or description:find("devtools", 1, true) then
		score = score - 30
	end

	return score
end

local function target_label(target)
	local parts = {}

	for _, value in ipairs({
		target.title,
		target.description,
		target.vm,
		target.id,
	}) do
		if non_empty(value) and not vim.tbl_contains(parts, value) then
			table.insert(parts, value)
		end
	end

	if #parts == 0 then
		return target.webSocketDebuggerUrl or "Hermes target"
	end

	return table.concat(parts, " | ")
end

function M.decode_targets(body)
	local ok, targets = pcall(vim.json.decode, body)

	if not ok then
		fail("Metro /json/list returned invalid JSON: " .. tostring(targets))
	end

	if type(targets) ~= "table" then
		fail("Metro /json/list did not return a JSON array.")
	end

	if vim.islist and not vim.islist(targets) then
		fail("Metro /json/list did not return a JSON array.")
	end

	return targets
end

function M.filter_hermes_targets(targets)
	local matches = {}

	for _, target in ipairs(targets) do
		if type(target) == "table" and non_empty(target.webSocketDebuggerUrl) then
			local title = as_lower(target.title)
			local description = as_lower(target.description)
			local vm = tostring(target.vm or "")
			local ws = as_lower(target.webSocketDebuggerUrl)

			local looks_like_hermes = vm == "Hermes"
				or title:find("hermes", 1, true) ~= nil
				or description:find("hermes", 1, true) ~= nil
				or ws:find("/inspector/debug", 1, true) ~= nil

			if looks_like_hermes then
				table.insert(matches, target)
			end
		end
	end

	table.sort(matches, function(a, b)
		return target_score(a) > target_score(b)
	end)

	return matches
end

function M.find_hermes_targets(config, opts)
	opts = normalize_options(opts)
	local host, port = metro_endpoint(config or {}, opts)
	local body = http_get(("http://%s:%s/json/list"):format(host, port))

	return M.filter_hermes_targets(M.decode_targets(body))
end

function M.pick_target(targets)
	if #targets == 0 then
		fail(
			"Metro is running, but no Hermes debug target was found. "
				.. "Make sure the app is open, connected to Metro, and using Hermes."
		)
	end

	if #targets == 1 then
		return targets[1]
	end

	local co, is_main = coroutine.running()
	local dap_ui = require("dap.ui")
	local pick = co and not is_main and dap_ui.pick_one or dap_ui.pick_one_sync
	local selected = pick(targets, "Multiple Hermes targets found: ", target_label)

	if not selected then
		fail("Hermes target selection cancelled.")
	end

	return selected
end

local function proxy_log(prefix, data, enabled)
	if not enabled then
		return
	end

	for _, line in ipairs(data or {}) do
		if line ~= "" then
			vim.notify(prefix .. line, vim.log.levels.DEBUG)
		end
	end
end

local function handle_proxy_line(proxy, prefix, line, enabled)
	if line == "" then
		return
	end

	local ok, payload = pcall(vim.json.decode, line)
	if ok and type(payload) == "table" then
		local details = payload.details
		if payload.message == "ready" and type(details) == "table" then
			proxy.host = tostring(details.host or proxy.host)
			proxy.port = tonumber(details.port) or proxy.port
			proxy.ready = true
		elseif payload.level == "error" then
			proxy.last_error = line
		end
	end

	proxy_log(prefix, { line }, enabled)
end

local function handle_proxy_output(proxy, stream, data, enabled)
	proxy.output_buffers = proxy.output_buffers or {}
	local buffer = proxy.output_buffers[stream] or ""
	local lines = data or {}
	local prefix = PROXY_LOG_PREFIX[stream] or "dap-react-native proxy: "

	for index, line in ipairs(lines) do
		if index == 1 then
			line = buffer .. line
			buffer = ""
		end

		if index == #lines and line ~= "" then
			buffer = line
		else
			handle_proxy_line(proxy, prefix, line, enabled)
		end
	end

	proxy.output_buffers[stream] = buffer
end

local function flush_proxy_output(proxy, enabled)
	for stream, buffer in pairs(proxy.output_buffers or {}) do
		if buffer ~= "" then
			local prefix = PROXY_LOG_PREFIX[stream] or "dap-react-native proxy: "
			handle_proxy_line(proxy, prefix, buffer, enabled)
			proxy.output_buffers[stream] = ""
		end
	end
end

local function stop_proxy(proxy)
	if not proxy or proxy.stopped then
		return
	end

	proxy.stopped = true

	if proxy.job_id and proxy.job_id > 0 then
		vim.fn.jobstop(proxy.job_id)
	end
end

local function register_proxy(proxy)
	next_proxy_id = next_proxy_id + 1
	active_proxies[next_proxy_id] = proxy
	return next_proxy_id
end

local function ensure_proxy_runtime(opts)
	local script_path = opts.proxy.script_path or default_proxy_script_path()
	if vim.fn.filereadable(script_path) ~= 1 then
		fail("CDP proxy script was not found: " .. script_path)
	end

	if script_path ~= default_proxy_script_path() then
		return
	end

	local missing = {}
	for _, path in ipairs({
		join_path(plugin_root(), "node_modules", "vscode-cdp-proxy", "dist", "server.js"),
		join_path(plugin_root(), "node_modules", "ws", "index.js"),
	}) do
		if vim.fn.filereadable(path) ~= 1 then
			table.insert(missing, path)
		end
	end

	if #missing > 0 then
		fail(
			"Node dependencies are missing. Run `npm ci` in "
				.. plugin_root()
				.. ". Missing files: "
				.. table.concat(missing, ", ")
		)
	end
end

local function start_proxy(config, opts)
	ensure_proxy_runtime(opts)

	local host, metro_port = metro_endpoint(config)
	local target = M.pick_target(M.find_hermes_targets(config, opts))
	local proxy_host = opts.proxy.host or "127.0.0.1"
	local node_command = opts.proxy.node_command or "node"
	local proxy = {
		host = proxy_host,
		port = 0,
		label = target_label(target),
		stopped = false,
		ready = false,
	}

	local args = {
		node_command,
		opts.proxy.script_path or default_proxy_script_path(),
		"--host",
		proxy_host,
		"--port",
		"0",
		"--websocket-url",
		target.webSocketDebuggerUrl,
		"--origin",
		http_origin(host, metro_port),
		"--label",
		proxy.label,
	}

	local job_id = vim.fn.jobstart(args, {
		cwd = plugin_root(),
		stdout_buffered = false,
		stderr_buffered = false,
		on_stdout = function(_, data)
			handle_proxy_output(proxy, "stdout", data, opts.proxy.log)
		end,
		on_stderr = function(_, data)
			handle_proxy_output(proxy, "stderr", data, opts.proxy.log)
		end,
		on_exit = function(_, code)
			flush_proxy_output(proxy, opts.proxy.log)
			proxy.exited = true
			proxy.exit_code = code
			if code ~= 0 and not proxy.stopped then
				vim.notify("dap-react-native proxy exited with code " .. tostring(code), vim.log.levels.WARN)
			end
		end,
	})

	if job_id <= 0 then
		fail("Could not start React Native Hermes CDP proxy.")
	end

	proxy.job_id = job_id

	local timeout = opts.proxy.start_timeout_ms or 5000
	local resolved = vim.wait(timeout, function()
		return proxy.ready or proxy.exited
	end, 20)

	if not resolved then
		stop_proxy(proxy)
		fail("Timed out waiting for React Native Hermes CDP proxy to start.")
	end

	if not proxy.ready then
		fail(
			"React Native Hermes CDP proxy exited before it was ready. "
				.. (proxy.last_error or ("Exit code: " .. tostring(proxy.exit_code)))
		)
	end

	if not proxy.port or proxy.port == 0 then
		stop_proxy(proxy)
		fail("React Native Hermes CDP proxy did not report a listening port.")
	end

	vim.notify(("dap-react-native proxy started on %s:%s"):format(proxy.host, proxy.port), vim.log.levels.DEBUG)
	return proxy
end

local function is_react_native_hermes_session(session)
	while session do
		if session.config and session.config.__reactNativeHermes == true then
			return true
		end
		session = session.parent
	end

	return false
end

local function top_frame(frames)
	for _, frame in ipairs(frames or {}) do
		if frame.source then
			return frame
		end
	end

	return frames and frames[1] or nil
end

local function apply_threads_response(session, response)
	local old_threads = session.threads or {}
	local threads = {}

	for _, thread in ipairs((response and response.threads) or {}) do
		local old_thread = old_threads[thread.id]
		thread.stopped = (old_thread and old_thread.stopped) or false
		thread.frames = old_thread and old_thread.frames or thread.frames
		threads[thread.id] = thread
	end

	session.threads = threads
	session.dirty.threads = false
end

local function populate_thread_stop(dap, session, stopped)
	local thread_id = stopped and stopped.threadId
	if not thread_id or session.closed then
		return
	end

	pending_thread_stop[session] = pending_thread_stop[session] or {}
	if pending_thread_stop[session][thread_id] then
		return
	end
	pending_thread_stop[session][thread_id] = true

	require("dap.async").run(function()
		dap.set_session(session)

		if (session.dirty and session.dirty.threads) or not session.threads[thread_id] then
			local err, response = session:request("threads", nil)
			if not err and response then
				apply_threads_response(session, response)
			end
		end

		local thread = session.threads[thread_id]
		if not thread then
			thread = {
				id = thread_id,
				name = "Unknown",
			}
			session.threads[thread_id] = thread
		end

		thread.stopped = true

		local frames = thread.frames
		if not frames then
			local err, response = session:request("stackTrace", {
				startFrame = 0,
				threadId = thread_id,
			})

			if err or not response then
				vim.notify("dap-react-native: could not resolve stopped stack: " .. tostring(err), vim.log.levels.WARN)
				pending_thread_stop[session][thread_id] = nil
				return
			end

			frames = response.stackFrames
			thread.frames = frames
		end

		local frame = top_frame(frames)
		if not frame then
			pending_thread_stop[session][thread_id] = nil
			return
		end

		session.stopped_thread_id = thread_id
		session:_frame_set(frame)
		pending_thread_stop[session][thread_id] = nil
	end)
end

local function cleanup_session_proxy(session)
	if not session or not session.config then
		return
	end

	local proxy_id = session.config.__reactNativeHermesProxyId
	if proxy_id then
		stop_proxy(active_proxies[proxy_id])
		active_proxies[proxy_id] = nil
	end
end

local function merge_source_map_overrides(config, cwd)
	local overrides = {
		["/[metro-project]/*"] = cwd .. "/*",
	}

	if type(config.sourceMapPathOverrides) == "table" then
		overrides = vim.tbl_deep_extend("force", overrides, config.sourceMapPathOverrides)
	end

	return overrides
end

function M.configure_launch_config(config, opts)
	opts = normalize_options(opts)

	local item = vim.deepcopy(config)
	local metro_config = vim.deepcopy(config)

	if item.request and item.request ~= "attach" then
		fail("reactnativedirect request=" .. tostring(item.request) .. " is not supported yet. Use request=attach.")
	end

	if item.useHermesEngine == false then
		fail("reactnativedirect without Hermes is not supported.")
	end

	local cwd = item.cwd or "${workspaceFolder}"
	local proxy = start_proxy(metro_config, opts)

	item.type = opts.adapter or DEFAULT_ADAPTER
	item.request = "attach"
	item.__reactNativeHermes = true
	item.__reactNativeHermesProxyId = register_proxy(proxy)
	item.name = item.name or "Attach React Native Hermes"
	item.cwd = cwd
	item.continueOnAttach = item.continueOnAttach ~= false
	item.sourceMaps = item.sourceMaps ~= false
	item.pauseForSourceMap = item.pauseForSourceMap ~= false
	item.rootPath = item.rootPath or "${workspaceFolder}"
	item.sourceMapPathOverrides = merge_source_map_overrides(item, cwd)
	item.resolveSourceMapLocations = item.resolveSourceMapLocations or DEFAULT_RESOLVE_SOURCE_MAP_LOCATIONS
	item.skipFiles = item.skipFiles or DEFAULT_SKIP_FILES
	item.timeout = item.timeout or 30000
	item.address = proxy.host
	item.port = proxy.port
	item.remoteHostHeader = nil
	item.websocketAddress = nil

	return item
end

function M.setup_pause_stop_fix()
	local dap = require("dap")

	dap.listeners.after.event_stopped["dap_react_native_pause_stop"] = function(session, stopped)
		if not is_react_native_hermes_session(session) then
			return
		end

		dap.set_session(session)

		if stopped.threadId and stopped.reason == "pause" and not stopped.allThreadsStopped then
			populate_thread_stop(dap, session, stopped)
		end
	end
end

function M.setup_proxy_cleanup()
	local dap = require("dap")

	dap.listeners.on_session["dap_react_native_proxy_cleanup"] = function(_, session)
		if not session or not is_react_native_hermes_session(session) then
			return
		end

		session.on_close["dap_react_native_proxy_cleanup"] = function(closed_session)
			vim.schedule(function()
				cleanup_session_proxy(closed_session)
			end)
		end
	end

	dap.listeners.before.disconnect["dap_react_native_proxy_cleanup"] = cleanup_session_proxy
	dap.listeners.before.event_terminated["dap_react_native_proxy_cleanup"] = cleanup_session_proxy
	dap.listeners.before.event_exited["dap_react_native_proxy_cleanup"] = cleanup_session_proxy
end

local function ensure_hooks()
	if hooks_registered then
		return
	end

	M.setup_proxy_cleanup()
	M.setup_pause_stop_fix()
	hooks_registered = true
end

local function with_enriched_config(adapter, config, opts)
	local item = vim.deepcopy(adapter)
	local original_enrich_config = item.enrich_config

	item.enrich_config = function(enrich_config, on_config)
		local function configure(next_config)
			on_config(M.configure_launch_config(next_config or config, opts))
		end

		if original_enrich_config then
			original_enrich_config(enrich_config or config, configure)
		else
			configure(config)
		end
	end

	return item
end

function M.adapter(callback, config, parent)
	ensure_hooks()

	local dap = require("dap")
	local opts = normalize_options()
	local base_adapter = dap.adapters[opts.adapter]

	if not base_adapter then
		fail(
			("`dap.adapters.%s` was not found. Configure vscode-js-debug as `%s` first."):format(
				opts.adapter,
				opts.adapter
			)
		)
	end

	if type(base_adapter) == "function" then
		base_adapter(function(adapter)
			callback(with_enriched_config(adapter, config, opts))
		end, config, parent)
		return
	end

	callback(with_enriched_config(base_adapter, config, opts))
end

function M.attach(config)
	ensure_hooks()

	local dap = require("dap")

	config = vim.tbl_deep_extend("force", {
		type = "reactnativedirect",
		request = "attach",
		name = "Attach React Native Hermes",
		cwd = vim.fn.getcwd(),
	}, config or {})

	dap.run(M.configure_launch_config(config))
end

return M
