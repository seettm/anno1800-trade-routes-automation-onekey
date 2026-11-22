# 游戏 UI 资产可行性调研

分支：`feature/game-ui`
日期：2026-11-22
目标：为 TRA 一键操控版做一个**真正的屏幕面板**（调度状态 / 物资需求 / 船队规模），替代现在"把字印在船名上"的做法。

---

## 一、结论先行

**Anno 1800 不存在"新增 HUD 面板"这种 UI 资产。**

社区里能做出悬浮面板的 mod（如 `Anno1800ModMenu`），走的都是**外部 DLL 注入 + Dear ImGui 渲染**，
和 `assets.xml` / Lua mod 完全是两套技术栈，不可能在纯 mod 目录里实现。

纯 mod 侧唯一能让文字出现在屏幕上的通道是：**借用游戏已有的文本载体**（船名、建筑名、tooltip、TextExport）。

---

## 二、证据

### 1. 官方 modding guide 全站没有 GUI/UI 章节

`https://anno-mods.github.io/modding-guide/` 的完整目录里，与界面沾边的只有两项：

| 条目 | 实际内容 |
|---|---|
| Tooltip modding (infotips) | 鼠标悬停提示框，改的是 `export.bin` 里的 InfoElement |
| Anno Building-menu Customizer | 第三方外部工具，只排布**建筑菜单**顺序 |

没有 "GUI"、"UI"、"HUD"、"Layout"、"Widget" 这类条目。一个有 7 篇系统教程的官方指南，
如果新增面板可行，不可能一个字都不写。

### 2. `data/config/gui/` 只放翻译文本，不是布局

所有 mod 教程里，`data/config/gui/` 的作用都只有一件事：放 `texts_english.xml`、`texts_chinese.xml` 这类本地化文件。

本 mod 自己的 `data/config/gui/` 也只有这两个文件。这不是巧合——**布局不在这里**。

### 3. 本机 178 个已安装 mod 的扫描结果

扫描 `C:\Users\Public\mod.io\4169\mods\`（178 个 mod，含各类 UI 美化、建筑菜单重排、超大仓库等）：

```
含 data/config/gui/ 目录的 mod：1 个
  → 5547162 = TradeRoutesAutomation_DEV 本身，且该目录里只有 texts_english.xml（543 字节）
含 <Template>Menu</Template> 的 mod：0 个
含 <Menu> 容器的 mod：0 个
```

**178 个 mod，零个新增 GUI 布局。** 这是最有说服力的一条：
如果这条路可行，spice it up、建筑菜单定制这类最激进的 mod 早就会用了。

### 4. 布局文件在 RDA 里，且不是可编辑 XML

`maindata/data0.rda` 中 `config/gui/` 下只有：

```
config/gui/credits.txt
config/gui/credits_as.html
config/gui/credits_eu.html
```

真正的界面布局在更高编号的 rda 里（data1.rda 9.2 GB 起），需要 RDAExplorer 提取，
且提取出来是游戏内部格式。mod loader 只能**同路径覆盖**，不能"新增一个面板再加到 HUD 上"——
即使能找到布局文件，也缺少"把这个面板挂进 HUD 层级"的公开接口。

### 5. `Menu` 模板存在，但不是 HUD 面板

`<Template>Menu</Template>` 用于主菜单背景/按钮这类**全屏菜单**，不是 HUD 悬浮层，
且需要配套的布局资源，不是写几个字段就能出画面。

---

## 三、三条路线对比

| 路线 | 能做到什么 | 成本 | 风险 | 结论 |
|---|---|---|---|---|
| **A. Lua 文本嵌入**<br>`[Source Variable]` 写进已有文本载体 | 文字级看板：船名、建筑名、tooltip | 低 | 低 | ✅ 已在用（船名） |
| **B. 外部 ImGui overlay**<br>DX11/DX12 hook + DLL | 真正的可交互面板 | 高（C++、编译、ABI） | 高（每次游戏更新可能崩） | ⚠️ 可选，独立于本 mod |
| **C. 直接写 UI 资产**<br>assets.xml 里定义面板 | —— | —— | —— | ❌ 不存在此范式 |

### A 路线还能扩展的载体

| 载体 | 显示位置 | 优点 | 副作用 |
|---|---|---|---|
| 船名（已用） | 选中船只、船只列表 | 零风险，随时可还原 | 只在该船附近可见 |
| **建筑名** | 地图上常驻标签 | **不选任何东西也一直可见** | 改了玩家建筑名，需提供还原 |
| TextExport + 文本嵌入 | 游戏各处引用该 GUID 的地方 | 可绑定实时数据 | 影响面不可控 |
| Infotip（`export.bin`） | 鼠标悬停提示框 | 信息量大 | 需要二进制工具，版本敏感 |

**建筑名是目前最优的候选**：它在地图上常驻显示，不依赖选中状态，且改名可逆。
代价是会覆盖玩家给建筑起的名字——可以用 `TRA|状态` 前缀 + 释放时还原原名来缓解。

---

## 四、本分支计划

### Phase 0（本次提交）— 用真实数据否定或确认路线

不猜 API，直接枚举运行时暴露的界面接口：

- `ts.Interface.*` 全部成员与类型
- `ts.GUI.*`、`game.gui.*`
- `_G` 中名字含 `gui` / `ui` / `interface` / `menu` 的键
- 逐个验证已知候选（`SetUiScreenScaling` 等）

结果写入 `<用户目录>\log\TRAtUI_uiprobe.txt`。触发键：`Shift + L`。

**为什么必须先做这一步**：之前已经实测过 5 个通知类 API 全部不可用（日志 `notify via=none`）。
在没有完整接口清单的情况下写布局或调用，等于继续猜。

### Phase 1 — 按探测结果选路

- 若 `ts.Interface` 存在创建/显示控件的接口 → 走原生控件
- 若只有 `SetUiScreenScaling` 这类全局设置 → 放弃原生面板，转 Phase 2
- 若什么都没有 → 确认只能走文本载体

### Phase 2 — 建筑名常驻看板

在玩家自选的一座建筑（贸易站/仓库）上挂状态文本，地图标签常驻可见。
提供 `Shift + ;` 之类的键切换挂载目标与还原。

### Phase 3 —（可选）外部 overlay

若确实需要可交互面板，另开仓库做 ImGui DLL，与本 mod 通过日志文件/共享内存交换数据。
**不属于本仓库范围**，因为它是 C++ 编译产物，和 mod 目录的加载机制无关。

---

## 五、Phase 0 怎么验证

1. 把本分支装进 `Documents\Anno 1800\mods\`
2. 进存档，按 `Shift + L`
3. 打开：

   ```
   C:\Users\<用户名>\Documents\Anno 1800\log\TRAtUI_uiprobe.txt
   ```

4. 文件里 `ts.Interface` 段落的成员数量，就是这个方案的天花板：
   - 只有 `SetUiScreenScaling` / `GetUiScreenScaling` 几个 → 原生面板不可行，走 Phase 2
   - 出现 `AddWidget` / `CreateMenu` / `ShowPanel` / `RegisterGui` 一类 → 有戏，继续深挖

---

## 六、一句话交代

如果你要的是"游戏里有个漂亮的悬浮窗"，纯 mod 做不到，这是引擎限制，不是没写对。
如果你要的是"不用切窗口就能看到状态"，建筑名看板（Phase 2）能达成，而且比船名更显眼。
