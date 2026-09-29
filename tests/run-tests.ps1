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

function Invoke-CliProcess {
    param([string]$Arguments)
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = (Get-Process -Id $PID).Path
    $info.Arguments = ('-NoProfile -File "{0}" {1}' -f $scriptPath,$Arguments)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = ($stdout + $stderr) }
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
Assert-True ($help -match 'TARGET ' -and $help -match 'LISTTARGETS' -and $help -match 'IcmpSamplesPerRegion' -and $help -match 'UseCachedTargets' -and $help -match 'SkipTraceroute' -and $help -match 'Real IP Validation') 'Comment-based help exposes V2 parameters and mode semantics'
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

Assert-Equal @((Get-RegionCatalog)).Count 19 'Catalog contains 19 Lightsail Regions'
Assert-Equal @((Get-RegionCatalog | Select-Object -ExpandProperty Code -Unique)).Count 19 'Catalog Region codes are unique'
Assert-True (@(Get-RegionCatalog | Where-Object { -not $_.LightsailSupported -or [string]::IsNullOrWhiteSpace($_.CatalogSource) -or [string]::IsNullOrWhiteSpace($_.CatalogUpdatedAt) }).Count -eq 0) 'Catalog metadata is complete'
Assert-True ($script:RegionGroups.Count -eq 5 -and $script:RegionGroups['us-all'].Count -eq 3 -and $script:RegionGroups['americas-all'].Count -eq 5 -and $script:RegionGroups['eu-all'].Count -eq 6 -and $script:RegionGroups['apac-all'].Count -eq 8 -and $script:RegionGroups['global'].Count -eq 19) 'Built-in Region groups expand to frozen counts'
$normalizedSelection = Resolve-RegionSelection ' AP-EAST-1, ap-southeast-1,AP-EAST-1 '
Assert-True ($normalizedSelection.Kind -eq 'CustomSet' -and ($normalizedSelection.Regions -join ',') -eq 'ap-east-1,ap-southeast-1') 'Custom target trims normalizes and deduplicates in first-seen order'
Assert-True ((Resolve-RegionSelection 'US-ALL').Regions -join ',' -eq 'us-east-1,us-east-2,us-west-2') 'Group selector is case-insensitive'
$invalidTargetRejected = $false
try { $null = Resolve-RegionSelection 'ap-east-1,us-west-1' } catch { $invalidTargetRejected = $_.Exception.Message -match 'Invalid Target token' }
Assert-True $invalidTargetRejected 'Non-Lightsail/invalid Region is rejected before probing'
$smallPlan = Get-ProbePlan @('us-east-1','us-east-2','us-west-2') 'Auto'
$globalPlan = Get-ProbePlan $script:RegionOrder 'Auto'
Assert-True ($smallPlan.Strategy -eq 'SingleStage' -and $smallPlan.FinalValidation.Profile -eq 'Standard') 'Auto planner uses Standard for 1-6 Regions'
Assert-True ($globalPlan.Strategy -eq 'TwoStage' -and $globalPlan.Screening.Profile -eq 'Quick' -and $globalPlan.FinalValidation.Profile -eq 'Standard' -and $globalPlan.FinalistLimit -eq 5) 'Auto planner uses Quick then up to five Standard finalists for 7+ Regions'
Assert-True ((Get-ProbePlan $script:RegionOrder 'Thorough').Strategy -eq 'SingleStage') 'Explicit Thorough applies to entire selected set'
$menuInputs = New-Object 'System.Collections.Generic.Queue[string]'
@('2','?','US-ALL') | ForEach-Object { $menuInputs.Enqueue($_) }
$menuRequest = Read-InteractiveRequest -InputProvider { param($prompt) $menuInputs.Dequeue() }
Assert-True ($menuRequest.Action -eq 'RegionProbe' -and $menuRequest.Target -eq 'US-ALL') 'Interactive targeted route supports catalog help and validated selection'
$quitInputs = New-Object 'System.Collections.Generic.Queue[string]'; $quitInputs.Enqueue('q')
Assert-Equal (Read-InteractiveRequest -InputProvider { param($prompt) $quitInputs.Dequeue() }).Action 'Quit' 'Interactive Q safely exits'

$knownInputs = New-Object 'System.Collections.Generic.Queue[string]'
@('3','10.1.2.3') | ForEach-Object { $knownInputs.Enqueue($_) }
$knownPrompts = New-Object 'System.Collections.Generic.List[string]'
$knownInteractive = Read-InteractiveRequest -InputProvider { param($prompt) $knownPrompts.Add($prompt); $knownInputs.Dequeue() } -RegionResolver {
    param($address)
    [pscustomobject][ordered]@{ Source='AWS ip-ranges.json';SourceUri='fixture://ip-ranges';RetrievedAtUtc=[datetime]::UtcNow.ToString('o');Address=$address;Region='us-west-2';NetworkBorderGroup='us-west-2';Service='EC2';Prefix='10.1.0.0/16';PrefixLength=16 }
}
Assert-True (($knownPrompts -join ',') -eq 'Select,Target IPv4') 'Known interactive Real path prompts only for Target IPv4'
Assert-True ($knownInteractive.RegionDetection.Region -eq 'us-west-2' -and $knownInteractive.RegionDetection.Source -eq 'AWS ip-ranges.json') 'Known interactive Real path preserves automatic Region detection'
Assert-Equal $knownInteractive.ProbePort 22 'Known interactive Real path silently defaults to TCP/22'

$fallbackInputs = New-Object 'System.Collections.Generic.Queue[string]'
@('3','192.0.2.20','us-west-2') | ForEach-Object { $fallbackInputs.Enqueue($_) }
$fallbackPrompts = New-Object 'System.Collections.Generic.List[string]'
$fallbackInteractive = Read-InteractiveRequest -InputProvider { param($prompt) $fallbackPrompts.Add($prompt); $fallbackInputs.Dequeue() } -RegionResolver { throw 'AWS_IP_NOT_RECOGNIZED: fixture unknown address.' }
Assert-True (($fallbackPrompts -join ',') -eq 'Select,Target IPv4,Region override') 'Unknown interactive Real path prompts once for Region override only after detection failure'
Assert-True ($fallbackInteractive.Region -eq 'us-west-2' -and $fallbackInteractive.RegionDetection.Source -eq 'ManualOverride') 'Interactive fallback preserves explicit Region override semantics'
Assert-Equal $fallbackInteractive.ProbePort 22 'Interactive fallback silently defaults to TCP/22'

$fetchFailureInputs = New-Object 'System.Collections.Generic.Queue[string]'
@('3','192.0.2.23','eu-west-1') | ForEach-Object { $fetchFailureInputs.Enqueue($_) }
$fetchFailurePrompts = New-Object 'System.Collections.Generic.List[string]'
$fetchFailureInteractive = Read-InteractiveRequest -InputProvider { param($prompt) $fetchFailurePrompts.Add($prompt); $fetchFailureInputs.Dequeue() } -RegionResolver { throw 'AWS_IP_RANGES_FETCH_FAILED: fixture feed outage.' }
Assert-True (($fetchFailurePrompts -join ',') -eq 'Select,Target IPv4,Region override' -and $fetchFailureInteractive.Region -eq 'eu-west-1') 'Interactive fetch failure requests one Region override and continues safely'

$emptyOverrideInputs = New-Object 'System.Collections.Generic.Queue[string]'
@('3','192.0.2.21','') | ForEach-Object { $emptyOverrideInputs.Enqueue($_) }
$emptyOverrideRejected = $false
try { $null = Read-InteractiveRequest -InputProvider { param($prompt) $emptyOverrideInputs.Dequeue() } -RegionResolver { throw 'AWS_IP_NOT_RECOGNIZED: fixture unknown address.' } } catch { $emptyOverrideRejected = $_.Exception.Message -match 'REGION_OVERRIDE_REQUIRED' }
Assert-True $emptyOverrideRejected 'Interactive fallback rejects an empty Region override without guessing'

$invalidOverrideInputs = New-Object 'System.Collections.Generic.Queue[string]'
@('3','192.0.2.22','us-west-1') | ForEach-Object { $invalidOverrideInputs.Enqueue($_) }
$invalidOverrideRejected = $false
try { $null = Read-InteractiveRequest -InputProvider { param($prompt) $invalidOverrideInputs.Dequeue() } -RegionResolver { throw 'AWS_IP_NOT_RECOGNIZED: fixture unknown address.' } } catch { $invalidOverrideRejected = $_.Exception.Message -match 'Unsupported Lightsail Region override' }
Assert-True $invalidOverrideRejected 'Interactive fallback rejects an unsupported Region override'

$fixtureHtml = @'
<table>
<tr><td>us-east-1</td><td>10.0.0.0/8</td><td>1.1.1.1</td><td>1.1.1.2</td></tr>
<tr><td>us-east-2</td><td>10.0.0.0/8</td><td>2.2.2.2</td></tr>
<tr><td>us-west-2</td><td>10.0.0.0/8</td><td>3.3.3.3</td></tr>
</table>
'@
$onlineTargets = Get-ReachabilityTargets -MaximumTargets 2 -ContentFetcher { $fixtureHtml }
Assert-Equal $onlineTargets.Source 'AWSReachabilityPageWithPerRegionFallback' 'Reachability online parsing path'
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
$partialTargets = Get-ReachabilityTargets -Regions @('us-east-1','ap-east-1') -MaximumTargets 1 -ContentFetcher { $fixtureHtml }
Assert-True ($partialTargets.Targets['us-east-1'].Count -eq 1 -and $partialTargets.Targets['ap-east-1'].Count -eq 0 -and $partialTargets.Failures['ap-east-1'] -match 'no verified cache') 'Per-Region target failure is isolated and not fabricated'
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
    SchemaVersion = '2.0'; Environment = [pscustomobject]@{ PowerShellVersion = $PSVersionTable.PSVersion.ToString() }
    TargetDiscovery = $fallbackTargets; Rankings = $ranked; Recommendation = $recommendation
    RawSamples = [pscustomobject]@{ Icmp = @(); Tcp443 = @(); Tls = @() }
}
$parsedJson = $reportFixture | ConvertTo-Json -Depth 12 | ConvertFrom-Json
Assert-Equal $parsedJson.SchemaVersion '2.0' 'JSON schema version is parseable'
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

$testDataRoot = Join-Path $root ('.tmp\tests-history-{0}' -f [guid]::NewGuid().ToString('N'))
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

$realFixture = [pscustomobject][ordered]@{ SchemaVersion='2.0'; Operation='RealIpValidation'; Target=[pscustomobject]@{Ip='192.0.2.1';Region='us-west-2';ProbePort=22}; RegionDetection=$manual; BaselineReference=$baselineRef; RealMetrics=[pscustomobject]@{Icmp=$healthyIcmp;Tcp=$healthyTcp}; Comparison=$goodComparison; Verdict=$keep; RealValidation=[pscustomobject]@{Verdict=$keep}; RawSamples=[pscustomobject]@{Icmp=@();Tcp=@()} }
$realParsed = $realFixture | ConvertTo-Json -Depth 14 | ConvertFrom-Json
Assert-True ($realParsed.SchemaVersion -eq '2.0' -and $realParsed.Operation -eq 'RealIpValidation' -and $null -ne $realParsed.RealValidation.Verdict) 'Real JSON schema is parseable'

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

$autoInteractiveIntegrated = Invoke-RealIpValidation -Address '10.1.2.3' -Port $knownInteractive.ProbePort -RegionOverride $null -RegionResolution $knownInteractive.RegionDetection -SelectedMode 'Quick' -IcmpCount 3 -TcpCount 2 -IcmpTimeout 250 -ConnectTimeout 500 -DelayMs 100 -TargetLimit 1 -JsonPath $null -WriteJson $false -CachedTargetsOnly $true -OmitTraceroute $true -ConfirmationDelaySeconds 1 -IpRangesFetcher { throw 'Automatic interactive Region must not be fetched twice.' } -BaselineRefresher $baselineRefresher -ProbeRunner $probeRunner
Assert-True ($autoInteractiveIntegrated.RegionDetection.Source -eq 'AWS ip-ranges.json' -and $autoInteractiveIntegrated.Target.Region -eq 'us-west-2') 'Interactive automatic Region resolution is reused without provenance loss'
Assert-Equal $autoInteractiveIntegrated.Target.ProbePort 22 'Integrated interactive Real workflow uses silent default TCP/22'

$script:CapturedProbePort = $null
$portProbeRunner = {
    param($ip,$resolvedRegion,$probePort,$icmpN,$tcpN,$pingMs,$connectMs,$roundMs,$skipTrace)
    $script:CapturedProbePort = $probePort
    [pscustomobject][ordered]@{
        Icmp=Get-SampleStatistics (New-Samples @(105,107,109) 0)
        Tcp=Get-SampleStatistics (New-Samples @(90,92) 0)
        Traceroute=[pscustomobject]@{Region=$resolvedRegion;Target=$ip;Skipped=$true;Success=$false;Output=@();Error=$null}
        RawSamples=[pscustomobject]@{Icmp=@();Tcp=@()}
    }
}
$explicitPortIntegrated = Invoke-RealIpValidation -Address '192.0.2.13' -Port 443 -RegionOverride 'us-west-2' -SelectedMode 'Quick' -IcmpCount 3 -TcpCount 2 -IcmpTimeout 250 -ConnectTimeout 500 -DelayMs 100 -TargetLimit 1 -JsonPath $null -WriteJson $false -CachedTargetsOnly $true -OmitTraceroute $true -ConfirmationDelaySeconds 1 -BaselineRefresher $baselineRefresher -ProbeRunner $portProbeRunner
Assert-True ($script:CapturedProbePort -eq 443 -and $explicitPortIntegrated.Target.ProbePort -eq 443) 'Explicit Real ProbePort remains effective'

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
Assert-True ($retryIntegrated.SchemaVersion -eq '2.0' -and $null -ne $retryIntegrated.RealValidation -and $retryIntegrated.BaselineRefresh.Reason -eq 'QuickOnlyBaseline') 'Real workflow emits schema 2.0 and refreshes Quick-only baseline quality'
$script:HistoryPath = $savedHistoryPath

$v1History = [pscustomobject][ordered]@{ SchemaVersion='1.0'; UpdatedAtUtc=[datetime]::UtcNow.ToString('o'); BaselineRuns=@([pscustomobject][ordered]@{TimestampUtc=[datetime]::UtcNow.ToString('o');Mode='Standard';Scope='AllRegions';Regions=@()});RealValidations=@() }
$migratedHistory = ConvertTo-HistorySchema2 $v1History
Assert-True ($migratedHistory.Migrated -and $migratedHistory.Store.SchemaVersion -eq '2.0' -and $migratedHistory.Store.BaselineRuns[0].ProbeProfile -eq 'Standard' -and $migratedHistory.Store.BaselineRuns[0].Stage -eq 'FinalValidation') 'History 1.0 lazily migrates to schema 2.0 with quality metadata'

$mockTargets = {
    param($regions,$limit,$cachedOnly)
    $targets = [ordered]@{}; $failures = [ordered]@{}; $octet = 10
    foreach ($candidateRegion in $regions) {
        if ($candidateRegion -eq 'ap-northeast-1') { $targets[$candidateRegion] = @(); $failures[$candidateRegion] = 'Mock unavailable target.' }
        else { $targets[$candidateRegion] = @("192.0.2.$octet"); $octet++ }
    }
    [pscustomobject][ordered]@{ Source='DeterministicMock';SourceUri='mock://targets';RetrievedAtUtc=[datetime]::UtcNow.ToString('o');CacheUpdated=$null;FallbackReason=$null;Targets=$targets;Failures=$failures }
}
$mockProbe = {
    param($kind,$probeRegion,$probeTarget,$timeout)
    $index = [array]::IndexOf($script:RegionOrder,$probeRegion)
    $duration = [double](20 + ($index * 7) + $(if ($kind -eq 'Tcp') { 3 } elseif ($kind -eq 'Tls') { 6 } else { 0 }))
    [pscustomobject][ordered]@{ Region=$probeRegion;Target=$probeTarget;Host=$probeTarget;TimestampUtc=[datetime]::UtcNow.ToString('o');Success=$true;DurationMs=$duration;Status='MockSuccess';Error=$null }
}
$autoRegions = @($script:RegionOrder | Select-Object -First 7)
$autoReport = Invoke-AwsRegionSelection -SelectedMode 'Auto' -IcmpCount 3 -TcpCount 1 -TlsCount 1 -IcmpTimeout 250 -ConnectTimeout 500 -DelayMs 100 -TargetLimit 1 -JsonPath $null -WriteJson $false -CachedTargetsOnly $false -OmitTraceroute $true -SelectedRegions $autoRegions -Scope 'CustomSet' -RecordHistory $false -Selection ($autoRegions -join ',') -TargetDiscoveryProvider $mockTargets -ProbeProvider $mockProbe
Assert-True ($autoReport.SchemaVersion -eq '2.0' -and $autoReport.Operation -eq 'RegionProbe' -and $autoReport.ProbePlan.Strategy -eq 'TwoStage' -and $autoReport.ProbePlan.Screening.Icmp -eq 3 -and $autoReport.ProbePlan.FinalValidation.Tcp -eq 1) 'Integrated Global Auto report uses JSON schema 2.0 and records effective two-stage plan'
Assert-True (@($autoReport.Screening.Rankings).Count -eq 7 -and @($autoReport.Screening.Rankings | Where-Object ProbeStatus -eq 'Unavailable').Count -eq 1) 'Unavailable Region remains in complete screening evidence'
Assert-True (@($autoReport.FinalValidation.Rankings).Count -eq 5 -and @($autoReport.Recommendation.TopRegions).Count -le 3) 'Auto promotes at most five finalists and recommends at most three'
Assert-True ($null -ne $autoReport.Screening.Rankings[0].PSObject.Properties['ScreeningRank'] -and $null -ne $autoReport.FinalValidation.Rankings[0].PSObject.Properties['FinalistRank']) 'Screening and finalist rank semantics remain separate'
Assert-True ($null -ne $autoReport.RawSamples.Screening -and $null -ne $autoReport.RawSamples.FinalValidation -and $autoReport.Warnings.Count -eq 1) 'Schema 2.0 retains stage raw samples and explicit warnings'

$targetedRegions = @($script:RegionOrder | Select-Object -First 3)
$targetedReport = Invoke-AwsRegionSelection -SelectedMode 'Standard' -IcmpCount 3 -TcpCount 1 -TlsCount 1 -IcmpTimeout 250 -ConnectTimeout 500 -DelayMs 100 -TargetLimit 1 -JsonPath $null -WriteJson $false -CachedTargetsOnly $false -OmitTraceroute $true -SelectedRegions $targetedRegions -Scope 'Group:us-all' -RecordHistory $false -Selection 'us-all' -TargetDiscoveryProvider $mockTargets -ProbeProvider $mockProbe
Assert-True ($targetedReport.Operation -eq 'RegionProbe' -and $targetedReport.ProbePlan.Strategy -eq 'SingleStage' -and @($targetedReport.FinalValidation.Rankings).Count -eq 3) 'Integrated Targeted Standard workflow remains unchanged'

$cliInvalid = Invoke-CliProcess '-Target us-west-1 -NoJson'
Assert-Equal $cliInvalid.ExitCode 2 'CLI rejects invalid Target before network operations'
$cliConflict = Invoke-CliProcess '-Target us-all -TargetIp 192.0.2.1 -NoJson'
Assert-Equal $cliConflict.ExitCode 2 'CLI rejects Target and TargetIp conflict before network operations'
$cliRegion = Invoke-CliProcess '-Region us-west-2 -NoJson'
Assert-Equal $cliRegion.ExitCode 2 'CLI rejects Region override outside Real mode'
$cliTargetIpInvalid = Invoke-CliProcess '-TargetIp not-an-ip -NoJson'
Assert-True ($cliTargetIpInvalid.ExitCode -eq 2 -and $cliTargetIpInvalid.Output -notmatch 'Region override|Probe port') 'Direct TargetIp CLI remains non-interactive'
$cliList = Invoke-CliProcess '-ListTargets -NoJson'
Assert-True ($cliList.ExitCode -eq 0 -and $cliList.Output -match 'ap-southeast-5' -and $cliList.Output -match 'global:') 'ListTargets is network-free and exposes full catalog/groups'

Remove-Item -LiteralPath $testDataRoot -Recurse -Force

$source = Get-Content -LiteralPath $scriptPath -Raw
$oldPromptPattern = 'Region override ' + [char]40 + 'optional' + [char]41
Assert-True ($source -notmatch [regex]::Escape($oldPromptPattern) -and $source -notmatch [regex]::Escape('Probe port [22]')) 'Obsolete interactive Region and Probe Port prompts are removed'
Assert-Equal $script:ToolVersion '2.0.1' 'Tool version is v2.0.1'
Assert-Equal $ProbePort 22 'Default CLI ProbePort remains TCP/22'
Assert-True ($source -match "ValidateRange\(0, 60\)" -and $source -match "ValidateRange\(100, 5000\)") 'Probe count and delay have hard safety bounds'
Assert-True ($source -notmatch 'ForEach-Object\s+-Parallel' -and $source -notmatch 'Start-ThreadJob|Start-Job') 'No parallel probe fan-out'

$readmeEn = Get-Content -LiteralPath (Join-Path $root 'README.md') -Raw -Encoding UTF8
$readmeZh = Get-Content -LiteralPath (Join-Path $root 'README.zh-CN.md') -Raw -Encoding UTF8
$documentedParameters = @('Target', 'ListTargets', 'TargetIp', 'ProbePort', 'Region', 'RetryDelaySeconds', 'Mode', 'IcmpSamplesPerRegion', 'TcpAttempts', 'TlsAttempts', 'PingTimeoutMs', 'ConnectionTimeoutMs', 'RoundDelayMs', 'MaxTargetsPerRegion', 'OutputPath', 'NoJson', 'UseCachedTargets', 'SkipTraceroute')
foreach ($parameterName in $documentedParameters) {
    Assert-True ($readmeEn -match [regex]::Escape("-$parameterName") -and $readmeZh -match [regex]::Escape("-$parameterName")) "README parameter parity: $parameterName"
}
Assert-True ($readmeEn -match 'README\.zh-CN\.md' -and $readmeZh -match '\[English\]\(README\.md\)') 'README language switch links'
Assert-True ($readmeEn -match 'AWS Lightsail Region Selection' -and $readmeZh -match 'AWS Lightsail Region Selection' -and $source -match "AWS Lightsail Region Selection") 'README example matches CLI heading'
Assert-True ($readmeEn -match 'Region Score' -and $readmeEn -match 'Confidence' -and $readmeZh -match 'Region Score' -and $readmeZh -match 'Confidence' -and $readmeEn -match 'JSON report' -and $readmeZh -match 'JSON') 'README required scoring and JSON sections'
Assert-True ($readmeEn -match 'Schema 2\.0' -and $readmeZh -match 'Schema 2\.0' -and $readmeEn -match 'us-all' -and $readmeZh -match 'us-all' -and $readmeEn -match 'Quick-only' -and $readmeZh -match 'Quick evidence') 'README V2 schema groups and baseline-quality parity'
$changelog = Get-Content -LiteralPath (Join-Path $root 'CHANGELOG.md') -Raw -Encoding UTF8
$workflow = Get-Content -LiteralPath (Join-Path $root '.github\workflows\test.yml') -Raw -Encoding UTF8
Assert-True ($changelog -match '\[2\.0\.1\].*2026-09-29' -and $changelog -match 'Interactive Real IP Validation' -and $changelog -match '\[2\.0\.0\].*2026-09-28' -and $changelog -match 'Schema 2\.0') 'CHANGELOG records v2.0.1 patch and v2.0 compatibility history'
Assert-True ($workflow -match 'windows-latest' -and $workflow -match 'shell: powershell' -and $workflow -match 'shell: pwsh' -and $workflow -notmatch 'Target global|TargetIp') 'CI covers both runtimes without live probes'
$license = Get-Content -LiteralPath (Join-Path $root 'LICENSE') -Raw
Assert-True ($license -match 'MIT License' -and $license -match 'Copyright \(c\) 2026 sqin') 'MIT License identity'

Write-Host ''
Write-Host ("RESULT passed={0} failed={1}" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0
