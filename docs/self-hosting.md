# 自部署 DDL Killer

本文说明如何从源码运行自己的实例。推荐先在本机启动一个账号，确认任务、课表和同步正常，再配置公网域名、邮件或 AI。

仓库根目录的 [`docker-compose.yml`](../docker-compose.yml) 与 [`Caddyfile`](../Caddyfile) 是本机自部署示例，使用 `https://localhost:8443`，不包含官方生产部署脚本或个人服务器配置。下面用独立文件名保存配置，便于更新源码时保留自己的设置；示例地址 `tasks.example.com` 均需换成自己的域名。

## 能运行哪些功能

| 功能 | 需要什么 |
| --- | --- |
| 账号、清单、任务、日历、课表导入和跨设备同步 | 自己的后端和 SQLite 数据库 |
| 已登录后的离线查看、编辑及恢复联网后的同步 | 先联网登录并同步；数据缓存在当前浏览器或设备 |
| 首个账号 | 空数据库的一次性初始化接口，不需要发信服务 |
| 后续用户自助注册、绑定邮箱、邮箱找回密码 | 腾讯云 SES 发信凭据、已验证发信地址和已审核模板 |
| AI 助手，使用用户自己的 Key | 启用 AI、配置服务端加密主密钥；用户填写自己的模型服务 Key |
| 实例提供的托管 AI 额度 | 额外配置实例自己的 DeepSeek Key 和预算上限 |
| MCP | `public-mcp` 网关和用户授权或手动令牌；不要求 AI Key |
| 语音转文字 | 单独启用语音服务并配置硅基流动 Key |
| 浏览器后台推送 | HTTPS、浏览器授权、后端持续运行以及到浏览器推送服务的网络连接 |

这不是无后端的游客应用：第一次使用仍要连接自己的服务。断网期间，账号、AI、邮件、MCP等在线功能不可用；不要把浏览器缓存当作唯一备份。

## 1. 准备工具并构建 Web

需要：

- Git。
- Docker Engine 或 Docker Desktop，以及 `docker compose`。
- Flutter SDK，其内置 Dart 须满足 `app/pubspec.yaml` 的 `^3.13.0` 约束。
- Python 3，用于每次 Web 构建后生成离线 worker。下面使用 `python`，Linux/macOS 若命令为 `python3`，请相应替换。
- 构建 APK 时还需要 Android SDK、相应 Java 工具链，可用 `flutter doctor` 检查。
- Node.js 24，用于检查 Web 离线资源；直接运行后端源码也使用此版本。Docker 后端镜像已使用 Node 24。

在克隆后的仓库根目录操作。先构建 Flutter Web：

```sh
cd app
flutter pub get
flutter build web --release --pwa-strategy=none --no-web-resources-cdn --dart-define=RELEASE_CHANNEL=stable
python tool/build_offline_worker.py
node tool/offline_worker_test.mjs
cd ..
```

产物是 `app/build/web/`。必须在 Flutter 构建完成后执行 `build_offline_worker.py`，生成 `app/build/web/offline-sw.js`；项目使用自己的离线 worker，`--pwa-strategy=none` 不会替它生成。随后运行的 Node 检查会验证资源存在、离线入口、字体缓存和 API 排除规则。

Web 默认使用打开页面时的同源地址访问 API，因此下面不需要给 Web 指定 `API_BASE`。不要将 Web 页面和 API 随意拆到两个来源：当前账号接口没有提供通用跨域 CORS 配置。

`--no-web-resources-cdn` 使 Flutter Web 的运行资源随构建产物部署。`app/web/app-update.json` 仍是上游更新信息，且当前更新模块会限制下载地址；自部署版本的更新入口需另行适配，见最后的限制说明。

## 2. 创建本地环境文件

在仓库根目录新建 `.env.self-host`，填入以下内容。该文件名已被仓库的 `.gitignore` 忽略。

```dotenv
JWT_SECRET=REPLACE_WITH_FIRST_RANDOM_SECRET
MCP_TOKEN_PEPPER=REPLACE_WITH_SECOND_RANDOM_SECRET
PUBLIC_ORIGIN=https://localhost:8443
APP_ORIGIN=https://localhost:8443
LEGACY_PUBLIC_ORIGIN=
NODE_ENV=production
TZ=Asia/Shanghai
AI_FEATURE_ENABLED=false
AI_HOSTED_ENABLED=false
ASR_ENABLED=false
```

`JWT_SECRET` 和 `MCP_TOKEN_PEPPER` 分别生成，至少 32 字符，不要复用。若本机有 Node，可分别执行两次：

```sh
node -e "console.log(require('node:crypto').randomBytes(32).toString('hex'))"
```

这些输出是自己的秘密，只写入私有环境文件；不要把真实值提交进 Git。本机的环境文件、部署配置和生成的证书材料也不应作为上游贡献提交。生产模式下，缺少 JWT 或 MCP 密钥会拒绝启动，即使暂时不用 MCP，也要配置 `MCP_TOKEN_PEPPER`。

`PUBLIC_ORIGIN` 必须是浏览器实际访问的完整来源，包含协议和非默认端口，末尾不加 `/`，不能带 `/api`。`APP_ORIGIN` 是允许登录的额外来源；下面与主来源一致。无需保留上游的域名为允许来源。

## 3. 创建独立 Compose 和 Caddy 配置

完成前两节的 Web 构建和环境配置后，根目录 Compose 可直接使用随仓库提供的 `Caddyfile`。长期维护自己的实例时，建议把配置保存为不受源码更新影响的独立文件：

```sh
cp docker-compose.yml compose.self-host.yaml
cp Caddyfile Caddyfile.self-host
```

然后在复制后的 `compose.self-host.yaml` 中，将 Caddy 挂载源从 `./Caddyfile` 改为 `./Caddyfile.self-host`，再按下面的完整示例核对。后续命令都使用这份独立配置。根目录 Compose 还声明了名为 `internal` 的容器网络；它不限制容器访问外部模型服务。

`compose.self-host.yaml` 的完整示例如下：

```yaml
services:
  plan-api:
    build: ./backend
    restart: unless-stopped
    env_file: .env.self-host
    environment:
      PORT: "3000"
      DB_PATH: /app/data/plan.db
      SCHEDULE_PATH: /app/no-legacy-schedule.json
    volumes:
      - ddl_data:/app/data

  public-mcp:
    build:
      context: ./mcp-server
      dockerfile: public/Dockerfile
    restart: unless-stopped
    user: node
    read_only: true
    security_opt:
      - no-new-privileges:true
    tmpfs:
      - /tmp:rw,noexec,nosuid,size=16m
    environment:
      NODE_ENV: production
      PORT: "8787"
      PLAN_INTERNAL_BASE: http://plan-api:3000
      PUBLIC_ORIGIN: ${PUBLIC_ORIGIN:?PUBLIC_ORIGIN is required}
    depends_on:
      - plan-api

  caddy:
    image: caddy:2
    restart: unless-stopped
    ports:
      - "127.0.0.1:8443:8443"
    volumes:
      - ./Caddyfile.self-host:/etc/caddy/Caddyfile:ro
      - ./app/build/web:/srv/web:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - plan-api
      - public-mcp

volumes:
  ddl_data:
  caddy_data:
  caddy_config:
```

后端的 `3000` 和 MCP 的 `8787` 只在 Compose 网络中可达，不映射到宿主机。`SCHEDULE_PATH` 指向不存在的迁移文件，防止套用上游的旧全局课表；正常课表由用户在应用中导入并存入自己的数据库。

`Caddyfile.self-host` 的完整示例如下：

```caddyfile
https://localhost:8443 {
    tls internal
    encode gzip
    header {
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Referrer-Policy "no-referrer"
        Permissions-Policy "geolocation=(), microphone=(self)"
    }

    handle /api/internal/* {
        respond "Not found" 404
    }
    handle /api/* {
        reverse_proxy plan-api:3000 {
            header_up X-Forwarded-For {remote_host}
        }
    }
    handle /mcp {
        reverse_proxy public-mcp:8787
    }
    handle /.well-known/oauth-protected-resource* {
        reverse_proxy public-mcp:8787
    }
    handle /.well-known/oauth-authorization-server {
        reverse_proxy plan-api:3000
    }
    handle /oauth/authorize {
        root * /srv/web
        rewrite * /index.html
        file_server
    }
    handle {
        root * /srv/web
        header Cache-Control "no-cache, no-store, must-revalidate"
        try_files {path} /index.html
        file_server
    }
}
```

保持 `/api/internal/*` 的拒绝规则：MCP 网关会通过容器网络调用内部接口，这些接口不能暴露给外部。这里的 `X-Forwarded-For` 覆写适用于客户端直接连接 Caddy；添加 CDN 或其他代理时，应重新设置可信代理和真实客户端地址，不能直接信任请求中任意传来的地址。

## 4. 启动并信任本机 HTTPS 证书

以下命令均在仓库根目录执行：

```sh
docker version
docker compose --env-file .env.self-host -f compose.self-host.yaml config --quiet
docker compose --env-file .env.self-host -f compose.self-host.yaml up -d --build
docker compose --env-file .env.self-host -f compose.self-host.yaml ps
docker compose --env-file .env.self-host -f compose.self-host.yaml logs --tail=50 plan-api caddy
```

`docker version` 应同时显示 Client 和 Server 信息。只显示 Client、提示无法连接 daemon 时，说明 Docker 引擎还没有正常运行；先解决 Docker 的启动问题，再执行 Compose。`config --quiet` 只检查配置能否解析，不代表镜像已经构建或服务已经启动。

浏览器账号使用 `Secure`、`HttpOnly` Cookie，应使用 HTTPS。Caddy 为本机生成的 CA 需要安装到自己的可信证书库，不能只忽略浏览器的证书报错。

导出本次实例的 CA 公钥证书：

```sh
docker compose --env-file .env.self-host -f compose.self-host.yaml cp caddy:/data/caddy/pki/authorities/local/root.crt ./caddy-local-root.crt
```

Windows PowerShell 可将这个证书导入当前用户的受信任根证书库：

```powershell
Import-Certificate -FilePath ./caddy-local-root.crt -CertStoreLocation Cert:\CurrentUser\Root
```

Debian/Ubuntu 可使用系统证书库：

```sh
sudo cp caddy-local-root.crt /usr/local/share/ca-certificates/ddl-local.crt
sudo update-ca-certificates
```

其他系统按其证书管理方式安装；部分浏览器或 MCP 客户端还使用独立的证书库。仅信任自己刚生成的实例 CA，并保护 `caddy_data` 卷中的 CA 私钥。

打开 `https://localhost:8443`。也可以访问 `https://localhost:8443/api/auth/email/config`，未接邮件时应返回：

```json
{"enabled":false,"registration_requires_email":true}
```

如果只想先检查 HTTPS 和 API，无需把证书导入系统，可以让本次命令单独信任导出的 CA：

```sh
curl --cacert ./caddy-local-root.crt https://localhost:8443/api/health
```

应返回 `{"ok":true}`。Windows PowerShell 中请使用 `curl.exe`，避免旧版 PowerShell 将 `curl` 解释为另一个命令。不要用 `-k` 跳过证书验证来判断 HTTPS 是否配置成功；浏览器日常使用仍需完成前面的信任设置。

## 5. 初始化第一个账号

当前注册界面要求验证邮箱。只想先用一个账号时，可以调用仅在 `users` 表为空时有效的 `/api/auth/setup`。它创建普通账号及默认清单，不是额外的管理员角色，也不会自动登录。

在 Windows PowerShell 中执行，用户名和密码通过交互输入，不直接写进命令历史：

```powershell
$firstUser = Read-Host '用户名（2-32位字母、数字或下划线）'
$firstPassword = Read-Host '密码（至少12字符，最多72 UTF-8字节）' -AsSecureString
$plainPassword = [System.Net.NetworkCredential]::new('', $firstPassword).Password
$setupBody = @{username=$firstUser; password=$plainPassword} | ConvertTo-Json
Invoke-RestMethod -Method Post -Uri 'https://localhost:8443/api/auth/setup' -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($setupBody))
Remove-Variable firstPassword,plainPassword,setupBody
```

Linux/macOS 如果已装 Python 3，可在仓库根目录执行：

```sh
python3 - <<'PY'
import getpass, json, ssl, urllib.request
body = json.dumps({
    'username': input('Username: '),
    'password': getpass.getpass('Password (at least 12 characters): '),
}).encode('utf-8')
request = urllib.request.Request(
    'https://localhost:8443/api/auth/setup',
    data=body,
    headers={'Content-Type': 'application/json'},
    method='POST',
)
context = ssl.create_default_context(cafile='caddy-local-root.crt')
with urllib.request.urlopen(request, context=context) as response:
    print(response.status, response.read().decode())
PY
```

成功返回 `{"ok":true}`。回到网页，用刚创建的账号登录。再次初始化返回 HTTP 403“已初始化”，这是正常行为。至少完成一次任务创建、刷新页面和重新登录，确认数据持久化。

新实例第一次开放访问前，先完成初始化，避免由其他人先创建首个账号。下面公网部署前仍建议保留本机绑定，完成初始化后再开放端口。

### 本机启动后的验收

先关闭邮件、AI 和语音等外部服务，只检查基本功能，避免把外部服务配置问题混在一起：

1. 打开网页并登录，确认页面、字体和图标正常，能看到默认清单。
2. 新建一条任务，设置截止日期并安排一个时间段；刷新网页，核对任务与日历中的安排。
3. 导入仓库提供的[虚构演示课表](examples/timetable-demo.json)，核对课程日期和时间；不要拿他人的真实课表做公开测试材料。这个演示文件的学期日期固定，查看时切到文件对应的日期。
4. 将任务标记为完成，在“已完成”中找到它，再取消完成，确认能恢复到原清单。
5. 在这台设备启用离线数据并等待首次同步完成；断网修改一条任务，再恢复联网，等同步完成后重新登录核对。另开一个已联网的设备或浏览器核对同一条记录，可以进一步确认跨设备同步。
6. 执行下面的停止命令，再按第 4 节启动；重新登录，确认任务、课表和安排还在。这个检查需要保留数据卷，不能使用 `down -v`。

```sh
docker compose --env-file .env.self-host -f compose.self-host.yaml down
docker compose --env-file .env.self-host -f compose.self-host.yaml up -d
```

需要 MCP 时，再按第 9 节创建只读令牌，确认客户端能读清单且没有写入工具；用可安排权限测试“生成草案 → 查看 → 确认”，确认草案生成时不会立即改动日程，最后撤销令牌并检查连接确实失效。

## 6. 配置自己的公网域名

本机示例仅监听 `127.0.0.1:8443`，手机和其他设备不能访问。对外部署时：

1. 将自己的域名解析到服务器，并允许访问服务器的 TCP 80/443。
2. 把 Caddy 站点地址改成自己的域名，例如 `tasks.example.com`，删除 `tls internal`，让 Caddy 为该域名申请公开可信证书。
3. 把 Compose 中 Caddy 的端口映射改为服务器实际监听地址的 `80:80` 和 `443:443`。只运行此站点的服务器可使用 `"80:80"`、`"443:443"`；与其他服务共用机器时，选择明确的监听 IP。
4. 在 `.env.self-host` 同时更新 `PUBLIC_ORIGIN=https://tasks.example.com`、`APP_ORIGIN=https://tasks.example.com`。
5. 重新执行 `docker compose --env-file .env.self-host -f compose.self-host.yaml up -d`。

保持 API 与 Web 同源。若使用 CDN、反向代理或隧道，还要检查其 TLS 模式、客户端 IP 转发和缓存；账号及 AI 接口不得缓存。模板没有要求使用任何特定 CDN。

`PUBLIC_ORIGIN` 同时用于 OAuth 发行者和 MCP 服务发现。更换来源后需要重新检查登录、MCP授权，并根据客户端情况重新连接；不要让网关和后端使用不同的值。

## 7. 可选：邮件注册与找回密码

当前邮件实现对接腾讯云 SES，没有 SMTP 配置入口。在自己的腾讯云账号中准备：

- SES 支持区域：`ap-hongkong` 或 `ap-guangzhou`。
- 已验证的发信域名和发信邮箱，按服务商要求配置 DNS 验证记录。
- 可调用 `SendEmail` 的凭据，建议限制到发信所需权限。
- 已审核通过的五个模板：注册验证码、绑定验证码、重置密码验证码、密码变更通知、邮箱变更通知。

给 `.env.self-host` 添加：

```dotenv
TENCENT_SES_SECRET_ID=REPLACE_WITH_YOUR_ID
TENCENT_SES_SECRET_KEY=REPLACE_WITH_YOUR_SECRET
TENCENT_SES_REGION=ap-hongkong
TENCENT_SES_FROM=no-reply@example.com
TENCENT_SES_TEMPLATE_REGISTER=REPLACE_WITH_NUMERIC_TEMPLATE_ID
TENCENT_SES_TEMPLATE_BIND=REPLACE_WITH_NUMERIC_TEMPLATE_ID
TENCENT_SES_TEMPLATE_RESET=REPLACE_WITH_NUMERIC_TEMPLATE_ID
TENCENT_SES_TEMPLATE_PASSWORD_CHANGED=REPLACE_WITH_NUMERIC_TEMPLATE_ID
TENCENT_SES_TEMPLATE_EMAIL_CHANGED=REPLACE_WITH_NUMERIC_TEMPLATE_ID
EMAIL_DAILY_LIMIT=100
BETA_EMAIL_RECIPIENTS=
```

全部必需配置有效才会启用：模板 ID 必须是数字，发件人必须是纯邮箱地址，不能附带显示名。前三种验证码模板接收 JSON 参数 `{"code":"六位验证码"}`，正文应使用服务商对应的 `code` 模板变量；两个安全通知模板接收 `{}`。验证码有效期为 10 分钟。HTML 和纯文本版本都应写清用途。

修改环境后重建容器配置：

```sh
docker compose --env-file .env.self-host -f compose.self-host.yaml up -d plan-api
```

重新打开 `/api/auth/email/config`，确认 `enabled:true`，再用自己能收信的邮箱走完“获取验证码 → 收信 → 填码 → 注册 → 登录”。配置检查成功、SES 接受发信请求都不等于邮件已进入收件箱。

邮件留空不会阻止后端启动；相关发码操作会返回服务不可用。首个初始化账号可以在邮件启用后绑定邮箱。正式实例不要设置 Beta 收件人白名单，也不要设置 `APP_CHANNEL=beta`。

## 8. 可选：AI 与语音

### 用户自己的模型 Key

在 `.env.self-host` 启用 AI，并配置独立的 32 字节加密密钥：

```dotenv
AI_FEATURE_ENABLED=true
AI_HOSTED_ENABLED=false
AI_KEY_ENCRYPTION_KEYS=v1:REPLACE_WITH_BASE64_32_BYTES
```

生成该密钥：

```sh
node -e "console.log(require('node:crypto').randomBytes(32).toString('base64'))"
```

按前节命令重新创建 `plan-api` 容器。登录后打开 AI 设置，选择“自己的 Key”，填入服务地址、模型名及 Key，再测试连接。密钥以 AES-256-GCM 加密后存入 SQLite，由自己的服务器解密并调用模型服务；浏览器不会直接调用模型厂商。

DeepSeek 支持的基础地址为 `https://api.deepseek.com` 或 `https://api.deepseek.com/v1`。自定义服务须兼容 Chat Completions；基础地址不要以 `/chat/completions` 结尾，后端会自动拼接。为防止请求访问实例内网，目前只允许解析到公网地址的域名、HTTPS 和 443 端口，拒绝 IP 字面量、localhost、内网地址及其他端口。因此不能直接填写本机 Ollama 或局域网模型端点。

备份数据库时同时备份加密密钥环。丢失主密钥后，数据库中的用户 Key 无法恢复。密钥环逗号分隔，第一项加密新数据，其余项解密历史数据；不要直接覆盖仍被历史记录使用的版本。

### 实例托管 AI

如果希望由自己的实例承担模型费用，再添加：

```dotenv
AI_HOSTED_ENABLED=true
AI_HOSTED_DEEPSEEK_KEY=REPLACE_WITH_YOUR_DEEPSEEK_KEY
AI_HOSTED_MODEL=deepseek-flash
AI_HOSTED_DAILY_LIMIT=3
AI_HOSTED_GLOBAL_DAILY_LIMIT=30
AI_HOSTED_GLOBAL_ATTEMPT_LIMIT=60
AI_HOSTED_TOKEN_DAILY_LIMIT=100000
AI_FAILURE_COOLDOWN_SECONDS=30
```

以上是小规模试运行的示例上限，应按自己的预算调整，不能视为服务商价格或费用保证。请为 `AI_HOSTED_GLOBAL_DAILY_LIMIT` 设置正整数，不留空，以限制全站每日额度。托管 Key 属于部署者；各用户自己的 Key 仍可单独配置。不需要邀请码机器人也可以运行基本 AI 功能。

### 语音转文字

文本 AI 不依赖语音服务。语音也要求 `AI_FEATURE_ENABLED=true`；启用文本 AI 后，再配置：

```dotenv
ASR_ENABLED=true
ASR_SILICONFLOW_KEY=REPLACE_WITH_YOUR_KEY
ASR_USER_DAILY_SECONDS=600
ASR_GLOBAL_DAILY_SECONDS=3600
```

重新创建 `plan-api` 容器；Web 还需要可信 HTTPS 和麦克风权限。该实现使用服务端硅基流动 Key，不是从用户的文本模型配置中取 Key。

## 9. 可选：MCP 连接

模板已启动隔离的 `public-mcp` 服务。连接地址是自己的 `https://tasks.example.com/mcp`，本机则是 `https://localhost:8443/mcp`。网关只访问 `PLAN_INTERNAL_BASE=http://plan-api:3000`，不要给它挂载数据库。

在应用的“智能体连接”中创建手动令牌，选择必要权限并设置到期时间。在支持 Streamable HTTP 的客户端填入自己的地址，并设置：

```text
Authorization: Bearer <自己刚创建的令牌>
```

令牌只显示一次，妥善保存；连接失效或不再使用时，在应用内撤销。支持 OAuth 的客户端可通过服务发现和浏览器授权连接；本机自签 CA 也必须被该客户端信任，公网可信证书更适合跨设备连接。

当前应用的连接说明里仍显示上游 MCP 地址，部署者要主动改用自己的地址。公共网关使用 `mcp-server/public/server.mjs`；根目录的 `mcp-server/server.mjs` 是旧的账号密码集成，不是这套 PAT/OAuth 网关，不要混用。

## 10. 构建自己的 Android APK

后端应先部署到手机可达且证书可信的 HTTPS 地址。Android 明确禁用了明文 HTTP；手机上的 `localhost` 指手机自己，不能用本机示例地址连接电脑。正式 APK 默认不信任随意安装的自签 CA，推荐使用自己的域名和公开可信证书。

调试 APK 不需要发行签名：

```sh
cd app
flutter build apk --debug --flavor stable --dart-define=RELEASE_CHANNEL=stable --dart-define=API_BASE=https://tasks.example.com
```

调试产物是 `build/app/outputs/flutter-apk/app-stable-debug.apk`。

发行 APK 必须准备自己的签名密钥。在仓库外的私有目录运行，例如：

```sh
keytool -genkeypair -v -keystore ddl-release.jks -alias ddl-release -keyalg RSA -keysize 2048 -validity 10000
```

交互输入密钥密码，再在同一私有目录新建 `signing.properties`：

```properties
storeFile=/absolute/private/path/ddl-release.jks
storePassword=YOUR_STORE_PASSWORD
keyAlias=ddl-release
keyPassword=YOUR_KEY_PASSWORD
```

Windows 的 `storeFile` 建议使用绝对路径和 `/`。设置 `DDL_SIGNING_PROPERTIES` 为该文件的绝对路径，例如 PowerShell：

```powershell
$env:DDL_SIGNING_PROPERTIES = 'C:/private/ddl/signing.properties'
```

或 Linux/macOS：

```sh
export DDL_SIGNING_PROPERTIES=/absolute/private/path/signing.properties
```

在 `app/` 目录构建：

```sh
flutter build apk --release --flavor stable --dart-define=RELEASE_CHANNEL=stable --dart-define=API_BASE=https://tasks.example.com
```

产物是 `build/app/outputs/flutter-apk/app-stable-release.apk`。缺少签名配置时，项目会主动拒绝 release 构建。升级自己的 APK 必须保留同一签名密钥和 applicationId，后续发行需增加 `pubspec.yaml` 的内部版本号。官方源码保留已发布的 applicationId 以兼容升级；独立分发的 fork 应在首次发行前设置自己的 Android applicationId。

请使用上面的命令构建自部署 APK，并核对自己的 API 来源。`RELEASE_CHANNEL=beta` 也会覆盖 `API_BASE` 并选择上游测试服务；自己的实例使用上述 stable 命令。

## 数据、更新与停止

后端会自动清理进入回收站超过 7 天、或已完成超过 3 天的任务；这些时限当前写在 `backend/src/retention.js` 中，没有环境变量开关。需要长期归档时，另行定期导出或备份。

SQLite 及浏览器推送密钥保存在 `ddl_data` 卷。卷名带 Compose 项目前缀，可用 `docker volume ls` 查看。数据库默认路径为容器内 `/app/data/plan.db`；源码直接运行时默认是 `backend/data/plan.db`，并会自动执行表结构迁移。

简单的停机备份流程：先停止服务，再复制整个数据目录，备份完恢复启动，避免只复制正在写入的 SQLite 主文件：

```sh
docker compose --env-file .env.self-host -f compose.self-host.yaml stop plan-api
docker compose --env-file .env.self-host -f compose.self-host.yaml cp plan-api:/app/data ../ddl-data-backup
docker compose --env-file .env.self-host -f compose.self-host.yaml start plan-api
```

示例备份目录 `../ddl-data-backup` 位于仓库外，包含个人数据；按自己的需要改成其他仓库外的私有备份目录。另行备份环境文件和签名密钥，不要上传这些材料。恢复备份或升级前先停止写入，保留原始数据卷和环境文件；首次恢复后检查登录、任务、课表、AI Key 及邮件配置。

更新源码后，重新执行第 1 节完整的 Web 构建步骤，包括在 `app/` 中生成离线 worker 并检查通过，然后重建容器。每次构建都会改变离线资源列表和缓存版本，不能沿用上一次的 `offline-sw.js`。不要删除旧数据卷；浏览器缓存有未同步内容时先完成同步或导出。

停止并保留数据：

```sh
docker compose --env-file .env.self-host -f compose.self-host.yaml down
```

不要给日常停止命令加 `-v`，该参数会删除数据卷。浏览器推送 VAPID 密钥由后端自动生成并保存在数据目录；Android 本机提醒使用系统通知权限，浏览器后台推送则依赖服务端和浏览器提供商，无法保证纯离线送达。

## 当前自部署限制

- 根目录 Compose/Caddy 是本机示例；公网域名、证书、代理信任和备份仍需部署者独立配置。
- `API_BASE` 只替换业务 API；应用内下载、更新检测、MCP说明、API Key教程、课表教程及部分分享或隐私链接仍包含上游地址。完整独立发行需要在 fork 中审阅并替换这些入口和相关政策内容；自建 APK 不能沿用上游签名或更新渠道。
- 邮件仅实现腾讯云 SES；普通注册必须验证邮箱。没有邮箱服务时可初始化一个账号，但没有面向多用户的免邮件注册开关或 SMTP 适配。
- AI 自定义地址的公网 HTTPS 限制使本地或内网模型不能直接接入。目前也没有纯浏览器、无后端的 AI Key 模式。
- Web 和 Android 是本文核实的构建目标；仓库中的其他平台目录不代表已经完成发布适配。运行时的业务语言主要为中文。

## 启动失败时先检查什么

| 现象 | 检查方法 |
| --- | --- |
| 无法连接 Docker daemon，或 Docker Desktop 自己弹出启动错误 | 先运行 `docker version`，确认 Server 可用。此时应用容器尚未启动，先按 Docker 官方排障说明处理；不要为启动应用直接恢复出厂设置或删除已有卷。 |
| Compose 提示环境变量或环境文件不存在 | 确认在仓库根目录执行、`.env.self-host` 已创建，且命令包含 `--env-file .env.self-host`；不要把真实配置贴到公开 Issue。 |
| Caddyfile 被当成目录，或挂载失败 | 确认 `Caddyfile.self-host` 是存在的文件，并且独立 Compose 中的挂载源已经改成 `./Caddyfile.self-host`。 |
| 网页空白，或找不到 `main.dart.js`、字体、`offline-sw.js` | 重新完成第 1 节构建及离线 worker 检查，确认 `app/build/web/` 中存在实际产物；只创建空目录不能代替构建。 |
| 证书报错 | 核对访问地址、端口和导出的 CA 是否属于当前实例；不要混用其他实例的 CA，也不要用忽略证书验证作为长期方案。 |
| API 返回 502 | 查看 `plan-api`、`public-mcp`、`caddy` 日志和容器状态，确认后端没有因缺少密钥或数据库写入失败而退出；启动瞬间的短暂 502 应在后端就绪后消失。 |
| 登录或修改操作返回“不受信任的来源” | 检查 `PUBLIC_ORIGIN`、`APP_ORIGIN` 与浏览器地址栏的协议、域名、端口完全一致；修改环境后重新创建 `plan-api` 容器。 |
| 未配置邮件时不能注册 | 这是当前注册要求；先按第 5 节初始化一个账号，多用户注册再配置邮件服务。 |

日志检查命令：

```sh
docker compose --env-file .env.self-host -f compose.self-host.yaml ps
docker compose --env-file .env.self-host -f compose.self-host.yaml logs --tail=100 plan-api public-mcp caddy
```

分享日志前删去邮箱、令牌、私有地址和个人任务内容；不要上传环境文件、数据库或 CA 私钥。Docker 自身的启动问题可参考 [Docker Desktop 官方排障说明](https://docs.docker.com/desktop/troubleshoot/overview/)。

## 已核实的范围

2026-10-10 从公开 Git 快照导出干净副本，重新安装依赖并构建 Flutter Web，生成的离线 worker 通过 63 个本地资源及更新生命周期检查；根 Compose 与复制后修改挂载源的独立配置均通过 `docker compose config`，公开 Caddy 配置通过实际 Caddy 校验。在隔离的本机 Node 24 与 Caddy 进程中，以实例 CA 验证真实 HTTPS，完成空库初始化、重复初始化拒绝、Web 登录 Cookie、来源校验、任务/排期/虚构课表、同步重试幂等、完成与撤销、重启后的 SQLite 数据和会话持久化，以及 MCP 只读权限、草案确认、令牌撤销和 OAuth PKCE 流程验收。

上述本机进程验收不等于容器验收：该次测试机器的 Docker Desktop 在启动自身 Inference 服务时失败，没有运行 Compose 容器或检验 Docker 卷。完整 Docker 构建、容器重建后的数据卷、浏览器真实离线交互、Android APK 和公网域名证书仍需在可用环境中完成。邮件实收、外部模型和语音调用也应由部署者按自己的服务配置分别验收；不要把本文核对记录视为已经替自己的环境部署成功。
