local serpLight = require("trat_fork/serp/lighttools");
local objectAccessor = require("trat_fork/anno_object_accessor");

local Anno = require("trat_fork/anno_interface");

local function MoveCameraTo(x, y)
    ts.SessionCamera.ToWorldPos(x, y);
end

local function sleep(frames)
    for i = 1, frames do
        coroutine.yield();
    end
end

local NOT_ACCESSIBLE = "not_accessible";
local SOMETHING_THERE = "something_there";
local LAND = "land";
local WATER = "water";
local WATER_ACCESS_POINT = "water_access_point";

local function IdentifyCoordinates(x, y)
    MoveCameraTo(x, y);
    game.startMouseMode(2001044)
    sleep(1);

    -- note: switching to build mode to check the cost and short-circuit function DID NOT WORK for me
    -- i did not debug this, from logs i saw destructible check being unreliable (`NOT_ACCESSIBLE` when there was something)

    local m1 = ts.Target.DestructionPayback.Empty;
    local m2 = ts.Target.DestructionCosts.Empty;
    local canBeDestroyed = not m1 or not m2;
    game.startMouseMode(0);
    game.startBuild(1000178);
    sleep(1);

    local hasCost = not ts.BuildMode.Costs.Empty;
    local cost = ts.BuildMode.Costs.MoneyCost;
    game.startBuild(0);

    -- no sleep(1) here, because we don't need to wait for `game.startBuild(0)` results

    local result;
    if hasCost then
        if cost == 3 then
            result = LAND;
        elseif cost == 20 then
            result = WATER;
        else
            result = SOMETHING_THERE;
        end
    else
        if canBeDestroyed then
            result = SOMETHING_THERE;
        else
            result = NOT_ACCESSIBLE;
        end
    end

    return {
        Destruction = canBeDestroyed,
        Cost = cost,
        Result = result
    }
end

local function encodeResult(r)
    if r == LAND then
        return "L";
    end
    if r == WATER then
        return "W";
    end
    if r == SOMETHING_THERE then
        return "S";
    end
    if r == NOT_ACCESSIBLE then
        return "N";
    end
    if r == WATER_ACCESS_POINT then
        return "w";
    end
    return "?";
end

---


local function PackCoordinates(x, y)
    return string.format("%d,%d", x, y);
end

local function UnpackCoordinates(key)
    -- [TRAtUI] 原实现对 key 不含逗号的情况会拿 nil 做算术（commaPos-1），
    -- 缓存文件格式一旦不符（旧版本写过、被外部工具改过）就是硬崩。
    local xs, ys = tostring(key):match("^%s*(-?%d+)%s*,%s*(-?%d+)%s*$");
    if xs == nil then
        return nil, nil;
    end
    return tonumber(xs), tonumber(ys);
end

---

local P25 = 25;
local P11 = 11;

local presets = {
    --P25 = {
    --    X0 = 420, -- it is more of 450
    --    Y0 = 350, -- it should be 250 (450 * 9/16)
    --    DeltaX = 420,
    --    DeltaY = 233, -- 350 * (2/3)
    --    X1 = 1900,
    --    Y1 = 1750
    --},
    P11 = {
        X0 = 250,
        Y0 = 250,
        DeltaX = 90,
        DeltaY = 50,
        X1 = {
            [Anno.Region_OldWorld] = 1820,
            [Anno.Region_NewWorld] = 2120,
        },
        Y1 = {
            [Anno.Region_OldWorld] = 1820,
            [Anno.Region_NewWorld] = 2120,
        }
    }
};

local preset = "P11";

--session.setCameraToPreset(preset);

local cityNameToShortName = {};
local shortNameToCityName = {};

local function getCityShortName(cityName)
    local sn = cityNameToShortName[cityName];
    if sn == nil then
        for i = 1, #cityName do
            local candidate = string.sub(cityName, i, i);
            if shortNameToCityName[candidate] == nil then
                cityNameToShortName[cityName] = candidate;
                shortNameToCityName[candidate] = cityName;
                return candidate;
            end
        end
    end
    return sn;
end

local function sessionScanner(region)
    local cur = Anno.Region_Current()
    if region == nil then
        region = cur
    end

    -- [TRAtUI] 网格采样必须发生在目标区域里：镜头瞬移只对「当前 session」有意义。
    -- 原实现既不接收 region 参数也不校验，一旦调用方传的 region 与所在地不符
    -- （切区域瞬间、或对另一个区域强制重扫），就会把 A 区域的采样结果
    -- 写成 B 区域的缓存 —— 之后 B 区域全是别人的 areaID，ship 永远不动且零报错。
    if cur ~= nil and region ~= cur then
        error(string.format("[TRAtUI] 地图网格扫描被拒绝：请求区域=%s 当前区域=%s。请在目标区域内再扫描。",
                tostring(region), tostring(cur)))
    end

    local p = presets[preset]
    local yStart = p and p.Y1[region]
    local xEnd = p and p.X1[region]
    if region == nil or yStart == nil or xEnd == nil then
        -- [TRAtUI] 原实现直接把 nil 丢进数值 for，抛
        -- "'for' initial value must be a number"，且发生在第一个采样点之前，
        -- 表现为「按了扫描键，什么都没有，日志也没有」。
        error(string.format("[TRAtUI] 区域 %s 暂不支持地图网格扫描（仅支持旧世界 OW / 新世界 NW）。",
                tostring(region)))
    end

    local results = {};

    for y = yStart, p.Y0, -p.DeltaY do
        for x = p.X0, xEnd, p.DeltaX do
            x = math.floor(x);
            y = math.floor(y);

            MoveCameraTo(x, y);
            sleep(1);

            -- [TRAtUI] 逐点隔离：整轮要采样数百次，任何单点抛错都不能带走整次扫描。
            -- 原版这里直接链式取 AreaFromID(areaID).CityName，areaID 为 nil 时会
            -- 抛 "no matching overload found"，让 576 次瞬移白跑。
            local okArea, areaID = pcall(function()
                return serpLight.AreatableToAreaID(ts.Area.Current.ID);
            end);

            if okArea and areaID ~= nil then
                local cityIndexStr = "";

                local okCity = pcall(function()
                    local q = objectAccessor.AreaFromID(areaID).CityName;
                    if q == nil or q == "" then
                        cityIndexStr = ".";
                    else
                        local sn = getCityShortName(q);
                        cityIndexStr = sn;
                    end
                end);
                if not okCity then
                    cityIndexStr = ".";
                end

                results[PackCoordinates(x, y)] = { city_index = cityIndexStr, area_id = areaID };
            end
        end
    end

    return results;
end

---

local function sessionScanner_areaGrids(res)
    local areaGrids = {};

    -- [TRAtUI] 缓存未命中/文件损坏时 res 可能是 nil，原实现直接 pairs(nil) 抛错；
    -- 里面的 v 也可能是 true/字符串（旧格式），v.area_id 为 nil 时
    -- `areaGrids[nil] = grid` 会报 "table index is nil"。
    if type(res) ~= "table" then
        return areaGrids;
    end

    for key, v in pairs(res) do
        if type(v) == "table" and v.area_id ~= nil and v.city_index ~= "." then
            local x, y = UnpackCoordinates(key);
            if x == nil or y == nil then
                goto continue;
            end
            local areaId = v.area_id;

            local grid = areaGrids[areaId];
            if grid == nil then
                grid = {
                    min_x = x,
                    min_y = y,
                    max_x = x,
                    max_y = y,
                };
            end
            if x < grid.min_x then
                grid.min_x = x;
            end
            if x > grid.max_x then
                grid.max_x = x;
            end
            if y < grid.min_y then
                grid.min_y = y;
            end
            if y > grid.max_y then
                grid.max_y = y;
            end
            areaGrids[areaId] = grid;
        end

        :: continue ::
    end

    return areaGrids;
end

---

local function areaScanner_grid(minX, minY, maxX, maxY)
    for x = minX, maxX, 10 do
        for y = minY, maxY, 10 do
            local res = IdentifyCoordinates(x, y);

            local c = "";
            if res.Result == LAND then
                c = "L";
            end
            if res.Result == WATER then
                c = "W";
            end
            if res.Result == SOMETHING_THERE then
                c = "S";
            end
            if res.Result == NOT_ACCESSIBLE then
                c = "N";
            end
            L.logf("%d,%d,%s", x, y, c);
        end
    end
end

---

local function areaScanner_dfs(L, minX, minY, maxX, maxY, resolution)
    -- [TRAtUI] resolution 为 nil/0 时：nil 会在构造 UP/DOWN 时抛算术错误，
    -- 0 则让 while 循环永不推进（每个格子都切镜头，表现为永久卡死且无报错）。
    resolution = tonumber(resolution);
    if resolution == nil or resolution <= 0 then
        error("[TRAtUI] Area_WaterPoints: invalid resolution " .. tostring(resolution));
    end
    if minX == nil or minY == nil or maxX == nil or maxY == nil or minX > maxX or minY > maxY then
        error(string.format("[TRAtUI] Area_WaterPoints: invalid bounds (%s,%s)-(%s,%s)",
                tostring(minX), tostring(minY), tostring(maxX), tostring(maxY)));
    end
    local dx = resolution;
    local dy = resolution;

    -- then, go ccw around border
    local UP = { dx = 0, dy = dy, name = "up" };
    local DOWN = { dx = 0, dy = -dy, name = "down" };
    local LEFT = { dx = -dx, dy = 0, name = "left" };
    local RIGHT = { dx = dx, dy = 0, name = "right" };

    local CCW = {
        [UP] = LEFT,
        [LEFT] = DOWN,
        [DOWN] = RIGHT,
        [RIGHT] = UP
    };
    local CW = {
        [UP] = RIGHT,
        [RIGHT] = DOWN,
        [DOWN] = LEFT,
        [LEFT] = UP
    };
    local INVERT = {
        [UP] = DOWN,
        [DOWN] = UP,
        [LEFT] = RIGHT,
        [RIGHT] = LEFT
    };

    local function encodeDirection(d)
        if d == UP then
            return "U";
        end
        if d == DOWN then
            return "D";
        end
        if d == LEFT then
            return "L";
        end
        if d == RIGHT then
            return "R";
        end
        return "?";
    end

    ---

    local visited = {};
    local visitedResult = {};

    local function _visit(_x, _y, srcResult)
        local outOfBounds = _x < minX or _x > maxX or _y < minY or _y > maxY;
        local srcIsNotAccessible = srcResult == NOT_ACCESSIBLE;
        if outOfBounds and srcIsNotAccessible then
            return true, NOT_ACCESSIBLE;
        end

        local key = PackCoordinates(_x, _y);
        if visited[key] then
            return true, visitedResult[key];
        end

        local u = PackCoordinates(_x + UP.dx, _y + UP.dy);
        local d = PackCoordinates(_x + DOWN.dx, _y + DOWN.dy);
        local l = PackCoordinates(_x + LEFT.dx, _y + LEFT.dy);
        local r = PackCoordinates(_x + RIGHT.dx, _y + RIGHT.dy);
        local uT, uR = visited[u], visitedResult[u];
        local dT, dR = visited[d], visitedResult[d];
        local lT, lR = visited[l], visitedResult[l];
        local rT, rR = visited[r], visitedResult[r];
        if uT and dT and lT and rT then
            if uR == LAND and dR == LAND and lR == LAND and rR == LAND then
                visited[key] = true;
                visitedResult[key] = LAND;
                return true, LAND;
            end
        end

        local res = IdentifyCoordinates(_x, _y);
        visited[key] = true;
        visitedResult[key] = res.Result;
        return false, res.Result;
    end

    ---

    -- start mid-top
    local x0 = math.floor((minX + maxX) / 2 / 10) * 10;
    local y0 = maxY;

    -- go to bottom until we hit something
    while y0 >= minY do
        local _, res = _visit(x0, y0, NOT_ACCESSIBLE);
        L.logf("%d,%d,%s,%s", x0, y0, encodeResult(res), encodeDirection(DOWN));
        if res ~= NOT_ACCESSIBLE then
            break ;
        end

        y0 = y0 - dy;
        :: continue ::
    end

    L.logf("Starting DFS at %d,%d", x0, y0);
    L.logf("%d,%d,Y,D", x0, y0);

    local _dfs_visit_inv = 0;

    local function _dfs_visit(x, y, dir)
        local function is_origin(_x, _y)
            return _x == x0 and _y == y0 and dir ~= DOWN;
        end
        local function halt_on_origin(_x, _y)
            if is_origin(_x, _y) then
                L.log("DFS visit halting due to return to origin");
                _dfs_visit_inv = 10000;
                return true;
            end
            return false;
        end
        local function halt_on_too_many_invocations()
            if _dfs_visit_inv > 200 then
                L.log("DFS visit halting due to too many invocations");
                return true;
            end
            return false;
        end
        local function halt()
            if halt_on_origin(x, y) then
                return true;
            end
            if halt_on_too_many_invocations() then
                return true;
            end
            return false;
        end
        local function log_dfs(_x, _y, _res, _dir)
            L.logf("%d,%d,%s,%s", _x, _y, encodeResult(_res), encodeDirection(_dir));
        end

        _dfs_visit_inv = _dfs_visit_inv + 1;
        if halt() then
            return ;
        end

        local t = CCW[dir];
        while true do
            if halt_on_too_many_invocations() then
                return ;
            end

            local tX = x + t.dx;
            local tY = y + t.dy;

            local xy = PackCoordinates(tX, tY);
            local xy_res = visitedResult[xy];

            local isVisited, res = _visit(tX, tY, xy_res);
            log_dfs(tX, tY, res, t);
            if isVisited or res == NOT_ACCESSIBLE then
                if halt_on_origin(tX, tY) then
                    return ;
                end
                goto continue;
            end

            _dfs_visit(tX, tY, t);

            :: continue ::
            t = CW[t];

            if t == INVERT[dir] then
                break ;
            end
        end
    end

    L.logf("start at %s time", os.date("%Y-%m-%d %H:%M:%S"));
    _dfs_visit(x0, y0, DOWN);
    L.logf("end at %s time", os.date("%Y-%m-%d %H:%M:%S"));

    return visitedResult;
end

---

local function visualizationTsvs(L, areas)
    for areaID, grid in pairs(areas) do
        local area = objectAccessor.AreaFromID(areaID);
        L.logf("%s / %d (owner=%d %s) grid{ minX=%d minY=%d maxX=%d maxY=%d }",
                area.CityName,
                areaID,
                area.Owner,
                area.OwnerName,
                tostring(grid.min_x),
                tostring(grid.min_y),
                tostring(grid.max_x),
                tostring(grid.max_y)
        );

        if area.Owner ~= 0 then
            goto continue;
        end

        local scan = cache.getOrSet(function(a, b, c, d, e)
            return map_scanner.Area_WaterPoints(L, a, b, c, d, e);
        end, "areaScanner_dfs", grid.min_x, grid.min_y, grid.max_x, grid.max_y, 20);
        L.logf("area returned %d scanned objects", #scan);

        local cityName = area.CityName:gsub("%s+", "_");

        -- [TRAtUI] 同 hl：用 areaID 而非中文岛名做文件名，避免 io.open 失败。
        local lq = L.logger("area_scan_" .. tostring(areaID) .. ".tsv");
        for k, v in pairs(scan) do
            local x, y = map_scanner.UnpackCoordinates(k);
            lq.logf("%d,%d,%s", x, y, map_scanner.Coordinate_ToLetter(v));
        end

        :: continue ::
    end
end

---

return {
    Session_Areas_Grid = sessionScanner,
    Area_WaterPoints = areaScanner_dfs,
    Session_Areas_Rectangles = sessionScanner_areaGrids,

    Coordinate_Land = LAND,
    Coordinate_Water = WATER,
    Coordinate_SomethingThere = SOMETHING_THERE,
    Coordinate_NotAccessible = NOT_ACCESSIBLE,
    Coordinate_WaterAccessPoint = WATER_ACCESS_POINT,
    Coordinate_ToLetter = encodeResult,

    PackCoordinates = PackCoordinates,
    UnpackCoordinates = UnpackCoordinates,
}
