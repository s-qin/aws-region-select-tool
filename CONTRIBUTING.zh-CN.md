# 贡献指南

[English](CONTRIBUTING.md)

感谢你帮助改进 AWS Region Select Tool。请保持改动聚焦，并在开始前搜索现有 Issue。敏感漏洞请按安全策略报告，不要创建公开 Issue。

## 项目约束

- 主工具必须兼容 Windows PowerShell 5.1 与 PowerShell 7.x。
- 运行时保持零第三方模块依赖，不要求 AWS CLI、账号或凭据。
- 所有网络探测必须串行、有界、限速，禁止端口范围扫描、洪泛、压力测试或无限重试。
- 除非改动明确记录了兼容性破坏，否则保持现有 CLI、退出码、History 和 JSON 行为。
- 英文与简体中文用户文档必须保持语义等价。
- 禁止提交生成的报告、本地 History、凭据、Token、私钥或个人数据。

## 开发与测试

创建范围聚焦的分支，完成最小且完整的改动，并在两个受支持运行时执行确定性测试：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
pwsh.exe -NoProfile -File .\tests\run-tests.ps1
```

测试套件不得依赖公共网络的瞬时结果。网络行为发生变化时，应增加确定性 fixture，并只执行经过明确控制的有界 smoke test。不要公开未经脱敏的控制台输出或 JSON 报告。

面向用户的行为发生变化时，同步更新两份 README 与脚本帮助。用户可见改动应在 `CHANGELOG.md` 中添加简洁记录；仅修正文档且不影响用法或兼容性时无需添加。

## Pull Request

请向 `main` 提交 Pull Request，说明改动内容、原因和测试方式。避免在 diff 中混入无关修改，完成 PR 检查项，并由 GitHub Actions 验证 Windows PowerShell 5.1 与 PowerShell 7.x。
