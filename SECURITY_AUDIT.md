# Shannon 静态安全审计

审计日期：2026-11-09

审计对象：`Silver-cybersec/shannon`（fork 自 `KeygraphHQ/shannon`）

审计提交：`4cef63e5900c9eda0b259a44f89458c7f8b1e10d`（`main`）

上游对照：GitHub compare `KeygraphHQ/shannon:main...Silver-cybersec/shannon:main` 结果为 `identical`（ahead 0，behind 0）。该提交的作者是上游维护者，提交说明为 `fix: validate workspace names and restrict target URLs to HTTP/HTTPS (#515)`。本树没有 fork 侧新增提交。

## 审计方法与边界

只做静态阅读，没有执行本仓库的安装脚本、CLI、worker、测试、Docker 构建或镜像。没有安装依赖，没有对任何扫描目标发请求。

额外使用的只读材料：

- npm registry 上 464 个锁文件条目的版本元数据（`dist.integrity`、`dist.tarball`、生命周期 `scripts`、`repository`、`deprecated`），并与 `pnpm-lock.yaml` 的 `sha512` 对照。
- OSV `https://api.osv.dev/v1/querybatch` 对这 464 个 `npm` 版本的查询，以及命中通告的摘要。OSV 按给定版本返回其认为受影响的通告。本审计没有逐条重算 `affected` 范围，因此「OSV 判定受影响」与「该代码路径在 Shannon 里一定能走到」是两件事，后者单独标未确认。
- Docker Hub 上 `temporalio/temporal:1.7.0` 的 tag 元数据。
- GitHub 上 Typst `v0.14.2` 的 release 资产列表，以及本仓库 workflow 里 Actions SHA 与对应 tag 的对应关系。
- 为核对安装钩子和外联，下载并阅读了下列已发布 tarball 的源码，没有执行其中任何脚本：`@swc/core@1.15.18` 的 `postinstall.js`、`protobufjs@7.5.5` 的 `scripts/postinstall.js`、`@earendil-works/pi-telemetry@0.84.4`、`@earendil-works/pi-ai@0.84.4`、`@earendil-works/pi-coding-agent@0.84.4`（检索目录刷新与遥测）、`@gotgenes/pi-permission-system@10.9.0` 的包清单、`@playwright/cli@0.1.1`、`pnpm@10.33.0` 的 `package.json` scripts。

仓库内带 NUL 的文件只有 PNG/GIF 图片。没有可执行文件、没有 `.gitmodules`。没有对图片做隐写分析，隐写风险标未确认。

## 总结论

| 问题 | 结论 |
| --- | --- |
| 是否含针对操作者的隐藏后门、混淆载荷、凭据偷发 | 未发现。fork 与上游一致。 |
| 实验室自行部署的总体风险 | 高。风险来自产品本身：默认会让模型在容器里执行 shell，容器持有模型 API 密钥，网络和系统调用隔离弱。 |
| 可否在隔离实验室使用 | 可以。只能在没有生产凭据、没有云元数据、出口受限的一次性实验机上使用，并按文末清单加固。 |
| 供应链 | 中。锁文件 464 个包全部带 `sha512`，且与 registry.npmjs.org 当前元数据一致；OSV 没有 `MAL-` 恶意包通告。同时存在已公开的严重依赖漏洞，以及镜像、Typst、Playwright 不在锁文件内。 |

这是一个自主白盒渗透测试程序，不是普通的只读分析器。下面把「隐藏恶意行为」和「设计上的高权限」分开写。

## 1. 恶意代码与后门

### 1.1 未发现的类别

在 `apps/`、根目录脚本、Dockerfile、compose、workflow 和 prompt 中检索了动态执行、外联、凭据处理、安装钩子和编码载荷。结果：

- 仓库自身的 TypeScript/Shell 没有 `eval`、`new Function`、`vm` 动态执行。`child_process` 只出现在 CLI 调 Docker/git、worker 调 `typst` 和 `git`，参数来自程序常量或已解析路径，不是远程下发的字符串。`apps/worker/src/services/pdf-renderer.ts` 与 `apps/worker/src/ai/sast/capella/artifacts.ts` 使用 `execFile`，不经 shell。
- `apps/worker/src/services/git-manager.ts:212` 把 git 参数放进 `zx` 模板字符串。调用点的命令来自仓库内部的 git 子命令，不是模型输出。zx 的设计是对插值做转义。本审计没有运行 zx，运行时转义行为标未确认。
- 没有混淆字符串、`atob`、大段 base64 载荷。`\x1b` 只用于终端颜色（`apps/cli/src/colors.ts`、`apps/cli/src/splash.ts`）。
- 根 `package.json`、`apps/cli/package.json`、`apps/worker/package.json` 都没有 `postinstall` / `preinstall` / `prepare`。`.npmrc` 第 4 行是 `ignore-scripts=true`。根 `package.json:23-26` 的 `pnpm.onlyBuiltDependencies` 只放行 `@swc/core` 和 `protobufjs`。
- 没有自更新循环。本地模式缺镜像时才会 `docker build`（`apps/cli/src/docker.ts:263-274`）；npx 模式按包版本拉取 `keygraph/shannon:<version>`（`apps/cli/src/docker.ts:24-41`）。启动时不会静默改写成别的地址。
- 没有 submodule，没有仓库内的 `curl`/`wget`/`git clone`，除了 Dockerfile 构建期下载 Typst（见第 3 章）。
- 凭据写入 `~/.shannon/config.toml` 时权限是 `0o600`（`apps/cli/src/config/writer.ts:22-29`）。传给容器时用 `-e KEY`，值不进 `docker run` 的参数（`apps/cli/src/env.ts:92-106`）。
- `apps/worker/package.json:20` 导出 `./ai/pi/source-jail`，源码树中没有对应文件。这是一条悬空导出，不是可执行后门。

### 1.2 看起来像外联、读完后不是偷凭据

**模型目录刷新。** `apps/worker/src/ai/models.ts:238-245` 把 `allowModelNetwork: true` 交给 pi 的 `ModelRuntime`。已发布的 `@earendil-works/pi-coding-agent@0.84.4` 在 `dist/core/remote-catalog-provider.js` 把目录基址定为 `https://pi.dev`，请求路径是 `/api/models/providers/<providerId>`。这与源码注释一致，会在扫描开始时出网，不携带扫描目标的业务数据。请求带 pi 的 User-Agent。实验室防火墙如果禁止 `pi.dev`，目录刷新会超时并退回内置目录（同一函数把超时设为 10 秒）。是否每次都成功退回，标未确认，因为没有运行。

**Cyber access 探测。** `apps/worker/src/services/cyber-access-verification.ts:40` 的 `https://staging.keygraph.io` 只写进发给 OpenAI/Anthropic 的提示词，Shannon 自己不对这个 URL 发 HTTP。`verifyCyberAccess`（同文件 162-189 行）只调用 `completeSimple`，把模型返回的 `bash_commands` 留在结构化结果里。`apps/worker/src/temporal/activities.ts` 里对该结果只做日志和是否拒绝的判断，没有执行这些命令。提示词要求模型给出针对固定示例代码的 bash，内容会进入所选模型供应商。这是凭据和提示外发给模型 API，不是发给 Keygraph 的隐藏信道。

**pi 遥测。** `@earendil-works/pi-telemetry@0.84.4` 的 README 和 `dist/index.js` 只提供 span 接口和内存实现，没有导出器。`pi-coding-agent` 的交互模式会请求 `https://pi.dev/api/report-install?version=`（`dist/modes/interactive/interactive-mode.js`），安装遥测默认开启（`dist/core/settings-manager.js` 中 `enableInstallTelemetry ?? true`）。Shannon 使用的是 `createAgentSession`（`apps/worker/src/ai/pi/pi-executor.ts:333`），静态检索里这条请求只出现在交互模式。库路径是否间接调用，标未确认。同一包的 `enableAnalytics` 默认是 `false`。对 OpenRouter、NVIDIA NIM、Cloudflare 模型，遥测开启时会加归因请求头（`dist/core/provider-attribution.js`），默认的 Anthropic/OpenAI/xAI/Bedrock 路径不加这些头。

**Radius。** `pi-ai` 里 `DEFAULT_RADIUS_GATEWAY = "https://radius.pi.dev"` 只属于名为 radius 的提供商及其 OAuth。默认模型是 `anthropic:claude-sonnet-4-6`（`apps/worker/src/ai/models.ts:84`）。不选该提供商时不会走这条地址。

### 1.3 显式的攻击能力，不是隐藏载荷

**`--exp-php2shell`。** `apps/cli/src/exp-php2shell/` 是实验性的 PHP 升级检查。`probe.ts:4-6` 和 `run.ts:43-46` 写明只做第一步：用超大 multipart 体触发未修补 PHP 的 worker 崩溃，不发送第二步代码执行请求。入口在 CLI，不启动 worker（`apps/cli/src/commands/start.ts:279-287`）。默认有确认提示，`--yes` 可跳过（`run.ts:48`）。这是对操作者指定 URL 的真实破坏性探测（短暂打垮一个 PHP worker）。它不是开机自启，也不是把 shell 装回本机。实验室里把它指向任何非一次性靶机都不合适。

**渗透阶段默认开启。** `apps/worker/src/temporal/workflows.ts:383` 为 `const exploit = input.exploit ?? true`。`apps/worker/src/services/prompt-manager.ts:437` 同样把缺省当成开启。`apps/worker/configs/config-schema.json:141-145` 的说明也是 default true。不写配置就会进入利用阶段。prompt 要求对命令注入做到影响证明，并举了 reverse shell 作为影响示例（`apps/worker/prompts/exploit-injection.txt:53`）。SSRF prompt 包含云元数据地址示例（`apps/worker/prompts/exploit-ssrf.txt:290-299`）。这些字符串是给模型的任务说明。模型随后可以通过 bash 工具真的去执行。

## 2. 危险能力与默认配置

等级按实验室误用或提示注入后的影响来写，不按「作者是否恶意」。

### F-01 模型拥有无命令白名单的 shell

- 等级：高
- 位置：`apps/worker/src/ai/pi/pi-executor.ts:59-60`、`263-269`；`apps/worker/src/ai/pi/task-tool.ts:47`；`apps/worker/src/ai/extensions/bash-timeout/index.ts:16-19`
- 说明：渗透代理的内置工具是 `read`、`bash`、`edit`、`write`、`grep`、`find`、`ls`。子会话还有 `bash` 和 `write`。唯一强制约束是 bash 必须带 timeout，且不超过 600 秒。没有命令白名单，没有目的地址限制。bash 继承容器进程环境，其中有 `buildEnvFlags` 转发进来的 API 密钥（`apps/cli/src/env.ts:30-38`、`97-106`）。
- 实验室影响：目标仓库或网页里的提示注入可以让模型读取密钥、用 `curl` 外带，或攻击容器能到达的地址。密钥外带是这条产品边界的直接后果。

### F-02 权限扩展默认不加载，加载后仍放行外部目录

- 等级：高
- 位置：`apps/worker/src/ai/pi/permission-system.ts:16-19`、`78-91`；`apps/worker/src/ai/pi/pi-executor.ts:84-94`
- 说明：只有配置了 `code_path` avoid 才会写入并加载 `@gotgenes/pi-permission-system`。配置体是 `permission['*'] = allow`，再叠加路径 deny，并且 `external_directory: allow`。注释写明这是为了让渗透代理访问挂载仓库以外的路径。没有 avoid 规则时，扩展不加载。
- 实验室影响：`rules.avoid` 不能当作沙箱。它只阻止一批路径上的文件工具和扩展能识别的 bash 读文件命令。`curl`、解释器、写 `/tmp` 不在这条策略里。

### F-03 静态分析阶段有工具牢笼，渗透阶段没有

- 等级：信息（对照项）
- 位置：`apps/worker/src/ai/pi/capella-agent-executor.ts:54-73`；`apps/worker/src/ai/sast/capella/tools/confinement.ts`
- 说明：Capella 明确禁止 `bash`、`shell`、`network`、`browser`、`edit`、`write` 等，仓库读取有路径、大小和超时限制。这个牢笼不覆盖五个漏洞类的分析和利用代理。

### F-04 容器丢掉 seccomp，rootfs 可写且 `/app` 全局可写

- 等级：高
- 位置：`apps/cli/src/docker.ts:493-497`；`Dockerfile:136-140`
- 说明：worker 启动参数包含 `--security-opt seccomp=unconfined` 和 `--shm-size 2gb`。注释写明这是给 Chromium 用的，但是容器级设置，worker 进程同样不受默认 seccomp 过滤。没有 `--privileged`，没有挂载 docker socket，这一点是正向的。Dockerfile 把 `/app`、`/tmp/.cache`、`/tmp/.config`、`/tmp/.npm` 设为 `0777`。镜像最后没有 `USER` 降权，`Dockerfile:50` 仍是 `USER root`，降权发生在入口脚本。
- 实验室影响：模型通过 bash 可以改容器里的 `/app`（含 `node_modules`）。`--rm` 默认会在退出时丢掉容器层，所以这不是宿主机上的持久后门。同一次扫描内它可以改自己的代码。未对「seccomp=unconfined 能否直接逃出 Docker」做动态验证，容器逃逸本身标未确认，依赖宿主机内核和 Docker 版本。

### F-05 入口以 root 改 uid，再把命令交给 `su`

- 等级：中
- 位置：`entrypoint.sh:4-18`；`apps/cli/src/docker.ts:448-451`
- 说明：入口默认 root。若设置了 `SHANNON_HOST_UID`，会 `userdel`/`groupadd`/`useradd` 再 `chown`。CLI 在 Linux 上把这两个变量设成当前用户的 uid/gid。随后 `exec su -m pentest -c "exec $*"`。`$*` 未加引号。CLI 把参数拆开传给 `docker run`，正常路径下是空格分隔的固定参数。手工 `docker run` 并传入带空格或元字符的命令时，这个入口会按 shell 规则拆词。
- 实验室影响：不要把不受信任的字符串直接接进镜像 CMD。正常 `./shannon start` 的 workspace 名有字符限制（`apps/cli/src/commands/start.ts:301`），URL 只能是 http/https（`apps/cli/src/index.ts:229-238`）。

### F-06 默认把宿主机名字和 host-gateway 送进容器

- 等级：高
- 位置：`apps/cli/src/docker.ts:309-316`、`335-346`、`356-396`、`453-488`
- 说明：Linux 上会加 `host.docker.internal:host-gateway`。`SHANNON_FORWARD_HOSTS` 默认 true，读取宿主机 `/etc/hosts`，把 `127.*` 和 `::1` 改写成 `host-gateway` 再 `--add-host`。跳过 `169.254.` 和 `fe80:`/`ff` 开头的地址。仓库以 `:ro` 挂载；`.shannon/deliverables`、scratchpad、Playwright 目录和可选的 `-o` 输出目录可写。`SHANNON_USE_PI_AUTH=1` 时把宿主机 `~/.pi/agent/auth.json` 以读写方式挂到 `/tmp/.pi/agent/auth.json`，OAuth 刷新会写回宿主机。
- 实验室影响：worker 被设计成能访问宿主机上的本地服务。只绑定在宿主机 `127.0.0.1` 的端口，从 `host-gateway` 是否真的打得到，取决于 Docker 版本，标未确认。监听在宿主机非回环地址上的服务则在这条路径上。Pi 登录文件被挂载后，模型 shell 可以读取或覆盖它。

### F-07 预检只挡 IPv4 链路本地，且只挡预检那一次请求

- 等级：高
- 位置：`apps/worker/src/services/preflight.ts:61-78`、`403-416`、`470-487`
- 说明：目标 URL 必须能解析。拦截范围只有 `169.254.0.0/16`。IPv6 链路本地、`fd00:ec2::254` 这类元数据地址不在表里。注释写明 RFC1918 和回环是故意允许的。HEAD 请求对 HTTPS 设置 `rejectUnauthorized: false`，DNS 结果会钉住这一次连接。钉扎不作用于之后代理的 bash、浏览器或任意 HTTP 客户端。
- 实验室影响：在云主机上跑时，容器若能访问实例元数据，模型可以自己去读。预检拒绝不能代替网络策略。关闭 TLS 校验只影响预检 HEAD，扫描过程中的浏览器和 curl 是否校验证书取决于那些客户端，标未确认。

### F-08 登录秘密进入模型提示，并以命令行形式进日志

- 等级：高
- 位置：`apps/worker/src/services/prompt-manager.ts:172-176`、`217-258`；`apps/worker/prompts/shared/login-instructions.txt:19`、`33`；`apps/worker/src/audit/workflow-logger.ts:324-331`；`apps/worker/src/audit/trace.ts:77-97`
- 说明：用户名、密码、TOTP 秘密和邮箱口令被替换进提示词，再发给模型供应商。提示要求模型执行 `generate-totp --secret <秘密>`。工具参数按完整 JSON 写入 `workflow.log` 和按代理拆分的日志，注释称之为无损记录。终端进度对 bash 只截前 60 个字符（`apps/worker/src/ai/output-formatters.ts:235-237`），文件日志不截断。错误行使用固定文案（`apps/worker/src/audit/safe-fields.ts:117-131`），`SHANNON_DEBUG_PROVIDER_ERRORS` 默认关闭。
- 实验室影响：工作区日志、模型供应商和进程列表都可能出现目标口令和 TOTP 种子。交付物 prompt 要求不要把这些秘密写进 finding（`apps/worker/prompts/shared/exploitation/_credentials-in-findings.txt`），这条约束管的是模型提交的字段，不管日志。

### F-09 浏览器登录态落盘，正常结束才删

- 等级：中
- 位置：`apps/worker/src/audit/utils.ts:69-70`；`apps/worker/src/temporal/activities.ts:2014-2023`；`apps/worker/src/temporal/workflows.ts:1366-1471`
- 说明：认证会话写到该次运行 `.shannon/` 下的 `auth-state.json`（cookie 和 storage）。`logWorkflowComplete` 在完成、失败、取消路径上都会尝试删除。删除失败只打警告。容器被 `docker kill` 或宿主机断电时，这个 activity 不会跑。
- 实验室影响：工作区目录在扫描结束后仍可能留有可用 cookie。Pi auth 挂载不在这次删除范围内。

### F-10 Temporal 开发服务器无认证，只绑宿主机回环

- 等级：中
- 位置：`docker-compose.yml:6-13`；`apps/cli/infra/compose.yml:6-12`
- 说明：镜像 `temporalio/temporal:1.7.0`，命令是 `server start-dev`，容器内 `--ip 0.0.0.0`。端口发布为 `127.0.0.1:7233` 和 `127.0.0.1:8233`。没有配置口令。开发服务器的默认姿态是无认证，本审计没有连上实例去验证，认证缺失标未确认，以 Temporal 1.7 开发模式的公开行为为依据。
- 实验室影响：同一台机器上的本地进程可以访问 7233/8233。不要把这两个端口改成 `0.0.0.0`。Web UI 会显示工作流输入，其中可以有目标 URL 和配置路径。

### F-11 Git 信任任意目录

- 等级：中
- 位置：`Dockerfile:101-104`
- 说明：镜像设置 `git config --system --add safe.directory '*'`。worker 会对挂载进来的目标仓库执行 git（checkpoint）。被扫描的仓库若带 `core.fsmonitor`、smudge/clean 或 hook，git 可能执行其中的程序。本审计没有用恶意仓库做动态验证，触发条件标未确认。
- 实验室影响：不要用这份镜像去扫不受信任的仓库，除非目标仓库来自你自己的实验靶场。

### F-12 Handlebars 编译本地模板，依赖版本有严重通告

- 等级：高（依赖），当前调用点未确认可被目标仓库直接触发
- 位置：`apps/worker/src/ai/sast/capella/prompt-loader.ts:83`；依赖 `handlebars@4.7.9`
- 说明：Capella 用 `handlebars.compile` 编译 `promptRoot` 下的本地 `.hbs`，选项 `noEscape: true`。模板文件属于 Shannon 自己的 prompt，不是扫描目标仓库。OSV 对 4.7.9 有两条严重通告，内容是 `compile` 路径上的 JavaScript 注入（`GHSA-8r5x-fm3f-whwj`、`GHSA-p8wg-vrv2-v86f`），另有一条中等通告 `GHSA-xw65-4hp5-5hc7`。对 `4.7.10` 的同一次 OSV 查询没有返回通告。`4.7.10` 的 registry 时间是 2026-10-05。
- 实验室影响：只要 prompt 目录保持为镜像或本仓库里的文件，目标应用不能直接把模板送进 `compile`。若有人把不受信任的文件放进 prompt 目录，或本地模式以可写方式改挂载，这条依赖漏洞就变成代码执行。YAML 配置不走 Handlebars。`apps/worker/src/config-parser.ts:230-231` 使用 `js-yaml` 的 `FAILSAFE_SCHEMA`。

### F-13 其他默认值

- 等级：中
- 位置：见下
- `agentic_sast` 默认关闭（`apps/worker/configs/config-schema.json:130-136`）。利用阶段默认开，见 1.3。
- `--pipeline-testing` 的 prompt 会让浏览器访问 `example.com`、`example.org`、`example.net`、`jsonplaceholder.typicode.com`、`httpbin.org`（`apps/worker/prompts/pipeline-testing/`）。这是显式测试模式，不是默认扫描。
- 示例配置和文档里的口令、TOTP（`JBSWY3DPEHPK3PXP`）是占位符或 RFC 6238 测试向量。`sample-reports/` 里的 JWT 和口令来自公开靶场写进样例报告的内容，不是 Shannon 的凭据。
- `apps/worker/src/ai/pi/pi-executor.ts:340` 使用 `SessionManager.inMemory()`。pi 是否仍向 `getAgentDir()` 写模型目录缓存，标未确认。目录刷新的存储路径被设到 agent 目录（`apps/worker/src/ai/models.ts:216-218`），该目录在容器 `/tmp/.pi` 下。

## 3. 依赖与供应链

本章覆盖一次本地构建加一次运行时镜像会碰到的全部拉取面：pnpm 锁文件、锁文件之外的 npm 全局包、apk、基础镜像、compose 镜像、npx 模式的 worker 镜像、构建期二进制、GitHub Actions。没有 Cargo/Go/Python/Ruby 锁文件，没有 git submodule。

### 3.1 拉取面一览

| 来源 | 何时拉取 | 版本是否锁定 | 校验和 / digest | 风险 |
| --- | --- | --- | --- | --- |
| `pnpm-lock.yaml`（464 个 npm 包） | `pnpm install --frozen-lockfile`，以及镜像构建里随后的 `--prod` | 是，lockfileVersion 9.0 | 全部为 `sha512`；2026-11-09 与 `registry.npmjs.org` 的 `dist.integrity` 一致，0 条不一致，0 条非官方 tarball | 中。完整性好，但有公开漏洞，见 3.5 |
| 根与 workspace 的直接依赖 | 同上 | 见 3.3 | 同上 | 中 |
| `pnpm@10.33.0` | Dockerfile:23，`npm install -g --ignore-scripts` | 版本钉死，不在 pnpm 锁文件里 | 安装时由 npm 按 registry 元数据核验；仓库没有提交 digest | 低 |
| `@playwright/cli@0.1.1` 及其依赖 | Dockerfile:119 | CLI 版本钉死。其 `package.json` 把 `playwright` 钉在 `1.59.0-alpha-1771104257000`，`minimist` 是 `^1.2.5` | CLI 与 playwright、playwright-core 的 registry integrity 存在，但没有写进本仓库。`minimist` 范围在构建时浮动 | 高 |
| `playwright-cli install --skills` | Dockerfile:120-123 | 无单独版本 | 未确认是否再下载 skill 或浏览器。`PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` 写在 Dockerfile:149，晚于这次 RUN，约束不到它 | 高，行为未确认 |
| Alpine/Wolfi `apk add` 的系统包 | Dockerfile:9-20、51-79 | 不锁定 | 无 digest。基础镜像是 tag | 高 |
| `cgr.dev/chainguard/wolfi-base:latest` | Dockerfile:6、44 | tag `latest` | 未取得 digest。匿名请求 registry manifest 返回 401 | 高 |
| Typst `0.14.2` | Dockerfile:82-95，从 GitHub releases 用 curl 下载并执行 `typst --version` | 版本钉死 | Dockerfile 无 sha256。该 release 资产列表里没有 checksum 文件 | 高 |
| `temporalio/temporal:1.7.0` | `docker-compose.yml:7`，`apps/cli/infra/compose.yml:7` | tag 钉死，digest 未写入文件 | 2026-11-09 Docker Hub tag digest `sha256:9c5b386d86bca59ba08f32ddc4c51287351c8c616b6a8359f03e96a585e137f4`。amd64 `sha256:6dc6fda8437b7aca517a5daeff024438f469f0c40a16c28118393d8477965f5f`，arm64 `sha256:3ccd1b745e19342edd4cfa5b0b64dc96596fd1fc70abb263a543cd8c23c625eb`。tag 可被覆盖，此 digest 只代表查询当时 | 中 |
| `keygraph/shannon:<包版本>` | 仅 npx 模式，`apps/cli/src/docker.ts:40-41` | tag 等于 npm 包版本 | CLI 拉取时不校验 cosign。签名发生在上游 `.github/workflows/release.yml:154-166`，验证身份是上游仓库的 workflow | 中。本地 `./shannon` 不走这条，改为本地构建 `shannon-worker` |
| GitHub Actions | 只在上游/本仓库 CI 发布时 | 第三方 action 用 commit SHA | 见 3.7。`npx semantic-release@25` 没有锁 | 中，且只影响发布流水线，不影响实验室运行时 |
| 模型 API、`pi.dev` 目录 | 每次扫描 | 不适用 | TLS，由运行时决定 | 见第 2 章 |

`.npmrc` 没有自定义 registry。`minimum-release-age=10080`（7 天）只影响新的版本解析，不替换锁文件里已经钉住的版本。

### 3.2 锁文件怎么读

`pnpm-lock.yaml` 头为 `lockfileVersion: '9.0'`，`autoInstallPeers: true`。`packages:` 下 464 个条目都有 `resolution.integrity`，算法都是 `sha512`，没有 `tarball:`、`git+`、`file:` 或 GitHub 直链。2026-11-09 对每个 `name@version` 请求 `https://registry.npmjs.org/<name>/<version>`，`dist.integrity` 与锁文件全部相同，`dist.tarball` 全部位于 `https://registry.npmjs.org/`。

依赖图按锁文件 `snapshots` 从 workspace 的生产依赖和开发依赖分别遍历，464 个快照全部可达：生产闭包 390 个，仅开发闭包 74 个。生产闭包包含 worker 和 CLI 的生产依赖，因为镜像构建在仓库根执行 `pnpm install --frozen-lockfile --prod`（`Dockerfile:33`、`41`）。因此 CLI 的 `smol-toml` 也会进镜像的 `node_modules`，即使 worker 进程不 import 它。

OSV 查询没有返回任何 `MAL-` 编号。这不能证明未来无人投毒，只能说明查询当日这些精确版本没有被 OSV 标成已知恶意包。

两个弃用说明：`node-domexception@1.0.0` 建议改用平台实现；`@smithy/core@3.24.6` 的 registry 弃用文案写明自定义 logger 的脱敏有缺陷。Shannon 源码没有配置 Smithy 自定义 logger。是否因此把 AWS 凭据打进日志，标未确认。Bedrock 使用 `AWS_BEARER_TOKEN_BEDROCK`，不是长期访问密钥（`.env.example:18-22`）。

`typebox@1.1.38`（直接依赖）和 `typebox@1.3.7`（pi 的传递依赖）的 `repository` 都是 `git+https://github.com/sinclairzx81/typebox.git`，不是同名仿冒包。`@earendil-works/*@0.84.4` 的仓库是 `earendil-works/pi`。`@gotgenes/pi-permission-system@10.9.0` 的仓库是 `gotgenes/pi-packages`。没有发现把官方包名换成缺字母或加连字符的依赖名。

### 3.3 直接依赖与锁定版本

根 `package.json` 只有开发依赖：

| 包 | 声明 | 锁定 |
| --- | --- | --- |
| `@biomejs/biome` | `^2.0.0` | `2.4.7` |
| `@types/node` | `^25.0.3` | `25.5.0` |
| `turbo` | `^2.5.0` | `2.8.17` |
| `typescript` | `^5.9.3` | `5.9.3` |

`apps/cli` 生产依赖：

| 包 | 声明 | 锁定 |
| --- | --- | --- |
| `@clack/prompts` | `^1.1.0` | `1.1.0` |
| `@temporalio/client` | `1.15.0` | `1.15.0` |
| `chokidar` | `^5.0.0` | `5.0.0` |
| `dotenv` | `^17.3.1` | `17.3.1` |
| `smol-toml` | `^1.6.1` | `1.6.1` |

CLI 开发依赖 `tsdown` `^0.21.5` 锁定 `0.21.5`。

`apps/worker` 生产依赖：

| 包 | 声明 | 锁定 |
| --- | --- | --- |
| `@earendil-works/pi-agent-core` | `^0.84.4` | `0.84.4` |
| `@earendil-works/pi-ai` | `^0.84.4` | `0.84.4` |
| `@earendil-works/pi-coding-agent` | `^0.84.4` | `0.84.4` |
| `@gotgenes/pi-permission-system` | `^10.9.0` | `10.9.0` |
| `@temporalio/activity` | `1.15.0` | `1.15.0` |
| `@temporalio/client` | `1.15.0` | `1.15.0` |
| `@temporalio/worker` | `1.15.0` | `1.15.0` |
| `@temporalio/workflow` | `1.15.0` | `1.15.0` |
| `ajv` | `^8.12.0` | `8.18.0` |
| `ajv-formats` | `^2.1.1` | `2.1.1` |
| `dotenv` | `^16.4.5` | `16.6.1` |
| `handlebars` | `^4.7.9` | `4.7.9` |
| `js-yaml` | `^4.1.0` | `4.1.1` |
| `typebox` | `1.1.38` | `1.1.38` |
| `zx` | `^8.0.0` | `8.8.5` |

worker 开发依赖 `@types/js-yaml` `^4.0.9` 锁定 `4.0.9`。

`^` 范围在锁文件存在且使用 `--frozen-lockfile` 时不会浮动。删掉锁文件再安装就会浮动。实验室构建应保留锁文件。

`@temporalio/worker@1.15.0` 的快照直接依赖 `@swc/core@1.15.18`、`webpack@5.105.4`、`protobufjs@7.5.5`、`@grpc/grpc-js@1.14.3`（`pnpm-lock.yaml:3032-3055`）。这些因此进入运行时镜像，不只是开发机。

### 3.4 安装钩子与仿冒面

464 个包里有 100 个在 registry 的 `scripts` 中声明了 `preinstall`、`install`、`postinstall`、`prepare`、`prepublish` 或 `prepublishOnly`。`prepublish` / `prepublishOnly` 是发布时钩子，`pnpm install` 不执行。

在当前 `.npmrc` 加 `onlyBuiltDependencies` 的策略下，安装期真正会跑的只有：

| 包 | 钩子 | 静态阅读结果 | 等级 |
| --- | --- | --- | --- |
| `protobufjs@7.5.5` | `postinstall`: `node scripts/postinstall` | 脚本只在包声明了 `versionScheme` 时向 stderr 打印版本警告，无网络、无下载。另有 `prepublish` 会 `npm install`，那是发布钩子 | 低 |
| `@swc/core@1.15.18` | `postinstall`: `node postinstall.js` | 先加载已安装的 native binding。失败且没有 `SWC_BINARY_PATH`、也没有现成的 `@swc/wasm` 时，执行 `npm install --no-save @swc/wasm@<与 core 相同的版本>`。这条下载不在 pnpm 锁文件里。版本号来自包自己的 `package.json`，不是外部字符串拼接进命令 | 中 |

若有人改用 `npm install` 或关掉 `ignore-scripts`，下面这些安装期脚本会执行。它们在默认 pnpm 策略下不跑，等级按「政策被绕过」计为低到中：

- `tree-sitter-bash@0.25.1` 的 `install` 是 `node-gyp-build`（本地编译/加载原生模块）。
- `@google/genai@1.52.0` 的 `preinstall` 是 `echo 'preinstall: no-op'`，`prepare` 是 `node scripts/prepare.js`。未执行该脚本，脚本正文标未确认。
- 多个包的 `prepare` 会跑 `husky`、`tshy` 或 `npm run compile`，包括 `undici`、`webpack`、`uuid`、`brace-expansion`、`minimatch`、`lru-cache`。
- `balanced-match@4.0.4`、`brace-expansion@5.0.6`、`lru-cache@11.5.1`、`minimatch@10.2.5`、`json-parse-even-better-errors@2.3.1`、`signal-exit@3.0.7` 的 `prepublishOnly` 含 `git push`。这是发布脚本被打进了已发布清单，安装时不执行。默认配置下不到达。

`pnpm@10.33.0` 的 scripts 是仓库开发用的 compile/test，没有 install 钩子，且 Dockerfile 使用了 `--ignore-scripts`。

`@playwright/cli@0.1.1` 自己的 scripts 只有 `test`。它的依赖 `playwright@1.59.0-alpha-1771104257000` 和 `playwright-core` 同版本在 registry 上没有 install/postinstall/prepare。这是 alpha 版本，不在 pnpm 锁文件中。Dockerfile 对这次全局安装使用了 `--ignore-scripts`，随后立刻执行 `playwright-cli install --skills`。该子命令的网络行为标未确认。

### 3.5 OSV / GHSA

查询日 2026-11-09。24 个锁定版本有通告，合计 116 条，其中严重 3、高 42、中 61、低 10，没有 withdrawn。没有 `MAL-`。

严重：

| 通告 | 包 | 图 | 摘要 | Shannon 里的到达情况 |
| --- | --- | --- | --- | --- |
| `GHSA-8r5x-fm3f-whwj` | `handlebars@4.7.9` | 生产，直接依赖 | compile 路径 JavaScript 注入 | 见 F-12。调用点编译本地模板 |
| `GHSA-p8wg-vrv2-v86f` | `handlebars@4.7.9` | 生产，直接依赖 | compile 路径 JavaScript 注入 | 同上 |
| `GHSA-jqcg-44mw-7w3h` | `proxy-addr@2.0.7` | 生产，经 MCP SDK 的 express | IPv4-mapped IPv6 导致 IP 欺骗 | Shannon 源码不启动 Express。是否走到该库，未确认 |

其余命中按包汇总。等级是 OSV 通告等级，不是已经证明的可利用性。

| 包@版本 | 图 | 通告数 | 最高 | 编号 |
| --- | --- | --- | --- | --- |
| `handlebars@4.7.9` | 生产 | 3 | 严重 | `GHSA-8r5x-fm3f-whwj` `GHSA-p8wg-vrv2-v86f` `GHSA-xw65-4hp5-5hc7` |
| `proxy-addr@2.0.7` | 生产 | 1 | 严重 | `GHSA-jqcg-44mw-7w3h` |
| `undici@8.9.0` | 生产，`pi-coding-agent` 直接依赖 | 18 | 高 | 含 `GHSA-2m5v-pch6-74hx`、`GHSA-w293-vg96-wgc3`（TLS 校验选项被丢弃）、`GHSA-4w7w-5xrc-9h26`（缓存与跨源重定向）。pi 0.84.4 是否调用受影响的 `Agent`/`BalancedPool`，未确认 |
| `hono@4.12.14` | 生产，MCP SDK | 26 | 高 | `GHSA-88fw-hqm2-52qc` 等。Shannon 是否启用 Hono 服务端，未确认 |
| `protobufjs@7.5.5` | 生产，Temporal worker | 11 | 高 | `GHSA-66ff-xgx4-vchm`、`GHSA-75px-5xx7-5xc7`（代码生成/原型污染小工具）、`GHSA-685m-2w69-288q` 等 DoS。Shannon 是否对不可信 protobuf 做代码生成，未确认 |
| `@grpc/grpc-js@1.14.3` | 生产，Temporal worker | 4 | 高 | `GHSA-99f4-grh7-6pcq` `GHSA-m9gg-hp2v-232j` `GHSA-5375-pq7m-f5r2` `GHSA-f596-whhp-79r4` |
| `@modelcontextprotocol/sdk@1.29.0` | 生产，pi 的 peer，锁文件已装入 | 6 | 高 | `GHSA-6qxp-vccf-f47h`（OAuth 凭据可能发给 MCP 服务器指定的授权端）、`GHSA-46jr-4wx8-v453`、`GHSA-f897-62hf-6gxq`、`GHSA-22jm-h49p-29qw`、`GHSA-6prh-2h8m-c8cw`、`GHSA-rvq5-wwqv-78pq`。Shannon 源码没有配置 MCP 远程服务器。pi 是否在默认会话里打开 MCP HTTP，未确认 |
| `js-yaml@4.1.1` | 生产，直接依赖 | 4 | 高 | `GHSA-52cp-r559-cp3m` `GHSA-5p4m-2wfm-xmqj` `GHSA-2883-xcg3-v3hh` `GHSA-h67p-54hq-rp68`，内容是 merge key / omap 的 CPU 消耗。解析配置时用了 `FAILSAFE_SCHEMA`。该 schema 是否仍走有问题的 merge 路径，未确认。配置文件由操作者提供 |
| `fast-uri@3.1.2` | 生产，经 ajv | 11 | 高 | 主机名规范化与 SSRF 类通告。到达 ajv 的输入是 Shannon 自己的 JSON Schema 和代理输出，不是任意 URL 抓取。可利用性未确认 |
| `ip-address@10.1.0` | 生产，经 express-rate-limit | 6 | 高 | 前导零八进制/十进制歧义。Shannon 不把该库当作出站 SSRF 过滤器。可利用性未确认 |
| `brace-expansion@5.0.6` | 生产 | 6 | 高 | 解析花括号时的 DoS |
| `body-parser@2.2.2` | 生产，经 express | 2 | 高 | 压缩体 DoS。服务端是否暴露，未确认 |
| `browserslist@4.28.1` | 生产，经 webpack | 2 | 高 | 不受信任的 stats 文件或缓存增长 |
| `qs@6.15.1` | 生产 | 4 | 中 | 原型污染/DoS 类，OSV 最高为中 |
| `zod@4.3.6` | 生产 | 1 | 高 | `GHSA-mrhx-c7xc-m3w5`，超大集合校验时的内存消耗 |
| `@hono/node-server@1.19.14` | 生产 | 2 | 中 | 随 Hono |
| `@protobufjs/utf8@1.1.0` | 生产 | 1 | 中 | `GHSA-q6x5-8v7m-xcrf` |
| `baseline-browser-mapping@2.10.8` | 生产 | 1 | 中 | `GHSA-w5vr-8v7q-w6rv` |
| `minimatch@10.2.5` | 生产，pi-coding-agent | 1 | 高 | `GHSA-g3hv-75wg-m249` |
| `smol-toml@1.6.1` | 生产（CLI 依赖，随 `--prod` 装入镜像） | 2 | 高 | `GHSA-7w5x-hrqm-74c2` `GHSA-r4xh-jqrq-34v2`，畸形 TOML 的 DoS。CLI 用它读 `~/.shannon/config.toml` |
| `source-map-js@1.2.1` | 生产 | 1 | 高 | `GHSA-68fv-2mgg-jv7q` |
| `uuid@11.1.0` | 生产 | 1 | 中 | `GHSA-w5hq-g745-h8pq` |
| `defu@6.1.4` | 仅开发（tsdown） | 1 | 高 | `GHSA-737v-mqg7-c878` 原型污染 |
| `turbo@2.8.17` | 仅开发 | 2 | 中 | `GHSA-3qcw-2rhx-2726` `GHSA-hcf7-66rw-9f5r` |

`hono` 的 26 条和 `undici` 的 18 条没有在正文逐条展开标题。编号以 OSV 查询结果为准，复现查询可以用第 3.2 节的同一批版本。需要升级时优先处理直接依赖 `handlebars@4.7.9`（OSV 对 `4.7.10` 无通告）以及运行时一定会加载的 `undici`、`protobufjs`、`@grpc/grpc-js`。

### 3.6 镜像、apk 与构建期二进制

**基础镜像。** `Dockerfile:6` 和 `Dockerfile:44` 都是 `cgr.dev/chainguard/wolfi-base:latest`。tag 会移动。digest 未确认。

**apk，均无版本号。** 构建阶段（`Dockerfile:9-20`）：`build-base`、`git`、`curl`、`wget`、`ca-certificates`、`nodejs-22`、`npm`、`bash`。运行阶段（`Dockerfile:51-79`）：`git`、`bash`、`curl`、`ca-certificates`、`shadow`、`xz`、`nodejs-22`、`npm`、`python3`、`chromium`、`nss`、`freetype`、`harfbuzz`、`libx11`、`libxcomposite`、`libxdamage`、`libxext`、`libxfixes`、`libxrandr`、`mesa-gbm`、`fontconfig`。Wolfi 仓库在构建当时解析到哪个构建号，未确认。Chromium 进入运行镜像，给 Playwright 用。

**Typst。** `Dockerfile:82-89` 按 `uname -m` 选择 `x86_64-unknown-linux-musl` 或 `aarch64-unknown-linux-musl`，从 `https://github.com/typst/typst/releases/download/v0.14.2/typst-<arch>.tar.xz` 下载，解压后执行。GitHub release `v0.14.2` 的资产名与这两个文件名一致，资产列表中没有 checksum 文件。下载内容在构建时被执行。等级高。

**Temporal。** 见 3.1 的 digest。compose 使用 `start-dev`。没有在本审计中拉取或运行该镜像，镜像层里还有什么启动脚本，标未确认。

**npx 镜像。** 实验室若使用 `./shannon`（本仓库入口会设置 `SHANNON_LOCAL=1`，`shannon` 文件第 4 行），worker 镜像名是本地的 `shannon-worker`，由当前源码构建。若改用 `npx @keygraph/shannon`，拉取的是 Docker Hub 上 `keygraph/shannon:<npm 版本>`，不是这个 fork 的 Dockerfile 产物，也没有在客户端做 cosign 验证。fork 与上游源码目前一致，已发布镜像是否等于这个提交，未确认，因为没有拉取镜像。

### 3.7 GitHub Actions

第三方 action 都钉在 commit SHA，注释中的 tag 与 GitHub 上的 tag 对象一致（`pnpm/action-setup` 的 `v4.4.0` 是附注 tag，剥开后的 commit 为 `fc06bc1257f339d1d5d8b3a19a8cae5388b55320`）：

| Action | SHA | tag |
| --- | --- | --- |
| `actions/checkout` | `de0fac2e4500dabe0009e67214ff5f5447ce83dd` | `v6.0.2` |
| `actions/setup-node` | `53b83947a5a98c8d113130e565377fae1a50d02f` | `v6.3.0` |
| `actions/upload-artifact` | `b7c566a772e6b6bfb58ed0dc250532a479d7789f` | `v6.0.0` |
| `actions/download-artifact` | `018cc2cf5baa6db3ef3c5f8a56943fffe632ef53` | `v6.0.0` |
| `pnpm/action-setup` | `fc06bc1257f339d1d5d8b3a19a8cae5388b55320` | `v4.4.0` |
| `docker/setup-buildx-action` | `4d04d5d9486b7bd6fa91e7baf45bbb4f8b9deedd` | `v4.0.0` |
| `docker/login-action` | `b45d80f862d83dbcd57f89517bcf500b2ab88fb2` | `v4.0.0` |
| `docker/build-push-action` | `d08e5c354a6adb9ed34480a06d141179aa583294` | `v7.0.0` |
| `sigstore/cosign-installer` | `ba7bc0a3fef59531c69a25acd34668d6d3fe6f22` | `v4.1.0` |

`.github/workflows/release.yml:49` 和 `:239` 执行 `npx semantic-release@25`，主版本钉死、补丁不钉。这只在手动 `workflow_dispatch` 的发布流程里发生。实验室运行时不执行这些 workflow。发布 workflow 会登录 Docker Hub 并推送 `keygraph/shannon`。本 fork 若原样运行该 workflow，需要自备密钥；默认 secrets 不会在 fork 上自动可用。未确认 Silver-cybersec 组织是否配置了这些 secret。

### 3.8 安全拉取建议

1. 只使用本仓库 `./shannon` 的本地构建，不要用 `npx @keygraph/shannon` 去拉 `keygraph/shannon:latest` 或未核对的 tag。构建命令保持 `pnpm install --frozen-lockfile`，不要加 `--ignore-scripts=false`。
2. 把 `cgr.dev/chainguard/wolfi-base:latest` 改成一次你自己拉取后的 digest，并把 apk 包版本钉住。在那之前，每次构建的系统包集合都可能变化。
3. 给 Typst 下载加 sha256，并在校验通过前不要执行 `typst --version`。上游 release 资产里没有现成的 checksum 文件，需要自行对官方资产计算并钉住。
4. 把 `temporalio/temporal:1.7.0` 写成查询到的 manifest list digest，并接受 tag 以后可能移动、届时需要重查。
5. 把 `@playwright/cli`、`playwright`、`playwright-core`、`minimist` 放进锁文件或提交 integrity。在弄清 `install --skills` 会下载什么之前，把它当作一次不受锁文件约束的网络安装。
6. 保留 `ignore-scripts=true` 和 `onlyBuiltDependencies`。升级 `@swc/core` 时确认 native binding 能离线加载，避免 postinstall 再去 `npm install @swc/wasm`。
7. 优先把 `handlebars` 升到 OSV 查询为空的 `4.7.10`，并跟踪 `undici`、`protobufjs`、`@grpc/grpc-js`、`js-yaml`、`smol-toml` 的上游修复。开发依赖 `turbo`、`defu` 不进入 `--prod` 镜像，仍会影响在开发机上执行的 `pnpm install`。
8. 构建和运行都放在不能访问生产网络和云元数据的机器上。完整性校验只能保证「装到的是 registry 上的那个 tarball」，不能保证那个 tarball 没有漏洞。

## 4. 结论与必做加固

总体风险高，原因是产品会在默认配置下把利用阶段和 shell 交给模型，同时容器持有模型密钥、seccomp 关闭、宿主机网络辅助默认开启。未发现隐藏后门或 fork 篡改。供应链完整性在 npm 锁文件这一层是好的，在基础镜像、系统包、Typst 和 Playwright 这一层没有 digest。

可以在隔离实验室使用，前提是下面各项都做到。缺任何一项，扫描目标或恶意仓库内容都有机会碰到密钥、宿主机服务或云元数据。

1. 专用虚拟机或专用用户。不要在存放生产 SSH 密钥、云凭据或日常浏览器配置的机器上运行。不要设置 `SHANNON_USE_PI_AUTH`。模型密钥使用只能访问实验模型、可以作废的密钥。
2. 出口防火墙只放行实验靶机和选定的模型 API。`pi.dev` 会被目录刷新访问（`apps/worker/src/ai/models.ts:243`）。若不希望出网到 `pi.dev`，需要在防火墙拒绝后接受目录刷新超时，或后续改代码关掉 `allowModelNetwork`。本审计不改那行代码。
3. 阻断容器到 `169.254.0.0/16`、IPv6 链路本地和云元数据主机名的路由。不要在开启 IMDS 的云主机上跑。设置 `SHANNON_FORWARD_HOSTS=false`，除非靶机必须靠宿主机 hosts。
4. 保持 compose 端口在 `127.0.0.1`。不要加 `--privileged`，不要挂载 docker socket。扫描结束删除工作区，或至少删除 `auth-state.json` 和 `workflow.log`。
5. 配置里写 `exploit: "false"`，除非这次实验就是要做利用。不要对非一次性靶机使用 `--exp-php2shell`。不要使用 `--pipeline-testing` 去打公网示例站，除非出口策略允许。
6. 只用 `./shannon` 本地构建和 `pnpm install --frozen-lockfile`。按 3.8 钉住基础镜像、apk、Typst、Temporal digest，并把 Playwright 纳入锁文件。优先升级 `handlebars@4.7.9`。
7. 把工作区日志当作秘密。TOTP 种子和口令会出现在发给模型的提示和 `workflow.log` 的 bash 行里。

未确认项汇总：图片隐写；zx 运行时转义；`playwright-cli install --skills` 的额外下载；Wolfi `latest` 的 digest 和 apk 解析结果；Temporal 开发模式在 1.7.0 镜像内是否确实无认证；`host-gateway` 能否打到只绑定 `127.0.0.1` 的端口；seccomp 放行后的容器逃逸；Handlebars/js-yaml/undici/protobufjs/MCP/Hono/proxy-addr 的漏洞函数是否被 Shannon 的默认调用走到；pi 交互遥测是否被 `createAgentSession` 间接触发；已发布的 `keygraph/shannon` 镜像是否等于本提交。

### 附录 A. 全部 464 个锁定包

图例：`生产` 表示从 workspace 生产依赖可达，会进入 `pnpm install --prod`；`开发` 表示只从开发依赖可达。校验列在 2026-11-09 全部为「与 registry 一致」。完整 `sha512` 在 `pnpm-lock.yaml` 的对应条目里，这里不重复粘贴 464 条哈希。

附录由审计脚本按锁文件生成，顺序为包名。

| 包 | 版本 | 图 | 安装期脚本 |
| --- | --- | --- | --- |
| `@anthropic-ai/sdk` | `0.91.1` | 生产 | — |
| `@aws-crypto/crc32` | `5.2.0` | 生产 | — |
| `@aws-crypto/sha256-browser` | `5.2.0` | 生产 | — |
| `@aws-crypto/sha256-js` | `5.2.0` | 生产 | — |
| `@aws-crypto/supports-web-crypto` | `5.2.0` | 生产 | — |
| `@aws-crypto/util` | `5.2.0` | 生产 | — |
| `@aws-sdk/client-bedrock-runtime` | `3.1048.0` | 生产 | — |
| `@aws-sdk/core` | `3.974.18` | 生产 | — |
| `@aws-sdk/credential-provider-env` | `3.972.44` | 生产 | — |
| `@aws-sdk/credential-provider-http` | `3.972.46` | 生产 | — |
| `@aws-sdk/credential-provider-ini` | `3.972.50` | 生产 | — |
| `@aws-sdk/credential-provider-login` | `3.972.49` | 生产 | — |
| `@aws-sdk/credential-provider-node` | `3.972.52` | 生产 | — |
| `@aws-sdk/credential-provider-process` | `3.972.44` | 生产 | — |
| `@aws-sdk/credential-provider-sso` | `3.972.49` | 生产 | — |
| `@aws-sdk/credential-provider-web-identity` | `3.972.49` | 生产 | — |
| `@aws-sdk/eventstream-handler-node` | `3.972.20` | 生产 | — |
| `@aws-sdk/middleware-eventstream` | `3.972.16` | 生产 | — |
| `@aws-sdk/middleware-websocket` | `3.972.25` | 生产 | — |
| `@aws-sdk/nested-clients` | `3.997.17` | 生产 | — |
| `@aws-sdk/signature-v4-multi-region` | `3.996.32` | 生产 | — |
| `@aws-sdk/token-providers` | `3.1048.0` | 生产 | — |
| `@aws-sdk/token-providers` | `3.1063.0` | 生产 | — |
| `@aws-sdk/types` | `3.973.11` | 生产 | — |
| `@aws-sdk/util-locate-window` | `3.965.5` | 生产 | — |
| `@aws-sdk/xml-builder` | `3.972.28` | 生产 | — |
| `@aws/lambda-invoke-store` | `0.2.4` | 生产 | — |
| `@babel/generator` | `8.0.0-rc.2` | 开发 | — |
| `@babel/helper-string-parser` | `8.0.0-rc.2` | 开发 | — |
| `@babel/helper-validator-identifier` | `8.0.0-rc.2` | 开发 | — |
| `@babel/parser` | `8.0.0-rc.2` | 开发 | — |
| `@babel/runtime` | `7.29.2` | 生产 | — |
| `@babel/types` | `8.0.0-rc.2` | 开发 | — |
| `@biomejs/biome` | `2.4.7` | 开发 | — |
| `@biomejs/cli-darwin-arm64` | `2.4.7` | 开发 | — |
| `@biomejs/cli-darwin-x64` | `2.4.7` | 开发 | — |
| `@biomejs/cli-linux-arm64-musl` | `2.4.7` | 开发 | — |
| `@biomejs/cli-linux-arm64` | `2.4.7` | 开发 | — |
| `@biomejs/cli-linux-x64-musl` | `2.4.7` | 开发 | — |
| `@biomejs/cli-linux-x64` | `2.4.7` | 开发 | — |
| `@biomejs/cli-win32-arm64` | `2.4.7` | 开发 | — |
| `@biomejs/cli-win32-x64` | `2.4.7` | 开发 | — |
| `@clack/core` | `1.1.0` | 生产 | — |
| `@clack/prompts` | `1.1.0` | 生产 | — |
| `@earendil-works/pi-agent-core` | `0.84.4` | 生产 | — |
| `@earendil-works/pi-ai` | `0.84.4` | 生产 | — |
| `@earendil-works/pi-client` | `0.84.4` | 生产 | — |
| `@earendil-works/pi-coding-agent` | `0.84.4` | 生产 | — |
| `@earendil-works/pi-protocol` | `0.84.4` | 生产 | — |
| `@earendil-works/pi-telemetry` | `0.84.4` | 生产 | — |
| `@earendil-works/pi-tui` | `0.84.4` | 生产 | — |
| `@emnapi/core` | `1.9.1` | 开发 | — |
| `@emnapi/runtime` | `1.9.1` | 开发 | — |
| `@emnapi/wasi-threads` | `1.2.0` | 开发 | — |
| `@google/genai` | `1.52.0` | 生产 | preinstall、prepare |
| `@gotgenes/pi-permission-system` | `10.9.0` | 生产 | — |
| `@grpc/grpc-js` | `1.14.3` | 生产 | prepare |
| `@grpc/proto-loader` | `0.8.0` | 生产 | prepare |
| `@hono/node-server` | `1.19.14` | 生产 | — |
| `@jridgewell/gen-mapping` | `0.3.13` | 生产 | — |
| `@jridgewell/resolve-uri` | `3.1.2` | 生产 | — |
| `@jridgewell/source-map` | `0.3.11` | 生产 | — |
| `@jridgewell/sourcemap-codec` | `1.5.5` | 生产 | — |
| `@jridgewell/trace-mapping` | `0.3.31` | 生产 | — |
| `@js-sdsl/ordered-map` | `4.4.2` | 生产 | — |
| `@jsonjoy.com/base64` | `1.1.2` | 生产 | — |
| `@jsonjoy.com/base64` | `17.67.0` | 生产 | — |
| `@jsonjoy.com/buffers` | `1.2.1` | 生产 | — |
| `@jsonjoy.com/buffers` | `17.67.0` | 生产 | — |
| `@jsonjoy.com/codegen` | `1.0.0` | 生产 | — |
| `@jsonjoy.com/codegen` | `17.67.0` | 生产 | — |
| `@jsonjoy.com/fs-core` | `4.56.11` | 生产 | — |
| `@jsonjoy.com/fs-fsa` | `4.56.11` | 生产 | — |
| `@jsonjoy.com/fs-node-builtins` | `4.56.11` | 生产 | — |
| `@jsonjoy.com/fs-node-to-fsa` | `4.56.11` | 生产 | — |
| `@jsonjoy.com/fs-node-utils` | `4.56.11` | 生产 | — |
| `@jsonjoy.com/fs-node` | `4.56.11` | 生产 | — |
| `@jsonjoy.com/fs-print` | `4.56.11` | 生产 | — |
| `@jsonjoy.com/fs-snapshot` | `4.56.11` | 生产 | — |
| `@jsonjoy.com/json-pack` | `1.21.0` | 生产 | — |
| `@jsonjoy.com/json-pack` | `17.67.0` | 生产 | — |
| `@jsonjoy.com/json-pointer` | `1.0.2` | 生产 | — |
| `@jsonjoy.com/json-pointer` | `17.67.0` | 生产 | — |
| `@jsonjoy.com/util` | `1.9.0` | 生产 | — |
| `@jsonjoy.com/util` | `17.67.0` | 生产 | — |
| `@mariozechner/clipboard-darwin-arm64` | `0.3.9` | 生产 | — |
| `@mariozechner/clipboard-darwin-universal` | `0.3.9` | 生产 | — |
| `@mariozechner/clipboard-darwin-x64` | `0.3.9` | 生产 | — |
| `@mariozechner/clipboard-linux-arm64-gnu` | `0.3.9` | 生产 | — |
| `@mariozechner/clipboard-linux-arm64-musl` | `0.3.9` | 生产 | — |
| `@mariozechner/clipboard-linux-riscv64-gnu` | `0.3.9` | 生产 | — |
| `@mariozechner/clipboard-linux-x64-gnu` | `0.3.9` | 生产 | — |
| `@mariozechner/clipboard-linux-x64-musl` | `0.3.9` | 生产 | — |
| `@mariozechner/clipboard-win32-arm64-msvc` | `0.3.9` | 生产 | — |
| `@mariozechner/clipboard-win32-x64-msvc` | `0.3.9` | 生产 | — |
| `@mariozechner/clipboard` | `0.3.9` | 生产 | — |
| `@modelcontextprotocol/sdk` | `1.29.0` | 生产 | — |
| `@napi-rs/wasm-runtime` | `1.1.1` | 开发 | — |
| `@nodable/entities` | `2.1.1` | 生产 | — |
| `@oxc-project/types` | `0.122.0` | 开发 | — |
| `@protobufjs/aspromise` | `1.1.2` | 生产 | — |
| `@protobufjs/base64` | `1.1.2` | 生产 | — |
| `@protobufjs/codegen` | `2.0.4` | 生产 | — |
| `@protobufjs/eventemitter` | `1.1.0` | 生产 | — |
| `@protobufjs/fetch` | `1.1.0` | 生产 | — |
| `@protobufjs/float` | `1.0.2` | 生产 | — |
| `@protobufjs/inquire` | `1.1.0` | 生产 | — |
| `@protobufjs/path` | `1.1.2` | 生产 | — |
| `@protobufjs/pool` | `1.1.0` | 生产 | — |
| `@protobufjs/utf8` | `1.1.0` | 生产 | — |
| `@quansync/fs` | `1.0.0` | 开发 | — |
| `@rolldown/binding-android-arm64` | `1.0.0-rc.11` | 开发 | — |
| `@rolldown/binding-darwin-arm64` | `1.0.0-rc.11` | 开发 | — |
| `@rolldown/binding-darwin-x64` | `1.0.0-rc.11` | 开发 | — |
| `@rolldown/binding-freebsd-x64` | `1.0.0-rc.11` | 开发 | — |
| `@rolldown/binding-linux-arm-gnueabihf` | `1.0.0-rc.11` | 开发 | — |
| `@rolldown/binding-linux-arm64-gnu` | `1.0.0-rc.11` | 开发 | — |
| `@rolldown/binding-linux-arm64-musl` | `1.0.0-rc.11` | 开发 | — |
| `@rolldown/binding-linux-ppc64-gnu` | `1.0.0-rc.11` | 开发 | — |
| `@rolldown/binding-linux-s390x-gnu` | `1.0.0-rc.11` | 开发 | — |
| `@rolldown/binding-linux-x64-gnu` | `1.0.0-rc.11` | 开发 | — |
| `@rolldown/binding-linux-x64-musl` | `1.0.0-rc.11` | 开发 | — |
| `@rolldown/binding-openharmony-arm64` | `1.0.0-rc.11` | 开发 | — |
| `@rolldown/binding-wasm32-wasi` | `1.0.0-rc.11` | 开发 | — |
| `@rolldown/binding-win32-arm64-msvc` | `1.0.0-rc.11` | 开发 | — |
| `@rolldown/binding-win32-x64-msvc` | `1.0.0-rc.11` | 开发 | — |
| `@rolldown/pluginutils` | `1.0.0-rc.11` | 开发 | — |
| `@silvia-odwyer/photon-node` | `0.3.4` | 生产 | — |
| `@smithy/core` | `3.24.6` | 生产 | — |
| `@smithy/credential-provider-imds` | `4.3.8` | 生产 | — |
| `@smithy/fetch-http-handler` | `5.4.6` | 生产 | — |
| `@smithy/is-array-buffer` | `2.2.0` | 生产 | — |
| `@smithy/node-http-handler` | `4.7.3` | 生产 | — |
| `@smithy/node-http-handler` | `4.7.7` | 生产 | — |
| `@smithy/signature-v4` | `5.4.6` | 生产 | — |
| `@smithy/types` | `4.14.3` | 生产 | — |
| `@smithy/util-buffer-from` | `2.2.0` | 生产 | — |
| `@smithy/util-utf8` | `2.3.0` | 生产 | — |
| `@swc/core-darwin-arm64` | `1.15.18` | 生产 | — |
| `@swc/core-darwin-x64` | `1.15.18` | 生产 | — |
| `@swc/core-linux-arm-gnueabihf` | `1.15.18` | 生产 | — |
| `@swc/core-linux-arm64-gnu` | `1.15.18` | 生产 | — |
| `@swc/core-linux-arm64-musl` | `1.15.18` | 生产 | — |
| `@swc/core-linux-x64-gnu` | `1.15.18` | 生产 | — |
| `@swc/core-linux-x64-musl` | `1.15.18` | 生产 | — |
| `@swc/core-win32-arm64-msvc` | `1.15.18` | 生产 | — |
| `@swc/core-win32-ia32-msvc` | `1.15.18` | 生产 | — |
| `@swc/core-win32-x64-msvc` | `1.15.18` | 生产 | — |
| `@swc/core` | `1.15.18` | 生产 | postinstall |
| `@swc/counter` | `0.1.3` | 生产 | — |
| `@swc/types` | `0.1.25` | 生产 | — |
| `@temporalio/activity` | `1.15.0` | 生产 | — |
| `@temporalio/client` | `1.15.0` | 生产 | — |
| `@temporalio/common` | `1.15.0` | 生产 | — |
| `@temporalio/core-bridge` | `1.15.0` | 生产 | — |
| `@temporalio/nexus` | `1.15.0` | 生产 | — |
| `@temporalio/proto` | `1.15.0` | 生产 | — |
| `@temporalio/worker` | `1.15.0` | 生产 | — |
| `@temporalio/workflow` | `1.15.0` | 生产 | — |
| `@tybys/wasm-util` | `0.10.1` | 开发 | prepare |
| `@types/eslint-scope` | `3.7.7` | 生产 | — |
| `@types/eslint` | `9.6.1` | 生产 | — |
| `@types/estree` | `1.0.8` | 生产 | — |
| `@types/js-yaml` | `4.0.9` | 开发 | — |
| `@types/jsesc` | `2.5.1` | 开发 | — |
| `@types/json-schema` | `7.0.15` | 生产 | — |
| `@types/node` | `25.5.0` | 生产 | — |
| `@types/retry` | `0.12.0` | 生产 | — |
| `@webassemblyjs/ast` | `1.14.1` | 生产 | — |
| `@webassemblyjs/floating-point-hex-parser` | `1.13.2` | 生产 | — |
| `@webassemblyjs/helper-api-error` | `1.13.2` | 生产 | — |
| `@webassemblyjs/helper-buffer` | `1.14.1` | 生产 | — |
| `@webassemblyjs/helper-numbers` | `1.13.2` | 生产 | — |
| `@webassemblyjs/helper-wasm-bytecode` | `1.13.2` | 生产 | — |
| `@webassemblyjs/helper-wasm-section` | `1.14.1` | 生产 | — |
| `@webassemblyjs/ieee754` | `1.13.2` | 生产 | — |
| `@webassemblyjs/leb128` | `1.13.2` | 生产 | — |
| `@webassemblyjs/utf8` | `1.13.2` | 生产 | — |
| `@webassemblyjs/wasm-edit` | `1.14.1` | 生产 | — |
| `@webassemblyjs/wasm-gen` | `1.14.1` | 生产 | — |
| `@webassemblyjs/wasm-opt` | `1.14.1` | 生产 | — |
| `@webassemblyjs/wasm-parser` | `1.14.1` | 生产 | — |
| `@webassemblyjs/wast-printer` | `1.14.1` | 生产 | — |
| `@xtuc/ieee754` | `1.2.0` | 生产 | — |
| `@xtuc/long` | `4.2.2` | 生产 | — |
| `abort-controller` | `3.0.0` | 生产 | — |
| `accepts` | `2.0.0` | 生产 | — |
| `acorn-import-phases` | `1.0.4` | 生产 | — |
| `acorn` | `8.16.0` | 生产 | prepare |
| `agent-base` | `7.1.4` | 生产 | — |
| `ajv-formats` | `2.1.1` | 生产 | — |
| `ajv-formats` | `3.0.1` | 生产 | — |
| `ajv-keywords` | `5.1.0` | 生产 | — |
| `ajv` | `8.18.0` | 生产 | — |
| `ansi-regex` | `5.0.1` | 生产 | — |
| `ansi-styles` | `4.3.0` | 生产 | — |
| `ansis` | `4.2.0` | 开发 | — |
| `argparse` | `2.0.1` | 生产 | — |
| `ast-kit` | `3.0.0-beta.1` | 开发 | — |
| `balanced-match` | `4.0.4` | 生产 | prepare |
| `base64-js` | `1.5.1` | 生产 | — |
| `baseline-browser-mapping` | `2.10.8` | 生产 | — |
| `bignumber.js` | `9.3.1` | 生产 | — |
| `birpc` | `4.0.0` | 开发 | — |
| `body-parser` | `2.2.2` | 生产 | — |
| `bowser` | `2.14.1` | 生产 | — |
| `brace-expansion` | `5.0.6` | 生产 | prepare |
| `browserslist` | `4.28.1` | 生产 | — |
| `buffer-equal-constant-time` | `1.0.1` | 生产 | — |
| `buffer-from` | `1.1.2` | 生产 | — |
| `bytes` | `3.1.2` | 生产 | — |
| `cac` | `7.0.0` | 开发 | — |
| `call-bind-apply-helpers` | `1.0.2` | 生产 | — |
| `call-bound` | `1.0.4` | 生产 | — |
| `caniuse-lite` | `1.0.30001778` | 生产 | — |
| `chalk` | `5.6.2` | 生产 | — |
| `chokidar` | `5.0.0` | 生产 | — |
| `chrome-trace-event` | `1.0.4` | 生产 | — |
| `cliui` | `8.0.1` | 生产 | prepare |
| `color-convert` | `2.0.1` | 生产 | — |
| `color-name` | `1.1.4` | 生产 | — |
| `commander` | `2.20.3` | 生产 | — |
| `content-disposition` | `1.1.0` | 生产 | — |
| `content-type` | `1.0.5` | 生产 | — |
| `cookie-signature` | `1.2.2` | 生产 | — |
| `cookie` | `0.7.2` | 生产 | — |
| `cors` | `2.8.6` | 生产 | — |
| `cross-spawn` | `7.0.6` | 生产 | — |
| `data-uri-to-buffer` | `4.0.1` | 生产 | — |
| `debug` | `4.4.3` | 生产 | — |
| `defu` | `6.1.4` | 开发 | — |
| `depd` | `2.0.0` | 生产 | — |
| `diff` | `8.0.4` | 生产 | — |
| `dotenv` | `16.6.1` | 生产 | — |
| `dotenv` | `17.3.1` | 生产 | — |
| `dts-resolver` | `2.1.3` | 开发 | — |
| `dunder-proto` | `1.0.1` | 生产 | — |
| `ecdsa-sig-formatter` | `1.0.11` | 生产 | — |
| `ee-first` | `1.1.1` | 生产 | — |
| `electron-to-chromium` | `1.5.313` | 生产 | — |
| `emoji-regex` | `8.0.0` | 生产 | — |
| `empathic` | `2.0.0` | 开发 | — |
| `encodeurl` | `2.0.0` | 生产 | — |
| `enhanced-resolve` | `5.20.0` | 生产 | prepare |
| `es-define-property` | `1.0.1` | 生产 | — |
| `es-errors` | `1.3.0` | 生产 | — |
| `es-module-lexer` | `2.0.0` | 生产 | — |
| `es-object-atoms` | `1.1.1` | 生产 | — |
| `escalade` | `3.2.0` | 生产 | — |
| `escape-html` | `1.0.3` | 生产 | — |
| `eslint-scope` | `5.1.1` | 生产 | — |
| `esrecurse` | `4.3.0` | 生产 | — |
| `estraverse` | `4.3.0` | 生产 | — |
| `estraverse` | `5.3.0` | 生产 | — |
| `estree-walker` | `3.0.3` | 开发 | — |
| `etag` | `1.8.1` | 生产 | — |
| `event-target-shim` | `5.0.1` | 生产 | — |
| `events` | `3.3.0` | 生产 | — |
| `eventsource-parser` | `3.0.6` | 生产 | — |
| `eventsource` | `3.0.7` | 生产 | prepare |
| `express-rate-limit` | `8.3.2` | 生产 | prepare |
| `express` | `5.2.1` | 生产 | — |
| `extend` | `3.0.2` | 生产 | — |
| `fast-deep-equal` | `3.1.3` | 生产 | — |
| `fast-uri` | `3.1.2` | 生产 | — |
| `fast-xml-builder` | `1.2.0` | 生产 | — |
| `fast-xml-parser` | `5.7.3` | 生产 | — |
| `fdir` | `6.5.0` | 开发 | — |
| `fetch-blob` | `3.2.0` | 生产 | — |
| `finalhandler` | `2.1.1` | 生产 | — |
| `formdata-polyfill` | `4.0.10` | 生产 | — |
| `forwarded` | `0.2.0` | 生产 | — |
| `fresh` | `2.0.0` | 生产 | — |
| `fs-monkey` | `1.1.0` | 生产 | — |
| `function-bind` | `1.1.2` | 生产 | — |
| `gaxios` | `7.1.5` | 生产 | prepare |
| `gcp-metadata` | `8.1.2` | 生产 | prepare |
| `get-caller-file` | `2.0.5` | 生产 | prepare |
| `get-east-asian-width` | `1.6.0` | 生产 | — |
| `get-intrinsic` | `1.3.0` | 生产 | — |
| `get-proto` | `1.0.1` | 生产 | — |
| `get-tsconfig` | `4.13.6` | 开发 | — |
| `glob-to-regex.js` | `1.2.0` | 生产 | — |
| `glob-to-regexp` | `0.4.1` | 生产 | — |
| `google-auth-library` | `10.7.0` | 生产 | prepare |
| `google-logging-utils` | `1.1.3` | 生产 | prepare |
| `gopd` | `1.2.0` | 生产 | — |
| `graceful-fs` | `4.2.11` | 生产 | — |
| `grok-mermaid` | `0.2.2` | 生产 | — |
| `handlebars` | `4.7.9` | 生产 | — |
| `has-flag` | `4.0.0` | 生产 | — |
| `has-symbols` | `1.1.0` | 生产 | — |
| `hasown` | `2.0.2` | 生产 | — |
| `heap-js` | `2.7.1` | 生产 | — |
| `highlight.js` | `10.7.3` | 生产 | — |
| `hono` | `4.12.14` | 生产 | — |
| `hookable` | `6.1.0` | 开发 | — |
| `hosted-git-info` | `9.0.3` | 生产 | — |
| `http-errors` | `2.0.1` | 生产 | — |
| `http-proxy-agent` | `7.0.2` | 生产 | — |
| `https-proxy-agent` | `7.0.6` | 生产 | — |
| `hyperdyperid` | `1.2.0` | 生产 | — |
| `iconv-lite` | `0.6.3` | 生产 | — |
| `iconv-lite` | `0.7.2` | 生产 | — |
| `ignore` | `7.0.5` | 生产 | — |
| `import-without-cache` | `0.2.5` | 开发 | — |
| `inherits` | `2.0.4` | 生产 | — |
| `ip-address` | `10.1.0` | 生产 | — |
| `ipaddr.js` | `1.9.1` | 生产 | — |
| `is-fullwidth-code-point` | `3.0.0` | 生产 | — |
| `is-promise` | `4.0.0` | 生产 | — |
| `isexe` | `2.0.0` | 生产 | — |
| `jest-worker` | `27.5.1` | 生产 | — |
| `jiti` | `2.7.0` | 生产 | — |
| `jose` | `6.2.2` | 生产 | — |
| `js-yaml` | `4.1.1` | 生产 | — |
| `jsesc` | `3.1.0` | 开发 | — |
| `json-bigint` | `1.0.0` | 生产 | — |
| `json-parse-even-better-errors` | `2.3.1` | 生产 | — |
| `json-schema-to-ts` | `3.1.1` | 生产 | — |
| `json-schema-traverse` | `1.0.0` | 生产 | — |
| `json-schema-typed` | `8.0.2` | 生产 | — |
| `jwa` | `2.0.1` | 生产 | — |
| `jws` | `4.0.1` | 生产 | — |
| `loader-runner` | `4.3.1` | 生产 | — |
| `lodash.camelcase` | `4.3.0` | 生产 | — |
| `long` | `5.3.2` | 生产 | — |
| `lru-cache` | `11.5.1` | 生产 | prepare |
| `marked` | `18.0.5` | 生产 | — |
| `math-intrinsics` | `1.1.0` | 生产 | — |
| `media-typer` | `1.1.0` | 生产 | — |
| `memfs` | `4.56.11` | 生产 | — |
| `merge-descriptors` | `2.0.0` | 生产 | — |
| `merge-stream` | `2.0.0` | 生产 | — |
| `mime-db` | `1.52.0` | 生产 | — |
| `mime-db` | `1.54.0` | 生产 | — |
| `mime-types` | `2.1.35` | 生产 | — |
| `mime-types` | `3.0.2` | 生产 | — |
| `minimatch` | `10.2.5` | 生产 | prepare |
| `minimist` | `1.2.8` | 生产 | — |
| `ms` | `2.1.3` | 生产 | — |
| `ms` | `3.0.0-canary.1` | 生产 | prepare |
| `negotiator` | `1.0.0` | 生产 | — |
| `neo-async` | `2.6.2` | 生产 | — |
| `nexus-rpc` | `0.0.1` | 生产 | prepare |
| `node-addon-api` | `8.8.0` | 生产 | — |
| `node-domexception` | `1.0.0` | 生产 | — |
| `node-fetch` | `3.3.2` | 生产 | — |
| `node-gyp-build` | `4.8.4` | 生产 | — |
| `node-releases` | `2.0.36` | 生产 | — |
| `object-assign` | `4.1.1` | 生产 | — |
| `object-inspect` | `1.13.4` | 生产 | — |
| `obug` | `2.1.1` | 开发 | — |
| `on-finished` | `2.4.1` | 生产 | — |
| `once` | `1.4.0` | 生产 | — |
| `openai` | `6.40.0` | 生产 | — |
| `p-retry` | `4.6.2` | 生产 | — |
| `parseurl` | `1.3.3` | 生产 | — |
| `partial-json` | `0.1.7` | 生产 | — |
| `path-expression-matcher` | `1.5.0` | 生产 | — |
| `path-key` | `3.1.1` | 生产 | — |
| `path-to-regexp` | `8.4.2` | 生产 | prepare |
| `pathe` | `2.0.3` | 开发 | — |
| `picocolors` | `1.1.1` | 生产 | — |
| `picomatch` | `4.0.4` | 开发 | — |
| `pkce-challenge` | `5.0.1` | 生产 | — |
| `proper-lockfile` | `4.1.2` | 生产 | — |
| `proto3-json-serializer` | `2.0.2` | 生产 | prepare |
| `protobufjs` | `7.5.5` | 生产 | postinstall |
| `proxy-addr` | `2.0.7` | 生产 | — |
| `qs` | `6.15.1` | 生产 | — |
| `quansync` | `1.0.0` | 开发 | — |
| `range-parser` | `1.2.1` | 生产 | — |
| `raw-body` | `3.0.2` | 生产 | — |
| `readdirp` | `5.0.0` | 生产 | — |
| `require-directory` | `2.1.1` | 生产 | — |
| `require-from-string` | `2.0.2` | 生产 | — |
| `resolve-pkg-maps` | `1.0.0` | 开发 | — |
| `retry` | `0.12.0` | 生产 | — |
| `retry` | `0.13.1` | 生产 | — |
| `rolldown-plugin-dts` | `0.22.5` | 开发 | — |
| `rolldown` | `1.0.0-rc.11` | 开发 | — |
| `router` | `2.2.0` | 生产 | — |
| `rxjs` | `7.8.2` | 生产 | — |
| `safe-buffer` | `5.2.1` | 生产 | — |
| `safer-buffer` | `2.1.2` | 生产 | — |
| `schema-utils` | `4.3.3` | 生产 | prepare |
| `semver` | `7.7.4` | 开发 | — |
| `semver` | `7.8.0` | 生产 | — |
| `send` | `1.2.1` | 生产 | — |
| `serve-static` | `2.2.1` | 生产 | — |
| `setprototypeof` | `1.2.0` | 生产 | — |
| `shebang-command` | `2.0.0` | 生产 | — |
| `shebang-regex` | `3.0.0` | 生产 | — |
| `side-channel-list` | `1.0.1` | 生产 | — |
| `side-channel-map` | `1.0.1` | 生产 | — |
| `side-channel-weakmap` | `1.0.2` | 生产 | — |
| `side-channel` | `1.1.0` | 生产 | — |
| `signal-exit` | `3.0.7` | 生产 | — |
| `sisteransi` | `1.0.5` | 生产 | — |
| `smol-toml` | `1.6.1` | 生产 | — |
| `source-map-js` | `1.2.1` | 生产 | — |
| `source-map-loader` | `4.0.2` | 生产 | prepare |
| `source-map-support` | `0.5.21` | 生产 | — |
| `source-map` | `0.6.1` | 生产 | — |
| `source-map` | `0.7.6` | 生产 | — |
| `statuses` | `2.0.2` | 生产 | — |
| `string-width` | `4.2.3` | 生产 | — |
| `strip-ansi` | `6.0.1` | 生产 | — |
| `strnum` | `2.3.0` | 生产 | — |
| `supports-color` | `8.1.1` | 生产 | — |
| `swc-loader` | `0.2.7` | 生产 | — |
| `tapable` | `2.3.0` | 生产 | — |
| `terser-webpack-plugin` | `5.4.0` | 生产 | prepare |
| `terser` | `5.46.0` | 生产 | prepare |
| `thingies` | `2.5.0` | 生产 | — |
| `tinyexec` | `1.0.4` | 开发 | prepare |
| `tinyglobby` | `0.2.15` | 开发 | — |
| `toidentifier` | `1.0.1` | 生产 | — |
| `tree-dump` | `1.1.0` | 生产 | — |
| `tree-kill` | `1.2.2` | 开发 | — |
| `tree-sitter-bash` | `0.25.1` | 生产 | install |
| `ts-algebra` | `2.0.0` | 生产 | — |
| `tsdown` | `0.21.5` | 开发 | — |
| `tslib` | `2.8.1` | 生产 | — |
| `turbo-darwin-64` | `2.8.17` | 开发 | — |
| `turbo-darwin-arm64` | `2.8.17` | 开发 | — |
| `turbo-linux-64` | `2.8.17` | 开发 | — |
| `turbo-linux-arm64` | `2.8.17` | 开发 | — |
| `turbo-windows-64` | `2.8.17` | 开发 | — |
| `turbo-windows-arm64` | `2.8.17` | 开发 | — |
| `turbo` | `2.8.17` | 开发 | — |
| `type-is` | `2.0.1` | 生产 | — |
| `typebox` | `1.1.38` | 生产 | — |
| `typebox` | `1.3.7` | 生产 | — |
| `typescript` | `5.9.3` | 开发 | — |
| `uglify-js` | `3.19.3` | 生产 | — |
| `unconfig-core` | `7.5.0` | 开发 | — |
| `undici-types` | `7.18.2` | 生产 | — |
| `undici` | `8.9.0` | 生产 | prepare |
| `unionfs` | `4.6.0` | 生产 | — |
| `unpipe` | `1.0.0` | 生产 | — |
| `unrun` | `0.2.33` | 开发 | — |
| `update-browserslist-db` | `1.2.3` | 生产 | — |
| `uuid` | `11.1.0` | 生产 | prepare |
| `vary` | `1.1.2` | 生产 | — |
| `watchpack` | `2.5.1` | 生产 | — |
| `web-streams-polyfill` | `3.3.3` | 生产 | prepare |
| `web-tree-sitter` | `0.26.9` | 生产 | — |
| `webpack-sources` | `3.3.4` | 生产 | — |
| `webpack` | `5.105.4` | 生产 | prepare |
| `which` | `2.0.2` | 生产 | — |
| `wordwrap` | `1.0.0` | 生产 | — |
| `wrap-ansi` | `7.0.0` | 生产 | — |
| `wrappy` | `1.0.2` | 生产 | — |
| `ws` | `8.21.0` | 生产 | — |
| `xml-naming` | `0.1.0` | 生产 | — |
| `y18n` | `5.0.8` | 生产 | prepare |
| `yaml` | `2.9.0` | 生产 | — |
| `yargs-parser` | `21.1.1` | 生产 | prepare |
| `yargs` | `17.7.2` | 生产 | prepare |
| `zod-to-json-schema` | `3.25.2` | 生产 | — |
| `zod` | `4.3.6` | 生产 | — |
| `zx` | `8.8.5` | 生产 | — |

共 464 行。生产 390，开发 74。
