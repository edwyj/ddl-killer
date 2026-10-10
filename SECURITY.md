# 安全问题反馈

请优先使用最新正式版本。维护者会优先检查最新正式版中的安全问题；Beta 用于测试，不应存放唯一一份重要数据。

## 私下报告

发现可能泄露数据、绕过认证或权限检查、暴露 API Key 等问题时，请私下报告。

请优先通过仓库的 **Security → Report a vulnerability** 私下提交，避免把细节放进公开 Issue。该入口仅在维护者启用 GitHub 私密漏洞报告后出现；如果看不到入口，请使用下面的临时渠道。配置方法见 [GitHub 官方说明](https://docs.github.com/en/code-security/security-advisories/working-with-repository-security-advisories/configuring-private-vulnerability-reporting-for-a-repository)。

若仓库尚未提供上述入口，已注册用户可登录 [应用](https://app.ddlkiller.com)，通过应用内“反馈”提交安全问题，由维护者私下查看；不要附上有效凭据或他人个人数据。此时尚未注册的报告者请等待 GitHub 私密报告入口开放，不要把漏洞细节发到公开 Issue。

请提供受影响版本、复现所需前提、尽可能少的复现步骤和影响范围。使用你自己的测试账号和测试数据，不要访问他人数据或对线上服务进行破坏性验证。

不要在公开 Issue、讨论或截图中发布有效令牌、密码、邮箱验证码、数据库、真实个人数据或可直接利用的漏洞细节。如果误泄露凭据，请先撤销或轮换，再联系维护者；仅删除文件或消息不能撤回已经传播的秘密。

项目由个人维护，暂不承诺固定响应时限或提供漏洞奖励。是否需要协调披露，可在私下沟通中商定。

## 自部署

自部署实例由部署者管理。请独立生成 JWT、MCP 与 AI Key 加密密钥，限制数据目录和备份权限，并配置 HTTPS。不要直接复制维护者的生产部署参数。配置要求与当前限制见 [自部署说明](docs/self-hosting.md)。
