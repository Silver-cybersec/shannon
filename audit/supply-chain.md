# 供应链

基准：<https://github.com/KeygraphHQ/shannon/tree/3760d2f9df9f3afa374a8eb2473adadfbf9ed991>  
查询时钟：2026-11-26 09:40:50 香港时间（本环境 `TZ=Asia/Hong_Kong date`）。OSV 使用 `https://api.osv.dev/v1/querybatch` 与 `/v1/vulns/{id}`。包元数据使用 `https://registry.npmjs.org`。镜像标签使用 Docker Hub HTTP API。未执行 `pnpm install`，未 `docker pull`，未运行构建脚本。

## 结论

已查询的直接依赖和两个允许执行安装脚本的包，没有 OSV 恶意包条目，npm 元数据也指向公开上游仓库，未见仿冒包名。这只说明这些对象没有公开恶意通告。锁文件中其余传递依赖、未拉取的镜像层，以及 pi SDK 内部的目录请求，都还没有核实到可以排除恶意或后门的程度。与此同时，若干锁定版本落在公开漏洞区间内，基础镜像使用浮动标签，Typst 二进制下载没有校验和。供应链风险维持在中，和旧审计的「中」一致；pi 从 0.84.4 升到 1.5.0 是这 15 个提交里最大的依赖面变化。

## 依赖是否恶意

结论：对已查询对象，未发现恶意包证据；未查询对象保持未核实，不能写成无恶意。

已查询且无 OSV 漏洞、也无恶意条目的直接依赖：

- `@earendil-works/pi-agent-core@1.5.0`、`pi-ai@1.5.0`、`pi-coding-agent@1.5.0`
- `@gotgenes/pi-permission-system@42.0.0`
- `@temporalio/activity`、`client`、`worker`、`workflow`，均为 `1.15.0`
- `@biomejs/biome@2.4.7`、`@clack/prompts@1.1.0`、`chokidar@5.0.0`、`dotenv@17.3.1` 与 `16.6.1`、`tsdown@0.21.5`、`ajv@8.18.0`、`ajv-formats@2.1.1`、`typebox@1.1.38`、`zx@8.8.5`、`typescript@5.9.3`、`@types/node@25.5.0`
- `@swc/core@1.15.18`（允许构建脚本；OSV 对该版本返回空）

npm 元数据（同一查询时钟）与公开上游一致，不像仿冒包：

| 包 | latest（仅作对照，锁文件不是这个版本） | 仓库 | 维护者 |
|---|---|---|---|
| `@earendil-works/pi-coding-agent` | 1.6.1（2026-11-25 21:41 香港时间，原始 `2026-11-25T13:41:09Z`） | `github.com/earendil-works/pi` | mitsuhiko, badlogic, rwachtler |
| `@gotgenes/pi-permission-system` | 43.0.0（2026-11-26 01:38 香港时间，原始 `2026-11-25T17:38:01Z`） | `github.com/gotgenes/pi-packages` | gotgenes |
| `smol-toml` | 1.9.1 | `github:squirrelchat/smol-toml` | cyyynthia |
| `@keygraph/shannon` | 3.6.1（2026-11-21 05:42 香港时间，原始 `2026-11-20T21:42:43Z`） | `github.com/KeygraphHQ/shannon` | keygraph-admin |

锁文件版本低于 registry 的 latest。本单不把「不是最新」写成漏洞，只把 OSV 标成受影响的版本记入下一节。

未核实，因此不写成无恶意：

- `pnpm-lock.yaml` 中 456 个锁定包里，除上表和下一节点名的包以外，没有逐个查询 OSV，也没有阅读 tarball。
- 没有安装 `node_modules`，没有审计 pi、Temporal、zx 的安装后代码。
- `@playwright/cli@0.1.1` 与 `pnpm@10.33.0` 在 `Dockerfile` 里全局安装，不在锁文件中，未查 OSV。
- 镜像层未拉取。Chainguard 的 tag 列表接口返回 401。

## 锁定版本与公开漏洞

结论：五组锁定版本被 OSV 标为受影响。其中 handlebars 的公告是脚本注入，严重度最高，但本仓调用点编译的是产品自带模板，本单没有证明扫描目标能把模板源送进 `compile()`。

| 包与锁定版本 | 角色 | OSV（2026-11-26 09:40 香港时间） | 本仓用法与可达性 |
|---|---|---|---|
| `handlebars@4.7.9` | worker 直接依赖 | GHSA-8r5x-fm3f-whwj / CVE-2026-106446、GHSA-p8wg-vrv2-v86f / CVE-2026-106445、GHSA-xw65-4hp5-5hc7 / CVE-2026-106444。公告写明修复于 4.7.10。前两条为脚本注入，CVSS 3.1 可达 9.8 量级 | `apps/worker/src/ai/sast/capella/prompt-loader.ts:83` 以 `noEscape: true` 编译仓库内 `.hbs`。部分确认：版本受影响已核实；外部输入进入 `compile()` 未证实 |
| `smol-toml@1.6.1` | CLI 直接依赖 | GHSA-7w5x-hrqm-74c2 / CVE-2026-85730（修复 1.7.1）、GHSA-r4xh-jqrq-34v2（修复 1.9.0）。均为解析拒绝服务 | CLI 用它解析 `~/.shannon/config.toml`。攻击者需要让操作者打开恶意文件。低 |
| `js-yaml@4.1.1` | worker 直接依赖 | GHSA-2883-xcg3-v3hh / CVE-2026-84375、GHSA-52cp-r559-cp3m / CVE-2026-59869、GHSA-5p4m-2wfm-xmqj、GHSA-h67p-54hq-rp68 / CVE-2026-53550。修复分布在 4.2.0–4.3.2，均为 CPU 拒绝服务 | `apps/worker/src/config-parser.ts:230-231` 使用 `yaml.FAILSAFE_SCHEMA`。版本落在区间内已核实；FAILSAFE 路径是否仍能触发这些合并键问题，未对照 js-yaml 实现复核 |
| `protobufjs@7.5.5` | 传递依赖；根 `package.json` 允许它跑构建脚本 | 11 条 GHSA，包括代码注入与拒绝服务（例如 GHSA-66ff-xgx4-vchm、GHSA-75px-5xx7-5xc7）。修复版本从 7.5.6 到 7.6.5 不等 | 业务源码没有直接 import。多半随 Temporal 进入。安装脚本在镜像构建时被允许执行。调用面未映射，未核实可利用性 |
| `turbo@2.8.17` | 根开发依赖 | GHSA-3qcw-2rhx-2726 / CVE-2026-45772（本地代码执行，修复 2.9.14）、GHSA-hcf7-66rw-9f5r / CVE-2026-45773 | 影响执行 turbo CLI 的开发者。`Dockerfile` 第二段是 `pnpm install --prod`，运行镜像应按此排除开发依赖。未拆镜像层，不能确认层内没有残留 |

建议是升级到各公告的修复版本，并重新生成锁文件。本单没有改产品依赖。

## 锁文件、钩子与源

结论：锁文件把 npm 依赖固定到 integrity，并默认跳过安装脚本；例外是两个构建包。没有子模块，没有仓库内的 `curl | sh`。

- 锁文件版本 9.0，路径 `pnpm-lock.yaml`。直接依赖版本见 `audit/matrix.md` 的查询笔记与本文件上一节。456 个锁定包。全文检索没有 `tarball:`、`git+`、`github:`、`gitlab:`、`jsr:` 依赖源。`file:` 的命中来自 `excludeLinksFromLockfile`、`proper-lockfile`、`get-caller-file` 这几个字面量，不是 `file:` 协议依赖。
- `.npmrc`：`ignore-scripts=true`，`minimum-release-age=10080`（7 天）。根 `package.json:22-26` 的 `onlyBuiltDependencies` 只有 `@swc/core` 与 `protobufjs`。镜像构建先复制 `.npmrc` 再 `pnpm install --frozen-lockfile`（`Dockerfile:29-33`）。
- 无 `.gitmodules`。
- 仓库脚本里没有把 `curl` 或 `wget` 管道给 shell。唯一的发布物下载是 Typst，见下节。
- CI：`.github/workflows/release.yml` 的 Actions 使用提交 SHA。发布作业另有 `npx semantic-release@25`（约第 49 与 239 行），主版本固定、精确版本不固定。这是发布流水线，不是扫描运行时。

相对旧基准 `4cef63e5`：`.npmrc` 未改。worker 的 pi 相关依赖从 `^0.84.4` / permission-system `^10.9.0` 改为 `^1.5.0` / `^42.0.0`（`94bf442d`，作者日期 2026-11-12 04:16 香港时间）。`pnpm-lock.yaml` 在该范围内有大段重写。旧「供应链中」不因这次升级自动下降。

## 容器镜像与二进制

结论：发布流程会签名镜像，但本仓的运行清单和 CLI 拉取都不固定摘要，也不在客户端校验签名。未拉取的层不能写成已确认安全。

| 对象 | 来源与标签 | 摘要／校验和 | 本单核对 |
|---|---|---|---|
| 构建与运行基础镜像 | `cgr.dev/chainguard/wolfi-base:latest`，`Dockerfile:5` 与 `:44` | 无 digest。浮动 `latest` | 标签列表接口 401。层未拉取。未核实 |
| 包管理器 | 同文件 `apk add`，包名无版本 | 无 | 未核实层内容 |
| Typst | `TYPST_VERSION=0.14.2`，`Dockerfile:82-95`，`curl -fsSL` GitHub Releases 的 tar.xz | 无校验和、无签名检查 | 只读到 Dockerfile。未下载该 tarball |
| Playwright CLI | `Dockerfile:119`，`npm install -g --ignore-scripts @playwright/cli@0.1.1` | 版本钉死，无仓库内 integrity | 未查 OSV，未安装 |
| pnpm | `Dockerfile:23`，`pnpm@10.33.0`，`--ignore-scripts` | 版本钉死 | 未查 OSV |
| Temporal | `temporalio/temporal:1.7.0`，`docker-compose.yml:7` 与 `apps/cli/infra/compose.yml:7` | 清单无 digest | Docker Hub 查询：标签 `1.7.0` 存在，`last_updated` 原始值 `2026-04-29T23:02:05Z`（2026-04-30 07:02 香港时间），标签 digest `sha256:9c5b386d86bca59ba08f32ddc4c51287351c8c616b6a8359f03e96a585e137f4`。这是标签元数据，不是层审计 |
| 发布的 worker 镜像 | CLI `apps/cli/src/docker.ts:25-42`：npx 模式拉取 `keygraph/shannon:<版本>`，无 digest，无 cosign 校验 | 发布工作流 `release.yml:139-166` 用 buildx digest 推送，并用 cosign 签名、验证 | Docker Hub 查询：`latest` 与 `3.6.1` 指向同一标签 digest `sha256:8040245b12ac96336eaedc659d36d82cb8c0e59c2987266caffb87b643c55782`，`last_updated` 原始值 `2026-11-20T21:38:52Z`（2026-11-21 05:38 香港时间）。该时间早于本单基准提交（2026-11-26 04:51 香港时间）。未核对镜像内容是否等于本 SHA，未拉取层 |

worker 镜像在本单基准上还不等于已发布的 `3.6.1` 标签。使用 `npx` 拉到的镜像，不能默认成这次读到的源码树。

## 与代码风险的交界

`zx` 在 `apps/worker/src/services/git-manager.ts:21` 等处以模板字符串执行 git。上游文档称插值会转义。本单未安装 zx，未复核其转义实现，不把这些调用记成已确认的命令注入。已确认的命令注入在 `entrypoint.sh`，见主报告 SHANNON-H1，那是产品脚本而不是依赖。
