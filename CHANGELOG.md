# Changelog

All notable changes to this project are documented here.

## [2.0.1] - 2026-09-29

### Changed

- Interactive Real IP Validation now asks only for Target IPv4 when AWS Region detection succeeds.
- Region override is requested only when automatic longest-prefix detection cannot provide a supported Lightsail Region.
- Interactive validation silently uses TCP/22; advanced CLI callers can still use `-ProbePort` and `-Region`.

### Compatibility

- No scoring, probe-model, History, or JSON Schema changes.
- Windows PowerShell 5.1, PowerShell 7.x, Global/Targeted scans, and non-interactive Real IP CLI behavior remain supported.

## [2.0.0] - 2026-09-28

### Added

- Controlled catalog for 19 currently documented Amazon Lightsail Regions.
- Interactive main menu, `-Target`, `-ListTargets`, five Region groups, and custom Region sets.
- Adaptive Auto planner with Quick screening and Standard validation for up to five finalists.
- Separate screening, finalist, and recommendation ranks with complete unavailable-Region evidence.
- Report JSON Schema 2.0 and aggregate History Schema 2.0 with v1 history migration.
- Minimal Windows CI for Windows PowerShell 5.1 and PowerShell 7.x.

### Changed

- **Breaking:** no-argument execution now opens the interactive menu. Use `-Target us-all -Mode Standard` for the v1.x US baseline equivalent.
- **Breaking:** Region Probe reports now use Schema 2.0 and stage-specific fields.
- Default Region Probe mode is now `Auto`.
- Reachability failures are isolated per Region instead of forcing whole-set fallback.
- Quick-only history evidence triggers a single-Region Standard refresh before Real IP comparison.
- Project positioning, bilingual documentation, Help, and GitHub facade now cover global Lightsail Region selection.

### Compatibility

- Preserves v1.1 `-TargetIp`, `-ProbePort`, Real `-Region`, longest-prefix AWS detection, Fresh/Usable/Stale/Missing semantics, bounded atomic history, and KEEP/RETEST/RETRY confirmation.
- Continues to support Windows PowerShell 5.1 and PowerShell 7.x without third-party runtime dependencies.

### Safety

- Probes remain serial and bounded; no AWS resources, firewalls, credentials, throughput tests, or stress tests are used.

## [1.1.0] - 2026-09-14

### Added

- Real AWS/Lightsail IPv4 validation, AWS longest-prefix Region detection, aggregate baseline history, single-Region refresh, metric deltas, and conservative KEEP/RETEST/RETRY verdicts.

## [1.0.0] - 2026-09-13

### Added

- Initial three-US-Region baseline selection with ICMP, TCP, TLS, traceroute, scoring, confidence, and JSON reporting.

[2.0.1]: https://github.com/s-qin/aws-region-select-tool/releases/tag/v2.0.1
[2.0.0]: https://github.com/s-qin/aws-region-select-tool/releases/tag/v2.0.0
[1.1.0]: https://github.com/s-qin/aws-region-select-tool/commits/2a179946974e2dcb89a42dda7ba2864c3a38d89b
[1.0.0]: https://github.com/s-qin/aws-region-select-tool/commits/b4a1b436c541150dc7f8ee2d73ebc3aa2b766ba4
