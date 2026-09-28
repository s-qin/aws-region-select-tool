# AWS Region Select Tool

[English](README.md) | [简体中文](README.zh-CN.md)

[![CI](https://img.shields.io/github/actions/workflow/status/s-qin/aws-region-select-tool/test.yml?branch=main&style=flat&label=CI)](https://github.com/s-qin/aws-region-select-tool/actions/workflows/test.yml) [![Release](https://img.shields.io/github/v/release/s-qin/aws-region-select-tool)](https://github.com/s-qin/aws-region-select-tool/releases/latest) [![Windows](https://img.shields.io/badge/Windows-10_%7C_11-0078D4?style=flat&logo=windows11&logoColor=white)](https://www.microsoft.com/windows) [![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B_%7C_7.x-5391FE?style=flat&logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/) [![AWS Lightsail](https://img.shields.io/badge/AWS-Lightsail-FF9900?style=flat&logo=amazonwebservices&logoColor=white)](https://aws.amazon.com/lightsail/) [![License](https://img.shields.io/github/license/s-qin/aws-region-select-tool?style=flat&logo=opensourceinitiative&logoColor=white)](LICENSE)

一个零第三方运行时依赖的 PowerShell 工具：从当前电脑和网络出口对可部署的 Amazon Lightsail Region 排序，并在部署后验证真实 AWS/Lightsail 实例 IPv4。

版本 2.0.0 支持 Windows PowerShell 5.1 与 PowerShell 7.x；不要求 AWS CLI、AWS 账号、凭据或第三方模块，也绝不会创建或修改 AWS 资源。

## 为什么使用它？

- 创建实例前，用实际使用该实例的电脑与网络证据选择 Lightsail Region。
- 比较单 Region、内建地理 Group、自定义集合或完整受控 Lightsail Catalog。
- 部署后验证真实实例 IP，同时避免把 API endpoint TCP/443 与实例 TCP/22 混为同一指标。
- 保存有界的聚合 Baseline History；完整 samples 只进入单次 JSON report。

这是当前时点的网络诊断，不衡量价格、吞吐量、容量、Availability Zone、SLA 或应用性能。

## V2.0.0 亮点

- 受控 19 个 Lightsail Region Catalog，依据 AWS 文档，更新时间 2026-09-27。
- 无参数交互工作流与稳定的自动化 CLI。
- Target Selector 支持单 Region、五个内建 Group 和逗号分隔自定义集合。
- 自适应 `Auto`：1–6 个 Region 使用 Standard；7 个以上先 Quick screening，再 Standard 验证 finalists。
- `ScreeningRank`、`FinalistRank`、`RecommendationRank` 语义明确分离。
- Reachability discovery 按 Region 隔离失败；缺少 target 的 Region 仍以 `Unavailable` 展示。
- 完整承接 v1.1 Real IP Validation，并升级 History 2.0 与 Report JSON Schema 2.0。

## 系统要求与零依赖

- Windows 10 或 11。
- Windows PowerShell 5.1+ 或 PowerShell 7.x。
- Region probe 需要允许时的 ICMP、TCP/443；Real IP Validation 需要目标实例的指定 TCP port。
- 在线 EC2 Reachability discovery 与 AWS IP 自动识别需要互联网连接。

只使用 PowerShell 与 .NET 内置 API，不使用 AWS CLI 或凭据。

## 安装 / 下载

从最新 GitHub Release 下载 `aws-region-select-tool.ps1`，并使用 `SHA256SUMS.txt` 验证；也可以 clone：

```powershell
git clone https://github.com/s-qin/aws-region-select-tool.git
cd aws-region-select-tool
```

如执行策略阻止脚本，可只对当前进程调整：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

## 快速开始

```powershell
# 交互菜单
.\aws-region-select-tool.ps1

# 全球 Lightsail 扫描
.\aws-region-select-tool.ps1 -Target global

# v1.x 美国三区替代入口
.\aws-region-select-tool.ps1 -Target us-all -Mode Standard

# 单 Region 或自定义集合
.\aws-region-select-tool.ps1 -Target ap-southeast-1
.\aws-region-select-tool.ps1 -Target "ap-east-1,ap-southeast-1,ap-northeast-1"

# 使用稳定的 SSH/22 验证已部署实例
.\aws-region-select-tool.ps1 -TargetIp 203.0.113.10 -ProbePort 22
```

## 交互工作流

无参数运行显示一屏菜单：

```text
[1] Global Lightsail Scan
[2] Targeted Region Scan
[3] Real IP Validation
[Q] Quit
```

Targeted Scan 输入 `?` 可查看 Catalog 与 Groups。错误菜单或 target 可以重试；`Q` 不产生网络操作并安全退出。

## Global Lightsail Scan

`-Target global -Mode Auto` 使用两个独立证据阶段：

1. 对 Catalog 中全部 Region 做 Quick screening：每 Region 9 ICMP、3 TCP、2 TLS，不做 traceroute。
2. 对最多五个 health/evidence 合格的 finalists 做 Standard validation：36 ICMP、8 TCP、4 TLS，并为每个 finalist 做一次诊断 traceroute。

控制台先显示最终 Top 3，再显示 finalist validation，最后显示完整 screening evidence。无法确认 Reachability target 的 Region 仍会显示 `ProbeStatus=Unavailable` 与原因。Quick score 不会被伪装为精密的 1–19 最终排名。

## Targeted Scan、Target Grammar 与 Groups

输入会 trim，大小写不敏感，规范化为小写，按首次出现顺序去重，并在网络操作前整体校验。

| Target | Regions |
|---|---|
| `us-all` | `us-east-1`、`us-east-2`、`us-west-2` |
| `americas-all` | 美国三区、`ca-central-1`、`sa-east-1` |
| `eu-all` | `eu-central-1`、`eu-north-1`、`eu-south-2`、`eu-west-1`、`eu-west-2`、`eu-west-3` |
| `apac-all` | `ap-east-1`、`ap-northeast-1`、`ap-northeast-2`、`ap-south-1`、`ap-southeast-1`、`ap-southeast-2`、`ap-southeast-3`、`ap-southeast-5` |
| `global` | 当前受控 Catalog 中全部 19 个 Region |

用 `-ListTargets` 查看 code、location、geography、opt-in metadata 和 Group 精确展开。单 Region 只报告自身证据，不制造虚假的跨 Region 相对排名。

## Real IP Validation

```powershell
# 使用 AWS 官方 IPv4 range feed 自动识别 Region
.\aws-region-select-tool.ps1 -TargetIp 203.0.113.10 -ProbePort 22

# Offline/BYOIP 恢复：明确提供已知的 Lightsail Region
.\aws-region-select-tool.ps1 -TargetIp 203.0.113.10 -Region us-west-2 -ProbePort 22
```

工具对 AWS `ip-ranges.json` 做最长前缀 IPv4 CIDR 匹配，报告 Region、network border group、service、prefix 与 prefix length；不假设存在 `LIGHTSAIL` service。Unknown、BYOIP 或尚未发布的地址绝不猜测。

真实 IP 测试包含多次 ICMP、对 `-ProbePort`（默认 22）的重复 TCP 建连、traceroute、P50/P95/loss/jitter、TCP success rate 与 TCP P50。只有 ICMP 指标会与同 Region Baseline 比较；Regional AWS API TCP/443 绝不与实例 TCP/22 直接比较。

若实例阻断 ICMP 但 TCP 正常，结果是 `RETEST / INCONCLUSIVE`，而不是 Critical。如需完整 RTT 对照，可临时允许 Lightsail Ping (ICMP) firewall rule。

Verdict 综合多个信号：

- `KEEP / GOOD`：TCP 健康，Fresh/Usable 对照完整，退化处于保守范围。
- `RETEST / BORDERLINE`：中度或混合退化。
- `RETEST / INCONCLUSIVE`：ICMP filtered、缺少对照、证据不完整或两轮冲突。
- `RETRY / POOR`：首轮与一次延迟后的缩短 confirmation 都明确恶化时才成立。

## Auto、Quick、Standard 与 Thorough

| Mode | Region 行为 | 每 Region ICMP / TCP / TLS | Traceroute |
|---|---|---:|---|
| `Auto` | 1–6 Standard；7+ Quick 后最多 5 个 Standard finalists | 自适应 | 只在 final validation |
| `Quick` | 整个 selected set | 9 / 3 / 2 | 除非跳过 |
| `Standard` | 整个 selected set | 36 / 8 / 4 | 每 Region 一次 |
| `Thorough` | 整个 selected set | 45 / 10 / 5 | 每 Region 一次 |

高级 count 参数可覆盖 profile。全部 probe 串行、有界，并受 `-RoundDelayMs` 限速。

## Metrics、Region Score、Health 与 Confidence

P50 表示典型延迟；P95 表示尾部延迟；packet loss 是失败 ICMP 比例；jitter 使用总体标准差。TCP/TLS 综合成功率与握手延迟。

Region Score 保留 v1.1 权重：

- P50 30%、P95 20%、packet loss 20%、jitter 10%、TCP 15%、TLS 5%。

同一阶段内混合 absolute 与 relative quality。Health gate（`Good`、`Fair`、`Degraded`、`Critical`、`NoData`）优先于 Score。Confidence 综合 evidence completeness、Health、score margin、Baseline quality，以及 Real mode 的 TCP/ICMP 可用性与 freshness。

Traceroute 只作诊断，绝不参与 Score。

## Reachability Target Discovery

Lightsail Region Catalog 与 AWS 维护的 EC2 Reachability target 是两个事实源。工具运行时读取 declared source，按所选 Region 校验 IPv4 target；只有存在已验证 built-in cache 时才按 Region fallback。一个 target 或 Region 失败不会终止其他 Region；工具不会为了让 Catalog 看起来完整而编造 IP。

`-UseCachedTargets` 主要用于诊断或离线场景。内建 cache 只覆盖项目曾验证的 target，其他 Region 正确显示 unavailable。

## Reports 与 History

除非使用 `-NoJson`，每次运行都会写入带 `SchemaVersion: "2.0"` 的时间戳 JSON report。

Region Probe report 可表达：

- `Tool`、`Environment`、`Test`、`Catalog`、`Selection`、`TargetDiscovery`、`ProbePlan`。
- `Screening`、`FinalValidation`、分离的 rank fields、`Recommendation`。
- `History`、完整单次 `RawSamples`、`Warnings`。

Real report 使用 `Operation: "RealIpValidation"`，包括 `RealValidation`、Region detection、Baseline reference/refresh、可比 deltas、metrics、verdict、confirmation、raw samples 与 history status。不存在的阶段为 `null`，不会伪造。

聚合 history 相对主脚本保存于：

```text
$PSScriptRoot\.data\baseline-history.json
```

History Schema 2.0 保存 timestamp、scope、selection、profile、stage、Region aggregates、Health、Score 与有界 Real verdict aggregate，不保存完整 raw samples。默认保留 30 天，最多 50 个 Baseline runs 与 100 个 Real validations。History 1.0 会 lazy normalization 为 2.0。写入使用同目录已验证 temp 与 atomic replace/move；损坏数据会被 quarantine 并重建。

Real Baseline 状态：Fresh（≤6h）、Usable（>6h 且 ≤24h）、Stale（>24h）、Missing。Stale、Missing 或只有 Quick evidence 时，只对目标 Region 做一次有界 Standard refresh。

## CLI 参数

| 参数 | 用途 |
|---|---|
| `-Target <value>` | Region、Group 或逗号分隔自定义集合 |
| `-ListTargets` | 无网络探测地列出 Catalog 与 Groups |
| `-TargetIp <IPv4>` | 进入 Real IP Validation |
| `-ProbePort <1-65535>` | Real TCP port，默认 22 |
| `-Region <code>` | Real mode 手动 Region override |
| `-RetryDelaySeconds <1-60>` | 唯一一次 RETRY confirmation 前的延迟，默认 5 |
| `-Mode Auto\|Quick\|Standard\|Thorough` | Probe 策略，默认 Auto |
| `-IcmpSamplesPerRegion <0,3-60>` | 覆盖 ICMP count；0 使用 profile |
| `-TcpAttempts <1-15>` | 覆盖 TCP attempts；省略时使用 profile |
| `-TlsAttempts <1-8>` | 覆盖 TLS attempts；省略时使用 profile |
| `-PingTimeoutMs <250-5000>` | ICMP timeout |
| `-ConnectionTimeoutMs <500-10000>` | TCP/TLS timeout |
| `-RoundDelayMs <100-5000>` | ICMP round 间隔 |
| `-MaxTargetsPerRegion <1-3>` | 每 Region target 上限 |
| `-OutputPath <path>` | JSON 输出路径 |
| `-NoJson` | 不写 JSON report |
| `-UseCachedTargets` | 跳过在线 Reachability discovery |
| `-SkipTraceroute` | 跳过诊断 traceroute |

`-Target` 与 `-TargetIp` 互斥；`-Region` 只允许与 `-TargetIp` 同用。冲突会在任何网络操作前拒绝。

## Exit Codes

- `0`：产生可操作的 Region recommendation 或 Real verdict；listing/quit 也成功。
- `2`：参数无效、路由冲突、识别失败或 runtime error。
- `3`：没有足够证据安全推荐或判定。

## 公共 Target 礼仪与安全

- Probe 串行执行，count、timeout、target、finalist、confirmation 都有硬上限。
- 不做 throughput、flood、stress、port-range scan 或无限重试。
- 单 Region 失败与其余 Region 隔离。
- `.data`、reports、test outputs 与临时文件由 Git 忽略。
- Report 包含诊断与本地环境 metadata，分享前请检查。
- 不请求或保存 secrets、tokens、cookies、AWS credentials、private keys。

## 故障排除

- **Region Unavailable：** online discovery 没有有效 target，且没有已验证 cache。稍后重试，不要随意替换 AWS IP。
- **所有 TLS 都失败：** proxy、TLS inspection 或本地策略可能阻断 Regional endpoint；检查 TCP/error 字段，Health gate 会阻止不安全推荐。
- **真实实例 ICMP 100% loss：** 先确认 TCP；需要完整对照时临时允许 Lightsail Ping。
- **AWS IP 无法识别：** 可能是 BYOIP 或比 published feed 更新；仅在确定事实时使用 `-Region`。
- **History warning：** 损坏文件保留为 `.corrupt-*.json`，新 store 自动创建。

## 示例输出

```text
AWS Lightsail Region Selection
Selection: global (19 Regions)
Plan: TwoStage

Final Recommendation
RecommendationRank  Region          Score  Health
1                   ap-southeast-1  91.4   Good
2                   ap-east-1       87.2   Good
3                   ap-northeast-1  82.6   Good

Global Screening - All Selected Regions
...包含明确 Unavailable 行的全部 selected Regions...
```

示例只展示格式；实际结果取决于当前电脑、路径、网络出口和时间。

## 开发、测试与 CI

确定性 suite 不对公共 target 产生 live 负载，覆盖 Catalog/groups/grammar、planner、Region failure isolation、rankings、JSON 2.0、History migration/retention/atomic recovery、CIDR detection、Real verdict/confirmation、CLI conflicts、安全、文档与 License。

```powershell
pwsh.exe -NoProfile -File .\tests\run-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

GitHub Actions 在 Windows PowerShell 5.1 与 PowerShell 7.x 上运行同一套测试。Live smoke 由人工有界执行，因为瞬时公共网络结果不能作为确定性 fixture。

## v1.1 → v2.0 迁移与 Breaking Changes

- 无参数现在打开交互菜单，不再立即执行美国三区 Baseline。
- 使用 `.\aws-region-select-tool.ps1 -Target us-all -Mode Standard` 获得 v1.x Baseline 等价入口。
- Region Probe 默认 `-Mode` 改为 `Auto`；显式 `Quick`、`Standard`、`Thorough` 保持对应 profile。
- Report schema 从 1.1 改为 2.0；消费者应按 `Operation` 路由并读取 stage-specific fields。
- History 1.0 可读取并 lazy normalization；删除 `.data` 仍可安全重置本地 history。
- Real IP 参数与 KEEP/RETEST/RETRY 核心语义保持兼容。

## 已知限制

- Catalog 是受控快照；AWS 改变 Lightsail 可用性时需要项目更新。
- Reachability target 是动态数据，即使 Lightsail 支持该 Region 也可能暂时缺失。
- ICMP/traceroute 可能被过滤；TCP/TLS 可能受 proxy 与 endpoint policy 影响。
- Atomic write 防止 partial JSON；多个进程并发写采用 last-completed-writer-wins，不提供跨进程锁。
- Score 只比较同一 probe stage 的候选；Quick 与 Standard evidence 不视为同一精度。

## 安全说明

执行前检查下载脚本并验证 Release SHA-256。工具只进行 outbound diagnostics 与本地 report/history 写入，不调用 AWS management API，也不修改云资源。

## License

[MIT](LICENSE) — Copyright (c) 2026 sqin。
