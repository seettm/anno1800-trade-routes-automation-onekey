local Anno = require("trat_fork/anno_interface");
local AnnoInfo = require("trat_fork/generator/products");

local AreaRequests = {
    __Internal = {
        ProductGUID_Unknown = {},
        -- [v1.11.1] 住宅 GUID 认不出来时只报一次：Population 现在每轮会被调两次
        -- （一次给供需表、一次给必需品判定），不去重日志会成倍膨胀。
        ResidenceGUID_Unknown = {},
    }
};

function AreaRequests.Population(L, region)
    local ret = {};
    local q = Anno.Region_ResidenceGUIDs(region);
    for areaID, residenceGUIDs in pairs(q) do
        for _, guid in pairs(residenceGUIDs) do
            local residence = AnnoInfo.Residence(L, region, tonumber(guid));
            if residence == nil or residence.Request == nil then
                local g = tonumber(guid);
                if AreaRequests.__Internal.ResidenceGUID_Unknown[g] == nil then
                    AreaRequests.__Internal.ResidenceGUID_Unknown[g] = true;
                    L.logf("Warning: Residence GUID %d not found in AnnoInfo.ResidencesInfo", g);
                end
                goto continue;
            end
            for _, product in pairs(residence.Request) do
                local areaID_num = tonumber(areaID);
                if ret[areaID_num] == nil then
                    ret[areaID_num] = {};
                end
                ret[areaID_num][tonumber(product.Guid)] = true;
            end
            :: continue ::
        end
    end
    return ret;
end

function AreaRequests.Production(L, region)
    local ret = {};
    local q = Anno.Region_ProductionGUIDs(region);
    for areaID, productionGUIDs in pairs(q) do
        for _, guid in pairs(productionGUIDs) do
            local production = AnnoInfo.FactoriesInfo[tonumber(guid)];
            if production == nil then
                if AreaRequests.__Internal.ProductGUID_Unknown[tonumber(guid)] == nil then
                    AreaRequests.__Internal.ProductGUID_Unknown[tonumber(guid)] = true;
                    L.logf("Warning: Production GUID %d not found in AnnoInfo.FactoriesInfo", tonumber(guid));
                end
                goto continue;
            end

            for _, product in pairs(production.Consumption) do
                local areaID_num = tonumber(areaID);
                if ret[areaID_num] == nil then
                    ret[areaID_num] = {};
                end
                ret[areaID_num][tonumber(product.Guid)] = true;
            end

            :: continue ::
        end
    end
    return ret;
end

function AreaRequests.Construction(L, region)
    local ret = {};
    local areas = Anno.Region_AreaID_To_OID(region);
    for areaID, areaOID in pairs(areas) do
        areaID = tonumber(areaID);
        if ret[areaID] == nil then
            ret[areaID] = {};
        end
        ret[areaID][120008] = true; -- Wood
        ret[areaID][1010196] = true; -- Timber
        ret[areaID][1010205] = true; -- Bricks
        ret[areaID][1010218] = true; -- Steel Beams
        ret[areaID][1010207] = true; -- Windows
        ret[areaID][1010202] = true; -- Reinforced Concrete
        ret[areaID][134623] = true; -- Elevator
        ret[areaID][1010224] = true; -- Steam Motors
        ret[areaID][838] = true; -- Aluminium Profiles
    end
    return ret;
end

function AreaRequests.TradeUnionAlikeReplacements(L, region)
    local ret = {};
    local buildings = Anno.Region_BuildingsWithSockets(region);
    for areaIdStr, items in pairs(buildings) do
        local areaID = tonumber(areaIdStr);
        for _, socketItemGuids in pairs(items) do
            local reps = Anno.SocketItemGuidsToInputReplacements(socketItemGuids);
            if #(reps) == 0 then
                goto continue;
            end
            if ret[areaID] == nil then
                ret[areaID] = {};
            end
            for _, rep in pairs(reps) do
                ret[areaID][tonumber(rep.Guid)] = true;
            end
            :: continue ::
        end
    end
    return ret;
end

-- [TRAtUI][v1.11.0] 区域级「居民消耗货物」并集。
-- 与 Population 的区别：Population 是「某座岛需要什么」，这里回答
-- 「本区域被居民消费的所有货物是什么」，用于判定哪些属于生活必需品
-- （这类货物即使达不到 50 单位的余量门槛也要照常发运）。
---@param L Logger
---@param region RegionID
---@return table<number, boolean>
function AreaRequests.Population_Union(L, region)
    local ret = {};
    local ok, population = pcall(AreaRequests.Population, L, region);
    if not ok or type(population) ~= "table" then
        L.logf("[TRAtUI] Population_Union 失败：%s", tostring(population));
        return ret;
    end
    for _, products in pairs(population) do
        for productGuid in pairs(products) do
            ret[tonumber(productGuid) or productGuid] = true;
        end
    end
    return ret;
end

-- [TRAtUI][v1.11.2] 消费类建筑的判定。
-- 这些建筑消耗货物是为了产出幸福度/服务/邮件，不产出可运输的成品；
-- 它们的原料不能被当成「加工链原料」，否则礼包工厂会把杜松子酒、
-- 医院会把药品、洗发剂厂会把肥皂从居民需求里摘掉，结果该运的不运。
--
-- 判定两路：
--   1) 名字里带冒号 —— 数据里所有 DLC 场所类建筑都是 "Bar: Absinthe"、
--      "Restaurant: Fish and Frites"、"Chemical Plant: Shampoo" 这种格式；
--   2) 少数没冒号的场所，显式列进黑名单。
AreaRequests.ConsumerBuildings = {
    ["Care Package Factory"] = true,
    ["Cinema"] = true,
    ["City Hospital"] = true,
    ["Mezcal Bar"] = true,
};

--- 这座建筑是否只是「消费场所」而不是加工厂。
---@param name string
---@return boolean
local function is_consumer_building(name)
    if type(name) ~= "string" then
        return false;
    end
    if AreaRequests.ConsumerBuildings[name] then
        return true;
    end
    return name:find(":", 1, true) ~= nil;
end

--- 本区域「我方岛屿上真实存在的生产建筑所消耗的原料」集合。
---
--- 这是「实时需求」的关键：判定依据不是静态数据表，而是
--- Anno.Region_ProductionGUIDs —— 也就是玩家**真的建了哪些厂**。
--- 于是「查西维奇没建面包厂 ⇒ 不需要运面粉」天然成立；
--- 玩家一旦补上面包厂，面粉立刻进入需求。
---@param L Logger
---@param region RegionID
---@return table<number, boolean>
function AreaRequests.ProductionInputs_Set(L, region)
    local ret = {};
    local ok, q = pcall(Anno.Region_ProductionGUIDs, region);
    if not ok or type(q) ~= "table" then
        L.logf("[TRAtUI] ProductionInputs_Set 取工厂列表失败：%s", tostring(q));
        return ret;
    end
    for _, guids in pairs(q) do
        for _, guid in pairs(guids) do
            local factory = AnnoInfo.FactoriesInfo[tonumber(guid)];
            if factory == nil then
                goto continue;
            end
            if is_consumer_building(factory.Name) then
                goto continue;
            end
            for _, input in pairs(factory.Consumption or {}) do
                ret[tonumber(input.Guid) or input.Guid] = true;
            end
            :: continue ::
        end
    end
    return ret;
end

--- 实时居民需求：居民消耗表 **减去**「本区域加工链原料」。
---
--- 为什么必须减：residence_info 里的 Request 是用
--- GetMaxHappiness/Money/SupplyForGood 探出来的，把「加工链原料」
--- 也算了进来（农民那一行会出现 Flour）。可原料没人加工就是废料 ——
--- 岛上没有面包厂，送面粉过去只会堆仓库。
--- 原料需求改由 AreaRequests.Production 按「岛上有那座厂」精确提供。
---@param L Logger
---@param region RegionID
---@return table<AreaID, table<number, boolean>> population 过滤后的居民需求
---@return table<number, boolean> intermediates 被剔除的加工链原料
function AreaRequests.Population_Realtime(L, region)
    local population = AreaRequests.Population(L, region);
    local intermediates = AreaRequests.ProductionInputs_Set(L, region);

    local ret = {};
    for areaID, products in pairs(population) do
        ret[areaID] = {};
        for productGuid in pairs(products) do
            local g = tonumber(productGuid) or productGuid;
            if not intermediates[g] then
                ret[areaID][productGuid] = true;
            end
        end
    end
    return ret, intermediates;
end

function AreaRequests.All(L, region, realtime)
    local population = AreaRequests.Population(L, region);
    if realtime then
        population = AreaRequests.Population_Realtime(L, region);
    end
    local production = AreaRequests.Production(L, region);
    local construction = AreaRequests.Construction(L, region);
    local tu = AreaRequests.TradeUnionAlikeReplacements(L, region);

    local ret = {};
    for areaID, products in pairs(population) do
        if ret[areaID] == nil then
            ret[areaID] = {};
        end
        for productGuid, _ in pairs(products) do
            ret[areaID][productGuid] = true;
        end
    end
    for areaID, products in pairs(production) do
        if ret[areaID] == nil then
            ret[areaID] = {};
        end
        for productGuid, _ in pairs(products) do
            ret[areaID][productGuid] = true;
        end
    end
    for areaID, products in pairs(construction) do
        if ret[areaID] == nil then
            ret[areaID] = {};
        end
        for productGuid, _ in pairs(products) do
            ret[areaID][productGuid] = true;
        end
    end
    for areaID, products in pairs(tu) do
        if ret[areaID] == nil then
            ret[areaID] = {};
        end
        for productGuid, _ in pairs(products) do
            ret[areaID][productGuid] = true;
        end
    end
    return ret;
end

return AreaRequests;
