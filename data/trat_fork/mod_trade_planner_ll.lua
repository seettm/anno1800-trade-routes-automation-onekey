local Anno = require("trat_fork/anno_interface");
local AreasRequest = require("trat_fork/mod_area_requests");
local AnnoInfo = require("trat_fork/generator/products");
local TradeExecutor = require("trat_fork/mod_trade_executor");
local inspector = require("trat_fork/anno_object_inspector");

local TradePlannerLL = {
    __Internal = {
        ProductGUID_Unknown = {},
    }
};

-- ===========================================================================
-- 调度策略（v1.11.0）
--
-- 原版所有环节都用一个硬编码的 50 作为「最小发运量」：
--   源岛余量 < 50 不算供给、目的岛缺口 < 50 不算需求、
--   可转移量 < 50 不建订单、船装不满 50 不发船。
-- 结果是：一座岛只剩 30 吨鱼，另一座岛饿着，调度器判定「没有任何岛屿可供」，
-- 船一动不动 —— 这对**生活必需品**尤其致命，因为它本来就该有多少搬多少。
--
-- 现在按货物类型分两套阈值：
--   · 基本需求货物（居民消耗品，数据来自 residence_info 的 Request 列表）
--     → 阈值降到 10，远低于此才不发，剩余量哪怕只有十几吨也会被搬走
--   · 其它货物（工业原料、建筑材料）
--     → 保持原来的 50，避免为了几吨零件让船跑一趟
--
-- v1.11.1：基本需求的判定粒度是**每座岛各自实际存在的人口等级**
-- （工人岛不会把小提琴当必需品），数据全部来自游戏内的住宅定义，
-- 不写死 GUID、也不依赖任何人工清单。
--
-- 想改行为不用翻代码：直接改下面 Policy 里的数值即可。
-- ===========================================================================
TradePlannerLL.Policy = {
    -- 非基本需求货物的最小发运量（原版行为）
    minTransferNormal = 50,
    -- 基本需求货物的最小发运量：调小 = 更积极，调大到 50 = 退回原版
    minTransferBasic = 10,
    -- 基本需求货物的存留目标（占岛屿单货容量的比例）。
    -- 原版把目标压在 10/25/50（即 13%~28%），等于「快见底了才补货」。
    -- 0.6 = 让每座岛尽量维持六成库存，低于此才进货，高于此的余量才会外运。
    basicTargetRatio = 0.6,
    -- 基本需求货物的「让渡底线」：源岛库存高于这个水位才愿意往外给。
    -- 和上面的 0.6 分开是有意的 —— 只有一个水位会导致
    -- 「源岛自己不满六成 → 一吨都不给」，明明还有富余却让目的岛饿着。
    -- 0.3 = 自己留三成，三成以上的都算可调剂的余量。
    basicKeepRatio = 0.3,
    -- 基本需求判定开关（false = 全部按 50 处理，用于对比排查）
    basicNeedEnabled = true,
    -- [v1.11.1] 必需品判定的粒度：
    --   "island" = 按每座岛「实际住着的人口等级」判定（默认，最贴游戏实际情况）
    --   "region" = 退回 v1.11.0 的全区并集（所有住宅需求的货全算，最激进）
    basicNeedScope = "island",
    -- [v1.11.2] 实时需求：居民消耗表里的「加工链原料」（例如面粉）
    -- 只在岛上真的建了消耗它的工厂时才算需求。
    -- false = 退回旧行为（居民表里出现什么就运什么）
    realtimeDemand = true,
    -- 额外视为「基本需求」的货物 GUID（数据里认不出来的可手工补，全区生效）
    -- 默认空；例如想强制把木材算进去就加 120008
    extraBasicGoods = {},
};

--- 某种货物本次允许的最小发运量。
---@param isBasic boolean
---@return number
local function min_transfer_for(isBasic)
    local p = TradePlannerLL.Policy;
    if isBasic then
        return p.minTransferBasic or 10;
    end
    return p.minTransferNormal or 50;
end

--- 构建「生活必需品」集合。
---
--- 数据源是 residence_info.json 的 Request 列表（游戏内住宅定义的导出），
--- 不写死 GUID，也不依赖截图/手工清单 —— 新 DLC、新人口等级只要被扫描进来就自动生效。
---
--- [v1.11.1] 粒度从「全区并集」收紧到「每座岛各自实际存在的人口等级」：
--- 原先取全区并集，等于把玩家根本没建的摩天楼（小提琴、蒸汽马车、留声机…）
--- 一起算作必需品，69 种货物全部降到 10，50 的门槛事实上失效，
--- 船会为了十几吨缝纫机跑一趟。现在只有**该岛真有居民消耗**的货才降阈值：
--- 鱼、面包、啤酒、香肠这类该便宜就便宜，工业原料照旧按 50。
---@param L Logger
---@param region RegionID
---@return table<AreaID, table<number, boolean>> byArea 每座岛各自的必需品
---@return table<number, boolean> regionUnion 全区并集（basicNeedScope="region" 与兜底用）
local function build_basic_need_by_area(L, region)
    local byArea = {};
    local regionUnion = {};
    if TradePlannerLL.Policy.basicNeedEnabled == false then
        return byArea, regionUnion;
    end

    local ok, population = pcall(AreasRequest.Population, L, region);
    if ok and type(population) == "table" then
        for areaIdStr, products in pairs(population) do
            local areaID = tonumber(areaIdStr) or areaIdStr;
            for productGuid in pairs(products) do
                local g = tonumber(productGuid) or productGuid;
                if byArea[areaID] == nil then
                    byArea[areaID] = {};
                end
                byArea[areaID][g] = true;
                regionUnion[g] = true;
            end
        end
    else
        L.logf("[TRAtUI] 基本需求集合构建失败：%s", tostring(population));
    end

    -- 手工补充的 GUID 对全区生效（数据里认不出来的货物兜底）
    for _, guid in ipairs(TradePlannerLL.Policy.extraBasicGoods or {}) do
        regionUnion[tonumber(guid) or guid] = true;
    end
    return byArea, regionUnion;
end

--- 集合里有没有这个货物；键可能是 number 也可能是 string，两种都试。
---@param set table|nil
---@param productID number|string
---@return boolean
local function set_has(set, productID)
    if type(set) ~= "table" then
        return false;
    end
    if set[productID] == true then
        return true;
    end
    return set[tostring(productID)] == true;
end

--- 某座岛的某种货物是否属于生活必需品（决定用 10 还是 50 的门槛）。
---@param basicNeed table 形如 { ByArea = ..., Region = ... }
---@param areaID AreaID
---@param productID number
---@return boolean
function TradePlannerLL.IsBasicFor(basicNeed, areaID, productID)
    if type(basicNeed) ~= "table" then
        return false;
    end
    local p = TradePlannerLL.Policy;
    for _, guid in ipairs(p.extraBasicGoods or {}) do
        if (tonumber(guid) or guid) == productID then
            return true;
        end
    end
    local regionSet = basicNeed.Region or {};
    if p.basicNeedScope == "region" then
        return set_has(regionSet, productID);
    end
    -- areaID 在不同路径里可能是 number 也可能是 string，两种键都试一次
    local byArea = basicNeed.ByArea or {};
    local areaSet = byArea[areaID] or byArea[tostring(areaID)];
    if areaSet ~= nil then
        return set_has(areaSet, productID);
    end
    -- 该岛没识别到居民数据（纯生产岛 / 扫描缺失）：退回全区并集。
    -- 保守方向 = 更容易判定为必需品，不会把本来在运的货突然卡回 50。
    return set_has(regionSet, productID);
end

--- 把「哪座岛把哪些货当必需品」打进日志，方便和游戏里的需求面板逐项对照。
--- 每个区域只打一次，避免刷屏。
---@param L Logger
---@param region RegionID
---@param byArea table<AreaID, table<number, boolean>>
local function log_basic_need_by_area(L, region, byArea)
    TradePlannerLL.__Internal.loggedBasicNeed = TradePlannerLL.__Internal.loggedBasicNeed or {};
    if TradePlannerLL.__Internal.loggedBasicNeed[region] then
        return;
    end
    TradePlannerLL.__Internal.loggedBasicNeed[region] = true;

    local scope = TradePlannerLL.Policy.basicNeedScope or "island";
    if TradePlannerLL.Policy.basicNeedEnabled == false then
        L.logf("[TRAtUI] 生活必需品：已关闭（全部按 %d 处理）", min_transfer_for(false));
        return;
    end
    L.logf("[TRAtUI] 生活必需品阈值 %d / 其它 %d，判定粒度=%s",
            min_transfer_for(true), min_transfer_for(false), tostring(scope));

    for areaID, set in pairs(byArea) do
        local names = {};
        for productID in pairs(set) do
            local p = AnnoInfo.Product(productID);
            table.insert(names, p ~= nil and p.Name or tostring(productID));
        end
        table.sort(names);
        local shown = #names;
        if shown > 24 then
            shown = 24;
        end
        local head = {};
        for i = 1, shown do
            head[i] = names[i];
        end
        L.logf("[TRAtUI]   岛 %s(id=%s)：必需品 %d 种 —— %s%s",
                tostring(Anno.Area_CityName(region, areaID)), tostring(areaID), #names,
                table.concat(head, ", "), #names > shown and " …" or "");
    end
end

--- 把「哪些货被当作加工链原料（必须有对应工厂才运）」打进日志，每个区域一次。
---@param L Logger
---@param region RegionID
local function log_intermediates(L, region)
    TradePlannerLL.__Internal.loggedIntermediates = TradePlannerLL.__Internal.loggedIntermediates or {};
    if TradePlannerLL.__Internal.loggedIntermediates[region] then
        return;
    end
    TradePlannerLL.__Internal.loggedIntermediates[region] = true;

    if TradePlannerLL.Policy.realtimeDemand == false then
        L.logf("[TRAtUI] 实时需求：已关闭（居民表里出现什么就运什么）");
        return;
    end
    local set = AreasRequest.ProductionInputs_Set(L, region);
    local names = {};
    for productID in pairs(set) do
        local p = AnnoInfo.Product(productID);
        table.insert(names, p ~= nil and p.Name or tostring(productID));
    end
    table.sort(names);
    if #names == 0 then
        L.logf("[TRAtUI] 实时需求：本区域没有登记到任何加工建筑，居民需求按原表执行");
        return;
    end
    local shown = math.min(#names, 24);
    local head = {};
    for i = 1, shown do
        head[i] = names[i];
    end
    L.logf("[TRAtUI] 加工链原料（岛上没对应工厂就不运）：%d 种 —— %s%s",
            #names, table.concat(head, ", "), #names > shown and " …" or "");
end

---@generic K1, K2, V
---@param k123 table<K1, table<K2, V>>
---@return table<K2, table<K1, V>>
local function dict123to213(k123)
    local ret = {}
    for k1, k23 in pairs(k123) do
        for k2, v3 in pairs(k23) do
            if ret[k2] == nil then
                ret[k2] = {}
            end
            ret[k2][k1] = v3
        end
    end
    return ret;
end

---@param coord1 Coordinate
---@param coord2 Coordinate
---@return number
local function CalculateDistanceBetweenCoordinates(coord1, coord2)
    local dx = coord1.x - coord2.x;
    local dy = coord1.y - coord2.y;
    return math.sqrt(dx * dx + dy * dy);
end

---@param areas table<AreaID, AreaData>
---@param areaID1 AreaID
---@param areaID2 AreaID
---@return Distance
local function CalculateDistanceBetweenAreas(L, areas, areaID1, areaID2)
    local area1 = areas[areaID1];
    local area2 = areas[areaID2];

    if area1 == nil or area1.water_points == nil then
        L.logf("Area %d has no water points", areaID1);
        return { dist = math.huge };
    end
    if area2 == nil or area2.water_points == nil then
        L.logf("Area %d has no water points", areaID2);
        return { dist = math.huge };
    end

    local options = {};
    for _, point1 in ipairs(areas[areaID1].water_points) do
        for _, point2 in ipairs(areas[areaID2].water_points) do
            local dist = CalculateDistanceBetweenCoordinates(point1, point2);
            table.insert(options, { src = point1, dst = point2, dist = dist });
        end
    end
    table.sort(options, function(a, b)
        return a.dist < b.dist
    end);

    if #options == 0 then
        L.logf("No water route found between area %d and area %d", areaID1, areaID2);
        return { dist = math.huge };
    end

    return options[1];
end

---

function TradePlannerLL.Ships_StockInFlight(L, region, ships)
    local _stockFromInFlight = {}; -- table<areaID, table<productID, amount>>
    -- 3.2. In flight
    for ship, _ in pairs(ships) do
        local info = TradeExecutor.Ship_Name_FetchCmdInfo(ship);
        if info == nil then
            goto continue;
        end

        local area_id = info.area_id;
        if area_id == nil then
            goto continue;
        end

        local cargo = Anno.Ship_Cargo_Get(ship);
        for _, cargo_item in pairs(cargo or {}) do
            local value = cargo_item.Value;
            if type(value) ~= "number" or value == 0 then
                goto continue_j;
            end
            if cargo_item.Guid == nil then
                goto continue_j;
            end

            if _stockFromInFlight[area_id] == nil then
                _stockFromInFlight[area_id] = {};
            end
            if _stockFromInFlight[area_id][cargo_item.Guid] == nil then
                _stockFromInFlight[area_id][cargo_item.Guid] = 0;
            end
            _stockFromInFlight[area_id][cargo_item.Guid] = _stockFromInFlight[area_id][cargo_item.Guid] + value;

            :: continue_j ::
        end

        :: continue ::
    end

    return _stockFromInFlight;
end

---

---@param L Logger
---@param region RegionID
---@param _stockFromInFlight TradePlanner.AreaGoodAmount
---@param areas table<AreaID, AreaData>
---@return TradePlanner.SupplyRequestTable
function TradePlannerLL.SupplyRequest_Build(L, region, _stockFromInFlight, areas)
    -- [v1.11.2] realtime=true：居民需求里剔除「本区域加工链原料」，
    -- 原料需求只由真的建了那座厂的岛产生（没面包厂就不运面粉）
    local areaToProductRequest = AreasRequest.All(L, region,
            TradePlannerLL.Policy.realtimeDemand ~= false);
    -- [v1.11.1] 生活必需品按「每座岛实际人口」判定；这些货物的最小发运量降到 minTransferBasic
    local basicByArea, basicRegion = build_basic_need_by_area(L, region);
    local basicNeed = { ByArea = basicByArea, Region = basicRegion };
    log_basic_need_by_area(L, region, basicByArea);
    log_intermediates(L, region);
    local allProducts = {};
    for areaID, products in pairs(areaToProductRequest) do
        for productID, _ in pairs(products) do
            allProducts[productID] = true;
        end
    end

    local supply = {};
    local request = {};
    for areaID, areaData in pairs(areas) do
        local inFlightStock_area = _stockFromInFlight[areaID] or {};
        for productID in pairs(allProducts) do
            local product = AnnoInfo.Product(productID);
            if product == nil then
                if not TradePlannerLL.__Internal.ProductGUID_Unknown[productID] then
                    L.logf("Warning: Product ID %d not found in AnnoInfo", productID);
                    TradePlannerLL.__Internal.ProductGUID_Unknown[productID] = true;
                end
                goto continue;
            end
            local productName = product.Name;

            local inFlightStock = inFlightStock_area[productID] or 0;

            -- [v1.11.0] 按货物类型选阈值：生活必需品 10，其它 50
            -- [v1.11.1] 必需品判定按「这座岛自己的居民」而不是全区并集
            local isBasic = TradePlannerLL.IsBasicFor(basicNeed, areaID, productID);
            local MIN = min_transfer_for(isBasic);

            local _stock = Anno.Area_GetGood(region, areaID, productID);
            -- [TRAtUI] 必须保证是数字。库存查询失败时返回 nil，
            -- 而下面要拿它和 _request ± 阈值 做大小比较，
            -- nil 会直接抛 "attempt to compare number with nil"，
            -- 整轮 iteration 报废（实测 2026-11-15 18:52 每轮都崩在这里，船一步不动）。
            -- 取不到库存按 0 处理：方向是安全的，最坏只是多派一次货，
            -- 货到港时引擎自己会按容量截断，不会把岛堆爆。
            if type(_stock) ~= "number" or _stock < 0 then
                _stock = 0;
            end
            local _request = 0;

            local _areaCap = areaData.capacity;
            -- [TRAtUI] 必须是数字：旧版 Area_GetGoodCapacity 查询失败时返回诊断 table，
            -- 而 `or 75` 只挡 nil 不挡 table，于是 math.min(table, 200) 抛
            -- "attempt to compare number with table"，整轮 iteration 报废（船永远不动）。
            if type(_areaCap) ~= "number" or _areaCap <= 0 then
                _areaCap = 75;
            end

            local doesAreaRequestProduct = areaToProductRequest[areaID] and areaToProductRequest[areaID][productID];
            if doesAreaRequestProduct then
                _request = math.min(_areaCap, 200);
            end
            -- [v1.11.0] 必需品存留目标 = 容量 × basicTargetRatio。
            -- 这一步不能省：若沿用 min(cap,200)=满仓做目标，只有「已经装满」的岛
            -- 才算有盈余，供给端会几乎全灭；若沿用 10/25/50，则目的地又只在快空时才补。
            -- 取中间的 60% 才能同时满足「缺了就补」和「多了才给」。
            if isBasic and _request > 0 then
                local ratio = TradePlannerLL.Policy.basicTargetRatio or 0.6;
                _request = math.floor(_areaCap * ratio);
                if _request < 1 then
                    _request = 1;
                end
            end
            if _request == 0 and _stock == 0 then
                goto continue;
            end

            L.logf("Area %s (id=%d) %s stock=%s (+%s) request=%s", areaData.city_name, areaID, productName, _stock, inFlightStock, _request);
            _request = _request - inFlightStock;

            -- [v1.11.0] 这三段「小岛/中岛/大岛」启发式对生活必需品是有害的：
            -- 它把目标量砍到 10/25/50，意思是「等库存掉到快见底了再补」。
            -- 对工业原料合理（少跑几趟），对鱼和土豆这类就不合理 ——
            -- 一座 5/75 的岛明明缺 70，却被算成「不缺」，船一步不动。
            -- 所以必需品直接跳过这套启发式，目标量 = 满仓。
            if not isBasic then
                if _areaCap == 75 then
                    -- small area
                    if _stock > 0 and _request == 0 then
                        -- do nothing? we will transfer at least 50
                    elseif _stock == 0 and _request > 0 then
                        -- do nothing? let it get as much as it can
                    elseif _stock > 0 and _request > 0 then
                        _request = 10; -- let it transfer at 60 before cap is hit
                    end
                elseif _areaCap == 125 then
                    -- medium area
                    if _stock > 0 and _request == 0 then
                        -- do nothing? we will transfer at least 50
                    elseif _stock == 0 and _request > 0 then
                        -- do nothing? let it get as much as it can
                    elseif _stock > 0 and _request > 0 then
                        _request = 25; -- let it transfer at 75 before cap is hit
                    end
                elseif _areaCap == 175 then
                    -- large area
                    if _stock > 0 and _request == 0 then
                        -- do nothing? we will transfer at least 50
                    elseif _stock == 0 and _request > 0 then
                        -- do nothing? let it get as much as it can
                    elseif _stock > 0 and _request > 0 then
                        _request = 50; -- let it transfer at 90 before cap is hit
                    end
                end
            end

            -- [v1.11.0] 生活必需品单独一套算法，不再借用 _request 这个「单一水位」：
            --   补货：低于 容量×basicTargetRatio(0.6) 就算缺口
            --   出货：高于 容量×basicKeepRatio(0.3)  的部分才算余量
            -- 两个水位分开，才能做到「自己还够用、多出来的就给出去」，
            -- 也就是你说的「库存不满足也要搬运」——不再要求源岛攒够 50 或满 60%。
            if isBasic then
                local keep = math.floor(_areaCap * (TradePlannerLL.Policy.basicKeepRatio or 0.3));
                local spare = _stock - keep;
                local need = _request - _stock;   -- _request 已含 -inFlightStock

                if spare >= MIN then
                    if supply[areaID] == nil then
                        supply[areaID] = {};
                    end
                    supply[areaID][productID] = spare;
                elseif need >= MIN then
                    if request[areaID] == nil then
                        request[areaID] = {};
                    end
                    request[areaID][productID] = need;
                end

            -- 非必需品：保持原版的 50 水位逻辑
            elseif _stock >= _request + MIN and _stock >= MIN then
                if supply[areaID] == nil then
                    supply[areaID] = {};
                end
                supply[areaID][productID] = _stock - _request;
            elseif _request - _stock >= MIN then
                if request[areaID] == nil then
                    request[areaID] = {};
                end
                request[areaID][productID] = _request - _stock;
            end

            :: continue ::
        end
    end

    ---@type TradePlanner.SupplyRequestTable
    local ret = {};
    ret.Supply = supply;
    ret.Request = request;
    -- [v1.11.0] 下游（订单生成 / 派船 / 执行）需要知道哪些货物享受低阈值，
    -- 否则这里放行了、后面几道 50 的闸门又会把它拦回去。
    ret.BasicNeed = basicNeed;

    -- [TRAtUI] 供需摘要：判断「船为什么不动」最直接的证据。
    -- 之前每轮都在上面崩掉，玩家只看到一行报错；现在把结果摊开，
    -- 一眼区分「没有达到阈值的余量/缺口」和「有供需但订单被跳过」。
    local function dump(tbl, tag)
        local n = 0;
        for areaID, goods in pairs(tbl) do
            for productID, amount in pairs(goods) do
                n = n + 1;
                local p = AnnoInfo.Product(productID);
                local basicMark = TradePlannerLL.IsBasicFor(basicNeed, areaID, productID) and " [必需品]" or "";
                L.logf("[TRAtUI] %s area=%d(%s) %s amount=%d%s", tag, areaID,
                        tostring(Anno.Area_CityName(region, areaID)),
                        p ~= nil and p.Name or tostring(productID), amount, basicMark);
            end
        end
        if n == 0 then
            L.logf("[TRAtUI] %s 为空：没有任何岛屿达到阈值（必需品 %d / 其它 %d）",
                    tag, min_transfer_for(true), min_transfer_for(false));
        end
    end
    dump(supply, "供给");
    dump(request, "缺口");

    return ret;
end

---@param L Logger
---@param region RegionID
---@param _stockFromInFlight TradePlanner.AreaGoodAmount
---@param areas table<AreaID, AreaData>
function TradePlannerLL.SupplyRequest_BuildHubs(L, region, _stockFromInFlight, areas)
    local hub = nil;
    for areaID, areaData in pairs(areas) do
        -- has suffix `(h)`
        if areaData.city_name:find("%(h%)$") then
            hub = areaID;
            break ;
        end
    end
    if hub == nil then
        L.logf("No hub area found in region %s", region);
        return nil;
    end

    -- [v1.11.2] realtime=true：居民需求里剔除「本区域加工链原料」，
    -- 原料需求只由真的建了那座厂的岛产生（没面包厂就不运面粉）
    local areaToProductRequest = AreasRequest.All(L, region,
            TradePlannerLL.Policy.realtimeDemand ~= false);
    -- [v1.11.1] hub 路径同样是「每座岛实际人口」判定必需品
    local basicByArea, basicRegion = build_basic_need_by_area(L, region);
    local basicNeed = { ByArea = basicByArea, Region = basicRegion };
    log_basic_need_by_area(L, region, basicByArea);
    log_intermediates(L, region);
    local allProducts = {};
    for areaID, products in pairs(areaToProductRequest) do
        for productID, _ in pairs(products) do
            allProducts[productID] = true;
        end
    end

    local supply = {};
    local request = {};
    for areaID, areaData in pairs(areas) do
        local inFlightStock_area = _stockFromInFlight[areaID] or {};
        for productID in pairs(allProducts) do
            local product = AnnoInfo.Product(productID);
            if product == nil then
                L.logf("Warning: Product ID %s not found in AnnoInfo", productID);
                goto continue;
            end
            local productName = product.Name;

            -- [v1.11.0] 按货物类型选阈值
            -- [v1.11.1] 按这座岛自己的居民判定
            local isBasic = TradePlannerLL.IsBasicFor(basicNeed, areaID, productID);
            local MIN = min_transfer_for(isBasic);

            local inFlightStock = inFlightStock_area[productID] or 0;

            local _stock = Anno.Area_GetGood(region, areaID, productID);
            -- [TRAtUI] 同 SupplyRequest_Build：库存可能是 nil，下面要拿它做比较，
            -- 必须先归一成数字，否则 "attempt to compare number with nil"。
            if type(_stock) ~= "number" or _stock < 0 then
                _stock = 0;
            end

            local _request = 0;
            local _areaCap = areaData.capacity;
            -- [TRAtUI] 必须是数字：旧版 Area_GetGoodCapacity 查询失败时返回诊断 table，
            -- 而 `or 75` 只挡 nil 不挡 table，于是 math.min(table, 200) 抛
            -- "attempt to compare number with table"，整轮 iteration 报废（船永远不动）。
            if type(_areaCap) ~= "number" or _areaCap <= 0 then
                _areaCap = 75;
            end
            local doesAreaRequestProduct = areaToProductRequest[areaID] and areaToProductRequest[areaID][productID];
            if areaID == hub then
                _request = _areaCap * 90 / 100;
            elseif doesAreaRequestProduct then
                _request = math.min(_areaCap, 200);
                -- [v1.11.0] 非枢纽岛的必需品：存留目标按比例，缺了就补
                if isBasic then
                    local ratio = TradePlannerLL.Policy.basicTargetRatio or 0.6;
                    _request = math.floor(_areaCap * ratio);
                    if _request < 1 then
                        _request = 1;
                    end
                end
            end

            if _request == 0 and _stock == 0 then
                goto continue;
            end

            L.logf("Area %s (id=%s) %s stock=%s (+%s) request=%s", areaData.city_name, areaID, productName, _stock, inFlightStock, _request);
            _stock = _stock + inFlightStock;

            if _stock >= _request * 2 and _stock >= MIN then
                if supply[areaID] == nil then
                    supply[areaID] = {};
                end
                supply[areaID][productID] = _stock - _request;
            elseif _request - _stock >= MIN and areaID == hub then
                if request[areaID] == nil then
                    request[areaID] = {};
                end
                request[areaID][productID] = _request - _stock;
            end

            :: continue ::
        end
    end

    ---@type TradePlanner.SupplyRequestTable
    local ret = {};
    ret.Supply = supply;
    ret.Request = request;
    ret.BasicNeed = basicNeed;
    return ret;
end

---@param L Logger
---@param supplyRequest TradePlanner.SupplyRequestTable
---@param areas table<AreaID, AreaData>
---@return TradePlanner.Orders
function TradePlannerLL.SupplyRequest_ToOrders(
        L,
        supplyRequest,
        areas
)
    local request_orders = {} -- table<orderKeyType, orderValueType>

    -- [v1.11.0] 生活必需品享受低阈值；带上这个标记，后面两道闸门才能同步放行
    -- [v1.11.1] 判定看「目的岛」自己是否真的消耗这种货
    local basicNeed = supplyRequest.BasicNeed or {};

    local supply_gta = dict123to213(supplyRequest.Supply)

    for areaID, area_requests in pairs(supplyRequest.Request) do
        for goodID, amount in pairs(area_requests) do
            local isBasic = TradePlannerLL.IsBasicFor(basicNeed, areaID, goodID);
            local MIN = min_transfer_for(isBasic);
            local supply_areas = supply_gta[goodID]
            if supply_areas == nil then
                -- [TRAtUI] 有缺口但没有任何岛有盈余：这是「船不动」最常见的正常原因，
                -- 必须显式写出来，否则玩家只会看到空白日志。
                L.logf("[TRAtUI] 缺口 area=%d goodID=%d amount=%d 没有任何岛屿可供（两岛之间无此货物盈余）",
                        areaID, goodID, amount);
            else
                L.logf("found supply areas for goodID=%d %s", goodID, tostring(supply_areas));
                for supply_areaID, supply_amount in pairs(supply_areas) do
                    local transfer_amount = math.min(amount, supply_amount)

                    local distance = CalculateDistanceBetweenAreas(L, areas, supply_areaID, areaID)

                    if distance.dist == math.huge then
                        L.logf("Skipping order from area %d to area %d for good %d due to no water route",
                                supply_areaID, areaID, goodID);
                        goto continue;
                    end
                    if transfer_amount < MIN then
                        L.logf("Skipping order from area %d to area %d for good %d due to insufficient transfer amount: %d < %d (needed=%d available=%d basic=%s)",
                                supply_areaID, areaID, goodID, transfer_amount, MIN, amount, supply_amount, tostring(isBasic));
                        goto continue;
                    end

                    local key = {
                        AreaID_from = supply_areaID,
                        AreaID_to = areaID,
                        GoodID = goodID,
                        RequestAmount = amount,
                        SupplyAmount = supply_amount,
                        IsBasic = isBasic,
                    }
                    local value = {
                        OrderDistance = distance,
                    }

                    request_orders[key] = value

                    :: continue ::
                end
            end
        end
    end

    return request_orders
end

---@param L Logger
---@param available_ships table<ShipID, any>
---@param request_orders TradePlanner.Orders
---@return TradePlanner.Commands
function TradePlannerLL.SupplyRequestOrders_ToShipCommands(
        L,
        available_ships,
        request_orders
)
    ---@type TradePlanner.Commands
    local available_commands = {}

    for ship, _ in pairs(available_ships) do
        local slots_cap = Anno.Ship_Cargo_SlotCapacity(ship);
        local cap = slots_cap * 50;

        if cap < 50 then
            L.logf("Skipping ship %d due to insufficient cargo capacity: %d slots (%d total)", ship, slots_cap, cap);
            goto continue;
        end

        for order_key, order_value in pairs(request_orders) do
            local ship_position = order_value.OrderDistance.src

            local info = TradeExecutor.Ship_Name_FetchCmdInfo(ship)
            if info ~= nil then
                ship_position = { x = info.x, y = info.y }
            end

            local distance_to_pickup = CalculateDistanceBetweenCoordinates(
                    ship_position,
                    order_value.OrderDistance.src
            )

            local total_distance = distance_to_pickup + order_value.OrderDistance.dist

            local amount;
            -- load to ship as much as we can, as long as supply is met
            if order_key.SupplyAmount >= cap then
                amount = cap;
            else
                amount = order_key.SupplyAmount;
            end

            if amount < min_transfer_for(order_key.IsBasic == true) then
                L.logf("Skipping command for ship %d due to insufficient transfer amount: %d < %d (basic=%s)",
                        ship, amount, min_transfer_for(order_key.IsBasic == true), tostring(order_key.IsBasic));
                goto continue;
            end

            ---@type TradePlanner.CommandKey
            local command_key = {
                ShipID = ship,
                Order = order_key,
            }
            ---@type TradePlanner.CommandValue
            local command_value = {
                Order = order_value,
                ShipDistance = total_distance,
                Amount = amount,
                ShipSlots = slots_cap,
            }

            table.insert(available_commands, {
                Key = command_key,
                Value = command_value,
            })
        end

        :: continue ::
    end

    table.sort(available_commands, function(a, b)
        return a.Value.ShipDistance < b.Value.ShipDistance
    end);

    return available_commands;
end

function TradePlannerLL.SupplyRequestShipCommands_Execute(
        L,
        region,
        supplyRequestTable,
        commands,
        ships
)
    local spawned_tasks = {}
    for _, kv in ipairs(commands) do
        local command_key = kv.Key
        local command_value = kv.Value

        local ship = command_key.ShipID
        local order = command_key.Order
        local order_value = command_value.Order
        local amount = command_value.Amount

        -- [TRAtUI] 原实现直接链式下标：[AreaID_from][GoodID]。只要供需表里
        -- 少了这个岛/这个商品（区域网格刚建、缓存表只覆盖部分岛），
        -- 就是 "attempt to index a nil value"，整轮迭代报废 = 船不动。
        local supply_of_area = supplyRequestTable.Supply[order.AreaID_from];
        local request_of_area = supplyRequestTable.Request[order.AreaID_to];
        local available_supply = supply_of_area and supply_of_area[order.GoodID];
        local available_request = request_of_area and request_of_area[order.GoodID];

        if type(available_supply) ~= "number" or type(available_request) ~= "number" then
            L.logf("Skipping order: supply/request entry missing for good=%s (%s -> %s)",
                    tostring(order.GoodID), tostring(order.AreaID_from), tostring(order.AreaID_to));
            goto continue;
        end

        if available_request <= 0 then
            -- filled
            goto continue;
        end
        if available_supply <= 0 then
            -- drained
            goto continue;
        end
        if ships[ship] == nil then
            -- ship already used
            goto continue;
        end

        -- [v1.11.0] 生活必需品：库存不够整单就按剩余量装，不整单放弃。
        -- 原逻辑是「供给不足就跳过」，于是前面几单把货源抽掉一部分之后，
        -- 后面这单明明还能装七八十吨也会被整单丢掉。
        local MIN_ORDER = min_transfer_for(order.IsBasic == true);
        if available_supply < amount then
            if order.IsBasic == true and available_supply >= MIN_ORDER then
                L.logf("[TRAtUI] 必需品按剩余量发运 good=%s 原计划=%d 实际=%d",
                        tostring(order.GoodID), amount, available_supply);
                amount = available_supply;
            else
                L.logf("Skipping order: insufficient supply: available_supply=%d < order=%d",
                        available_supply, amount);
                goto continue;
            end
        end
        if available_request < MIN_ORDER then
            L.logf("Skipping order: insufficient request: available_request=%d (type=%s) < %d basic=%s",
                    available_request, type(available_request), MIN_ORDER, tostring(order.IsBasic));
            goto continue;
        end

        supplyRequestTable.Supply[order.AreaID_from][order.GoodID] = supplyRequestTable.Supply[order.AreaID_from][order.GoodID] - amount
        supplyRequestTable.Request[order.AreaID_to][order.GoodID] = supplyRequestTable.Request[order.AreaID_to][order.GoodID] - amount
        ships[ship] = nil;

        -- Spawn async task

        local cmd = {
            Key = {
                ShipID = ship,
                Order = {
                    AreaID_from = order.AreaID_from,
                    AreaID_to = order.AreaID_to,
                    GoodID = order.GoodID,
                    Amount = amount,
                }
            },
            Value = {
                Order = {
                    OrderDistance = {
                        src = order_value.OrderDistance.src,
                        dst = order_value.OrderDistance.dst,
                        dist = order_value.OrderDistance.dist,
                    },
                },
                ShipDistance = command_value.ShipDistance,
            }
        }

        local shipName = Anno.Ship_Name_Get(ship);
        local info = TradeExecutor.Ship_Name_FetchCmdInfo(ship);
        if info ~= nil then
            shipName = info.name;
        end

        --local orderLogKey = string.format("%s-%s-%s-%s-%s",
        --        shipName,
        --        os.date("%Y-%m-%dT%H:%M:%SZ"),
        --        Anno.Area_CityName(region, order.AreaID_from),
        --        Anno.Area_CityName(region, order.AreaID_to),
        --        order.GoodID .. "_" .. string.gsub(AnnoInfo.Product(order.GoodID).Name, " ", "_")
        --);

        local tags = {
            ship = tostring(ship) .. " (" .. shipName .. ")",
            aSrc = order.AreaID_from .. " (" .. Anno.Area_CityName(region, order.AreaID_from) .. ")",
            aDst = order.AreaID_to .. " (" .. Anno.Area_CityName(region, order.AreaID_to) .. ")",
            good = order.GoodID .. " (" .. AnnoInfo.Product(order.GoodID).Name .. ")",
            amount = tostring(amount),
        }
        local L1 = L;
        for k, v in pairs(tags) do
            L1 = L1.with(k, v);
        end
        local Lo = L.logger("trades.log");
        for k, v in pairs(tags) do
            Lo = Lo.with(k, v);
        end

        L1.logf("Spawning trade order");
        Lo.logf("Spawning trade order");

        local task_id = TradeExecutor.SpawnTradeOrder(Lo, region, ship, cmd)
        table.insert(spawned_tasks, task_id)

        :: continue ::
    end
    return spawned_tasks;
end

---

---@param L Logger
---@param region RegionID
---@param areas table<AreaID, AreaData>
---@param toUnload table<ShipID, any>
function TradePlannerLL.Ships_ForceUnloadStoppedShips(
        L,
        region,
        areas,
        toUnload
)
    local trades = {};
    -- [TRAtUI] toUnload 可能为 nil：Ships_Available 在「当前区域没有船」时返回 nil,nil,nil，
    -- 原版直接 pairs(nil) 抛错，把整个执行线程带走。
    for ship, _ in pairs(toUnload or {}) do
        L.logf("Ship %d has cargo, waiting for it to unload before starting automation.", ship);

        local sGuid, sValue = nil, 0;

        local cargo = Anno.Ship_Cargo_Get(ship) or {};
        for _, cargo_item in pairs(cargo) do
            local guid, value = cargo_item.Guid, cargo_item.Value;
            if sGuid == nil then
                sGuid = guid;
            elseif sGuid ~= guid then
                L.logf("Ship %d has mixed cargo, cannot proceed with automation.", ship);
                goto continue;
            end
            -- [TRAtUI] Value 可能为 nil（槽位解析失败），与数字相加会抛错。
            sValue = sValue + (value or 0);
        end
        if sGuid == nil then
            L.logf("Ship %d has no cargo, cannot proceed with automation.", ship);
            goto continue;
        end

        local areaToStorageT = {};
        local areaToStorageD = {};
        -- [TRAtUI] areas 可能为 nil（区域还没扫出水域点），原版直接 pairs(nil) 抛错。
        for areaID, areaData in pairs(areas or {}) do
            local capacity = areaData.capacity;
            -- [TRAtUI] 查不到容量时按小岛 75 处理，而不是直接跳过这座岛。
            -- 跳过会让「卸货」这条路径整个失效（船上货永远卸不掉）。
            if type(capacity) ~= "number" or capacity <= 0 then
                capacity = 75;
            end
            local current = Anno.Area_GetGood(region, areaID, sGuid);
            if type(current) ~= "number" then
                goto continueA;
            end
            local availableCap = capacity - current;
            if availableCap <= 50 then
                goto continueA;
            end

            table.insert(areaToStorageT, {
                AreaID = areaID,
                Available = availableCap,
            });
            areaToStorageD[areaID] = availableCap;

            :: continueA ::
        end
        table.sort(areaToStorageT, function(a, b)
            return a.Available > b.Available
        end);

        for _, areaInfo in ipairs(areaToStorageT) do
            local areaID = areaInfo.AreaID;
            local availableCap = areaToStorageD[areaID];
            local areaData = areas[areaID];

            if availableCap >= sValue then
                table.insert(trades, {
                    ship_oid = ship,
                    good_id = sGuid,
                    total_cargo = sValue,
                    areaID_dst = areaID,
                    area_dst_coords = areaData.water_points[1],
                });
                areaToStorageD[areaID] = availableCap - sValue;
                goto continue;
            end
        end

        :: continue ::
    end
    for _, trade in ipairs(trades) do
        L.logf("Forcing ship %d to unload %d of good %d to area %d",
                trade.ship_oid,
                trade.total_cargo,
                trade.good_id,
                trade.areaID_dst
        );

        local goodID = trade.good_id;
        local shipName = Anno.Ship_Name_Get(trade.ship_oid);
        local Lt = L.logger("trades.log")
                    .with("ship", tostring(trade.ship_oid) .. " (" .. shipName .. ")")
                    .with("aDst", trade.areaID_dst .. " (" .. Anno.Area_CityName(region, trade.areaID_dst) .. ")")
                    .with("good", goodID .. " (" .. AnnoInfo.Product(goodID).Name .. ")")
                    .with("amount", tostring(trade.total_cargo));
        TradeExecutor._ExecuteUnloadWithShip(
                Lt,
                region,
                trade.ship_oid,
                trade.good_id,
                trade.areaID_dst,
                trade.area_dst_coords
        );
    end
end

------

---@alias AreaID number
---@alias ProductGUID number
---@alias Amount number
---@alias TradePlanner.AreaGoodAmount table<AreaID, table<ProductGUID, Amount>>
---@alias TradePlanner.GoodAreaAmount table<ProductGUID, table<AreaID, Amount>>
---@alias Distance { src: Coordinate, dst: Coordinate, dist: number }

---@class TradePlanner.SupplyRequestTable
---@field Supply TradePlanner.AreaGoodAmount
---@field Request TradePlanner.AreaGoodAmount

---@class TradePlanner.OrderKey
---@field AreaID_from AreaID
---@field AreaID_to AreaID
---@field GoodID ProductGUID
---@field RequestAmount Amount
---@field SupplyAmount Amount

---@class TradePlanner.OrderValue
---@field Distance Distance

---@alias TradePlanner.Orders table<TradePlanner.OrderKey, TradePlanner.OrderValue>

---@class TradePlanner.CommandKey
---@field ShipID ShipID
---@field Order TradePlanner.OrderKey
---@class TradePlanner.CommandValue
---@field Order TradePlanner.OrderValue
---@field ShipDistance number
---@field Amount Amount
---@field ShipSlots number

---@alias TradePlanner.Commands table<TradePlanner.CommandKey, TradePlanner.CommandValue>

return TradePlannerLL;