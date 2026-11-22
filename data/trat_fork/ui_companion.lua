--- TRAtUI Companion —— 为 Trade Routes Automation 提供「一键」操作入口
---
--- 设计约束（务必遵守，否则会踩 _main.lua 的生命周期坑）：
---   1. 不得在模块级缓存其他模块的实例。_main.lua 每次 reset 会清空
---      package.loaded 里所有 trat_fork* 模块，旧表会变成僵尸。
---      → 一律用 mods() 就地 require，用完即弃。
---   2. 所有耗时动作必须在 system.start 起的协程里执行，并用 _G 单例守卫防重入
---      （原 ui_cmds 无重入保护，连点会出现两个协程抢相机与建造模式）。
---   3. 只做编排。扫描算法（mod_map_scanner*）与调度算法（mod_trade_planner_*）
---      的计算逻辑一行都不改。

local UI = {};

-- 单例守卫键
local BUSY_KEY = "trat_fork_companion_busy";
-- 接管清单所在的全局表：oid(bumber) -> { name = 原船名, region = "OW"/"NW", at = 时间戳 }
-- 放在 _G 而不是模块内，因为模块会被 _main.lua 重新加载。
local TAKEOVER_KEY = "trat_fork_takeover";

-- 单岛扫描分辨率。原 mod 注释推荐 {30, 20, 15}，20 是速度/精度平衡点。
local SCAN_STEP = 20;

---@return table
local function mods()
    return {
        Anno = require("trat_fork/anno_interface"),
        serpLight = require("trat_fork/serp/lighttools"),
        cache = require("trat_fork/utils_cache"),
        MapScannerLL = require("trat_fork/mod_map_scanner"),
        MapScannerHL = require("trat_fork/mod_map_scanner_hl"),
        json = require("trat_fork/rxi/json"),
    };
end

--- 保证扫描缓存有落盘目录。
---
--- _main.lua 是在自己的 Lua 作用域里给 utils_cache 赋 baseDir 的。如果热键执行环境
--- 是另一个 Lua state（Anno 的触发器 / 控制台确实可能是），那么这里的 utils_cache
--- 是另一个实例，baseDir 为 nil → 每次 cache.Set 都会在拼路径时抛
--- "attempt to concatenate a nil value"，被 pcall 吞掉，表现为
--- 「扫描说成功、实际一个缓存都没写、调度器永远等不到数据」。
--- 路径推导与 _main.lua 完全一致，保证两边指向同一批文件。
local function ensure_cache_base()
    local okAll, err = pcall(function()
        local cache = require("trat_fork/utils_cache");
        if cache.baseDir ~= nil then
            return;
        end

        local sn = ts.GameSetup.SettingsFileName;
        if type(sn) ~= "string" then
            return;
        end
        local base = sn:match("^(.*)[/\\]GameSettings[/\\]Setup%.xml$");
        if base == nil then
            return;
        end

        local pname = "unknown";
        pcall(function()
            local n = ts.Participants.Current.Profile.CompanyName;
            if type(n) == "string" and n ~= "" then
                pname = n;
            end
        end);
        pname = pname:gsub("%s+", "_");

        cache.baseDir = base .. "\\log\\TrRAt_Cache_" .. pname .. "_";
    end);
    if not okAll then
        print("[TRAtUI] ensure_cache_base failed: " .. tostring(err));
    end
end

---------------------------------------------------------------------
-- 接管清单的持久化
--
-- 清单本身是「玩家-owned 的运行时状态」，原版靠贸易航线名承载（随存档走）。
-- Fork 取消了航线依赖，就必须自己落盘，否则每次读档都要重新点一遍。
--
-- 键统一用 tostring(oid)：JSON 对象键只能是字符串，混用数字键会在重载后
-- 静默失配（list[123] 查不到 "123"），表现为「清单里有船但 planner 不认」。
---------------------------------------------------------------------

local function takeover_path()
    local sn = ts.GameSetup.SettingsFileName;
    if type(sn) == "string" then
        local base = sn:match("^(.*)[/\\]GameSettings[/\\]Setup%.xml$");
        if base ~= nil then
            return base .. "\\log\\TRAtUI_takeover.json";
        end
    end
    return "TRAtUI_takeover.json";
end

local function load_takeover()
    local ok, f = pcall(io.open, takeover_path(), "r");
    if not ok or f == nil then
        return nil;
    end
    local content = f:read("*a");
    f:close();
    if content == nil or content == "" then
        return nil;
    end

    local M = mods();
    local okDecode, decoded = pcall(M.json.decode, content);
    if not okDecode or type(decoded) ~= "table" then
        return nil;
    end

    local ret = {};
    for k, v in pairs(decoded) do
        local key = tostring(k);
        if v == true then
            ret[key] = { name = nil };
        elseif type(v) == "table" then
            ret[key] = v;
        end
    end
    return ret;
end

local function save_takeover(list)
    local M = mods();
    local okEncode, content = pcall(M.json.encode, list);
    if not okEncode or content == nil then
        return false;
    end
    local ok, f = pcall(io.open, takeover_path(), "w");
    if not ok or f == nil then
        return false;
    end
    f:write(content);
    f:close();
    return true;
end

--- 日志器解析顺序：
---   1. _G["trat_fork_logger"] —— _main.lua 初始化后挂上去的真日志器，会落盘
---   2. tratt_fork/ui_cmds 导出的 L —— 实测恒为 nil（该模块只声明不赋值），保留兼容
---   3. print 降级
local function logger()
    local g = _G["trat_fork_logger"];
    if g ~= nil and type(g.logf) == "function" then
        return g;
    end

    local ok, TrRAt = pcall(require, "trat_fork/ui_cmds");
    if ok and TrRAt ~= nil and TrRAt.L ~= nil and type(TrRAt.L.logf) == "function" then
        return TrRAt.L;
    end

    return {
        log = function(_, s) print("[TRAtUI] " .. tostring(s)); end,
        logf = function(_, fmt, ...) print("[TRAtUI] " .. string.format(fmt, ...)); end,
    };
end

--- 游戏内屏幕提示（不是日志）。
---
--- 【为什么需要它】玩家不可能一边玩一边 tail 日志。之前只有 say() 写文件，
--- 于是 Shift+K 明明查到了状态、Shift+O 明明执行了，玩家屏幕上一个字也没有，
--- 主观感受就是"按了没反应"。日志实锤：两条键的 probe 都是 ok=true。
---
--- 【为什么不写死一个 API】Anno 各版本提示接口位置不统一，写死
--- game.gui.BroadcastNotification 一旦不存在就静默失效（旧代码还有个
--- "失败一次就永久放弃"的开关，把问题放大成完全无反馈）。
--- 这里改成候选列表逐个试、谁成功就记住谁，并把结果写进日志——
--- 全都不行时日志会留下 notify via=none 这条明确证据，不必再猜。
local NOTIFY_CANDIDATES = {
    { name = "game.gui.BroadcastNotification", fn = function(m) game.gui.BroadcastNotification(m); end },
    { name = "game.gui.ShowNotification",      fn = function(m) game.gui.ShowNotification(m); end },
    { name = "game.gui.Notify",                fn = function(m) game.gui.Notify(m); end },
    { name = "ts.GUI.BroadcastNotification",   fn = function(m) ts.GUI.BroadcastNotification(m); end },
    { name = "gui.BroadcastNotification",      fn = function(m) gui.BroadcastNotification(m); end },
};

--- nil = 尚未探测；false = 全部不可用；function = 已验证可用
local _notifyImpl = nil;

local function notify(msg)
    msg = tostring(msg);
    local L = logger();

    if _notifyImpl == false then
        return;
    end

    if _notifyImpl == nil then
        for _, cand in ipairs(NOTIFY_CANDIDATES) do
            local ok = pcall(cand.fn, msg);
            if ok then
                _notifyImpl = cand.fn;
                L.logf("[TRAtUI] notify via=%s", cand.name);
                return;
            end
        end
        _notifyImpl = false;
        L.logf("[TRAtUI] notify via=none（所有提示 API 都不可用，反馈只落日志）");
        return;
    end

    if not pcall(_notifyImpl, msg) then
        -- 运行中失效（切场景后 GUI 重建）：退回重探测，别永久失声
        _notifyImpl = nil;
    end
end

--- 统一的用户反馈出口。
--- 走了降级日志器时（无 dst）额外直接写探针文件，避免"按键有反应但什么都看不见"。
local function say(msg)
    local L = logger();
    L.logf("[TRAtUI] %s", tostring(msg));
    print("[TRAtUI] " .. tostring(msg));
    notify(msg);

    if L.dst == nil then
        local dst = nil;
        local root = _G["trat_fork_lua_root"];
        if type(root) == "string" then
            local logBase = root:match("^(.*)[/\\]mods[/\\]");
            if logBase ~= nil then
                dst = logBase .. "\\log\\TRAtUI_probe.txt";
            end
        end
        dst = dst or "TRAtUI_probe.txt";

        local ok, f = pcall(io.open, dst, "a");
        if ok and f ~= nil then
            f:write("[TRAtUI] " .. tostring(msg) .. "\n");
            f:close();
        end
    end
end

---@return table
function UI.TakeOverList()
    local list = _G[TAKEOVER_KEY];
    if list == nil then
        -- 首次访问时从磁盘恢复（读档后不必重新接管）
        list = load_takeover() or {};
        _G[TAKEOVER_KEY] = list;
    end
    return list;
end

function UI.IsManaged(oid)
    local list = UI.TakeOverList();
    return list[tostring(oid)] ~= nil;
end

---------------------------------------------------------------------
-- [v1.12.0] 航线舰队：把「挂在 TRA_<区域>[_A|_B] 航线上的船」自动纳入接管清单
--
-- 游戏没有开放「用 Lua 创建航线」的接口（原版作者 kr3v 也是让玩家手工建
-- 一条 TRA_OW 假航线），所以这里不做创建，只做纳管：
--   玩家把船拖进 TRA_OW_A / TRA_OW_B → 下一次调度迭代自动接管，无需 Shift+O
--   玩家把船拖出航线            → 自动释放，不再接单
--   手动 Shift+O 接管的船        → 标记 manual，拖出航线也不会被释放
---------------------------------------------------------------------

--- 舰队分布统计。
---   A / B = 两条模板航线，ALL = 无后缀的单条航线（原版写法），M = 手动接管
---@return table { A=number, B=number, ALL=number, M=number, total=number }
function UI.FleetSummary()
    local s = { A = 0, B = 0, ALL = 0, M = 0, total = 0 };
    for _, v in pairs(UI.TakeOverList()) do
        s.total = s.total + 1;
        local fleet = (type(v) == "table") and v.fleet or nil;
        if fleet == "A" or fleet == "B" then
            s[fleet] = s[fleet] + 1;
        elseif fleet == "ALL" then
            s.ALL = s.ALL + 1;
        elseif type(v) == "table" and v.manual then
            s.M = s.M + 1;
        else
            -- 老版本清单（v1.11.x 及以前）没有 fleet 字段，按手动接管算
            s.M = s.M + 1;
        end
    end
    return s;
end

--- 把一艘航线船纳入接管清单。
---@param oid number
---@param region string
---@param fleet string|nil "A" / "B" / "ALL"
---@param manual boolean|nil 玩家手动接管（拖出航线也不释放）
---@return boolean isNew 本次是否新增
function UI.AdoptShip(oid, region, fleet, manual)
    local list = UI.TakeOverList();
    local key = tostring(oid);
    local cur = list[key];

    if type(cur) == "table" then
        local dirty = false;
        if fleet ~= nil and cur.fleet ~= fleet then
            cur.fleet = fleet;
            dirty = true;
        end
        if manual and not cur.manual then
            cur.manual = true;
            dirty = true;
        end
        if dirty then
            save_takeover(list);
        end
        return false;
    end

    list[key] = {
        region = region,
        at = os.time(),
        fleet = fleet,
        manual = manual and true or false,
    };
    save_takeover(list);
    return true;
end

--- 船已经不在 TRA_* 航线上时，把「由航线纳管进来」的那部分释放掉。
---
--- 关键保护：只动 fleet 不为空的条目。
---   · 手动 Shift+O 接管的船（fleet=nil）→ 永远不会被航线同步误释放
---   · v1.11.x 及更早写下的旧清单没有 fleet 字段 → 同样不动，
---     否则玩家升级后会突然丢掉全部手动接管的船
---@return boolean released
function UI.ReleaseIfAuto(oid)
    local list = UI.TakeOverList();
    local key = tostring(oid);
    local cur = list[key];
    if type(cur) ~= "table" then
        return false;
    end
    if cur.manual then
        return false;
    end
    if cur.fleet == nil then
        return false;
    end
    list[key] = nil;
    save_takeover(list);
    return true;
end

function UI.IsBusy()
    return _G[BUSY_KEY] == true;
end

local function region_supported(region)
    local M = mods();
    return region == M.Anno.Region_OldWorld or region == M.Anno.Region_NewWorld;
end

--- 在协程里跑一个动作，带重入守卫与错误捕获。
local function run_action(name, fn)
    if _G[BUSY_KEY] == true then
        say("上一个操作还在进行中，请稍候再试。");
        return false;
    end
    _G[BUSY_KEY] = true;

    system.start(function()
        local ok, err = xpcall(fn, debug.traceback);
        _G[BUSY_KEY] = nil;
        if not ok then
            -- 成功路径由各动作自己 say 具体结果（"新扫 2 座 / 跳过 0 座"），
            -- 这里只补错误，避免出现「已中止」后面又跟一句「完成」。
            say(string.format("%s 执行失败：%s", name, tostring(err)));
        end
    end, "trat_fork_companion_" .. name);

    return true;
end

--- 记下玩家当前所在岛屿的 OID，供扫描结束后把镜头拉回去。
--- 引擎没有「读取相机世界坐标」的接口（CSessionCameraManager 只有 ToWorldPos 设置器），
--- 所以只能用「当前岛屿」做近似还原。
local function remember_camera_anchor()
    -- [TRAtUI] 整段 pcall：这一步只是"扫完把镜头拉回去"的锦上添花，
    -- 任何失败都不该阻断扫描本体。上一次实测就是在这里抛
    -- "no matching overload found"，把整次扫描带走了。
    local ok, oid = pcall(function()
        local M = mods();
        local areaID = M.serpLight.AreatableToAreaID(ts.Area.Current.ID);
        if areaID == nil then
            return nil;
        end
        local mapping = M.Anno.Region_AreaID_To_OID(M.Anno.Region_Current());
        if mapping == nil then
            return nil;
        end
        return tonumber(mapping[tostring(areaID)]);
    end);
    if not ok then
        return nil;
    end
    return oid;
end

local function restore_camera_anchor(oid)
    if oid == nil then
        return;
    end
    pcall(function()
        ts.SessionCamera.CheatToGameObject(oid);
    end);
end

---------------------------------------------------------------------
-- 一键扫描
---------------------------------------------------------------------

--- 扫描当前区域内全部我方岛屿，并把结果写进原 mod 的缓存格式。
---@param force boolean|nil 已缓存时是否强制重扫
function UI.ScanRegion(force)
    ensure_cache_base();
    run_action("扫描区域", function()
        ensure_cache_base();
        local M = mods();
        local L = logger();
        local region = M.Anno.Region_Current();

        if not region_supported(region) then
            say("当前区域不支持自动化（仅旧世界 / 新世界）。");
            return;
        end

        -- 1) 确保「区域 → 岛屿包围盒」网格存在。没有就先建，这一步会切镜头。
        -- 每一步都隔离，任何一个环节抛错都不要带走整次扫描。
        local anchor = remember_camera_anchor();

        local okGet, areas = pcall(M.MapScannerHL.Region_AllAreas_Get, region);
        if not okGet then
            L.logf("[TRAtUI] Region_AllAreas_Get 失败：%s", tostring(areas));
            areas = nil;
        end

        -- 缓存存在但内容为空 = 上一次扫描没采到任何城（多半在错误的区域扫的），
        -- 当作没有网格处理，强制重建一次。
        if areas ~= nil and next(areas) == nil then
            L.logf("[TRAtUI] 区域网格缓存为空，按未建立处理");
            areas = nil;
        end

        if areas == nil then
            say("首次运行，正在建立区域网格（约 10 秒，画面会跳动，请勿操作）…");
            local okScan, result = pcall(M.MapScannerHL.Region_AllAreas_ForceScan, region);
            if okScan then
                areas = result;
            else
                L.logf("[TRAtUI] 区域网格扫描失败：%s", tostring(result));
                areas = nil;
            end
            restore_camera_anchor(anchor);
        end

        if areas == nil then
            say("区域网格建立失败，已中止。");
            return;
        end

        -- 2) 收集我方岛屿
        -- 逐岛打印归属：owner=nil 表示没认出来（接口问题），owner=数字表示别人/中立。
        -- 这一行是「明明有两座岛却只扫了一座」类问题的唯一现场证据。
        local targets = {};
        local totalAreas, unknownOwner = 0, 0;
        for areaID in pairs(areas) do
            totalAreas = totalAreas + 1;
            local ok, owner = pcall(M.Anno.Area_Owner, region, areaID);
            local okName, name = pcall(M.Anno.Area_CityName, region, areaID);
            local probe = "";
            pcall(function() probe = tostring(M.Anno.Area_Owner_Probe(areaID) or ""); end);
            L.logf("[TRAtUI]   岛 %s (areaID=%s owner=%s via=%s)",
                    tostring(okName and name or "?"),
                    tostring(areaID),
                    tostring(ok and owner or "err"),
                    probe);
            if not ok or owner == nil then
                unknownOwner = unknownOwner + 1;
            elseif owner == 0 then
                targets[#targets + 1] = areaID;
            end
        end

        L.logf("[TRAtUI] 网格内共 %d 座岛，其中归属无法识别 %d 座，判定为我方 %d 座",
                totalAreas, unknownOwner, #targets);

        if #targets == 0 then
            if unknownOwner > 0 then
                say(string.format("扫描到 %d 座岛，但一座也没能确认是你的（归属接口返回空）。详情见日志。", totalAreas));
            else
                say("当前区域没有找到属于你的岛屿。");
            end
            return;
        end

        table.sort(targets);
        L.logf("[TRAtUI] 本区域我方岛屿 %d 座，开始扫描（step=%d）", #targets, SCAN_STEP);

        -- 3) 逐岛扫描
        local scanned, skipped, failed = 0, 0, 0;
        for index, areaID in ipairs(targets) do
            local grid = areas[areaID];
            local cityName = "area_" .. tostring(areaID);
            local okName, name = pcall(M.Anno.Area_CityName, region, areaID);
            if okName and name ~= nil and name ~= "" then
                cityName = name;
            end

            if type(grid) ~= "table" then
                failed = failed + 1;
                L.logf("[TRAtUI] (%d/%d) %s 没有包围盒，跳过", index, #targets, cityName);
            else
                local okCached, cached = pcall(M.MapScannerHL.Area.WaterPoints.IsCached,
                        L, areas, region, areaID, SCAN_STEP);
                if not okCached then
                    cached = false;
                end
                if cached and not force then
                    skipped = skipped + 1;
                    L.logf("[TRAtUI] (%d/%d) %s 已有缓存，跳过", index, #targets, cityName);
                else
                    L.logf("[TRAtUI] (%d/%d) 正在扫描 %s …", index, #targets, cityName);
                    local ok, scan = pcall(function()
                        return M.MapScannerLL.Area_WaterPoints(
                                L, grid.min_x, grid.min_y, grid.max_x, grid.max_y, SCAN_STEP);
                    end);

                    if ok and type(scan) == "table" then
                        -- 只写 planner 真正会读的那一种键：(region, areaID, step)。
                        -- 原版还写了一份 (region名, 岛屿名, step字符串)，那条线路没有任何
                        -- 读取方，纯属垃圾文件，而且 cityName 为 nil 时会写成 "nil"。
                        local okSet = pcall(M.cache.Set, "areaScanner_dfs", function() return scan; end,
                                region, areaID, SCAN_STEP);
                        if not okSet then
                            failed = failed + 1;
                            L.logf("[TRAtUI] %s 扫描成功但写缓存失败（磁盘/目录问题）", cityName);
                        else
                            scanned = scanned + 1;
                        end
                    else
                        failed = failed + 1;
                        L.logf("[TRAtUI] %s 扫描失败：%s", cityName, tostring(scan));
                    end
                end
            end
        end

        restore_camera_anchor(anchor);
        say(string.format("扫描结束：新扫 %d 座 / 跳过 %d 座 / 失败 %d 座。",
                scanned, skipped, failed));
    end);
end

---------------------------------------------------------------------
-- 一键接管（等价于「一键创建航线」）
---------------------------------------------------------------------

--- 从任意「选中对象」里榨出 oid。
---
--- 【为什么不能只用 get_OID】
--- ts.Selection.Object 不是裸 GameObject，它的 :getName() 常常是
--- "CSelectionObject"/"Selection"之类，**不含 "oid N"**，于是
--- serpLight.get_OID() 的正则匹配失败、返回 nil ——
--- 这就是「按 Shift+O 只得到『无法识别选中的对象』」的真正原因（日志已实锤）。
---
--- 真正的 oid 藏在 obj.GUID 里，那是一个 OIDtable：
---   { ObjectID = ..., AreaID = ..., EditorFlag = ..., EditorChunkID = ... }
--- lighttools 自己判断「选中对象属于谁」时用的就是 ts.Selection.Object.GUID.Owner，
--- 说明这条属性是可靠的。OIDtableToOID() 负责把它拼回完整 oid。
---
---@return number|nil oid, string via   via 仅用于诊断日志
local function oid_from_object(obj, M, depth)
    if obj == nil then
        return nil, "nil";
    end
    depth = depth or 0;
    if depth > 2 then
        return nil, "depth>2";
    end

    -- 1) obj.GUID —— OIDtable（首选，最可靠）
    --    注意：GUID 可能是 Lua table，也可能是引擎 userdata。
    --    不能只判 type == "table"，否则 userdata 形态会被整条跳过。
    local okG, guid = pcall(function() return obj.GUID; end);
    if okG and guid ~= nil then
        if type(guid) == "number" then
            if guid > 0 then
                return guid, "GUID(number)";
            end
        else
            -- 1a) 直接交给 OIDtableToOID（table 形态走这条）
            local okC, oid = pcall(M.serpLight.OIDtableToOID, guid);
            if okC then
                oid = tonumber(oid);
                if oid ~= nil and oid > 0 then
                    return oid, "GUID";
                end
            end

            -- 1b) userdata 形态：把字段抠出来重组成 Lua table 再拼
            local okId, objId = pcall(function() return guid.ObjectID; end);
            objId = (okId and (type(objId) == "number" or type(objId) == "string")) and tonumber(objId) or nil;
            if objId ~= nil and objId > 0 then
                local packed = { ObjectID = objId };
                local okAr, arId = pcall(function() return guid.AreaID; end);
                if okAr and arId ~= nil then
                    packed.AreaID = arId;
                end
                local okC2, oid2 = pcall(M.serpLight.OIDtableToOID, packed);
                if okC2 then
                    oid2 = tonumber(oid2);
                    if oid2 ~= nil and oid2 > 0 then
                        return oid2, "GUID(ObjectID=" .. tostring(objId) .. ")";
                    end
                end
            end
        end
    end

    -- 2) 直接暴露的 oid 字段（容忍字符串形态的大数）
    for _, field in ipairs({ "OID", "ObjectID", "ID" }) do
        local okF, v = pcall(function() return obj[field]; end);
        local n = (okF and (type(v) == "number" or type(v) == "string")) and tonumber(v) or nil;
        if n ~= nil and n > 0 then
            return n, field;
        end
    end

    -- 3) 名字正则：普通 GameObject（船本体、建筑）走这条
    local okO, oid = pcall(M.serpLight.get_OID, obj);
    if okO then
        oid = tonumber(oid);
        if oid ~= nil and oid > 0 then
            return oid, "getName()";
        end
    end

    -- 4) 嵌套一层：selection wrapper 里裹着真正的 GameObject
    local okI, inner = pcall(function() return obj.Object; end);
    if okI and inner ~= nil and inner ~= obj then
        local oid2, via2 = oid_from_object(inner, M, depth + 1);
        if oid2 ~= nil then
            return oid2, "Object." .. via2;
        end
    end

    return nil, "unknown";
end

--- 该 oid 是否在当前区域的船只清单里。
--- 清单来自磁盘缓存，刚造出来 / 刚开进本区域的船不在里面，
--- 所以未命中时主动失效重算一次（cached_miss 记录是否已经算过，避免循环里重复算）。
local function region_has_ship(M, region, oid, already_refreshed)
    local function contains(list, want)
        for _, shipOid in pairs(list or {}) do
            if tonumber(shipOid) == want then
                return true;
            end
        end
        return false;
    end

    local ships = M.Anno.Region_Ships_GetAll(region);
    if contains(ships, oid) then
        return true;
    end
    if already_refreshed then
        return false;
    end

    pcall(M.cache.Remove, "Anno.Ships_GetAll", region);
    return contains(M.Anno.Region_Ships_GetAll(region), oid);
end

---------------------------------------------------------------------
-- 船名状态标记 —— 唯一真正「看得见」的反馈通道
--
-- 【为什么必须这么做】Anno 1800 **没有屏幕提示 API**。官方 modding 文档明确：
-- print 只写进游戏控制台（而且要装 console mod 才看得到），
-- 没有任何 Lua 接口能直接往屏幕上弹字。
-- 实测 game.gui.BroadcastNotification / ShowNotification / Notify /
-- ts.GUI.* / gui.* 五条全部不可用（日志 notify via=none）。
--
-- 但 Nameable.SetName() 对本地玩家是「即时生效」的（官方文档原话），
-- 而船名是屏幕上一直显示的东西 —— 所以用它同时做两件事：
--   1) 操作成功的即时确认
--   2) 长期状态标记（哪些船被托管、自动化是开还是关）
-- 释放时会精确还原成玩家原本的船名。
---------------------------------------------------------------------

-- 前缀里**绝不能出现方括号**：船名是作为参数嵌进文本嵌入命令串的
-- （[MetaObjects ... Nameable Name(<船名>)]），而 `[` `]` 会被解析器当成
-- 嵌套嵌入，直接把整条命令打坏、改名静默失败。同理避开 `(|)`。
local NAME_TAG_ON    = "TRA_";
local NAME_TAG_OFF   = "TRA-OFF_";
local NAME_TAG_ALL   = { NAME_TAG_OFF, NAME_TAG_ON };  -- 长的在前，避免误剥

--- 去掉可能已经存在的状态标记，拿到玩家原本的船名。
local function strip_name_tag(name)
    if type(name) ~= "string" then
        return nil;
    end
    for _, tag in ipairs(NAME_TAG_ALL) do
        if string.sub(name, 1, #tag) == tag then
            return string.sub(name, #tag + 1);
        end
    end
    return name;
end

--- 给一艘船打上状态标记（保留原名）。默认开启，可用 _G["trat_fork_name_tag"]=false 关掉。
local function apply_name_tag(M, oid, originalName, enabled)
    if _G["trat_fork_name_tag"] == false then
        return;
    end
    local tag = enabled and NAME_TAG_ON or NAME_TAG_OFF;
    local base = strip_name_tag(originalName) or "";
    pcall(function()
        M.Anno.Ship_Name_Set(oid, tag .. base);
    end);
end

--- 取当前选中的船的 oid。返回 nil + 原因。
---@return number|nil oid, string|nil err, string|nil via
local function selected_ship_oid()
    local M = mods();
    local L = logger();
    local region = M.Anno.Region_Current();

    -- 收集所有可能的「选中对象」来源，逐个试。
    -- Anno 的选中态有多条通道，不同版本/不同 UI 状态下哪条有值不确定。
    local candidates = {};
    local function push(obj, label)
        if obj ~= nil then
            candidates[#candidates + 1] = { obj = obj, label = label };
        end
    end

    local ok1, obj = pcall(function() return ts.Selection.Object; end);
    if ok1 then
        push(obj, "ts.Selection.Object");
    end

    local ok2, objs = pcall(function() return ts.Selection.Objects; end);
    if ok2 and objs ~= nil then
        -- 这个 vector 既可能 0 基也可能 1 基，两个都试
        local okA, a = pcall(function() return objs[0]; end);
        if okA then
            push(a, "ts.Selection.Objects[0]");
        end
        local okB, b = pcall(function() return objs[1]; end);
        if okB and (not okA or b ~= a) then
            push(b, "ts.Selection.Objects[1]");
        end
    end

    -- 引擎自带的「选中了什么」查询（anno_session.lua 也导出了它）
    local ok3, fac = pcall(function() return session.getSelectedFactory(); end);
    if ok3 then
        push(fac, "session.getSelectedFactory()");
    end

    if #candidates == 0 then
        return nil, "请先在游戏里选中一艘船。";
    end

    local refreshed = false;
    local lastReject = nil;

    for _, c in ipairs(candidates) do
        local oid, via = oid_from_object(c.obj, M);
        if oid ~= nil then
            if region_has_ship(M, region, oid, refreshed) then
                L.logf("[TRAtUI] 选中识别成功：%s via=%s oid=%s", c.label, via, tostring(oid));
                return oid, nil, c.label .. "/" .. via;
            end
            refreshed = true;
            L.logf("[TRAtUI] 候选 %s via=%s 得到 oid=%s，但不是本区域（%s）的船",
                    c.label, via, tostring(oid), tostring(region));
            lastReject = c.label .. "/" .. via .. " -> oid=" .. tostring(oid) .. " 不在船只清单";
        else
            L.logf("[TRAtUI] 候选 %s 取不到 oid（%s）", c.label, tostring(via));
        end
    end

    -- 全军覆没：把第一个候选的原始形态 dump 进日志。
    -- 这一条是下一次定位问题的唯一凭据，不要省。
    local head = candidates[1];
    if head ~= nil then
        local okN, nm = pcall(function() return head.obj:getName(); end);
        L.logf("[TRAtUI] 诊断 选中对象 %s type=%s getName=%s",
                head.label, type(head.obj), tostring(okN and nm or "ERR"));
        for _, f in ipairs({ "GUID", "ObjectID", "AreaID", "OID", "ID", "Object", "Owner" }) do
            local okV, v = pcall(function() return head.obj[f]; end);
            L.logf("[TRAtUI]   属性 %-10s -> %s", f, tostring(okV and v or "ERR"));
        end
    end

    return nil, "无法识别选中的对象（" .. tostring(lastReject or "所有探测路径均失败") .. "）。";
end

function UI.TakeOverSelected()
    ensure_cache_base();
    local M = mods();
    local region = M.Anno.Region_Current();
    if not region_supported(region) then
        say("当前区域不支持自动化（仅旧世界 / 新世界）。");
        return;
    end

    local oid, err = selected_ship_oid();
    if oid == nil then
        say(err or "无法识别选中的对象。");
        return;
    end

    if UI.IsManaged(oid) then
        -- 已经在清单里（例如上个版本接管过、当时还没有船名标记功能）：
        -- 顺手把看板和标记补上，再按一次 O 就能看到船名变化。
        pcall(UI.RefreshStatusNames);
        say(string.format("这艘船已经在自动化列表里了（船名已同步为「%s」）。",
                tostring(_G["trat_fork_status_name"] or "")));
        return;
    end

    local isMoving = M.Anno.Ship_IsMoving(oid);
    if isMoving then
        say("这艘船正在航行，请等它停稳后再接管。");
        return;
    end

    local hasCargo = false;
    local okCargo, cargo = pcall(M.Anno.Ship_Cargo_Get, oid);
    if okCargo and cargo ~= nil then
        for _, item in pairs(cargo) do
            if item ~= nil and (item.Value or 0) > 0 then
                hasCargo = true;
                break;
            end
        end
    end

    local list = UI.TakeOverList();
    local originalName = nil;
    pcall(function() originalName = M.Anno.Ship_Name_Get(oid); end);

    -- 存「玩家原本的船名」，不含状态标记；重复接管时也不会把标记叠起来
    originalName = strip_name_tag(originalName);

    list[tostring(oid)] = {
        name = originalName,
        region = region,
        at = os.time(),
    };
    save_takeover(list);

    -- 立刻改名 —— 这是玩家唯一能"看见"的确认（没有屏幕提示 API）。
    -- v1.9.7 起船名不再只是 "TRA_+原名"，而是整块状态看板：
    --   TRA_运行_2艘_Wood200 / TRA_待扫描_2艘 / TRA_已停止_2艘
    pcall(UI.RefreshStatusNames);

    say(string.format("已接管船只 oid=%s（原名：%s），船名已改为「%s」。%s",
            tostring(oid),
            tostring(originalName or "未知"),
            tostring(_G["trat_fork_status_name"] or ""),
            hasCargo and " 注意：货舱里有货，调度时会先强制卸货。" or ""));

    -- 不需要额外通知调度器：planner 每轮迭代都会 Region_RefreshCache，
    -- 船列表本来就会重新枚举（这里原先把一个没人读的 _G 标记当真了）。
end

---------------------------------------------------------------------
-- 一键释放（等价于「一键删除航线」）
---------------------------------------------------------------------

function UI.ReleaseAll()
    local M = mods();
    local list = UI.TakeOverList();
    local count = 0;

    -- 先收集键再删除：pairs 期间改动表可能漏项。
    local keys = {};
    for k in pairs(list) do
        keys[#keys + 1] = k;
    end

    for _, k in ipairs(keys) do
        local info = list[k];
        local oid = tonumber(k);
        if oid ~= nil then
            -- 还原玩家原本的船名（去掉 [TRA] / [TRA-OFF] 前缀）
            local restore = strip_name_tag(info and info.name);
            if restore == nil or restore == "" then
                -- 旧版清单没存原名：退而从当前船名里剥掉标记
                pcall(function()
                    restore = strip_name_tag(M.Anno.Ship_Name_Get(oid));
                end);
            end
            if restore ~= nil and restore ~= "" then
                pcall(function() M.Anno.Ship_Name_Set(oid, restore); end);
            end
        end
        list[k] = nil;
        count = count + 1;
    end

    _G[TAKEOVER_KEY] = {};
    save_takeover({});
    say(string.format("已释放 %d 艘船，自动化不再接管它们。", count));
end

---------------------------------------------------------------------
-- 状态
---------------------------------------------------------------------

--- 自动化总开关。
---
--- 【语义】`_G["trat_fork_enabled"]` 就是原版 `trat_fork_enable()` / `trat_fork_disable()`
--- 操作的那个变量（TRADE_ROUTE_AUTOMATION_NAME == "trat_fork"）。
--- 默认「开启」：只有玩家显式按过 Shift+U 才会变成关闭，没动过 = 正常工作。
function UI.IsEnabled()
    return _G["trat_fork_enabled"] ~= false;
end

---------------------------------------------------------------------
-- 状态看板（v1.9.7）
--
-- 约束：这版游戏没有任何可用的屏幕提示 API（实测 5 条候选全失败），
-- 所以「不用装 UI 框架就能看见」的通道只有一个 —— 船名。
-- 所有被托管的船统一显示同一块看板，看一行就知道全部：
--
--   TRA_运行_3艘_Wood200   调度在跑，接管 3 艘，最大缺口是木材 200
--   TRA_运行_3艘_平衡      调度在跑，两岛之间已经不需要调货
--   TRA_待扫描_3艘         区域网格还没建（按 Shift+P）
--   TRA_已停止_3艘         调度协程没了（按 Shift+K 会尝试就地复活）
--   TRA_卡住_3艘           协程还在，但 90 秒没有心跳（多半卡在等船）
--   TRA_已关闭_3艘         自动化开关被关了（按 Shift+U）
---------------------------------------------------------------------

local VIEW_MAX_GOODS = 5;   -- Shift+K / 状态文件里最多列几种货
local NAME_MAX_GOOD  = 8;   -- 船名里货物名的最大长度

--- GUID → 货物名。名字里必须去掉会打坏文本嵌入命令的字符（[ ] ( ) |）。
---@param maxLen number|nil 截断长度；nil = 不截断（明细用）
local function good_display_name(guid, maxLen)
    local map = _G["trat_fork_good_names"];
    local name = nil;
    if type(map) == "table" then
        name = map[tostring(guid)];
    end
    if type(name) ~= "string" or name == "" then
        return tostring(guid);
    end
    name = name:gsub("[%[%]%(%)|]", ""):gsub("%s+", "");
    local limit = maxLen or NAME_MAX_GOOD;
    if #name > limit then
        name = string.sub(name, 1, limit);
    end
    return name;
end

--- 本轮缺口最大的那种货。返回 名称, 数量；没有缺口返回 nil。
local function top_demand()
    local d = _G["trat_fork_demand"];
    if type(d) ~= "table" or type(d.deficit) ~= "table" then
        return nil;
    end
    local bestGuid, bestTotal = nil, 0;
    for guid, info in pairs(d.deficit) do
        local total = 0;
        if type(info) == "table" then
            total = tonumber(info.Total) or 0;
        end
        if total > bestTotal then
            bestGuid, bestTotal = guid, total;
        end
    end
    if bestGuid == nil then
        return nil;
    end
    return good_display_name(bestGuid), math.floor(bestTotal);
end

--- 调度器状态：已关闭 / 已停止 / 卡住 / 待扫描 / 运行
local function scheduler_state(M, region)
    if not UI.IsEnabled() then
        return "已关闭";
    end
    local alive = (_G["trade-route-executor-loop-ow"] == true)
            or (_G["trade-route-executor-loop-nw"] == true);
    if not alive then
        -- 启动瞬间（_main 自检里就会调一次本函数）线程还没被 systemStartXpcall 置位，
        -- 这时既不是「停止」也不该给玩家一个假状态，直接标成启动中、不改船名。
        if _G["trat_fork_last_tick"] == nil and _G["trat_fork_loop_alive_ow"] == nil
                and _G["trat_fork_loop_alive_nw"] == nil then
            return "启动中";
        end
        return "已停止";
    end
    -- 优先看「这条 region 的调度循环」有没有在推进。async 心跳只证明 watcher 活着，
    -- 循环卡在 await 里时它照样在跳，用它判断会漏报「卡在半路」。
    local last = tonumber(_G["trat_fork_loop_alive_" .. tostring(region)]);
    if last == nil then
        last = tonumber(_G["trat_fork_last_tick"]);
    end
    if last ~= nil and os.time() - last > 90 then
        return "卡住";
    end
    local n = 0;
    local ok, areas = pcall(M.MapScannerHL.Region_AllAreas_Get, region);
    if ok and type(areas) == "table" then
        for _ in pairs(areas) do
            n = n + 1;
        end
    end
    if n == 0 then
        return "待扫描";
    end
    return "运行";
end

--- 拼出看板船名。
local function compose_status_name()
    local M = mods();
    local region = M.Anno.Region_Current();
    local list = UI.TakeOverList();
    local n = 0;
    for _ in pairs(list) do
        n = n + 1;
    end

    local state = scheduler_state(M, region);
    if state == "启动中" then
        return nil;   -- 启动瞬间不下结论，保留上一次的船名
    end

    local parts = { NAME_TAG_ON .. state, n .. "艘" };

    -- [v1.12.0] 舰队分布：只有真的用了 A/B 航线才写进船名。
    -- 纯手动接管的玩家看到的仍然是原来的 TRA_运行_2艘_平衡，不受这次改动影响。
    local fleet = UI.FleetSummary();
    if fleet.A > 0 or fleet.B > 0 then
        local seg = {};
        if fleet.A > 0 then
            seg[#seg + 1] = "A" .. fleet.A;
        end
        if fleet.B > 0 then
            seg[#seg + 1] = "B" .. fleet.B;
        end
        parts[#parts + 1] = table.concat(seg);
    end

    if state == "运行" then
        local good, amount = top_demand();
        if good ~= nil then
            parts[#parts + 1] = good .. tostring(amount);
        else
            parts[#parts + 1] = "平衡";
        end
    end
    return table.concat(parts, "_");
end

local function status_file_path()
    local ok, sn = pcall(function() return ts.GameSetup.SettingsFileName; end);
    if ok and type(sn) == "string" then
        local base = sn:match("^(.*)[/\\]GameSettings[/\\]Setup%.xml$");
        if base ~= nil then
            return base .. "\\log\\TRAtUI_status.txt";
        end
    end
    return "TRAtUI_status.txt";
end

local function write_status_file(text)
    pcall(function()
        local f = io.open(status_file_path(), "w");
        if f ~= nil then
            f:write(text);
            f:close();
        end
    end);
end

--- 供需明细：每种缺口 + 具体是哪座岛缺多少。
local function demand_lines(limit)
    local d = _G["trat_fork_demand"];
    if type(d) ~= "table" or type(d.deficit) ~= "table" then
        return { "需求：暂无数据（调度器还没跑完一轮）" };
    end

    local rows = {};
    for guid, info in pairs(d.deficit) do
        if type(info) == "table" then
            rows[#rows + 1] = { guid = guid, total = tonumber(info.Total) or 0 };
        end
    end
    table.sort(rows, function(a, b) return a.total > b.total; end);

    if #rows == 0 then
        return { "需求：无（两岛之间没有达到 50 单位的缺口）" };
    end

    local out = {};
    local maxN = math.min(limit or #rows, #rows);
    for i = 1, maxN do
        local r = rows[i];
        local info = d.deficit[r.guid];
        local who = {};
        for _, a in ipairs((type(info) == "table" and info.Areas) or {}) do
            who[#who + 1] = string.format("%s(%s)+%d",
                    tostring(a.AreaName or "?"),
                    tostring(a.AreaID),
                    math.floor(tonumber(a.Amount) or 0));
        end
        out[#out + 1] = string.format("需求 %s 共%d：%s",
                good_display_name(r.guid, 48),
                math.floor(r.total),
                table.concat(who, " "));
    end
    return out;
end

function UI.StatusName()
    return compose_status_name();
end

--- 把看板刷到所有被托管的船上。返回 船数, 实际改名的船数。
function UI.RefreshStatusNames()
    if _G["trat_fork_name_tag"] == false then
        return 0, 0;
    end

    local M = mods();
    local want = compose_status_name();
    if want == nil then
        return 0, 0;   -- 启动中：还没有确定状态，别去改船名
    end
    local list = UI.TakeOverList();

    local total, changed = 0, 0;
    for k in pairs(list) do
        local oid = tonumber(k);
        if oid ~= nil then
            total = total + 1;
            local cur = nil;
            pcall(function() cur = M.Anno.Ship_Name_Get(oid); end);
            -- 只在真的变了才写：文本嵌入命令每次都发一遍没有意义，
            -- 而且改名会触发一次 Nameable 变更，白刷没好处。
            if cur ~= want then
                local ok = pcall(M.Anno.Ship_Name_Set, oid, want);
                if ok then
                    changed = changed + 1;
                end
            end
        end
    end
    _G["trat_fork_status_name"] = want;

    -- 顺手落一份纯文本看板：Alt-Tab 出来就能读，事后也方便对账。
    pcall(function()
        local lines = { want, os.date("更新于 %Y-%m-%d %H:%M:%S") };
        for _, l in ipairs(demand_lines(VIEW_MAX_GOODS)) do
            lines[#lines + 1] = l;
        end
        write_status_file(table.concat(lines, "\n") .. "\n");
    end);

    return total, changed;
end

function UI.Status()
    local M = mods();
    local region = M.Anno.Region_Current();
    local list = UI.TakeOverList();

    local n = 0;
    for _ in pairs(list) do
        n = n + 1;
    end

    -- 顺手报一下地图数据状态：这是「船不动」最常见的根因，
    -- 玩家按一次 K 就能自己判断要不要先扫描。
    local scanned = 0;
    local okAreas, areas = pcall(M.MapScannerHL.Region_AllAreas_Get, region);
    if okAreas and type(areas) == "table" then
        for _ in pairs(areas) do
            scanned = scanned + 1;
        end
    end

    -- 顺手把看板刷一遍：
    --   1) 修好「上个版本接管过、当时还没标记功能」的老船
    --   2) 让 K 这个纯查询键也有可见效果（否则玩家眼里 K 永远是"没反应"）
    local namedTotal, namedChanged = 0, 0;
    pcall(function()
        namedTotal, namedChanged = UI.RefreshStatusNames();
    end);

    -- 调度循环存活状态：这是「船不动」最关键的一项。
    -- systemStartXpcall 在协程运行期间把 _G[name] 置 true，结束置 nil。
    local loopAlive = (_G["trade-route-executor-loop-ow"] == true);

    -- [TRAtUI][v1.9.5] 现场自动复活。
    -- 19:15 那次的实际症状：v1.9.4 库存已经修好、也成功派了 1 单，
    -- 但读档后引擎把二次触发的 system.start 整个丢掉，
    -- 于是 owner / Loop / async_watcher 一个都没起来（日志里 [Tick] 0 条），
    -- 船开到一半就再无动静，而热键全部正常。
    -- 这里发现 Loop 不在就不重启游戏、就地重新拉起调度。
    local revived = false;
    if not loopAlive and UI.IsEnabled() then
        local restart = _G["trat_fork_restart"];
        if type(restart) == "function" then
            local okR = pcall(restart);
            revived = okR;
        end
    end

    -- [TRAtUI] 全链路自检：把「调度到底卡在哪一步」一次讲清楚。
    -- 之前排查这个要反复重启游戏看日志，现在按一次 K 就够了。
    local gridN, gridOk = 0, false;
    local okGrid, grid = pcall(M.MapScannerHL.Region_AllAreas_Get, region);
    if okGrid and type(grid) == "table" then
        gridOk = true;
        for _ in pairs(grid) do
            gridN = gridN + 1;
        end
    end

    local cacheNames = {
        "map_scanner.Session(P11)",
        "Anno.AreaID_To_ItsOID",
        "Anno.Ships_GetAll",
        "Anno.AreasToResidenceGuids",
        "Anno.AreasToProductionGuids",
        "Anno.BuildingsWithSockets",
    };
    local cparts = {};
    for _, k in ipairs(cacheNames) do
        local okE, has = pcall(M.cache.Exists, k, region);
        local label = k:gsub("^Anno%.", ""):gsub("^map_scanner%.", "grid");
        label = label:gsub("%(P11%)", "");
        cparts[#cparts + 1] = label .. "=" .. (okE and tostring(has) or "ERR");
    end

    local shipN = 0;
    local okShips, ships = pcall(M.Anno.Region_Ships_GetAll, region);
    if okShips and type(ships) == "table" then
        for _ in pairs(ships) do
            shipN = shipN + 1;
        end
    end

    say(string.format("区域=%s 自动化=%s 已接管=%d 艘 地图岛屿=%d 座 调度器=%s",
            tostring(region),
            UI.IsEnabled() and "开启" or "关闭",
            n,
            scanned,
            loopAlive and "运行中"
                    or (revived and "已停止→已重新拉起（等 10 秒再看）"
                    or "已停止（需重启游戏）")));

    say(string.format("诊断 grid可读=%s 网格岛数=%d 本区域船=%d 缓存[%s]",
            tostring(gridOk), gridN, shipN, table.concat(cparts, " ")));

    -- 看板：和船名里那块内容一致，日志里再留一份可回溯的版本。
    local good, amount = top_demand();
    say(string.format("看板 %s｜船队 接管%d艘 / 本区域共%d艘｜最高需求 %s｜改名 %d/%d 艘",
            tostring(_G["trat_fork_status_name"] or ""),
            n, shipN,
            (good ~= nil) and string.format("%s %d", good, amount) or "无",
            namedChanged, namedTotal));

    -- [v1.12.0] 舰队分布：只在真的用了航线时才多打一行，避免干扰手动接管用户。
    local fleet = UI.FleetSummary();
    if (fleet.A + fleet.B + fleet.ALL) > 0 then
        say(string.format("舰队 航线A=%d艘 航线B=%d艘 无后缀航线=%d艘 手动接管=%d艘",
                fleet.A, fleet.B, fleet.ALL, fleet.M));

        -- [v1.12.1] 空舱移动 = 航线 AI 在开，不是本 mod 派的单（我们派单时舱里一定有货）。
        -- 这是「挂了航线之后反而不搬运」的唯一成因，直接把船数和处置办法一起报出来。
        local aiDriven = 0;
        for k in pairs(list) do
            local oid = tonumber(k);
            if oid ~= nil then
                local okMoving, moving = pcall(M.Anno.Ship_IsMoving, oid);
                local hasCargo = false;
                local okCargo, cargo = pcall(M.Anno.Ship_Cargo_Get, oid);
                if okCargo and type(cargo) == "table" then
                    for _, item in pairs(cargo) do
                        if type(item) == "table" and (item.Value or 0) > 0 then
                            hasCargo = true;
                            break;
                        end
                    end
                end
                if okMoving and moving and not hasCargo then
                    aiDriven = aiDriven + 1;
                end
            end
        end
        if aiDriven > 0 then
            say(string.format("注意 有 %d 艘船在空舱移动：航线 AI 正在驱动它们。"
                    .. "请把航线站点删到只剩一个待命岛，或在航线界面暂停这条航线，船才会交还调度器。",
                    aiDriven));
        end
    else
        say(string.format("舰队 未检测到搬运航线（在航线界面建一条名为 TRA_%s_A 的航线，把船拖进去即自动接管）",
                tostring(region)));
    end

    for _, line in ipairs(demand_lines(VIEW_MAX_GOODS)) do
        say(line);
    end
end

function UI.ToggleEnabled()
    local want = not UI.IsEnabled();

    -- [TRAtUI] 必须走原版入口，不能直接写 _G。
    -- trat_fork_enable() 除了置位还会把 owner 协程拉起来 ——
    -- 这是「调度循环已经死了但玩家不想重启游戏」时唯一的自愈途径。
    local fn = want and _G["trat_fork_enable"] or _G["trat_fork_disable"];
    if type(fn) == "function" then
        local ok, err = pcall(fn);
        if not ok then
            _G["trat_fork_enabled"] = want;
            say("开关调用失败（" .. tostring(err) .. "），已直接改写状态。");
        end
    else
        _G["trat_fork_enabled"] = want;
    end
    local on = UI.IsEnabled();

    -- U 键唯一可见的反馈：把看板刷成新状态（关闭时看板会变成 "TRA_已关闭_N艘"）。
    -- 没有这一步，玩家按 U 得到的只有日志里一行字（屏幕上什么都不会变）。
    local touched = 0;
    pcall(function()
        touched = select(1, UI.RefreshStatusNames());
    end);

    say(string.format("自动化已%s，%d 艘船的船名已同步为「%s」。",
            on and "开启" or "关闭",
            touched,
            tostring(_G["trat_fork_status_name"] or "")));
end

--- UI 接口探测（Shift+L，仅 feature/game-ui 分支）。
---
--- 这个按键不参与自动化，只用来回答一个问题：这版游戏到底有没有
--- 可编程的界面构造能力。结果写 log\TRAtUI_uiprobe.txt。
--- 探测本身只读、不改游戏状态，失败也只落日志，不影响调度。
function UI.ProbeUI()
    local ok, wrote, path, err = pcall(function()
        local P = require("trat_fork/ui_probe");
        return P.Run();
    end);

    if not ok then
        say("UI 探测失败：" .. tostring(wrote));
        return;
    end

    if wrote then
        say("UI 接口清单已写入 log\\TRAtUI_uiprobe.txt，把内容发出来即可定方案。");
    else
        say(string.format("UI 探测跑完了但没能写文件（path=%s err=%s），请看 base.log。",
                tostring(path), tostring(err)));
    end
end

return UI;
