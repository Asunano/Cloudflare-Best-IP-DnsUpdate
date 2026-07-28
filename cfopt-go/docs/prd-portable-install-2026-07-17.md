# 增量 PRD：cfopt-go 便携优先安装 / 系统级可选 / Windows GUI 推荐 / 文档同步

- **文档版本**：v1.0（增量 PRD，仅描述本次变更部分）
- **日期**：2026-07-17
- **作者**：许清楚（Product Manager）
- **项目**：cfopt-go（Go 重写版 cfopt；CLI = Cobra，GUI = Tauri v2 包装 Go sidecar）
- **语言**：简体中文
- **本文档性质**：简单 PRD（增量），不写竞品分析、不含市场研究。
- **配套文档**：Phase B 设计 `docs/design-installer-quickdeploy-2026-07-17.md`、Phase B PRD `docs/prd-installer-quickdeploy-2026-07-17.md`（既有 `install`/`uninstall`/`quickdeploy` 范围与决策 Q1–Q4 仍有效，本次在其之上做「便携化」增量）。

---

## 0. 背景与边界（给架构师的前置约束）

### 0.1 本轮目标（一句话）
将 `cfopt install` / `cfopt uninstall` 从「默认写系统 PATH/LOCALAPPDATA」改为**默认便携**，让 CLI 的安装/测试像 GUI 一样「下载即用、临时目录可验证、删目录即干净退出」，同时保留显式 `--system` 走旧的系统级行为。

### 0.2 已拍板的两项决策（必须遵守）

| 编号 | 决策 | 对本次的影响 |
|---|---|---|
| **Q0** | 终端（CLI）或 GUI 都可以，但 **Windows 下更推荐 GUI**；用户明确抱怨「目前的 CLI 安装测试有点麻烦」，要求 **CLI 的安装/测试也要像 GUI 一样方便**（沙箱里用临时目录就能验证，不要默认去写系统 PATH/注册表/系统目录）。 | 默认 `cfopt install` 不得触碰全局 PATH / 注册表 / LOCALAPPDATA；卸载默认也不清理这些系统痕迹。 |
| **Q1** | **默认便携，系统级可选**。`cfopt install` 默认走便携模式（二进制与配置放在同一目录，不写 PATH、不写注册表、不自复制到 LOCALAPPDATA）；卸载 = 删除该目录即干净退出。系统级通过 `cfopt install --system` 显式开启（LOCALAPPDATA 自安置 + 用户级 PATH，即 Phase B 旧行为）。 | 安装命令引入「便携 / 系统级」二态；两者互斥校验。 |

### 0.3 非目标 / 硬约束（务必纳入设计）

- **本次只改 Go 侧（CLI）**：沙箱能编 Go，但**不能编 Rust/Node**（无法构建 Tauri GUI）。GUI 向导本身属于前端（Svelte/Tauri），列为「前端后续项」，本次**不实现前端代码**，仅在 CLI 侧打印「Windows 推荐用 GUI 完成安装」的提示文案。
- **不改动 IPC / Tauri GUI 既有行为**：13 个 IPC 方法契约不变；`cmd/serve.go`、`pkg/ipc`、Tauri/Rust 侧零改动。
- **禁用 bash 专属语法**（`$(...)` / `printf` / 管道 `nc` 等）；用户运行环境 Windows + cmd/PowerShell，生成的命令必须用跨平台 Go 代码（`os/exec` 调 PowerShell / `setx` / `os.Symlink`）实现。
- **`internal/install` 与 `cmd` 的边界铁律保持**：调度注册由 `cmd` 层调用 `runSchedule` 完成；`install` 包**不得 import `cmd`**（避免循环引用）。本次增量不回归此约束。
- **部署逻辑已下沉到 `internal/deploy`（Phase B 已完成）**：本次不重复造，仅保证 `install`/`uninstall` 编排层不回退到在命令里内联部署逻辑。
- **不要默认写系统服务的调度**：便携模式天然不注册系统服务（kardianos/service 会写系统服务管理器，属「系统级」范畴），这与 Q0（不污染系统）和 Q1（删目录即干净）一致。

### 0.4 与 Phase B 的关系（复用而非推翻）

| Phase B 既有能力 | 本次如何使用 |
|---|---|
| `internal/install`：`SelfPlace` / `ProvisionConf` / `RunInstall` / `RemoveGlobalCommand` / `RemoveDataDir` / `GlobalCommandInstaller` / `GlobalCommandRemover`（可注入 seam） | 复用；新增「mode = portable | system」分支：便携模式跳过 `SelfPlace`（二进制已在目标目录）与 `GlobalCommandInstaller`，其余（ProvisionConf / cfst 就绪 / 网络体检）照常。 |
| `cmd/install.go`、`cmd/uninstall.go` | 复用为编排层；新增 `--system` / `--dir` 标志解析与模式互斥校验、Windows GUI 提示打印。 |
| `cmd/schedule.go` 的 `runSchedule("install"\|"start"\|"uninstall"...)` | 仅 `--system` 模式 + `--schedule` 时由 cmd 层调用；便携模式不调用。 |
| 默认 `cfgDir = "conf"`（相对 cwd）与默认 `data_dir = "./assets/data"` | 天然契合便携：用户从便携目录运行 `cfopt`，`./conf` 与 `./assets/data` 即解析到便携目录内，无需改默认。 |

---

## 1. 产品目标

**让 cfopt-go 的安装「零系统痕迹、可随手测试、删目录即走」，同时保留显式系统级安装供需要全局命令/常驻调度的用户使用；并在 Windows 上温和引导用户优先使用 GUI。**

三个正交的子目标：

1. **默认便携**：`cfopt install` 不写 PATH、不写注册表、不自复制到 LOCALAPPDATA，二进制与配置同目录落盘，删目录即干净退出。
2. **测试友好**：因默认不触碰系统，沙箱里一条 `cfopt install --dir <临时目录>` 即可端到端验证安装/卸载，无系统残留（直击 Q0 痛点）。
3. **系统级可选**：需要全局命令与常驻调度时，显式 `cfopt install --system` 提供 Phase B 旧行为，二者互斥、意图明确。

---

## 2. 用户故事

| 编号 | 角色 | 故事 | 价值 |
|---|---|---|---|
| US1 | Windows 试用者 | 作为**试用者**，我希望下载 `cfopt.exe` 后直接在任意目录运行 `cfopt install`，程序把配置骨架生成在**同一目录**、不写 PATH/注册表，以便我**在沙箱或临时目录里随手测试**后想删就删、不留系统痕迹。 | 直击 Q0 痛点 |
| US2 | 便携用户 | 作为**便携用户**，我希望把 `cfopt` 放在 U 盘/工作目录就能用，配置随目录走，以便我**在多台机器间拷贝即用、无需安装**。 | 零安装体验 |
| US3 | 运维用户 | 作为**运维**，我仍需要全局命令与常驻调度，我希望 `cfopt install --system` 显式开启 LOCALAPPDATA 自安置 + 用户级 PATH + 可选系统服务，以便我在受控机器上标准化铺机。 | 系统级能力保留 |
| US4 | 卸载用户 | 作为**任何用户**，我希望 `cfopt uninstall` 在便携模式下**删除该目录即干净退出**（含配置/数据），系统级模式下才额外清理 PATH 与调度，且**默认交互确认防误删**，以便我随时干净退出不留残留。 | 零残留退出 |
| US5 | Windows 新手 | 作为**Windows 新手**，我希望在终端跑 `cfopt install` 或 `cfopt`（无参主菜单）时看到一句「推荐用 GUI 完成安装与部署」的提示，以便我**知道还有更省事的图形界面可选**。 | 降低上手门槛 |

---

## 3. 需求池（P0 / P1）

> 优先级：P0 = Must（本次必须）、P1 = Should（增强，本次一并交付）。每条含编号、标题、描述、验收标准。
> 涉及标志：`--system`（系统级开关）、`--dir <path>`（便携目标目录，仅便携模式有意义）、`--schedule`（仅系统级生效）、`--force`（跳过确认，供脚本/CI）。

### P0 — Must

#### P0-1 便携优先安装：`cfopt install` 默认便携
- **描述**：无 `--system` 时进入便携模式。
  - 目标目录 `dir`：若显式 `--dir <path>` 则取该值；否则取**当前二进制所在目录**（`filepath.Dir(os.Executable())`）。
  - **二进制安置**：若 `dir` 与当前二进制目录不同，则 `SelfPlace` 将二进制复制进 `dir`（使该目录自包含）；若相同则**跳过复制**（幂等，呼应 Q1「SelfPlace 可跳过」）。
  - **配置骨架**：`ProvisionConf(dir)` 在 `dir` 下生成 `conf/`、`conf/cf-dns/`、`conf/dnspod/`、`assets/data/`、`global.json` 等（沿用现有 `config.WriteDefaults` 语义）；cfst 二进制下载到 `dir`（而非固定系统目录）。
  - **不写全局命令**：便携模式**不调用** `GlobalCommandInstaller`（不写 PATH、不写注册表、不写 LOCALAPPDATA）。
  - **不注册系统服务**：便携模式不触发 `runSchedule`（不污染系统服务管理器）。
  - **幂等**：重复运行不破坏已有用户配置；已生成的 conf / 已下载的 cfst 跳过。
- **验收标准**：
  - [ ] 运行 `cfopt install`（无 `--system`）后，二进制与 `conf/`、`assets/data/`、`global.json` 全部落在**同一目录**；新开终端**无需** PATH 即可在该目录内直接运行 `cfopt`。
  - [ ] 运行后用户级 PATH 与注册表**无任何 cfopt 相关新增项**（可用注入 seam 断言 `GlobalCommandInstaller` 未被调用 / 未写 PATH）。
  - [ ] LOCALAPPDATA 下**不生成** `cfopt` 子目录（除非 `--system`）。
  - [ ] 重复运行幂等：已有 conf 不被覆盖、已下载 cfst 不重复下载；退出码 0。
  - [ ] `--dir <临时目录>` 时，所有落盘（二进制/conf/cfst）均在临时目录内，系统其余位置零写入（**沙箱可端到端验证，呼应 Q0**）。

#### P0-2 系统级安装可选项：`cfopt install --system`
- **描述**：显式 `--system` 走 Phase B 旧行为——LOCALAPPDATA 自安置（Windows）/ `/usr/local/bin` 软链（其他）+ 用户级 PATH + `ProvisionConf` + cfst 就绪 + 轻量网络体检；配合 `--schedule` 可选注册常驻调度（kardianos/service）。
- **验收标准**：
  - [ ] `cfopt install --system` 后，二进制自安置到 LOCALAPPDATA\cfopt（Windows）或 `/usr/local/bin`（其他），用户级 PATH 含该目录，新开终端可直接 `cfopt`。
  - [ ] `cfopt install --system --schedule` 进一步注册并启动系统服务（计划任务/cron）。
  - [ ] 与便携模式**互斥**：同时传 `--system` 与 `--dir`（便携式指定目录）视为冲突——以 `--system` 为准并忽略 `--dir` 且给出明确警告（或报错，由架构师二选一，默认建议：警告并忽略 `--dir`）。
  - [ ] 幂等：已自安置/已写 PATH/已存在配置跳过对应步骤。

#### P0-3 便携卸载：`cfopt uninstall` 删目录即干净退出
- **描述**：无 `--system` 时进入便携卸载——交互确认后**删除便携目录**（含二进制、conf、assets/data），即干净退出。系统级痕迹（PATH、调度）在便携模式下本就不存在，故无需清理。
  - 目标目录判定：优先用 `--dir <path>`；否则取当前二进制所在目录。
  - **默认防误删**：交互终端下必须 `Confirm`（默认 **No**）才执行删除。
- **验收标准**：
  - [ ] 在便携目录内运行 `cfopt uninstall` 并确认后，该目录被整体删除，系统 PATH/注册表/LOCALAPPDATA **无任何 cfopt 残留**（呼应 Q1「删目录即干净退出」）。
  - [ ] 未确认（默认 No）时**不删除任何内容**，退出码 0。
  - [ ] 非交互终端（管道/重定向）下不静默删除，提示需手动处理或要求 `--force`（防误删）。
  - [ ] 删除前打印将移除的范围清单；失败项明确列出，不静默跳过。

#### P0-4 系统级卸载：`cfopt uninstall --system` 清理 PATH 与调度
- **描述**：`--system` 走系统级清理：停止并卸载调度（`runSchedule("uninstall")`）→ 移除全局命令（PATH 项/软链）→ 删除 LOCALAPPDATA\cfopt 目录（含配置/数据）。默认交互确认（防误删），支持「保留配置 / 全清」选项（沿用 Phase B `UninstallPlan`）。
- **验收标准**：
  - [ ] `cfopt uninstall --system` 确认后，用户级 PATH 移除 cfopt 目录项、系统服务注销、LOCALAPPDATA\cfopt 目录被删（或按选项保留配置）。
  - [ ] 缺 `--system` 且当前运行于便携目录时，仅删便携目录、不触碰 PATH/服务（与 P0-3 一致）。

#### P0-5 Windows GUI 推荐提示（CLI 侧文案）
- **描述**：在 **Windows** 终端下运行 `cfopt install`（含便携默认）与 `cfopt`（无参主菜单）时，打印一句自然、不突兀的提示，引导优先使用 GUI 版本。GUI 向导本身是前端后续项，本文档**只描述 CLI 侧提示文案**，不实现前端。
- **建议文案（供实现参考，可微调）**：
  - `cfopt install`（Windows）：
    `💡 提示：在 Windows 上，推荐直接使用图形界面（GUI）版本完成安装与部署，操作更直观、无需命令行。GUI 桌面程序可在本项目 Release 页获取（基于 Tauri，自动封装本命令行核心）。您当前使用的是命令行（CLI）模式。`
  - `cfopt`（无参主菜单，Windows）菜单顶部或底部一行：
    `提示：Windows 用户推荐使用 GUI 版本（更省事）。本程序命令行与 GUI 功能完全一致。`
- **验收标准**：
  - [ ] 在 `runtime.GOOS == "windows"` 时，上述两个入口均打印该提示；非 Windows 不打印（避免噪音）。
  - [ ] 提示为纯 CLI 输出，不改动任何 IPC/GUI 契约；不影响安装/菜单主流程。
  - [ ] 「前端后续项」在本文档显式标注，不进入本次 Go 实现范围。

#### P0-6 测试便利性（对应 Q0 痛点）的设计保障
- **描述**：通过既有 `install.GlobalCommandInstaller` / `install.GlobalCommandRemover` 可注入 seam，便携模式**根本不触发**全局命令逻辑，从而默认不在沙箱写 PATH/注册表/LOCALAPPDATA。
- **验收标准**：
  - [ ] 提供单测：注入 no-op `GlobalCommandInstaller`/`GlobalCommandRemover`，断言便携模式 `RunInstall` 不调用它们、不写任何系统 PATH（用临时目录作为 `dir` 即可完整验证安装+卸载闭环）。
  - [ ] 端到端冒烟：在临时目录 `T` 执行 `cfopt install --dir T` → 断言 `T` 内含二进制/conf/cfst、`%PATH%` 与 LOCALAPPDATA 无变化 → `cfopt uninstall --dir T --force` → 断言 `T` 被彻底删除、系统零残留。

### P1 — Should

#### P1-1 模块化 / 职责区分显式化
- **描述**：明确分层职责，避免命令层内联安置逻辑：
  - `internal/install`：**「安置（SelfPlace）+ 配置骨架（ProvisionConf）+（可选）全局命令（Setup/Remove GlobalCommand）+ cfst 就绪 + 网络体检」**。不得 import `cmd`，不得自行注册调度。
  - `cmd/install.go`、`cmd/uninstall.go`：**编排层**——解析 `--system`/`--dir`/`--schedule`/`--force`、判定便携/系统级、调用 `internal/install`、仅在系统级 + `--schedule` 时调用 `runSchedule`、打印 Windows GUI 提示。
  - `internal/deploy`（Phase B 已下沉）：部署/校验编排保持不动，本次不回退。
- **验收标准**：
  - [ ] `internal/install` 包内无 `import ".../cmd"`，无 `runSchedule` 调用（铁律保持）。
  - [ ] `cmd/install.go` 不含安置/conf 生成的具体实现，仅做编排与标志解析。
  - [ ] 部署相关逻辑仍在 `internal/deploy`，未被重新内联进 `cmd`。

#### P1-2 README / 文档同步
- **描述**：安装/卸载章节新增「便携 vs 系统级」说明。需同步的文档清单见 §4.3；同步要点：便携默认、删目录即卸载、`--system` 开启全局命令与调度、Windows 推荐 GUI。
- **验收标准**：
  - [ ] 根 `README.md` 的「快速开始 / 启动程序」补充 `cfopt install`（便携）与 `cfopt install --system` 说明，澄清默认不再写系统目录。
  - [ ] `cfopt-go/README.md` §3 终端模式新增「安装（Install）」与「卸载（Uninstall）」小节，含便携/系统级对照与 Windows GUI 提示说明。
  - [ ] 如 `docs/system_design.md` 涉及安装架构，补充「便携 vs 系统级」二态与职责边界。
  - [ ] 文档与最终实现行为一致（交由 QA 在 #3 验收）。

---

## 4. 终端交互 / 菜单稿

### 4.1 `cfopt install` 交互（便携默认 / `--system` 可选）

```
cfopt install [--dir <目录>] [--system] [--schedule] [--force]

[Windows 专属提示（P0-5）]
  💡 提示：在 Windows 上，推荐直接使用图形界面（GUI）版本完成安装与部署，
     操作更直观、无需命令行。GUI 桌面程序可在本项目 Release 页获取
    （基于 Tauri，自动封装本命令行核心）。您当前使用的是命令行（CLI）模式。

模式判定：
  - 无 --system  → 便携模式
       目标目录 = --dir 指定值 | 否则 = 当前二进制所在目录
       二进制：若目标目录≠当前目录则复制进去（SelfPlace），否则跳过
       配置骨架：在目标目录生成 conf/ conf/cf-dns/ conf/dnspod/ assets/data/ global.json
       cfst：下载到目标目录
       不写 PATH / 注册表 / LOCALAPPDATA；不注册系统服务
  - 有 --system  → 系统级模式（Phase B 旧行为）
       自安置 LOCALAPPDATA\cfopt（Win）/ /usr/local/bin（其他）
       写用户级 PATH；--schedule 时注册并启动系统服务
       与 --dir 互斥（以 --system 为准，忽略 --dir 并警告）

交互：
  交互终端 + 无 --force → Confirm("将在 <dir> 以[便携|系统级]模式安装 cfopt，是否继续？", 默认 Yes)
  非交互终端 → 直接幂等执行（不阻塞），结尾打印关键后续提示
结尾打印：安装结果摘要（自安置/配置骨架/cfst/全局命令/调度 各就绪状态）+ 提示
```

### 4.2 `cfopt uninstall` 交互（便携默认 / `--system` 可选）

```
cfopt uninstall [--dir <目录>] [--system] [--force]

模式判定：
  - 无 --system  → 便携卸载：删除便携目录（含二进制/conf/data）即干净退出
       目标目录 = --dir 指定值 | 否则 = 当前二进制所在目录
       不触碰 PATH / 注册表 / 系统服务（便携模式下本就无这些痕迹）
  - 有 --system  → 系统级卸载：停止并卸载调度 → 移除全局命令(PATH/软链)
       → 删除 LOCALAPPDATA\cfopt（或按选项保留配置）

交互（默认防误删）：
  交互终端 + 无 --force → Confirm("确定卸载 cfopt 吗？（将清理[便携目录|全局命令与调度]，默认保留配置）", 默认 No)
  选范围（系统级）：[1] 保留配置  [2] 全清
  非交互终端 → 不静默删除，提示需手动处理或加 --force
结尾打印：已移除清单 + 失败项（不静默跳过）
```

### 4.3 需同步更新的文档清单（P1-2）

| 文档 | 新增/修改章节 | 关键内容 |
|---|---|---|
| `README.md`（仓库根） | 「快速开始」「启动程序」 | 区分 `cfopt install`（便携，不写系统目录）与 `cfopt install --system`；说明「删目录即卸载」。 |
| `cfopt-go/README.md` | §3 终端模式新增「安装（Install）」「卸载（Uninstall）」 | 便携 vs 系统级对照表；`--dir`/`--system`/`--schedule`/`--force` 说明；Windows GUI 提示说明；`--config-dir` 默认 `conf` 相对路径的便携含义。 |
| `docs/system_design.md`（如涉及安装架构） | 安装/卸载架构 | 便携 vs 系统级二态、各层职责边界（`internal/install` 不含调度、`cmd` 编排 + 调 `runSchedule`）、可注入 seam 用途。 |

---

## 5. 待确认问题（需架构师 / 用户拍板）

| 编号 | 问题 | 影响范围 | 建议默认值（供拍板参考） |
|---|---|---|---|
| **Q-C1** | **便携模式是否允许 `--schedule`（注册系统服务）？** Q1 文本「系统级模式下才清理 PATH 与调度」暗示便携无调度；但用户可能想要「便携目录 + 常驻调度」。若允许，则便携卸载也必须移除该调度以保持「删目录即干净」。 | P0-1 / P0-3 / P0-6 | **默认不允许**：便携模式忽略 `--schedule` 并提示「调度为系统级能力，请使用 `cfopt install --system --schedule` 或安装后 `cfopt schedule install`」。最贴合 Q0/Q1，且沙箱测试零系统残留。若用户坚持要，则改为「允许 + 便携卸载一并移除调度」。 |
| **Q-C2** | **`--system` 与 `--dir` 同时传入时如何处理？** | P0-2 | 建议：以 `--system` 为准，忽略 `--dir` 并打印警告。备选：直接报错退出。 |
| **Q-C3** | **便携卸载的目标目录判定**：仅依赖「当前二进制所在目录」是否足够？是否必须支持 `--dir` 显式指定（便于非当前目录的便携实例卸载）？ | P0-3 | 建议：`--dir` 优先，否则取当前二进制目录；两者都支持。 |

> 以上三项均不阻塞 P0 主链路实现；Q-C1 建议默认值已能使本次增量自洽，拍板后架构师可据此细化。

---

## 6. 验收总览（本次增量完成定义）

当以下全部达成，视为本次增量完成：

- [ ] **便携 install 同目录落盘**：`cfopt install`（无 `--system`）将二进制与 `conf/`、`conf/cf-dns/`、`conf/dnspod/`、`assets/data/`、`global.json` 生成在**同一目录**；新开终端无需 PATH 即可在该目录内运行。
- [ ] **便携 install 不写系统**：用户级 PATH、注册表、LOCALAPPDATA **均无** cfopt 新增项（由注入 seam 单测断言 `GlobalCommandInstaller` 未被调用）。
- [ ] **便携 install 幂等**：重复运行不破坏已有配置、不重复下载 cfst，退出码 0。
- [ ] **`--system` 走系统级**：LOCALAPPDATA 自安置 + 用户级 PATH +（`--schedule` 时）系统服务；与便携互斥校验生效。
- [ ] **便携 uninstall 删目录即干净**：在便携目录内确认卸载后，该目录被整体删除，系统零残留；默认防误删（Confirm 默认 No）。
- [ ] **系统级 uninstall 清理 PATH 与调度**：`--system` 卸载移除 PATH 项、注销系统服务、删除 LOCALAPPDATA 目录（或按选项保留配置）。
- [ ] **Windows GUI 提示**：`runtime.GOOS == "windows"` 时，`cfopt install` 与 `cfopt`（无参主菜单）均打印推荐 GUI 文案；非 Windows 不打印；不改 IPC/GUI 契约。
- [ ] **测试便利性（Q0）**：提供临时目录端到端冒烟——`cfopt install --dir <T>` → 断言 T 内含全部产物且系统 PATH/LOCALAPPDATA 无变化 → `cfopt uninstall --dir <T> --force` → 断言 T 被彻底删除、系统零残留。
- [ ] **模块化不回归**：`internal/install` 无 `import cmd`、无 `runSchedule` 调用；部署逻辑仍在 `internal/deploy`；`cmd` 仅编排。
- [ ] **文档同步**：根 `README.md`、`cfopt-go/README.md`（必要时 `docs/system_design.md`）的安装/卸载章节新增「便携 vs 系统级」说明，与最终实现一致（QA #3 验收）。
- [ ] **IPC / Tauri GUI 既有行为未改动**；无 bash 专属语法；未触碰 Rust/Node。
