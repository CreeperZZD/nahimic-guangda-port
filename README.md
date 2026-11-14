# Nahimic 3 音效套件 · 广达模具机型移植方案

> 把 **雷神猎刃 16（Thunderobot NLY）** 自带的 Nahimic 3 音效系统，移植到 **同款广达模具、同款 Realtek ALC256 编解码器**的其他笔记本上（实测机型：七彩虹 隐星 G16 24）。
>
> 本仓库**只包含原创脚本与文档**，不含任何第三方版权文件。所需驱动与应用请自行从你设备的官方渠道获取，详见下方「版权声明」。

---

## ⚠️ 重要声明（请先阅读）

### 版权与侵权处理

1. **本仓库不包含、不分发、不镜像任何第三方版权文件。**
   包括但不限于：A-Volute / Nahimic 的 `NahimicAPO4.dll`、`NahimicService.exe`、`.cat` 签名目录、`.inf` 驱动安装信息、`.cab` 调音档案、`.appxbundle` 应用包，以及雷神（Thunderobot）、七彩虹（COLORFUL）、Realtek 的任何驱动或固件。**一个字节都没有。**

2. **本仓库提供的全部内容为原创脚本与文档**，用于在**你自己拥有合法授权的设备与软件**上完成配置，属个人学习与研究性质。

3. **如果你认为本仓库的任何内容侵犯了你的合法权益**，请立即通过下列方式联系我，我会在核实后 **24 小时内删除相关内容**：

   📧 **1876536805@qq.com**

   请在邮件中说明：权利主体、被侵权内容的具体路径、权利证明。我会配合处理，不做任何抗辩。

4. **商标声明**：Nahimic®、A-Volute® 为 A-Volute SAS 的商标；雷神 / Thunderobot 为雷神科技的商标；七彩虹 / COLORFUL 为七彩虹科技的商标；Realtek® 为瑞昱半导体的商标。本仓库与上述公司**没有任何关联、合作或授权关系**，仅为技术研究与个人使用目的提及这些名称。

5. **使用风险自负。** 修改驱动安装信息、开启测试签名模式、改写注册表音频链路，都可能造成系统不稳定、音频异常、开机签名校验失败等问题。请务必先阅读「恢复与卸载」并做好备份。作者不对任何直接或间接损失承担责任。

6. **禁止商业使用。** 请勿将本方案用于商业分发、预装、收费服务或任何形式的二次售卖。

### 一句话版本

> 我这里只放**怎么做的脚本和文档**，不放**别人家的文件**。文件你自己从官方渠道拿，我教你改哪一行、怎么装、怎么退。有意见请发邮件，我立刻删。

---

## 这是什么

Nahimic 3 是 A-Volute 开发的音效增强套件，通常由笔记本 OEM 随机器预装。它在硬件上没有真正的锁定，设备识别依赖**音频端点上的注册表属性**，而这些属性由 OEM 的 **EXT 扩展驱动**写入。

本项目的核心发现是：

> 同一广达（Quanta）模具的不同品牌机型，硬件差异常常只有 **PCI 子系统 ID 的末几位**（如雷神 `SUBSYS_152D1535` vs 隐星 `SUBSYS_152D1534`）。只要在 EXT 驱动的匹配表里补一行本机 ID，整套音效系统就能正常绑定并工作。

所以移植的实质是三步：**改一行 INF 匹配 → 用测试签名装载 → 装官方应用**。应用层不需要任何修改。

---

## 适配范围

### 可以尝试的条件（全部满足）

| 条件 | 要求 |
|---|---|
| 编解码器 | **Realtek ALC256**（`VEN_10EC&DEV_0256`） |
| 子系统厂商 | **广达 0x152D**（`SUBSYS_152Dxxxx`） |
| 总线 | Intel Smart Sound（`INTELAUDIO`） |
| 基础驱动 | 已装 Realtek 通用音频驱动 + Realtek Audio Universal Service |
| 系统 | Windows 10 1809 及以上 / Windows 11（应用最低要求 16299） |
| 固件 | **必须能关闭 Secure Boot**（BIOS 里有该选项） |

### 已实测机型

| 机型 | 子系统 ID | 结果 |
|---|---|---|
| 七彩虹 隐星 G16 24 | `SUBSYS_152D1534` | ✅ 音效、麦克风正常；声音追踪器部分可用（见下表） |

### 不适用

- 非 ALC256 编解码器（如 ALC295 / ALC3306 / Cirrus Logic 等）
- 非广达模具或子系统厂商不是 `0x152D`
- BIOS 无法关闭 Secure Boot 的机型（无法装载测试签名驱动）
- ARM 架构 Windows
- 蓝牙耳机、USB 声卡本身不走此链路

---

## 功能可用性矩阵

实测环境：七彩虹 隐星 G16 24 + Windows 11 + Realtek 6.0.9622.1。**✅ 可用 / ⚠️ 有条件 / ❌ 不可用**

### 核心音效

| 功能 | 状态 | 说明 |
|---|:---:|---|
| 图形均衡器（EQ） | ✅ | 10 段 EQ，预设与自定义均可保存 |
| 音效预设（音乐 / 游戏 / 影音 / 通讯） | ✅ | 切换即时生效 |
| 音量稳定器 / 响度均衡 | ✅ | |
| 低音增强 / 环绕强度 | ✅ | 在立体声端点上是心理声学上混，非真实多声道 |
| 设备自动识别 | ✅ | 插拔耳机后自动切换配置 |
| App 界面品牌 | ✅ | **不显示任何 OEM 品牌**。EXT 驱动写的 `PKEY_VENDORNAME="Thunderobot"` 只落在 Windows 端点属性（`{3B454CDE-…},0`）里，App UI 不读它，界面与原生 Nahimic 3 一致 |

### 麦克风

| 功能 | 状态 | 说明 |
|---|:---:|---|
| 麦克风降噪 / 静态噪声抑制 | ✅ | 实测生效 |
| 麦克风均衡 / 增益 | ✅ | |
| 回声消除 | ✅ | |
| 通话场景预设 | ✅ | |

### 声音追踪器（Sound Tracker / 雷达）

这是**最受限**的功能，也是移植后最容易被误解的部分。它能否显示 360°，取决于**音频端点的声道数 + APO 链形态**，与音效本身无关。

| 端点类型 | 声道 | APO 链形态 | 雷达表现 |
|---|:---:|---|---|
| 内置扬声器（6 声道端点） | 6ch | 复合链 `,13/14/15` | ✅ **360° 正常** |
| USB 小尾巴 / DAC（2 声道端点） | 2ch | 单层三段 `,5/6/7` | ✅ **360° 正常** |
| 主板耳机孔（2 声道端点） | 2ch | 复合链 `,13/14/15` | ❌ **只有前方左右** |

从实测反推的规律：**「复合链 + 2 声道」这个组合会让方位分析失效**。原因是 Nahimic 的包装层 APO 在多声道端点上才能正常做方位解析，而 Realtek 耳机孔端点只声明立体声（`PhysicalSpeakers=0x3`），驱动也拒绝了 6/8 声道格式请求（`AUDCLNT_E_UNSUPPORTED_FORMAT`）。

**结论与实际用法：**

- 想要雷达 360°：**用 USB 声卡/小尾巴**，或**用内置扬声器**。
- 主板耳机孔：音效完全正常，雷达只有前后左右之分。
- 这不是安装失败，是**端点能力限制**，改注册表、换驱动、开测试签名都无法解决。

### 明确不可用 / 不适用

| 项目 | 状态 | 原因 |
|---|:---:|---|
| 蓝牙耳机上的音效 | ❌ | 蓝牙走独立链路，APO 不参与 |
| USB 声卡上的 Nahimic 虚拟环绕 7.1 | ⚠️ | 雷达可用，但真实 7.1 需游戏本身输出多声道 |
| 与 SteelSeries Sonar 同时启用 | ⚠️ | 可共存但会叠加处理，听感互相干扰，建议只开一个 |
| 部分反作弊游戏 | ⚠️ | 社区有 `NahimicService` 与 Riot 系反作弊的冲突报告，可临时停服务 |
| 真实 7.1 声道物理输出 | ❌ | 笔记本主板只有立体声输出，所谓 7.1 是虚拟上混 |

---

## 使用前提

### 必须

1. **关闭 Secure Boot**（BIOS → Security → Secure Boot → Disabled）。
   改过匹配表的 INF 会使 `.cat` 目录哈希失效，WHQL 签名不再有效，必须走测试签名模式。
2. **开启测试签名**：`bcdedit /set testsigning on`，然后重启。
   重启后桌面右下角会出现「测试模式」水印，属正常现象。
3. **管理员权限**运行全部脚本。

### 建议

- 先用系统还原点或镜像备份系统盘。
- 记录当前 Realtek 驱动版本，便于回滚。
- 卸载任何其他音效增强软件（Dolby、DTS、Sonic Studio、Sonar）避免叠加。

---

## 快速开始

### 第 0 步：准备你需要的文件

本项目**不提供**这些文件，请自行获取：

| 文件 | 获取方式 |
|---|---|
| Nahimic 3 应用包（`*.appxbundle` + 依赖 + `License1.xml`） | 你设备 OEM 官网的预装软件下载区，或出厂恢复分区 |
| APO4 SWC 驱动（`A-VoluteNhApo4Swc.inf` 及同目录文件） | 同上（通常打包在 OEM 的 Nahimic Restore Tool 中） |
| EXT 扩展驱动（`AVoluteNH3Ext.inf` + `.cat`） | 同上 |
| 调音档案（`NH3ProductSettings.cab`） | 同上 |

把它们放进一个目录，结构如下：

```
kit/
├── 1-Driver-APO/          # SWC 驱动原样解出，不要改动
│   ├── A-VoluteNhApo4Swc.inf
│   ├── a-volutenhapo4swc.cat
│   └── ...（dll / exe）
├── 2-Driver-EXT/
│   ├── AVoluteNH3Ext.inf
│   ├── avolutenh3ext.cat
│   └── NH3ProductSettings.cab
└── appx/
    ├── Nahimic3.appxbundle
    ├── Microsoft.NET.Native.Framework.2.2_*.appx
    ├── Microsoft.NET.Native.Runtime.2.2_*.appx
    ├── Microsoft.VCLibs.140.00_*.appx
    └── *License1.xml
```

### 第 1 步：环境体检

```powershell
# 管理员 PowerShell
.\scripts\diagnose\check-env.ps1
```

会检查：Secure Boot 状态、ALC256 是否存在、子系统 ID、Realtek 驱动版本、是否存在残留、测试签名状态。**任何一项不通过都会明确告诉你原因，不会盲装。**

### 第 2 步：生成适配你机型的驱动包

```powershell
.\scripts\prepare-kit.ps1 -KitDir "D:\kit" -OutDir "D:\kit-ready"
```

脚本会：
1. 读出本机 ALC256 的 `SUBSYS` 值；
2. 在 EXT INF 的匹配表里补一行本机 ID（幂等，重复运行不会写重复行）；
3. 把 `NH3ProductSettings.cab` 里 `152D1535_*.nsx` 复制一份改名为 `<你的SUBSYS>_*.nsx` 并重建 CAB；
4. 输出到 `OutDir`，原 `KitDir` **不做任何修改**。

### 第 3 步：安装

```powershell
# 第一次运行：开启测试签名，提示重启
.\scripts\install.ps1 -KitDir "D:\kit-ready"

# 重启后再次运行：完成安装
.\scripts\install.ps1 -KitDir "D:\kit-ready" -AppxDir "D:\kit-ready\appx"
```

安装完成后重启，验证：

- 设备管理器 → 软件组件 → 出现 `A-Volute Nh4 Audio Effects Component`
- 服务 → `NahimicService` 运行中
- 开始菜单 → 打开 Nahimic，能识别到扬声器

---

## 仓库结构

```
nahimic-guangda-port/
├── README.md                       # 本文件
├── LICENSE                         # MIT（仅适用于原创脚本与文档）
├── NOTICE.md                       # 第三方商标与版权归属、联系方式
├── docs/
│   ├── 01-原理与移植思路.md          # 逆向分析：包结构、APO 链、为什么改一行就够
│   ├── 02-端点与声音追踪器.md        # 雷达 360° 的条件、实测数据、为什么耳机孔不行
│   ├── 03-常见问题.md               # 装不上、没声音、更新后失效……
│   └── 04-恢复与卸载.md             # 完整回退步骤
└── scripts/
    ├── prepare-kit.ps1             # 从你的官方包生成适配本机的 kit
    ├── install.ps1                 # 两段式安装
    ├── uninstall.ps1               # 完整卸载
    └── diagnose/
        ├── check-env.ps1           # 环境体检（只读）
        ├── dump-apo.ps1            # 查看端点 APO 链与声道（只读）
        └── radar-probe.ps1         # 声音追踪器方向探测（只读）
```

---

## 工作原理（简版）

```
prepare-kit.ps1 在 EXT INF 补一行本机 SUBSYS
        │
        ▼
EXT 驱动绑定到 ALC256 ──► 创建 SWC 子设备 (VEN_AVOL&AID_0F02)
        │                              │
        ▼                              ▼
写 EPSubVer2=4 + 端点属性          SWC 驱动绑定 ──► APO/服务文件落地
(PKEY_PRODUCTID/VENDORNAME)             │
        │                               ▼
        ▼                        APO 注册 + NahimicService 启动
Realtek 驱动栈按 APO4 模式
把 NahimicAPO4.dll 挂进音频链              │
        │                                 ▼
        └──────────► Nahimic 3 App 识别到设备 ◄── 端点属性匹配
```

细节见 [`docs/01-原理与移植思路.md`](docs/01-原理与移植思路.md)。

---

## 恢复与卸载

```powershell
# 管理员 PowerShell
.\scripts\uninstall.ps1
```

会依次：停并删除 `NahimicService` → 卸载 SWC/EXT 驱动包 → 删除 `HKLM\SOFTWARE\Nahimic` → 卸载 Appx → 恢复端点属性 → 可选关闭测试签名。

**关闭测试签名前必须先卸载驱动**，否则下次启动可能因签名校验失败而进不了系统（可用高级启动修复）。

---

## 已知问题

| 现象 | 原因 | 处理 |
|---|---|---|
| 装完 App 打不开 / 一开就退 | 测试签名未生效（没重启），SWC 组件未创建 | 重启后重跑 `install.ps1` |
| App 能开但没效果 | APO 未挂入链路，或 Realtek 驱动不支持 APO4 | 检查设备管理器是否有 `A-Volute Nh4 Audio Effects Component`；换 OEM 版 Realtek 驱动 |
| 某次 Windows Update 后失效 | 通用 Realtek 驱动被替换 | 重跑 `install.ps1`，或改用 OEM 驱动并暂停驱动更新 |
| 声音追踪器只有前方 | 端点声道/APO 链组合不支持 | 见 [`docs/02-端点与声音追踪器.md`](docs/02-端点与声音追踪器.md)，换 USB 声卡或内置扬声器 |
| 桌面右下角「测试模式」水印 | 测试签名模式的正常现象 | 无法去除，除非放弃该驱动 |
| 游戏反作弊报错 | `NahimicService` 冲突 | `Stop-Service NahimicService` 后启动游戏 |

更多见 [`docs/03-常见问题.md`](docs/03-常见问题.md)。

---

## 贡献

欢迎提交 Issue 报告**新的适配机型**（请附上：机型、`SUBSYS` 值、编解码器型号、功能可用情况）。如果确认某个机型可用，我会加进「已实测机型」表。

请**不要**在 Issue 或 PR 中上传任何第三方版权文件，包括驱动、DLL、安装包、日志中的完整文件路径截图。这类内容会被直接删除。

---

## 致谢

- 感谢社区多年来对 Nahimic 移植方案的探索与公开讨论，本项目的方法论受其启发。
- 感谢 A-Volute 提供了这样一套设计上高度解耦、依赖 OEM 驱动声明而非硬编码锁定的音效系统——这在客观上让同模具机型之间的移植成为可能。

---

## 联系

侵权投诉 / 技术交流 / 机型反馈：**1876536805@qq.com**

再次强调：**本项目不含任何第三方版权文件**。所有驱动与应用请从你拥有合法授权的官方渠道获取。

<sub>本项目脚本与文档以 MIT 协议发布，仅适用于原创部分。使用即表示你已阅读并同意上述全部声明。</sub>
