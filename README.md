# AWS Region Select Tool

[简体中文](README.zh-CN.md)

[![Windows](https://img.shields.io/badge/Windows-10_%7C_11-0078D4?style=flat&logo=windows11&logoColor=white)](https://www.microsoft.com/windows) [![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B_%7C_7.x-5391FE?style=flat&logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/) [![AWS Lightsail](https://img.shields.io/badge/AWS-Lightsail-FF9900?style=flat&logo=amazonwebservices&logoColor=white)](https://aws.amazon.com/lightsail/) [![License](https://img.shields.io/github/license/s-qin/aws-region-select-tool?style=flat&logo=opensourceinitiative&logoColor=white)](LICENSE)

A single-file PowerShell tool with two complementary workflows: **Region Baseline** ranks three AWS US Regions before deployment, and **Real IP Validation** checks a newly assigned AWS/Lightsail IPv4 address against recent local baseline evidence.

- `us-east-1` — US East (N. Virginia)
- `us-east-2` — US East (Ohio)
- `us-west-2` — US West (Oregon)

It creates no AWS resources, needs no AWS account or AWS CLI, and has no third-party runtime dependencies. It supports Windows PowerShell 5.1+ and PowerShell 7.x on Windows 10/11.

## How it works

The tool reads AWS's [EC2 Reachability Test](http://ec2-reachability.amazonaws.com/) data source and selects up to three targets per Region. If discovery fails, it uses targets cached inside the script and records the fallback reason and cache date.

ICMP probes are sequential and interleaved across Regions in a randomized round-robin order. This keeps samples in similar time windows and avoids sustained or concurrent traffic to AWS's shared public targets. The tool then tests Regional AWS HTTPS endpoints and captures one traceroute per Region.

Each successful Baseline stores only aggregate results in `.data/baseline-history.json`. `-TargetIp` resolves AWS ownership using the official [AWS IP ranges](https://ip-ranges.amazonaws.com/ip-ranges.json), selects the most-specific IPv4 prefix, finds the nearest earlier same-Region baseline, and tests the real IP with ICMP and repeated TCP connections. A manual `-Region` override supports BYOIP, unpublished ranges, or an unavailable range feed without guessing.

Real TCP (TCP/22 by default) is instance reachability evidence. It is intentionally not compared with the Baseline's Regional API TCP/443 measurement.

## What is tested

| Test | Recorded values | Role |
|---|---|---|
| ICMP | sent, received, loss, min, average, P50, P95, max, population standard deviation (jitter) | Core latency and stability evidence |
| TCP 443 | success rate, P50/P95 connect time, timeout count | Real connection capability |
| TLS | success rate, P50/P95 handshake time, protocol and cipher | Certificate-validated application-path check |
| `tracert` | bounded raw route output to the primary Reachability target | Diagnostic context only; never scored |

Real IP mode records ICMP P50/P95/loss/jitter, TCP success rate and P50 for `-ProbePort`, plus one traceroute. TLS is not required because a new Lightsail instance normally exposes SSH/22 before HTTPS is configured.

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

Validate a real instance IP (AWS Region auto-detected):

```powershell
.\aws-region-select-tool.ps1 -TargetIp 203.0.113.10 -ProbePort 22
```

Validate an unknown/BYOIP address with an explicit supported Region, bypassing the range download:

```powershell
.\aws-region-select-tool.ps1 -TargetIp 203.0.113.10 -Region us-west-2 -ProbePort 22
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
| `-TargetIp` | none | IPv4 literal; selects Real IP Validation mode |
| `-ProbePort` | `22` | Real IP TCP port, 1–65535 |
| `-Region` | auto | Manual `us-east-1`, `us-east-2`, or `us-west-2` override; valid only with `-TargetIp` |
| `-RetryDelaySeconds` | `5` | Delay before the one shortened confirmation of a RETRY candidate, 1–60 seconds |
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

In Real mode, profile defaults are Quick 6/4, Standard 15/8, and Thorough 25/12 ICMP/TCP attempts. Explicit `-IcmpSamplesPerRegion` and `-TcpAttempts` still override them. `-TlsAttempts` is retained for Baseline compatibility and is unused for the real IP.

## Reading the output

The ranking table shows the primary metrics, health state, and composite score. A per-Region section then shows successful attempts and traceroute status. Target source is always displayed.

Health is evaluated before recommendation:

- `Good`: no material fault was detected.
- `Fair`: usable, with mild loss, tail-latency, or TCP concerns.
- `Degraded`: substantial loss or reduced TCP/TLS success; score is capped at 55.
- `Critical`: TCP is unavailable or severe combined failures exist; score is capped at 25.
- `NoData`: all core probes failed; score is 0.

The process exits with `0` when a safe recommendation is produced, `3` when evidence is insufficient, and `2` for an unexpected runtime/usage failure. A diagnostic JSON report is still attempted for insufficient-evidence runs.

## Real IP comparison and Verdict

Baseline freshness is `Fresh` at 6 hours or less, `Usable` after 6 through 24 hours, `Stale` after 24 hours, and `Missing` when absent. Fresh/Usable evidence is used directly. Stale/Missing automatically triggers a Quick Baseline for only the detected Region; it never needlessly probes all three Regions.

The table compares ICMP P50, P95, packet loss, and jitter with absolute and percentage deltas. A zero baseline denominator reports no percentage. The decision combines all available latency, loss, jitter, TCP success, completeness, and freshness evidence:

- `KEEP / GOOD`: TCP success is at least 90%, ICMP comparison is available, and degradation stays within conservative P50 20%, P95 25%, loss 2 percentage points, and jitter 50% or 5 ms limits.
- `RETEST / BORDERLINE`: evidence is usable but moderately degraded or mixed.
- `RETEST / INCONCLUSIVE`: comparison is unavailable, evidence conflicts, or ICMP is blocked while TCP remains reachable.
- `RETRY / POOR`: TCP success below 50% or at least two severe ICMP regressions. A final RETRY is emitted only if one delayed shortened confirmation is also a RETRY candidate; conflicting rounds become RETEST/INCONCLUSIVE.

If ICMP has 100% loss but TCP/22 works, the tool reports “ICMP unavailable / possibly firewall-filtered,” lowers confidence, and never invents RTT deltas or labels the network Critical. For a complete Baseline comparison, temporarily enable the Lightsail Ping (ICMP) firewall rule, run the validation, then remove the rule if it is not otherwise needed.

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

Unless `-NoJson` is used, Baseline reports use `aws-us-region-test_yyyy-MM-dd_HHmmss.json`; Real reports use `aws-real-ip-validation_<ip>_yyyy-MM-dd_HHmmss.json`. `SchemaVersion` is `1.1`.

Top-level content includes:

- tool and run settings;
- UTC timestamps and PowerShell/Windows environment;
- target source, retrieval/cache metadata, fallback reason, and targets;
- ranked Region summaries, health, score components, completeness, and traceroute;
- recommendation, confidence, decisiveness, and score margin;
- every raw ICMP, TCP 443, and TLS sample, including structured errors.

Baseline keeps the v1 top-level fields and adds `Operation: RegionBaseline` and `History`. Real reports use `Operation: RealIpValidation` with `Target`, `RegionDetection`, `BaselineReference`, `BaselineRefresh`, `RealMetrics`, `Comparison`, `InitialAssessment`, optional `Confirmation`, `Verdict`, `RawSamples`, and `History`.

Parse it with:

```powershell
$report = Get-Content .\aws-us-region-test_2026-09-13_092500.json -Raw | ConvertFrom-Json
$report.Recommendation
$report.Rankings | Select-Object Region, Score, Health
```

## Local history

The store is always relative to the script: `$PSScriptRoot\.data\baseline-history.json`, independent of the installation drive. It retains 30 days, at most 50 Baseline runs and 100 Real validations. Baseline entries contain UTC timestamp, mode/scope, Region, P50/P95/loss/jitter, Health, and Score; Real entries contain target/port aggregates, baseline reference, and Verdict. Full raw samples exist only in report JSON.

Writes use a validated same-directory temporary file and atomic replace/move. The previous file is retained as `.bak`. Invalid JSON is moved to `.corrupt-<UTC>.json` and a clean store is rebuilt, so damaged history cannot permanently disable the tool. Delete `.data` to reset history.

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

Real mode uses the heading `AWS Real IP Validation` and prints target, detected Region/source, probe port, baseline timestamp/age/status, the delta table, Instance Fit, Recommendation, Confidence, and reasons.

## Limits and cautions

- Results represent only the current PC, network exit, route, and test time. Run again at different times before a consequential deployment.
- ICMP may be filtered or rate-limited. TCP/TLS corroborate it but do not measure application response time or throughput.
- AWS range detection reflects the published feed. BYOIP/unpublished addresses require `-Region`; addresses outside the three supported Baseline Regions are rejected honestly.
- A real instance port can be closed by its OS or Lightsail firewall. That is reachability evidence, not proof of poor geographic routing by itself.
- A Regional AWS API endpoint can be reached through enterprise proxies or security products; interpret unusually low TCP times alongside TLS and ICMP.
- `tracert` timeouts at intermediate hops are common and do not prove packet loss.
- The tool does not evaluate service availability, cost, compliance, capacity, Availability Zones, data residency, or application architecture.
- It is a pre-deployment signal, not continuous monitoring or a service-level guarantee.

## Safety and privacy

The script sends bounded, sequential probes and has no infinite retries or parallel fan-out. Even the Thorough profile is capped at 45 ICMP, 10 TCP, and 5 TLS attempts per Region, below the hard parameter maxima. Do not schedule it at high frequency against AWS's shared targets.

No AWS credentials are requested or read. Reports/history can contain the local computer name, timestamps, target IPs, network errors, and traceroute paths; review them before sharing. Timestamped reports, `.data/`, `reports/`, `test-results/`, and temporary files are excluded from Git by default.

## Development verification

The repository includes a zero-dependency deterministic test runner:

```powershell
pwsh.exe -NoProfile -File .\tests\run-tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

It covers the v1 regression plus IPv4/CIDR longest-prefix detection, unknown/override/fetch errors, history create/retention/atomic recovery, baseline age/selection, ICMP/TCP combinations, deltas, KEEP/RETEST/RETRY confirmation, insufficient evidence, JSON parsing, and rate-safety bounds. Live network results are intentionally not used as deterministic pass/fail fixtures.

## License

[MIT](LICENSE) © 2026 sqin
