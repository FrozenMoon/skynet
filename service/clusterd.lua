local skynet = require "skynet"
local sc = require "socketchannel"
local socket = require "socket"
local cluster = require "cluster.c"

local config_name = skynet.getenv "cluster"
local node_address = {}
assert(loadfile(config_name, "t", node_address))()
local node_session = {}
local command = {}

local function read_response(sock)
	local sz = socket.header(sock:read(2))
	local msg = sock:read(sz)
	return cluster.unpackresponse(msg)	-- session, ok, data
end

local function open_channel(t, key)
	local host, port = string.match(node_address[key], "([^:]+):(.*)$")
	local c = sc.channel {
		host = host,
		port = tonumber(port),
		response = read_response,
	}
	assert(c:connect(true))
	t[key] = c
	node_session[key] = 1
	return c
end

local node_channel = setmetatable({}, { __index = open_channel })

function command.listen(source, addr, port)
	local gate = skynet.newservice("gate")
	skynet.call(gate, "lua", "open", { address = addr, port = port })
	skynet.ret(skynet.pack(nil))
end

function command.req(source, node, addr, msg, sz)
	local request
	local c = node_channel[node]
	local session = node_session[node]
	-- msg is a local pointer, cluster.packrequest will free it
	request, node_session[node] = cluster.packrequest(addr, session , msg, sz)
	skynet.ret(c:request(request, session))
end

local request_fd = {}

function command.socket(source, subcmd, fd, msg)
	if subcmd == "data" then
		local addr, session, msg = cluster.unpackrequest(msg)
		local msg, sz = skynet.rawcall(addr, "lua", msg)
		local response = cluster.packresponse(session, msg, sz)
		socket.write(fd, response)
	elseif subcmd == "open" then
		skynet.error(string.format("socket accept from %s", msg))
		skynet.call(source, "lua", "accept", fd)
	else
		skynet.error(string.format("socket %s %d : %s", subcmd, fd, msg))
	end
end

skynet.start(function()
	skynet.dispatch("lua", function(_, source, cmd, ...)
		local f = assert(command[cmd])
		f(source, ...)
	end)
end)
