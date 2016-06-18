local shaco = require "shaco"
local http = require "http"
local httpsocket = require "httpsocket"
local socket = require "socket"
local websocket = require "websocket"
local tbl = require "tbl"
local cjson = require "cjson"
local sfmt = string.format

local __user = shaco.getenv("user")
local __passwd = shaco.getenv("passwd")
local __name = shaco.getenv("name") or "Test"
local __server = shaco.getenv("server")

assert(__user and __passwd, "Not user config")
assert(__server, "Not server config")

local __agents = {}

local CMD = {}

local function __auth(v)
    --assert(v.user=="qa" and v.passwd=="qa@2016^$", "Auth fail")
    assert(v.user==__user and v.passwd==__passwd, "Auth fail")
    return {user=v.user, passwd=v.passwd, name=__name}
end

function CMD.serverstatus()
    return {
        name=__name,
        time=os.date("%Y-%m-%d %H:%M:%S"),
    }
end

function CMD.changetime(v)
    local time = v.time
    time = os.date("%m%d%H%M%Y.%S", time)
    if os.execute(sfmt(
        'date %s && su - %s -c "cd server && ./shaco-foot restart game"', 
        time, __server)) then
        return {time=time}
    end
end

local function __send(id, cmd, body)
    local str = cjson.encode({cmd=cmd, body=body})
    shaco.trace("Send:", id, str)
    websocket.text(id, str)
end

local function __exec(id, v)
    shaco.trace(id, tbl(v, "Cmd"))
    local ag = assert(__agents[id], "No found agent:"..id)
    local body
    if not ag.logined then
        assert(v.cmd == "auth", "Auth first")
        body = __auth(v.body)
        ag.logined = true
    else
        body = assert(CMD[v.cmd], "Invalid cmd")(v.body)
    end
    if not body then
        body = {code=1}
    end
    __send(id, v.cmd, body)
end

local function __logout(id, err)
    local ag = __agents[id]
    if ag then
        __agents[id] = nil
        shaco.trace("Agent logout:", id, err)
        socket.close(id)
    end
end

local function __timeloop(id)
    local tick = 0
    while true do
        local ag = __agents[id]
        if not ag then
            break
        end
        if not ag.logined then
            if shaco.now() - ag.createtime > 10*000 then
                __logout(id, "login timeout")
                break
            end
        else
            --if tick%3==0 then
                __exec(id, {cmd="serverstatus"})
            --end
        end
        shaco.sleep(1000)
        tick = tick+1
    end
end

local function agent_login(id, addr, code, method, uri, head_t, body, version)
    local ok, err = pcall(function()
        __agents[id] = {
            id = id, 
            addr = addr,
            createtime = shaco.now();
            logined = false,
        }
        shaco.fork(__timeloop, id)
        websocket.handshake(id, code, method, uri, head_t, body, version)
        local ag = __agents[id]
        if not ag then -- logout
            return
        end
        while true do
            local data, typ = websocket.read(id)
            if typ == "data" then
                local v = cjson.decode(data)
                __exec(id, v)
            else
                __logout(id, "websocket "..typ)
                break
            end
        end
    end)
    if not ok then
        shaco.error(id, addr, err)
        __logout(id, "exception")
    end
end

shaco.start(function()
    local CTYPE = {
        html="text/html",
        css="text/css",
        js="application/x-javascript",
    }
    local CTYPE_UNKNOWN = "application/octet-stream"

    local webdir = shaco.getenv("webdir") or "./html"
    local host = shaco.getenv("host") or "0.0.0.0:20160"
    local lid = assert(socket.listen(host, function(id, addr)
        local ok, err = pcall(function()
            shaco.trace("Conn:", id, addr)
            socket.start(id)
            socket.readon(id)
            local code, method, uri, head_t, body, version = http.read(
            httpsocket.reader(id))
            if code ~= 200 then
                socket.close(id)
                return
            end
            if method ~= "GET" then
                socket.close(id)
                return
            end

            --if uri == "/" then -- default for main
            --  uri = "/mdl/index.html"
            --end
            shaco.trace(id, addr, method, uri, version, code, body)
            if uri == "/gmop" then -- tag websocket
                agent_login(id, addr, code, method, uri, head_t, body, version)
            elseif string.find(uri, "favicon") then
                http.response(200, nil, 
                {["content-type"]="image/x-icon", connection="close"},
                httpsocket.sender(id))
                socket.close(id, false)
            else
                -- just simple verify uri
                assert(string.find(uri, "..",1,true)==nil, "Invalid uri")

                local fname = webdir..uri
                local f = io.open(fname)
                assert(f, fname)
                local ok2, err2 = pcall(function()
                    local ftype = string.match(uri, ".*[.]([^.]*)$")
                    local ctype = CTYPE[ftype] or CTYPE_UNKNOWN
                    local size = 64*1024
                    http.response(200, function()
                        local data = f:read(size)
                        if data and #data == size then
                            shaco.sleep(1) -- sleep for socker send
                        end
                        return data
                    end,
                    {["content-type"]=sfmt("%s",ctype), connection="close"},
                    httpsocket.sender(id))
                end)
                f:close()
                if ok2 then
                    socket.close(id, false)
                else
                    error(err2)
                end
            end
        end)
        if not ok then
            shaco.error(id, addr, err)
            socket.close(id)
        end
    end))
    shaco.info("gmop listen on", host, lid, webdir)
end)
