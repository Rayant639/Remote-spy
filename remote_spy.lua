--[[
    RayanSpy v2.0 — Remote Spy
    Author  : Rayan Scripts
    Executor: UNC-compliant (Synapse X / Delta / Wave)
    UI      : remote_spy_ui.html @ ws://localhost:7272

    _G.RayanSpy API:
      .dump()        — print all captured remotes
      .clear()       — wipe log + notify UI
      .unhook()      — restore original __namecall, close socket
      .reconnect()   — re-attempt WebSocket connection
      .getLog()      — return raw log table
      .count()       — return capture count
]]

-- ─── CONFIG ────────────────────────────────────────────────────
local CONFIG = {
    WS_PORT   = 7272,
    WS_HOST   = "localhost",
    MAX_LOG   = 1000,
    PRINT_LOG = false,   -- set true to also print to executor console

    -- remotes to silently ignore (add game-specific noise here)
    BLACKLIST = {
        "Heartbeat", "Ping", "UpdatePosition", "PositionUpdate",
        "CharacterUpdate", "AnimationUpdate", "MouseUpdate",
        "CameraUpdate", "InputUpdate", "NetworkTick",
    },
}

-- ─── BLACKLIST SET ──────────────────────────────────────────────
local blacklistSet = {}
for _, name in ipairs(CONFIG.BLACKLIST) do
    blacklistSet[name] = true
end

-- ─── STATE ─────────────────────────────────────────────────────
local remoteLog   = {}
local hookActive  = false
local ws          = nil
local wsConnected = false

-- ─── ARG SERIALIZER ────────────────────────────────────────────
-- Returns a table describing one argument, safe for JSON encoding.
local function serializeArg(val, depth)
    depth = depth or 0
    if depth > 4 then
        return { type = "table", value = "(max depth)" }
    end

    local t = typeof(val)

    if val == nil then
        return { type = "nil", value = "nil" }

    elseif t == "boolean" then
        return { type = "boolean", value = val }

    elseif t == "number" then
        if val ~= val then
            return { type = "number", value = "NaN" }
        elseif val == math.huge then
            return { type = "number", value = "Infinity" }
        elseif val == -math.huge then
            return { type = "number", value = "-Infinity" }
        end
        return { type = "number", value = val }

    elseif t == "string" then
        local s = val
        if #s > 300 then s = s:sub(1, 300) .. "…" end
        return { type = "string", value = s }

    elseif t == "Instance" then
        local ok, result = pcall(function()
            return {
                type  = "Instance",
                class = val.ClassName,
                value = val:GetFullName(),
            }
        end)
        if ok then return result end
        return { type = "Instance", class = "?", value = "(destroyed)" }

    elseif t == "Vector3" then
        return {
            type = "Vector3",
            x    = math.floor(val.X * 100 + 0.5) / 100,
            y    = math.floor(val.Y * 100 + 0.5) / 100,
            z    = math.floor(val.Z * 100 + 0.5) / 100,
        }

    elseif t == "CFrame" then
        local p = val.Position
        return {
            type = "CFrame",
            x    = math.floor(p.X * 100 + 0.5) / 100,
            y    = math.floor(p.Y * 100 + 0.5) / 100,
            z    = math.floor(p.Z * 100 + 0.5) / 100,
        }

    elseif t == "Color3" then
        return {
            type = "Color3",
            r    = math.floor(val.R * 255 + 0.5),
            g    = math.floor(val.G * 255 + 0.5),
            b    = math.floor(val.B * 255 + 0.5),
        }

    elseif t == "EnumItem" then
        return { type = "EnumItem", value = tostring(val) }

    elseif t == "table" then
        -- shallow copy with cycle protection
        local ok2, tbl = pcall(function()
            local out   = {}
            local count = 0
            for k, v in pairs(val) do
                count = count + 1
                if count > 24 then
                    out["..."] = string.format("(%d more)", count)
                    break
                end
                local ks = tostring(k)
                local ok3, sv = pcall(serializeArg, v, depth + 1)
                out[ks] = ok3 and sv or { type = "error", value = "unserializable" }
            end
            return out
        end)
        if ok2 then
            return { type = "table", value = tbl }
        end
        return { type = "table", value = "(cyclic/inaccessible)" }

    else
        return { type = t, value = tostring(val) }
    end
end

-- Serialize the full vararg pack (preserves nil holes via .n)
local function serializeArgs(argPack)
    local out = {}
    for i = 1, argPack.n do
        out[i] = serializeArg(argPack[i])
    end
    return out
end

-- ─── JSON ENCODER ──────────────────────────────────────────────
-- Minimal Luau JSON encoder — no external deps.
local function jsonEncode(val, depth)
    depth = depth or 0
    local t = type(val)

    if val == nil then
        return "null"
    elseif t == "boolean" then
        return val and "true" or "false"
    elseif t == "number" then
        if val ~= val then return '"NaN"' end
        if val == math.huge  then return '"Infinity"' end
        if val == -math.huge then return '"-Infinity"' end
        -- integers print without decimal
        if val == math.floor(val) and math.abs(val) < 1e15 then
            return string.format("%d", val)
        end
        return string.format("%g", val)
    elseif t == "string" then
        -- escape special chars
        local s = val
            :gsub('\\', '\\\\')
            :gsub('"',  '\\"')
            :gsub('\n', '\\n')
            :gsub('\r', '\\r')
            :gsub('\t', '\\t')
        return '"' .. s .. '"'
    elseif t == "table" then
        if depth > 8 then return '"[max depth]"' end

        -- detect array (consecutive integer keys from 1)
        local isArray = true
        local maxN = 0
        for k, _ in pairs(val) do
            if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
                isArray = false
                break
            end
            if k > maxN then maxN = k end
        end
        if isArray then
            for i = 1, maxN do
                if val[i] == nil then isArray = false; break end
            end
        end

        local parts = {}
        if isArray then
            for i = 1, maxN do
                parts[i] = jsonEncode(val[i], depth + 1)
            end
            return '[' .. table.concat(parts, ',') .. ']'
        else
            for k, v in pairs(val) do
                local ks = type(k) == "string" and k or tostring(k)
                table.insert(parts, jsonEncode(ks, depth + 1) .. ':' .. jsonEncode(v, depth + 1))
            end
            return '{' .. table.concat(parts, ',') .. '}'
        end
    end
    return '"' .. tostring(val) .. '"'
end

-- ─── WEBSOCKET BRIDGE ──────────────────────────────────────────
local function sendToUI(payload)
    if not wsConnected or not ws then return end
    local ok, err = pcall(function()
        ws:Send(jsonEncode(payload))
    end)
    if not ok then
        wsConnected = false
        if CONFIG.PRINT_LOG then
            warn("[RayanSpy] WS send failed:", err)
        end
    end
end

local function tryConnect()
    local url = string.format("ws://%s:%d", CONFIG.WS_HOST, CONFIG.WS_PORT)
    local ok, result = pcall(function()
        return WebSocket.connect(url)
    end)
    if ok and result then
        ws          = result
        wsConnected = true
        if CONFIG.PRINT_LOG then
            print("[RayanSpy] Connected to UI @", url)
        end
        ws.OnClose:Connect(function()
            wsConnected = false
            if CONFIG.PRINT_LOG then
                warn("[RayanSpy] WS closed.")
            end
        end)
    else
        wsConnected = false
        if CONFIG.PRINT_LOG then
            warn("[RayanSpy] WS connect failed:", result)
        end
    end
end

tryConnect()

-- ─── HOOK ──────────────────────────────────────────────────────
local mt = getrawmetatable(game)
setreadonly(mt, false)

local oldNamecall = mt.__namecall
hookActive = true

mt.__namecall = newcclosure(function(self, ...)
    local method = getnamecallmethod()

    if method == "FireServer" or method == "InvokeServer" then
        local ok1, className = pcall(function()
            return typeof(self) == "Instance" and self.ClassName or ""
        end)
        local cls = ok1 and className or ""

        if cls == "RemoteEvent" or cls == "RemoteFunction" then
            local ok2, remoteName = pcall(function() return self.Name end)
            local name = ok2 and remoteName or "?"

            if not blacklistSet[name] then
                -- table.pack preserves nil holes via .n
                local argPack = table.pack(...)
                local fullPath = ""
                pcall(function() fullPath = self:GetFullName() end)

                local payload = {
                    id       = os.clock(),
                    path     = fullPath,
                    remote   = name,
                    method   = method,
                    class    = cls,
                    args     = serializeArgs(argPack),
                    argCount = argPack.n,
                    time     = os.date("%H:%M:%S"),
                }

                table.insert(remoteLog, payload)
                if #remoteLog > CONFIG.MAX_LOG then
                    table.remove(remoteLog, 1)
                end

                -- protected send — hook must never crash
                pcall(sendToUI, { type = "remote", data = payload })

                if CONFIG.PRINT_LOG then
                    print(string.format(
                        "[RayanSpy] %s :: %s | %d arg(s)",
                        fullPath, method, argPack.n
                    ))
                end
            end
        end
    end

    -- call original, re-raise errors so game logic sees them
    local results = table.pack(pcall(oldNamecall, self, ...))
    if not results[1] then
        error(results[2], 2)
    end
    return table.unpack(results, 2, results.n)
end)

setreadonly(mt, true)

-- ─── PUBLIC API ────────────────────────────────────────────────
_G.RayanSpy = {
    getLog = function()
        return remoteLog
    end,

    count = function()
        return #remoteLog
    end,

    dump = function()
        if #remoteLog == 0 then
            print("[RayanSpy] No remotes captured yet.")
            return
        end
        print(string.format("[RayanSpy] === %d Remotes ===", #remoteLog))
        for i, r in ipairs(remoteLog) do
            print(string.format(
                "  [%d] %s :: %s | args: %d | %s",
                i, r.path, r.method, r.argCount, r.time
            ))
        end
    end,

    clear = function()
        remoteLog = {}
        pcall(sendToUI, { type = "clear" })
        print("[RayanSpy] Log cleared.")
    end,

    unhook = function()
        if not hookActive then
            print("[RayanSpy] Already unhooked.")
            return
        end
        local mt2 = getrawmetatable(game)
        setreadonly(mt2, false)
        mt2.__namecall = oldNamecall
        setreadonly(mt2, true)
        hookActive = false
        if ws and wsConnected then
            pcall(function() ws:Close() end)
        end
        wsConnected = false
        print("[RayanSpy] Unhooked. Original __namecall restored.")
    end,

    reconnect = function()
        if wsConnected then
            pcall(function() ws:Close() end)
            wsConnected = false
        end
        tryConnect()
        print("[RayanSpy] Reconnect attempted.")
    end,
}

print(string.format(
    "[RayanSpy v2.0] Hooked. UI: ws://localhost:%d | API: _G.RayanSpy",
    CONFIG.WS_PORT
))
