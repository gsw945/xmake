--!A cross-platform build utility based on Lua
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- Copyright (C) 2015-present, TBOOX Open Source Group.
--
-- @author      ruki
-- @file        client.lua
--

-- imports
import("core.base.bytes")
import("core.base.base64")
import("core.base.socket")
import("core.base.option")
import("core.base.scheduler")
import("core.project.config", {alias = "project_config"})
import("lib.detect.find_tool")
import("private.service.client_config", {alias = "config"})
import("private.service.message")
import("private.service.client")
import("private.service.stream", {alias = "socket_stream"})

-- define module
local remote_cache_client = remote_cache_client or client()
local super = remote_cache_client:class()

-- init client
function remote_cache_client:init()
    super.init(self)

    -- init address
    local address = assert(config.get("remote_cache.connect"), "config(remote_cache.connect): not found!")
    self:address_set(address)

    -- get project directory
    local projectdir = os.projectdir()
    local projectfile = os.projectfile()
    if projectfile and os.isfile(projectfile) and projectdir then
        self._PROJECTDIR = projectdir
        self._WORKDIR = path.join(project_config.directory(), "remote_cache")
    else
        raise("we need enter a project directory with xmake.lua first!")
    end
end

-- get class
function remote_cache_client:class()
    return remote_cache_client
end

-- connect to the remote server
function remote_cache_client:connect()
    if self:is_connected() then
        print("%s: has been connected!", self)
        return
    end

    -- we need user authorization?
    local token = config.get("remote_cache.token")
    if not token and self:user() then

        -- get user password
        cprint("Please input user ${bright}%s${clear} password to connect <%s:%d>:", self:user(), self:addr(), self:port())
        io.flush()
        local pass = (io.read() or ""):trim()
        assert(pass ~= "", "password is empty!")

        -- compute user authorization
        token = base64.encode(self:user() .. ":" .. pass)
        token = hash.md5(bytes(token))
    end

    -- do connect
    local addr = self:addr()
    local port = self:port()
    local sock = assert(socket.connect(addr, port), "%s: server unreachable!", self)
    local session_id = self:session_id()
    local ok = false
    local errors
    print("%s: connect %s:%d ..", self, addr, port)
    if sock then
        local stream = socket_stream(sock)
        if stream:send_msg(message.new_connect(session_id, {token = token})) and stream:flush() then
            local msg = stream:recv_msg()
            if msg then
                vprint(msg:body())
                if msg:success() then
                    ok = true
                else
                    errors = msg:errors()
                end
            end
        end
    end
    if ok then
        print("%s: connected!", self)
    else
        print("%s: connect %s:%d failed, %s", self, addr, port, errors or "unknown")
    end

    -- update status
    local status = self:status()
    status.addr = addr
    status.port = port
    status.token = token
    status.connected = ok
    status.session_id = session_id
    self:status_save()
end

-- disconnect server
function remote_cache_client:disconnect()
    if not self:is_connected() then
        print("%s: has been disconnected!", self)
        return
    end
    local addr = self:addr()
    local port = self:port()
    local sock = socket.connect(addr, port)
    local session_id = self:session_id()
    local errors
    local ok = false
    print("%s: disconnect %s:%d ..", self, addr, port)
    if sock then
        local stream = socket_stream(sock)
        if stream:send_msg(message.new_disconnect(session_id, {token = self:token()})) and stream:flush() then
            local msg = stream:recv_msg()
            if msg then
                vprint(msg:body())
                if msg:success() then
                    ok = true
                else
                    errors = msg:errors()
                end
            end
        end
    else
        -- server unreachable, but we still disconnect it.
        wprint("%s: server unreachable!", self)
        ok = true
    end
    if ok then
        print("%s: disconnected!", self)
    else
        print("%s: disconnect %s:%d failed, %s", self, addr, port, errors or "unknown")
    end

    -- update status
    local status = self:status()
    status.token = nil
    status.connected = not ok
    self:status_save()
end

-- pull cache file
function remote_cache_client:pull(cachekey, cachefile)
    assert(self:is_connected(), "%s: has been not connected!", self)
    local addr = self:addr()
    local port = self:port()
    local sock = assert(socket.connect(addr, port), "%s: server unreachable!", self)
    local session_id = self:session_id()
    local errors
    local ok = false
    local exists = false
    dprint("%s: pull cache(%s) in %s:%d ..", self, cachekey, addr, port)
    local stream = socket_stream(sock)
    if stream:send_msg(message.new_pull(session_id, cachekey, {token = self:token()})) and stream:flush() then
        if stream:recv_file(cachefile) then
            local msg = stream:recv_msg()
            if msg then
                dprint(msg:body())
                if msg:success() then
                    ok = true
                    exists = msg:body().exists
                else
                    errors = msg:errors()
                end
            end
        else
            errors = "recv cache file failed"
        end
    end
    if ok then
        dprint("%s: pull cache(%s) ok!", self, cachekey)
    else
        dprint("%s: pull cache(%s) failed in %s:%d, %s", self, cachekey, addr, port, errors or "unknown")
    end
    return exists
end

-- push cache file
function remote_cache_client:push(cachekey, cachefile)
    assert(self:is_connected(), "%s: has been not connected!", self)
    local addr = self:addr()
    local port = self:port()
    local sock = assert(socket.connect(addr, port), "%s: server unreachable!", self)
    local session_id = self:session_id()
    local errors
    local ok = false
    dprint("%s: push cache(%s) in %s:%d ..", self, cachekey, addr, port)
    local stream = socket_stream(sock)
    if stream:send_msg(message.new_push(session_id, cachekey, {token = self:token()})) and stream:flush() then
        if stream:send_file(cachefile, {compress = os.filesize(cachefile) > 4096}) then
            local msg = stream:recv_msg()
            if msg then
                dprint(msg:body())
                if msg:success() then
                    ok = true
                else
                    errors = msg:errors()
                end
            end
        else
            errors = "send cache file failed"
        end
    end
    if ok then
        dprint("%s: push cache(%s) ok!", self, cachekey)
    else
        dprint("%s: push cache(%s) failed in %s:%d, %s", self, cachekey, addr, port, errors or "unknown")
    end
end

-- clean server files
function remote_cache_client:clean()
    assert(self:is_connected(), "%s: has been not connected!", self)
    local addr = self:addr()
    local port = self:port()
    local sock = assert(socket.connect(addr, port), "%s: server unreachable!", self)
    local session_id = self:session_id()
    local errors
    local ok = false
    print("%s: clean files in %s:%d ..", self, addr, port)
    local stream = socket_stream(sock)
    if stream:send_msg(message.new_clean(session_id, {token = self:token()})) and stream:flush() then
        local msg = stream:recv_msg()
        if msg then
            vprint(msg:body())
            if msg:success() then
                ok = true
            else
                errors = msg:errors()
            end
        end
    end
    if ok then
        print("%s: clean files ok!", self)
    else
        print("%s: clean files failed in %s:%d, %s", self, addr, port, errors or "unknown")
    end
end

-- is connected?
function remote_cache_client:is_connected()
    return self:status().connected
end

-- get the status
function remote_cache_client:status()
    local status = self._STATUS
    local statusfile = self:statusfile()
    if not status then
        if os.isfile(statusfile) then
            status = io.load(statusfile)
        end
        status = status or {}
        self._STATUS = status
    end
    return status
end

-- save status
function remote_cache_client:status_save()
    io.save(self:statusfile(), self:status())
end

-- get the status file
function remote_cache_client:statusfile()
    return path.join(self:workdir(), "status.txt")
end

-- get the project directory
function remote_cache_client:projectdir()
    return self._PROJECTDIR
end

-- get working directory
function remote_cache_client:workdir()
    return self._WORKDIR
end

-- get user token
function remote_cache_client:token()
    return self:status().token
end

-- get the session id, only for unique project
function remote_cache_client:session_id()
    return self:status().session_id or hash.uuid():split("-", {plain = true})[1]:lower()
end

-- set the given client address
function remote_cache_client:address_set(address)
    local addr, port, user = self:address_parse(address)
    self._ADDR = addr
    self._PORT = port
    self._USER = user
end

-- get user name
function remote_cache_client:user()
    return self._USER
end

-- get the ip address
function remote_cache_client:addr()
    return self._ADDR
end

-- get the address port
function remote_cache_client:port()
    return self._PORT
end

function remote_cache_client:__tostring()
    return "<remote_cache_client>"
end

-- is connected? we cannot depend on client:init when run action
function is_connected()
    -- the current process is in service? we cannot enable it
    if os.getenv("XMAKE_IN_SERVICE") then
        return false
    end
    local projectdir = os.projectdir()
    local projectfile = os.projectfile()
    if projectfile and os.isfile(projectfile) and projectdir then
        local workdir = path.join(project_config.directory(), "remote_cache")
        local statusfile = path.join(workdir, "status.txt")
        if os.isfile(statusfile) then
            local status = io.load(statusfile)
            if status and status.connected then
                return true
            end
        end
    end
end

-- new a client instance
function new()
    local instance = remote_cache_client()
    instance:init()
    return instance
end

-- get the singleton
function singleton()
    local instance = _g.singleton
    if not instance then
        instance = new()
        _g.singleton = instance
    end
    return instance
end

function main()
    return new()
end
