# 验收矩阵

审计对象：<https://github.com/KeygraphHQ/shannon>  
本单基准：`3760d2f9df9f3afa374a8eb2473adadfbf9ed991`（2026-11-26 04:51:49 香港时间）  
旧基准：`4cef63e5900c9eda0b259a44f89458c7f8b1e10d`  
矩阵填写时间：2026-11-26 09:40 香港时间（Asia/Hong_Kong）。查询记录的具体时钟见 `supply-chain.md`。

用户给出的 R1–R7 全部保留。后表是执行中补的检查行。

| ID | 需求 | 检查项 | 证据 | 结论 | 未覆盖 |
|---|---|---|---|---|---|
| R1 | 对用户指定的本仓、本单固定基准 SHA 做只读静态重审 | 记录上游 URL、默认分支、基准 SHA、提交时间（香港时间）；只读源码、清单与锁文件 | `git fetch` 后 `rev-parse` 为 `3760d2f9df9f3afa374a8eb2473adadfbf9ed991`；作者 George Flores，作者日期 `2026-11-25T12:51:49-08:00`，即 2026-11-26 04:51:49 香港时间；提交说明为 `feat(plugin): prepare Shannon plugin for Claude and OpenAI directory listings (#545)` | 已按该树阅读。fork `Silver-cybersec/shannon` 的 `main` 仍停在旧基准，本单未把它当作审计对象 | 无。SHA 已检出 |
| R2 | 代码安全 | 故意漏洞与对部署者／宿主机的真实风险分开；危险执行、默认凭据、硬编码密钥、数据外传、隔离、暴露面、容器／宿主挂载；按高／中／低分级 | `audit/findings.json`；主报告第 3 节 | 高 2、中 4、低 4。未发现产品内故意漏洞或隐藏后门。部署者风险来自入口脚本把参数重新送进 shell，以及带密钥的代理容器沙箱过弱 | 未做动态逃逸、未对任何目标发包、未验证容器出站是否被宿主机策略挡住 |
| R3 | 架构（含与学习目标相称的功能阅读） | 主要组件、信任边界、数据与权限流；关键流程能否被绕过的已读证据 | 主报告第 2 节所列路径与行号 | 主机 CLI、Temporal 开发服务器、worker 容器、可选编辑器插件四段。Capella 静态分析限制工具集；渗透代理默认有 `bash`。多处防护只覆盖预检或提示词 | 未逐份读完全部提示词，未做宣称对照全表。Capella 每个阶段的内部数据格式未逐项展开 |
| R4 | 供应链，且必须单列「依赖是否恶意」 | 锁文件、镜像、子模块、curl/wget、版本与校验和、仿冒包名、安装钩子、非官方源、OSV／GHSA | `audit/supply-chain.md`。OSV 与 npm、Docker Hub 查询时间为 2026-11-26 09:40 香港时间 | 未见恶意包通告或仿冒包名。该结论只覆盖已查询对象。直接依赖里 handlebars、smol-toml、js-yaml 落入公开漏洞区间；基础镜像与 Typst 下载无摘要／校验和 | 456 个锁定包未逐包查 OSV、未读源码。未拉取任何镜像层。Chainguard 仓库返回 401。pi 目录刷新的具体主机在 SDK 内，未安装依赖，未核实 |
| R5 | 产出精练中文报告 | 四个交付文件；每节先结论再短分条 | 本目录四个文件 | 已写在本分支，仅新增 `audit/` | 无运行录像、无镜像层清单、无旧报告全文附件 |
| R6 | 对照旧审计基准 | `4cef63e5...3760d2f9`；旧结论逐项标仍成立／已变化／未覆盖 | 本地 `merge-base` 等于旧基准；ahead 15、behind 0。主报告第 5 节 | 旧结论「未见隐藏后门」「实验室部署风险高」「供应链中」仍成立。新增插件与 pi 主版本升级改变了信任边界和依赖面，没有把宿主风险降下来。入口脚本问题在旧树已存在，旧结论未单列 | 旧报告全文与飞书卡不在本树，未读取 |
| R7 | 不新建私库、不改产品代码、不把静态阅读写成已运行验证 | 交付物与表述 | 本 PR 只新增 `audit/` 四个文件 | 符合。未写「已验证可部署」 | — |
| R8 | 功能与使用：README／文档宣称与实现是否一致；安装后怎么用 | 逐条宣称→文件:行号→一致／部分／不符／未找到；主要命令、关键配置默认值、一条典型工作流 | 主报告第 8 节。对照 `README.md`、`docs/development.md`、`docs/configuration.md`、`docs/coverage-roadmap.md` 与 CLI／workflow 源码 | 主路径一致。部分：SAST 默认可选但架构图未标明、`exploit: false` 仍出分析报告、裸 npx 只引导 setup、五类之外另有 miscellaneous、`logs` 帮助未列 `--agent`。不符：`docs/configuration.md:24` 的 `configs/example-config.yaml` 在本树不存在。未找到：本仓内的 GitHub Action／GitLab 组件。全部未实测 | 外部 Action／GitLab 仓未读；未逐份读提示词；未实际执行任何命令 |
| R9 | 编译与部署要求 | Dockerfile／compose／包管理器、语言与外部服务版本、硬件、外网依赖、文档与代码不符 | 主报告第 9 节。`Dockerfile`、两份 compose、`package.json`、`docs/development.md`、`docs/platforms.md` | 无 Makefile。pnpm 构建加 `./shannon build`；npx 拉 Docker Hub；compose 只起 Temporal（内嵌 `temporal.db`）。文档要求 Node 22+，`apps/cli/package.json` 为 `>=18` 且 CLI 不检查版本。未写 GPU／内存下限；代码有 `--shm-size 2gb`。全部未实测，不得称为已验证可部署 | 未执行 `pnpm install`、`pnpm build`、`docker build` 或 compose。镜像层仍未拉取 |

## 执行中补充的检查行

| ID | 需求 | 检查项 | 证据 | 结论 | 未覆盖 |
|---|---|---|---|---|---|
| R2-1 | 危险执行 | 入口脚本是否把 URL、仓库目录名重新送进 shell | `entrypoint.sh:18`；`apps/cli/src/docker.ts:512`；`apps/cli/src/paths.ts:91-94`；`apps/cli/src/index.ts:229-238`。本机 bash 复核了相同引号语义 | 高。见 SHANNON-H1。已确认 | 未在真实容器里启动 worker |
| R2-2 | 隔离与挂载 | seccomp、网络、密钥、只读仓库、宿主 hosts、Temporal | `apps/cli/src/docker.ts:431-506`；`docker-compose.yml:7-12`；`apps/cli/src/env.ts:96-112` | 高。见 SHANNON-H2。代码配置已确认 | 未验证从容器访问宿主环回或云元数据是否真的通 |
| R2-3 | 硬编码密钥 | 源码与示例配置中的口令、密钥形态 | 检索 `apps/`、`plugins/`、文档示例 | 未发现可用生产密钥。示例与基准文档含占位口令，只记位置，不抄录 | 未扫描历史提交中已删除的密钥 |
| R2-4 | 数据外传 | `fetch`、遥测 SDK、固定外联主机 | `cyber-access-verification.ts`；`models.ts:243`；`exp-php2shell/transport.ts` | 未见独立遥测。外联是操作者配置的模型端点，以及操作者指定的探测 URL。`staging.keygraph.io` 只出现在预检提示词文本里 | pi SDK 刷新目录时的请求体未核实 |
| R2-5 | 故意漏洞 | 仓内是否带靶场或可利用的演示应用 | `repos/.gitkeep`；`benchmark/` 为既有报告文件；`sample-reports/` 为第三方目标的历史报告 | 本仓没有随附可运行靶场。`--exp-php2shell` 是对操作者指定 URL 的崩溃探测，源码写明不发送后续代码执行请求 | 未动态确认探测是否停在崩溃步骤 |
| R3-1 | 权限流能否绕过 | 工作区名、URL 协议、元数据拦截、认证文件判定、Capella 工具禁令 | `start.ts:307-308`；`preflight.ts:65-78`；`validate-authentication.ts:240-252`；`capella-agent-executor.ts:54-73` | 工作区名有白名单。元数据拦截不约束代理的 `bash`。认证成功判定接受空数组。Capella 禁止 bash，渗透代理没有同等限制 | 未跑通登录预检 |
| R4-1 | 安装钩子与非官方源 | `.npmrc`、`onlyBuiltDependencies`、锁文件源字段、CI action pin | `.npmrc`；根 `package.json:22-26`；`pnpm-lock.yaml`；`.github/workflows/release.yml` | 默认忽略脚本；允许 `@swc/core` 与 `protobufjs` 构建。锁文件未见 git／tarball 源。Actions 用提交 SHA 固定。`npx semantic-release@25` 只固定主版本 | 未执行安装，未观察脚本实际行为 |
