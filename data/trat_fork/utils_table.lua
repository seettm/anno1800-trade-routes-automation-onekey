local utable = {};

function utable.length(t)
    -- [TRAtUI] pairs(nil) 会抛错。这个函数是整条链路里唯一的「判空」入口，
    -- 上游（Anno.Ships_GetAll）在区域未缓存时确实会返回 nil，必须容忍。
    if type(t) ~= "table" then
        return 0;
    end
    local count = 0;
    for _, _ in pairs(t) do
        count = count + 1;
    end
    return count;
end

return utable;
