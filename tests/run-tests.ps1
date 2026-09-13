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
Assert-True ($help -match 'IcmpSamplesPerRegion' -and $help -match 'UseCachedTargets' -and $help -match 'SkipTraceroute') 'Comment-based help exposes key parameters'

Assert-Equal (Get-Percentile @(10, 20, 30, 40) 50) 25 'P50 interpolation'
Assert-Equal (Get-Percentile @(10, 20, 30, 40) 95) 38.5 'P95 interpolation'
$stats = Get-SampleStatistics (New-Samples @(10, 20, 30, 40) 1)
Assert-Equal $stats.Sent 5 'Statistics sent count'
Assert-Equal $stats.Received 4 'Statistics received count'
Assert-Equal $stats.LossPct 20 'Statistics packet loss'
Assert-Equal $stats.AverageMs 25 'Statistics average'
Assert-Equal $stats.JitterMs 11.18 'Statistics population standard deviation jitter'

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

$source = Get-Content -LiteralPath $scriptPath -Raw
Assert-True ($source -match "ValidateRange\(0, 60\)" -and $source -match "ValidateRange\(100, 5000\)") 'Probe count and delay have hard safety bounds'
Assert-True ($source -notmatch 'ForEach-Object\s+-Parallel' -and $source -notmatch 'while\s*\(\s*\$true') 'No parallel or unbounded probe loop'

Write-Host ''
Write-Host ("RESULT passed={0} failed={1}" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0
