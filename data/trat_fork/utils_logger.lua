local default_dst = "tra-log.txt";

--- 写日志。
--- [TRAtUI] 日志只是诊断辅助，**绝不能因为写不进去就中断业务逻辑**。
--- 实测崩溃：`io.open failed for ..._area_scan_沟中死水岛.tsv` —— 中文路径下
--- io.open 返回 nil（Lua 以 UTF-8 字节调 fopen，Windows 按 ANSI 代码页解释），
--- 旧实现在这里 error()，把整轮地图扫描/调度直接打死。
--- 现在改为静默失败并返回 false，调用方可以选择忽略。
local function _write_to_file(t, dst)
    local ok, file = pcall(io.open, dst, "a+")
    if not ok or file == nil then
        return false
    end
    pcall(function()
        file:write(t)
        file:close()
    end)
    return true
end

local logs_removed = {}

local function newLogger(dst, base)
    if dst == nil then
        dst = default_dst
    end
    -- if "/" in dst then
    if string.find(dst, "/") or string.find(dst, "\\") then
    elseif base then
        dst = base .. dst
    end
    if not logs_removed[dst] then
        os.remove(dst)
        logs_removed[dst] = true
    end

    local l = {};
    l.fields = {};
    l.dst = dst or default_dst;
    l.__base = base;

    local function formatFields()
        local ret = "";
        for k, v in pairs(l.fields) do
            if string.find(v, " ") then
                v = '"' .. v .. '"'
            end
            local kv = string.format("%s=%s", tostring(k), tostring(v));
            if ret ~= "" then
                ret = ret .. " " .. kv
            else
                ret = kv
            end
        end
        return ret;
    end

    local function formatField(k, v)
        if string.find(v, " ") then
            v = '"' .. v .. '"'
        end
        local kv = string.format("%s=%s", tostring(k), tostring(v));
        return kv
    end

    l.log = function(msg)
        local ret;
        if not l.disableDate then
            local date = os.date("%Y-%m-%dT%H:%M:%SZ")
            ret = date .. " ";
        else
            ret = "";
        end

        local fields = formatFields();
        if fields ~= "" then
            ret = ret .. fields .. " ";
        end
        ret = ret .. msg;
        _write_to_file(ret .. "\n", l.dst)
    end
    l.logf = function(fmt, ...)
        return l.log(string.format(fmt, ...))
    end
    l.with = function(key, value)
        local fields_copy = {};
        for k, v in pairs(l.fields) do
            fields_copy[k] = v;
        end
        fields_copy[key] = value;

        local ret = newLogger(l.dst);
        ret.fields = fields_copy;
        return ret;
    end
    l.logger = function(dst, forceRemoval)
        if forceRemoval then
            os.remove(dst)
            logs_removed[dst] = true
        end

        local fields_copy = {};
        for k, v in pairs(l.fields) do
            fields_copy[k] = v;
        end

        local ret = newLogger(dst, l.__base);
        ret.fields = fields_copy;
        return ret;
    end

    return l
end

---@class Logger
---@field log fun(msg: string)
---@field logf fun(fmt: string, ...: any)
---@field with fun(key: string, value: any): Logger
---@field logger fun(dst: string, forceRemoval: boolean?): Logger
---@field dst string -- <internal>

---@return Logger
return newLogger(default_dst)
