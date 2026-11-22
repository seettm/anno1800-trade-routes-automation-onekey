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

    local stillExistingRequestsC = 0;
    local remainingDeficit = {};
    for areaID, goods in pairs(request) do
        for goodID, amount in pairs(goods) do
            if amount >= 50 then
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
            if amount >= 50 then
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

        -- user must cache this manually
        -- [TRAtUI] 包 pcall：cache.Get 内部要拼路径 + 解 JSON，缓存目录还没准备好
        -- 或文件损坏时会抛错，而这里在 xpcall 之外，抛一次就整条 region 循环死亡。
        local okGrid, grid = pcall(MapScannerHL.Region_AllAreas_Get, region);
        if not okGrid or grid == nil then
            if not okGrid then
                L.logf("MapScannerHL.Region_AllAreas_Get failed: %s", tostring(grid));
            end
            reason = "please scan the region " .. tostring(region) .. " first using the map scanner";
            goto continue;
        end

        if Anno.Region_CanCache(region) then
            Anno.Region_RefreshCache(region);
        end
        if Anno.Region_IsCached(region) then
            break
        end
        reason = "please enter region " .. region .. " to cache it";

        :: continue ::
        for _ = 1, 10 do
            coroutine.yield();
        end
        _yields = _yields + 10;
        -- [TRAtUI] 从 600 帧一次改为 120 帧（约 2 秒）一次，并且把分项状态打出来。
        -- 只在前 30 次（约 1 分钟）打，之后降频，避免长时间挂机刷爆日志。
        if _yields % 120 == 0 and _yields <= 3600 then
            L.logf("[TRAtUI] 等待 region=%s yields=%d reason=%s grid=%s cache[%s]",
                    tostring(region), _yields, tostring(reason),
                    tostring(grid ~= nil), cache_state_str(region));
        end
    end

    L.logf("[TRAtUI] region=%s 缓存就绪，开始初始化调度", tostring(region));

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
