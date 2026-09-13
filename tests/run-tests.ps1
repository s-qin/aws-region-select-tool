#requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $root 'aws-region-select-tool.ps1'
. $scriptPath

$script:Passed = 0
$script:Failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) {
        $script:Passed++
        Write-Host "PASS $Name"
    }
    else {
        $script:Failed++
        Write-Host "FAIL $Name" -ForegroundColor Red
    }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Name)
    Assert-True -Condition ($Actual -eq $Expected) -Name ("{0} (actual={1}, expected={2})" -f $Name, $Actual, $Expected)
}

function New-Samples {
    param([double[]]$Values, [int]$Failures = 0)
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($value in $Values) { $items.Add([pscustomobject]@{ Success = $true; DurationMs = $value }) }
    for ($index = 0; $index -lt $Failures; $index++) { $items.Add([pscustomobject]@{ Success = $false; DurationMs = $null }) }
    return @($items | ForEach-Object { $_ })
}

function New-RegionFixture {
    param(
        [string]$Region, [double[]]$IcmpValues, [int]$IcmpFailures,
        [double[]]$TcpValues, [int]$TcpFailures, [double[]]$TlsValues, [int]$TlsFailures
    )
    $icmp = Get-SampleStatistics (New-Samples $IcmpValues $IcmpFailures)
    $tcp = Get-SampleStatistics (New-Samples $TcpValues $TcpFailures)
    $tls = Get-SampleStatistics (New-Samples $TlsValues $TlsFailures)
    $tcp | Add-Member QualityPct (Get-TcpOrTlsQuality $tcp)
    $tls | Add-Member QualityPct (Get-TcpOrTlsQuality $tls)
    return [pscustomobject][ordered]@{
        Region = $Region; Name = $script:RegionMetadata[$Region].Name; Icmp = $icmp; Tcp = $tcp; Tls = $tls
        Health = Get-RegionHealth $icmp $tcp $tls; Score = 0.0; ScoreComponents = $null; DataCompletenessPct = 0.0
    }
}

$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
Assert-Equal $parseErrors.Count 0 'PowerShell syntax parser'

$help = Get-Help $scriptPath -Full | Out-String
Assert-True ($help -match 'IcmpSamplesPerRegion' -and $help -match 'UseCachedTargets' -and $help -match 'SkipTraceroute' -and $help -match 'Real IP Validation mode') 'Comment-based help exposes parameters and mode semantics'
Assert-True ($help -match '-TargetIp 203\.0\.113\.10' -and $help -match 'Exit 3') 'Comment-based help exposes Real example and exit semantics'

Assert-Equal (Get-Percentile @(10, 20, 30, 40) 50) 25 'P50 interpolation'
Assert-Equal (Get-Percentile @(10, 20, 30, 40) 95) 38.5 'P95 interpolation'
$stats = Get-SampleStatistics (New-Samples @(10, 20, 30, 40) 1)
Assert-Equal $stats.Sent 5 'Statistics sent count'
Assert-Equal $stats.Received 4 'Statistics received count'
Assert-Equal $stats.LossPct 20 'Statistics packet loss'
Assert-Equal $stats.AverageMs 25 'Statistics average'
Assert-Equal $stats.JitterMs 11.18 'Statistics population standard deviation jitter'
Assert-True ((Get-ModeDefaults 'Quick').Icmp -eq 9 -and (Get-ModeDefaults 'Quick').Tcp -eq 3 -and (Get-ModeDefaults 'Quick').Tls -eq 2) 'Quick Baseline profile unchanged'
Assert-True ((Get-ModeDefaults 'Standard').Icmp -eq 36 -and (Get-ModeDefaults 'Standard').Tcp -eq 8 -and (Get-ModeDefaults 'Standard').Tls -eq 4) 'Standard Baseline profile unchanged'
Assert-True ((Get-ModeDefaults 'Thorough').Icmp -eq 45 -and (Get-ModeDefaults 'Thorough').Tcp -eq 10 -and (Get-ModeDefaults 'Thorough').Tls -eq 5) 'Thorough Baseline profile unchanged'

$fixtureHtml = @'
<table>
<tr><td>us-east-1</td><td>10.0.0.0/8</td><td>1.1.1.1</td><td>1.1.1.2</td></tr>
<tr><td>us-east-2</td><td>10.0.0.0/8</td><td>2.2.2.2</td></tr>
<tr><td>us-west-2</td><td>10.0.0.0/8</td><td>3.3.3.3</td></tr>
</table>
'@
$onlineTargets = Get-ReachabilityTargets -MaximumTargets 2 -ContentFetcher { $fixtureHtml }
Assert-Equal $onlineTargets.Source 'AWSReachabilityPage' 'Reachability online parsing path'
Assert-Equal $onlineTargets.Targets['us-east-1'][0] '1.1.1.1' 'Reachability parser excludes CIDR prefix'
Assert-Equal $onlineTargets.Targets['us-east-1'].Count 2 'Reachability parser honors target limit'
$fixtureJson = '[{"us-east-1":{"10.0.0.0/8":"1.1.1.1"}},{"us-east-2":{"10.0.0.0/8":"2.2.2.2"}},{"us-west-2":{"10.0.0.0/8":"3.3.3.3"}}]'
$dynamicTargets = Get-ReachabilityTargets -MaximumTargets 1 -ContentFetcher {
    param($uri)
    if ($uri -match 'prefixes-ipv4.json') { return $fixtureJson }
    return '<div data-source="prefixes-ipv4.json"></div>'
}
Assert-Equal $dynamicTargets.SourceUri 'http://ec2-reachability.amazonaws.com/prefixes-ipv4.json' 'Reachability page follows declared JSON data source'
Assert-Equal $dynamicTargets.Targets['us-west-2'][0] '3.3.3.3' 'Reachability JSON data source parsing'
$fallbackTargets = Get-ReachabilityTargets -MaximumTargets 2 -ContentFetcher { throw 'fixture outage' }
Assert-Equal $fallbackTargets.Source 'BuiltInCache' 'Reachability fallback path'
Assert-True ($fallbackTargets.FallbackReason -match 'fixture outage') 'Fallback reason is recorded'

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
$tcpSuccess = Invoke-TcpProbe -Region 'test' -HostName '127.0.0.1' -Port $port -TimeoutMs 1000
$listener.Stop()
Assert-True $tcpSuccess.Success 'TCP reachable path'
$tcpFailure = Invoke-TcpProbe -Region 'test' -HostName '127.0.0.1' -Port $port -TimeoutMs 500
Assert-True (-not $tcpFailure.Success) 'TCP failure path'

$tlsFailure = Invoke-TlsProbe -Region 'test' -HostName 'does-not-exist.invalid' -TimeoutMs 500
Assert-True (-not $tlsFailure.Success) 'TLS failure path is captured'
$trace = Invoke-TraceRoute -Region 'test' -Target '127.0.0.1' -HopLimit 2 -HopTimeoutMs 200
Assert-True ($null -ne $trace.Output -and $trace.PSObject.Properties.Name -contains 'Success') 'tracert diagnostic path returns structured data'

$fast = New-RegionFixture 'us-west-2' @(70, 72, 74, 76) 0 @(80, 82, 84) 0 @(90, 92) 0
$middle = New-RegionFixture 'us-east-1' @(100, 105, 110, 115) 0 @(115, 120, 125) 0 @(130, 135) 0
$slow = New-RegionFixture 'us-east-2' @(160, 180, 210, 240) 1 @(180, 210) 1 @(220) 1
$ranked = Add-RegionScores @($fast, $middle, $slow)
Assert-Equal $ranked[0].Region 'us-west-2' 'Region score ordering'
Assert-True ($ranked[0].Score -gt $ranked[1].Score) 'Region score separates leader'
Assert-Equal $slow.Health 'Degraded' 'Health hard gate detects degraded Region'
$recommendation = Get-Recommendation $ranked
Assert-Equal $recommendation.Region 'us-west-2' 'Recommendation chooses eligible leader'
Assert-True ($recommendation.Confidence -in @('High', 'Medium')) 'Confidence for clear healthy leader'

$nearA = New-RegionFixture 'us-east-1' @(100, 101, 102) 0 @(110, 111) 0 @(120) 0
$nearB = New-RegionFixture 'us-east-2' @(100, 101, 103) 0 @(110, 112) 0 @(121) 0
$nearC = New-RegionFixture 'us-west-2' @(180, 190, 200) 0 @(200, 210) 0 @(220) 0
$nearRanked = Add-RegionScores @($nearA, $nearB, $nearC)
$nearRecommendation = Get-Recommendation $nearRanked
Assert-True (-not $nearRecommendation.Decisive -and $nearRecommendation.Confidence -eq 'Low') 'Near tie yields no decisive winner'

$zero = New-RegionFixture 'us-east-1' @() 3 @() 2 @() 1
$zero2 = New-RegionFixture 'us-east-2' @() 3 @() 2 @() 1
$zero3 = New-RegionFixture 'us-west-2' @() 3 @() 2 @() 1
$allFailed = Add-RegionScores @($zero, $zero2, $zero3)
$noRecommendation = Get-Recommendation $allFailed
Assert-Equal $noRecommendation.Region $null 'All-target failure emits no recommendation'
Assert-True (($allFailed | Where-Object Health -eq 'NoData').Count -eq 3) 'All-target failure health state'

$reportFixture = [pscustomobject][ordered]@{
    SchemaVersion = '1.0'; Environment = [pscustomobject]@{ PowerShellVersion = $PSVersionTable.PSVersion.ToString() }
    TargetDiscovery = $fallbackTargets; Rankings = $ranked; Recommendation = $recommendation
    RawSamples = [pscustomobject]@{ Icmp = @(); Tcp443 = @(); Tls = @() }
}
$parsedJson = $reportFixture | ConvertTo-Json -Depth 12 | ConvertFrom-Json
Assert-Equal $parsedJson.SchemaVersion '1.0' 'JSON schema version is parseable'
Assert-True ($null -ne $parsedJson.TargetDiscovery -and $null -ne $parsedJson.RawSamples -and $parsedJson.Rankings.Count -eq 3) 'JSON required top-level content'

Assert-True (Test-IPv4Literal '203.0.113.9') 'TargetIp accepts IPv4 literal'
Assert-True (-not (Test-IPv4Literal '2001:db8::1') -and -not (Test-IPv4Literal '999.1.1.1')) 'TargetIp rejects IPv6 and invalid input'
Assert-True (Test-IPv4InCidr '10.1.255.255' '10.1.0.0/16') 'IPv4 CIDR includes upper address'
Assert-True (-not (Test-IPv4InCidr '10.2.0.0' '10.1.0.0/16')) 'IPv4 CIDR excludes adjacent range'
$rangeFixture = @(
    [pscustomobject]@{ ip_prefix='10.0.0.0/8'; region='us-east-1'; service='AMAZON'; network_border_group='us-east-1' },
    [pscustomobject]@{ ip_prefix='10.1.0.0/16'; region='us-west-2'; service='EC2'; network_border_group='us-west-2' },
    [pscustomobject]@{ ip_prefix='10.1.0.0/16'; region='us-east-2'; service='AMAZON'; network_border_group='us-east-2' }
)
$longest = Find-AwsIpPrefix '10.1.2.3' $rangeFixture
Assert-Equal $longest.Prefix '10.1.0.0/16' 'AWS CIDR selects longest prefix'
Assert-Equal $longest.Region 'us-west-2' 'Equal-prefix diagnostic prefers EC2 metadata'
Assert-Equal (Find-AwsIpPrefix '192.0.2.1' $rangeFixture) $null 'Unknown AWS IP is not guessed'
$manual = Resolve-AwsIpRegion '192.0.2.1' 'us-west-2' { throw 'must not fetch' }
Assert-Equal $manual.Source 'ManualOverride' 'Region override bypasses online fetch'
$fetchFailed = $false
try { Resolve-AwsIpRegion '192.0.2.1' $null { throw 'fixture outage' } | Out-Null } catch { $fetchFailed = $_.Exception.Message -match 'AWS_IP_RANGES_FETCH_FAILED' }
Assert-True $fetchFailed 'ip-ranges fetch failure has explicit error code'
$unknownFailed = $false
try { Resolve-AwsIpRegion '192.0.2.1' $null { '{"prefixes":[]}' } | Out-Null } catch { $unknownFailed = $_.Exception.Message -match 'AWS_IP_NOT_RECOGNIZED' }
Assert-True $unknownFailed 'Unknown IP has explicit no-guess error'

$testDataRoot = Join-Path $root '.tmp\tests-history'
if (Test-Path -LiteralPath $testDataRoot) { Remove-Item -LiteralPath $testDataRoot -Recurse -Force }
[void](New-Item -ItemType Directory -Path $testDataRoot -Force)
$historyPath = Join-Path $testDataRoot 'baseline-history.json'
$now = [datetime]'2026-09-14T00:00:00Z'
$emptyRead = Read-HistoryStore -Path $historyPath -NowUtc $now
Assert-Equal $emptyRead.Store.BaselineRuns.Count 0 'History first read creates empty in-memory schema'
$historyStore = New-HistoryStore
for ($i=0; $i -lt 60; $i++) {
    $timestamp = $now.AddHours(-$i).ToString('o')
    $historyStore.BaselineRuns += [pscustomobject]@{ TimestampUtc=$timestamp; Mode='Quick'; Scope='AllRegions'; Regions=@([pscustomobject]@{Region='us-west-2';P50Ms=100+$i;P95Ms=110+$i;LossPct=0;JitterMs=2;Health='Good';Score=80}) }
}
for ($i=0; $i -lt 110; $i++) { $historyStore.RealValidations += [pscustomobject]@{TimestampUtc=$now.AddHours(-$i).ToString('o')} }
$writeInfo = Write-HistoryStore -Store $historyStore -Path $historyPath -NowUtc $now
$stored = (Read-HistoryStore -Path $historyPath -NowUtc $now).Store
Assert-Equal $stored.BaselineRuns.Count 50 'History retains at most 50 Baseline runs'
Assert-Equal $stored.RealValidations.Count 100 'History retains at most 100 Real validations'
Assert-True ($writeInfo.Atomic -and (Test-Path -LiteralPath $historyPath)) 'History initial write is validated and atomic'
$stored.UpdatedAtUtc = $now.AddMinutes(1).ToString('o')
$replaceInfo = Write-HistoryStore -Store $stored -Path $historyPath -NowUtc $now.AddMinutes(1)
Assert-True ($replaceInfo.Atomic -and (Test-Path -LiteralPath "$historyPath.bak")) 'History existing write uses atomic replacement with backup'
[IO.File]::WriteAllText($historyPath, '{broken', (New-Object Text.UTF8Encoding($false)))
$recovered = Read-HistoryStore -Path $historyPath -NowUtc $now
Assert-Equal $recovered.Recovery.Action 'QuarantinedAndRebuilt' 'Corrupt history is quarantined and rebuilt'
Assert-True (Test-Path -LiteralPath $recovered.Recovery.CorruptPath) 'Corrupt history quarantine is recoverable'

$lookupStore = New-HistoryStore
$lookupStore.BaselineRuns = @(
    [pscustomobject]@{TimestampUtc=$now.AddHours(1).ToString('o');Mode='Quick';Scope='Future';Regions=@([pscustomobject]@{Region='us-west-2';P50Ms=1})},
    [pscustomobject]@{TimestampUtc=$now.AddHours(-5).ToString('o');Mode='Standard';Scope='AllRegions';Regions=@([pscustomobject]@{Region='us-west-2';P50Ms=100})},
    [pscustomobject]@{TimestampUtc=$now.AddHours(-2).ToString('o');Mode='Quick';Scope='SingleRegionRefresh';Regions=@([pscustomobject]@{Region='us-west-2';P50Ms=90})}
)
$nearest = Get-BaselineReference $lookupStore 'us-west-2' $now
Assert-Equal $nearest.Metrics.P50Ms 90 'Nearest prior same-Region Baseline selected'
Assert-Equal (Get-BaselineReference $lookupStore 'us-east-1' $now).Status 'Missing' 'Baseline Missing status'
$lookupStore.BaselineRuns[1].TimestampUtc = $now.AddHours(-6).ToString('o')
Assert-Equal (Get-BaselineReference $lookupStore 'us-west-2' $now).Status 'Fresh' 'Baseline Fresh boundary'
$lookupStore.BaselineRuns = @([pscustomobject]@{TimestampUtc=$now.AddHours(-7).ToString('o');Mode='x';Scope='x';Regions=@([pscustomobject]@{Region='us-west-2'})})
Assert-Equal (Get-BaselineReference $lookupStore 'us-west-2' $now).Status 'Usable' 'Baseline Usable status'
$lookupStore.BaselineRuns[0].TimestampUtc = $now.AddHours(-25).ToString('o')
Assert-Equal (Get-BaselineReference $lookupStore 'us-west-2' $now).Status 'Stale' 'Baseline Stale status'

$baselineMetrics = [pscustomobject]@{P50Ms=100;P95Ms=120;LossPct=0;JitterMs=4}
$healthyIcmp = Get-SampleStatistics (New-Samples @(105,108,110,112) 0)
$healthyTcp = Get-SampleStatistics (New-Samples @(90,92,94,96,98,100,102,104,106,108) 0)
$baselineRef = [pscustomobject]@{Status='Fresh';Metrics=$baselineMetrics}
$goodComparison = Get-RealComparison $baselineMetrics $healthyIcmp
Assert-Equal (@($goodComparison.Metrics | Where-Object Metric -eq 'P50 RTT')[0]).AbsoluteDelta 9 'Baseline-vs-real absolute delta'
Assert-Equal (@($goodComparison.Metrics | Where-Object Metric -eq 'P50 RTT')[0]).PercentageDelta 9 'Baseline-vs-real percentage delta'
$keep = Get-RealValidationAssessment $baselineRef $healthyIcmp $healthyTcp $goodComparison
Assert-Equal $keep.Recommendation 'KEEP' 'Verdict KEEP path'
$blockedIcmp = Get-SampleStatistics (New-Samples @() 10)
$blockedComparison = Get-RealComparison $baselineMetrics $blockedIcmp
$icmpBlocked = Get-RealValidationAssessment $baselineRef $blockedIcmp $healthyTcp $blockedComparison
Assert-True ($icmpBlocked.Recommendation -eq 'RETEST' -and $icmpBlocked.InstanceFit -eq 'INCONCLUSIVE') 'ICMP blocked plus TCP healthy is inconclusive, not Critical'
$partialTcp = Get-SampleStatistics (New-Samples @(90,100,110) 1)
$borderlineIcmp = Get-SampleStatistics (New-Samples @(125,128,130,135) 0)
$borderline = Get-RealValidationAssessment $baselineRef $borderlineIcmp $partialTcp (Get-RealComparison $baselineMetrics $borderlineIcmp)
Assert-Equal $borderline.Recommendation 'RETEST' 'Verdict RETEST path with partial TCP/moderate latency'
$poorIcmp = Get-SampleStatistics (New-Samples @(190,200,210,220) 2)
$failedTcp = Get-SampleStatistics (New-Samples @() 8)
$poor = Get-RealValidationAssessment $baselineRef $poorIcmp $failedTcp (Get-RealComparison $baselineMetrics $poorIcmp)
Assert-True ($poor.RetryCandidate -and $poor.InstanceFit -eq 'POOR') 'Verdict RETRY candidate uses multiple poor signals'
$confirmed = Resolve-ConfirmationVerdict $poor $poor
Assert-Equal $confirmed.Recommendation 'RETRY' 'RETRY requires two poor rounds'
$conflict = Resolve-ConfirmationVerdict $poor $keep
Assert-True ($conflict.Recommendation -eq 'RETEST' -and $conflict.InstanceFit -eq 'INCONCLUSIVE') 'Conflicting confirmation becomes RETEST/INCONCLUSIVE'
$noEvidenceTcp = Get-SampleStatistics (New-Samples @() 8)
$missingRef = [pscustomobject]@{Status='Missing';Metrics=$null}
$noEvidence = Get-RealValidationAssessment $missingRef $blockedIcmp $noEvidenceTcp (Get-RealComparison $null $blockedIcmp)
Assert-True (-not $noEvidence.EvidenceComplete) 'All evidence unavailable is insufficient'

$realFixture = [pscustomobject][ordered]@{ SchemaVersion='1.1'; Operation='RealIpValidation'; Target=[pscustomobject]@{Ip='192.0.2.1';Region='us-west-2';ProbePort=22}; RegionDetection=$manual; BaselineReference=$baselineRef; RealMetrics=[pscustomobject]@{Icmp=$healthyIcmp;Tcp=$healthyTcp}; Comparison=$goodComparison; Verdict=$keep; RawSamples=[pscustomobject]@{Icmp=@();Tcp=@()} }
$realParsed = $realFixture | ConvertTo-Json -Depth 14 | ConvertFrom-Json
Assert-True ($realParsed.SchemaVersion -eq '1.1' -and $realParsed.Operation -eq 'RealIpValidation' -and $null -ne $realParsed.Verdict) 'Real JSON schema is parseable'

$savedHistoryPath = $script:HistoryPath
$script:HistoryPath = Join-Path $testDataRoot 'integration-history.json'
$script:CapturedRefreshRegion = $null
$baselineRefresher = {
    param($onlyRegion)
    $script:CapturedRefreshRegion = $onlyRegion
    $storeForRefresh = New-HistoryStore
    $storeForRefresh.BaselineRuns = @([pscustomobject]@{
        TimestampUtc=[datetime]::UtcNow.ToString('o');Mode='Quick';Scope='SingleRegionRefresh'
        Regions=@([pscustomobject]@{Region=$onlyRegion;P50Ms=100;P95Ms=120;LossPct=0;JitterMs=4;Health='Good';Score=80})
    })
    $null = Write-HistoryStore -Store $storeForRefresh -Path $script:HistoryPath
}
$probeRunner = {
    param($ip,$resolvedRegion,$probePort,$icmpN,$tcpN,$pingMs,$connectMs,$roundMs,$skipTrace)
    $icmpValues = @(1..$icmpN | ForEach-Object { 105 + ($_ % 4) })
    $tcpValues = @(1..$tcpN | ForEach-Object { 90 + $_ })
    [pscustomobject][ordered]@{
        Icmp=Get-SampleStatistics (New-Samples $icmpValues 0)
        Tcp=Get-SampleStatistics (New-Samples $tcpValues 0)
        Traceroute=[pscustomobject]@{Region=$resolvedRegion;Target=$ip;Skipped=$true;Success=$false;Output=@();Error=$null}
        RawSamples=[pscustomobject]@{Icmp=@();Tcp=@()}
    }
}
$integrated = Invoke-RealIpValidation -Address '192.0.2.10' -Port 22 -RegionOverride 'us-west-2' -SelectedMode 'Quick' -IcmpCount 3 -TcpCount 2 -IcmpTimeout 250 -ConnectTimeout 500 -DelayMs 100 -TargetLimit 1 -JsonPath $null -WriteJson $false -CachedTargetsOnly $true -OmitTraceroute $true -ConfirmationDelaySeconds 1 -BaselineRefresher $baselineRefresher -ProbeRunner $probeRunner
Assert-Equal $script:CapturedRefreshRegion 'us-west-2' 'Missing Baseline auto-refresh requests only target Region'
Assert-True ($integrated.BaselineRefresh.Required -and $integrated.BaselineRefresh.Succeeded -and $integrated.BaselineReference.Status -eq 'Fresh') 'Missing Baseline refresh is selected and recorded'
Assert-True ($integrated.Verdict.Recommendation -eq 'KEEP' -and $integrated.RegionDetection.Source -eq 'ManualOverride') 'Injected Real workflow produces deterministic KEEP'
$historyAfterReal = (Read-HistoryStore -Path $script:HistoryPath).Store
Assert-True ($historyAfterReal.BaselineRuns.Count -eq 1 -and $historyAfterReal.RealValidations.Count -eq 1) 'Real workflow persists bounded aggregate history'
Assert-True ($historyAfterReal.RealValidations[0].PSObject.Properties.Name -notcontains 'RawSamples') 'History omits full raw samples'

$staleStore = New-HistoryStore
$staleStore.BaselineRuns = @([pscustomobject]@{TimestampUtc=[datetime]::UtcNow.AddHours(-25).ToString('o');Mode='Standard';Scope='AllRegions';Regions=@([pscustomobject]@{Region='us-west-2';P50Ms=150;P95Ms=170;LossPct=1;JitterMs=8;Health='Fair';Score=65})})
$null = Write-HistoryStore -Store $staleStore -Path $script:HistoryPath
$script:CapturedRefreshRegion = $null
$staleIntegrated = Invoke-RealIpValidation -Address '192.0.2.11' -Port 22 -RegionOverride 'us-west-2' -SelectedMode 'Quick' -IcmpCount 3 -TcpCount 2 -IcmpTimeout 250 -ConnectTimeout 500 -DelayMs 100 -TargetLimit 1 -JsonPath $null -WriteJson $false -CachedTargetsOnly $true -OmitTraceroute $true -ConfirmationDelaySeconds 1 -BaselineRefresher $baselineRefresher -ProbeRunner $probeRunner
Assert-True ($staleIntegrated.BaselineRefresh.Required -and $script:CapturedRefreshRegion -eq 'us-west-2' -and $staleIntegrated.BaselineReference.Status -eq 'Fresh') 'Stale Baseline auto-refreshes only target Region'

$script:PoorRoundCount = 0
$poorRunner = {
    param($ip,$resolvedRegion,$probePort,$icmpN,$tcpN,$pingMs,$connectMs,$roundMs,$skipTrace)
    $script:PoorRoundCount++
    [pscustomobject][ordered]@{
        Icmp=(Get-SampleStatistics (New-Samples @(200,210,220) 2))
        Tcp=(Get-SampleStatistics (New-Samples @() 4))
        Traceroute=[pscustomobject]@{Region=$resolvedRegion;Target=$ip;Skipped=$true;Success=$false;Output=@();Error=$null}
        RawSamples=[pscustomobject]@{Icmp=@();Tcp=@()}
    }
}
$retryIntegrated = Invoke-RealIpValidation -Address '192.0.2.12' -Port 22 -RegionOverride 'us-west-2' -SelectedMode 'Quick' -IcmpCount 3 -TcpCount 2 -IcmpTimeout 250 -ConnectTimeout 500 -DelayMs 100 -TargetLimit 1 -JsonPath $null -WriteJson $false -CachedTargetsOnly $true -OmitTraceroute $true -ConfirmationDelaySeconds 1 -BaselineRefresher $baselineRefresher -ProbeRunner $poorRunner
Assert-True ($script:PoorRoundCount -eq 2 -and $null -ne $retryIntegrated.Confirmation) 'RETRY candidate runs exactly one delayed shortened confirmation'
Assert-True ($retryIntegrated.Verdict.Recommendation -eq 'RETRY' -and $retryIntegrated.Verdict.InstanceFit -eq 'POOR') 'Two poor integrated rounds finalize RETRY/POOR'
$script:HistoryPath = $savedHistoryPath

Remove-Item -LiteralPath $testDataRoot -Recurse -Force

$source = Get-Content -LiteralPath $scriptPath -Raw
Assert-True ($source -match "ValidateRange\(0, 60\)" -and $source -match "ValidateRange\(100, 5000\)") 'Probe count and delay have hard safety bounds'
Assert-True ($source -notmatch 'ForEach-Object\s+-Parallel' -and $source -notmatch 'while\s*\(\s*\$true') 'No parallel or unbounded probe loop'

$readmeEn = Get-Content -LiteralPath (Join-Path $root 'README.md') -Raw -Encoding UTF8
$readmeZh = Get-Content -LiteralPath (Join-Path $root 'README.zh-CN.md') -Raw -Encoding UTF8
$documentedParameters = @('TargetIp', 'ProbePort', 'Region', 'RetryDelaySeconds', 'Mode', 'IcmpSamplesPerRegion', 'TcpAttempts', 'TlsAttempts', 'PingTimeoutMs', 'ConnectionTimeoutMs', 'RoundDelayMs', 'MaxTargetsPerRegion', 'OutputPath', 'NoJson', 'UseCachedTargets', 'SkipTraceroute')
foreach ($parameterName in $documentedParameters) {
    Assert-True ($readmeEn -match [regex]::Escape("-$parameterName") -and $readmeZh -match [regex]::Escape("-$parameterName")) "README parameter parity: $parameterName"
}
Assert-True ($readmeEn -match 'README\.zh-CN\.md' -and $readmeZh -match '\[English\]\(README\.md\)') 'README language switch links'
Assert-True ($readmeEn -match 'AWS US Region Network Test' -and $readmeZh -match 'AWS US Region Network Test' -and $source -match "AWS US Region Network Test") 'README example matches CLI heading'
Assert-True ($readmeEn -match 'Region Score and Confidence' -and $readmeZh -match 'Region Score' -and $readmeZh -match 'Confidence' -and $readmeEn -match 'JSON report' -and $readmeZh -match '## JSON') 'README required scoring and JSON sections'
$license = Get-Content -LiteralPath (Join-Path $root 'LICENSE') -Raw
Assert-True ($license -match 'MIT License' -and $license -match 'Copyright \(c\) 2026 sqin') 'MIT License identity'

Write-Host ''
Write-Host ("RESULT passed={0} failed={1}" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0
