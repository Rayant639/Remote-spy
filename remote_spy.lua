--[[
    RayanSpy v2.1 — Remote Spy (Delta-safe)
    No WebSocket dependency — works standalone.
    UI connection is optional, never blocks execution.

    _G.RayanSpy API:
      .dump()    — print all captured remotes to console
      .clear()   — wipe log
      .unhook()  — restore original __namecall
      .getLog()  — return raw log table
      .count()   — return capture count
]]

-- ─── CONFIG ────────────────────────────────────────────────────
local CONFIG = {
    WS_PORT    = 7272,
    WS_HOST    = "localhost",
    MAX_LOG    = 1000,
    PRINT_LOG  = true,    -- print every remote to console

    BLACKLIST = {
        "Heartbeat", "Ping", "UpdatePosition", "PositionUpdate",
        "CharacterUpdate", "AnimationUpdate", "MouseUpdate",
        "CameraUpdate", "InputUpdate", "NetworkTick",
    },
}

local blacklistSet = {}
for _, v in ipairs(CONFIG.BLACKLIST) do blacklistSet[v] = true end

-- ─── STATE ─────────────────────────────────────────────────────
local remoteLog  = {}
local hookActive = false

-- ─── WEBSOCKET (non-blocking, optional) ────────────────────────
local ws          = nil
local wsConnected = false

-- Fire and forget — runs in a coroutine so it never blocks
local function tryConnectAsync()
    coroutine.wrap(function()
        local ok, result = pcall(function()
            return WebSocket.connect(
                string.format("ws://%s:%d", CONFIG.WS_HOST, CONFIG.WS_PORT)
            )
        end)
        if ok and result then
            ws          = result
            wsConnected = true
            print("[RayanSpy] UI connected at ws://localhost:" .. CONFIG.WS_PORT)
            result.OnClose:Connect(function()
                wsConnected = false
            end)
        end
        -- silently fail — UI is optional
    end)()
end

local function sendToUI(payload)
    if not wsConnected or not ws then return end
    pcall(function()
        -- inline minimal JSON
        local function enc(v, d)
            d = d or 0
            local t = type(v)
            if v == nil then return "null"
            elseif t == "boolean" then return v and "true" or "false"
            elseif t == "number" then
                if v ~= v then return '"NaN"' end
                if v == math.huge then return '"Inf"' end
                if v == -math.huge then return '"-Inf"' end
                if v == math.floor(v) then return tostring(math.floor(v)) end
                return string.format("%g", v)
            elseif t == "string" then
                return '"' .. v:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n') .. '"'
            elseif t == "table" and d < 6 then
                local parts = {}
                for k, val in pairs(v) do
                    table.insert(parts, enc(tostring(k),d+1)..":"..enc(val,d+1))
                end
                return "{"..table.concat(parts,",").."}"
            end
            return enc(tostring(v), d)
        end
        ws:Send(enc(payload))
    end)
end

-- ─── ARG SERIALIZER ────────────────────────────────────────────
local function serializeArg(val, depth)
    depth = depth or 0
    if depth > 4 then return {type="table",value="(max depth)"} end

    local t = typeof(val)

    if val == nil then
        return {type="nil", value="nil"}
    elseif t == "boolean" then
        return {type="boolean", value=val}
    elseif t == "number" then
        if val ~= val then return {type="number",value="NaN"} end
        if val ==  math.huge then return {type="number",value="Inf"} end
        if val == -math.huge then return {type="number",value="-Inf"} end
        return {type="number", value=val}
    elseif t == "string" then
        return {type="string", value=#val>256 and val:sub(1,256).."…" or val}
    elseif t == "Instance" then
        local ok, r = pcall(function()
            return {type="Instance", class=val.ClassName, value=val:GetFullName()}
        end)
        return ok and r or {type="Instance",class="?",value="(destroyed)"}
    elseif t == "Vector3" then
        return {type="Vector3",
            x=math.floor(val.X*100+.5)/100,
            y=math.floor(val.Y*100+.5)/100,
            z=math.floor(val.Z*100+.5)/100}
    elseif t == "CFrame" then
        local p = val.Position
        return {type="CFrame",
            x=math.floor(p.X*100+.5)/100,
            y=math.floor(p.Y*100+.5)/100,
            z=math.floor(p.Z*100+.5)/100}
    elseif t == "Color3" then
        return {type="Color3",
            r=math.floor(val.R*255+.5),
            g=math.floor(val.G*255+.5),
            b=math.floor(val.B*255+.5)}
    elseif t == "EnumItem" then
        return {type="EnumItem", value=tostring(val)}
    elseif t == "table" then
        local ok2, tbl = pcall(function()
            local out, n = {}, 0
            for k, v in pairs(val) do
                n = n + 1
                if n > 20 then out["..."]="("..n.." more)"; break end
                local ok3, sv = pcall(serializeArg, v, depth+1)
                out[tostring(k)] = ok3 and sv or {type="error",value="?"}
            end
            return out
        end)
        return ok2 and {type="table",value=tbl} or {type="table",value="(cyclic)"}
    else
        return {type=t, value=tostring(val)}
    end
end

local function serializeArgs(pack)
    local out = {}
    for i = 1, pack.n do out[i] = serializeArg(pack[i]) end
    return out
end

-- ─── HOOK ──────────────────────────────────────────────────────
local mt = getrawmetatable(game)
setreadonly(mt, false)
local oldNamecall = mt.__namecall
hookActive = true

mt.__namecall = newcclosure(function(self, ...)
    local method = getnamecallmethod()

    if method == "FireServer" or method == "InvokeServer" then
        local ok1, cls = pcall(function()
            return (typeof(self)=="Instance") and self.ClassName or ""
        end)
        cls = ok1 and cls or ""

        if cls == "RemoteEvent" or cls == "RemoteFunction" then
            local ok2, name = pcall(function() return self.Name end)
            name = ok2 and name or "?"

            if not blacklistSet[name] then
                local argPack  = table.pack(...)
                local fullPath = ""
                pcall(function() fullPath = self:GetFullName() end)

                local entry = {
                    id       = os.clock(),
                    path     = fullPath,
                    remote   = name,
                    method   = method,
                    class    = cls,
                    args     = serializeArgs(argPack),
                    argCount = argPack.n,
                    time     = os.date("%H:%M:%S"),
                }

                table.insert(remoteLog, entry)
                if #remoteLog > CONFIG.MAX_LOG then
                    table.remove(remoteLog, 1)
                end

                pcall(sendToUI, {type="remote", data=entry})

                if CONFIG.PRINT_LOG then
                    print(string.format("[RayanSpy] %s :: %s | %d args",
                        fullPath, method, argPack.n))
                end
            end
        end
    end

    local res = table.pack(pcall(oldNamecall, self, ...))
    if not res[1] then error(res[2], 2) end
    return table.unpack(res, 2, res.n)
end)

setreadonly(mt, true)

-- try UI connection async — never blocks
tryConnectAsync()

-- ─── API ────────────────────────────────────────────────────────
_G.RayanSpy = {
    getLog = function() return remoteLog end,
    count  = function() return #remoteLog end,

    dump = function()
        if #remoteLog == 0 then print("[RayanSpy] Nothing captured."); return end
        print(string.format("[RayanSpy] %d remotes:", #remoteLog))
        for i, r in ipairs(remoteLog) do
            print(string.format("  [%d] %s :: %s | %d args @ %s",
                i, r.path, r.method, r.argCount, r.time))
        end
    end,

    clear = function()
        remoteLog = {}
        pcall(sendToUI, {type="clear"})
        print("[RayanSpy] Cleared.")
    end,

    unhook = function()
        if not hookActive then print("[RayanSpy] Already unhooked."); return end
        local m = getrawmetatable(game)
        setreadonly(m, false)
        m.__namecall = oldNamecall
        setreadonly(m, true)
        hookActive = false
        if ws and wsConnected then pcall(function() ws:Close() end) end
        print("[RayanSpy] Unhooked.")
    end,

    reconnect = function()
        if wsConnected then pcall(function() ws:Close() end); wsConnected=false end
        tryConnectAsync()
    end,
}

print("[RayanSpy v2.1] Hooked. _G.RayanSpy ready. Call _G.RayanSpy.dump() to see remotes.")
