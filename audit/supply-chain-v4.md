# 供应链补查（v4）

基准 SHA：[`3760d2f9df9f3afa374a8eb2473adadfbf9ed991`](https://github.com/KeygraphHQ/shannon/commit/3760d2f9df9f3afa374a8eb2473adadfbf9ed991)。已有长文在 `audit/supply-chain.md`（查询时钟 2026-11-26 09:40:50 香港时间）。本文件只补八项归类和当时未查的缺口。

本轮只读查询时钟：**2026-11-26 11:31:27 香港时间**。OSV：`https://api.osv.dev/v1/querybatch`（漏洞正文 `https://api.osv.dev/v1/vulns/{id}`）。包元数据：`https://registry.npmjs.org`。仓库是否归档：`https://api.github.com/repos/{owner}/{repo}`。未安装依赖，未拉镜像层，未运行仓库脚本或 CI。

结论只用四档。实证是文件或查询返回；推断单独标明。未拉取、未读脚本正文的，不写成安全。

## 八项结论

| 项 | 结论 | 证据要点 |
|---|---|---|
| 1 清单与 lockfile（含间接） | 未发现问题 | 有 `pnpm-lock.yaml`（lockfileVersion 9.0）。`packages:` 下 448 条带 `integrity` 的版本，含间接依赖 |
| 2 版本钉、校验和、git／URL 直装 | 已确认 | 锁内 npm 包有 integrity，且无 git／URL 直装。镜像构建里的 pnpm、Playwright CLI、Typst 不在锁内，后两者与 Typst 无仓库内校验和 |
| 3 仿冒包名、安装钩子、非官方源 | 未核实 | 427 个包名无已知恶意包名、无非 ASCII。钩子正文未取回。源为默认 npm registry |
| 4 镜像来源、tag、digest | 已确认 | `wolfi-base:latest` 无 digest；Temporal 与 CLI 拉取的 worker 镜像只钉 tag |
| 5 子模块、下载脚本、运行时远程拉取 | 已确认 | 无子模块、无 `curl\|bash`。有 Typst 的 `curl`、构建期全局 npm 安装，以及扫描期模型目录刷新 |
| 6 CI：SHA、密钥、危险触发 | 已确认 | `uses:` 均为提交 SHA。`npx semantic-release@25` 未钉 SHA。无 `pull_request_target` / `workflow_run`。密钥只出现在 `secrets.*` 引用 |
| 7a 依赖是否恶意（MAL-） | 未发现问题 | 448 个锁内版本加 `@playwright/cli@0.1.1`、`pnpm@10.33.0`，OSV 返回 0 条 `MAL-` |
| 7b 已知漏洞 | 已确认 | 21 个已查版本落在 GHSA 区间。新增重点是构建用的 `pnpm@10.33.0`（18 条） |
| 8 主要依赖维护状态 | 未发现问题 | 抽查的上游仓库均未归档、npm 版本未标 deprecated。其余传递包未逐个查 |

## 1. 清单与 lockfile

结论：**未发现问题**。`pnpm-lock.yaml:1` 为 lockfileVersion `9.0`。直接依赖写在 `importers`（根、`apps/cli`、`apps/worker`）。`packages:` 至 `snapshots:`（约第 2077 行）之间有 448 条 `integrity:`，版本含间接依赖。`snapshots:` 只重复解析结果，不另计。无第二套语言锁文件。

## 2. 版本钉、校验和、git／URL

结论：**已确认**（锁外下载没有仓库内校验和）。

- 锁内：抽查的 `resolution` 含 `integrity`（例 `pnpm-lock.yaml:100-101`）。全文无 `tarball:`、`git+`、`github:`、`gitlab:`、`jsr:` 依赖源。`package.json` 里大量 `^` 范围，实际安装版本以锁文件为准。
- 锁外，基准 SHA 上已读到：`Dockerfile:23` `pnpm@10.33.0`；`Dockerfile:82-95` Typst `0.14.2` 的 `curl -fsSL`，无校验和；`Dockerfile:119` `@playwright/cli@0.1.1`。后两个没有提交 integrity。npm 客户端是否在安装时核对 registry integrity，本单未安装，**未核实**。

## 3. 仿冒包名、钩子、非官方源

结论：**未核实**（钩子正文）。

- 包名：427 个锁内包名与一组历史恶意包名无交集，无非 ASCII 包名。短名 `ajv`、`ms`、`qs`、`ws`、`zod`、`zx` 是常见包，不是仿冒结论。这是名称比对，不是 tarball 审计。
- 钩子：`.npmrc:3-4` 为 `ignore-scripts=true` 与 `minimum-release-age=10080`。根 `package.json:22-26` 仍允许 `@swc/core`、`protobufjs` 执行构建脚本。脚本内容在 npm 包内，本单未下载，**未核实**。
- 源：锁文件无非 registry URL。未见私有 registry 配置。

## 4. 镜像

结论：**已确认**（清单不钉 digest）。层未拉取，不判断层内容是否恶意。

- `Dockerfile:6` 与 `:44`：`cgr.dev/chainguard/wolfi-base:latest`，浮动 tag，无 digest。2026-11-26 09:40 香港时间标签接口 401，本轮未重试。
- `docker-compose.yml:7` 与 `apps/cli/infra/compose.yml:7`：`temporalio/temporal:1.7.0`，tag 固定，无 digest。
- `apps/cli/src/docker.ts:25-42`：npx 拉取 `keygraph/shannon:<版本>`，无 digest，不校验 cosign。发布侧签名见 `audit/supply-chain.md`，签名没有接到这条拉取路径。

## 5. 子模块与远程拉取

结论：**已确认**（存在未校验或未钉死的远程获取）。无 `.gitmodules`。工作流与脚本中没有 `curl|bash` / `wget|sh`。

- 构建期：`Dockerfile:89` 下载 Typst；`Dockerfile:23` 与 `:119` 从 npm 全局安装。
- 运行期：`apps/worker/src/ai/models.ts:243` `allowModelNetwork: true`，扫描开始会刷新模型目录。具体主机在 pi SDK 内，**未核实**。
- 插件技能要求执行 `npx -y @keygraph/shannon@latest`（`plugins/shannon/skills/shannon/SKILL.md:43`）。`@latest` 会随标签移动。这是文档化的安装方式，不是隐藏拉取。

## 6. CI

结论：**已确认**（一处工具未钉 SHA）。危险触发方式：**未发现问题**。仓库内密钥明文：**未发现问题**。

- 五个工作流的 `uses:` 均带 40 位提交 SHA。例：`plugin-docs-check.yml:30`、`release.yml:25`。
- `release.yml:49` 与 `:239`：`npx semantic-release@25`，只钉主版本。仅 `workflow_dispatch`（`release.yml:3-4`）。`release-beta.yml`、`rollback.yml`、`rollback-beta.yml` 同样是 `workflow_dispatch`。
- 无 `pull_request_target`、无 `workflow_run`。`plugin-docs-check.yml:3-18` 在 `pull_request` 上跑仓库内 `sync-docs.sh`，权限 `contents: read`（第 20-21 行），该作业未引用密钥。
- `DOCKERHUB_USERNAME`、`DOCKERHUB_TOKEN`、`NPM_TOKEN`、`GITHUB_TOKEN` 只作为 `${{ secrets.* }}` 出现（如 `rollback.yml:71`）。文件中无密钥值。日志是否打印密钥，未跑 CI，**未核实**。

## 7. 公开漏洞库与恶意包库

查询：2026-11-26 11:31 香港时间，对 448 个锁内版本以及 `@playwright/cli@0.1.1`、`pnpm@10.33.0` 调用 OSV `querybatch`。`@playwright/cli@0.1.1` 返回空，补上了 `audit/supply-chain.md` 里该项未查。

### 依赖是否恶意

结论：**未发现问题**（仅限上述 450 个版本的 OSV `MAL-` 记录）。返回 0 条 `MAL-`。这不覆盖未读的 tarball、未拉的镜像层，也不覆盖钩子脚本正文。

### 已知漏洞

结论：**已确认**（版本落在公告区间）。利用路径除已写明的调用点外均为 **未核实**。直接依赖的条文不重复，见 `audit/supply-chain.md`「锁定版本与公开漏洞」。

本轮新出现、且锁定版本被 OSV 标为受影响的包：

| 依赖与锁定版本 | 角色 | 编号 | 影响版本（OSV 对本查询的返回） |
|---|---|---|---|
| `pnpm@10.33.0` | 镜像构建工具，`Dockerfile:23`，不在锁内 | 18 条：GHSA-3qhv-2rgh-x77r、GHSA-4gxm-v5v7-fqc4、GHSA-54hh-g5mx-jqcp、GHSA-5wx6-mg75-v57r、GHSA-72r4-9c5j-mj57、GHSA-c59q-g84q-2gj5、GHSA-cjhr-43r9-cfmw、GHSA-fr4h-3cph-29xv、GHSA-gj8w-mvpf-x27x、GHSA-hg3w-7f8c-63hp、GHSA-hwx4-2j3j-g496、GHSA-p4xf-rf54-rj3x、GHSA-q6j5-fjx5-2mc3、GHSA-qrv3-253h-g69c、GHSA-rxhj-4m44-96r4、GHSA-vq4v-j7r6-jq4m、GHSA-vx52-2968-3vc6、GHSA-w466-c33r-3gjp | 抽查四条的修复版本为 10.34.0–10.34.4，均高于 10.33.0。其中 GHSA-54hh-g5mx-jqcp 写明默认行为会破坏 integrity 检查；GHSA-3qhv-2rgh-x77r 与仓库配置把环境变量送进 registry 请求有关。未运行 pnpm，未验证这些路径在本 Dockerfile 的 `npm install -g` 中是否触发 |
| `hono@4.12.14` | 锁内间接 | 31 条，含 GHSA-2gcr-mfcq-wcc3（抽查：修复于 4.12.21）以及 GHSA-3gg2-335m-rxc6、GHSA-3hrh-pfw6-9m5x、GHSA-46wx-v44x-9hh2、GHSA-4h7h-rv7c-7m2v、GHSA-4m76-xfj5-7975、GHSA-54fx-42gc-7vw4、GHSA-5r4p-p66f-jhc7、GHSA-69xw-7hcm-h432、GHSA-79qm-7rj5-m7r9、GHSA-88fw-hqm2-52qc、GHSA-8j4g-w8fx-2239、GHSA-9vqf-7f2p-gf9v、GHSA-crvj-82cr-hjcx、GHSA-f23p-vx2j-j53r、GHSA-f577-qrjj-4474、GHSA-g6gw-c38x-mqfc、GHSA-gqvv-2mrq-wpjv、GHSA-h7mg-cq63-vhpq、GHSA-hm8q-7f3q-5f36、GHSA-hvrm-45r6-mjfj、GHSA-hxh3-vqpv-xpqv、GHSA-j6c9-x7qj-28xf、GHSA-p77w-8qqv-26rm、GHSA-qp7p-654g-cw7p、GHSA-rv63-4mwf-qqc2、GHSA-w62v-xxxg-mg59、GHSA-wgpf-jwqj-8h8p、GHSA-wwfh-h76j-fc44、GHSA-xgm2-5f3f-mvvc、GHSA-xrhx-7g5j-rcj5 | 锁定 4.12.14。业务源码无直接 import。调用面未核实 |
| `@hono/node-server@1.19.14` | 锁内间接 | GHSA-frvp-7c67-39w9、GHSA-jpvv-r467-5p4w、GHSA-rmxm-3fg6-px4f | 锁定版本被标为受影响。调用面未核实 |
| `@modelcontextprotocol/sdk@1.29.0` | 锁内间接（随 pi） | GHSA-22jm-h49p-29qw、GHSA-46jr-4wx8-v453、GHSA-6prh-2h8m-c8cw、GHSA-6qxp-vccf-f47h、GHSA-f897-62hf-6gxq、GHSA-rvq5-wwqv-78pq | 锁定版本被标为受影响。调用面未核实 |
| `@grpc/grpc-js@1.14.3` | 锁内间接 | GHSA-5375-pq7m-f5r2、GHSA-99f4-grh7-6pcq、GHSA-f596-whhp-79r4、GHSA-m9gg-hp2v-232j | 同上 |
| `fast-uri@3.1.2` | 锁内间接 | 11 条：GHSA-333x-w4r6-6crp、GHSA-4c8g-83qw-93j6、GHSA-7p8r-x3mc-p8w7、GHSA-f65p-4m7j-42xc、GHSA-fph4-wmhf-6fwf、GHSA-hrr3-gc8f-f4qj、GHSA-jqff-g426-hqxp、GHSA-qw65-cvwx-89v3、GHSA-v2hh-gcrm-f6hx、GHSA-w74x-v6f9-j3xg、GHSA-xhq7-xmqj-769h | 同上 |
| `ip-address@10.1.0` | 锁内间接 | GHSA-h3mg-xc3c-68pw、GHSA-j6r3-76f7-8jcv、GHSA-mwp4-54f8-5fhr、GHSA-rpw4-54j3-4h4q、GHSA-rxp7-6hxx-x8q5、GHSA-v2v4-37r5-5v8g | 同上 |
| `qs@6.15.1` | 锁内间接 | GHSA-4mjr-xmp4-gh2g、GHSA-6pq8-jhm2-2vcw、GHSA-q8mj-m7cp-5q26、GHSA-x5fp-wj9c-mxmx | 同上 |
| `body-parser@2.2.2` | 锁内间接 | GHSA-27r3-jxmh-p828、GHSA-v422-hmwv-36x6 | 同上 |
| `browserslist@4.28.1` | 锁内间接 | GHSA-73wf-gq98-2v4g、GHSA-c83g-rgw3-j3cx | 同上 |
| `@protobufjs/utf8@1.1.0` | 锁内间接 | GHSA-q6x5-8v7m-xcrf（与 `protobufjs@7.5.5` 的同号公告重叠） | 同上 |
| `baseline-browser-mapping@2.10.8`、`defu@6.1.4`、`proxy-addr@2.0.7`、`source-map-js@1.2.1`、`uuid@11.1.0` | 锁内间接 | 各 1 条：GHSA-w5vr-8v7q-w6rv、GHSA-737v-mqg7-c878、GHSA-jqcg-44mw-7w3h、GHSA-68fv-2mgg-jv7q、GHSA-w5hq-g745-h8pq | 同上 |

已在 `audit/supply-chain.md` 写过、本轮复核仍成立：`handlebars@4.7.9`、`smol-toml@1.6.1`、`js-yaml@4.1.1`、`protobufjs@7.5.5`、`turbo@2.8.17`。

## 8. 主要依赖的维护状态

结论：**未发现问题**（下表这些仓库与版本）。未逐个查其余传递包，那些保持 **未核实**。

npm `time` 与 `deprecated`、GitHub `archived` 均在 2026-11-26 11:31 香港时间读取。抽查的 14 个 GitHub 仓库 `archived=false`。对应 npm 锁定版本均无 `deprecated`。

| 包 | 锁定版本发布时间（香港时间） | 当时 registry latest | 仓库最近 push（香港时间） |
|---|---|---|---|
| `@earendil-works/pi-coding-agent` | 1.5.0，2026-11-02 19:05 | 1.6.1，2026-11-25 21:41 | `earendil-works/pi`，2026-11-26 10:41 |
| `@temporalio/client` | 1.15.0，2026-02-19 02:46 | 1.27.0，2026-11-25 16:25 | `temporalio/sdk-typescript`，2026-11-26 08:22 |
| `pnpm` | 10.33.0，2026-03-25 00:40 | 12.23.0，2026-11-22 21:21 | `pnpm/pnpm`，2026-11-26 10:07 |
| `hono` | 4.12.14，2026-04-15 14:13 | 4.13.22，2026-11-25 08:06 | `honojs/hono`，2026-11-26 11:14 |
| `zx` | 8.8.5，2025-10-19 21:48（latest 仍是该版） | 同左 | `google/zx`，2026-11-05 19:24 |
| `@playwright/cli` | 0.1.1，2026-02-15 07:28 | 0.1.25，2026-11-19 02:55 | `microsoft/playwright-cli`，2026-11-25 04:31 |

锁定版本落后于 latest 只说明未升级，不单独构成弃用。`zx` 的 npm 版本停在 2025-10-19，仓库在 2026-11 仍有 push，未标弃用。
