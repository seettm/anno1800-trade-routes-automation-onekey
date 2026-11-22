local serpLight = require("trat_fork/serp/lighttools");
local objectAccessor = require("trat_fork/anno_object_accessor");
local cache = require("trat_fork/utils_cache");

local Anno = {
    Internal = {},
};

---

function Anno.Camera_MoveTo_Object(oid)
    ts.MetaObjects.CheatLookAtObject(oid);
end

function Anno.Object_Properties(oid)
    local props = {};
    for i, v in pairs(serpLight.PropertiesStringToID) do
        xpcall(function()
            local t = session.getObjectByID(oid):getProperty(v);
            table.insert(props, { name = i, id = v });
        end, debug.traceback);
    end
    return props;
end

-- Objects[OID] = { GUID = GUID, userdata = userdata, OID = OID, ParticipantID = ParticipantID, SessionGuid = SessionGuid }

---@class SessionObject
---@field GUID number
---@field userdata userdata
---@field OID number
---@field ParticipantID number
---@field SessionGuid number

---@return table<number, SessionObject>
function Anno.Objects_GetAll_ByProperty(property)
    return serpLight.GetCurrentSessionObjectsFromLocaleByProperty(property);
end

---@class TsVectorType
---@field Guid number
---@field Icon string
---@field Text string
---@field Value string

Anno.TsVectorType = {
    Guid = "number",
    Icon = "string",
    Text = "string",
    Value = "string",
}

---@return TsVectorType[]
function Anno.Object_ItemContainer_GetSockets(oid)
    return serpLight.GetVectorGuidsFromSessionObject('[MetaObjects SessionGameObject(' .. tostring(oid) .. ') ItemContainer Sockets Count]', Anno.TsVectorType);
end

---@return GUID[]
function Anno.SocketItemGuidsToInputReplacements(socketItemGUID)
    local res = {};
    local i = 0;
    while true do
        local r = serpLight.DoForSessionGameObjectRaw('[AssetData([ItemAssetData(' .. tostring(socketItemGUID) .. ') ReplaceInputNewInput(' .. tostring(i) .. ')]) Guid]');
        local rN = tonumber(r);
        if rN == nil or rN <= 0 then
            break ;
        end
        table.insert(res, r);

        i = i + 1;
        if i > 100 then
            --error("wtf? infinite loop detected in Anno.SocketItemGuidsToInputReplacements for socketItemGUID " .. tostring(socketItemGUID));
            break ;
        end
    end
    return res;
end


---

-- [TRAtUI] 岛屿 → 一个属于该岛的 GameObject OID（用于 [MetaObjects SessionGameObject(oid) Area ...] 查询）。
--
-- 原版靠「遍历 LoadingPier 属性组、反查每个码头的 Area」建映射表，实测在 28 座岛的
-- 旧世界里只建出 1 条记录（其余对象 get_OID 返回 nil 或拿不到 Area.ID），结果：
--   · Area_Owner 全部返回 nil → 除那一座岛外都被当成"非玩家所有"筛掉
--   · Area_CityName 全部返回 nil → 日志里岛屿名缺失
--   · 建筑材料的 area_requests 只覆盖一座岛
-- 引擎本身有 CConstructionArea.KontorID（该岛贸易站/码头的 OID），无需任何反查。
local _areaOidCache = {};
local _oidDiag = {};   -- [v1.9.4] areaID -> true，OID 映射只打一次日志

--- 引擎直连：CConstructionArea.KontorID = 该岛贸易站/码头的 GameObject OID。
--- 单独抽出来是为了让 _AreaID_To_ItsOID_Build 也能用，同时避免
--- area_oid → Region_AreaID_To_OID → _AreaID_To_ItsOID_Build → area_oid 的递归。
---@return number|nil
local function kontor_oid(areaID)
    if areaID == nil then
        return nil;
    end
    local oid = nil;
    pcall(function()
        local area = ts.Area.GetAreaFromID(areaID);
        if area == nil then
            return;
        end
        local raw = area.KontorID;
        if raw == nil then
            return;
        end
        -- KontorID 声明类型是 GameObjectID，可能以 number 或 64 位整数包装形式返回，
        -- 用 tostring 里抠数字兜一层，避免 tonumber 拿到 nil 静默失效。
        local n = tonumber(raw);
        if n == nil then
            local s = tostring(raw);
            n = tonumber(s:match("(%d+)") or "");
        end
        -- [TRAtUI][v1.9.4] KontorID 实测返回 1804 / 1 这种小整数（不是 ObjectID），
        -- 真正的 SessionGameObject OID 是 12884902099 这个量级。
        -- 阈值提到 1e6：低于它的一律视为无效占位值。
        if n ~= nil and n >= 1000000 then
            oid = n;
        end
    end);
    return oid;
end

---@return number|nil
local function area_oid(region, areaID)
    if areaID == nil then
        return nil;
    end

    local key = tostring(region) .. ":" .. tostring(areaID);
    local cached = _areaOidCache[key];
    if cached ~= nil then
        return cached;
    end

    -- [TRAtUI] ts.Area.GetAreaFromID 只能在「玩家当前所在 session」里用：
    -- 拿另一个区域的 areaID 去问，引擎会按当前 session 解析出别的岛（不报错）。
    -- 旧世界/新世界两个调度循环是并发跑的，所以这里必须先判区域。
    local cur = nil;
    pcall(function() cur = Anno.Region_Current(); end);
    local oid, via = nil, nil;
    if cur == nil or region == nil or cur == region then
        -- [TRAtUI][v1.9.4] 顺序对调：本地建筑 OID 提到第一位。
        -- v1.9.3 里 KontorID 先返回 1804（>1000 通过了当时的校验），
        -- 直接短路了后面唯一能用的路径，所以库存照旧全是 0。
        if Anno.Areas_Owned_OID_Get ~= nil then
            local okOwn, oidMap = pcall(Anno.Areas_Owned_OID_Get, region);
            if okOwn and type(oidMap) == "table" then
                oid = tonumber(oidMap[areaID] or oidMap[tostring(areaID)]);
                if oid ~= nil then
                    via = "player building";
                end
            end
        end
        if oid == nil then
            oid = kontor_oid(areaID);
            if oid ~= nil then
                via = "KontorID";
            end
        end
    end

    -- 兜底：映射表（非当前区域时读的是该区域扫描时落盘的缓存）
    if oid == nil then
        local okMap, mapping = pcall(Anno.Region_AreaID_To_OID, region);
        if okMap and mapping ~= nil then
            oid = tonumber(mapping[tostring(areaID)]);
            if oid ~= nil then
                via = "mapping";
            end
        end
    end

    -- 统一校验：真 OID 在 1e9 量级，低于 1e6 一律当无效
    if oid ~= nil and oid < 1000000 then
        oid = nil;
    end

    if oid ~= nil then
        _areaOidCache[key] = oid;
        if not _oidDiag[tostring(areaID)] then
            _oidDiag[tostring(areaID)] = true;
            local L = _G["trat_fork_logger"];
            if L ~= nil then
                L.logf("[TRAtUI] OID 映射 areaID=%s oid=%s via=%s",
                        tostring(areaID), tostring(oid), tostring(via));
            end
        end
    end
    return oid;
end

Anno.Area_OID = area_oid;

function Anno.Area_AddGood(region, areaID, guid, amount)
    if amount == 1 then
        amount = 2;
    end

    local oid = area_oid(region, areaID);
    if oid == nil then
        return nil;
    end
    local cmd = '[MetaObjects SessionGameObject(' .. tostring(oid) .. ') Area Economy AddAmount(' .. tostring(guid) .. ',' .. tostring(amount / 2) .. ')]';
    return serpLight.DoForSessionGameObjectRaw(cmd);
end

-- 库存查询失败的诊断记录：每个 areaID+guid 只打一次。
local _goodDiag = {};

--- 岛屿仓库里某货物的现有数量。
--- 返回 nil 表示查询失败（调用方必须自己兜底，绝不能直接拿去比较/运算）。
---@return number|nil
function Anno.Area_GetGood(region, areaID, guid)
    -- 1) 引擎直连：和容量查询走同一个 Economy 对象。
    --    实测 Area.Economy.GetStorageCapacity 在本版本可用，说明 area.Economy 这条路是通的。
    --    （旧版只用文本嵌入 AvailableAmount，遇到没解锁/无仓库的货物会解析失败返回 nil，
    --     而调用方 SupplyRequest_Build 直接拿它做大小比较 → "attempt to compare number with nil"，
    --     每轮调度都在那里崩掉，船永远不动。这就是 2026-11-15 18:52 那条报错的根因。）
    --
    --    每个候选方法单独 pcall：方法不存在时不能把整个 direct 分支炸掉，
    --    否则后面的候选根本没机会试。
    -- [TRAtUI][v1.9.3] 实测 ts.Area.GetAreaFromID(id) 拿到的东西上
    -- AvailableAmount/GetStorageAmount/GetAmount 全都不存在（log: direct(ok=true)=nil），
    -- 于是库存恒按 0 算 → 供给表全空 → 0 条航线 → 船永不动。
    -- 新路径：从「本地建筑代表对象」的 .Area 进去（Areas_Owned 已证明 GameObject(oid).Area.ID 可读）。
    local oid0 = area_oid(region, areaID);
    if oid0 ~= nil then
        local okG, v0 = pcall(function()
            local o = objectAccessor.GameObject(oid0);
            if o == nil then return nil; end
            local a = o.Area;
            if a == nil then return nil; end
            local e = a.Economy;
            if e == nil then return nil; end
            for _, m in ipairs({ "AvailableAmount", "GetStorageAmount", "GetAmount" }) do
                local okM, r = pcall(function() return e[m](e, guid); end);
                if okM then
                    local n = tonumber(r);
                    if n ~= nil and n >= 0 and n < 2147483647 then
                        return n;
                    end
                end
            end
            return nil;
        end);
        if okG and v0 ~= nil then
            return v0;
        end
    end

    local aid = tonumber(areaID) or areaID;
    local okDirect, direct = pcall(function()
        -- 缓存 JSON 解出来的 areaID 是字符串（对象 key），引擎接口要数字，这里统一转换。
        local area = ts.Area.GetAreaFromID(aid);
        if area == nil then
            return nil;
        end
        local economy = area.Economy;
        if economy == nil then
            return nil;
        end
        -- 语义优先与原版文本嵌入完全一致（AvailableAmount = 仓库现有量），
        -- 再退到 GetStorageAmount / GetAmount。
        for _, method in ipairs({ "AvailableAmount", "GetStorageAmount", "GetAmount" }) do
            local okM, v = pcall(function()
                return economy[method](economy, guid);
            end);
            if okM then
                local n = tonumber(v);
                if n ~= nil and n >= 0 and n < 2147483647 then
                    return n;
                end
            end
        end
        return nil;
    end);
    if okDirect and direct ~= nil then
        return direct;
    end

    -- 2) 文本嵌入兜底
    local oid = area_oid(region, areaID);
    if oid ~= nil then
        local cmd = '[MetaObjects SessionGameObject(' .. tostring(oid) .. ') Area Economy AvailableAmount(' .. tostring(guid) .. ')]';
        local ret = serpLight.DoForSessionGameObjectRaw(cmd);
        local n = tonumber(ret);
        if n ~= nil then
            return n;
        end
    end

    -- 3) 全失败：记一次诊断后返回 nil
    local key = tostring(areaID) .. ":" .. tostring(guid);
    if not _goodDiag[key] then
        _goodDiag[key] = true;
        local L = _G["trat_fork_logger"];
        if L ~= nil then
            L.logf("[TRAtUI] 库存查询失败 areaID=%s guid=%s oid=%s direct(ok=%s)=%s → 按 0 处理",
                    tostring(areaID), tostring(guid), tostring(oid),
                    tostring(okDirect), tostring(direct));
        end
    end
    return nil;
end

-- 容量查询失败的诊断记录：每个 areaID 只打一次，避免每轮调度都刷同一条日志。
local _capDiag = {};

--- 岛屿仓库对某货物的存储上限（75 = 小岛 / 125 = 中岛 / 175 = 大岛）。
--- 返回 nil 表示查不到，调用方必须用 `or 75` 兜底。
---@return number|nil
function Anno.Area_GetGoodCapacity(region, areaID, guid)
    -- 1) 引擎直连 Economy.GetStorageCapacity —— 不走文本嵌入解析，最可靠。
    --    依据：原版 generator/products.lua 里就是 currentEconomy.GetStorageCapacity(guid)。
    -- [TRAtUI][v1.9.3] 和 Area_GetGood 同因：GetAreaFromID 那条取不到 Economy。
    -- 改走「本地建筑代表对象」的 .Area.Economy。
    local oid0 = area_oid(region, areaID);
    if oid0 ~= nil then
        local okG, capG = pcall(function()
            local o = objectAccessor.GameObject(oid0);
            if o == nil then return nil; end
            local a = o.Area;
            if a == nil then return nil; end
            local e = a.Economy;
            if e == nil then return nil; end
            local n = tonumber(e.GetStorageCapacity(guid));
            if n == nil then
                n = tonumber(e.StorageCapacity);
            end
            return n;
        end);
        if okG and capG ~= nil and capG > 0 and capG < 2147483647 then
            return capG;
        end
    end

    local okDirect, direct = pcall(function()
        -- 缓存 JSON 解出来的 areaID 是字符串（对象 key），引擎接口要数字，这里统一转换。
        local aid = tonumber(areaID) or areaID;
        local area = ts.Area.GetAreaFromID(aid);
        if area == nil then
            return nil;
        end
        local economy = area.Economy;
        if economy == nil then
            return nil;
        end
        local n = tonumber(economy.GetStorageCapacity(guid));
        if n == nil then
            -- 有些版本把它暴露成属性而不是方法
            n = tonumber(economy.StorageCapacity);
        end
        return n;
    end);
    if okDirect and direct ~= nil and direct > 0 and direct < 2147483647 then
        return direct;
    end

    -- 2) 文本嵌入兜底
    local oid = area_oid(region, areaID);
    local embedCap, embedRaw = nil, nil;
    if oid ~= nil then
        local cmd = '[MetaObjects SessionGameObject(' .. tostring(oid) .. ') Area Economy StorageCapacity(' .. tostring(guid) .. ')]';
        local ret = serpLight.DoForSessionGameObjectRaw(cmd);
        embedRaw = ret;
        embedCap = tonumber(ret);
        if embedCap ~= nil and embedCap > 0 and embedCap < 2147483647 then
            return embedCap;
        end
    end

    -- 3) 全失败：记一次诊断后返回 nil（绝不能返回 table，调用方是当数字用的）
    local key = tostring(areaID);
    if not _capDiag[key] then
        _capDiag[key] = true;
        local L = _G["trat_fork_logger"];
        if L ~= nil then
            L.logf("[TRAtUI] 容量查询失败 areaID=%s guid=%s oid=%s direct(ok=%s)=%s embed(raw=%s)=%s → 按 75 处理",
                    key, tostring(guid), tostring(oid),
                    tostring(okDirect), tostring(direct),
                    tostring(embedRaw), tostring(embedCap));
        end
    end
    return nil;
end

---

--- 当前本地玩家（人类）的 ParticipantID。
--- 引擎 API 名是 GetGetCurrentParticipantID（双 Get 不是笔误，见 lighttools.lua 注释）。
---@return number|nil
local function current_pid()
    local ok, p = pcall(function() return ts.Participants.GetGetCurrentParticipantID() end);
    if ok then
        local n = tonumber(p);
        if n ~= nil then
            return n;
        end
    end
    return nil;
end

-- 归属判定的诊断记录：areaID -> 哪一路探测生效（只在第一次算的时候打印）
local _ownerProbe = {};

---------------------------------------------------------------------
-- [TRAtUI] 岛屿归属的「兜底真相」：用本地玩家的建筑反推。
--
-- GetCurrentSessionObjectsFromLocaleByProperty 返回的对象组天然只包含
-- **本地玩家** 的物体（见 lighttools 里该函数的注释）。所以只要某座岛上
-- 存在一座我的住宅/工厂/仓库，这座岛就一定是我的。
-- 前面的 .Owner / IsOwnedByCurrentParticipant 在不同游戏版本/DLC 下
-- 可能整体失效（实测就出现过 28 座岛里 27 座 owner=nil），这条路不依赖
-- 任何「所有者」属性，是最后一道能确定结论的证据。
--
-- 代价：一次枚举几百个对象。因此按区域缓存 15 秒，避免每座岛都重算。
---------------------------------------------------------------------
local _ownedAreas = {};       -- region -> { [areaID] = true }
local _ownedOid = {};         -- region -> { [areaID] = 该岛任意一座本地建筑的 OID }
local _ownedDiagLog = {};     -- [v1.9.4] region -> true，诊断只打一次
local _ownedAreasAt = {};     -- region -> os.time()
local OWNED_AREAS_TTL = 15;

function Anno.Areas_Owned_Invalidate()
    _ownedAreas = {};
    _ownedOid = {};
    _ownedAreasAt = {};
end

---[TRAtUI][v1.9.3] areaID → 该岛任意一座**本地**建筑的 OID。
--- 用途：KontorID 这条拿 OID 的路已证实返回垃圾值（1），文本嵌入
--- `[MetaObjects SessionGameObject(<oid>) Area Economy AvailableAmount(<guid>)]`
--- 只要有**属于该岛的任意对象** OID 就能取到该岛仓库库存。
--- 本地建筑天然满足这个条件，所以拿它当代表 OID 最稳。
---@return table<number, number>|nil
function Anno.Areas_Owned_OID_Get(region)
    local key = tostring(region);
    pcall(Anno.Areas_Owned_Get, region);   -- 确保映射已建好（带 15 秒缓存）
    return _ownedOid[key];
end

---@return table<number, boolean>
function Anno.Areas_Owned_Get(region)
    local key = tostring(region);
    local now = os.time();
    local at = _ownedAreasAt[key];
    if _ownedAreas[key] ~= nil and at ~= nil and (now - at) < OWNED_AREAS_TTL then
        return _ownedAreas[key];
    end

    local set = {};
    local oidMap = {};
    local groups = { "Residence7", "Factory7", "Distribution" };
    for _, group in ipairs(groups) do
        local ok, objs = pcall(serpLight.GetCurrentSessionObjectsFromLocaleByProperty, group);
        if ok and type(objs) == "table" then
            for oid in pairs(objs) do
                local okArea, areaID = pcall(function()
                    return serpLight.AreatableToAreaID(objectAccessor.GameObject(oid).Area.ID);
                end);
                if okArea and areaID ~= nil then
                    set[areaID] = true;
                    if oidMap[areaID] == nil then
                        oidMap[areaID] = oid;
                    end
                end
            end
        end
    end

    _ownedAreas[key] = set;
    _ownedOid[key] = oidMap;

    -- [v1.9.4] 一行诊断：确认「本地建筑 → areaID → OID」这条链真的建起来了。
    -- 如果这里岛数=0，说明 GetCurrentSessionObjectsFromLocaleByProperty 没返回东西，
    -- 那就别再指望从这条路取库存。
    if not _ownedDiagLog[key] then
        _ownedDiagLog[key] = true;
        local L = _G["trat_fork_logger"];
        if L ~= nil then
            local n = 0;
            for _ in pairs(set) do
                n = n + 1;
            end
            local sampleOid = "无";
            for _, v in pairs(oidMap) do
                sampleOid = tostring(v);
                break;
            end
            L.logf("[TRAtUI] 本地建筑反推：%d 座岛，OID 样本=%s", n, sampleOid);
        end
    end
    _ownedAreasAt[key] = now;
    return set;
end

--- 判断某个 candidate（参与者 ID 或 "所有者 ID"）是否等于本地玩家。
--- 约定：0 在 Anno 的 Area 属性里表示「玩家自己」，但也有接口返回真实 PID，
--- 两种都认，才能同时兼容不同的取值方式。
local function is_me(candidate, pid)
    local n = tonumber(candidate);
    if n == nil then
        return nil;
    end
    if n == 0 then
        return true;
    end
    if pid ~= nil and n == pid then
        return true;
    end
    return false;
end

function Anno.Area_Owner(region, areaID)
    -- [TRAtUI] 返回约定保持不变：0 = 本地玩家所有，其他 = 别人/中立，nil = 认不出来。
    --
    -- 这是「明明有两座岛却只扫了一座」的根因所在，因此改成多路探测：
    --   1) CConstructionArea.Owner（原版可视化代码用的就是这个，0 = 玩家）
    --   2) CConstructionArea.IsOwnedByCurrentParticipant（布尔直读）
    --   3) 该岛 KontorID 对应的 GameObject.Owner（lighttools 已证明 GameObject.Owner 可用）
    --   4) 老的文本嵌入 [.. Area Owner]
    -- 任一路明确判定为「我」就返回 0；全部失效才返回 nil。
    -- 探测过程只在第一次算某座岛时写一行日志，便于下次现场定位。
    if areaID == nil then
        return nil;
    end

    local pid = current_pid();
    local rawOwner = nil;

    -- 同 area_oid 的理由：GetAreaFromID 只对当前 session 有效。
    local cur = nil;
    pcall(function() cur = Anno.Region_Current(); end);
    local useEngine = (cur == nil or region == nil or cur == region);

    local ok, decided = false, nil;
    if useEngine then
        ok, decided = pcall(function()
        local area = ts.Area.GetAreaFromID(areaID);
        if area == nil then
            return nil;
        end

        -- 1) 数值 Owner
        local n = tonumber(area.Owner);
        if n ~= nil then
            rawOwner = n;
            local mine = is_me(n, pid);
            if mine == true then
                _ownerProbe[tostring(areaID)] = "area.Owner=" .. tostring(n);
                return 0;
            end
        end

        -- 2) 布尔直读（属性 / 方法两种形态都试：C++ 绑定里同名成员可能是方法）
        local own = area.IsOwnedByCurrentParticipant;
        if type(own) ~= "boolean" and own ~= nil then
            local okm, mv = pcall(function() return area:IsOwnedByCurrentParticipant(); end);
            if okm and type(mv) == "boolean" then
                own = mv;
            else
                own = nil;
            end
        end
        if own == true then
            _ownerProbe[tostring(areaID)] = "IsOwnedByCurrentParticipant";
            return 0;
        end
        if own == false then
            _ownerProbe[tostring(areaID)] = "IsOwnedByCurrentParticipant=false raw=" .. tostring(rawOwner);
            -- 明确「不是我」时，绝不能把 0 透出去（上层把 0 当「我的」）。
            if rawOwner ~= nil and rawOwner ~= 0 then
                return rawOwner;
            end
            return 1;
        end

        return nil;
        end);
    end
    if ok and decided ~= nil then
        return decided;
    end

    -- 3) 用「本地玩家自己的建筑」反推（不依赖任何 Owner 属性，最可靠）
    --    放在 kontor 之前：kontor 的 GameObject.Owner 只有拿到正确 pid 才能比对，
    --    而 pid 取不到时会把「我的岛」误判成别人的。
    --    同样只能在当前 session 用（对象组查询只看当前 session）。
    if useEngine then
        local okSet, ownedSet = pcall(Anno.Areas_Owned_Get, region);
        if okSet and type(ownedSet) == "table" and ownedSet[areaID] == true then
            _ownerProbe[tostring(areaID)] = "player buildings on island";
            return 0;
        end
    end

    -- 4) 走该岛码头/贸易站的 GameObject.Owner
    --    注意：GameObject.Owner 返回的是「参与者 ID」（人类玩家从 1 开始），
    --    与 area.Owner 的「0 = 首位人类玩家」不是同一套编号。
    --    所以这里绝不能把 0 当成「我的」——0 很可能表示无主。
    local oid = area_oid(region, areaID);
    if oid ~= nil then
        local ok3, v = pcall(function()
            local g = ts.GetGameObject(oid);
            if g == nil then
                return nil;
            end
            local n = tonumber(g.Owner);
            if n == nil then
                return nil;
            end
            if pid ~= nil and n == pid then
                _ownerProbe[tostring(areaID)] = "GameObject.Owner=" .. tostring(n);
                return 0;
            end
            if pid == nil or n == 0 then
                -- 没有可比对的 pid，或对面无主：不下结论，交给下一路
                return nil;
            end
            return n;
        end);
        if ok3 and v ~= nil then
            return v;
        end
    end

    -- 5) 老路：文本嵌入
    if oid ~= nil then
        local ok4, ret = pcall(serpLight.DoForSessionGameObjectRaw,
                '[MetaObjects SessionGameObject(' .. tostring(oid) .. ') Area Owner]');
        if ok4 then
            local n = tonumber(ret);
            if n ~= nil then
                _ownerProbe[tostring(areaID)] = "embed Owner=" .. tostring(n);
                if is_me(n, pid) then
                    return 0;
                end
                return n;
            end
        end
    end

    _ownerProbe[tostring(areaID)] = "unknown (raw=" .. tostring(rawOwner) .. " pid=" .. tostring(pid) .. ")";
    return nil;
end

---@return string
function Anno.Area_Owner_Probe(areaID)
    return _ownerProbe[tostring(areaID)] or "";
end

function Anno.Area_CityName(region, areaID)
    local ok, name = pcall(function()
        local area = ts.Area.GetAreaFromID(areaID);
        if area == nil then
            return nil;
        end
        return area.CityName;
    end);
    if ok and name ~= nil and name ~= "" then
        return name;
    end

    local oid = area_oid(region, areaID);
    if oid == nil then
        return nil;
    end
    return serpLight.DoForSessionGameObjectRaw('[MetaObjects SessionGameObject(' .. tostring(oid) .. ') Area CityName]');
end

---

local type_Cargo = {
    Guid = "number",
    Value = "number"
}

function Anno. Ship_Cargo_Get(oid)
    return serpLight.GetVectorGuidsFromSessionObject('[MetaObjects SessionGameObject(' .. tostring(oid) .. ') ItemContainer Cargo Count]', type_Cargo);
end

function Anno.Ship_Cargo_Set(oid, slot, cargo)
    if cargo.Value == 1 then
        cargo.Value = 2;
    end
    return serpLight.DoForSessionGameObjectRaw('[MetaObjects SessionGameObject(' .. tostring(oid) .. ') ItemContainer CheatItemInSlot(' .. tostring(cargo.Guid) .. ',' .. tostring(cargo.Value / 2) .. ')]');
end

function Anno.Ship_Cargo_Clear(oid, slot)
    return serpLight.DoForSessionGameObjectRaw('[MetaObjects SessionGameObject(' .. tostring(oid) .. ') ItemContainer ClearSlot(' .. tostring(slot) .. '))]');
end

local guidToCargoSlotCapacity = {
    ["100438"] = 2, -- Schooner
    ["100441"] = 4, -- Clipper
    ["100443"] = 2, -- Monitor
    ["101121"] = 3, -- Flagship
    ["100439"] = 3, -- Frigate
    ["118718"] = 8, -- The Great Eastern
    ["1010062"] = 6, -- Cargo Ship
    ["132404"] = 6, -- World-Class Reefer

    ["1058"] = 3,
    ["1060"] = 8,
}

-- [TRAtUI] 原版这里对未知船型返回 -1，随后在 mod_trade_planner_ll.lua:361-367
-- 被判定为「货舱容量不足」而静默跳过 —— 表现为「接管成功，但船永远不动」。
-- DLC 船和 Ships 之类 mod 新增的船全部落在这个坑里。
-- 未知船型改用保守默认值，宁可低估运力多跑几趟，也不要完全不干活。
local DEFAULT_SLOT_CAPACITY = 2;

function Anno.Ship_Cargo_SlotCapacity(oid)
    local guid = serpLight.DoForSessionGameObjectRaw('[MetaObjects SessionGameObject(' .. tostring(oid) .. ') Static Guid]');
    local cap = guidToCargoSlotCapacity[tostring(guid)];
    if cap == nil then
        return DEFAULT_SLOT_CAPACITY;
    end
    return cap;
end

---

function Anno.Ship_Name_Get(oid)
    return serpLight.DoForSessionGameObjectRaw("[MetaObjects SessionGameObject(" .. tostring(oid) .. ") Nameable Name]");
end

function Anno.Ship_Name_Set(oid, name)
    return serpLight.DoForSessionGameObjectRaw("[MetaObjects SessionGameObject(" .. tostring(oid) .. ") Nameable Name(" .. tostring(name) .. ")]");
end

---

function Anno.Ship_IsMoving(oid)
    local ret = serpLight.DoForSessionGameObjectRaw("[MetaObjects SessionGameObject(" .. tostring(oid) .. ") Walking IsMoving(true)]");
    return ret == "true";
end

function Anno.Ship_MoveTo(oid, x, y)
    return serpLight.DoForSessionGameObjectRaw("[MetaObjects SessionGameObject(" .. tostring(oid) .. ") Walking DebugGoto(" .. tostring(x) .. "," .. tostring(y) .. ")]");
end

---

function Anno.Ship_TradeRoute_GetName(oid)
    return serpLight.DoForSessionGameObjectRaw("[MetaObjects SessionGameObject(" .. tostring(oid) .. ") TradeRouteVehicle RouteName]");
end

---

---@alias RegionID string

---@type RegionID
Anno.Region_OldWorld = "OW";
---@type RegionID
Anno.Region_NewWorld = "NW";
---@type RegionID
Anno.Region_Enbesa = "EN";
---@type RegionID
Anno.Region_Arctic = "AR";
---@type RegionID
Anno.Region_CapeTrelawney = "CT";

---@type table<string, RegionID>
local sessions = {
    ["180023"] = Anno.Region_OldWorld,
    ["180025"] = Anno.Region_NewWorld,
    ["112132"] = Anno.Region_Enbesa,
    ["180045"] = Anno.Region_Arctic,
    ["110934"] = Anno.Region_CapeTrelawney,
}

---@return RegionID
function Anno.Region_Current()
    local _session = session.getSessionGUID();
    local region = sessions[tostring(_session)];
    return region;
end

---

----- high level region functions -----

local function _Ships_GetAll()
    local ret = {};

    -- 首选：封装版属性查询。
    -- [TRAtUI] 外层 pcall 是必须的：该函数内部任何一个成员抛错都会让整轮返回 nil，
    -- 随后 Region_RefreshCache 失败 → Region_IsCached 永远为 false →
    -- planner 的 per-region 循环永远停在「please enter region」，
    -- 表现就是「接管了但船一动不动」。所以宁可走兜底也不能让它整体挂掉。
    local ok, objs = pcall(serpLight.GetCurrentSessionObjectsFromLocaleByProperty, "Walking");
    if ok and type(objs) == "table" then
        for oid in pairs(objs) do
            if oid ~= nil then
                table.insert(ret, oid);
            end
        end
        return ret;
    end

    -- 兜底：直接遍历对象组，逐项隔离，坏成员跳过。
    local okGroup, userdatas = pcall(session.getObjectGroupByProperty, serpLight.PropertiesStringToID.Walking);
    if okGroup and type(userdatas) == "table" then
        for _, ud in ipairs(userdatas) do
            local okOid, oid = pcall(serpLight.get_OID, ud);
            if okOid and oid ~= nil then
                table.insert(ret, oid);
            end
        end
    end

    return ret;
end

local function _AreaID_To_ItsOID_Build()
    local ret = {};

    -- 首选：从「区域网格」缓存拿到本区域所有 areaID，再用引擎的 KontorID 直接取码头 OID。
    -- 旧实现靠遍历 LoadingPier 属性组反查，实测 28 座岛只建出 1 条记录，
    -- 直接导致「只有一座岛被认成我方」。
    local region = Anno.Region_Current();
    local okGrid, grid = pcall(cache.Get, "map_scanner.Session(P11)", region);
    if okGrid and type(grid) == "table" then
        local seen = {};
        for _, cell in pairs(grid) do
            if type(cell) == "table" and cell.area_id ~= nil then
                seen[cell.area_id] = true;
            end
        end
        -- [TRAtUI][v1.9.4] 映射表同样以「本地建筑 OID」为准；KontorID 只作最后的补充。
        local oidMap = nil;
        if Anno.Areas_Owned_OID_Get ~= nil then
            local okOwn, m = pcall(Anno.Areas_Owned_OID_Get, region);
            if okOwn and type(m) == "table" then
                oidMap = m;
            end
        end
        for areaID in pairs(seen) do
            local oid = nil;
            if oidMap ~= nil then
                oid = tonumber(oidMap[areaID] or oidMap[tostring(areaID)]);
            end
            if oid == nil then
                oid = kontor_oid(areaID);
            end
            if oid ~= nil and oid >= 1000000 then
                ret[tostring(areaID)] = oid;
            end
        end
    end

    if next(ret) ~= nil then
        return ret;
    end

    -- 兜底：旧的码头反查（网格还没建时走这里）
    local os = session.getObjectGroupByProperty(serpLight.PropertiesStringToID.LoadingPier);
    for _, v in pairs(os) do
        -- [TRAtUI] get_OID 靠 :getName() 里正则抠 "oid xxx"，对部分对象会返回 nil。
        -- 原版直接把 nil 传给 objectAccessor.GameObject()，触发
        -- "no matching overload found"（ts.GetGameObject(nil)），导致整个映射构建失败、
        -- ui_companion 的 remember_camera_anchor 崩掉、扫描一开始就中止。
        -- 这里逐项隔离，坏掉的对象跳过即可，不牵连其余岛屿。
        local okOid, oid = pcall(serpLight.get_OID, v);
        if okOid and oid ~= nil then
            local okArea, areaID = pcall(function()
                return serpLight.AreatableToAreaID(objectAccessor.GameObject(oid).Area.ID);
            end);
            if okArea and areaID ~= nil then
                ret[tostring(areaID)] = oid;
            end
        end
    end
    return ret;
end

local function _AreasToResidenceGuids()
    local _residenceGuids = {};
    local os = session.getObjectGroupByProperty(serpLight.PropertiesStringToID.Residence7);
    for _, v in pairs(os) do
        -- [TRAtUI] 逐项隔离：get_OID 可能返回 nil（空指针成员），
        -- 原版会把 nil 传给 GameObject 直接抛错，导致整张缓存表建不出来。
        local ok = pcall(function()
            local oid = serpLight.get_OID(v);
            if oid == nil then
                return;
            end
            local o = objectAccessor.GameObject(oid);
            local areaID = serpLight.AreatableToAreaID(o.Area.ID);
            local guid = o.Static.Guid;

            if _residenceGuids[areaID] == nil then
                _residenceGuids[areaID] = {};
            end
            _residenceGuids[areaID][guid] = true;
        end);
    end

    local ret = {};
    for areaID, guidSet in pairs(_residenceGuids) do
        local areaIdStr = tostring(areaID);
        ret[areaIdStr] = {};
        for guid, _ in pairs(guidSet) do
            table.insert(ret[areaIdStr], guid);
        end
    end
    return ret;
end

---@alias GUID number
---@alias OID number
---@alias OID_str string

---@return table<AreaID_str, table<OID_str, GUID[]>>
local function _BuildingsWithSockets()
    local ret = {};
    local os = Anno.Objects_GetAll_ByProperty(serpLight.PropertiesStringToID.Distribution);
    for oid, _ in pairs(os) do
        -- [TRAtUI] 逐项隔离，理由同 _AreasToResidenceGuids。
        pcall(function()
            local areaId = serpLight.AreatableToAreaID(objectAccessor.GameObject(oid).Area.ID);
            local areaIdStr = tostring(areaId);
            local oidStr = tostring(oid);

            local sockets = Anno.Object_ItemContainer_GetSockets(oid);
            if #sockets > 0 then

                local socketItemsGuids = {};
                for _, v in ipairs(sockets) do
                    table.insert(socketItemsGuids, v.Guid);
                end

                if ret[areaIdStr] == nil then
                    ret[areaIdStr] = {};
                end
                ret[areaIdStr][oidStr] = socketItemsGuids;
            end
        end);
    end
    return ret;
end

---

function Anno.Internal._AreasToProductionGuids()
    local os = {};
    local factories = session.getObjectGroupByProperty(serpLight.PropertiesStringToID.Factory7);
    for _, v in pairs(factories) do
        table.insert(os, serpLight.get_OID(v));
    end
    local recipeBuildings = session.getObjectGroupByProperty(serpLight.PropertiesStringToID.RecipeBuilding);
    for _, v in pairs(recipeBuildings) do
        table.insert(os, serpLight.get_OID(v));
    end
    local buffFactories = session.getObjectGroupByProperty(serpLight.PropertiesStringToID.BuffFactory);
    for _, v in pairs(buffFactories) do
        table.insert(os, serpLight.get_OID(v));
    end

    local guids = {};
    for _, v in ipairs(os) do
        -- [TRAtUI] 逐项隔离：get_OID 可能返回 nil，原版会把 nil 传给 GameObject 抛错。
        pcall(function()
            local oid = (v);
            if oid == nil then
                return;
            end
            local o = objectAccessor.GameObject(oid);
            local areaID = serpLight.AreatableToAreaID(o.Area.ID);
            local guid = o.Static.Guid;

            if guids[areaID] == nil then
                guids[areaID] = {};
            end
            guids[areaID][guid] = true;
        end);
    end

    local ret = {};
    for areaID, guidSet in pairs(guids) do
        local areaIdStr = tostring(areaID);
        ret[areaIdStr] = {};
        for guid, _ in pairs(guidSet) do
            table.insert(ret[areaIdStr], guid);
        end
    end
    return ret;
end

---

function Anno.Region_AreaID_To_OID(region)
    local currentRegion = Anno.Region_Current();
    if currentRegion ~= region then
        return cache.Get("Anno.AreaID_To_ItsOID", region);
    end
    return cache.GetOrSet("Anno.AreaID_To_ItsOID", _AreaID_To_ItsOID_Build, region);
end

function Anno.Region_Ships_GetAll(region)
    local currentRegion = Anno.Region_Current();
    -- [TRAtUI] 磁盘缓存可能损坏/不存在，读失败时返回 nil（调用方需容忍），
    -- 而不是让异常冒到 planner 循环里。
    if currentRegion ~= region then
        local ok, v = pcall(cache.Get, "Anno.Ships_GetAll", region);
        if ok then
            return v;
        end
        return nil;
    end
    local ok, v = pcall(cache.GetOrSet, "Anno.Ships_GetAll", _Ships_GetAll, region);
    if ok then
        return v;
    end
    return _Ships_GetAll();
end

function Anno.Region_ResidenceGUIDs(region)
    local currentRegion = Anno.Region_Current();
    if currentRegion ~= region then
        return cache.Get("Anno.AreasToResidenceGuids", region);
    end
    return cache.GetOrSet("Anno.AreasToResidenceGuids", _AreasToResidenceGuids, region);
end

function Anno.Region_ProductionGUIDs(region)
    local currentRegion = Anno.Region_Current();
    if currentRegion ~= region then
        return cache.Get("Anno.AreasToProductionGuids", region);
    end
    return cache.GetOrSet("Anno.AreasToProductionGuids", Anno.Internal._AreasToProductionGuids, region);
end

function Anno.Region_BuildingsWithSockets(region)
    local currentRegion = Anno.Region_Current();
    if currentRegion ~= region then
        return cache.Get("Anno.BuildingsWithSockets", region);
    end
    return cache.GetOrSet("Anno.BuildingsWithSockets", _BuildingsWithSockets, region);
end

---

function Anno.Region_IsCached(region)
    return cache.Exists("Anno.AreaID_To_ItsOID", region)
            and cache.Exists("Anno.Ships_GetAll", region)
            and cache.Exists("Anno.AreasToResidenceGuids", region)
            and cache.Exists("Anno.AreasToProductionGuids", region)
            and cache.Exists("Anno.BuildingsWithSockets", region);
end

function Anno.Region_CanCache(region)
    local currentRegion = Anno.Region_Current();
    return currentRegion == region;
end

-- no camera jumps
function Anno.Region_RefreshCache()
    local currentRegion = Anno.Region_Current();
    -- [TRAtUI] 每一项独立隔离：原来任意一张表构建失败都会抛出去，
    -- 直接打死 planner 的 per-region 循环。现在单项失败只丢自己。
    pcall(cache.Set, "Anno.AreaID_To_ItsOID", _AreaID_To_ItsOID_Build, currentRegion);
    pcall(cache.Set, "Anno.Ships_GetAll", _Ships_GetAll, currentRegion);
    pcall(cache.Set, "Anno.AreasToResidenceGuids", _AreasToResidenceGuids, currentRegion);
    pcall(cache.Set, "Anno.AreasToProductionGuids", Anno.Internal._AreasToProductionGuids, currentRegion);
    pcall(cache.Set, "Anno.BuildingsWithSockets", _BuildingsWithSockets, currentRegion);
end

---

return Anno
