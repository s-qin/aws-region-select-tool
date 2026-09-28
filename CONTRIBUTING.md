# Contributing

[简体中文](CONTRIBUTING.zh-CN.md)

Thanks for helping improve AWS Region Select Tool. Keep changes focused and search existing issues before starting. Use the security policy for sensitive vulnerabilities instead of a public issue.

## Project constraints

- Keep the main tool compatible with Windows PowerShell 5.1 and PowerShell 7.x.
- Keep runtime operation free of third-party modules, AWS CLI, accounts, and credentials.
- Keep all network probes serial, bounded, rate-limited, and free of port-range, flood, stress, or unbounded retry behavior.
- Preserve existing CLI, exit-code, history, and JSON behavior unless the change intentionally documents a compatibility break.
- Keep English and Simplified Chinese user documentation equivalent.
- Never commit generated reports, local history, credentials, tokens, private keys, or personal data.

## Develop and test

Create a focused branch, make the smallest complete change, and run the deterministic suite in both supported runtimes:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
pwsh.exe -NoProfile -File .\tests\run-tests.ps1
```

The test suite must not depend on live public-network results. If network behavior changes, add deterministic fixtures and perform only a deliberate, bounded smoke test. Do not publish unsanitized console output or JSON reports.

Update both READMEs and script help when user-facing behavior changes. Add a concise `CHANGELOG.md` entry for user-visible changes; documentation-only corrections do not require one unless they affect usage or compatibility.

## Pull requests

Open a pull request against `main` that explains what changed, why, and how it was tested. Keep unrelated edits out of the diff, complete the pull request checklist, and let GitHub Actions verify Windows PowerShell 5.1 and PowerShell 7.x.
