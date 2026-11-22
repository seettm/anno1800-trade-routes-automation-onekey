local Anno = require("trat_fork/anno_interface");
local async = require("trat_fork/utils_async");

local ShipCmd = {};

function ShipCmd.MoveShipToAsync(oid, x, y)
    Anno.Ship_MoveTo(oid, x, y)
    async.sleep(1)
    -- [TRAtUI][v1.9.5] 加超时上限。
    -- 原来是无上限 `await(not IsMoving)`：船一旦到不了目标点
    -- （坐标落在水域外 / 寻路失败 / 被别的 mod 拦住），这个 async 任务就永久挂起，
    -- 这艘船永远被判成「任务中」，之后再也不会被派新单。
    -- 玩家看到的就是——船开出去一半，然后整个系统再无动静（19:15:21 的实际现场）。
    -- 120 ticks ≈ 200 秒游戏时间，跨岛航行足够，超时就当到达，继续装货。
    local ticks = 0
    local timedOut = false
    async.await(function()
        ticks = ticks + 1
        if ticks >= 120 then
            timedOut = true
            return true
        end
        return not Anno.Ship_IsMoving(oid)
    end)
    if timedOut then
        local L = _G["trat_fork_logger"]
        if L ~= nil then
            L.logf("[TRAtUI] 船只 %s 移动超时（120 ticks），按已到达处理，继续装货", tostring(oid))
        end
    end
end

function ShipCmd.WaitUntilShipStops(oid)
    -- [TRAtUI][v1.9.5] 同样加超时，避免整条协程被一艘卡住的船拖死。
    local ticks = 0
    async.await(function()
        ticks = ticks + 1
        if ticks >= 120 then
            return true
        end
        return not Anno.Ship_IsMoving(oid)
    end)
end

function ShipCmd.WaitUntilShipMoves(oid, timeout)
    local ticks = 0
    async.await(function()
        ticks = ticks + 1
        if timeout and ticks >= timeout then
            return true -- Timeout reached
        end
        return Anno.Ship_IsMoving(oid)
    end)
    return ticks < (timeout or math.huge) -- Returns false if timed out
end

return ShipCmd
