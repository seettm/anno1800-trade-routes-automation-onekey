---@alias Coordinate { x: number, y: number }
---@alias CoordinateString string
---@alias AreaID number
---@alias AreaID_str string
---@alias ShipID number

---@class AreaData
---@field city_name string
---@field scan table<CoordinateString, string>
---@field water_points Coordinate[]
---@field capacity number

---

TRADE_ROUTE_AUTOMATION_NAME = "trat_fork"

local function apply(fn, ...)
    local a = { ... }
    return function()
        return fn(table.unpack(a));
    end
end

local function _or(...)
    local funcs = { ... }
    return function()
        for _, f in ipairs(funcs) do
            if f() then
                return true
            end
        end
        return false
    end
end

local function file_exists(path)
    local file = io.open(path, "r")
    if file then
        file:close()
        return true
    end
    return false
end

local function interrupt_on_file(path)
    return function()
        local y = file_exists(path);
        if y then
            os.remove(path);
        end
        return y;
    end
end

local function systemStartXpcall(L, name, fn)
    local _ret = {};
    system.start(function()
        local q = _G[name];
        if q ~= nil then
            print(string.format("%s is already running, skipping duplicate start.", name));
            return ;
        end
        _G[name] = true;
        local ret, err = xpcall(fn, debug.traceback)
        _G[name] = nil;

        if L ~= nil then
            L.logf("%s finished: ret=%s err=%s", name, ret, err)
        end
        print(string.format("%s finished: ret=%s err=%s", name, ret, err))

        table.insert(_ret, { Ret = ret, Err = err });
    end, name)
    return _ret;
end

---

local function getProfileName()
    return ts.Participants.Current.Profile.CompanyName;
end

local function theTradeRouteAutomation()
    systemStartXpcall(nil, TRADE_ROUTE_AUTOMATION_NAME .. "-owner", function()
        :: reset ::

        ---@type string
        local profileName;
        while true do
            profileName = getProfileName();
            if profileName ~= nil and profileName ~= "" then
                break ;
            end

            for _ = 1, 30 do
                coroutine.yield();
            end
        end

        local profileNameSafe = profileName:gsub('%s+', '_');
        local settingsFileName = ts.GameSetup.SettingsFileName;
        local base = nil;
        if type(settingsFileName) == "string" then
            base = settingsFileName:match("^(.*)[/\\]GameSettings[/\\]Setup%.xml$");
        end

        -- [TRAtUI] 动态定位本 mod 的 data 目录。
        --
        -- 历史上这里踩过两次同一个坑：把 mod 文件夹名写死。
        --   1) 原版写死 "TradeRoutesAutomation_DEV"
        --   2) 本分支写死 "TRAtUI_Fork" —— 2026-11-22 把目录改名成
        --      TradeRoutesAutomation_OneKey 之后，这里仍然拼出旧的
        --      ...\mods\TRAtUI_Fork\data\ 并塞进 package.path，而那个目录已经不存在。
        --      后果：require("trat_fork/anno_interface") 立刻失败 → 整个 mod 一行日志都不产生
        --      （base.log 停在上一次运行的时间），而热键层报 module not found。
        --
        -- 现在改成：自身脚本路径 → 已知文件夹名 × 已知根目录 → 枚举 mods 目录。
        -- 只认「该目录下确实存在 trat_fork\_main.lua」的候选，绝不返回未验证的路径。
        local function resolveLuaRoot(baseDir)
            local tried = {};

            local function attempt(candidate)
                if candidate == nil or candidate == "" then
                    return nil;
                end
                tried[#tried + 1] = candidate;
                local f = io.open(candidate .. "trat_fork\\_main.lua", "r");
                if f ~= nil then
                    f:close();
                    print("[TRAtUI] luaRoot resolved to: " .. candidate);
                    return candidate;
                end
                return nil;
            end

            -- 0) 最可靠：脚本自身所在目录（引擎若给绝对路径，一步到位）
            local src = tostring(debug.getinfo(1, "S").source or ""):gsub("^@", "");
            print("[TRAtUI] self source: " .. src);
            local selfDir = src:match("^(.*)[/\\]trat_fork[/\\]_main%.lua$");
            if selfDir ~= nil then
                local r = attempt(selfDir .. "\\");
                if r ~= nil then return r; end
            end

            -- 1) 候选根目录：文档目录（SettingsFileName 推出）+ 游戏安装目录
            local roots = {};
            if baseDir ~= nil then roots[#roots + 1] = baseDir; end
            local gameRoot = package.path:match("^([^;]-)[/\\]Bin[/\\]Win64[/\\]");
            if gameRoot ~= nil then roots[#roots + 1] = gameRoot; end

            -- 2) 已知文件夹名（当前名 + 历史名，后者兼容老用户直接覆盖升级）
            local names = { "TradeRoutesAutomation_OneKey", "TRAtUI_Fork" };
            for _, root in ipairs(roots) do
                for _, name in ipairs(names) do
                    local r = attempt(root .. "\\mods\\" .. name .. "\\data\\");
                    if r ~= nil then return r; end
                end
            end

            -- 3) 最后手段：枚举 mods 目录逐个试。io.popen 可能被禁用，失败就跳过。
            for _, root in ipairs(roots) do
                local modsDir = root .. "\\mods";
                local okPipe, pipe = pcall(io.popen, 'dir /b /ad "' .. modsDir .. '" 2>nul');
                if okPipe and pipe ~= nil then
                    local found = nil;
                    for line in pipe:lines() do
                        local name = line:gsub("%s+$", "");
                        if name ~= "" then
                            found = attempt(modsDir .. "\\" .. name .. "\\data\\");
                            if found ~= nil then break; end
                        end
                    end
                    pcall(function() pipe:close(); end);
                    if found ~= nil then return found; end
                end
            end

            print("[TRAtUI] resolveLuaRoot FAILED, tried:\n  " .. table.concat(tried, "\n  "));
            return nil, tried;
        end

        -- 失败时把线索落到磁盘：这时 logger 还不存在，只能自己开文件写。
        local function boot_note(text)
            local dir = nil;
            if base ~= nil then dir = base .. "\\log"; end
            if dir ~= nil then
                local f = io.open(dir .. "\\TRAtUI_boot.txt", "a");
                if f ~= nil then
                    f:write("[boot] " .. tostring(text) .. "\n");
                    f:close();
                end
            end
        end

        local luaRoot, triedRoots = resolveLuaRoot(base);
        if luaRoot == nil then
            boot_note("luaRoot 解析失败，base=" .. tostring(base) .. "；尝试过："
                    .. table.concat(triedRoots or {}, " | "));
            error("[TRAtUI] unable to resolve mod data directory, base=" .. tostring(base));
        end
        boot_note("luaRoot=" .. tostring(luaRoot));
        local pathEntry = luaRoot .. "?.lua";
        if package.path:find(pathEntry, 1, true) == nil then
            package.path = package.path .. ";" .. pathEntry;
        end

        for k, v in pairs(package.loaded) do
            if type(k) == "string" and k:find(TRADE_ROUTE_AUTOMATION_NAME .. "") == 1 then
                package.loaded[k] = nil;
            end
        end

        local Anno = require(TRADE_ROUTE_AUTOMATION_NAME .. "/anno_interface");
        local inspector = require(TRADE_ROUTE_AUTOMATION_NAME .. "/anno_object_inspector");
        local objectAccessor = require(TRADE_ROUTE_AUTOMATION_NAME .. "/anno_object_accessor");
        local session = require(TRADE_ROUTE_AUTOMATION_NAME .. "/anno_session");

        ---@type Logger
        local L = require(TRADE_ROUTE_AUTOMATION_NAME .. "/utils_logger");
        local serpLight = require(TRADE_ROUTE_AUTOMATION_NAME .. "/serp/lighttools");
        local json = require(TRADE_ROUTE_AUTOMATION_NAME .. "/rxi/json");
        local cache = require(TRADE_ROUTE_AUTOMATION_NAME .. "/utils_cache");
        local base64 = require(TRADE_ROUTE_AUTOMATION_NAME .. "/iskolbin/base64");
        local async = require(TRADE_ROUTE_AUTOMATION_NAME .. "/utils_async");
        local utable = require(TRADE_ROUTE_AUTOMATION_NAME .. "/utils_table");

        local AreasRequest = require(TRADE_ROUTE_AUTOMATION_NAME .. "/mod_area_requests");
        local TradePlannerLL = require(TRADE_ROUTE_AUTOMATION_NAME .. "/mod_trade_planner_ll");
        local TradePlannerHL = require(TRADE_ROUTE_AUTOMATION_NAME .. "/mod_trade_planner_hl");
        local map_scanner = require(TRADE_ROUTE_AUTOMATION_NAME .. "/mod_map_scanner");
        local mapScannerHL = require(TRADE_ROUTE_AUTOMATION_NAME .. "/mod_map_scanner_hl");
        local shipCmd = require(TRADE_ROUTE_AUTOMATION_NAME .. "/mod_ship_cmd");
        local TradeExecutor = require(TRADE_ROUTE_AUTOMATION_NAME .. "/mod_trade_executor");

        local GeneratorProducts = require(TRADE_ROUTE_AUTOMATION_NAME .. "/generator/products");
        GeneratorProducts.Load(L, luaRoot .. TRADE_ROUTE_AUTOMATION_NAME .. "/generator/");

        -- [TRAtUI][v1.9.7] 把「货物 GUID → 名称」摊平到 _G，供热键层拼状态看板。
        -- 热键执行环境未必和这里同一个 module 实例（require 缓存可能不共享），
        -- 直接 require generator/products 在那边可能拿到还没 Load 的空表，
        -- 拼出来的船名就只剩一串数字 GUID。这里一次性导出纯字符串表最稳。
        pcall(function()
            local names = {};
            for guid, info in pairs(GeneratorProducts.Products or {}) do
                if type(info) == "table" and type(info.Name) == "string" then
                    names[tostring(guid)] = info.Name;
                end
            end
            _G["trat_fork_good_names"] = names;
        end);

        local TrRAt_UI = require(TRADE_ROUTE_AUTOMATION_NAME .. "/ui_cmds");
        TrRAt_UI.L = L;

        -- [TRAtUI] base 可能为 nil（SettingsFileName 结构变化时），回退到 luaRoot 的上层目录，
        -- 避免 "attempt to concatenate a nil value" 让整个 mod 起不来。
        local logBase = base;
        if logBase == nil then
            logBase = luaRoot:match("^(.*)[/\\]mods[/\\]") or ".";
        end

        L.__base = logBase .. "\\log\\" .. "TrRAt_" .. profileNameSafe .. "_";
        L = L.logger("base.log");

        cache.baseDir = logBase .. "\\log\\" .. "TrRAt_Cache_" .. profileNameSafe .. "_";

        print(string.format("base=%s luaRoot=%s dst=%s", tostring(logBase), tostring(luaRoot), tostring(L.dst)));

        L.logf("profileName=%s profileNameSafe=%s", tostring(profileName), tostring(profileNameSafe));
        L.logf("settingsFileName=%s base=%s", tostring(settingsFileName), tostring(base));

        -- [TRAtUI] 把日志器暴露到 _G，供热键入口（ui_companion）复用。
        -- 原版 L 只存在于本文件的局部变量里，而 ui_cmds.L 恒为 nil，
        -- 导致 ui_companion 的 say() 全部退化成 print —— 用户在游戏里看不到任何反馈。
        _G["trat_fork_logger"] = L;
        _G["trat_fork_lua_root"] = luaRoot;

        -- [TRAtUI] 启动自检：这一段本身就能证明「模块加载层」是否可用，
        -- 不依赖任何热键。结果同时写日志与探针文件。
        pcall(function()
            local probe = "TRAtUI[] self-check" .. "\n";
            local okc, uic = pcall(require, "trat_fork/ui_companion");
            probe = probe .. "require ui_companion ok=" .. tostring(okc) .. " err=" .. tostring(uic) .. "\n";
            if okc then
                local oks, errs = pcall(uic.Status);
                probe = probe .. "Status ok=" .. tostring(oks) .. " err=" .. tostring(errs) .. "\n";
            end
            L.log(probe);
            local f = io.open(logBase .. "\\log\\TRAtUI_probe.txt", "a");
            if f ~= nil then
                f:write(probe);
                f:write("package.path=" .. tostring(package.path) .. "\n---\n");
                f:close();
            end
        end);

        --------------------------------
        local function async_watcher(L, interrupt)
            local max_ticks = math.huge -- 10000 -- Safety limit
            local tick_count = 0

            while tick_count < max_ticks do
                if interrupt() then
                    L.log("Async watcher received interrupt signal, stopping.");
                    break
                end

                tick_count = tick_count + 1

                -- [TRAtUI][v1.9.7] 心跳时间戳：热键层用它判断「调度器还活着吗」。
                -- 只靠 _G 标志位不够 —— 协程可能活着但卡死在某个 await 里。
                _G["trat_fork_last_tick"] = os.time();
                _G["trat_fork_tick_count"] = tick_count;

                if tick_count % 100 == 0 then
                    local stats = async.tick()
                    L.logf("[Tick %d] Async stats: running=%d, waiting=%d, completed=%d, errors=%d",
                            tick_count, stats.running, stats.waiting, stats.completed, stats.errors)

                    -- 状态看板刷新（约 10 秒一次，每帧都刷太浪费）。
                    -- 船名是这游戏里唯一能「不装 UI 框架就看到」的显示通道。
                    pcall(function()
                        local ui = require("trat_fork/ui_companion");
                        if ui ~= nil and ui.RefreshStatusNames ~= nil then
                            ui.RefreshStatusNames();
                        end
                    end);
                end
                if tick_count % 1000 == 0 then
                    async.cleanup(true)
                end
                coroutine:yield();
            end

            async.cleanup(true)

            local final_stats = async.tick()
            L.logf("Final stats after %d ticks: completed=%d, errors=%d",
                    tick_count, final_stats.completed, final_stats.errors)

            local errored = async.get_tasks_by_state("error")
            if #errored > 0 then
                L.logf("Tasks with errors: %d", #errored)
                for _, task in ipairs(errored) do
                    L.logf("  Task %d error: %s", task.id, task.error)
                end
            end
        end

        local function heartbeat_loop(L, interrupt)
            while true do
                if interrupt() then
                    L.log("Trade executor heartbeat received interrupt signal, stopping.");
                    break
                end

                L.log("Trade executor alive heartbeat at " .. os.date("%Y-%m-%d %H:%M:%S"));
                cache.WriteTo(L.__base .. "trade-executor-history.json", TradeExecutor.Records);

                for i = 1, 1200 do
                    coroutine.yield();
                end
            end
        end

        local asyncInterruptF = interrupt_on_file(TRADE_ROUTE_AUTOMATION_NAME .. "/stop-trade-route-async-watcher");
        local heartbeatInterruptF = interrupt_on_file(TRADE_ROUTE_AUTOMATION_NAME .. "/stop-trade-executor-heartbeat");
        local tradeRouteLoopInterruptOwF = interrupt_on_file(TRADE_ROUTE_AUTOMATION_NAME .. "/stop-trade-route-loop-ow");
        local tradeRouteLoopInterruptNwF = interrupt_on_file(TRADE_ROUTE_AUTOMATION_NAME .. "/stop-trade-route-loop-nw");
        local interruptF = interrupt_on_file(TRADE_ROUTE_AUTOMATION_NAME .. "/stop-trade-routes-automation-owner");

        local profileNameInterrupt = function()
            local b = getProfileName() == profileName;
            return not b;
        end

        local anyThreadFailed;
        local function interruptOnFail()
            return anyThreadFailed ~= nil;
        end

        local enabledInterrupt = function()
            return _G[TRADE_ROUTE_AUTOMATION_NAME .. "_enabled"] ~= true;
        end

        -- [TRAtUI][v1.9.5] 语义统一：和 ui_companion 的 UI.IsEnabled() 保持一致。
        -- UI.IsEnabled() 用 `~= false`（nil 视为开启），而这里原来是 `~= true`（nil 视为关闭）。
        -- 两套判定打架的直接后果：状态显示「自动化=开启」，而调度协程却卡在下面这个
        -- 等待循环里永远不出来 —— 一行日志都没有，玩家只看到船不动。
        if _G[TRADE_ROUTE_AUTOMATION_NAME .. "_enabled"] == false then
            L.log("Trade route automation is disabled, waiting...");
            while true do
                if interruptF() then
                    L.log("Received external interrupt signal, stopping trade route automation.");
                    return ;
                end
                if profileNameInterrupt() then
                    L.log("Profile name changed, restarting trade route automation.");
                    goto reset;
                end

                if _G[TRADE_ROUTE_AUTOMATION_NAME .. "_enabled"] ~= false then
                    goto reset;
                end

                L.log("Trade route automation is disabled, waiting...");
                for _ = 1, 600 do
                    coroutine.yield();
                end
            end
        end

        -- [TRAtUI 关键修复] 绝不能把 enabledInterrupt 放进这些 interrupt 链。
        -- interrupt() 返回 true 时，Loop / async_watcher / heartbeat 会直接 `break` 退出协程，
        -- 而它们由 systemStartXpcall 启动、只在 owner 协程 reset 时才会重新拉起。
        -- 结果是：玩家按一次「关闭自动化」→ 三个协程全部永久死亡 → 再按「开启」也不会重启，
        -- 表现为「UI 都正常、船永远不动」。实测 2026-11-15 18:07:42 三条
        -- "received interrupt signal, stopping" 同时出现，之后再也没有 iteration 日志。
        -- 正确做法：开关只做「暂停」，由 TradePlannerHL.Loop 内部空转让出时间片，
        -- 随时可以把 _G["trat_fork_enabled"] 设回 true 立刻恢复，不需要重进游戏。
        local asyncInterrupt = _or(asyncInterruptF, profileNameInterrupt, interruptOnFail);
        local heartbeatInterrupt = _or(heartbeatInterruptF, profileNameInterrupt, interruptOnFail);
        local tradeRouteLoopInterruptOW = _or(tradeRouteLoopInterruptOwF, profileNameInterrupt, interruptOnFail);
        local tradeRouteLoopInterruptNW = _or(tradeRouteLoopInterruptNwF, profileNameInterrupt, interruptOnFail);

        local ts = {
            systemStartXpcall(L, "trade-route-async-watcher", apply(async_watcher, L, asyncInterrupt)),
            systemStartXpcall(L, "trade-executor-alive-heartbeat", apply(heartbeat_loop, L, heartbeatInterrupt)),
            systemStartXpcall(L, "trade-route-executor-loop-ow", apply(TradePlannerHL.Loop, L, Anno.Region_OldWorld, tradeRouteLoopInterruptOW)),
            systemStartXpcall(L, "trade-route-executor-loop-nw", apply(TradePlannerHL.Loop, L, Anno.Region_NewWorld, tradeRouteLoopInterruptNW)),
        }

        while true do
            if interruptF() then
                anyThreadFailed = true;
                L.log("Received external interrupt signal, stopping trade route automation.");
                return ;
            end
            if profileNameInterrupt() then
                L.log("Profile name changed, restarting trade route automation.");
                anyThreadFailed = true;
                goto reset;
            end

            for _, t in ipairs(ts) do
                for _, v in ipairs(t) do
                    L.logf("Detected error in subtask: ret=%s err=%s", tostring(v.Ret), tostring(v.Err));
                    anyThreadFailed = true;

                    -- let it rest a bit before restarting
                    for _ = 1, 600 do
                        coroutine.yield();
                    end
                    goto reset;
                end
            end

            -- [TRAtUI] 兜底自愈：任何子协程意外退出（被 interrupt 停掉、内部 error 未捕获等），
            -- systemStartXpcall 会把 _G[name] 置回 nil，但 owner 若察觉不到就再也不会重启，
            -- 玩家看到的就是「UI 全部正常、船永远不动」，只能重启游戏。
            -- 这里主动巡检，发现缺口就 reset 重新拉起。
            do
                local missing = nil;
                for _, nm in ipairs({ "trade-route-async-watcher",
                                      "trade-route-executor-loop-ow",
                                      "trade-route-executor-loop-nw" }) do
                    if _G[nm] == nil then
                        missing = nm;
                        break ;
                    end
                end
                if missing ~= nil then
                    L.logf("[TRAtUI] 子协程 %s 已退出，600 帧后重启调度", tostring(missing));
                    for _ = 1, 600 do
                        coroutine.yield();
                    end
                    goto reset;
                end
            end

            for _ = 1, 600 do
                coroutine.yield();
            end
        end
    end);
end

if _G[TRADE_ROUTE_AUTOMATION_NAME .. "_enabled"] == nil then
    _G[TRADE_ROUTE_AUTOMATION_NAME .. "_enabled"] = true;
end
function trat_fork_enable()
    _G[TRADE_ROUTE_AUTOMATION_NAME .. "_enabled"] = true;
    theTradeRouteAutomation();
end
function trat_fork_disable()
    _G[TRADE_ROUTE_AUTOMATION_NAME .. "_enabled"] = false;
end

-- [TRAtUI][v1.9.5] 把「重启整个调度」暴露给热键层。
-- 现场问题：读档 / 脚本重载后，引擎可能把二次触发的 system.start 丢掉，
-- 结果是 owner / Loop / async_watcher 一个都没起来（日志里 [Tick] 一条都没有），
-- 而玩家的热键一切正常。以前这种情况只能重启游戏。
_G["trat_fork_restart"] = theTradeRouteAutomation;

theTradeRouteAutomation();
