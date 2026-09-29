<#
.SYNOPSIS
Ranks Amazon Lightsail Regions or validates a real AWS/Lightsail IPv4 address.

.DESCRIPTION
Without arguments, opens an interactive menu for a global Lightsail scan,
targeted Region scan, or Real IP Validation. Region Probe mode accepts a
single Region, built-in group, or comma-separated custom set. Auto mode uses
Standard probes for 1-6 Regions and Quick screening followed by Standard
validation of up to five finalists for 7 or more Regions. Probes are serial,
bounded, and use dynamically discovered AWS EC2 Reachability targets.

With -TargetIp, identifies the AWS Region (or uses -Region), compares the real
IP with quality-aware local baseline history, and validates ICMP/TCP stability.
Reports use JSON Schema 2.0. Traceroute is diagnostic and is never scored.

.PARAMETER Target
Region code, built-in group, or comma-separated custom Region set.

.PARAMETER ListTargets
Lists the controlled Lightsail Region catalog and built-in groups, then exits.

.PARAMETER TargetIp
IPv4 address to validate. Supplying it selects Real IP Validation mode.

.PARAMETER ProbePort
TCP port used for Real IP Validation. Default 22.

.PARAMETER Region
Manual Lightsail Region override for an unknown/BYOIP address or offline range lookup.

.PARAMETER RetryDelaySeconds
Delay before the one shortened confirmation run for a RETRY candidate.

.PARAMETER Mode
Auto (default), Quick, Standard, or Thorough sampling strategy.

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
Skip online target discovery. Regions without a verified bundled target are
reported unavailable; the script never fabricates fallback addresses.

.PARAMETER SkipTraceroute
Skip the one diagnostic tracert run per Region.

.EXAMPLE
.\aws-region-select-tool.ps1

.EXAMPLE
.\aws-region-select-tool.ps1 -Target global

.EXAMPLE
.\aws-region-select-tool.ps1 -Target us-all -Mode Standard

.EXAMPLE
.\aws-region-select-tool.ps1 -Target "ap-east-1,ap-southeast-1,ap-northeast-1"

.EXAMPLE
.\aws-region-select-tool.ps1 -ListTargets

.EXAMPLE
.\aws-region-select-tool.ps1 -TargetIp 203.0.113.10 -Region us-west-2 -ProbePort 22

.OUTPUTS
Console recommendation/evidence and, unless -NoJson is used, a JSON 2.0 report.

.NOTES
Exit 0: actionable result, listing, or safe quit. Exit 2: usage/runtime error.
Exit 3: insufficient evidence for a safe recommendation or verdict.
#>
#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Target,

    [switch]$ListTargets,

    [string]$TargetIp,

    [ValidateRange(1, 65535)]
    [int]$ProbePort = 22,

    [string]$Region,

    [ValidateRange(1, 60)]
    [int]$RetryDelaySeconds = 5,

    [ValidateSet('Auto', 'Quick', 'Standard', 'Thorough')]
    [string]$Mode = 'Auto',

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

$script:ToolVersion = '2.0.1'
$script:ReachabilityUri = 'http://ec2-reachability.amazonaws.com/'
$script:IpRangesUri = 'https://ip-ranges.amazonaws.com/ip-ranges.json'
$script:HistoryPath = Join-Path $PSScriptRoot '.data\baseline-history.json'
$script:CachedTargetUpdated = '2026-09-13'
$script:CatalogSource = 'https://docs.aws.amazon.com/lightsail/latest/userguide/understanding-regions-and-availability-zones-in-amazon-lightsail.html'
$script:CatalogUpdatedAt = '2026-09-27'
$script:RegionCatalog = @(
    @('us-east-1','N. Virginia','United States','Americas',$false), @('us-east-2','Ohio','United States','Americas',$false),
    @('us-west-2','Oregon','United States','Americas',$false), @('ca-central-1','Canada (Central)','Canada','Americas',$false),
    @('sa-east-1','Sao Paulo','Brazil','Americas',$false), @('ap-east-1','Hong Kong','Hong Kong','APAC',$true),
    @('ap-northeast-1','Tokyo','Japan','APAC',$false), @('ap-northeast-2','Seoul','South Korea','APAC',$false),
    @('ap-south-1','Mumbai','India','APAC',$false), @('ap-southeast-1','Singapore','Singapore','APAC',$false),
    @('ap-southeast-2','Sydney','Australia','APAC',$false), @('ap-southeast-3','Jakarta','Indonesia','APAC',$true),
    @('ap-southeast-5','Malaysia','Malaysia','APAC',$true), @('eu-central-1','Frankfurt','Germany','Europe',$false),
    @('eu-north-1','Stockholm','Sweden','Europe',$false), @('eu-south-2','Spain','Spain','Europe',$true),
    @('eu-west-1','Ireland','Ireland','Europe',$false), @('eu-west-2','London','United Kingdom','Europe',$false),
    @('eu-west-3','Paris','France','Europe',$false)
) | ForEach-Object {
    [pscustomobject][ordered]@{ Code = $_[0]; Location = $_[1]; CountryOrArea = $_[2]; Geography = $_[3]; LightsailSupported = $true; OptInRequired = [bool]$_[4]; CatalogSource = $script:CatalogSource; CatalogUpdatedAt = $script:CatalogUpdatedAt }
}
$script:RegionOrder = @($script:RegionCatalog | ForEach-Object { $_.Code })
$script:RegionMetadata = [ordered]@{}
foreach ($catalogRegion in $script:RegionCatalog) {
    $script:RegionMetadata[$catalogRegion.Code] = [ordered]@{
        Name = $catalogRegion.Location
        Endpoint = ('ec2.{0}.amazonaws.com' -f $catalogRegion.Code)
        Catalog = $catalogRegion
        CachedTargets = @()
    }
}
$script:RegionMetadata['us-east-1'].CachedTargets = @('23.23.255.255', '34.192.0.54', '34.224.0.252')
$script:RegionMetadata['us-east-2'].CachedTargets = @('3.13.0.254', '13.58.0.253', '52.15.55.0')
$script:RegionMetadata['us-west-2'].CachedTargets = @('18.246.28.254', '34.208.63.251', '35.95.2.254')
$script:RegionGroups = [ordered]@{
    'us-all' = @('us-east-1','us-east-2','us-west-2')
    'americas-all' = @('us-east-1','us-east-2','us-west-2','ca-central-1','sa-east-1')
    'eu-all' = @('eu-central-1','eu-north-1','eu-south-2','eu-west-1','eu-west-2','eu-west-3')
    'apac-all' = @('ap-east-1','ap-northeast-1','ap-northeast-2','ap-south-1','ap-southeast-1','ap-southeast-2','ap-southeast-3','ap-southeast-5')
    'global' = @($script:RegionOrder)
}

function New-OrderedObject {
    param([hashtable]$Properties)
    return [pscustomobject]$Properties
}

function Get-RegionCatalog {
    return @($script:RegionCatalog | ForEach-Object { $_ })
}

function Resolve-RegionSelection {
    param([Parameter(Mandatory = $true)][string]$Selection)
    if ([string]::IsNullOrWhiteSpace($Selection)) { throw 'Target cannot be empty.' }
    $normalized = $Selection.Trim().ToLowerInvariant()
    if ($script:RegionGroups.Contains($normalized)) {
        return [pscustomobject][ordered]@{ Input = $Selection; Normalized = $normalized; Kind = 'Group'; Group = $normalized; Regions = @($script:RegionGroups[$normalized]) }
    }
    $seen = [ordered]@{}
    foreach ($part in @($normalized -split ',')) {
        $token = $part.Trim()
        if ([string]::IsNullOrWhiteSpace($token)) { throw "Invalid Target '$Selection': empty Region token." }
        if ($token -notin $script:RegionOrder) { throw "Invalid Target token '$token'. Use -ListTargets to see supported Lightsail Regions and groups." }
        if (-not $seen.Contains($token)) { $seen[$token] = $true }
    }
    $regions = @($seen.Keys)
    $kind = if ($regions.Count -eq 1) { 'SingleRegion' } else { 'CustomSet' }
    return [pscustomobject][ordered]@{ Input = $Selection; Normalized = ($regions -join ','); Kind = $kind; Group = $null; Regions = $regions }
}

function Get-SelectionScope {
    param([object]$Selection)
    if ($Selection.Kind -eq 'Group') { return ('Group:{0}' -f $Selection.Group) }
    return $Selection.Kind
}

function Show-TargetCatalog {
    Write-Host 'Amazon Lightsail Region Catalog'
    Write-Host ("Source updated: {0}" -f $script:CatalogUpdatedAt)
    Get-RegionCatalog | Select-Object Code, Location, CountryOrArea, Geography, OptInRequired | Format-Table -AutoSize | Out-Host
    Write-Host 'Built-in groups'
    foreach ($name in $script:RegionGroups.Keys) { Write-Host ("- {0}: {1}" -f $name, ($script:RegionGroups[$name] -join ', ')) }
}

function Get-ProbePlan {
    param([Parameter(Mandatory = $true)][string[]]$SelectedRegions, [Parameter(Mandatory = $true)][string]$SelectedMode)
    $count = @($SelectedRegions).Count
    if ($count -lt 1) { throw 'At least one Region is required.' }
    if ($SelectedMode -eq 'Auto' -and $count -ge 7) {
        return [pscustomobject][ordered]@{
            Strategy = 'TwoStage'; RequestedMode = 'Auto'; RegionCount = $count; FinalistLimit = 5; RecommendationLimit = 3
            Screening = [pscustomobject][ordered]@{ Profile = 'Quick'; Regions = @($SelectedRegions); Icmp = 9; Tcp = 3; Tls = 2; Traceroute = $false }
            FinalValidation = [pscustomobject][ordered]@{ Profile = 'Standard'; Regions = @(); Icmp = 36; Tcp = 8; Tls = 4; Traceroute = $true }
        }
    }
    $profile = if ($SelectedMode -eq 'Auto') { 'Standard' } else { $SelectedMode }
    $defaults = Get-ModeDefaults $profile
    return [pscustomobject][ordered]@{
        Strategy = 'SingleStage'; RequestedMode = $SelectedMode; RegionCount = $count; FinalistLimit = $count; RecommendationLimit = [math]::Min(3,$count)
        Screening = $null
        FinalValidation = [pscustomobject][ordered]@{ Profile = $profile; Regions = @($SelectedRegions); Icmp = $defaults.Icmp; Tcp = $defaults.Tcp; Tls = $defaults.Tls; Traceroute = $true }
    }
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

function Convert-IPv4ToUInt32 {
    param([Parameter(Mandatory = $true)][string]$Address)
    if (-not (Test-IPv4Literal $Address)) { throw "Invalid IPv4 address: $Address" }
    $bytes = ([System.Net.IPAddress]::Parse($Address)).GetAddressBytes()
    return [uint64](($bytes[0] * 16777216L) + ($bytes[1] * 65536L) + ($bytes[2] * 256L) + $bytes[3])
}

function Test-IPv4InCidr {
    param([string]$Address, [string]$Cidr)
    if ($Cidr -notmatch '^(?<network>[^/]+)/(?<length>\d{1,2})$') { return $false }
    $prefixLength = [int]$Matches.length
    if ($prefixLength -lt 0 -or $prefixLength -gt 32 -or -not (Test-IPv4Literal $Matches.network)) { return $false }
    $ipValue = Convert-IPv4ToUInt32 $Address
    $networkValue = Convert-IPv4ToUInt32 $Matches.network
    $mask = if ($prefixLength -eq 0) { [uint64]0 } else { [uint64]([math]::Pow(2, 32) - [math]::Pow(2, (32 - $prefixLength))) }
    return (($ipValue -band $mask) -eq ($networkValue -band $mask))
}

function Find-AwsIpPrefix {
    param([string]$Address, [object[]]$Prefixes)
    if (-not (Test-IPv4Literal $Address)) { throw "TargetIp must be an IPv4 literal: $Address" }
    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($Prefixes)) {
        $prefixProperty = $entry.PSObject.Properties['ip_prefix']
        if ($null -eq $prefixProperty) { continue }
        $prefix = [string]$prefixProperty.Value
        if ($prefix -notmatch '/(?<length>\d{1,2})$') { continue }
        if (Test-IPv4InCidr -Address $Address -Cidr $prefix) {
            $serviceRank = switch ([string]$entry.service) { 'EC2' { 0 } 'AMAZON' { 1 } default { 2 } }
            $candidates.Add([pscustomobject]@{ Entry = $entry; PrefixLength = [int]$Matches.length; ServiceRank = $serviceRank })
        }
    }
    if ($candidates.Count -eq 0) { return $null }
    $winner = @($candidates | Sort-Object -Property @{ Expression = 'PrefixLength'; Descending = $true }, @{ Expression = 'ServiceRank'; Descending = $false })[0]
    return [pscustomobject][ordered]@{
        Address = $Address
        Region = [string]$winner.Entry.region
        NetworkBorderGroup = [string]$winner.Entry.network_border_group
        Service = [string]$winner.Entry.service
        Prefix = [string]$winner.Entry.ip_prefix
        PrefixLength = $winner.PrefixLength
    }
}

function Resolve-AwsIpRegion {
    param([string]$Address, [string]$RegionOverride, [scriptblock]$ContentFetcher)
    if (-not (Test-IPv4Literal $Address)) { throw "TargetIp must be an IPv4 literal: $Address" }
    if (-not [string]::IsNullOrWhiteSpace($RegionOverride)) {
        return [pscustomobject][ordered]@{ Source = 'ManualOverride'; SourceUri = $null; RetrievedAtUtc = $null; Address = $Address; Region = $RegionOverride; NetworkBorderGroup = $null; Service = $null; Prefix = $null; PrefixLength = $null }
    }
    try {
        $content = if ($null -ne $ContentFetcher) { & $ContentFetcher $script:IpRangesUri } else { (Invoke-WebRequest -Uri $script:IpRangesUri -UseBasicParsing -TimeoutSec 15).Content }
        $feed = $content | ConvertFrom-Json
        $match = Find-AwsIpPrefix -Address $Address -Prefixes @($feed.prefixes)
        if ($null -eq $match) { throw "AWS_IP_NOT_RECOGNIZED: $Address is not present in the current AWS IPv4 ranges. Use -Region for BYOIP or unpublished addresses." }
        $result = [ordered]@{ Source = 'AWS ip-ranges.json'; SourceUri = $script:IpRangesUri; RetrievedAtUtc = [datetime]::UtcNow.ToString('o'); SyncToken = [string]$feed.syncToken; CreateDate = [string]$feed.createDate }
        foreach ($property in $match.PSObject.Properties) { $result[$property.Name] = $property.Value }
        return [pscustomobject]$result
    }
    catch {
        if ($_.Exception.Message -like 'AWS_IP_NOT_RECOGNIZED:*') { throw }
        throw "AWS_IP_RANGES_FETCH_FAILED: $($_.Exception.Message). Supply -Region to continue without online detection."
    }
}

function New-HistoryStore {
    return [pscustomobject][ordered]@{ SchemaVersion = '2.0'; UpdatedAtUtc = [datetime]::UtcNow.ToString('o'); BaselineRuns = @(); RealValidations = @() }
}

function ConvertTo-HistorySchema2 {
    param([object]$Store)
    if ($null -eq $Store.PSObject.Properties['SchemaVersion'] -or $null -eq $Store.PSObject.Properties['BaselineRuns'] -or $null -eq $Store.PSObject.Properties['RealValidations']) { throw 'History schema is incomplete.' }
    $migrated = ([string]$Store.SchemaVersion -ne '2.0')
    foreach ($run in @($Store.BaselineRuns)) {
        if ($null -eq $run.PSObject.Properties['Selection']) { $run | Add-Member -NotePropertyName Selection -NotePropertyValue $(if ($null -ne $run.PSObject.Properties['Scope']) { [string]$run.Scope } else { 'Legacy' }) }
        if ($null -eq $run.PSObject.Properties['ProbeProfile']) { $run | Add-Member -NotePropertyName ProbeProfile -NotePropertyValue $(if ($null -ne $run.PSObject.Properties['Mode']) { [string]$run.Mode } else { 'Legacy' }) }
        if ($null -eq $run.PSObject.Properties['Stage']) { $run | Add-Member -NotePropertyName Stage -NotePropertyValue 'FinalValidation' }
    }
    $Store.SchemaVersion = '2.0'
    $Store.BaselineRuns = @($Store.BaselineRuns)
    $Store.RealValidations = @($Store.RealValidations)
    return [pscustomobject][ordered]@{ Store = $Store; Migrated = $migrated }
}

function Trim-HistoryStore {
    param([object]$Store, [datetime]$NowUtc = [datetime]::UtcNow)
    $cutoff = $NowUtc.ToUniversalTime().AddDays(-30)
    $Store.BaselineRuns = @($Store.BaselineRuns | Where-Object { try { ([datetime]$_.TimestampUtc).ToUniversalTime() -ge $cutoff } catch { $false } } | Sort-Object { [datetime]$_.TimestampUtc } -Descending | Select-Object -First 50)
    $Store.RealValidations = @($Store.RealValidations | Where-Object { try { ([datetime]$_.TimestampUtc).ToUniversalTime() -ge $cutoff } catch { $false } } | Sort-Object { [datetime]$_.TimestampUtc } -Descending | Select-Object -First 100)
    $Store.UpdatedAtUtc = $NowUtc.ToUniversalTime().ToString('o')
    return $Store
}

function Read-HistoryStore {
    param([string]$Path = $script:HistoryPath, [datetime]$NowUtc = [datetime]::UtcNow)
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject][ordered]@{ Store = (New-HistoryStore); Recovery = $null; Migrated = $false } }
    try {
        $store = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        $normalized = ConvertTo-HistorySchema2 -Store $store
        return [pscustomobject][ordered]@{ Store = (Trim-HistoryStore -Store $normalized.Store -NowUtc $NowUtc); Recovery = $null; Migrated = $normalized.Migrated }
    }
    catch {
        $stamp = $NowUtc.ToUniversalTime().ToString('yyyyMMddHHmmssfff')
        $quarantine = "$Path.corrupt-$stamp.json"
        Move-Item -LiteralPath $Path -Destination $quarantine -Force
        return [pscustomobject][ordered]@{ Store = (New-HistoryStore); Recovery = [pscustomobject][ordered]@{ Action = 'QuarantinedAndRebuilt'; CorruptPath = $quarantine; Error = $_.Exception.Message }; Migrated = $false }
    }
}

function Write-HistoryStore {
    param([object]$Store, [string]$Path = $script:HistoryPath, [datetime]$NowUtc = [datetime]::UtcNow)
    $Store = Trim-HistoryStore -Store $Store -NowUtc $NowUtc
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    $tempPath = Join-Path $parent ('.{0}.{1}.tmp' -f ([IO.Path]::GetFileName($Path)), [guid]::NewGuid().ToString('N'))
    $backupPath = "$Path.bak"
    try {
        $json = $Store | ConvertTo-Json -Depth 12
        [IO.File]::WriteAllText($tempPath, $json, (New-Object Text.UTF8Encoding($false)))
        $null = Get-Content -LiteralPath $tempPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (Test-Path -LiteralPath $Path) {
            if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force }
            [IO.File]::Replace($tempPath, $Path, $backupPath, $true)
        }
        else { [IO.File]::Move($tempPath, $Path) }
        $null = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        return [pscustomobject][ordered]@{ Path = (Resolve-Path -LiteralPath $Path).Path; BaselineRunCount = @($Store.BaselineRuns).Count; RealValidationCount = @($Store.RealValidations).Count; Atomic = $true }
    }
    finally { if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force } }
}

function Get-BaselineReference {
    param([object]$Store, [string]$Region, [datetime]$ValidationStartedUtc = [datetime]::UtcNow)
    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($run in @($Store.BaselineRuns)) {
        try { $timestamp = ([datetime]$run.TimestampUtc).ToUniversalTime() } catch { continue }
        if ($timestamp -gt $ValidationStartedUtc.ToUniversalTime()) { continue }
        foreach ($metrics in @($run.Regions)) { if ($metrics.Region -eq $Region) { $candidates.Add([pscustomobject]@{ Run = $run; Metrics = $metrics; Timestamp = $timestamp }) } }
    }
    if ($candidates.Count -eq 0) { return [pscustomobject][ordered]@{ Status = 'Missing'; TimestampUtc = $null; AgeHours = $null; Metrics = $null; Mode = $null; Scope = $null; ProbeProfile = $null; Stage = $null } }
    $selected = @($candidates | Sort-Object Timestamp -Descending)[0]
    $ageHours = ($ValidationStartedUtc.ToUniversalTime() - $selected.Timestamp).TotalHours
    $status = if ($ageHours -le 6) { 'Fresh' } elseif ($ageHours -le 24) { 'Usable' } else { 'Stale' }
    $profile = if ($null -ne $selected.Run.PSObject.Properties['ProbeProfile']) { [string]$selected.Run.ProbeProfile } else { [string]$selected.Run.Mode }
    return [pscustomobject][ordered]@{ Status = $status; TimestampUtc = $selected.Timestamp.ToString('o'); AgeHours = [math]::Round($ageHours, 3); Metrics = $selected.Metrics; Mode = $selected.Run.Mode; Scope = $selected.Run.Scope; ProbeProfile = $profile; Stage = $(if ($null -ne $selected.Run.PSObject.Properties['Stage']) { $selected.Run.Stage } else { 'FinalValidation' }) }
}

function Add-BaselineHistory {
    param([object]$Store, [object]$Report, [string]$Scope = 'AllRegions', [string]$Selection = 'Legacy', [string]$ProbeProfile, [string]$Stage = 'FinalValidation')
    $regions = foreach ($item in @($Report.Rankings)) { [pscustomobject][ordered]@{ Region = $item.Region; P50Ms = $item.Icmp.P50Ms; P95Ms = $item.Icmp.P95Ms; LossPct = $item.Icmp.LossPct; JitterMs = $item.Icmp.JitterMs; Health = $item.Health; Score = $item.Score } }
    if ([string]::IsNullOrWhiteSpace($ProbeProfile)) { $ProbeProfile = [string]$Report.Test.Mode }
    $Store.BaselineRuns = @([pscustomobject][ordered]@{ TimestampUtc = $Report.Test.CompletedAtUtc; Mode = $Report.Test.Mode; Scope = $Scope; Selection = $Selection; ProbeProfile = $ProbeProfile; Stage = $Stage; Regions = @($regions) }) + @($Store.BaselineRuns)
    return $Store
}

function Get-CachedTargetResult {
    param([int]$MaximumTargets = 3, [string]$Reason, [string[]]$Regions = $script:RegionOrder)
    $targets = [ordered]@{}
    $failures = [ordered]@{}
    foreach ($region in $Regions) {
        $targets[$region] = @($script:RegionMetadata[$region].CachedTargets | Select-Object -First $MaximumTargets)
        if (@($targets[$region]).Count -eq 0) { $failures[$region] = 'No verified built-in cached target is available for this Region.' }
    }
    return [pscustomobject][ordered]@{
        Source = 'BuiltInCache'
        SourceUri = $script:ReachabilityUri
        RetrievedAtUtc = $null
        CacheUpdated = $script:CachedTargetUpdated
        FallbackReason = $Reason
        Targets = $targets
        Failures = $failures
    }
}

function Get-ReachabilityTargets {
    param(
        [switch]$CachedOnly,
        [ValidateRange(1, 3)][int]$MaximumTargets = 3,
        [string[]]$Regions = $script:RegionOrder,
        [scriptblock]$ContentFetcher
    )
    if ($CachedOnly) { return Get-CachedTargetResult -MaximumTargets $MaximumTargets -Reason 'Requested by -UseCachedTargets.' -Regions $Regions }

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
        $failures = [ordered]@{}
        $trimmedContent = ([string]$content).TrimStart()
        if ($trimmedContent.StartsWith('[') -or $trimmedContent.StartsWith('{')) {
            $jsonData = $content | ConvertFrom-Json
            foreach ($region in $Regions) {
                $found = New-Object System.Collections.Generic.List[string]
                foreach ($entry in @($jsonData)) {
                    $regionProperty = $entry.PSObject.Properties[$region]
                    if ($null -eq $regionProperty) { continue }
                    foreach ($targetProperty in $regionProperty.Value.PSObject.Properties) {
                        $candidate = [string]$targetProperty.Value
                        if ((Test-IPv4Literal $candidate) -and -not $found.Contains($candidate)) { $found.Add($candidate) }
                    }
                }
                $targets[$region] = @($found | Select-Object -First $MaximumTargets)
            }
        }
        else {
            foreach ($region in $Regions) {
                $found = New-Object System.Collections.Generic.List[string]
                $rowPattern = '(?is)<tr[^>]*>(?:(?!</tr>).)*' + [regex]::Escape($region) + '(?:(?!</tr>).)*</tr>'
                foreach ($rowMatch in [regex]::Matches([string]$content, $rowPattern)) {
                    foreach ($ipMatch in [regex]::Matches($rowMatch.Value, '(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])')) {
                        $candidate = $ipMatch.Value
                        $isPrefix = $rowMatch.Value -match ([regex]::Escape($candidate) + '\s*/\s*\d{1,2}')
                        if ((Test-IPv4Literal $candidate) -and -not $isPrefix -and -not $found.Contains($candidate)) { $found.Add($candidate) }
                    }
                }
                $targets[$region] = @($found | Select-Object -First $MaximumTargets)
            }
        }

        foreach ($region in $Regions) {
            if (@($targets[$region]).Count -gt 0) { continue }
            $cached = @($script:RegionMetadata[$region].CachedTargets | Select-Object -First $MaximumTargets)
            if ($cached.Count -gt 0) {
                $targets[$region] = $cached
                $failures[$region] = 'Online source had no valid target; using verified built-in cache for this Region.'
            }
            else {
                $targets[$region] = @()
                $failures[$region] = 'Online source had no valid target and no verified cache is available.'
            }
        }

        return [pscustomobject][ordered]@{
            Source = 'AWSReachabilityPageWithPerRegionFallback'
            SourceUri = $effectiveSourceUri
            RetrievedAtUtc = [datetime]::UtcNow.ToString('o')
            CacheUpdated = $script:CachedTargetUpdated
            FallbackReason = $null
            Targets = $targets
            Failures = $failures
        }
    }
    catch {
        $detail = Get-ExceptionDetail $_.Exception
        return Get-CachedTargetResult -MaximumTargets $MaximumTargets -Reason ("{0}: {1}" -f $detail.Type, $detail.Message) -Regions $Regions
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
    Write-Host 'AWS Lightsail Region Selection'
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

function Get-MetricDelta {
    param([string]$Metric, $BaselineValue, $RealValue, [string]$Unit = 'ms')
    if ($null -eq $BaselineValue -or $null -eq $RealValue) { return [pscustomobject][ordered]@{ Metric = $Metric; Unit = $Unit; Baseline = $BaselineValue; Real = $RealValue; AbsoluteDelta = $null; PercentageDelta = $null } }
    $absolute = [math]::Round(([double]$RealValue - [double]$BaselineValue), 2)
    $percentage = if ([double]$BaselineValue -eq 0) { $null } else { [math]::Round(($absolute / [double]$BaselineValue) * 100.0, 2) }
    return [pscustomobject][ordered]@{ Metric = $Metric; Unit = $Unit; Baseline = $BaselineValue; Real = $RealValue; AbsoluteDelta = $absolute; PercentageDelta = $percentage }
}

function Get-RealComparison {
    param([object]$BaselineMetrics, [object]$RealIcmp)
    $available = $null -ne $BaselineMetrics -and $null -ne $BaselineMetrics.P50Ms -and $null -ne $BaselineMetrics.P95Ms -and $RealIcmp.Received -gt 0
    return [pscustomobject][ordered]@{
        Available = $available
        Reason = $(if ($available) { $null } elseif ($RealIcmp.Received -eq 0) { 'ICMP unavailable; possibly firewall-filtered.' } else { 'No usable Region Baseline.' })
        Metrics = @(
            Get-MetricDelta 'P50 RTT' $(if ($null -ne $BaselineMetrics) { $BaselineMetrics.P50Ms } else { $null }) $(if ($RealIcmp.Received -gt 0) { $RealIcmp.P50Ms } else { $null }) 'ms'
            Get-MetricDelta 'P95 RTT' $(if ($null -ne $BaselineMetrics) { $BaselineMetrics.P95Ms } else { $null }) $(if ($RealIcmp.Received -gt 0) { $RealIcmp.P95Ms } else { $null }) 'ms'
            Get-MetricDelta 'Packet Loss' $(if ($null -ne $BaselineMetrics) { $BaselineMetrics.LossPct } else { $null }) $(if ($RealIcmp.Sent -gt 0) { $RealIcmp.LossPct } else { $null }) 'percentage points'
            Get-MetricDelta 'Jitter' $(if ($null -ne $BaselineMetrics) { $BaselineMetrics.JitterMs } else { $null }) $(if ($RealIcmp.Received -gt 0) { $RealIcmp.JitterMs } else { $null }) 'ms'
        )
    }
}

function Get-RealValidationAssessment {
    param([object]$BaselineReference, [object]$RealIcmp, [object]$RealTcp, [object]$Comparison)
    $tcpRate = [double]$RealTcp.SuccessRatePct
    $icmpAvailable = $RealIcmp.Received -gt 0
    $comparisonAvailable = [bool]$Comparison.Available
    $reasons = New-Object System.Collections.Generic.List[string]
    if (-not $icmpAvailable -and $RealTcp.Received -eq 0) {
        return [pscustomobject][ordered]@{ Recommendation = 'RETEST'; InstanceFit = 'INCONCLUSIVE'; Confidence = 'Low'; RetryCandidate = $false; EvidenceComplete = $false; Reasons = @('Neither ICMP nor TCP produced usable evidence.') }
    }
    $severe = 0
    $moderate = 0
    if ($comparisonAvailable) {
        $p50 = @($Comparison.Metrics | Where-Object Metric -eq 'P50 RTT')[0]
        $p95 = @($Comparison.Metrics | Where-Object Metric -eq 'P95 RTT')[0]
        $loss = @($Comparison.Metrics | Where-Object Metric -eq 'Packet Loss')[0]
        $jitter = @($Comparison.Metrics | Where-Object Metric -eq 'Jitter')[0]
        if ($null -ne $p50.PercentageDelta -and $p50.PercentageDelta -gt 50) { $severe++; $reasons.Add('P50 degradation exceeds 50%.') } elseif ($null -ne $p50.PercentageDelta -and $p50.PercentageDelta -gt 20) { $moderate++ }
        if ($null -ne $p95.PercentageDelta -and $p95.PercentageDelta -gt 60) { $severe++; $reasons.Add('P95 degradation exceeds 60%.') } elseif ($null -ne $p95.PercentageDelta -and $p95.PercentageDelta -gt 25) { $moderate++ }
        if ($null -ne $loss.AbsoluteDelta -and $loss.AbsoluteDelta -gt 10) { $severe++; $reasons.Add('Packet loss degradation exceeds 10 points.') } elseif ($null -ne $loss.AbsoluteDelta -and $loss.AbsoluteDelta -gt 2) { $moderate++ }
        if ($null -ne $jitter.PercentageDelta -and $jitter.PercentageDelta -gt 150 -and $jitter.AbsoluteDelta -gt 5) { $severe++; $reasons.Add('Jitter shows a severe sustained increase.') } elseif (($null -ne $jitter.PercentageDelta -and $jitter.PercentageDelta -gt 50) -and $jitter.AbsoluteDelta -gt 5) { $moderate++ }
    }
    if ($tcpRate -lt 50) { $reasons.Add('TCP success is below 50%.') }
    $retryCandidate = ($tcpRate -lt 50) -or ($severe -ge 2)
    if ($retryCandidate) { return [pscustomobject][ordered]@{ Recommendation = 'RETRY'; InstanceFit = 'POOR'; Confidence = $(if ($comparisonAvailable -and $BaselineReference.Status -eq 'Fresh') { 'High' } else { 'Medium' }); RetryCandidate = $true; EvidenceComplete = $true; Reasons = @($reasons) } }
    if (-not $icmpAvailable -and $tcpRate -ge 75) { return [pscustomobject][ordered]@{ Recommendation = 'RETEST'; InstanceFit = 'INCONCLUSIVE'; Confidence = 'Low'; RetryCandidate = $false; EvidenceComplete = $true; Reasons = @('ICMP unavailable / possibly firewall-filtered; TCP is reachable.') } }
    if (-not $comparisonAvailable -or $BaselineReference.Status -in @('Missing', 'Stale')) { return [pscustomobject][ordered]@{ Recommendation = 'RETEST'; InstanceFit = 'INCONCLUSIVE'; Confidence = 'Low'; RetryCandidate = $false; EvidenceComplete = ($icmpAvailable -or $tcpRate -gt 0); Reasons = @('A usable comparable baseline is unavailable.') } }
    if ($tcpRate -ge 90 -and $moderate -eq 0 -and $severe -eq 0) { return [pscustomobject][ordered]@{ Recommendation = 'KEEP'; InstanceFit = 'GOOD'; Confidence = $(if ($BaselineReference.Status -eq 'Fresh') { 'High' } else { 'Medium' }); RetryCandidate = $false; EvidenceComplete = $true; Reasons = @('Latency, loss, jitter and TCP evidence are within conservative limits.') } }
    return [pscustomobject][ordered]@{ Recommendation = 'RETEST'; InstanceFit = 'BORDERLINE'; Confidence = 'Medium'; RetryCandidate = $false; EvidenceComplete = ($icmpAvailable -or $tcpRate -gt 0); Reasons = @('Results are usable but contain moderate or mixed degradation.') }
}

function Resolve-ConfirmationVerdict {
    param([object]$Initial, [object]$Confirmation)
    if ($Initial.RetryCandidate -and $Confirmation.RetryCandidate) {
        return [pscustomobject][ordered]@{ Recommendation = 'RETRY'; InstanceFit = 'POOR'; Confidence = 'High'; RetryCandidate = $false; EvidenceComplete = $true; Reasons = @('Initial and confirmation rounds both show marked degradation.') }
    }
    return [pscustomobject][ordered]@{ Recommendation = 'RETEST'; InstanceFit = 'INCONCLUSIVE'; Confidence = 'Low'; RetryCandidate = $false; EvidenceComplete = ($Initial.EvidenceComplete -or $Confirmation.EvidenceComplete); Reasons = @('Initial and confirmation rounds conflict; avoid changing IP from one transient result.') }
}

function Invoke-RealProbeRound {
    param([string]$Address, [string]$ResolvedRegion, [int]$Port, [int]$IcmpCount, [int]$TcpCount, [int]$IcmpTimeout, [int]$ConnectTimeout, [int]$DelayMs, [bool]$OmitTraceroute)
    $icmpSamples = New-Object System.Collections.Generic.List[object]
    for ($index = 0; $index -lt $IcmpCount; $index++) {
        $icmpSamples.Add((Invoke-IcmpProbe -Region $ResolvedRegion -Target $Address -TimeoutMs $IcmpTimeout))
        if ($index -lt ($IcmpCount - 1)) { Start-Sleep -Milliseconds $DelayMs }
    }
    $tcpSamples = New-Object System.Collections.Generic.List[object]
    for ($index = 0; $index -lt $TcpCount; $index++) { $tcpSamples.Add((Invoke-TcpProbe -Region $ResolvedRegion -HostName $Address -Port $Port -TimeoutMs $ConnectTimeout)) }
    $trace = if ($OmitTraceroute) { [pscustomobject][ordered]@{ Region = $ResolvedRegion; Target = $Address; Skipped = $true; Success = $false; ExitCode = $null; Output = @(); Error = $null } } else { $value = Invoke-TraceRoute -Region $ResolvedRegion -Target $Address; $value | Add-Member -NotePropertyName Skipped -NotePropertyValue $false; $value }
    return [pscustomobject][ordered]@{
        Icmp = (Get-SampleStatistics @($icmpSamples | ForEach-Object { $_ }))
        Tcp = (Get-SampleStatistics @($tcpSamples | ForEach-Object { $_ }))
        Traceroute = $trace
        RawSamples = [pscustomobject][ordered]@{ Icmp = @($icmpSamples | ForEach-Object { $_ }); Tcp = @($tcpSamples | ForEach-Object { $_ }) }
    }
}

function Write-RealValidation {
    param([object]$Report)
    Write-Host ''
    Write-Host 'AWS Real IP Validation'
    Write-Host ''
    Write-Host ("Target IP:       {0}" -f $Report.Target.Ip)
    Write-Host ("Detected Region: {0}" -f $Report.Target.Region)
    Write-Host ("Region Source:   {0}" -f $Report.RegionDetection.Source)
    Write-Host ("Probe Port:      TCP/{0}" -f $Report.Target.ProbePort)
    Write-Host ''
    Write-Host 'Baseline:'
    Write-Host ("Timestamp: {0}" -f $(if ($null -eq $Report.BaselineReference.TimestampUtc) { '-' } else { $Report.BaselineReference.TimestampUtc }))
    Write-Host ("Age: {0}" -f $(if ($null -eq $Report.BaselineReference.AgeHours) { '-' } else { "{0:N2} hours" -f $Report.BaselineReference.AgeHours }))
    Write-Host ("Status: {0}" -f $Report.BaselineReference.Status)
    Write-Host ''
    Write-Host ('{0,-16} {1,-18} {2,-14} {3}' -f 'Metric','Region Baseline','Real IP','Delta')
    foreach ($metric in $Report.Comparison.Metrics) {
        $displayUnit = if ($metric.Metric -eq 'Packet Loss') { '%' } else { $metric.Unit }
        $deltaUnit = if ($metric.Metric -eq 'Packet Loss') { 'points' } else { $metric.Unit }
        $baseline = if ($null -eq $metric.Baseline) { '-' } else { "{0}{1}" -f $metric.Baseline,$displayUnit }
        $real = if ($null -eq $metric.Real) { '-' } else { "{0}{1}" -f $metric.Real,$displayUnit }
        $delta = if ($null -eq $metric.AbsoluteDelta) { '-' } elseif ($metric.Metric -eq 'Packet Loss') { "{0:+0.##;-0.##;0} {1}" -f $metric.AbsoluteDelta,$deltaUnit } elseif ($null -eq $metric.PercentageDelta) { "{0:+0.##;-0.##;0} {1}" -f $metric.AbsoluteDelta,$deltaUnit } else { "{0:+0.##;-0.##;0} {1} / {2:+0.##;-0.##;0}%" -f $metric.AbsoluteDelta,$deltaUnit,$metric.PercentageDelta }
        Write-Host ('{0,-16} {1,-18} {2,-14} {3}' -f $metric.Metric,$baseline,$real,$delta)
    }
    Write-Host ('{0,-16} {1,-18} {2,-14} {3}' -f 'TCP Success','-',("{0}/{1}" -f $Report.RealMetrics.Tcp.Received,$Report.RealMetrics.Tcp.Sent),'-')
    Write-Host ('{0,-16} {1,-18} {2,-14} {3}' -f 'TCP P50','-',$(if ($null -eq $Report.RealMetrics.Tcp.P50Ms) { '-' } else { "$($Report.RealMetrics.Tcp.P50Ms) ms" }),'-')
    if (-not $Report.Comparison.Available) { Write-Warning $Report.Comparison.Reason }
    Write-Host ''
    Write-Host ("Instance Fit: {0}" -f $Report.Verdict.InstanceFit)
    Write-Host ("Recommendation: {0}" -f $Report.Verdict.Recommendation)
    Write-Host ("Confidence: {0}" -f $Report.Verdict.Confidence)
    foreach ($reason in $Report.Verdict.Reasons) { Write-Host ("- {0}" -f $reason) }
}

function Invoke-RegionProbePass {
    [CmdletBinding()]
    param(
        [string]$SelectedMode, [int]$IcmpCount, [int]$TcpCount, [int]$TlsCount,
        [int]$IcmpTimeout, [int]$ConnectTimeout, [int]$DelayMs, [int]$TargetLimit,
        [string]$JsonPath, [bool]$WriteJson, [bool]$CachedTargetsOnly, [bool]$OmitTraceroute,
        [string[]]$SelectedRegions = $script:RegionOrder, [string]$Scope = 'AllRegions', [bool]$RecordHistory = $true,
        [string]$Selection = 'Legacy', [string]$Stage = 'FinalValidation', [bool]$DisplayOutput = $true,
        [scriptblock]$TargetDiscoveryProvider, [scriptblock]$ProbeProvider
    )
    $started = [datetime]::UtcNow
    if ($IcmpCount -in @(1, 2)) { throw 'IcmpSamplesPerRegion must be 0 (preset) or between 3 and 60.' }
    $defaults = Get-ModeDefaults $SelectedMode
    if ($IcmpCount -eq 0) { $IcmpCount = $defaults.Icmp }
    if ($TcpCount -eq 0) { $TcpCount = $defaults.Tcp }
    if ($TlsCount -eq 0) { $TlsCount = $defaults.Tls }

    Write-Host ("Loading AWS Reachability targets ({0} mode)..." -f $SelectedMode)
    $targetInfo = if ($null -ne $TargetDiscoveryProvider) { & $TargetDiscoveryProvider $SelectedRegions $TargetLimit $CachedTargetsOnly } else { Get-ReachabilityTargets -CachedOnly:$CachedTargetsOnly -MaximumTargets $TargetLimit -Regions $SelectedRegions }
    if ($targetInfo.Source -eq 'BuiltInCache') { Write-Warning ("Using built-in cached targets: {0}" -f $targetInfo.FallbackReason) }
    $availableRegions = @($SelectedRegions | Where-Object { @($targetInfo.Targets[$_]).Count -gt 0 })

    $icmpSamples = New-Object System.Collections.Generic.List[object]
    Write-Host ("Running {0} interleaved ICMP samples per Region..." -f $IcmpCount)
    for ($round = 0; $round -lt $IcmpCount; $round++) {
        $regionsThisRound = @($availableRegions | Sort-Object { Get-Random })
        foreach ($region in $regionsThisRound) {
            $regionTargets = @($targetInfo.Targets[$region])
            $target = $regionTargets[$round % $regionTargets.Count]
            $sample = if ($null -ne $ProbeProvider) { & $ProbeProvider 'Icmp' $region $target $IcmpTimeout } else { Invoke-IcmpProbe -Region $region -Target $target -TimeoutMs $IcmpTimeout }
            $icmpSamples.Add($sample)
        }
        if ($round -lt ($IcmpCount - 1)) { Start-Sleep -Milliseconds $DelayMs }
    }

    $tcpSamples = New-Object System.Collections.Generic.List[object]
    Write-Host ("Running {0} TCP 443 attempts per Region..." -f $TcpCount)
    for ($round = 0; $round -lt $TcpCount; $round++) {
        foreach ($region in @($availableRegions | Sort-Object { Get-Random })) {
            $sample = if ($null -ne $ProbeProvider) { & $ProbeProvider 'Tcp' $region $script:RegionMetadata[$region].Endpoint $ConnectTimeout } else { Invoke-TcpProbe -Region $region -HostName $script:RegionMetadata[$region].Endpoint -TimeoutMs $ConnectTimeout }
            $tcpSamples.Add($sample)
        }
    }

    $tlsSamples = New-Object System.Collections.Generic.List[object]
    Write-Host ("Running {0} TLS handshake attempts per Region..." -f $TlsCount)
    for ($round = 0; $round -lt $TlsCount; $round++) {
        foreach ($region in @($availableRegions | Sort-Object { Get-Random })) {
            $sample = if ($null -ne $ProbeProvider) { & $ProbeProvider 'Tls' $region $script:RegionMetadata[$region].Endpoint $ConnectTimeout } else { Invoke-TlsProbe -Region $region -HostName $script:RegionMetadata[$region].Endpoint -TimeoutMs $ConnectTimeout }
            $tlsSamples.Add($sample)
        }
    }

    $traces = [ordered]@{}
    foreach ($region in $SelectedRegions) {
        if (@($targetInfo.Targets[$region]).Count -eq 0) {
            $traces[$region] = [pscustomobject][ordered]@{ Region = $region; Target = $null; Skipped = $true; Success = $false; ExitCode = $null; Output = @(); Error = [string]$targetInfo.Failures[$region] }
        }
        elseif ($OmitTraceroute) {
            $traces[$region] = [pscustomobject][ordered]@{ Region = $region; Target = $targetInfo.Targets[$region][0]; Skipped = $true; Success = $false; ExitCode = $null; Output = @(); Error = $null }
        }
        else {
            Write-Host ("Capturing traceroute for {0}..." -f $region)
            $trace = if ($null -ne $ProbeProvider) { & $ProbeProvider 'Traceroute' $region $targetInfo.Targets[$region][0] 0 } else { Invoke-TraceRoute -Region $region -Target $targetInfo.Targets[$region][0] }
            $trace | Add-Member -NotePropertyName Skipped -NotePropertyValue $false
            $traces[$region] = $trace
        }
    }

    $regionResults = New-Object System.Collections.Generic.List[object]
    foreach ($region in $SelectedRegions) {
        $icmp = Get-SampleStatistics -Samples @($icmpSamples | Where-Object Region -eq $region)
        $tcp = Get-SampleStatistics -Samples @($tcpSamples | Where-Object Region -eq $region)
        $tls = Get-SampleStatistics -Samples @($tlsSamples | Where-Object Region -eq $region)
        $tcp | Add-Member -NotePropertyName QualityPct -NotePropertyValue (Get-TcpOrTlsQuality $tcp)
        $tls | Add-Member -NotePropertyName QualityPct -NotePropertyValue (Get-TcpOrTlsQuality $tls)
        $health = Get-RegionHealth -Icmp $icmp -Tcp $tcp -Tls $tls
        $probeStatus = if (@($targetInfo.Targets[$region]).Count -eq 0) { 'Unavailable' } elseif ($icmp.Received -eq 0 -and $tcp.Received -eq 0 -and $tls.Received -eq 0) { 'Failed' } elseif ($icmp.Received -lt $icmp.Sent -or $tcp.Received -lt $tcp.Sent -or $tls.Received -lt $tls.Sent) { 'Partial' } else { 'Complete' }
        $regionResults.Add([pscustomobject][ordered]@{
            Region = $region; Name = $script:RegionMetadata[$region].Name; Location = $script:RegionMetadata[$region].Name; Endpoint = $script:RegionMetadata[$region].Endpoint
            Targets = @($targetInfo.Targets[$region]); Icmp = $icmp; Tcp = $tcp; Tls = $tls
            Health = $health; Score = 0.0; ScoreComponents = $null; DataCompletenessPct = 0.0
            ProbeStatus = $probeStatus; UnavailableReason = $(if ($probeStatus -eq 'Unavailable') { [string]$targetInfo.Failures[$region] } else { $null }); Traceroute = $traces[$region]
        })
    }
    $ranked = Add-RegionScores -RegionResults @($regionResults | ForEach-Object { $_ })
    $recommendation = Get-Recommendation -RankedRegions $ranked
    if ($DisplayOutput) { Write-Ranking -Ranked $ranked -Recommendation $recommendation -TargetInfo $targetInfo }

    $report = [pscustomobject][ordered]@{
        SchemaVersion = '2.0'
        Operation = 'RegionProbePass'
        Tool = [pscustomobject][ordered]@{ Name = 'AWS Region Select Tool'; Version = $script:ToolVersion }
        Test = [pscustomobject][ordered]@{
            StartedAtUtc = $started.ToString('o'); CompletedAtUtc = [datetime]::UtcNow.ToString('o')
            Source = 'Current PC / Current Network Exit'; CandidateRegions = @($SelectedRegions); Mode = $SelectedMode; Scope = $Scope; Stage = $Stage
            Settings = [pscustomobject][ordered]@{ IcmpSamplesPerRegion = $IcmpCount; TcpAttemptsPerRegion = $TcpCount; TlsAttemptsPerRegion = $TlsCount; PingTimeoutMs = $IcmpTimeout; ConnectionTimeoutMs = $ConnectTimeout; RoundDelayMs = $DelayMs; TracerouteSkipped = $OmitTraceroute }
        }
        Environment = [pscustomobject][ordered]@{
            ComputerName = $env:COMPUTERNAME; OSVersion = [System.Environment]::OSVersion.VersionString
            PowerShellVersion = $PSVersionTable.PSVersion.ToString(); PowerShellEdition = $(if ($PSVersionTable.ContainsKey('PSEdition')) { $PSVersionTable.PSEdition } else { 'Desktop' })
        }
        TargetDiscovery = $targetInfo
        Selection = [pscustomobject][ordered]@{ Input = $Selection; Scope = $Scope; Regions = @($SelectedRegions) }
        Rankings = $ranked
        Recommendation = $recommendation
        RawSamples = [pscustomobject][ordered]@{
            Icmp = @($icmpSamples | ForEach-Object { $_ })
            Tcp443 = @($tcpSamples | ForEach-Object { $_ })
            Tls = @($tlsSamples | ForEach-Object { $_ })
        }
    }

    $historyInfo = [pscustomobject][ordered]@{ Enabled = $RecordHistory; Path = $script:HistoryPath; Write = $null; Recovery = $null }
    if ($RecordHistory) {
        try {
            $historyRead = Read-HistoryStore
            $historyInfo.Recovery = $historyRead.Recovery
            $historyStore = Add-BaselineHistory -Store $historyRead.Store -Report $report -Scope $Scope -Selection $Selection -ProbeProfile $SelectedMode -Stage $Stage
            $historyInfo.Write = Write-HistoryStore -Store $historyStore
            if ($null -ne $historyRead.Recovery) { Write-Warning ("History was corrupt and rebuilt; quarantined at {0}" -f $historyRead.Recovery.CorruptPath) }
        }
        catch { $historyInfo.Write = [pscustomobject][ordered]@{ Error = $_.Exception.Message }; Write-Warning ("Baseline completed but history could not be updated: {0}" -f $_.Exception.Message) }
    }
    $report | Add-Member -NotePropertyName History -NotePropertyValue $historyInfo

    if ($WriteJson) {
        if ([string]::IsNullOrWhiteSpace($JsonPath)) { $JsonPath = Join-Path (Get-Location) ("aws-region-probe_{0}.json" -f (Get-Date -Format 'yyyy-MM-dd_HHmmss')) }
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

function Add-StageRanks {
    param([object[]]$Items, [string]$PropertyName)
    $rank = 0
    foreach ($item in @($Items)) {
        $rank++
        if ($null -ne $item.PSObject.Properties[$PropertyName]) { $item.$PropertyName = $rank }
        else { $item | Add-Member -NotePropertyName $PropertyName -NotePropertyValue $rank }
    }
    return @($Items)
}

function Get-TopRecommendations {
    param([object[]]$Ranked, [int]$Limit = 3)
    $eligible = @($Ranked | Where-Object { $_.ProbeStatus -ne 'Unavailable' -and $_.Health -in @('Good','Fair','Degraded') -and $_.Icmp.Received -gt 0 -and $_.Tcp.Received -gt 0 -and $_.Tls.Received -gt 0 } | Select-Object -First $Limit)
    $rank = 0
    foreach ($item in $eligible) {
        $rank++
        if ($null -ne $item.PSObject.Properties['RecommendationRank']) { $item.RecommendationRank = $rank } else { $item | Add-Member -NotePropertyName RecommendationRank -NotePropertyValue $rank }
    }
    return @($eligible)
}

function Write-RegionProbeOutput {
    param([object]$Report)
    Write-Host ''
    Write-Host 'AWS Lightsail Region Selection'
    Write-Host ("Selection: {0} ({1} Regions)" -f $Report.Selection.Input,@($Report.Selection.Regions).Count)
    Write-Host ("Plan: {0}" -f $Report.ProbePlan.Strategy)
    if (@($Report.Recommendation.TopRegions).Count -gt 0) {
        Write-Host ''
        Write-Host 'Final Recommendation'
        $Report.Recommendation.TopRegions | Select-Object RecommendationRank,Region,Location,Score,Health,DataCompletenessPct | Format-Table -AutoSize | Out-Host
    }
    else { Write-Warning 'No decisive winner / insufficient evidence.' }
    if ($null -ne $Report.FinalValidation) {
        if (@($Report.Selection.Regions).Count -eq 1) {
            Write-Host 'Single Region Validation (Score is evidence quality, not a cross-Region rank)'
            $Report.FinalValidation.Rankings | Select-Object Region,Location,@{Name='P50';Expression={$_.Icmp.P50Ms}},@{Name='P95';Expression={$_.Icmp.P95Ms}},@{Name='Loss%';Expression={$_.Icmp.LossPct}},Health,ProbeStatus,Score | Format-Table -AutoSize | Out-Host
        }
        else {
            Write-Host 'Finalist Validation'
            $Report.FinalValidation.Rankings | Select-Object FinalistRank,Region,Location,@{Name='P50';Expression={$_.Icmp.P50Ms}},@{Name='P95';Expression={$_.Icmp.P95Ms}},@{Name='Loss%';Expression={$_.Icmp.LossPct}},Health,ProbeStatus,Score | Format-Table -AutoSize | Out-Host
        }
    }
    if ($null -ne $Report.Screening) {
        Write-Host 'Global Screening - All Selected Regions'
        $Report.Screening.Rankings | Select-Object ScreeningRank,Region,Location,@{Name='P50';Expression={$_.Icmp.P50Ms}},@{Name='P95';Expression={$_.Icmp.P95Ms}},@{Name='Loss%';Expression={$_.Icmp.LossPct}},@{Name='Jitter';Expression={$_.Icmp.JitterMs}},@{Name='TCP';Expression={$_.Tcp.SuccessRatePct}},@{Name='TLS';Expression={$_.Tls.SuccessRatePct}},Health,ProbeStatus | Format-Table -AutoSize | Out-Host
    }
}

function Invoke-AwsRegionSelection {
    [CmdletBinding()]
    param(
        [string]$SelectedMode, [int]$IcmpCount, [int]$TcpCount, [int]$TlsCount,
        [int]$IcmpTimeout, [int]$ConnectTimeout, [int]$DelayMs, [int]$TargetLimit,
        [string]$JsonPath, [bool]$WriteJson, [bool]$CachedTargetsOnly, [bool]$OmitTraceroute,
        [string[]]$SelectedRegions = $script:RegionOrder, [string]$Scope = 'Group:global', [bool]$RecordHistory = $true,
        [string]$Selection = 'global', [scriptblock]$TargetDiscoveryProvider, [scriptblock]$ProbeProvider
    )
    $started = [datetime]::UtcNow
    $plan = Get-ProbePlan -SelectedRegions $SelectedRegions -SelectedMode $SelectedMode
    if ($IcmpCount -gt 0) { if ($null -ne $plan.Screening) { $plan.Screening.Icmp = $IcmpCount }; $plan.FinalValidation.Icmp = $IcmpCount }
    if ($TcpCount -gt 0) { if ($null -ne $plan.Screening) { $plan.Screening.Tcp = $TcpCount }; $plan.FinalValidation.Tcp = $TcpCount }
    if ($TlsCount -gt 0) { if ($null -ne $plan.Screening) { $plan.Screening.Tls = $TlsCount }; $plan.FinalValidation.Tls = $TlsCount }
    $plan.FinalValidation.Traceroute = (-not $OmitTraceroute)
    Write-Host ("Probe plan: {0}; {1} selected Region(s)." -f $plan.Strategy,$plan.RegionCount)
    if ($plan.Strategy -eq 'TwoStage') { Write-Host 'Auto: Quick screening for all selected Regions, then Standard validation for up to 5 finalists.' }

    $screeningReport = $null
    $finalReport = $null
    if ($plan.Strategy -eq 'TwoStage') {
        $screeningReport = Invoke-RegionProbePass -SelectedMode 'Quick' -IcmpCount $(if ($IcmpCount -gt 0) { $IcmpCount } else { 9 }) -TcpCount $(if ($TcpCount -gt 0) { $TcpCount } else { 3 }) -TlsCount $(if ($TlsCount -gt 0) { $TlsCount } else { 2 }) -IcmpTimeout $IcmpTimeout -ConnectTimeout $ConnectTimeout -DelayMs $DelayMs -TargetLimit $TargetLimit -JsonPath $null -WriteJson $false -CachedTargetsOnly $CachedTargetsOnly -OmitTraceroute $true -SelectedRegions $SelectedRegions -Scope $Scope -RecordHistory $RecordHistory -Selection $Selection -Stage 'Screening' -DisplayOutput $false -TargetDiscoveryProvider $TargetDiscoveryProvider -ProbeProvider $ProbeProvider
        $screeningReport.Rankings = @(Add-StageRanks -Items $screeningReport.Rankings -PropertyName 'ScreeningRank')
        $finalists = @($screeningReport.Rankings | Where-Object { $_.ProbeStatus -ne 'Unavailable' -and $_.Health -in @('Good','Fair','Degraded') -and $_.Icmp.Received -gt 0 -and $_.Tcp.Received -gt 0 -and $_.Tls.Received -gt 0 } | Select-Object -First 5 | ForEach-Object { $_.Region })
        $plan.FinalValidation.Regions = @($finalists)
        if ($finalists.Count -gt 0) {
            $finalReport = Invoke-RegionProbePass -SelectedMode 'Standard' -IcmpCount $(if ($IcmpCount -gt 0) { $IcmpCount } else { 36 }) -TcpCount $(if ($TcpCount -gt 0) { $TcpCount } else { 8 }) -TlsCount $(if ($TlsCount -gt 0) { $TlsCount } else { 4 }) -IcmpTimeout $IcmpTimeout -ConnectTimeout $ConnectTimeout -DelayMs $DelayMs -TargetLimit $TargetLimit -JsonPath $null -WriteJson $false -CachedTargetsOnly $CachedTargetsOnly -OmitTraceroute $OmitTraceroute -SelectedRegions $finalists -Scope $Scope -RecordHistory $RecordHistory -Selection $Selection -Stage 'FinalValidation' -DisplayOutput $false -TargetDiscoveryProvider $TargetDiscoveryProvider -ProbeProvider $ProbeProvider
            $finalReport.Rankings = @(Add-StageRanks -Items $finalReport.Rankings -PropertyName 'FinalistRank')
        }
    }
    else {
        $profile = $plan.FinalValidation.Profile
        $finalReport = Invoke-RegionProbePass -SelectedMode $profile -IcmpCount $IcmpCount -TcpCount $TcpCount -TlsCount $TlsCount -IcmpTimeout $IcmpTimeout -ConnectTimeout $ConnectTimeout -DelayMs $DelayMs -TargetLimit $TargetLimit -JsonPath $null -WriteJson $false -CachedTargetsOnly $CachedTargetsOnly -OmitTraceroute $OmitTraceroute -SelectedRegions $SelectedRegions -Scope $Scope -RecordHistory $RecordHistory -Selection $Selection -Stage 'FinalValidation' -DisplayOutput $false -TargetDiscoveryProvider $TargetDiscoveryProvider -ProbeProvider $ProbeProvider
        if (@($SelectedRegions).Count -gt 1) { $finalReport.Rankings = @(Add-StageRanks -Items $finalReport.Rankings -PropertyName 'FinalistRank') }
    }

    $finalRankings = if ($null -ne $finalReport) { @($finalReport.Rankings) } else { @() }
    $primary = if ($null -ne $finalReport) { $finalReport.Recommendation } else { [pscustomobject][ordered]@{ Region=$null; Name=$null; Confidence='Low'; Decisive=$false; Message='Insufficient evidence; no finalists passed the screening gate.'; ScoreMargin=$null } }
    $top = if ($primary.Decisive) { @(Get-TopRecommendations -Ranked $finalRankings -Limit 3) } else { @() }
    $recommendation = [pscustomobject][ordered]@{ Region = $primary.Region; Name = $primary.Name; Confidence = $primary.Confidence; Decisive = $primary.Decisive; Message = $primary.Message; ScoreMargin = $primary.ScoreMargin; TopRegions = @($top) }
    $warnings = New-Object System.Collections.Generic.List[string]
    foreach ($pass in @($screeningReport,$finalReport)) {
        if ($null -eq $pass) { continue }
        foreach ($region in @($pass.Rankings | Where-Object ProbeStatus -eq 'Unavailable')) { $warnings.Add(("{0}: {1}" -f $region.Region,$region.UnavailableReason)) }
    }
    $report = [pscustomobject][ordered]@{
        SchemaVersion = '2.0'; Operation = 'RegionProbe'
        Tool = [pscustomobject][ordered]@{ Name = 'AWS Region Select Tool'; Version = $script:ToolVersion }
        Environment = $(if ($null -ne $finalReport) { $finalReport.Environment } elseif ($null -ne $screeningReport) { $screeningReport.Environment } else { $null })
        Test = [pscustomobject][ordered]@{ StartedAtUtc = $started.ToString('o'); CompletedAtUtc = [datetime]::UtcNow.ToString('o'); Mode = $SelectedMode; Scope = $Scope }
        Catalog = [pscustomobject][ordered]@{ Source = $script:CatalogSource; UpdatedAt = $script:CatalogUpdatedAt; RegionCount = $script:RegionOrder.Count; Regions = @(Get-RegionCatalog) }
        Selection = [pscustomobject][ordered]@{ Input = $Selection; Scope = $Scope; Regions = @($SelectedRegions) }
        ProbePlan = $plan
        TargetDiscovery = [pscustomobject][ordered]@{ Screening = $(if ($null -ne $screeningReport) { $screeningReport.TargetDiscovery } else { $null }); FinalValidation = $(if ($null -ne $finalReport) { $finalReport.TargetDiscovery } else { $null }) }
        Screening = $(if ($null -ne $screeningReport) { [pscustomobject][ordered]@{ Profile = 'Quick'; Rankings = @($screeningReport.Rankings) } } else { $null })
        FinalValidation = $(if ($null -ne $finalReport) { [pscustomobject][ordered]@{ Profile = $plan.FinalValidation.Profile; Rankings = @($finalReport.Rankings) } } else { $null })
        Rankings = @($finalRankings)
        Recommendation = $recommendation
        RealValidation = $null
        History = [pscustomobject][ordered]@{ Screening = $(if ($null -ne $screeningReport) { $screeningReport.History } else { $null }); FinalValidation = $(if ($null -ne $finalReport) { $finalReport.History } else { $null }) }
        RawSamples = [pscustomobject][ordered]@{ Screening = $(if ($null -ne $screeningReport) { $screeningReport.RawSamples } else { $null }); FinalValidation = $(if ($null -ne $finalReport) { $finalReport.RawSamples } else { $null }) }
        Warnings = @($warnings)
    }
    Write-RegionProbeOutput -Report $report
    if ($WriteJson) {
        if ([string]::IsNullOrWhiteSpace($JsonPath)) { $JsonPath = Join-Path (Get-Location) ("aws-region-probe_{0}.json" -f (Get-Date -Format 'yyyy-MM-dd_HHmmss')) }
        $parent = Split-Path -Parent $JsonPath
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
        $report | ConvertTo-Json -Depth 18 | Set-Content -LiteralPath $JsonPath -Encoding UTF8
        $resolved = (Resolve-Path -LiteralPath $JsonPath).Path; Write-Host ''; Write-Host ("JSON report: {0}" -f $resolved); $report | Add-Member -NotePropertyName ReportPath -NotePropertyValue $resolved
    }
    return $report
}

function Add-RealValidationHistory {
    param([object]$Store, [object]$Report)
    $entry = [pscustomobject][ordered]@{
        TimestampUtc = $Report.Test.CompletedAtUtc; Ip = $Report.Target.Ip; Region = $Report.Target.Region; ProbePort = $Report.Target.ProbePort
        Metrics = [pscustomobject][ordered]@{ P50Ms = $Report.RealMetrics.Icmp.P50Ms; P95Ms = $Report.RealMetrics.Icmp.P95Ms; LossPct = $Report.RealMetrics.Icmp.LossPct; JitterMs = $Report.RealMetrics.Icmp.JitterMs; TcpSuccessRatePct = $Report.RealMetrics.Tcp.SuccessRatePct; TcpP50Ms = $Report.RealMetrics.Tcp.P50Ms }
        BaselineReference = [pscustomobject][ordered]@{ TimestampUtc = $Report.BaselineReference.TimestampUtc; Status = $Report.BaselineReference.Status }
        Verdict = [pscustomobject][ordered]@{ Recommendation = $Report.Verdict.Recommendation; InstanceFit = $Report.Verdict.InstanceFit; Confidence = $Report.Verdict.Confidence }
    }
    $Store.RealValidations = @($entry) + @($Store.RealValidations)
    return $Store
}

function Invoke-RealIpValidation {
    [CmdletBinding()]
    param(
        [string]$Address, [int]$Port, [string]$RegionOverride, [string]$SelectedMode,
        [int]$IcmpCount, [int]$TcpCount, [int]$IcmpTimeout, [int]$ConnectTimeout,
        [int]$DelayMs, [int]$TargetLimit, [string]$JsonPath, [bool]$WriteJson,
        [bool]$CachedTargetsOnly, [bool]$OmitTraceroute, [int]$ConfirmationDelaySeconds,
        [scriptblock]$IpRangesFetcher, [scriptblock]$BaselineRefresher, [scriptblock]$ProbeRunner,
        [object]$RegionResolution
    )
    $started = [datetime]::UtcNow
    if (-not (Test-IPv4Literal $Address)) { throw "TargetIp must be an IPv4 literal: $Address" }
    if ($IcmpCount -in @(1, 2)) { throw 'IcmpSamplesPerRegion must be 0 (preset) or between 3 and 60.' }
    if ($null -ne $RegionResolution) {
        if ($null -eq $RegionResolution.PSObject.Properties['Address'] -or $null -eq $RegionResolution.PSObject.Properties['Region']) { throw 'Interactive Region resolution is incomplete.' }
        if ([string]$RegionResolution.Address -ne $Address) { throw 'Interactive Region resolution does not match TargetIp.' }
        $detection = $RegionResolution
    }
    else {
        $detection = Resolve-AwsIpRegion -Address $Address -RegionOverride $RegionOverride -ContentFetcher $IpRangesFetcher
    }
    if ($detection.Region -notin $script:RegionOrder) { throw "UNSUPPORTED_REGION: detected Region '$($detection.Region)' is outside the supported baseline set: $($script:RegionOrder -join ', ')." }

    $realDefaults = switch ($SelectedMode) { 'Quick' { @{ Icmp = 6; Tcp = 4 } } 'Thorough' { @{ Icmp = 25; Tcp = 12 } } default { @{ Icmp = 15; Tcp = 8 } } }
    if ($IcmpCount -eq 0) { $IcmpCount = $realDefaults.Icmp }
    if ($TcpCount -eq 0) { $TcpCount = $realDefaults.Tcp }

    $historyRead = Read-HistoryStore
    $historyRecovery = $historyRead.Recovery
    if ($null -ne $historyRead.Recovery) { Write-Warning ("History was corrupt and rebuilt; quarantined at {0}" -f $historyRead.Recovery.CorruptPath) }
    $baseline = Get-BaselineReference -Store $historyRead.Store -Region $detection.Region -ValidationStartedUtc $started
    $quickOnly = ($baseline.Status -in @('Fresh','Usable') -and $baseline.ProbeProfile -eq 'Quick')
    $refresh = [pscustomobject][ordered]@{ Required = ($baseline.Status -in @('Stale','Missing') -or $quickOnly); Reason = $(if ($quickOnly) { 'QuickOnlyBaseline' } else { $baseline.Status }); Attempted = $false; Succeeded = $false; Region = $detection.Region; Error = $null }
    if ($refresh.Required) {
        $refresh.Attempted = $true
        Write-Host ("Baseline refresh required ({0}); refreshing only {1} in Standard mode..." -f $refresh.Reason,$detection.Region)
        try {
            if ($null -ne $BaselineRefresher) { & $BaselineRefresher $detection.Region }
            else {
                $null = Invoke-AwsRegionSelection -SelectedMode 'Standard' -IcmpCount 0 -TcpCount 0 -TlsCount 0 -IcmpTimeout $IcmpTimeout -ConnectTimeout $ConnectTimeout -DelayMs $DelayMs -TargetLimit $TargetLimit -JsonPath $null -WriteJson $false -CachedTargetsOnly $CachedTargetsOnly -OmitTraceroute $true -SelectedRegions @($detection.Region) -Scope 'SingleRegionRefresh' -RecordHistory $true -Selection $detection.Region
            }
            $historyRead = Read-HistoryStore
            $baseline = Get-BaselineReference -Store $historyRead.Store -Region $detection.Region -ValidationStartedUtc ([datetime]::UtcNow.AddSeconds(1))
            $refresh.Succeeded = $baseline.Status -in @('Fresh','Usable')
        }
        catch { $refresh.Error = $_.Exception.Message; Write-Warning ("Single-Region baseline refresh failed: {0}" -f $_.Exception.Message) }
    }

    $runner = if ($null -ne $ProbeRunner) { $ProbeRunner } else { { param($ip,$region,$probePort,$icmpN,$tcpN,$pingMs,$connectMs,$roundMs,$skipTrace) Invoke-RealProbeRound -Address $ip -ResolvedRegion $region -Port $probePort -IcmpCount $icmpN -TcpCount $tcpN -IcmpTimeout $pingMs -ConnectTimeout $connectMs -DelayMs $roundMs -OmitTraceroute $skipTrace } }
    Write-Host ("Running Real IP probes for {0} in {1}: {2} ICMP, {3} TCP/{4}..." -f $Address,$detection.Region,$IcmpCount,$TcpCount,$Port)
    $initialRound = & $runner $Address $detection.Region $Port $IcmpCount $TcpCount $IcmpTimeout $ConnectTimeout $DelayMs $OmitTraceroute
    $usableBaselineMetrics = if ($baseline.Status -in @('Fresh','Usable')) { $baseline.Metrics } else { $null }
    $comparison = Get-RealComparison -BaselineMetrics $usableBaselineMetrics -RealIcmp $initialRound.Icmp
    $initialAssessment = Get-RealValidationAssessment -BaselineReference $baseline -RealIcmp $initialRound.Icmp -RealTcp $initialRound.Tcp -Comparison $comparison
    $confirmation = $null
    $verdict = $initialAssessment
    if ($initialAssessment.RetryCandidate) {
        Write-Warning ("Initial result is a RETRY candidate; waiting {0}s for one shortened confirmation." -f $ConfirmationDelaySeconds)
        Start-Sleep -Seconds $ConfirmationDelaySeconds
        $confirmRound = & $runner $Address $detection.Region $Port ([math]::Min(6,$IcmpCount)) ([math]::Min(4,$TcpCount)) $IcmpTimeout $ConnectTimeout $DelayMs $true
        $confirmComparison = Get-RealComparison -BaselineMetrics $usableBaselineMetrics -RealIcmp $confirmRound.Icmp
        $confirmAssessment = Get-RealValidationAssessment -BaselineReference $baseline -RealIcmp $confirmRound.Icmp -RealTcp $confirmRound.Tcp -Comparison $confirmComparison
        $verdict = Resolve-ConfirmationVerdict -Initial $initialAssessment -Confirmation $confirmAssessment
        $confirmation = [pscustomobject][ordered]@{ DelaySeconds = $ConfirmationDelaySeconds; Metrics = $confirmRound; Comparison = $confirmComparison; Assessment = $confirmAssessment }
    }

    $report = [pscustomobject][ordered]@{
        SchemaVersion = '2.0'; Operation = 'RealIpValidation'
        Tool = [pscustomobject][ordered]@{ Name = 'AWS Region Select Tool'; Version = $script:ToolVersion }
        Test = [pscustomobject][ordered]@{ StartedAtUtc = $started.ToString('o'); CompletedAtUtc = [datetime]::UtcNow.ToString('o'); Source = 'Current PC / Current Network Exit'; Mode = $SelectedMode; Settings = [pscustomobject][ordered]@{ IcmpSamples = $IcmpCount; TcpAttempts = $TcpCount; PingTimeoutMs = $IcmpTimeout; ConnectionTimeoutMs = $ConnectTimeout; RoundDelayMs = $DelayMs; ConfirmationDelaySeconds = $ConfirmationDelaySeconds; TracerouteSkipped = $OmitTraceroute } }
        Environment = [pscustomobject][ordered]@{ ComputerName = $env:COMPUTERNAME; OSVersion = [Environment]::OSVersion.VersionString; PowerShellVersion = $PSVersionTable.PSVersion.ToString(); PowerShellEdition = $(if ($PSVersionTable.ContainsKey('PSEdition')) { $PSVersionTable.PSEdition } else { 'Desktop' }) }
        Catalog = [pscustomobject][ordered]@{ Source = $script:CatalogSource; UpdatedAt = $script:CatalogUpdatedAt; RegionCount = $script:RegionOrder.Count }
        Selection = $null; TargetDiscovery = $null; ProbePlan = [pscustomobject][ordered]@{ Strategy = 'RealIpValidation'; Icmp = $IcmpCount; Tcp = $TcpCount; ProbePort = $Port }
        Screening = $null; FinalValidation = $null; Rankings = @(); Recommendation = $null
        Target = [pscustomobject][ordered]@{ Ip = $Address; Region = $detection.Region; ProbePort = $Port }
        RegionDetection = $detection; BaselineReference = $baseline; BaselineRefresh = $refresh
        RealMetrics = [pscustomobject][ordered]@{ Icmp = $initialRound.Icmp; Tcp = $initialRound.Tcp; Traceroute = $initialRound.Traceroute }
        Comparison = $comparison; InitialAssessment = $initialAssessment; Confirmation = $confirmation; Verdict = $verdict
        RealValidation = [pscustomobject][ordered]@{ Target = [pscustomobject][ordered]@{ Ip = $Address; Region = $detection.Region; ProbePort = $Port }; RegionDetection = $detection; BaselineReference = $baseline; BaselineRefresh = $refresh; Comparison = $comparison; Verdict = $verdict }
        RawSamples = $initialRound.RawSamples
        Warnings = @()
    }
    $historyInfo = [pscustomobject][ordered]@{ Path = $script:HistoryPath; Recovery = $historyRecovery; Write = $null }
    try { $store = Add-RealValidationHistory -Store $historyRead.Store -Report $report; $historyInfo.Write = Write-HistoryStore -Store $store } catch { $historyInfo.Write = [pscustomobject][ordered]@{ Error = $_.Exception.Message }; Write-Warning ("Validation completed but history could not be updated: {0}" -f $_.Exception.Message) }
    $report | Add-Member -NotePropertyName History -NotePropertyValue $historyInfo
    Write-RealValidation -Report $report
    if ($WriteJson) {
        if ([string]::IsNullOrWhiteSpace($JsonPath)) { $JsonPath = Join-Path (Get-Location) ("aws-real-ip-validation_{0}_{1}.json" -f ($Address -replace '\.','-'),(Get-Date -Format 'yyyy-MM-dd_HHmmss')) }
        $parent = Split-Path -Parent $JsonPath
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
        $report | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $JsonPath -Encoding UTF8
        $resolved = (Resolve-Path -LiteralPath $JsonPath).Path; Write-Host ''; Write-Host ("JSON report: {0}" -f $resolved); $report | Add-Member -NotePropertyName ReportPath -NotePropertyValue $resolved
    }
    return $report
}

function Read-InteractiveRequest {
    param([scriptblock]$InputProvider, [scriptblock]$RegionResolver)
    while ($true) {
        Write-Host ''
        Write-Host 'AWS Region Select Tool'
        Write-Host '[1] Global Lightsail Scan'
        Write-Host '[2] Targeted Region Scan'
        Write-Host '[3] Real IP Validation'
        Write-Host '[Q] Quit'
        $choice = ([string]$(if ($null -ne $InputProvider) { & $InputProvider 'Select' } else { Read-Host 'Select' })).Trim().ToLowerInvariant()
        switch ($choice) {
            '1' { return [pscustomobject][ordered]@{ Action = 'RegionProbe'; Target = 'global'; TargetIp = $null; Region = $null; ProbePort = 22; RegionDetection = $null } }
            '2' {
                while ($true) {
                    $selection = ([string]$(if ($null -ne $InputProvider) { & $InputProvider 'Region, group, custom comma list, or ?' } else { Read-Host 'Region, group, custom comma list, or ?' })).Trim()
                    if ($selection -eq '?') { Show-TargetCatalog; continue }
                    try { $null = Resolve-RegionSelection -Selection $selection; return [pscustomobject][ordered]@{ Action = 'RegionProbe'; Target = $selection; TargetIp = $null; Region = $null; ProbePort = 22; RegionDetection = $null } }
                    catch { Write-Warning $_.Exception.Message }
                }
            }
            '3' {
                $ip = ([string]$(if ($null -ne $InputProvider) { & $InputProvider 'Target IPv4' } else { Read-Host 'Target IPv4' })).Trim()
                if (-not (Test-IPv4Literal $ip)) { throw "TargetIp must be an IPv4 literal: $ip" }
                try {
                    $detection = if ($null -ne $RegionResolver) { & $RegionResolver $ip } else { Resolve-AwsIpRegion -Address $ip }
                    if ($null -eq $detection -or $null -eq $detection.PSObject.Properties['Region'] -or [string]::IsNullOrWhiteSpace([string]$detection.Region)) { throw "AWS_IP_NOT_RECOGNIZED: $ip did not resolve to an AWS Region." }
                    if ($detection.Region -notin $script:RegionOrder) { throw "UNSUPPORTED_REGION: detected Region '$($detection.Region)' is outside the supported Lightsail Region catalog." }
                    Write-Host ("Detected Region: {0} ({1})" -f $detection.Region,$script:RegionMetadata[$detection.Region].Name)
                    return [pscustomobject][ordered]@{ Action = 'RealIpValidation'; Target = $null; TargetIp = $ip; Region = $null; ProbePort = 22; RegionDetection = $detection }
                }
                catch {
                    $detectionError = $_.Exception.Message
                    if ($detectionError -notlike 'AWS_IP_NOT_RECOGNIZED:*' -and $detectionError -notlike 'AWS_IP_RANGES_FETCH_FAILED:*' -and $detectionError -notlike 'UNSUPPORTED_REGION:*') { throw }
                    Write-Warning ("AWS Region could not be detected automatically: {0}" -f $detectionError)
                    $override = ([string]$(if ($null -ne $InputProvider) { & $InputProvider 'Region override' } else { Read-Host 'Region override' })).Trim().ToLowerInvariant()
                    if ([string]::IsNullOrWhiteSpace($override)) { throw 'REGION_OVERRIDE_REQUIRED: automatic Region detection failed and Region override was empty.' }
                    if ($override -notin $script:RegionOrder) { throw "Unsupported Lightsail Region override '$override'. Use -ListTargets." }
                    $detection = Resolve-AwsIpRegion -Address $ip -RegionOverride $override
                    return [pscustomobject][ordered]@{ Action = 'RealIpValidation'; Target = $null; TargetIp = $ip; Region = $override; ProbePort = 22; RegionDetection = $detection }
                }
            }
            'q' { return [pscustomobject][ordered]@{ Action = 'Quit'; Target = $null; TargetIp = $null; Region = $null; ProbePort = 22; RegionDetection = $null } }
            default { Write-Warning 'Choose 1, 2, 3, or Q.' }
        }
    }
}

function Invoke-EntryPoint {
    try {
        $interactiveRegionResolution = $null
        if ($ListTargets) {
            if (-not [string]::IsNullOrWhiteSpace($Target) -or -not [string]::IsNullOrWhiteSpace($TargetIp) -or -not [string]::IsNullOrWhiteSpace($Region)) { throw '-ListTargets cannot be combined with -Target, -TargetIp, or -Region.' }
            Show-TargetCatalog
            return 0
        }
        if (-not [string]::IsNullOrWhiteSpace($Target) -and -not [string]::IsNullOrWhiteSpace($TargetIp)) { throw '-Target and -TargetIp cannot be combined.' }
        if ([string]::IsNullOrWhiteSpace($TargetIp) -and -not [string]::IsNullOrWhiteSpace($Region)) { throw '-Region is valid only with -TargetIp.' }
        if (-not [string]::IsNullOrWhiteSpace($Region)) {
            $Region = $Region.Trim().ToLowerInvariant()
            if ($Region -notin $script:RegionOrder) { throw "Unsupported Lightsail Region override '$Region'. Use -ListTargets." }
        }
        if ([string]::IsNullOrWhiteSpace($Target) -and [string]::IsNullOrWhiteSpace($TargetIp)) {
            $request = Read-InteractiveRequest
            if ($request.Action -eq 'Quit') { return 0 }
            $Target = $request.Target; $TargetIp = $request.TargetIp; $Region = $request.Region; $ProbePort = $request.ProbePort; $interactiveRegionResolution = $request.RegionDetection
        }
        if (-not [string]::IsNullOrWhiteSpace($TargetIp)) {
            $report = Invoke-RealIpValidation -Address $TargetIp -Port $ProbePort -RegionOverride $Region -SelectedMode $Mode -IcmpCount $IcmpSamplesPerRegion -TcpCount $TcpAttempts -IcmpTimeout $PingTimeoutMs -ConnectTimeout $ConnectionTimeoutMs -DelayMs $RoundDelayMs -TargetLimit $MaxTargetsPerRegion -JsonPath $OutputPath -WriteJson (-not $NoJson) -CachedTargetsOnly ([bool]$UseCachedTargets) -OmitTraceroute ([bool]$SkipTraceroute) -ConfirmationDelaySeconds $RetryDelaySeconds -RegionResolution $interactiveRegionResolution
            if (-not $report.Verdict.EvidenceComplete) { return 3 }
            return 0
        }
        $selection = Resolve-RegionSelection -Selection $Target
        $scope = Get-SelectionScope -Selection $selection
        $report = Invoke-AwsRegionSelection -SelectedMode $Mode -IcmpCount $IcmpSamplesPerRegion -TcpCount $TcpAttempts -TlsCount $TlsAttempts -IcmpTimeout $PingTimeoutMs -ConnectTimeout $ConnectionTimeoutMs -DelayMs $RoundDelayMs -TargetLimit $MaxTargetsPerRegion -JsonPath $OutputPath -WriteJson (-not $NoJson) -CachedTargetsOnly ([bool]$UseCachedTargets) -OmitTraceroute ([bool]$SkipTraceroute) -SelectedRegions $selection.Regions -Scope $scope -RecordHistory $true -Selection $selection.Normalized
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
