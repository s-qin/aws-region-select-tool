#requires -Version 5.1
<#
.SYNOPSIS
Measures network quality from the current PC to three AWS US Regions.

.DESCRIPTION
Runs low-rate, interleaved ICMP probes against AWS EC2 Reachability targets,
then measures TCP 443 and TLS handshake performance against Regional AWS API
endpoints. Traceroute is collected for diagnostics but is never scored. The
script ranks us-east-1, us-east-2, and us-west-2 and writes a JSON report.

.PARAMETER Mode
Quick, Standard (default), or Thorough sampling preset.

.PARAMETER IcmpSamplesPerRegion
Overrides the preset ICMP sample count per Region (3-60).

.PARAMETER TcpAttempts
Overrides TCP 443 attempts per Region (1-15).

.PARAMETER TlsAttempts
Overrides TLS handshake attempts per Region (1-8).

.PARAMETER PingTimeoutMs
Timeout for each ICMP probe in milliseconds.

.PARAMETER ConnectionTimeoutMs
Timeout for TCP connect and TLS handshake operations in milliseconds.

.PARAMETER RoundDelayMs
Pause after each interleaved ICMP round. Minimum 100 ms protects shared targets.

.PARAMETER MaxTargetsPerRegion
Maximum Reachability targets used per Region (1-3).

.PARAMETER OutputPath
JSON report path. By default a timestamped file is created in the current directory.

.PARAMETER NoJson
Do not write a JSON report.

.PARAMETER UseCachedTargets
Skip online target discovery and use the targets bundled with this script.

.PARAMETER SkipTraceroute
Skip the one diagnostic tracert run per Region.

.EXAMPLE
.\aws-region-select-tool.ps1

.EXAMPLE
.\aws-region-select-tool.ps1 -Mode Quick -UseCachedTargets -SkipTraceroute

.OUTPUTS
Console ranking and, unless -NoJson is used, a JSON report.

.NOTES
Exit 0: recommendation produced. Exit 2: invalid/runtime error.
Exit 3: insufficient evidence for a safe recommendation.
#>
[CmdletBinding()]
param(
    [ValidateSet('Quick', 'Standard', 'Thorough')]
    [string]$Mode = 'Standard',

    [ValidateRange(0, 60)]
    [int]$IcmpSamplesPerRegion = 0,

    [ValidateRange(1, 15)]
    [int]$TcpAttempts = 0,

    [ValidateRange(1, 8)]
    [int]$TlsAttempts = 0,

    [ValidateRange(250, 5000)]
    [int]$PingTimeoutMs = 1200,

    [ValidateRange(500, 10000)]
    [int]$ConnectionTimeoutMs = 3000,

    [ValidateRange(100, 5000)]
    [int]$RoundDelayMs = 250,

    [ValidateRange(1, 3)]
    [int]$MaxTargetsPerRegion = 3,

    [string]$OutputPath,

    [switch]$NoJson,
    [switch]$UseCachedTargets,
    [switch]$SkipTraceroute
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ToolVersion = '1.0.0'
$script:ReachabilityUri = 'http://ec2-reachability.amazonaws.com/'
$script:CachedTargetUpdated = '2026-09-13'
$script:RegionOrder = @('us-east-1', 'us-east-2', 'us-west-2')
$script:RegionMetadata = [ordered]@{
    'us-east-1' = [ordered]@{
        Name = 'US East (N. Virginia)'
        Endpoint = 'ec2.us-east-1.amazonaws.com'
        CachedTargets = @('23.23.255.255', '34.192.0.54', '34.224.0.252')
    }
    'us-east-2' = [ordered]@{
        Name = 'US East (Ohio)'
        Endpoint = 'ec2.us-east-2.amazonaws.com'
        CachedTargets = @('3.13.0.254', '13.58.0.253', '52.15.55.0')
    }
    'us-west-2' = [ordered]@{
        Name = 'US West (Oregon)'
        Endpoint = 'ec2.us-west-2.amazonaws.com'
        CachedTargets = @('18.246.28.254', '34.208.63.251', '35.95.2.254')
    }
}

function New-OrderedObject {
    param([hashtable]$Properties)
    return [pscustomobject]$Properties
}

function Get-ExceptionDetail {
    param([System.Exception]$Exception)
    $baseException = $Exception.GetBaseException()
    return [pscustomobject][ordered]@{
        Type = $baseException.GetType().FullName
        Message = $baseException.Message
    }
}

function Limit-Number {
    param([double]$Value, [double]$Minimum = 0.0, [double]$Maximum = 100.0)
    if ($Value -lt $Minimum) { return $Minimum }
    if ($Value -gt $Maximum) { return $Maximum }
    return $Value
}

function Get-Percentile {
    param(
        [double[]]$Values,
        [ValidateRange(0, 100)][double]$Percentile
    )
    if ($null -eq $Values -or $Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 1) { return [double]$sorted[0] }
    $rank = ($Percentile / 100.0) * ($sorted.Count - 1)
    $lower = [math]::Floor($rank)
    $upper = [math]::Ceiling($rank)
    if ($lower -eq $upper) { return [double]$sorted[$lower] }
    $fraction = $rank - $lower
    return [double]$sorted[$lower] + (($sorted[$upper] - $sorted[$lower]) * $fraction)
}

function Get-SampleStatistics {
    param(
        [object[]]$Samples,
        [string]$ValueProperty = 'DurationMs'
    )
    $all = @($Samples)
    $successful = @($all | Where-Object { $_.Success -and $null -ne $_.$ValueProperty })
    $values = @($successful | ForEach-Object { [double]$_.$ValueProperty })
    $sent = $all.Count
    $received = $successful.Count
    $loss = if ($sent -gt 0) { (($sent - $received) / [double]$sent) * 100.0 } else { 100.0 }

    if ($values.Count -eq 0) {
        return [pscustomobject][ordered]@{
            Sent = $sent; Received = 0; SuccessRatePct = 0.0; LossPct = [math]::Round($loss, 2)
            MinMs = $null; AverageMs = $null; P50Ms = $null; P95Ms = $null
            MaxMs = $null; JitterMs = $null; TimeoutCount = $sent
        }
    }

    $average = ($values | Measure-Object -Average).Average
    $variance = 0.0
    foreach ($value in $values) { $variance += [math]::Pow(($value - $average), 2) }
    $jitter = [math]::Sqrt($variance / $values.Count)

    return [pscustomobject][ordered]@{
        Sent = $sent
        Received = $received
        SuccessRatePct = [math]::Round(($received / [double]$sent) * 100.0, 2)
        LossPct = [math]::Round($loss, 2)
        MinMs = [math]::Round(($values | Measure-Object -Minimum).Minimum, 2)
        AverageMs = [math]::Round($average, 2)
        P50Ms = [math]::Round((Get-Percentile -Values $values -Percentile 50), 2)
        P95Ms = [math]::Round((Get-Percentile -Values $values -Percentile 95), 2)
        MaxMs = [math]::Round(($values | Measure-Object -Maximum).Maximum, 2)
        JitterMs = [math]::Round($jitter, 2)
        TimeoutCount = $sent - $received
    }
}

function Test-IPv4Literal {
    param([string]$Value)
    $address = $null
    if (-not [System.Net.IPAddress]::TryParse($Value, [ref]$address)) { return $false }
    return $address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
}

function Get-CachedTargetResult {
    param([int]$MaximumTargets = 3, [string]$Reason)
    $targets = [ordered]@{}
    foreach ($region in $script:RegionOrder) {
        $targets[$region] = @($script:RegionMetadata[$region].CachedTargets | Select-Object -First $MaximumTargets)
    }
    return [pscustomobject][ordered]@{
        Source = 'BuiltInCache'
        SourceUri = $script:ReachabilityUri
        RetrievedAtUtc = $null
        CacheUpdated = $script:CachedTargetUpdated
        FallbackReason = $Reason
        Targets = $targets
    }
}

function Get-ReachabilityTargets {
    param(
        [switch]$CachedOnly,
        [ValidateRange(1, 3)][int]$MaximumTargets = 3,
        [scriptblock]$ContentFetcher
    )
    if ($CachedOnly) { return Get-CachedTargetResult -MaximumTargets $MaximumTargets -Reason 'Requested by -UseCachedTargets.' }

    try {
        $effectiveSourceUri = $script:ReachabilityUri
        if ($null -ne $ContentFetcher) {
            $content = & $ContentFetcher $script:ReachabilityUri
        }
        else {
            $response = Invoke-WebRequest -Uri $script:ReachabilityUri -UseBasicParsing -TimeoutSec 12
            $content = $response.Content
        }

        if ([string]::IsNullOrWhiteSpace([string]$content)) { throw 'Reachability page returned empty content.' }
        $dataSourceMatch = [regex]::Match([string]$content, 'data-source=["''](?<path>[^"'']+)["'']', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($dataSourceMatch.Success) {
            $effectiveSourceUri = (New-Object System.Uri((New-Object System.Uri($script:ReachabilityUri)), $dataSourceMatch.Groups['path'].Value)).AbsoluteUri
            if ($null -ne $ContentFetcher) {
                $content = & $ContentFetcher $effectiveSourceUri
            }
            else {
                $response = Invoke-WebRequest -Uri $effectiveSourceUri -UseBasicParsing -TimeoutSec 12
                $content = $response.Content
            }
        }

        $targets = [ordered]@{}
        $trimmedContent = ([string]$content).TrimStart()
        if ($trimmedContent.StartsWith('[') -or $trimmedContent.StartsWith('{')) {
            $jsonData = $content | ConvertFrom-Json
            foreach ($region in $script:RegionOrder) {
                $found = New-Object System.Collections.Generic.List[string]
                foreach ($entry in @($jsonData)) {
                    $regionProperty = $entry.PSObject.Properties[$region]
                    if ($null -eq $regionProperty) { continue }
                    foreach ($targetProperty in $regionProperty.Value.PSObject.Properties) {
                        $candidate = [string]$targetProperty.Value
                        if ((Test-IPv4Literal $candidate) -and -not $found.Contains($candidate)) { $found.Add($candidate) }
                    }
                }
                if ($found.Count -eq 0) { throw "No valid target parsed for $region." }
                $targets[$region] = @($found | Select-Object -First $MaximumTargets)
            }
        }
        else {
            foreach ($region in $script:RegionOrder) {
                $found = New-Object System.Collections.Generic.List[string]
                $rowPattern = '(?is)<tr[^>]*>(?:(?!</tr>).)*' + [regex]::Escape($region) + '(?:(?!</tr>).)*</tr>'
                foreach ($rowMatch in [regex]::Matches([string]$content, $rowPattern)) {
                    foreach ($ipMatch in [regex]::Matches($rowMatch.Value, '(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])')) {
                        $candidate = $ipMatch.Value
                        $isPrefix = $rowMatch.Value -match ([regex]::Escape($candidate) + '\s*/\s*\d{1,2}')
                        if ((Test-IPv4Literal $candidate) -and -not $isPrefix -and -not $found.Contains($candidate)) { $found.Add($candidate) }
                    }
                }
                if ($found.Count -eq 0) { throw "No valid target parsed for $region." }
                $targets[$region] = @($found | Select-Object -First $MaximumTargets)
            }
        }

        return [pscustomobject][ordered]@{
            Source = 'AWSReachabilityPage'
            SourceUri = $effectiveSourceUri
            RetrievedAtUtc = [datetime]::UtcNow.ToString('o')
            CacheUpdated = $script:CachedTargetUpdated
            FallbackReason = $null
            Targets = $targets
        }
    }
    catch {
        $detail = Get-ExceptionDetail $_.Exception
        return Get-CachedTargetResult -MaximumTargets $MaximumTargets -Reason ("{0}: {1}" -f $detail.Type, $detail.Message)
    }
}

function Invoke-IcmpProbe {
    param([string]$Region, [string]$Target, [int]$TimeoutMs)
    $ping = New-Object System.Net.NetworkInformation.Ping
    try {
        $reply = $ping.Send($Target, $TimeoutMs)
        $success = $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success
        return [pscustomobject][ordered]@{
            Region = $Region; Target = $Target; TimestampUtc = [datetime]::UtcNow.ToString('o')
            Success = $success; DurationMs = $(if ($success) { [double]$reply.RoundtripTime } else { $null })
            Status = [string]$reply.Status; Error = $null
        }
    }
    catch {
        $detail = Get-ExceptionDetail $_.Exception
        return [pscustomobject][ordered]@{
            Region = $Region; Target = $Target; TimestampUtc = [datetime]::UtcNow.ToString('o')
            Success = $false; DurationMs = $null; Status = 'Error'; ErrorType = $detail.Type; Error = $detail.Message
        }
    }
    finally { $ping.Dispose() }
}

function Invoke-TcpProbe {
    param([string]$Region, [string]$HostName, [int]$Port = 443, [int]$TimeoutMs)
    $client = New-Object System.Net.Sockets.TcpClient
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $async = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { throw [System.TimeoutException]::new('TCP connect timed out.') }
        $client.EndConnect($async)
        $watch.Stop()
        return [pscustomobject][ordered]@{
            Region = $Region; Host = $HostName; Port = $Port; TimestampUtc = [datetime]::UtcNow.ToString('o')
            Success = $true; DurationMs = [math]::Round($watch.Elapsed.TotalMilliseconds, 2); Status = 'Connected'; Error = $null
        }
    }
    catch {
        $watch.Stop()
        $detail = Get-ExceptionDetail $_.Exception
        return [pscustomobject][ordered]@{
            Region = $Region; Host = $HostName; Port = $Port; TimestampUtc = [datetime]::UtcNow.ToString('o')
            Success = $false; DurationMs = $null; Status = $(if ($detail.Type -eq 'System.TimeoutException') { 'Timeout' } else { 'Error' }); ErrorType = $detail.Type; Error = $detail.Message
        }
    }
    finally { $client.Close() }
}

function Invoke-TlsProbe {
    param([string]$Region, [string]$HostName, [int]$TimeoutMs)
    $client = New-Object System.Net.Sockets.TcpClient
    $ssl = $null
    $watch = $null
    try {
        $connect = $client.BeginConnect($HostName, 443, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { throw [System.TimeoutException]::new('TLS prerequisite TCP connect timed out.') }
        $client.EndConnect($connect)
        $ssl = New-Object System.Net.Security.SslStream($client.GetStream(), $false)
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $task = $ssl.AuthenticateAsClientAsync($HostName)
        if (-not $task.Wait($TimeoutMs)) { throw [System.TimeoutException]::new('TLS handshake timed out.') }
        if ($task.IsFaulted) { throw $task.Exception.GetBaseException() }
        $watch.Stop()
        return [pscustomobject][ordered]@{
            Region = $Region; Host = $HostName; TimestampUtc = [datetime]::UtcNow.ToString('o')
            Success = $true; DurationMs = [math]::Round($watch.Elapsed.TotalMilliseconds, 2)
            Protocol = [string]$ssl.SslProtocol; CipherAlgorithm = [string]$ssl.CipherAlgorithm
            Status = 'Authenticated'; Error = $null
        }
    }
    catch {
        if ($null -ne $watch) { $watch.Stop() }
        $detail = Get-ExceptionDetail $_.Exception
        return [pscustomobject][ordered]@{
            Region = $Region; Host = $HostName; TimestampUtc = [datetime]::UtcNow.ToString('o')
            Success = $false; DurationMs = $null; Protocol = $null; CipherAlgorithm = $null
            Status = $(if ($detail.Type -eq 'System.TimeoutException') { 'Timeout' } else { 'Error' }); ErrorType = $detail.Type; Error = $detail.Message
        }
    }
    finally {
        if ($null -ne $ssl) { $ssl.Dispose() }
        $client.Close()
    }
}

function Invoke-TraceRoute {
    param([string]$Region, [string]$Target, [int]$HopLimit = 20, [int]$HopTimeoutMs = 800)
    $process = $null
    $command = Get-Command tracert.exe -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return [pscustomobject][ordered]@{ Region = $Region; Target = $Target; Success = $false; ExitCode = $null; Output = @(); Error = 'tracert.exe is unavailable.' }
    }
    try {
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = $command.Source
        $info.Arguments = "-d -h $HopLimit -w $HopTimeoutMs $Target"
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $info
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $maximumRunMs = ($HopLimit * $HopTimeoutMs * 3) + 5000
        if (-not $process.WaitForExit($maximumRunMs)) {
            try { $process.Kill() } catch { }
            throw [System.TimeoutException]::new('tracert exceeded its bounded runtime.')
        }
        $output = $stdoutTask.Result
        $errorText = $stderrTask.Result
        return [pscustomobject][ordered]@{
            Region = $Region; Target = $Target; Success = ($process.ExitCode -eq 0); ExitCode = $process.ExitCode
            Output = @($output -split "`r?`n"); Error = $(if ([string]::IsNullOrWhiteSpace($errorText)) { $null } else { $errorText.Trim() })
        }
    }
    catch {
        return [pscustomobject][ordered]@{ Region = $Region; Target = $Target; Success = $false; ExitCode = $null; Output = @(); Error = $_.Exception.Message }
    }
    finally { if ($null -ne $process) { $process.Dispose() } }
}

function Get-RegionHealth {
    param([object]$Icmp, [object]$Tcp, [object]$Tls)
    if ($Icmp.Received -eq 0 -and $Tcp.Received -eq 0 -and $Tls.Received -eq 0) { return 'NoData' }
    if ($Tcp.SuccessRatePct -eq 0 -or ($Icmp.LossPct -ge 75 -and $Tls.SuccessRatePct -eq 0)) { return 'Critical' }
    if ($Icmp.LossPct -ge 10 -or $Tcp.SuccessRatePct -lt 75 -or $Tls.SuccessRatePct -lt 50) { return 'Degraded' }
    if ($Icmp.LossPct -ge 3 -or $Tcp.SuccessRatePct -lt 90 -or ($null -ne $Icmp.P50Ms -and $Icmp.P50Ms -gt 0 -and $Icmp.P95Ms -gt ($Icmp.P50Ms * 1.5))) { return 'Fair' }
    return 'Good'
}

function Get-AbsoluteMetricScore {
    param([string]$Metric, $Value)
    if ($null -eq $Value) { return 0.0 }
    switch ($Metric) {
        'P50' { return Limit-Number (100.0 - ([double]$Value / 3.0)) }
        'P95' { return Limit-Number (100.0 - ([double]$Value / 4.0)) }
        'Loss' { return Limit-Number (100.0 - ([double]$Value * 5.0)) }
        'Jitter' { return Limit-Number (100.0 - ([double]$Value * 4.0)) }
        'Tcp' { return Limit-Number ([double]$Value) }
        'Tls' { return Limit-Number ([double]$Value) }
    }
    return 0.0
}

function Get-RelativeMetricScores {
    param([object[]]$Regions, [scriptblock]$Selector, [switch]$HigherIsBetter)
    $values = [ordered]@{}
    foreach ($region in $Regions) {
        $value = & $Selector $region
        if ($null -ne $value) { $values[$region.Region] = [double]$value }
    }
    $output = [ordered]@{}
    if ($values.Count -eq 0) {
        foreach ($region in $Regions) { $output[$region.Region] = 0.0 }
        return $output
    }
    $minimum = ($values.Values | Measure-Object -Minimum).Minimum
    $maximum = ($values.Values | Measure-Object -Maximum).Maximum
    foreach ($region in $Regions) {
        if (-not $values.Contains($region.Region)) { $output[$region.Region] = 0.0; continue }
        if ($maximum -eq $minimum) { $output[$region.Region] = 75.0; continue }
        $raw = if ($HigherIsBetter) { (($values[$region.Region] - $minimum) / ($maximum - $minimum)) * 100.0 } else { (($maximum - $values[$region.Region]) / ($maximum - $minimum)) * 100.0 }
        $output[$region.Region] = $raw
    }
    return $output
}

function Add-RegionScores {
    param([object[]]$RegionResults)
    $relative = [ordered]@{
        P50 = Get-RelativeMetricScores $RegionResults { param($r) $r.Icmp.P50Ms }
        P95 = Get-RelativeMetricScores $RegionResults { param($r) $r.Icmp.P95Ms }
        Loss = Get-RelativeMetricScores $RegionResults { param($r) $r.Icmp.LossPct }
        Jitter = Get-RelativeMetricScores $RegionResults { param($r) $r.Icmp.JitterMs }
        Tcp = Get-RelativeMetricScores $RegionResults { param($r) $r.Tcp.QualityPct } -HigherIsBetter
        Tls = Get-RelativeMetricScores $RegionResults { param($r) $r.Tls.QualityPct } -HigherIsBetter
    }
    $weights = [ordered]@{ P50 = 0.30; P95 = 0.20; Loss = 0.20; Jitter = 0.10; Tcp = 0.15; Tls = 0.05 }
    foreach ($region in $RegionResults) {
        $metricValues = [ordered]@{
            P50 = $region.Icmp.P50Ms; P95 = $region.Icmp.P95Ms; Loss = $region.Icmp.LossPct; Jitter = $region.Icmp.JitterMs
            Tcp = $region.Tcp.QualityPct; Tls = $region.Tls.QualityPct
        }
        $components = [ordered]@{}
        $score = 0.0
        foreach ($metric in $weights.Keys) {
            $absolute = Get-AbsoluteMetricScore $metric $metricValues[$metric]
            $blended = (0.70 * $absolute) + (0.30 * $relative[$metric][$region.Region])
            $components[$metric] = [math]::Round($blended, 2)
            $score += $blended * $weights[$metric]
        }
        switch ($region.Health) {
            'Degraded' { $score = [math]::Min($score, 55.0) }
            'Critical' { $score = [math]::Min($score, 25.0) }
            'NoData' { $score = 0.0 }
        }
        $region.Score = [math]::Round((Limit-Number $score), 1)
        $region.ScoreComponents = [pscustomobject]$components
        $region.DataCompletenessPct = [math]::Round((0.50 * $region.Icmp.SuccessRatePct) + (0.30 * $region.Tcp.SuccessRatePct) + (0.20 * $region.Tls.SuccessRatePct), 1)
    }
    return @($RegionResults | Sort-Object -Property @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'Region'; Descending = $false })
}

function Get-Recommendation {
    param([object[]]$RankedRegions)
    $eligible = @($RankedRegions | Where-Object { $_.Health -in @('Good', 'Fair', 'Degraded') -and $_.Icmp.Received -gt 0 -and $_.Tcp.Received -gt 0 -and $_.Tls.Received -gt 0 })
    if ($eligible.Count -eq 0) {
        return [pscustomobject][ordered]@{ Region = $null; Name = $null; Confidence = 'Low'; Decisive = $false; Message = 'Insufficient evidence; no safe recommendation.'; ScoreMargin = $null }
    }
    $winner = $eligible[0]
    $runnerUp = if ($eligible.Count -gt 1) { $eligible[1] } else { $null }
    $margin = if ($null -ne $runnerUp) { [math]::Round(($winner.Score - $runnerUp.Score), 1) } else { $winner.Score }
    $decisive = $null -eq $runnerUp -or $margin -ge 5.0
    $confidence = 'Low'
    if ($decisive -and $winner.Health -eq 'Good' -and $winner.DataCompletenessPct -ge 85 -and $margin -ge 12) { $confidence = 'High' }
    elseif ($decisive -and $winner.Health -in @('Good', 'Fair') -and $winner.DataCompletenessPct -ge 65) { $confidence = 'Medium' }
    $message = if ($decisive) { 'Recommended from this run and network exit.' } else { 'No decisive winner; rerun later to confirm.' }
    return [pscustomobject][ordered]@{
        Region = $winner.Region; Name = $winner.Name; Confidence = $confidence; Decisive = $decisive
        Message = $message; ScoreMargin = $margin
    }
}

function Get-ModeDefaults {
    param([string]$SelectedMode)
    switch ($SelectedMode) {
        'Quick' { return [pscustomobject]@{ Icmp = 9; Tcp = 3; Tls = 2 } }
        'Thorough' { return [pscustomobject]@{ Icmp = 45; Tcp = 10; Tls = 5 } }
        default { return [pscustomobject]@{ Icmp = 36; Tcp = 8; Tls = 4 } }
    }
}

function Get-TcpOrTlsQuality {
    param([object]$Statistics)
    $latencyScore = if ($null -eq $Statistics.P50Ms) { 0.0 } else { Limit-Number (100.0 - ($Statistics.P50Ms / 3.0)) }
    return [math]::Round((0.70 * $Statistics.SuccessRatePct) + (0.30 * $latencyScore), 2)
}

function Write-Ranking {
    param([object[]]$Ranked, [object]$Recommendation, [object]$TargetInfo)
    Write-Host ''
    Write-Host 'AWS US Region Network Test'
    Write-Host 'Source: Current PC / Current Network Exit'
    Write-Host ("Target Source: {0}" -f $TargetInfo.Source)
    Write-Host ''
    $rank = 0
    $table = foreach ($region in $Ranked) {
        $rank++
        [pscustomobject][ordered]@{
            Rank = $rank; Region = $region.Region
            P50 = $(if ($null -eq $region.Icmp.P50Ms) { '-' } else { "{0}ms" -f $region.Icmp.P50Ms })
            P95 = $(if ($null -eq $region.Icmp.P95Ms) { '-' } else { "{0}ms" -f $region.Icmp.P95Ms })
            Loss = ("{0}%" -f $region.Icmp.LossPct)
            Jitter = $(if ($null -eq $region.Icmp.JitterMs) { '-' } else { "{0}ms" -f $region.Icmp.JitterMs })
            TCP = ("{0}%" -f $region.Tcp.SuccessRatePct); Health = $region.Health; Score = $region.Score
        }
    }
    $table | Format-Table -AutoSize | Out-Host
    if ($null -ne $Recommendation.Region) {
        Write-Host ("Recommended Region: {0} ({1})" -f $Recommendation.Region, $Recommendation.Name)
    }
    else { Write-Host 'Recommended Region: None' }
    Write-Host ("Confidence: {0}" -f $Recommendation.Confidence)
    Write-Host $Recommendation.Message
    foreach ($region in $Ranked) {
        Write-Host ''
        Write-Host $region.Region
        Write-Host ("- ICMP: {0}/{1}, loss {2}%" -f $region.Icmp.Received, $region.Icmp.Sent, $region.Icmp.LossPct)
        Write-Host ("- TCP 443: {0}/{1}, P50 {2} ms" -f $region.Tcp.Received, $region.Tcp.Sent, $region.Tcp.P50Ms)
        Write-Host ("- TLS: {0}/{1}, P50 {2} ms" -f $region.Tls.Received, $region.Tls.Sent, $region.Tls.P50Ms)
        Write-Host ("- Route: {0}" -f $(if ($region.Traceroute.Skipped) { 'Skipped' } elseif ($region.Traceroute.Success) { 'Captured (diagnostic only)' } else { 'Unavailable/failed (diagnostic only)' }))
    }
}

function Invoke-AwsRegionSelection {
    [CmdletBinding()]
    param(
        [string]$SelectedMode, [int]$IcmpCount, [int]$TcpCount, [int]$TlsCount,
        [int]$IcmpTimeout, [int]$ConnectTimeout, [int]$DelayMs, [int]$TargetLimit,
        [string]$JsonPath, [bool]$WriteJson, [bool]$CachedTargetsOnly, [bool]$OmitTraceroute
    )
    $started = [datetime]::UtcNow
    if ($IcmpCount -in @(1, 2)) { throw 'IcmpSamplesPerRegion must be 0 (preset) or between 3 and 60.' }
    $defaults = Get-ModeDefaults $SelectedMode
    if ($IcmpCount -eq 0) { $IcmpCount = $defaults.Icmp }
    if ($TcpCount -eq 0) { $TcpCount = $defaults.Tcp }
    if ($TlsCount -eq 0) { $TlsCount = $defaults.Tls }

    Write-Host ("Loading AWS Reachability targets ({0} mode)..." -f $SelectedMode)
    $targetInfo = Get-ReachabilityTargets -CachedOnly:$CachedTargetsOnly -MaximumTargets $TargetLimit
    if ($targetInfo.Source -eq 'BuiltInCache') { Write-Warning ("Using built-in cached targets: {0}" -f $targetInfo.FallbackReason) }

    $icmpSamples = New-Object System.Collections.Generic.List[object]
    Write-Host ("Running {0} interleaved ICMP samples per Region..." -f $IcmpCount)
    for ($round = 0; $round -lt $IcmpCount; $round++) {
        $regionsThisRound = @($script:RegionOrder | Sort-Object { Get-Random })
        foreach ($region in $regionsThisRound) {
            $regionTargets = @($targetInfo.Targets[$region])
            $target = $regionTargets[$round % $regionTargets.Count]
            $icmpSamples.Add((Invoke-IcmpProbe -Region $region -Target $target -TimeoutMs $IcmpTimeout))
        }
        if ($round -lt ($IcmpCount - 1)) { Start-Sleep -Milliseconds $DelayMs }
    }

    $tcpSamples = New-Object System.Collections.Generic.List[object]
    Write-Host ("Running {0} TCP 443 attempts per Region..." -f $TcpCount)
    for ($round = 0; $round -lt $TcpCount; $round++) {
        foreach ($region in @($script:RegionOrder | Sort-Object { Get-Random })) {
            $tcpSamples.Add((Invoke-TcpProbe -Region $region -HostName $script:RegionMetadata[$region].Endpoint -TimeoutMs $ConnectTimeout))
        }
    }

    $tlsSamples = New-Object System.Collections.Generic.List[object]
    Write-Host ("Running {0} TLS handshake attempts per Region..." -f $TlsCount)
    for ($round = 0; $round -lt $TlsCount; $round++) {
        foreach ($region in @($script:RegionOrder | Sort-Object { Get-Random })) {
            $tlsSamples.Add((Invoke-TlsProbe -Region $region -HostName $script:RegionMetadata[$region].Endpoint -TimeoutMs $ConnectTimeout))
        }
    }

    $traces = [ordered]@{}
    foreach ($region in $script:RegionOrder) {
        if ($OmitTraceroute) {
            $traces[$region] = [pscustomobject][ordered]@{ Region = $region; Target = $targetInfo.Targets[$region][0]; Skipped = $true; Success = $false; ExitCode = $null; Output = @(); Error = $null }
        }
        else {
            Write-Host ("Capturing traceroute for {0}..." -f $region)
            $trace = Invoke-TraceRoute -Region $region -Target $targetInfo.Targets[$region][0]
            $trace | Add-Member -NotePropertyName Skipped -NotePropertyValue $false
            $traces[$region] = $trace
        }
    }

    $regionResults = New-Object System.Collections.Generic.List[object]
    foreach ($region in $script:RegionOrder) {
        $icmp = Get-SampleStatistics -Samples @($icmpSamples | Where-Object Region -eq $region)
        $tcp = Get-SampleStatistics -Samples @($tcpSamples | Where-Object Region -eq $region)
        $tls = Get-SampleStatistics -Samples @($tlsSamples | Where-Object Region -eq $region)
        $tcp | Add-Member -NotePropertyName QualityPct -NotePropertyValue (Get-TcpOrTlsQuality $tcp)
        $tls | Add-Member -NotePropertyName QualityPct -NotePropertyValue (Get-TcpOrTlsQuality $tls)
        $health = Get-RegionHealth -Icmp $icmp -Tcp $tcp -Tls $tls
        $regionResults.Add([pscustomobject][ordered]@{
            Region = $region; Name = $script:RegionMetadata[$region].Name; Endpoint = $script:RegionMetadata[$region].Endpoint
            Targets = @($targetInfo.Targets[$region]); Icmp = $icmp; Tcp = $tcp; Tls = $tls
            Health = $health; Score = 0.0; ScoreComponents = $null; DataCompletenessPct = 0.0
            Traceroute = $traces[$region]
        })
    }
    $ranked = Add-RegionScores -RegionResults @($regionResults | ForEach-Object { $_ })
    $recommendation = Get-Recommendation -RankedRegions $ranked
    Write-Ranking -Ranked $ranked -Recommendation $recommendation -TargetInfo $targetInfo

    $report = [pscustomobject][ordered]@{
        SchemaVersion = '1.0'
        Tool = [pscustomobject][ordered]@{ Name = 'AWS Region Select Tool'; Version = $script:ToolVersion }
        Test = [pscustomobject][ordered]@{
            StartedAtUtc = $started.ToString('o'); CompletedAtUtc = [datetime]::UtcNow.ToString('o')
            Source = 'Current PC / Current Network Exit'; CandidateRegions = $script:RegionOrder; Mode = $SelectedMode
            Settings = [pscustomobject][ordered]@{ IcmpSamplesPerRegion = $IcmpCount; TcpAttemptsPerRegion = $TcpCount; TlsAttemptsPerRegion = $TlsCount; PingTimeoutMs = $IcmpTimeout; ConnectionTimeoutMs = $ConnectTimeout; RoundDelayMs = $DelayMs; TracerouteSkipped = $OmitTraceroute }
        }
        Environment = [pscustomobject][ordered]@{
            ComputerName = $env:COMPUTERNAME; OSVersion = [System.Environment]::OSVersion.VersionString
            PowerShellVersion = $PSVersionTable.PSVersion.ToString(); PowerShellEdition = $(if ($PSVersionTable.ContainsKey('PSEdition')) { $PSVersionTable.PSEdition } else { 'Desktop' })
        }
        TargetDiscovery = $targetInfo
        Rankings = $ranked
        Recommendation = $recommendation
        RawSamples = [pscustomobject][ordered]@{
            Icmp = @($icmpSamples | ForEach-Object { $_ })
            Tcp443 = @($tcpSamples | ForEach-Object { $_ })
            Tls = @($tlsSamples | ForEach-Object { $_ })
        }
    }

    if ($WriteJson) {
        if ([string]::IsNullOrWhiteSpace($JsonPath)) { $JsonPath = Join-Path (Get-Location) ("aws-us-region-test_{0}.json" -f (Get-Date -Format 'yyyy-MM-dd_HHmmss')) }
        $parent = Split-Path -Parent $JsonPath
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
        $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $JsonPath -Encoding UTF8
        $resolved = (Resolve-Path -LiteralPath $JsonPath).Path
        Write-Host ''
        Write-Host ("JSON report: {0}" -f $resolved)
        $report | Add-Member -NotePropertyName ReportPath -NotePropertyValue $resolved
    }
    return $report
}

function Invoke-EntryPoint {
    try {
        $report = Invoke-AwsRegionSelection -SelectedMode $Mode -IcmpCount $IcmpSamplesPerRegion -TcpCount $TcpAttempts -TlsCount $TlsAttempts -IcmpTimeout $PingTimeoutMs -ConnectTimeout $ConnectionTimeoutMs -DelayMs $RoundDelayMs -TargetLimit $MaxTargetsPerRegion -JsonPath $OutputPath -WriteJson (-not $NoJson) -CachedTargetsOnly ([bool]$UseCachedTargets) -OmitTraceroute ([bool]$SkipTraceroute)
        if ($null -eq $report.Recommendation.Region) { return 3 }
        return 0
    }
    catch {
        Write-Error ("AWS Region Select Tool failed: {0}" -f $_.Exception.Message) -ErrorAction Continue
        return 2
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-EntryPoint)
}
