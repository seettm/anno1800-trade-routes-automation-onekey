# Trade Routes Automation — One-Key Edition

《纪元 1800》(Anno 1800) 贸易航线自动化 mod，**一键操控版**。

基于 [kr3v 的 Trade Routes Automation](https://github.com/kr3v/anno1800-trade-routes-automation) 改造而来，
把原本"必须手动建一条名字叫 `TRA_OW` 的贸易航线、再把船塞进去"的流程，
简化成 **选船 → 按一下快捷键 → 剩下的交给调度器**。

> 当前版本：**v1.9.7**
> 适用：Anno 1800 + 全部 DLC（旧世界 OW / 新世界 NW）

---

## 它做什么

1. **扫描区域**：把当前区域所有岛屿、水域采样点建成一张网格缓存。
2. **读真实库存**：直接走引擎接口读每座岛每种货的现有量与仓容量。
3. **算供需**：按货物类型分两套水位（见下节）。
4. **派船**：挑一艘空闲的被接管船，开去装货、返航卸货。
5. **循环**：卸完自动接下一单，全程无人值守。

整个过程的状态**印在船名上**（这游戏没有任何 Lua 屏幕提示接口，实测 5 条候选全部失败）。

---

## 调度阈值（v1.11.0 起）

原版所有环节都用一个硬编码的 **50** 当最小发运量，结果一座岛饿着、另一座岛还剩 30 吨，
调度器会判定"没有任何岛屿可供"，船一动不动。现在按货物类型分开：

| 货物类型 | 判定方式 | 最小发运量 |
|---|---|---|
| **生活必需品**（居民消耗品） | 双水位：低于容量的 **60%** 就补货；高于容量的 **30%** 就出货 | **10** |
| 其它（工业原料、建材） | 与目标量的差值 | 50（原版行为） |

"生活必需品"没有写死 GUID，而是直接读 `residence_info.json` 里各级住宅的消耗列表 ——
新 DLC、新人口等级只要被扫描到就自动纳入。

想调松紧不用改代码，改 `data/trat_fork/mod_trade_planner_ll.lua` 顶部的 `Policy`：

```lua
TradePlannerLL.Policy = {
    minTransferNormal = 50,    -- 非必需品最小发运量
    minTransferBasic  = 10,    -- 必需品最小发运量（调小=更积极，改 50=退回原版）
    basicTargetRatio  = 0.6,   -- 低于容量的这个比例就补货
    basicKeepRatio    = 0.3,   -- 高于这个比例的部分才会外运
    basicNeedEnabled  = true,  -- false = 全部按 50 处理
    extraBasicGoods   = {},    -- 手工追加算作必需品的 GUID，如 {120008} 木材
};
```

---

## 安装

1. 解压到：
   ```
   C:\Users\<用户名>\Documents\Anno 1800\mods\
   ```
   确保路径形如 `...\mods\TradeRoutesAutomation_OneKey\modinfo.json`。

   > ⚠️ **必须放 `Documents\Anno 1800\mods\`**。
   > 新版内置加载器不扫描游戏根目录的 `mods\`，放错位置会导致"装了什么都没发生"。

2. 启动游戏 → 读取存档 → 弹出「模块」窗口时**给本 mod 打勾**（本地 mod 默认是「未启用」）。
3. 进存档，选中一艘船，按 `Shift + O`。

---

## 快捷键

| 按键 | 功能 | 屏幕反馈 |
|---|---|---|
| `Shift + O` | 接管当前选中的船 | 船名变成 `TRA_...` |
| `Shift + P` | 扫描当前区域（已有缓存会跳过） | 画面自动抖动、镜头移动 |
| `Shift + F` | 强制重扫（忽略缓存） | 同上 |
| `Shift + K` | 状态自检 + 必要时就地复活调度器 | 船名刷新 |
| `Shift + U` | 开 / 关自动化 | 前缀 `TRA_` ↔ `TRA-OFF_` |
| `Shift + I` | 释放所有被接管的船 | 船名还原 |

`Ctrl + 同字母` 为备用键（部分输入法/键位下 `Shift+字母` 不送达时可用）。

---

## 船名看板

所有被接管的船会显示同一行状态，每 10 秒自动刷新：

```
TRA_运行_3艘_Wood200
```

| 片段 | 含义 |
|---|---|
| `运行` | 调度正常 |
| `待扫描` | 区域网格为空，按 `Shift + P` |
| `已停止` | 调度协程不在了，按 `Shift + K` 尝试复活 |
| `卡住` | 协程还在但 90 秒无心跳，多半在等船靠岸 |
| `已关闭` | 按过 `Shift + U` |
| `3艘` | 已接管的船数 |
| `Wood200` | 当前最大缺口（货物 + 数量）；`平衡` 表示无需调货 |

完整需求清单（每种货物缺多少、缺在哪座岛）另写在：

```
C:\Users\<用户名>\Documents\Anno 1800\log\TRAtUI_status.txt
```

---

## 常见问题

**按了快捷键毫无反应**
先确认 mod 在游戏内模块列表里是**已勾选**状态。本地 mod 出现在列表里 ≠ 生效。

**船一动不动**
按顺序查：
1. `Shift + K` 看状态。显示 `待扫描` → 按 `Shift + P`。
2. 扫描时必须**人在该区域画面里**，不要停在世界地图总览。
3. 扫描会带动镜头跳动，属正常现象，别碰鼠标。
4. 切到窗口外游戏会暂停逻辑帧，船必然不动——**留在游戏画面里**。
5. 还是没有？看 `log\` 下的 `TrRAt_*_base.log` 与 `trade-execute-iteration.log`。

**扫描结束没看到任何提示**
这游戏不提供 Lua 提示接口。扫描完成的唯一迹象是 `base.log` 里出现
`扫描结束：新扫 N 座 / 跳过 M 座 / 失败 0 座`。

**`Production GUID 1900xxxxxx not found in AnnoInfo.FactoriesInfo`**
部分 DLC / 其他 mod 的工厂不在供给表内，属已知限制，不影响原版建筑。

---

## 分支说明

| 分支 | 用途 |
|---|---|
| `main` | 稳定发布版，与 Releases 中的压缩包一一对应 |
| `feature/game-ui` | 试验用：直接把状态面板做成游戏原生 UI 资产（menu 模板 + 数据绑定），失败也不影响 `main` |

---

## 打包（仅开发者需要）

```bash
python tools/build_release.py
# 产物默认在 mods 目录之外：<Anno 1800>\_build\TradeRoutesAutomation_OneKey_v<版本>.zip
```

> ⚠️ **绝对不要把 zip 放在 mod 目录里面**（比如 `mods\TradeRoutesAutomation_OneKey\dist\`）。
>
> 游戏内置加载器会**递归扫描** mods 目录，把 zip 当成第二个 mod 加载。日志里会多出一条：
>
> ```
> Load TradeRoutesAutomation_OneKey_v1.9.7 (unversioned) from ...\dist\...zip
> ```
>
> 后果：同一个 mod 加载两遍，两份相同 GUID 的 Trigger（1475200100）互相冲突，
> 主脚本 `_main.lua` 直接不执行 —— 所有热键 `require` 失败，表现就是"按了完全没反应"。
>
> 打包脚本已内置保护：输出目录落在 mod 目录内会直接拒绝并报错退出。

---

## 来源与致谢

- 原作者：[kr3v](https://github.com/kr3v/anno1800-trade-routes-automation) —— 自动化调度核心逻辑
- 依赖库（已随包附带，遵循各自许可）：
  - `serp/lighttools.lua`、`serp/bint.lua` —— Serpens66 的 Anno Lua 工具库
  - `rxi/json.lua` —— [rxi/json.lua](https://github.com/rxi/json.lua) (MIT)
  - `iskolbin/base64.lua` —— [iskolbin/lbase64](https://github.com/iskolbin/lbase64) (MIT)

本仓库的改动部分（一键接管、船名看板、库存直连读取、协程自愈）同样以 MIT 发布，详见 `LICENSE`。

---

## 免责声明

仅供单人游戏使用。使用 mod 前请备份存档。作者不对存档损坏、成就失效等后果负责。
