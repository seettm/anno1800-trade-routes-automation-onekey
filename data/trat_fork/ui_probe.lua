--- TRAtUI UI 接口探测器（feature/game-ui 分支专用）
---
--- 目的：在写任何 UI 资产之前，先拿到「运行时到底暴露了哪些界面接口」的清单。
--- 之前已实测 5 个通知类 API 全部不可用（日志里的 notify via=none 就是证据），
--- 继续靠猜 API 写代码没有意义，先把清单打出来。
---
--- 产出：<用户目录>\log\TRAtUI_uiprobe.txt
--- 触发：Shift + L  →  ui_companion.ProbeUI()
---
--- 判断标准（见 docs/UI_ASSETS_RESEARCH.md）：
---   ts.Interface 只有 SetUiScreenScaling 这类全局设置 → 原生面板不可行，转建筑名看板
---   出现 AddWidget / CreateWidget / OpenMenu / RegisterGui 一类 → 有戏，继续深挖

local Probe = {};

local MAX_DEPTH = 2;    -- 子表展开层数
local MAX_KEYS  = 240;  -- 单个对象最多列多少成员
local MAX_STR   = 80;   -- 字符串截断长度

local function logf(fmt, ...)
    local g = _G["trat_fork_logger"];
    if g ~= nil and type(g.logf) == "function" then
        pcall(g.logf, g, fmt, ...);
    end
end

--- 与 ui_companion.ensure_cache_base / _main 完全一致的路径推导，
--- 保证探测报告落在玩家真正会去翻的 log 目录里。
local function report_path()
    local ok, p = pcall(function()
        local sn = ts.GameSetup.SettingsFileName;
        if type(sn) ~= "string" then
            return nil;
        end
        local base = sn:match("^(.*)[/\\]GameSettings[/\\]Setup%.xml$");
        if base == nil then
            return nil;
        end
        return base .. "\\log\\TRAtUI_uiprobe.txt";
    end);
    if ok then
        return p;
    end
    return nil;
end

local function fmt_value(v)
    local t = type(v);
    if t == "string" then
        local s = v;
        if #s > MAX_STR then
            s = string.sub(s, 1, MAX_STR) .. "...";
        end
        return "string " .. string.format("%q", s);
    elseif t == "number" then
        return "number " .. tostring(v);
    elseif t == "boolean" then
        return "boolean " .. tostring(v);
    elseif t == "function" then
        return "function";
    elseif t == "table" then
        return "table";
    end
    return t;
end

--- pairs 对 userdata 会抛错，必须 pcall 包住；键排序保证两次报告可 diff。
local function collect_keys(obj)
    local ok, res = pcall(function()
        local list = {};
        for k, v in pairs(obj) do
            list[#list + 1] = { k = k, v = v };
        end
        return list;
    end);
    if not ok then
        return nil, tostring(res);
    end
    table.sort(res, function(a, b)
        return tostring(a.k) < tostring(b.k);
    end);
    return res, nil;
end

local function dump_members(lines, label, obj, depth)
    local kind = type(obj);
    if obj == nil then
        lines[#lines + 1] = string.format("%s = nil（不存在）", label);
        return;
    end
    if kind ~= "table" and kind ~= "userdata" then
        lines[#lines + 1] = string.format("%s = %s", label, fmt_value(obj));
        return;
    end

    local list, err = collect_keys(obj);
    if list == nil then
        lines[#lines + 1] = string.format("%s <%s> 无法枚举：%s", label, kind, tostring(err));
        return;
    end

    lines[#lines + 1] = string.format("%s <%s> 成员数=%d", label, kind, #list);

    local shown = 0;
    for _, e in ipairs(list) do
        if shown >= MAX_KEYS then
            lines[#lines + 1] = string.format("  ... 另有 %d 项未列出", #list - shown);
            break;
        end
        shown = shown + 1;
        lines[#lines + 1] = string.format("  %-42s %s", tostring(e.k), fmt_value(e.v));

        if depth < MAX_DEPTH and type(e.v) == "table" then
            local sub = collect_keys(e.v);
            if sub ~= nil and #sub > 0 and #sub <= 40 then
                for _, se in ipairs(sub) do
                    lines[#lines + 1] = string.format("    .%-40s %s", tostring(se.k), fmt_value(se.v));
                end
            end
        end
    end
end

--- 按 "a.b.c" 路径取值，任何一段不存在都返回 nil 而不抛错。
local function resolve(path)
    local cur = _G;
    for seg in string.gmatch(path, "[^%.]+") do
        if cur == nil then
            return nil;
        end
        local ok, v = pcall(function()
            return cur[seg];
        end);
        if not ok then
            return nil;
        end
        cur = v;
    end
    return cur;
end

local ROOTS = {
    { "ts",           function() return ts end },
    { "ts.Interface", function() return ts.Interface end },
    { "ts.GUI",       function() return ts.GUI end },
    { "ts.Selection", function() return ts.Selection end },
    { "game",         function() return game end },
    { "game.gui",     function() return game.gui end },
};

--- 已知或有传闻的 UI 能力，逐个验证是否存在、是什么类型。
local CANDIDATES = {
    "ts.Interface.SetUiScreenScaling",
    "ts.Interface.GetUiScreenScaling",
    "ts.Interface.AddWidget",
    "ts.Interface.CreateWidget",
    "ts.Interface.ShowMessage",
    "ts.Interface.OpenMenu",
    "ts.Interface.RegisterGui",
    "ts.Interface.CreatePanel",
    "ts.Interface.SetUIElementVisible",
    "ts.GUI.BroadcastNotification",
    "ts.GUI.ShowNotification",
    "game.gui.BroadcastNotification",
    "game.gui.ShowNotification",
};

--- _G 里名字带这些词的键，全部列出来。
local G_PATTERNS = { "gui", "interface", "menu", "hud", "screen", "window", "panel", "widget" };

function Probe.Run()
    local lines = {};
    local function add(s)
        lines[#lines + 1] = s;
    end

    add("TRAtUI UI 接口探测报告");
    add("时间: " .. tostring(os.date("%Y-%m-%d %H:%M:%S")));
    add("版本: " .. tostring(_G["trat_fork_version"] or "unknown"));
    add("");

    add("========== 一、候选能力逐个验证 ==========");
    for _, path in ipairs(CANDIDATES) do
        local v = resolve(path);
        local t = type(v);
        if v == nil then
            add(string.format("  [无] %-42s", path));
        elseif t == "table" or t == "userdata" then
            add(string.format("  [有] %-42s %s（需进一步看成员）", path, t));
        else
            add(string.format("  [有] %-42s %s", path, fmt_value(v)));
        end
    end
    add("");

    add("========== 二、根对象成员清单 ==========");
    for _, root in ipairs(ROOTS) do
        local ok, obj = pcall(root[2]);
        add("");
        if ok then
            dump_members(lines, root[1], obj, 0);
        else
            add(string.format("%s 取值失败：%s", root[1], tostring(obj)));
        end
    end
    add("");

    add("========== 三、_G 中与界面相关的键 ==========");
    local hits = {};
    local okG = pcall(function()
        for k, v in pairs(_G) do
            if type(k) == "string" then
                local lk = string.lower(k);
                for _, p in ipairs(G_PATTERNS) do
                    if string.find(lk, p, 1, true) ~= nil then
                        hits[#hits + 1] = { k = k, v = v };
                        break;
                    end
                end
            end
        end
    end);
    if not okG then
        add("  _G 枚举失败");
    else
        table.sort(hits, function(a, b)
            return tostring(a.k) < tostring(b.k);
        end);
        add(string.format("  命中 %d 个", #hits));
        for _, e in ipairs(hits) do
            add(string.format("  %-42s %s", tostring(e.k), fmt_value(e.v)));
        end
    end;
    add("");

    add("========== 四、怎么读这份报告 ==========");
    add("  1. 先看「一」。若 SetUiScreenScaling 有、AddWidget/CreateWidget/OpenMenu 全无，");
    add("     说明这版游戏没有可编程界面构造能力，原生面板路线作废，转建筑名看板。");
    add("  2. 再看「二」里 ts.Interface 的成员数。数量很少（<30）也佐证上一条。");
    add("  3. 若有意外发现（某个函数名带 Widget/Panel/Menu），把那一行发出来。");

    local txt = table.concat(lines, "\r\n");
    local path = report_path();
    local wrote = false;
    local err = nil;

    if path ~= nil then
        local okWrite, werr = pcall(function()
            local f = io.open(path, "w");
            if f ~= nil then
                f:write(txt);
                f:close();
                wrote = true;
            else
                error("io.open 返回 nil");
            end
        end);
        if not okWrite then
            err = tostring(werr);
        end
    else
        err = "路径推导失败";
    end

    logf("[TRAtUI] UI 探测完成：条目=%d 写入=%s path=%s err=%s",
            #lines, tostring(wrote), tostring(path), tostring(err));

    return wrote, path, err;
end

return Probe;
