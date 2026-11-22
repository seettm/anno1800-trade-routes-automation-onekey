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

function AreaRequests.All(L, region)
    local population = AreaRequests.Population(L, region);
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
