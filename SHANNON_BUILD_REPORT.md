# Shannon worker 镜像只构建比对

观察时间：2026-11-16（UTC）。本报告只记录在本云 VM 内的 `docker build`、`docker pull` 和静态检查。没有执行 `docker run`、`docker compose up`，没有启动 Temporal 或其他业务进程，没有运行 `./shannon`、`npx @keygraph/shannon` 或 agent，没有连接或扫描目标，没有调用 LLM API，没有使用仓库里的密钥。

## 1. 结论摘要

自建成功。在安装 Docker Engine 与 Buildx 插件之后，按仓库 `Dockerfile` 和 `apps/cli/src/docker.ts` 里的 `docker build` 参数，构建出 `shannon-worker:local`，退出码 0。

自建 worker 与 Docker Hub 上的 `keygraph/shannon:3.5.1`（与 `:latest` 是同一索引）不一致。两边的索引 digest、amd64 清单 digest、镜像 config digest 都不同。历史命令文本相同，入口、命令、用户、工作目录和环境变量相同，但 rootfs 28 层里只有 8 层 digest 相同。不一致有已核实的原因：构建提交不同，以及 `wolfi-base:latest` 在两次构建之间换成了另一个 digest，连带 89 个 apk 包版本不同。同一提交能否被本机构建复现成 Hub 镜像，未核实。

Docker Hub 上的 `keygraph/shannon:3.5.1` / `:latest` 由 GitHub Actions 构建。依据是仓库工作流 `.github/workflows/release.yml`，以及该镜像自带的 SLSA provenance：builder 指向 run [43101184964](https://github.com/KeygraphHQ/shannon/actions/runs/43101184964)，本次 `docker pull` 得到的索引 digest 与该 run 日志里推送的 digest 相同。没有在本机重新执行 `cosign verify`，签名是否仍然通过，未复验。

## 2. 构建步骤、提交与工具链

### 2.1 实际构建的提交

| 项 | 值 |
| --- | --- |
| 仓库远端 | `github.com/Silver-cybersec/shannon` |
| 分支 | `main`，与 `origin/main` 相同 |
| 构建提交 | `4cef63e5900c9eda0b259a44f89458c7f8b1e10d` |
| 提交时间 | 2026-11-06 22:13:37 +0530 |
| 提交说明 | `fix: validate workspace names and restrict target URLs to HTTP/HTTPS (#515)` |

`git fetch origin main` 之后，本地 `HEAD` 与 `origin/main` 仍是这个提交。

KeygraphHQ/shannon 的发布标签 `v3.5.1` 指向 `94bf442d58539994af1c929dedb8bd958e8198c1`（2026-11-11T20:16:40Z，`chore(deps): upgrade pi SDK to 1.5.0 and pi-permission-system to 42.0.0 (#522)`）。GitHub compare `4cef63e5900c9eda0b259a44f89458c7f8b1e10d...v3.5.1` 的结果是 `ahead_by=2`、`behind_by=0`。中间两个提交是：

- `804b80636d5022f06dfd6242744610e7521c8f21`：`fix: decode git and subprocess output once to preserve multi-byte characters (#518)`
- `94bf442d58539994af1c929dedb8bd958e8198c1`：上面的依赖升级

改动文件 6 个：`apps/cli/src/ui.ts`、`apps/worker/package.json`、`apps/worker/src/ai/pi/task-tool.ts`、`apps/worker/src/services/git-manager.ts`、`apps/worker/src/services/report-checkpoints.ts`、`pnpm-lock.yaml`。

因此这次自建的是当前检出，不是 Hub 镜像 provenance 里记录的 `94bf442d58539994af1c929dedb8bd958e8198c1`。

### 2.2 从脚本抽出的命令

`./shannon build` 会进入 CLI。按限制没有运行它。`apps/cli/src/commands/build.ts` 只调用 `buildImage`，不会启动 Temporal。`apps/cli/src/docker.ts` 的 `buildImage`（约第 249–256 行）在本地模式执行：

```text
docker build -t shannon-worker .
```

本地模式的标签来自常量 `DEV_IMAGE = 'shannon-worker'`（第 25 行），版本参数不进入标签。本次按交付要求把标签改成 `shannon-worker:local`，并加了 `--progress=plain`，只为了留下可读日志。进度显示方式不进入镜像层。

成功的那次命令，工作目录 `/agent/repos/shannon`：

```text
docker build --progress=plain -t shannon-worker:local .
```

### 2.3 工具链

本机起初没有 `docker`。为执行上述构建，用 Ubuntu 软件源安装了：

| 组件 | 版本 |
| --- | --- |
| 操作系统 | Ubuntu 24.04.5 LTS，x86_64 |
| Docker Engine | 29.1.3，包 `29.1.3-0ubuntu3~24.04.2` |
| containerd | 2.2.1 |
| runc | 1.3.4-0ubuntu1~24.04.1 |
| docker-buildx | 0.30.1，包 `0.30.1-0ubuntu1~24.04.1` |
| 默认 builder 的 BuildKit | v0.26.2（`docker buildx ls`） |
| 宿主机 git | 2.43.0 |
| 宿主机 Node / npm / pnpm | v22.23.4 / 10.9.9 / 10.33.0 |

宿主机的 Node 没有参与镜像构建。镜像里的 Node 由 Wolfi 的 `nodejs-22` 提供。没有 systemd，dockerd 是为了 `docker build` / `docker pull` / `docker inspect` 单独拉起的，没有用它启动 Shannon 或 Temporal。

安装 buildx 之前，`docker build` 走 legacy builder，并打印将在未来移除的提示。Hub 镜像的构建日志和 provenance 使用的是 BuildKit。装上发行版的 buildx 插件后，同名 `docker build` 才使用 BuildKit。Hub 镜像内嵌 SBOM 的 creator 写的是 `buildkit-v0.34.2` 和 `syft-v1.51.0`，与本机 BuildKit v0.26.2 不是同一版本。

静态清单使用的 syft 是 v1.57.1（linux amd64）。压缩包 sha256 为 `bf52519eb57f675d47c07d43213cb6dff6449f3d6d1147ff6701ed91f44eef0c`，与上游 `syft_1.57.1_checksums.txt` 一致。本机没有 dive，没有做 dive 检查。

### 2.4 失败记录

第一次包装脚本在调用 `docker build` 之前就退出，因为本机没有 `/usr/bin/time`：

```text
bash: line 1: /usr/bin/time: No such file or directory
BUILD_EXIT 127
```

第二次在尚未安装 buildx 时加了 `--progress`，legacy builder 拒绝该参数：

```text
DEPRECATED: The legacy builder is deprecated and will be removed in a future release.
            Install the buildx component to build images with BuildKit:
            https://docs.docker.com/go/buildx/

unknown flag: --progress
BUILD_EXIT 125
```

这两次都没有产生 `shannon-worker:local`。Dockerfile 步骤本身没有失败。

### 2.5 成功构建的耗时

成功构建的日志时间戳：

- `BUILD_START 2026-11-16T16:40:07Z`
- `BUILD_END 2026-11-16T16:42:24Z`
- `BUILD_EXIT 0`

按这两条 `date` 输出，墙钟间隔是 137 秒。镜像内本地 provenance 的精度更高：`buildStartedOn` 为 `2026-11-16T16:40:07.624532241Z`，`buildFinishedOn` 为 `2026-11-16T16:42:12.407805931Z`，间隔 124.783 秒。日志里 `exporting to image` 单独写了 `46.2s`。

构建日志摘录：

```text
#4 [builder  1/11] FROM cgr.dev/chainguard/wolfi-base:latest@sha256:2c12da5496e21e99003b3db3b9246f025e53d533c4df334205391260f1e8f85b
#13 2.977 Done in 2.8s using pnpm v10.33.0
#16 4.892 Done in 3.6s using pnpm v10.33.0
#17 1.163 typst 0.14.2 (b33de9de)
#28 0.299 Downloading Chrome for Testing 146.0.7680.0 (playwright chromium v1212) from https://cdn.playwright.dev/builds/cft/146.0.7680.0/linux64/chrome-linux64.zip
#33 exporting manifest sha256:fe43387f8fdad0cababccbd7ec1223f511c442cbd1b55b87aed41cd7dde02074
#33 exporting config sha256:0aa84a9acf51cd19ac8eeb8bf3972ee9e6e5043546816207e24f7cf28dd065a2
#33 exporting manifest list sha256:331e0739f298bff4e7085d7848317b9db9eb8a77a78184d798ef3410a90ae41b
#33 naming to docker.io/library/shannon-worker:local done
```

pnpm 在安装时打印了升级提示，实际使用的仍是锁定的 10.33.0：

```text
Update available! 10.33.0 → 12.21.0.
Changelog: https://pnpm.io/v/12.21.0
```

## 3. 供应链清单

### 3.1 基础镜像

| 镜像 | 引用方式 | 本次观察到的 digest | 是否锁 digest |
| --- | --- | --- | --- |
| `cgr.dev/chainguard/wolfi-base:latest` | `Dockerfile` 第 6 行和第 44 行，builder 与 runtime 都用 `:latest` | 索引 `sha256:2c12da5496e21e99003b3db3b9246f025e53d533c4df334205391260f1e8f85b`。索引注解 `org.opencontainers.image.created=2026-11-15T22:10:17Z`。amd64 清单 `sha256:fa63d07ad857b4fb4dacb80f3f269116d24e3f27f9ce41feed5c0f617afcaf7e` | 否。标签是 `latest` |
| Hub 构建当时的同一标签 | Actions 日志与 Hub provenance 的 resolvedDependencies | `sha256:94fa13e26d449f7d78dbcd02d12ea37a0da80d24fcc3e1f17b95d515dec607a7`。最终镜像标签里的 `org.opencontainers.image.created=2026-11-10T15:49:14Z` | 构建当时解析到了 digest，Dockerfile 源码仍写 `:latest` |
| `temporalio/temporal:1.7.0` | `docker-compose.yml` 第 7 行，`apps/cli/infra/compose.yml` 第 7 行。不在 worker 镜像内 | 索引 `sha256:9c5b386d86bca59ba08f32ddc4c51287351c8c616b6a8359f03e96a585e137f4`。amd64 清单 `sha256:6dc6fda8437b7aca517a5daeff024438f469f0c40a16c28118393d8477965f5f`。arm64 清单 `sha256:3ccd1b745e19342edd4cfa5b0b64dc96596fd1fc70abb263a543cd8c23c625eb` | 否。只锁了标签 `1.7.0` |
| `keygraph/shannon:3.5.1` 与 `:latest` | npx 模式按 CLI 版本拉标签，见第 4 节 | 两者索引都是 `sha256:c31b05cd9273816e7ccb3c5a76658b17debd9c433a615a87c19607dee867be02` | CLI 按标签拉取，不按 digest |

`temporalio/temporal:1.7.0` 的 amd64 config：`Created=2026-04-29T23:01:45.060726373Z`，`Entrypoint=["temporal"]`，`User=temporal`，`WorkingDir=/`。`docker history` 显示基础层是 `ADD alpine-minirootfs-3.23.4-x86_64.tar.gz /`，随后 `apk add --no-cache ca-certificates tzdata`，再复制 `dist/amd64/temporal`。`docker images` 显示 SIZE 为 `706MB`，`docker image inspect` 的 Size 为 `117989264`。没有对这个镜像跑 syft。Alpine 压缩包本身的校验和，未核实。

### 3.2 apk

下载索引：`https://apk.cgr.dev/chainguard/x86_64/APKINDEX.tar.gz`。构建日志写明该索引当时有 `119712 distinct packages`。

`Dockerfile` 的 `apk add` 只写包名，不写版本，也没有 apk 锁文件。包名 `npm` 在这次索引里解析成 `npm-12`。包名 `python3` 解析成 `python-3.13` 及其依赖。最终镜像里没有 `build-base`、`wget`、`gcc` 或名为 `pnpm` 的包；它们留在 builder 阶段。

runtime 阶段日志是 `(192/192)`。同一天 Actions 的 linux/amd64 日志也是 `(192/192)`，linux/arm64 日志是 `(191/191)`。本机没有构建 arm64。

Dockerfile 直接点名、以及 python 带进来的 `py3-pip-wheel`，用同一份 syft 1.57.1 对两个最终镜像扫描的结果：

| 包 | Hub `keygraph/shannon:3.5.1` | 本地 `shannon-worker:local` | 对比 |
| --- | --- | --- | --- |
| bash | 5.3-r14 | 5.3-r14 | 同 |
| ca-certificates | 20261020-r0 | 20261020-r0 | 同 |
| chromium | 149.0.7827.53-r0 | 149.0.7827.53-r0 | 同 |
| curl | 8.23.0-r3 | 8.23.0-r3 | 同 |
| fontconfig | 2.18.3-r5 | 2.18.3-r5 | 同 |
| freetype | 2.14.3-r7 | 2.15.0-r0 | 不同 |
| git | 2.56.1-r0 | 2.56.1-r1 | 不同 |
| harfbuzz | 15.1.0-r0 | 15.1.0-r0 | 同 |
| libx11 | 1.8.14-r4 | 1.8.14-r4 | 同 |
| libxcomposite | 0.4.7-r5 | 0.4.7-r6 | 不同 |
| libxdamage | 1.1.7-r5 | 1.1.7-r5 | 同 |
| libxext | 1.3.7-r5 | 1.3.7-r5 | 同 |
| libxfixes | 6.0.2-r4 | 6.0.2-r4 | 同 |
| libxrandr | 1.5.5-r7 | 1.5.5-r7 | 同 |
| mesa-gbm | 26.3.0-r0 | 26.3.0-r0 | 同 |
| nodejs-22 | 22.23.2-r1 | 22.23.2-r1 | 同 |
| npm-12 | 12.2.2-r0 | 12.2.2-r1 | 不同 |
| nss | 3.133-r0 | 3.133-r0 | 同 |
| python-3.13 | 3.13.18_git20261030-r0 | 3.13.18_git20261115-r1 | 不同 |
| python-3.13-base | 3.13.18_git20261030-r0 | 3.13.18_git20261115-r1 | 不同 |
| shadow | 4.20.3-r3 | 4.20.3-r4 | 不同 |
| xz | 5.8.4-r1 | 5.8.4-r2 | 不同 |
| py3-pip-wheel | 26.2.2-r2 | 26.2.2-r3 | 不同 |

syft 对两个镜像各看到 211 个不重复 apk 包名。其中 210 个名字两边都有，89 个版本不同；另外 Hub 有 `libopenjph0.32`、本地有 `libopenjph0.33`。89 个版本差异的完整名单在第 4.6 节。

### 3.3 npm 与 pnpm

| 来源 | 版本约束 | 校验 |
| --- | --- | --- |
| `Dockerfile` 第 23 行 `npm install -g --ignore-scripts pnpm@10.33.0` | 精确版本 10.33.0，只存在于 builder | Dockerfile 没有 integrity 或 tarball sha256。构建日志确认使用 pnpm v10.33.0 |
| `pnpm install --frozen-lockfile` 与随后的 `--prod` | `pnpm-lock.yaml` 的 `lockfileVersion: '9.0'` | 锁文件锁定工作区依赖。`.npmrc` 没有改 registry，默认 `https://registry.npmjs.org`。`.npmrc` 含 `minimum-release-age=10080` 和 `ignore-scripts=true` |
| `Dockerfile` 第 119 行 `npm install -g --ignore-scripts @playwright/cli@0.1.1` | 精确版本 0.1.1 | Dockerfile 没有 integrity。两个镜像里 syft 都看到 `@playwright/cli` 0.1.1，以及它带入的 `playwright` / `playwright-core` `1.59.0-alpha-1771104257000`。后者不在 Dockerfile 里写死 |
| 当前检出的直接依赖 | `@earendil-works/pi-*` 范围 `^0.84.4`，锁文件解析为 0.84.4；`@gotgenes/pi-permission-system` 范围 `^10.9.0`，锁文件解析为 10.9.0；`@temporalio/*` 精确 1.15.0 | Hub 镜像对应的是后一个提交，syft 看到 pi 组件 1.5.0、`@gotgenes/pi-permission-system` 42.0.0，`@temporalio/worker` 仍是 1.15.0 |

`package.json` 里的 `^` 范围本身不是安装结果。有锁文件且使用 `--frozen-lockfile` 时，安装结果由锁文件决定。全局的 pnpm 和 `@playwright/cli` 不走这个锁文件。

### 3.4 pip

`Dockerfile` 没有 `pip install`。两个最终镜像里都有 Wolfi 包 `py3-pip-wheel`（Hub `26.2.2-r2`，本地 `26.2.2-r3`），它是 `python3` 的依赖，不是构建脚本单独安装的。Hub 构建时内嵌的 SPDX 还记了一条 `pkg:pypi/pip@26.2.2`，来源文件是 `/var/lib/db/sbom/py3-pip-wheel-26.2.2-r2.spdx.json`。

### 3.5 Typst

`Dockerfile` 第 82–95 行把 `TYPST_VERSION` 默认设为 `0.14.2`，按架构从 GitHub Releases 下载：

```text
https://github.com/typst/typst/releases/download/v${TYPST_VERSION}/typst-${TYPST_ARCH}.tar.xz
```

amd64 对应 `typst-x86_64-unknown-linux-musl.tar.xz`。Dockerfile 没有校验和。

本地构建日志：`typst 0.14.2 (b33de9de)`。Actions run 43101184964 的 linux/amd64 日志同一行也是 `typst 0.14.2 (b33de9de)`。两个镜像里 `/usr/local/bin/typst` 的字节 sha256 都是 `3ac6b84150c50a694d44134dc201624fbdc44f705b9992124a13474ddf8c6413`，大小都是 50889504 字节。版本字符串和文件哈希这次一致，不表示下载地址已被锁定。

### 3.6 Playwright 与 Chrome for Testing

`playwright-cli install --skills` 在设置 `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` 之前运行。本地构建下载：

```text
https://cdn.playwright.dev/builds/cft/146.0.7680.0/linux64/chrome-linux64.zip
```

日志写明 Chrome for Testing `146.0.7680.0`（playwright chromium v1212），落到 `/root/.cache/ms-playwright/chromium-1212`。Dockerfile 没有写这个版本，也没有 zip 校验和。版本由 `@playwright/cli@0.1.1` 决定。

Actions 的 linux/amd64 日志是同一个 URL 和同一个版本。linux/arm64 日志是另一个 URL：`https://cdn.playwright.dev/dbazure/download/playwright/builds/chromium/1212/chromium-linux-arm64.zip`，版本号仍是 `146.0.7680.0`。

amd64 两个镜像里这个 Chrome 二进制的 sha256 都是 `e3f5d162f56b0051229c9cd5ae2c486f5d3519bd3f9112e831e586d00089a302`，大小都是 272698584 字节。Wolfi `chromium` 包的 `/usr/lib/chromium/chrome` 也相同：sha256 `063664374133f44a0c406ddd0f7c10cef8a995e7c3ed4faf8027caeb332954af`，大小 300882728 字节。这是这次字节碰巧一致，不是校验和锁定。

### 3.7 未锁版本、`@latest` 和无校验和

- `cgr.dev/chainguard/wolfi-base:latest`：浮动标签，无 digest。
- 全部 `apk add` 包名：无版本，无锁文件。`nodejs-22`、`npm`、`python3` 会随 Wolfi 索引换成新的修订版。
- `pnpm@10.33.0` 和 `@playwright/cli@0.1.1`：版本精确，Dockerfile 无 integrity。
- Typst 0.14.2 的 tarball：版本写在 URL 里，无 sha256。
- Chrome for Testing 的 zip：版本和 URL 都不在 Dockerfile 里，无 sha256。
- `temporalio/temporal:1.7.0`：无 digest。
- npx 拉取的 `keygraph/shannon:<cli 版本>`：标签，不是 digest。裸 `docker pull keygraph/shannon` 等于 `:latest`。
- `.github/workflows/release.yml` 第 49 行和第 239 行的 `npx semantic-release@25`：主版本浮动。它不进入 worker 镜像。
- README 里的 `npx @keygraph/shannon@latest` 是 npm dist-tag。2026-11-16 查询 `npm view @keygraph/shannon dist-tags`，`latest` 为 `3.5.1`，`beta` 为 `2.0.0-beta.4`。

工作区依赖有 `pnpm-lock.yaml`，这一项是锁住的。

## 4. 镜像比对

比对对象是 linux/amd64。Hub 镜像是多架构索引，本地镜像是本机单架构索引。下面的“清单”分开写，避免把索引 digest 和单平台 digest 当成同一个数。

### 4.1 digest

| 对象 | 本地 `shannon-worker:local` | Hub `keygraph/shannon:3.5.1`（`:latest` 相同） |
| --- | --- | --- |
| `docker images` 显示的索引 / Id | `sha256:331e0739f298bff4e7085d7848317b9db9eb8a77a78184d798ef3410a90ae41b` | `sha256:c31b05cd9273816e7ccb3c5a76658b17debd9c433a615a87c19607dee867be02` |
| OCI 索引 | 同上。含 amd64 清单和一份 attestation | 同上。含 amd64、arm64，以及各自的 attestation |
| amd64 OCI 清单 | `sha256:fe43387f8fdad0cababccbd7ec1223f511c442cbd1b55b87aed41cd7dde02074` | `sha256:b2c86fe3ef69b38729d909a631aa6320c4671d8a583d2ae5dc2912833e5fec63` |
| amd64 config | `sha256:0aa84a9acf51cd19ac8eeb8bf3972ee9e6e5043546816207e24f7cf28dd065a2` | `sha256:d3bccfadd7bd273255395f78113b2aee4459eaa7b14df40e320f37eb29d235c9` |
| arm64 OCI 清单 | 无 | `sha256:64704d69bf6651fb0895573949248ab1150d2918f00178fb512683fcdb0ccc83` |
| attestation 清单 | `sha256:5ded109a3bd27c809c075ec0672d2854de61d1000846e6e10c5b6915e822b827`（SLSA provenance v0.2，一层，1189 字节） | amd64 对应 `sha256:5f17040bf3e7a94584efbb5975639a3c28539505b16fe3a783e365cc596fb0eb`，内含 SPDX 与 SLSA provenance v1 |

syft 1.57.1 另外计算了一份 Docker schema2 清单 digest：本地 `sha256:fbcc81d301dce267232cb8810e80dbdf38564c9e3343787fe5b83c75a1cad4d8`，Hub `sha256:5b61cfe3a1697333802054d37b9e3840f4e4efe2c46276002c0f2198144add41`。这是 syft 的视图，不是 registry 上的 OCI 清单。config digest 与上表一致。

`docker images` 的 SIZE 列：本地 `3.55GB`，Hub `3.62GB`。`docker image inspect` 的 Size 字段：本地 `874562399`，Hub `882190909`。syft 的 `imageSize`：本地 `2458388944`，Hub `2490906708`。三个数口径不同，这里不把它们换算成同一个“真实大小”。

### 4.2 层

两边 rootfs 都是 28 层，`docker history` 都是 42 行。42 行的 `CreatedBy` 文本逐行相同，包含同样的 `RUN`、`COPY`、`ENV`、`ENTRYPOINT`、`CMD`，以及 11 行 `apko` 基础历史。`CreatedBy` 相同不表示层 digest 相同。

28 个 diff id 中，下标 1、2、3、4、5、6、8、27 共 8 层相同。第 27 层是空层 `sha256:5f70bf18a086007016e948b04aed3b82103a36bea41755b6cddfaf10ace3c6ef`。其余 20 层不同。相同的非空层来自两次 `wolfi-base` 里没有变化的那部分。

`docker history` 显示的 Size 里，能看出来的差别：

| 步骤 | Hub | 本地 |
| --- | --- | --- |
| `apk add` runtime 依赖 | 1.25GB | 1.25GB |
| Typst | 50.9MB | 50.9MB |
| 复制 lockfile 等清单 | 160kB | 164kB |
| 复制 `node_modules` | 460MB | 436MB |
| `npm install -g @playwright/cli@0.1.1` | 57.5MB | 57.6MB |
| `playwright-cli install --skills` | 390MB | 390MB |
| `chown` / `chmod` 那一层 | 486MB | 462MB |

这些是 `docker history` 打印的大小，不是重新计算的字节数。

### 4.3 入口、用户、环境变量

两边 config 相同的部分：

- `Entrypoint`: `["/app/entrypoint.sh"]`
- `Cmd`: `["node", "apps/worker/dist/temporal/worker.js"]`
- `User`: `root`
- `WorkingDir`: `/app`
- `Author`: `github.com/chainguard-dev/apko`（来自 Wolfi 基础镜像，不是 Shannon 的作者字段）
- 环境变量：`PATH`、`SSL_CERT_FILE`、`NODE_ENV=production`、`SHANNON_DOCKER=true`、`PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1`、`PLAYWRIGHT_MCP_EXECUTABLE_PATH=/usr/bin/chromium-browser`、`npm_config_cache=/tmp/.npm`、`HOME=/tmp`、`XDG_CACHE_HOME=/tmp/.cache`、`XDG_CONFIG_HOME=/tmp/.config`
- 标签 `shannon.worker-protocol=workflow-id-v1`
- 其余 Chainguard 标签的键相同

`PATH` 两边都是 `/usr/local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/sbin:/bin`，`/usr/local/bin` 出现两次，因为 Dockerfile 又前置了一次。

不同的部分：

- config `Created`：Hub `2026-11-11T21:16:01.051278778Z`，本地 `2026-11-16T16:41:37.797291343Z`
- 标签 `org.opencontainers.image.created`：Hub `2026-11-10T15:49:14Z`，本地 `2026-11-15T22:10:17Z`。这是各自基础镜像的创建时间，不是 Shannon 业务代码写的

`User` 是 `root`。`Dockerfile` 创建了 uid/gid 1001 的 `pentest`，但没有在最后一条 `USER` 切过去。`entrypoint.sh` 在进程启动后执行 `su`。本次没有运行容器，所以没有观察降权后的实际 uid。`/etc/passwd` 与 `/etc/group` 的 sha256 两边相同，分别是 `2e82b44351bcd6630e16039b0703b142eb8ba55f9fe7ed14a155f9471afeb6c9`（857 字节）和 `f03595ea34295acb0f28091f46e10f9ed89e263d7e912f2ff7a04a3ac881f75d`（633 字节）。

### 4.4 抽查的文件

| 路径 | Hub sha256 | 本地 sha256 | 结果 |
| --- | --- | --- | --- |
| `/usr/bin/node` | `c3b6380cfaef4f8b720350ecfa41062bc7a02c9cbe424b76187f1af0b91784fe`（81442576 字节） | 相同 | 相同 |
| `/usr/lib/chromium/chrome` | `063664374133f44a0c406ddd0f7c10cef8a995e7c3ed4faf8027caeb332954af`（300882728 字节） | 相同 | 相同 |
| `/usr/bin/chromium` | `e92a267a998926c9861df83339dd06e720ac1815a9707ae0563ae48fa1ff6bbb`（619 字节） | 相同 | 相同 |
| Chrome for Testing `chrome` | `e3f5d162f56b0051229c9cd5ae2c486f5d3519bd3f9112e831e586d00089a302`（272698584 字节） | 相同 | 相同 |
| `/usr/local/bin/typst` | `3ac6b84150c50a694d44134dc201624fbdc44f705b9992124a13474ddf8c6413`（50889504 字节） | 相同 | 相同 |
| `/app/entrypoint.sh` | `c30ae491b21fc8c6634ddac0f843034772bb41342983e4ae2764e69ac5fad583`（515 字节） | 相同 | 相同 |
| `/app/package.json` | `c30e91abe649e8d4eab8170760e6201fcb08df23d63cfe9de8687c21f69a906a`（673 字节） | 相同 | 相同 |
| `/app/apps/cli/package.json` | `384990576c81808b58493a15e66583339b09e730ae1c278b6bb8a238eb5df3c3`（1193 字节） | 相同 | 相同 |
| `/app/.npmrc` | `e63760126b4615d29cca2650b41c21c5f84154be10a9b56728f1c79e4c3d7f65`（101 字节） | 相同 | 相同 |
| `/app/pnpm-workspace.yaml` | `72c2d99ba2824a7179823a0a820ca2750e2b64af468327a16d6f3757fa37b3b6`（23 字节） | 相同 | 相同 |
| `/usr/lib/node_modules/npm/package.json` | `44c37a6a06ae01d4ad987bc4710031ae3a42d47173100316e4913ab2cd113cd3`（6860 字节） | 相同 | 相同 |
| `/app/apps/worker/package.json` | `64f251b19545788e42933c2f51ee3f0762e4cc2c0aba3dea8651b9d58544b37b`（2718 字节） | `a11f0c8082f95bfab0624bf3838f840e249dcc677a33f00afafbfdfc1c45b4b6`（2721 字节） | 不同 |
| `/app/pnpm-lock.yaml` | `7c199d331d403c57638b8bc862fa2e730e50127ffd04ff415d99983a7b8c3adb`（136874 字节） | `c7012f22556a85bb90be600f9680bd25becaf6a747f12d1db086c128e6f66792`（140705 字节） | 不同 |
| `/usr/lib/apk/db/installed` | `945e7955daf4782b86e5a6b9e5156c62220cfbc6cb2f2531396d41bf909c93a9`（672619 字节） | `efa587af771e52d33913e1cee38da7528b2563fb7d7c95fb4055635ca29bc5a2`（674870 字节） | 不同 |

### 4.5 npm 包差异

syft 1.57.1 的 npm artifact 条数：Hub 552，本地 562。按包名比较：51 个名字版本不同，8 个只出现在 Hub，20 个只出现在本地。

和这次提交差直接对应的：

| 包 | Hub | 本地 |
| --- | --- | --- |
| `@earendil-works/pi-coding-agent` | 1.5.0 | 0.84.4 |
| `@earendil-works/pi-ai` | 1.5.0 | 0.84.4 |
| `@earendil-works/pi-agent-core` | 1.5.0 | 0.84.4 |
| `@earendil-works/pi-tui` | 1.5.0 | 0.84.4 |
| `@earendil-works/pi-telemetry` | 1.5.0 | 0.84.4 |
| `@gotgenes/pi-permission-system` | 42.0.0 | 10.9.0 |
| `@temporalio/worker` | 1.15.0 | 1.15.0 |
| `@playwright/cli` | 0.1.1 | 0.1.1 |
| `playwright` / `playwright-core` | 1.59.0-alpha-1771104257000 | 相同 |
| `npm`（Wolfi 自带的 npm 12） | 12.2.2 | 12.2.2 |

只在 Hub 出现：`@earendil-works/pi-codemode`、`@earendil-works/pi-mcp`、`@earendil-works/pi-schema`、`@stablelib/base64`、`fast-sha256`、`marked-cjk-friendly`、`quickjs-wasi`、`standardwebhooks`。

只在本地出现：`@aws-crypto/crc32`、`@aws-crypto/sha256-browser`、`@aws-crypto/sha256-js`、`@aws-crypto/supports-web-crypto`、`@aws-crypto/util`、`@aws-sdk/util-locate-window`、`@earendil-works/pi-client`、`@earendil-works/pi-protocol`、`@mariozechner/clipboard`、`@mariozechner/clipboard-linux-x64-gnu`、`@nodable/entities`、`@smithy/is-array-buffer`、`@smithy/util-buffer-from`、`@smithy/util-utf8`、`fast-xml-builder`、`fast-xml-parser`、`path-expression-matcher`、`pi-extension-sandbox`、`strnum`、`xml-naming`。

其余版本不同的名字主要是 pi 1.5.0 带上的传递依赖，例如 `@anthropic-ai/sdk` Hub `0.129.0`、本地 `0.91.1`，`openai` Hub `7.19.0`、本地 `6.40.0`，`zod` Hub `4.6.7`、本地 `4.3.6`，以及一组 `@aws-sdk/*`、`@smithy/*`。rust-crate artifact 两边都是 84 条。没有逐个比对 crate 版本，未核实它们是否逐条相同。

### 4.6 apk 版本差异全表

下表 89 行，列顺序是 Hub、本地。另有包名替换：Hub `libopenjph0.32`，本地 `libopenjph0.33`。

| 包 | Hub | 本地 |
| --- | --- | --- |
| alsa-lib | 1.2.16.1-r5 | 1.2.16.1-r6 |
| aom-libs | 3.15.3-r0 | 3.15.3-r1 |
| at-spi2-core | 2.62.1-r0 | 2.62.1-r1 |
| avahi-libs | 0.9_rc5-r3 | 0.9_rc5-r4 |
| bubblewrap | 0.13.1-r0 | 0.13.1-r1 |
| cairo | 1.18.6-r1 | 1.18.6-r2 |
| cairo-gobject | 1.18.6-r1 | 1.18.6-r2 |
| dbus | 1.16.2-r11 | 1.16.4-r0 |
| dbus-libs | 1.16.2-r11 | 1.16.4-r0 |
| e2fsprogs-libs | 1.47.4-r5 | 1.47.4-r6 |
| freetype | 2.14.3-r7 | 2.15.0-r0 |
| fribidi | 1.0.18-r2 | 1.0.18-r3 |
| gdbm | 1.26-r9 | 1.26-r10 |
| gdk-pixbuf | 2.44.8-r6 | 2.44.8-r7 |
| git | 2.56.1-r0 | 2.56.1-r1 |
| glibc-2.44 | 2.44-r16 | 2.44-r20 |
| glibc-2.44-locale-posix | 2.44-r16 | 2.44-r20 |
| graphite2 | 1.3.15-r6 | 1.3.15-r7 |
| gtk-3 | 3.24.52-r5 | 3.24.52-r6 |
| gtk-3-update-icon-cache | 3.24.52-r5 | 3.24.52-r6 |
| heimdal-libs | 7.8.0-r55 | 7.8.0-r56 |
| keyutils-libs | 1.6.3-r41 | 1.6.3-r42 |
| kmod | 34.3-r0 | 34.3-r1 |
| kmod-libs | 34.3-r0 | 34.3-r1 |
| ld-linux-2.44 | 2.44-r16 | 2.44-r20 |
| libacl1 | 2.4.0-r5 | 2.4.0-r6 |
| libasyncns | 0.8-r9 | 0.8-r10 |
| libatk-1.0 | 2.62.1-r0 | 2.62.1-r1 |
| libatk-bridge-2.0 | 2.62.1-r0 | 2.62.1-r1 |
| libaudit | 4.2.1-r4 | 4.2.1-r5 |
| libblkid | 2.42.4-r2 | 2.42.4-r3 |
| libcap | 2.78-r4 | 2.78-r5 |
| libcap-ng | 0.9.6-r1 | 0.9.6-r2 |
| libcom_err | 1.47.4-r5 | 1.47.4-r6 |
| libcrypt1-2.44 | 2.44-r16 | 2.44-r20 |
| libde265 | 1.1.3-r0 | 1.1.3-r1 |
| libelf | 0.197-r0 | 0.197-r1 |
| libfdisk | 2.42.4-r2 | 2.42.4-r3 |
| libflac | 1.5.0-r2 | 1.5.0-r3 |
| libgcc | 16.2.0-r3 | 16.2.0-r4 |
| libglvnd | 1.7.0-r12 | 1.7.0-r13 |
| libgomp | 16.2.0-r3 | 16.2.0-r4 |
| libheif | 1.23.7-r1 | 1.23.7-r2 |
| libidn2 | 2.3.8-r12 | 2.3.8-r13 |
| libltdl | 2.5.4-r5 | 2.5.4-r6 |
| libmount | 2.42.4-r2 | 2.42.4-r3 |
| libnspr | 4.40-r2 | 4.40-r3 |
| libpulse | 17.0-r13 | 17.0-r14 |
| librsvg | 2.63.4-r2 | 2.63.4-r4 |
| libseccomp | 2.6.1-r4 | 2.6.1-r5 |
| libselinux | 3.11-r2 | 3.11-r3 |
| libsemanage | 3.11-r3 | 3.11-r4 |
| libsepol | 3.11-r3 | 3.11-r4 |
| libsndfile | 1.2.2-r6 | 1.2.2-r7 |
| libssh | 0.12.2-r3 | 0.12.2-r4 |
| libstdc++ | 16.2.0-r3 | 16.2.0-r4 |
| libsystemd | 262.2-r1 | 262.2-r2 |
| libsystemd-compression-libs | 262.2-r1 | 262.2-r2 |
| libsystemd-shared | 262.2-r1 | 262.2-r2 |
| libudev | 262.2-r1 | 262.2-r2 |
| libuuid | 2.42.4-r2 | 2.42.4-r3 |
| libx265-216 | 4.2-r3 | 4.2-r4 |
| libxcomposite | 0.4.7-r5 | 0.4.7-r6 |
| libxslt | 1.1.45-r7 | 1.1.45-r8 |
| libzstd1 | 1.5.7-r13 | 1.5.7-r14 |
| lmdb | 0.9.35-r3 | 0.9.35-r4 |
| minizip | 1.3.2.1_rc20260921-r2 | 1.4-r0 |
| npm-12 | 12.2.2-r0 | 12.2.2-r1 |
| openjpeg | 2.5.4-r3 | 2.5.4-r4 |
| pango | 1.58.2-r1 | 1.58.2-r2 |
| py3-pip-wheel | 26.2.2-r2 | 26.2.2-r3 |
| python-3.13 | 3.13.18_git20261030-r0 | 3.13.18_git20261115-r1 |
| python-3.13-base | 3.13.18_git20261030-r0 | 3.13.18_git20261115-r1 |
| qt6-qtbase | 6.12.0-r1 | 6.12.0-r2 |
| qt6-qtbase-x11 | 6.12.0-r1 | 6.12.0-r2 |
| quota-tools | 4.11-r3 | 4.11-r4 |
| rav1e | 0.8.1-r13 | 0.8.1-r14 |
| readline | 8.3-r3 | 8.3-r4 |
| shadow | 4.20.3-r3 | 4.20.3-r4 |
| shared-mime-info | 2.5.1-r5 | 2.5.1-r6 |
| soxr | 0.1.3-r10 | 0.1.3-r11 |
| systemd | 262.2-r1 | 262.2-r2 |
| systemd-boot | 262.2-r1 | 262.2-r2 |
| systemd-systemctl | 262.2-r1 | 262.2-r2 |
| tdb | 1.4.15-r6 | 1.4.15-r7 |
| xdg-utils | 1.2.1-r8 | 1.2.1-r9 |
| xz | 5.8.4-r1 | 5.8.4-r2 |
| zlib | 1.3.2.1_rc20260921-r2 | 1.4-r0 |
| zstd | 1.5.7-r13 | 1.5.7-r14 |

### 4.7 为什么不一致

已核实：

1. 源码提交不同。Hub provenance 的 `vcs:revision` 是 `94bf442d58539994af1c929dedb8bd958e8198c1`，本地 provenance 是 `4cef63e5900c9eda0b259a44f89458c7f8b1e10d`。`/app/pnpm-lock.yaml` 和 `/app/apps/worker/package.json` 的哈希不同，与 pi SDK 从 0.84.4 升到 1.5.0 的那个提交相符。
2. `wolfi-base:latest` 的 digest 不同，见第 3.1 节。apk 数据库哈希不同，89 个包版本不同。
3. 索引的附带清单不同。Hub 是 `provenance: mode=max` 加 `sbom: true` 产生的 SLSA v1 和 SPDX。本地 BuildKit 默认只附了一份很小的 SLSA v0.2，`builder.id` 为空，`reproducible` 为 false。这会让索引 digest 不同。config digest 也不同，所以差异不只有外层 attestation。

未核实：

- 没有在提交 `94bf442d58539994af1c929dedb8bd958e8198c1` 上重放构建，因此不能把“同一份 Dockerfile 在同一天、同一 BuildKit 下能否得到 Hub 的层 digest”说成已测结果。
- Hub SBOM creator 写 BuildKit v0.34.2，本机是 v0.26.2。构建器版本对层元数据的影响有多大，未单独测量。
- 文件抽查不是全盘哈希。相同的 Node、Chromium、Typst、Chrome for Testing 文件，出现在 digest 不同的层里，是因为那些层还包含别的文件。

### 4.8 Docker Hub 镜像与 Actions

npx 使用的标签不是字面量 `latest`。`apps/cli/src/version.ts` 的 `getVersion()` 在非本地模式返回已安装包的 `package.json` version。`apps/cli/src/index.ts` 约第 367 行把这个值传给 start。`apps/cli/src/docker.ts` 第 40–41 行把它拼成 `keygraph/shannon:<version>`。2026-11-16，npm dist-tag `latest` 对应包版本 `3.5.1`，所以当前 npx latest 会拉 `keygraph/shannon:3.5.1`。

同日实测 `docker pull keygraph/shannon:3.5.1` 与 `docker pull keygraph/shannon:latest` 的索引 digest 都是 `sha256:c31b05cd9273816e7ccb3c5a76658b17debd9c433a615a87c19607dee867be02`。裸 `docker pull keygraph/shannon` 等于 `:latest`。

工作流文件：

- `.github/workflows/release.yml` 第 3–4 行：`workflow_dispatch`，不是每次 push 都构建。
- 第 59–73 行：`build-docker` 矩阵 `linux/amd64` 与 `linux/arm64`。
- 第 88–96 行：`docker/build-push-action` 以 `name=keygraph/shannon`、`push-by-digest=true`、`push=true`、`provenance: mode=max`、`sbom: true` 推送。
- 第 139–145 行：把两个架构的 digest 标成 `keygraph/shannon:<version>` 和 `keygraph/shannon:latest`。
- 第 157–166 行：`cosign sign`，并用 GitHub Actions OIDC 身份做 `cosign verify`。身份字符串指向 `.github/workflows/release.yml`。

`.github/workflows/release-beta.yml` 也会构建并推送 `keygraph/shannon`，但标签是 beta 版本，不打 `latest`。本次 3.5.1 镜像的 provenance 写的是工作流名 `Release` 和 `release.yml`，不是 beta 工作流。`.github/workflows/rollback.yml` 只把已有版本标签重新指到 `latest`，不构建。

已核实的运行记录：

- 成功 run `43101184964`，2026-11-11T21:13:21Z，`workflow_dispatch`，head `94bf442d58539994af1c929dedb8bd958e8198c1`。六个 job 都是 success：Preflight、Build Docker (linux/amd64)、Build Docker (linux/arm64)、Push Docker manifests、Publish npm、Create GitHub release。
- 该 run 日志里，linux/amd64 导出的清单是 `sha256:b2c86fe3ef69b38729d909a631aa6320c4671d8a583d2ae5dc2912833e5fec63`，随后把索引 `sha256:c31b05cd9273816e7ccb3c5a76658b17debd9c433a615a87c19607dee867be02` 推到 `:3.5.1` 和 `:latest`。这与本次 pull 的索引、以及 `docker buildx imagetools inspect` 的 amd64 清单一致。
- 从 registry 取下的 amd64 SLSA v1 provenance：`builder.id` 为 `https://github.com/KeygraphHQ/shannon/actions/runs/43101184964/attempts/1`，`vcs:source` 为 `https://github.com/KeygraphHQ/shannon`，`vcs:revision` 为 `94bf442d58539994af1c929dedb8bd958e8198c1`，`github_workflow_ref` 为 `KeygraphHQ/shannon/.github/workflows/release.yml@refs/heads/main`。subject digest 就是上面的 amd64 清单。`startedOn` `2026-11-11T21:14:18.945586435Z`，`finishedOn` `2026-11-11T21:17:15.959382006Z`。
- npm 上 `3.5.1` 的发布时间是 `2026-11-11T21:21:47.691Z`，GitHub Release `v3.5.1` 的 `published_at` 是 `2026-11-11T21:20:17Z`，都在这次成功 run 的末尾。

同一天较早的 run `43095078292` 被标成 failure。它的 Push Docker manifests、Publish npm、Create GitHub release 都是 skipped。失败步骤的日志原文没有摘进本报告。

未复验：没有在本机执行 `cosign verify`。发布当时的日志包含一次成功的 `cosign verify`，那是当时的记录，不是今天重新验证的结果。

## 5. 加固建议

下面只写做法，本次没有执行这些命令，也没有改 CLI。

### 5.1 锁 digest、锁版本

1. 把 `Dockerfile` 两处 `FROM cgr.dev/chainguard/wolfi-base:latest` 改成带 digest 的引用，例如本次解析到的 `cgr.dev/chainguard/wolfi-base@sha256:2c12da5496e21e99003b3db3b9246f025e53d533c4df334205391260f1e8f85b`。更新基础镜像时改 digest，并让 CI 记录它。不要继续跟踪 `:latest`。
2. `apk add` 写上本次打算接受的版本，或者引入 Wolfi/apk 的锁文件并在 CI 里拒绝漂移。至少把 `nodejs-22`、`npm-12`、`python-3.13`、`chromium`、`git`、`curl`、`ca-certificates` 这些直接包钉住。
3. Typst 下载后校验 sha256。本次两边文件哈希都是 `3ac6b84150c50a694d44134dc201624fbdc44f705b9992124a13474ddf8c6413`，可以把这个值当作当前 0.14.2 musl amd64 二进制的已知值，再为 arm64 单独记录。
4. `npm install -g pnpm@10.33.0` 和 `npm install -g @playwright/cli@0.1.1` 使用带 integrity 的锁文件，不要只靠版本号。
5. 把 Chrome for Testing 的版本和 zip sha256 写进构建参数。`playwright-cli install --skills` 现在会在 `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD` 生效前下载浏览器，而且下载结果留在镜像的 `/root/.cache/ms-playwright`。若运行时只用 Wolfi 的 `/usr/bin/chromium-browser`，应关掉这次额外下载，避免一个未校验的浏览器二进制进入镜像。
6. `docker-compose.yml` 和 `apps/cli/infra/compose.yml` 的 Temporal 镜像改为 `temporalio/temporal@sha256:9c5b386d86bca59ba08f32ddc4c51287351c8c616b6a8359f03e96a585e137f4`，或至少把该 digest 记在发布说明里。这是本次 pull 到的索引 digest，以后标签仍可能被覆盖。
7. 发布工作流已经按 digest 推送再打标签。客户端仍按标签拉。让发布说明同时写出索引 digest 和 amd64 清单 digest。`npx semantic-release@25` 改成完整版本。

### 5.2 让 npx 使用自建镜像

仓库现在的两条路径：

- 本地模式：`./shannon` 设置 `SHANNON_LOCAL=1`。`getWorkerImage` 返回 `shannon-worker`，也就是 `shannon-worker:latest`，不会去 Docker Hub。`buildImage` 打的标签就是这个名字。
- npx 模式：返回 `keygraph/shannon:<已安装 CLI 的 package.json 版本>`。`ensureImage` 如果本地已经有这个标签，就不再 pull，只检查标签 `shannon.worker-protocol` 是否等于 `workflow-id-v1`。本次自建镜像有这个标签。它不比较 digest。

因此，在不改代码的情况下：

1. 给本地模式用：`docker tag shannon-worker:local shannon-worker`，然后在仓库里用 `./shannon start`。这是现有代码设计的自建路径。
2. 给当前 npx 3.5.1 用：`docker tag shannon-worker:local keygraph/shannon:3.5.1`。之后 `npx @keygraph/shannon`（解析到 3.5.1）会因为本地已有该标签而跳过 pull。这会挡住官方镜像，而且 CLI 不会发现内容其实来自另一个提交。不建议把它当作长期做法。

更稳妥的代码改法，仍然只是建议：

- 增加显式镜像覆盖，例如只接受 `repo@sha256:...` 的环境变量，npx 与本地模式都走它。
- 默认继续按版本标签解析，但把发布时的 digest 写进 CLI 包，pull 之后比对 `RepoDigest`，不一致就停止。
- 不要靠预先占用 `keygraph/shannon:<version>` 标签来替换官方镜像。

本次没有打这些标签，没有运行 start。

## 6. 未覆盖项

- 没有 `docker run`，因此没有验证入口脚本、`pentest` 降权、Chromium 能否启动、Typst 能否编译、worker 进程能否连上 Temporal。
- 没有构建 linux/arm64。Hub 的 arm64 清单 digest 只从索引和 Actions 日志记录，没有在本机解开。
- 没有在 `v3.5.1` 的提交 `94bf442d58539994af1c929dedb8bd958e8198c1` 上重放 `docker build`。同一提交、同一 BuildKit 是否得到同一层 digest，未核实。
- 没有在本机执行 `cosign verify`。
- 没有使用 dive。
- 没有对 `temporalio/temporal:1.7.0` 做 syft。Alpine minirootfs 3.23.4 来自 `docker history` 的 `ADD` 行，压缩包校验和未核实。
- syft 文件目录不是完整文件系统清单。`pnpm-lock.yaml`、`entrypoint.sh`、`typst` 是从对应层的 tar 里取出后做的 sha256。其余路径没有逐文件比对。
- rust crate 只比较了 artifact 条数，没有逐条比版本。
- 失败的 Actions run `43095078292` 只记录了 job 结论，没有摘录失败日志。
- 本地 provenance 的 `builder.id` 为空，不能用它证明构建者身份；它只能证明 BuildKit 记录到的提交和基础镜像 digest。
