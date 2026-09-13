# AWS Region Select Tool

[English](README.md)

这是一个单文件 PowerShell 工具，用当前电脑的真实网络路径测试三个 AWS 美国 Region，并推荐最佳的预部署候选：

- `us-east-1` — 美国东部（弗吉尼亚北部）
- `us-east-2` — 美国东部（俄亥俄）
- `us-west-2` — 美国西部（俄勒冈）

工具不会创建 AWS 资源，不需要 AWS 账号或 AWS CLI，也没有第三方运行时依赖。支持 Windows 10/11 上的 Windows PowerShell 5.1+ 与 PowerShell 7.x。

## 工作原理

工具读取 AWS [EC2 Reachability Test](http://ec2-reachability.amazonaws.com/) 声明的数据源，每个 Region 最多选择三个目标。发现失败时，使用脚本内置的缓存目标，并记录 fallback 原因和缓存日期。

ICMP 探测按 Region 随机轮转、交错、串行执行，使三组样本处在接近的时间窗口，同时避免对 AWS 共享公共目标产生持续或并发流量。随后测试区域 AWS HTTPS Endpoint，并为每个 Region 保存一次 traceroute。

结果只回答一个问题：从这台电脑、这个网络出口出发，哪个候选 Region 当前网络质量最好、最稳定？

## 测试内容

| 测试 | 记录指标 | 用途 |
|---|---|---|
| ICMP | Sent、Received、Loss、Min、Average、P50、P95、Max、总体标准差（Jitter） | 核心延迟与稳定性证据 |
| TCP 443 | 成功率、P50/P95 建连时间、超时数 | 真实连接能力 |
| TLS | 成功率、P50/P95 握手时间、协议和加密算法 | 带证书验证的应用路径检查 |
| `tracert` | 到主 Reachability target 的有界原始路径输出 | 只用于诊断，绝不计分 |

## 安装 / 下载

先下载、检查脚本，再运行。不要把远程脚本直接通过管道传给 `Invoke-Expression`。

```powershell
$url = 'https://raw.githubusercontent.com/s-qin/aws-region-select-tool/main/aws-region-select-tool.ps1'
Invoke-WebRequest -Uri $url -OutFile .\aws-region-select-tool.ps1
Get-FileHash .\aws-region-select-tool.ps1 -Algorithm SHA256
```

若 Windows 将下载文件标记为已阻止：

```powershell
Unblock-File .\aws-region-select-tool.ps1
```

## 使用方法

运行 Standard 模式：

```powershell
.\aws-region-select-tool.ps1
```

做一次较短验证、强制使用内置目标并跳过 traceroute：

```powershell
.\aws-region-select-tool.ps1 -Mode Quick -UseCachedTargets -SkipTraceroute
```

把报告写到指定位置：

```powershell
.\aws-region-select-tool.ps1 -OutputPath .\reports\office-network.json
```

显示完整内置帮助：

```powershell
Get-Help .\aws-region-select-tool.ps1 -Full
```

如果本地执行策略阻止脚本，请使用进程级调用，不要修改整台机器的策略：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\aws-region-select-tool.ps1
```

## 参数

| 参数 | 默认值 | 含义 |
|---|---:|---|
| `-Mode` | `Standard` | 每 Region 的 ICMP/TCP/TLS 次数：`Quick` = 9/3/2、`Standard` = 36/8/4、`Thorough` = 45/10/5 |
| `-IcmpSamplesPerRegion` | 跟随模式 | 覆盖为 3–60 个样本 |
| `-TcpAttempts` | 跟随模式 | 覆盖为 1–15 次 |
| `-TlsAttempts` | 跟随模式 | 覆盖为 1–8 次 |
| `-PingTimeoutMs` | `1200` | 单次 ICMP 超时，250–5000 ms |
| `-ConnectionTimeoutMs` | `3000` | TCP 建连与 TLS 握手超时，500–10000 ms |
| `-RoundDelayMs` | `250` | 每轮 ICMP 后暂停，100–5000 ms |
| `-MaxTargetsPerRegion` | `3` | 每 Region 使用 1–3 个 Reachability targets |
| `-OutputPath` | 带时间戳文件 | JSON 输出位置 |
| `-NoJson` | 关闭 | 不生成 JSON |
| `-UseCachedTargets` | 关闭 | 跳过在线目标发现 |
| `-SkipTraceroute` | 关闭 | 跳过诊断 traceroute |

## 输出解释

排名表显示核心指标、健康状态和综合分；每个 Region 的摘要随后显示成功次数和 traceroute 状态。Target Source 始终会显示。

推荐前先执行健康检查：

- `Good`：未发现明显故障。
- `Fair`：可用，但有轻微丢包、尾延迟或 TCP 问题。
- `Degraded`：丢包明显或 TCP/TLS 成功率下降；Score 最高封顶 55。
- `Critical`：TCP 不可用或存在严重组合故障；Score 最高封顶 25。
- `NoData`：所有核心探测失败；Score 为 0。

安全产生推荐时进程退出码为 `0`；证据不足时为 `3`；意外运行/用法错误为 `2`。证据不足时仍会尽量写出诊断 JSON。

## Region Score 与 Confidence

0–100 的 Region Score 不是最低 Ping 排名，权重如下：

| 组成 | 权重 |
|---|---:|
| ICMP P50 | 30% |
| ICMP P95 | 20% |
| Packet Loss | 20% |
| RTT Jitter / 标准差 | 10% |
| TCP 443 质量 | 15% |
| TLS 质量 | 5% |

每个组成项由 70% 有界绝对质量和 30% 三个 Region 之间的相对位置混合得到。TCP 与 TLS 质量各自由 70% 成功率和 30% 中位延迟质量组成。健康分上限可防止很低的平均延迟掩盖已损坏的路径。

Confidence 同时考虑分差、健康状态和成功数据完整度：

- `High`：第一名为 Good，领先至少 12 分，数据完整度至少 85%。
- `Medium`：领先达到决定性标准（至少 5 分），第一名为 Good/Fair，完整度至少 65%。
- `Low`：前两名接近、证据不完整或健康状态下降。

分差低于 5 时输出 **No decisive winner**。应稍后复测，不要把很小的瞬时差异当作确定结论。Score 只能在同一次运行内比较，不能跨设备、网络或日期直接比较。

## JSON 报告

除非使用 `-NoJson`，默认文件名为 `aws-us-region-test_yyyy-MM-dd_HHmmss.json`。当前 `SchemaVersion` 为 `1.0`。

顶层内容包括：

- 工具与运行设置；
- UTC 时间戳及 PowerShell/Windows 环境；
- 目标来源、获取/缓存元数据、fallback 原因和目标列表；
- 排名、健康状态、分数组成、完整度和 traceroute；
- 推荐、Confidence、是否有决定性、分差；
- 每一个原始 ICMP、TCP 443、TLS 样本及结构化错误。

解析示例：

```powershell
$report = Get-Content .\aws-us-region-test_2026-09-13_092500.json -Raw | ConvertFrom-Json
$report.Recommendation
$report.Rankings | Select-Object Region, Score, Health
```

## 示例输出

以下缩略示例与当前 CLI 布局一致；数值会随网络和时间变化：

```text
AWS US Region Network Test
Source: Current PC / Current Network Exit
Target Source: AWSReachabilityPage

Rank Region    P50   P95     Loss Jitter TCP  Health Score
1    us-west-2 185ms 191ms   0%   4.91ms 100% Good   68.5
2    us-east-1 239ms 241ms   0%   4.02ms 100% Good   56.3
3    us-east-2 251ms 252.6ms 0%   1.4ms  100% Good   53.5

Recommended Region: us-west-2 (US West (Oregon))
Confidence: High
Recommended from this run and network exit.
```

## 限制与注意事项

- 结果只代表当前电脑、网络出口、路由和测试时刻。重要部署前应在不同时段重复运行。
- ICMP 可能被过滤或限速；TCP/TLS 用于相互印证，但不测应用响应时间或吞吐量。
- 企业代理或安全产品可能参与区域 AWS API Endpoint 的连接；若 TCP 时间异常低，应结合 TLS 和 ICMP 解读。
- `tracert` 中间 Hop 超时很常见，不能据此认定丢包。
- 工具不评估服务可用性、价格、合规、容量、可用区、数据驻留或应用架构。
- 它是预部署信号，不是持续监控或服务等级保证。

## 安全与隐私

脚本只发送有界、串行探测，没有无限重试或并行扇出。即使 Thorough 模式，每 Region 也固定为 45 ICMP、10 TCP、5 TLS，低于参数硬上限。不要对 AWS 共享目标进行高频定时运行。

脚本不会请求或读取 AWS 凭据。报告可能包含本机名、时间戳、目标 IP、网络错误和 traceroute 路径；公开分享前请检查。带时间戳的报告、`reports/`、`test-results/` 和临时文件默认被 Git 忽略。

## 开发验证

仓库包含一个零依赖的确定性测试运行器：

```powershell
pwsh.exe -NoProfile -File .\tests\run-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

它覆盖语法、Help、发现与 fallback、统计、TCP/TLS/tracert 失败隔离、评分、健康状态、Confidence、近似平局、全部目标失败、JSON 解析和频率安全边界。真实网络结果不会被用作确定性的通过/失败 fixture。

## License

[MIT](LICENSE) © 2026 sqin
