# AWS Region Select Tool

[简体中文](README.zh-CN.md)

A single-file PowerShell tool that measures the current PC's real network path to three AWS US Regions and recommends the best pre-deployment candidate:

- `us-east-1` — US East (N. Virginia)
- `us-east-2` — US East (Ohio)
- `us-west-2` — US West (Oregon)

It creates no AWS resources, needs no AWS account or AWS CLI, and has no third-party runtime dependencies. It supports Windows PowerShell 5.1+ and PowerShell 7.x on Windows 10/11.

## How it works

The tool reads AWS's [EC2 Reachability Test](http://ec2-reachability.amazonaws.com/) data source and selects up to three targets per Region. If discovery fails, it uses targets cached inside the script and records the fallback reason and cache date.

ICMP probes are sequential and interleaved across Regions in a randomized round-robin order. This keeps samples in similar time windows and avoids sustained or concurrent traffic to AWS's shared public targets. The tool then tests Regional AWS HTTPS endpoints and captures one traceroute per Region.

The result answers one question only: from this PC and this network exit, which candidate Region currently has the best and most stable network quality?

## What is tested

| Test | Recorded values | Role |
|---|---|---|
| ICMP | sent, received, loss, min, average, P50, P95, max, population standard deviation (jitter) | Core latency and stability evidence |
| TCP 443 | success rate, P50/P95 connect time, timeout count | Real connection capability |
| TLS | success rate, P50/P95 handshake time, protocol and cipher | Certificate-validated application-path check |
| `tracert` | bounded raw route output to the primary Reachability target | Diagnostic context only; never scored |

## Install / download

Download the script, inspect it, and then run it. Avoid piping a remote script directly into `Invoke-Expression`.

```powershell
$url = 'https://raw.githubusercontent.com/s-qin/aws-region-select-tool/main/aws-region-select-tool.ps1'
Invoke-WebRequest -Uri $url -OutFile .\aws-region-select-tool.ps1
Get-FileHash .\aws-region-select-tool.ps1 -Algorithm SHA256
```

If Windows marks the downloaded file as blocked:

```powershell
Unblock-File .\aws-region-select-tool.ps1
```

## Usage

Run the Standard profile:

```powershell
.\aws-region-select-tool.ps1
```

Run a shorter validation, force bundled targets, and omit traceroute:

```powershell
.\aws-region-select-tool.ps1 -Mode Quick -UseCachedTargets -SkipTraceroute
```

Write the report to a chosen location:

```powershell
.\aws-region-select-tool.ps1 -OutputPath .\reports\office-network.json
```

Show complete built-in help:

```powershell
Get-Help .\aws-region-select-tool.ps1 -Full
```

If local execution policy blocks scripts, use a process-scoped invocation rather than changing the machine policy:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\aws-region-select-tool.ps1
```

## Parameters

| Parameter | Default | Meaning |
|---|---:|---|
| `-Mode` | `Standard` | `Quick` = 9/3/2, `Standard` = 36/8/4, `Thorough` = 45/10/5 ICMP/TCP/TLS attempts per Region |
| `-IcmpSamplesPerRegion` | profile | Override with 3–60 samples |
| `-TcpAttempts` | profile | Override with 1–15 attempts |
| `-TlsAttempts` | profile | Override with 1–8 attempts |
| `-PingTimeoutMs` | `1200` | Per-ICMP timeout, 250–5000 ms |
| `-ConnectionTimeoutMs` | `3000` | TCP connect and TLS handshake timeout, 500–10000 ms |
| `-RoundDelayMs` | `250` | Pause after each ICMP round, 100–5000 ms |
| `-MaxTargetsPerRegion` | `3` | Reachability targets used per Region, 1–3 |
| `-OutputPath` | timestamped file | JSON destination |
| `-NoJson` | off | Suppress JSON output |
| `-UseCachedTargets` | off | Skip online target discovery |
| `-SkipTraceroute` | off | Skip diagnostic traceroutes |

## Reading the output

The ranking table shows the primary metrics, health state, and composite score. A per-Region section then shows successful attempts and traceroute status. Target source is always displayed.

Health is evaluated before recommendation:

- `Good`: no material fault was detected.
- `Fair`: usable, with mild loss, tail-latency, or TCP concerns.
- `Degraded`: substantial loss or reduced TCP/TLS success; score is capped at 55.
- `Critical`: TCP is unavailable or severe combined failures exist; score is capped at 25.
- `NoData`: all core probes failed; score is 0.

The process exits with `0` when a safe recommendation is produced, `3` when evidence is insufficient, and `2` for an unexpected runtime/usage failure. A diagnostic JSON report is still attempted for insufficient-evidence runs.

## Region Score and Confidence

The 0–100 Region Score is not a lowest-ping ranking. Its weights are:

| Component | Weight |
|---|---:|
| ICMP P50 | 30% |
| ICMP P95 | 20% |
| Packet loss | 20% |
| RTT jitter / standard deviation | 10% |
| TCP 443 quality | 15% |
| TLS quality | 5% |

Each component blends 70% bounded absolute quality with 30% relative position among the three Regions. TCP and TLS quality each combine 70% success rate with 30% median latency quality. Health caps prevent a low average latency from hiding a broken path.

Confidence also considers score margin, health, and successful-data completeness:

- `High`: a Good winner leads by at least 12 points with at least 85% data completeness.
- `Medium`: the lead is decisive (at least 5 points), the winner is Good/Fair, and completeness is at least 65%.
- `Low`: the top two are close, evidence is incomplete, or health is degraded.

A margin below 5 points is reported as **No decisive winner**. Rerun later instead of treating a tiny point-in-time difference as conclusive. Scores are comparable only within one run, not across different devices, networks, or dates.

## JSON report

Unless `-NoJson` is used, the default filename is `aws-us-region-test_yyyy-MM-dd_HHmmss.json`. `SchemaVersion` is currently `1.0`.

Top-level content includes:

- tool and run settings;
- UTC timestamps and PowerShell/Windows environment;
- target source, retrieval/cache metadata, fallback reason, and targets;
- ranked Region summaries, health, score components, completeness, and traceroute;
- recommendation, confidence, decisiveness, and score margin;
- every raw ICMP, TCP 443, and TLS sample, including structured errors.

Parse it with:

```powershell
$report = Get-Content .\aws-us-region-test_2026-09-13_092500.json -Raw | ConvertFrom-Json
$report.Recommendation
$report.Rankings | Select-Object Region, Score, Health
```

## Example output

This shortened example matches the current CLI layout; values vary by network and time:

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

## Limits and cautions

- Results represent only the current PC, network exit, route, and test time. Run again at different times before a consequential deployment.
- ICMP may be filtered or rate-limited. TCP/TLS corroborate it but do not measure application response time or throughput.
- A Regional AWS API endpoint can be reached through enterprise proxies or security products; interpret unusually low TCP times alongside TLS and ICMP.
- `tracert` timeouts at intermediate hops are common and do not prove packet loss.
- The tool does not evaluate service availability, cost, compliance, capacity, Availability Zones, data residency, or application architecture.
- It is a pre-deployment signal, not continuous monitoring or a service-level guarantee.

## Safety and privacy

The script sends bounded, sequential probes and has no infinite retries or parallel fan-out. Even the Thorough profile is capped at 45 ICMP, 10 TCP, and 5 TLS attempts per Region, below the hard parameter maxima. Do not schedule it at high frequency against AWS's shared targets.

No AWS credentials are requested or read. Reports can contain the local computer name, timestamps, target IPs, network errors, and traceroute paths; review a report before sharing it publicly. Timestamped reports, `reports/`, `test-results/`, and temporary files are excluded from Git by default.

## Development verification

The repository includes a zero-dependency deterministic test runner:

```powershell
pwsh.exe -NoProfile -File .\tests\run-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

It covers syntax, help, discovery and fallback, statistics, TCP/TLS/tracert failure isolation, scoring, health, confidence, near ties, all-target failure, JSON parsing, and rate-safety bounds. Live network results are intentionally not used as deterministic pass/fail fixtures.

## License

[MIT](LICENSE) © 2026 sqin

