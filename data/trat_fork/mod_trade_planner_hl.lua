local Anno = require("trat_fork/anno_interface");
local inspector = require("trat_fork/anno_object_inspector");
local objectAccessor = require("trat_fork/anno_object_accessor");

local serpLight = require("trat_fork/serp/lighttools");
local json = require("trat_fork/rxi/json");
local cache = require("trat_fork/utils_cache");
local base64 = require("trat_fork/iskolbin/base64");
local async = require("trat_fork/utils_async");
local utable = require("trat_fork/utils_table");

local AreasRequest = require("trat_fork/mod_area_requests");
local TradePlannerLL = require("trat_fork/mod_trade_planner_ll");
local MapScannerLL = require("trat_fork/mod_map_scanner");
local MapScannerHL = require("trat_fork/mod_map_scanner_hl");
local shipCmd = require("trat_fork/mod_ship_cmd");
local TradeExecutor = require("trat_fork/mod_trade_executor");

local TrRAt_UI = require("trat_fork/ui_cmds");
local Companion = require("trat_fork/ui_companion");

----

local TPHL_Internal = {};

local TradePlannerHL = {
    __Internal = TPHL_Internal,
};

--- [TRAtUI] 判定一艘船是否归自动化管理。
--- 原版只认「船被挂在名为 TRA_<region> 的贸易航线上」，
--- 玩家必须手工建航线才能用；Fork 后追加「船在接管清单里」这一条，
--- 于是「点一下接管」就等价于原版的「建航线 + 挂船」。
---
--- 清单通过 Companion.IsManaged 访问，而不是直接读 _G：
---   · 首次访问会从磁盘恢复（读档后不必重新点接管）
---   · 键统一为字符串，避免 JSON 落盘后数字键失配
---@return boolean managed, string|nil route_name
local function is_managed_ship(oid, region)
    local okManaged, managed = pcall(Companion.IsManaged, oid);
    if okManaged and managed then
        return true, nil;
    end

    local route_name = Anno.Ship_TradeRoute_GetName(oid);
    if route_name ~= nil and route_name:match("^TRA_" .. region) ~= nil then
        return true, route_name;
    end

    return false, route_name;
end

TradePlannerHL.IsManagedShip = is_managed_ship;

--- [v1.12.3] 舰队标签最大长度。
--- 单字符时代只能有 A-Z + 0-9 共 36 组，玩家想按「近岛/远岛/建材/食物」分组就不够用。
--- 放到 4 位后标签空间是 36^1 + … + 36^4，实际瓶颈是游戏里航线列表的长度，不是这里。
local MAX_FLEET_TAG = 4;

--- [v1.12.0] 航线名 → 舰队标签。只认 TRA_<region> 前缀，绝不误抓玩家的自有航线。
---   TRA_OW      → "ALL"（原版单航线写法，继续兼容）
---   TRA_OW_A    → "A"  （模板航线 1）
---   TRA_OW_B    → "B"  （模板航线 2）
---   TRA_OW_C    → "C"  （v1.12.3 起不再限制只有 A/B）
---   TRA_OW_01   → "01" （v1.12.3：多字符标签，最多 4 位字母数字）
---   TRA_OW 运输 → "ALL"（认不出的后缀按单舰队处理，仍然会被纳管）
---@return string|nil
local function parse_fleet(route_name, region)
    if type(route_name) ~= "string" or type(region) ~= "string" then
        return nil;
    end
    local prefix = "TRA_" .. region;
    if string.sub(route_name, 1, #prefix) ~= prefix then
        return nil;
    end

    local rest = string.sub(route_name, #prefix + 1);
    if rest == "" then
        return "ALL";
    end

    -- 可带一个分隔符（_ - 空格），标签本身必须是纯字母数字：
    -- 用字母数字而不是任意字符，是为了让船名里的 "A2B2" 不会被切成有歧义的段。
    local tag = rest:match("^[_%-%s]?([%w]+)$");
    if tag == nil or #tag > MAX_FLEET_TAG then
        -- TRA_OW 主舰队 / TRA_OW 运输队 这类自定义后缀，统一按单舰队处理
        return "ALL";
    end
    return string.upper(tag);
end

TradePlannerHL.ParseFleet = parse_fleet;

--- [v1.12.0] 把航线上的船同步进接管清单 —— 「两条模板航线」的落地方式。
---
--- 游戏没有开放用 Lua 创建航线的接口（原版作者 kr3v 也是让玩家手工建一条
--- TRA_OW 假航线再挂船），所以这里不去创建航线，而是把航线当成玩家侧的容器：
---   · 船拖进 TRA_OW_A / TRA_OW_B  → 下一轮迭代自动接管，不用 Shift+O
---   · 船拖出航线                  → 自动释放，不再接单
---   · 手动 Shift+O 接管的船        → manual=true，拖出航线也不会被释放
---
--- 只在真的发生变化时才写盘，避免每轮迭代都碰 IO。
---@return number added, number released
function TPHL_Internal.SyncRouteFleets(L, region)
    local ships = Anno.Region_Ships_GetAll(region);
    if type(ships) ~= "table" then
        return 0, 0;
    end

    local added, released = 0, 0;
    local seen = {};
    for _, oid in pairs(ships) do
        local route_name = nil;
        local okRoute, rn = pcall(Anno.Ship_TradeRoute_GetName, oid);
        if okRoute then
            route_name = rn;
        end
        if type(route_name) == "string" and route_name ~= "" then
            seen[route_name] = true;
        end

        local fleet = parse_fleet(route_name, region);
        if fleet ~= nil then
            local okAdopt, isNew = pcall(Companion.AdoptShip, oid, region, fleet, false);
            if okAdopt and isNew then
                added = added + 1;
            end
        else
            local okRel, did = pcall(Companion.ReleaseIfAuto, oid);
            if okRel and did then
                released = released + 1;
            end
        end
    end

    -- 航线名打错是这套机制唯一容易踩的坑：名字不对就静默不纳管，
    -- 玩家在游戏里看不出任何异常。这里把「实际看到的航线名」打一次，
    -- 同一批名字只提示一次，避免每轮刷屏。
    local names = {};
    for name in pairs(seen) do
        names[#names + 1] = name;
    end
    if #names > 0 then
        table.sort(names);
        local sig = table.concat(names, " | ");
        if _G["trat_fork_route_hint"] ~= sig then
            _G["trat_fork_route_hint"] = sig;
            L.logf("[TRAtUI] 检测到航线：%s —— 只有 TRA_%s / TRA_%s_A / TRA_%s_B 会被纳管",
                    sig, tostring(region), tostring(region), tostring(region));
        end
    end

    if added > 0 or released > 0 then
        L.logf("[TRAtUI] 航线舰队同步：纳管 %d 艘，释放 %d 艘（命名 TRA_%s_A / TRA_%s_B）",
                added, released, tostring(region), tostring(region));
        pcall(Companion.RefreshStatusNames);
    end

    return added, released;
end

function TPHL_Internal.Ships_RenameAll(L, region)
    -- [TRAtUI] 必须容忍 nil：非当前区域的船只列表来自磁盘缓存，
    -- 该区域还没扫过时取不到（Region_Ships_GetAll 返回 nil），
    -- 原来直接 pairs(nil) 会抛 "bad argument #1 to 'for iterator'"，
    -- 把整个 planner 循环打死（实测发生在退出/切区域触发 interrupt 时）。
    local ships = Anno.Region_Ships_GetAll(region) or {};

    local total = 1;

    for _, oid in pairs(ships) do
        -- [TRAtUI] 只管老路子（挂着 TRA_<region> 航线的船）。
        -- 通过「接管」进来的船不再改名：改名的唯一用途是把坐标编码进船名供
        -- TradeExecutor 读取，而接管船只没有坐标信息可编码，改了只会把玩家
        -- 自己起的船名（"东方号"）变成 "1"/"2"，且释放时容易还原成垃圾名。
        local okManaged, managed = pcall(Companion.IsManaged, oid);
        if not (okManaged and managed) and is_managed_ship(oid, region) then
            local newName = TradeExecutor.numberToBase62(total);
            total = total + 1;

            local okInfo, info = pcall(TradeExecutor.Ship_Name_FetchCmdInfo, oid);
            if not okInfo then
                info = nil;
            end
            if info == nil then
                pcall(Anno.Ship_Name_Set, oid, newName);
            else
                info.name = newName;
                pcall(TradeExecutor.Ship_Name_StoreCmdInfo, oid, info);
            end
        end
    end
end

function TPHL_Internal.Ships_Available(L, region)
    local available = {};
    local stillMoving = {};
    local notEmpty = {};

    local ships = Anno.Region_Ships_GetAll(region);
    if not ships then
        L.log("No ships found in region " .. region);
        return nil, nil, nil;
    end

    for _, oid in pairs(ships) do
        local managed, route_name = is_managed_ship(oid, region);
        if managed then
            local isMoving = Anno.Ship_IsMoving(oid);

            -- [TRAtUI] 三处加固，全部来自实测崩溃/误判：
            --  · Ship_Cargo_Get 内部命令可能整条失败（对非 ItemContainer 的
            --    "Walking" 对象，例如某些 mod 的载具），这里必须 pcall；
            --  · cargo_item.Value 可能为 nil（槽位解析失败的占位）→ 与 0 比较会抛
            --    "attempt to compare nil with number"，整轮迭代报废 = 船永远不动；
            --  · 日志里的 objectAccessor.GameObject(oid).Nameable.Name 对坏对象会抛错。
            local okCargo, cargo = pcall(Anno.Ship_Cargo_Get, oid);
            if not okCargo or type(cargo) ~= "table" then
                cargo = {};
            end
            local hasCargo = false;
            for _, cargo_item in pairs(cargo) do
                if type(cargo_item) == "table" and (cargo_item.Value or 0) > 0 then
                    hasCargo = true;
                    break ;
                end
            end

            local shipName = "?";
            pcall(function()
                shipName = tostring(objectAccessor.GameObject(oid).Nameable.Name);
            end);

            if isMoving then
                -- [v1.12.1] 「空舱却一直在开」基本只有一种解释：船挂在**有站点**的
                -- 游戏航线上，航线 AI 在驱动它循环跑，调度器永远等不到它停下。
                -- 本 mod 派单是「装货 → 开过去 → 卸货」，中途货舱一定有货；
                -- 空舱长距离移动不可能是我们干的。
                -- 连续 6 轮（约 1 分钟）就报一次，避免刷屏。
                if not hasCargo then
                    local driveKey = "trat_fork_ai_drive_" .. tostring(oid);
                    local n = (tonumber(_G[driveKey]) or 0) + 1;
                    _G[driveKey] = n;
                    if n == 6 then
                        L.logf("[TRAtUI] 船只 %d 连续 %d 轮空舱移动：是航线 AI 在驱动它，不是本 mod 派的单。"
                                .. "请把该航线的站点删掉只留一个待命岛（或直接在航线界面暂停这条航线），船才会交还调度器。",
                                oid, n);
                    end
                else
                    _G["trat_fork_ai_drive_" .. tostring(oid)] = 0;
                end

                stillMoving[oid] = { route_name = route_name };
                L.logf("trade route automation ship -> stillMoving : oid=%d name=%s route=%s isMoving=%s hasCargo=%s",
                        oid, shipName, tostring(route_name), tostring(isMoving), tostring(hasCargo));
            elseif hasCargo then
                notEmpty[oid] = { route_name = route_name, cargo = cargo };
                L.logf("trade route automation ship -> notEmpty : oid=%d name=%s route=%s isMoving=%s hasCargo=%s",
                        oid, shipName, tostring(route_name), tostring(isMoving), tostring(hasCargo));
            else
                available[oid] = { route_name = route_name };
                L.logf("trade route automation ship -> available : oid=%d name=%s route=%s isMoving=%s hasCargo=%s",
                        oid, shipName, tostring(route_name), tostring(isMoving), tostring(hasCargo));
            end
        end
    end

    L.logf("Total available trade route automation ships: %d", utable.length(available));
    L.logf("Total still moving trade route automation ships: %d", utable.length(stillMoving));

    local notEmptyL = utable.length(notEmpty);
    if notEmptyL > 0 then
        L.logf("[warn] total not empty trade route automation ships: %d", utable.length(notEmpty));
    end

    return available, stillMoving, notEmpty;
end

---@param region RegionID
---@param supplyRequest TradePlanner.SupplyRequestTable
local function tradeExecutor_remainingSurplusDeficit(
        L,
        region,
        supplyRequest
)
    local supply = supplyRequest.Supply;
    local request = supplyRequest.Request;
    -- [v1.11.0] 看板也要跟着策略走：必需品阈值更低，否则会出现
    -- 「调度实际在运，看板却显示 0 缺口」的割裂。
    -- [v1.11.1] 必需品按岛判定，所以阈值查询必须带上 areaID
    local basicNeed = supplyRequest.BasicNeed or {};
    local function threshold_of(areaID, goodID)
        if TradePlannerLL.IsBasicFor and TradePlannerLL.IsBasicFor(basicNeed, areaID, goodID) then
            return (TradePlannerLL.Policy and TradePlannerLL.Policy.minTransferBasic) or 10;
        end
        return (TradePlannerLL.Policy and TradePlannerLL.Policy.minTransferNormal) or 50;
    end

    local stillExistingRequestsC = 0;
    local remainingDeficit = {};
    for areaID, goods in pairs(request) do
        for goodID, amount in pairs(goods) do
            if amount >= threshold_of(areaID, goodID) then
                local goodIdStr = tostring(goodID);

                if remainingDeficit[goodIdStr] == nil then
                    remainingDeficit[goodIdStr] = {
                        Total = 0,
                        Areas = {},
                    }
                end
                remainingDeficit[goodIdStr].Total = remainingDeficit[goodIdStr].Total + amount;
                table.insert(remainingDeficit[goodIdStr].Areas, {
                    AreaID = areaID,
                    AreaName = Anno.Area_CityName(region, areaID),
                    Amount = amount,
                })
                stillExistingRequestsC = stillExistingRequestsC + 1;
            end
        end
    end
    local remainingSurplus = {};
    for areaID, goods in pairs(supply) do
        for goodID, amount in pairs(goods) do
            if amount >= threshold_of(areaID, goodID) then
                local goodIdStr = tostring(goodID);

                if remainingSurplus[goodIdStr] == nil then
                    remainingSurplus[goodIdStr] = {
                        Total = 0,
                        Areas = {},
                    }
                end
                remainingSurplus[goodIdStr].Total = remainingSurplus[goodIdStr].Total + amount;
                table.insert(remainingSurplus[goodIdStr].Areas, {
                    AreaID = areaID,
                    AreaName = Anno.Area_CityName(region, areaID),
                    Amount = amount,
                })
            end
        end
    end
    cache.WriteTo(L.__base .. region .. "_remaining-deficit.json", remainingDeficit);
    cache.WriteTo(L.__base .. region .. "_remaining-surplus.json", remainingSurplus);

    -- [TRAtUI][v1.9.7] 把本轮供需结果暴露出去，供热键层拼状态看板。
    -- 之前这些数据只写进 json 文件，玩家在游戏里完全看不到，
    -- 只能靠「船有没有在动」猜调度器知不知道自己缺什么。
    pcall(function()
        _G["trat_fork_demand"] = {
            region   = region,
            at       = os.time(),
            deficit  = remainingDeficit,
            surplus  = remainingSurplus,
            requests = stillExistingRequestsC,
        };
    end);

    return stillExistingRequestsC;
end

---@param L Logger
---@param areas table<AreaID, AreaData>
---@param region RegionID
local function tradeExecutor_iteration(L, areas, region)
    local now = os.date("%Y-%m-%d %H:%M:%S");
    L.logf("start at %s time", now);

    -- 3.1. Find all ships allocated to trade routes automation.
    local available_ships, stillMoving, hasCargo = TradePlannerHL.__Internal.Ships_Available(L, region);
    if utable.length(available_ships) == 0 then
        L.log("No available ships for trade routes automation, exiting iteration.");
        return ;
    end

    local Lu = L.logger("force-unload-ships.log");
    TradePlannerLL.Ships_ForceUnloadStoppedShips(Lu, region, areas, hasCargo);

    -- 4. (work in progress) Determine product disbalances in the areas. Assign ship to balance the good
    local srt = TradePlannerLL.SupplyRequest_Build(
            L,
            region,
            TradePlannerLL.Ships_StockInFlight(L, region, stillMoving),
            areas
    );
    L.log("supply request table - done");

    local request_orders = TradePlannerLL.SupplyRequest_ToOrders(L, srt, areas);
    L.log("request_orders - done");

    local available_commands_kv = TradePlannerLL.SupplyRequestOrders_ToShipCommands(L, available_ships, request_orders);
    L.log("available_commands - done");

    -- ========================================================================
    -- NEW: Spawn async tasks for trade orders
    -- ========================================================================

    local tasks = TradePlannerLL.SupplyRequestShipCommands_Execute(
            L, region,
            srt, available_commands_kv, available_ships
    )
    L.logf("Spawned %d async tasks for trade route execution.", #tasks);

    local stillAvailableShips = 0;
    for _, v in pairs(available_ships) do
        if v ~= nil then
            stillAvailableShips = stillAvailableShips + 1;
        end
    end
    local stillExistingRequestsC = tradeExecutor_remainingSurplusDeficit(L, region, srt);
    if stillAvailableShips == 0 then
        L.log("No more available ships for trade routes automation.");
    elseif stillExistingRequestsC == 0 then
        L.log("No more existing requests for trade routes automation.");
    else
        L.logf("Still available ships: %d, still existing requests: %d", stillAvailableShips, stillExistingRequestsC);
    end

    if stillAvailableShips > 0 then
        for _ = 1, 10 do
            coroutine.yield();
        end

        L.log("Attempting hub run with remaining available ships.");
        local L_dest = L.dst .. ".hub";
        L = L.logger(L_dest);

        local shipsAvailable, shipsMoving, _ = TradePlannerHL.__Internal.Ships_Available(L, region);
        if utable.length(shipsAvailable) == 0 then
            L.log("No available ships for trade routes automation, exiting iteration.");
            return ;
        end
        local srt = TradePlannerLL.SupplyRequest_BuildHubs(
                L,
                region,
                TradePlannerLL.Ships_StockInFlight(L, region, shipsMoving),
                areas
        );
        if srt == nil then
            L.log("No supply request table generated for hub run, exiting iteration.");
            goto done;
        end
        local rq = TradePlannerLL.SupplyRequest_ToOrders(L, srt, areas);
        local acs = TradePlannerLL.SupplyRequestOrders_ToShipCommands(L, shipsAvailable, rq);
        local tasks = TradePlannerLL.SupplyRequestShipCommands_Execute(
                L, region,
                srt, acs, shipsAvailable
        )
        L.logf("Spawned %d async tasks for trade route execution (hub run).", #tasks);
    end
    :: done ::
    L.logf("end at %s time", os.date("%Y-%m-%d %H:%M:%S"));
end

--- 诊断：区域缓存的五张表各自是否就绪。
--- 「船不动」最常见的原因就是其中某一张没建起来，而原来的日志只在 600 帧后
--- 打一句笼统的 "Waiting for region ..."，玩家永远看不出卡在哪一项。
local function cache_state_str(region)
    local names = {
        "map_scanner.Session(P11)",
        "Anno.AreaID_To_ItsOID",
        "Anno.Ships_GetAll",
        "Anno.AreasToResidenceGuids",
        "Anno.AreasToProductionGuids",
        "Anno.BuildingsWithSockets",
    };
    local parts = {};
    for _, k in ipairs(names) do
        local ok, v = pcall(cache.Exists, k, region);
        parts[#parts + 1] = (k:gsub("^Anno%.", ""):gsub("^map_scanner%.", "grid:")) .. "=" .. (ok and tostring(v) or "err");
    end
    return table.concat(parts, ",");
end

function TradePlannerHL.Loop(L, region, interrupt)
    local _yields = 0;
    -- [v1.11.2] 停泊标记：区域既不在地图上、也没有历史缓存时进入静默等待
    local parked = false;
    -- [TRAtUI] 入口立即留痕：这条日志是「调度协程到底有没有跑起来」的唯一证据。
    -- 之前整个等待阶段最多 600 帧才写一行，玩家在游戏里等 10 秒什么都看不到。
    L.logf("[TRAtUI] Loop 启动 region=%s", tostring(region));
    -- 1. Wait for region cache to be ready.
    while true do
        -- [TRAtUI][v1.9.7] 调度心跳：热键层据此区分「在等扫描」和「真的卡死了」。
        _G["trat_fork_loop_alive_" .. tostring(region)] = os.time();

        if interrupt() then
            L.log("Trade executor loop received interrupt signal, stopping.");
            break
        end

        local reason = "";
        local hasGrid = false;

        -- ================================================================
        -- [v1.11.2] 没有我方岛屿的区域自动跳过
        --
        -- 原来的实现不管区域在不在，都每 10 帧去问一次地图扫描器，
        -- 于是「根本没开新世界」的存档会看到 NW 循环永远在刷
        -- "等待 region=NW yields=… please scan the region NW first"。
        -- 现在：区域既不是当前地图、也没有历史缓存 → 直接停泊，
        -- 一个日志都不再打；等玩家真的切进该区域，自动恢复等待扫描。
        -- ================================================================
        local currentRegion = nil;
        pcall(function() currentRegion = Anno.Region_Current(); end);
        if currentRegion ~= region and not Anno.Region_IsCached(region) then
            if not parked then
                parked = true;
                L.logf("[TRAtUI] 区域 %s 不在当前地图且无缓存：停泊等待（进入该区域后自动接上）", tostring(region));
            end
            reason = "region-not-loaded";
        else
            if parked then
                parked = false;
                L.logf("[TRAtUI] 区域 %s 已回到当前地图，恢复等待缓存", tostring(region));
            end

            -- user must cache this manually
            -- [TRAtUI] 包 pcall：cache.Get 内部要拼路径 + 解 JSON，缓存目录还没准备好
            -- 或文件损坏时会抛错，而这里在 xpcall 之外，抛一次就整条 region 循环死亡。
            local okGrid, grid = pcall(MapScannerHL.Region_AllAreas_Get, region);
            if not okGrid or grid == nil then
                if not okGrid then
                    L.logf("MapScannerHL.Region_AllAreas_Get failed: %s", tostring(grid));
                end
                reason = "please scan the region " .. tostring(region) .. " first using the map scanner";
            else
                hasGrid = true;
                if Anno.Region_CanCache(region) then
                    Anno.Region_RefreshCache(region);
                end
                if Anno.Region_IsCached(region) then
                    break
                end
                reason = "please enter region " .. region .. " to cache it";
            end
        end

        for _ = 1, 10 do
            coroutine.yield();
        end
        _yields = _yields + 10;
        -- [TRAtUI] 从 600 帧一次改为 120 帧（约 2 秒）一次，并且把分项状态打出来。
        -- 只在前 30 次（约 1 分钟）打，之后降频，避免长时间挂机刷爆日志。
        if reason ~= "region-not-loaded" and _yields % 120 == 0 and _yields <= 3600 then
            L.logf("[TRAtUI] 等待 region=%s yields=%d reason=%s grid=%s cache[%s]",
                    tostring(region), _yields, tostring(reason),
                    tostring(hasGrid), cache_state_str(region));
        end
    end

    L.logf("[TRAtUI] region=%s 缓存就绪，开始初始化调度", tostring(region));

    -- [v1.12.0] 先把航线上的船纳管，再跑 RenameAll。
    -- 顺序反了的话，RenameAll 会把航线船的船名改成 base62 短名（"1"/"2"），
    -- 玩家自己起的名字白丢，紧接着又会被状态看板覆盖一次。
    local okFleet, addedN, releasedN = pcall(TPHL_Internal.SyncRouteFleets, L, region);
    if okFleet then
        L.logf("[TRAtUI] 航线纳管：新增 %d 艘，释放 %d 艘", addedN or 0, releasedN or 0);
    else
        L.logf("[Error] SyncRouteFleets: %s", tostring(addedN));
    end

    -- [TRAtUI] 开局这几步在 xpcall 之外，任何一处抛错都会让整个 region 循环永久死掉
    -- （表现：热键正常、日志有扫描记录、但船永远不动）。逐段隔离。
    local okRename, errRename = pcall(TradePlannerHL.__Internal.Ships_RenameAll, L, region);
    if not okRename then
        L.logf("[Error] Ships_RenameAll: %s", tostring(errRename));
    else
        L.logf("[TRAtUI] Ships_RenameAll ok");
    end
    coroutine.yield();
    coroutine.yield();
    coroutine.yield();

    local okAreas, areasOrErr = pcall(MapScannerHL.Areas, L, region);
    local areas = nil;
    if okAreas and type(areasOrErr) == "table" and next(areasOrErr) ~= nil then
        areas = areasOrErr;
        local cnt = 0;
        for _ in pairs(areas) do cnt = cnt + 1; end
        L.logf("[TRAtUI] Areas 就绪：%d 座岛参与调度", cnt);
    elseif not okAreas then
        L.logf("[Error] MapScannerHL.Areas: %s", tostring(areasOrErr));
    else
        -- 返回空表 = 还没有任何岛屿完成水域点扫描（玩家还没按扫描键）。
        -- 必须留在 nil，否则后面的重试分支永远不会再执行，扫完了也不会生效。
        L.log("No scanned areas yet for region " .. tostring(region) .. ", will retry.");
    end
    coroutine.yield();
    coroutine.yield();
    coroutine.yield();

    -- ================================================================
    -- [v1.11.2] 空区域跳过
    --
    -- 缓存建好了，但这座区域既没有我方岛屿、也没有我方船只
    -- （典型：从没开过新世界 / 只在别人的区域里逛过），就没必要继续
    -- 初始化改名、清舱、迭代 —— 直接退出这条区域的循环。
    -- 两个条件同时满足才跳过，避免某个探测 API 失效时把正在干活的区域误杀。
    -- ================================================================
    local ownedCnt, shipCnt = 0, 0;
    local okOwned, owned = pcall(Anno.Areas_Owned_Get, region);
    if okOwned and type(owned) == "table" then
        for _ in pairs(owned) do ownedCnt = ownedCnt + 1; end
    end
    local okShips, shipsAll = pcall(Anno.Region_Ships_GetAll, region);
    if okShips and type(shipsAll) == "table" then
        for _ in pairs(shipsAll) do shipCnt = shipCnt + 1; end
    end
    if okOwned and okShips and ownedCnt == 0 and shipCnt == 0 then
        L.logf("[TRAtUI] 区域 %s 既没有我方岛屿也没有我方船只（岛 0 / 船 0），跳过该区域调度", tostring(region));
        return;
    end

    local okAvail, availShips, _, withCargo = pcall(TradePlannerHL.__Internal.Ships_Available, L, region);
    if not okAvail then
        withCargo = nil;
        L.logf("[Error] Ships_Available: %s", tostring(availShips));
    else
        local scnt = 0;
        for _ in pairs(availShips or {}) do scnt = scnt + 1; end
        L.logf("[TRAtUI] 可派船 = %d 艘", scnt);
    end
    local Lu = L.logger("force-unload-ships.log");
    pcall(TradePlannerLL.Ships_ForceUnloadStoppedShips, Lu, region, areas, withCargo);
    coroutine.yield();
    coroutine.yield();
    coroutine.yield();

    local resetScan = function(_region, _areaID)
        if _region ~= region then
            return ;
        end
        if _areaID == nil then
            L.log("Region %s rescan event received, resetting areas cache.", tostring(_region));
        else
            L.logf("Area rescan event received for region=%s areaID=%s", tostring(_region), tostring(_areaID));
        end
        areas = nil;
    end

    table.insert(TrRAt_UI.AreaRescan.Events, resetScan);
    table.insert(TrRAt_UI.RegionRescan.Events, resetScan);

    while true do
        -- [TRAtUI][v1.9.7] 调度心跳（迭代阶段）。一轮约 10 秒，超过 90 秒没更新
        -- 就说明卡在某个 await 里（等船停下 / 等库存命令返回）。
        _G["trat_fork_loop_alive_" .. tostring(region)] = os.time();

        -- [TRAtUI] Li 提前到循环最顶部：下面用 goto 跳过整轮，
        -- 而 goto 不允许跳进局部变量的作用域，标签前不能再出现新 local。
        local Li = L.logger("trade-execute-iteration.log");

        if interrupt() then
            L.log("Trade route executor loop received interrupt signal, stopping.");
            break
        end

        -- [TRAtUI] 自动化总开关（Shift+U）。
        -- 关闭时保持协程存活、只空转：再按一次立刻恢复，不必重进游戏。
        -- 注意用「不显式为 false」判定，默认就是开启，不会因为没按过 U 而停工。
        if type(Companion.IsEnabled) == "function" and not Companion.IsEnabled() then
            for i = 1, 600 do
                coroutine.yield();
            end
            goto continue_loop;
        end

        L.log("Starting trade execute iteration loop at " .. os.date("%Y-%m-%d %H:%M:%S"));
        Li.log("Starting trade execute iteration loop at " .. os.date("%Y-%m-%d %H:%M:%S"));

        if Anno.Region_CanCache(region) then
            Anno.Region_RefreshCache(region);
        end

        if areas == nil then
            L.log("Rescanning areas due to area rescan event.");
            Li.log("Rescanning areas due to area rescan event.");
            -- [TRAtUI] 原来这一行在 pcall 之外：任何一次读取失败都会让整个 region 循环
            -- 直接退出，之后 _main 重启它、又重新失败，表现就是「船永远不动、日志刷屏」。
            local okA, res = pcall(MapScannerHL.Areas, L, region);
            if okA and type(res) == "table" and next(res) ~= nil then
                areas = res;
            else
                areas = nil;
                if not okA then
                    L.logf("[Error] MapScannerHL.Areas (loop): %s", tostring(res));
                end
            end
            coroutine.yield();
            coroutine.yield();
            coroutine.yield();
        end

        -- 区域还没扫出水域点（Scanner 没建网格/没有我方岛屿）时不要硬跑，
        -- 否则每轮都抛一次 pairs(nil)，日志被刷爆却毫无进展。
        if areas == nil then
            L.log("Areas unavailable for region " .. tostring(region) .. ", waiting for a map scan (hotkey).");
            Li.log("Areas unavailable for region " .. tostring(region) .. ", waiting for a map scan (hotkey).");
            for i = 1, 600 do
                coroutine.yield();
            end
        else
            -- [v1.12.0] 每轮迭代前同步航线归属：玩家在游戏里把船拖进/拖出
            -- TRA_OW_A / TRA_OW_B 不需要任何热键，下一轮就生效。
            pcall(TPHL_Internal.SyncRouteFleets, Li, region);

            local success, err = xpcall(function()
                return tradeExecutor_iteration(Li, areas, region);
            end, debug.traceback);
            if not success then
                L.logf("[Error] trade execute iteration: %s", tostring(err));
                Li.logf("[Error] trade execute iteration: %s", tostring(err));
            end

            for i = 1, 600 do
                coroutine.yield();
            end
        end

        :: continue_loop ::
    end
end

return TradePlannerHL;
