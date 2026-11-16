# Shannon 锁定构建

本文件记录锁定依赖之后的 worker 镜像构建。构建只使用 `docker build`。没有执行 `docker run`、`docker compose up`，没有启动 Temporal 或其他服务，没有运行 `./shannon`、`npx` 或 agent，没有连接目标，没有调用 LLM API。

## 构建环境

| 项 | 实测值 |
| --- | --- |
| 操作系统 | Ubuntu 24.04.5 LTS |
| 内核 | Linux 6.12.113+，`uname -srm` 为 `Linux 6.12.113+ x86_64` |
| CPU | `/proc/cpuinfo` 的 `model name` 为 `Intel(R) Xeon(R) Processor`，`nproc` 为 4 |
| 内存 | `/proc/meminfo` 的 `MemTotal` 为 16387328 kB |
| 架构 | x86_64 |
| Docker 客户端 / 引擎 | 29.1.3（Ubuntu 包 `29.1.3-0ubuntu3~24.04.2`） |
| containerd | 2.2.1 |
| runc | 1.3.4-0ubuntu1~24.04.1 |
| docker-buildx | 0.30.1（`0.30.1-0ubuntu1~24.04.1`） |
| BuildKit | v0.26.2（`docker buildx ls` 的默认 builder） |
| 源码提交 | `4cef63e5900c9eda0b259a44f89458c7f8b1e10d` |
| `SOURCE_DATE_EPOCH` | `1793983417`，即该提交的提交者时间 `2026-11-06T22:13:37+05:30`（UTC `2026-11-06T16:43:37Z`） |

本机没有 systemd。dockerd 只为 `docker build` 和 `docker image inspect` 运行。

## 构建命令与时间

两次命令相同，工作目录是仓库根目录。第二次把标签改成 `shannon-worker:local-2`，避免覆盖第一次的镜像。`--no-cache` 让两次都重新执行 `RUN`。`--provenance=false` 让导出的 digest 是镜像清单本身，不附带带有墙钟时间的 provenance。

```text
docker build --progress=plain --no-cache --provenance=false --build-arg SOURCE_DATE_EPOCH=1793983417 -t shannon-worker:local -t shannon-worker .
```

第二次只改了标签：`-t shannon-worker:local-2`。

| 次数 | 开始（HKT） | 结束（HKT） | 耗时 | 退出码 |
| --- | --- | --- | --- | --- |
| 1 | 2026-11-17T02:11:36+0800 | 2026-11-17T02:13:59+0800 | 143 秒 | 0 |
| 2 | 2026-11-17T02:14:40+0800 | 2026-11-17T02:16:56+0800 | 136 秒 | 0 |

耗时由上述两个 `date` 时间戳相减得到。

网络源，来自构建日志里实际出现的 URL，以及锁文件的校验方式：

| 用途 | 地址 |
| --- | --- |
| Wolfi 基础镜像 | `cgr.dev/chainguard/wolfi-base`，按 digest 拉取 |
| apk 索引 | `https://apk.cgr.dev/chainguard/x86_64/APKINDEX.tar.gz` |
| pnpm 10.33.0 | `https://registry.npmjs.org/pnpm/-/pnpm-10.33.0.tgz` |
| 工作区依赖 | `pnpm install --frozen-lockfile`。构建日志没有逐条打印 tarball URL。`.npmrc` 没有改 registry，`pnpm-lock.yaml` 为每个包记录了 `integrity` |
| `@playwright/cli` 及其依赖 | `npm ci` 使用 `docker/playwright-cli/package-lock.json`，resolved 地址在 `https://registry.npmjs.org` |
| Typst 0.14.2 | `https://github.com/typst/typst/releases/download/v0.14.2/typst-x86_64-unknown-linux-musl.tar.xz` |
| Chrome for Testing | `https://cdn.playwright.dev/builds/cft/146.0.7680.0/linux64/chrome-linux64.zip` |

这次是 amd64 构建，所以日志里没有请求 arm64 的 Typst 和 Chrome URL。这两个 URL 和校验和写在 Dockerfile 里，供 aarch64 使用。

## 两次构建的 digest

两次都不一致。

| 项 | 第一次 `shannon-worker:local` | 第二次 `shannon-worker:local-2` |
| --- | --- | --- |
| 镜像 Id / 清单 digest | `sha256:f0235743b7a55e147fc32bcb32a54854b95013bde4e9f2721b6d53c80ecd7f19` | `sha256:b86abab70c9ba9d085afb5b7036d9cc7e1ea4139e1f201edd2efa8b06c0869b5` |
| config digest | `sha256:35e8f9b46c5948c7dc94583545f399d0cef388dbbe05d0d138142c706dbec2c5` | `sha256:3bfa82e8fd9f8650be575f0c8722c0c172eae3538573b3ad0e773d34c542d3d8` |
| `Created` | `2026-11-06T16:43:37Z` | `2026-11-06T16:43:37Z` |
| `docker image inspect` 的 Size | 859328968 | 859327027 |
| rootfs 层数 | 32 | 32 |
| 相同的层 | 13 | 13 |
| 不同的层 | 19 | 19 |

`Entrypoint`、`Cmd`、`User`、`WorkingDir`、`Env`、`Labels` 两边相同。`docker history` 的命令文本和打印出来的 Size 两边相同。

抽查了第一处不同的层。它是把 `docker/apk-runtime.lock` 复制到 `/tmp/apk-runtime.lock` 的那一层。文件名、大小（3853 字节）和文件 mtime（1794852593）相同。不同的是目录 `tmp` 的 mtime：第一次 1794852697，第二次 1794852880。这两层压缩后的大小分别是 1.864kB 和 1.866kB。没有把其余 18 个不同层逐个拆开，所以不能把它们全部说成只有目录时间不同。

第一次构建的日志有 `typst 0.14.2 (b33de9de)`。两次日志都没有 `Downloading`，`playwright-cli install --skills` 没有再下载浏览器。

## 锁定清单

| 组件 | 原写法 | 锁定值 | 校验方式 |
| --- | --- | --- | --- |
| Wolfi 基础镜像 | `cgr.dev/chainguard/wolfi-base:latest` | `cgr.dev/chainguard/wolfi-base@sha256:2c12da5496e21e99003b3db3b9246f025e53d533c4df334205391260f1e8f85b` | 镜像 digest。builder 和 runtime 使用同一个索引 digest |
| Temporal | `temporalio/temporal:1.7.0` | `temporalio/temporal@sha256:9c5b386d86bca59ba08f32ddc4c51287351c8c616b6a8359f03e96a585e137f4` | 镜像索引 digest。`docker-compose.yml` 和 `apps/cli/infra/compose.yml` 都已改 |
| npx 所用 worker 镜像 | `keygraph/shannon:<CLI 版本>` | `keygraph/shannon@sha256:c31b05cd9273816e7ccb3c5a76658b17debd9c433a615a87c19607dee867be02` | 镜像索引 digest。这是 2026-11-16 拉取时 `3.5.1` 与 `latest` 的共同 digest，不是本次自建镜像 |
| 本地模式 worker 镜像 | `shannon-worker` | 仍由 `./shannon build` 从本 Dockerfile 构建并打 `shannon-worker` 标签 | 不从仓库拉取。本次测量标签是 `shannon-worker:local` |
| pnpm | `npm install -g pnpm@10.33.0` | `https://registry.npmjs.org/pnpm/-/pnpm-10.33.0.tgz` | sha512 `EFaLtKavtYyes2MNqQzJUWQXq+vT+rvmc58K55VyjaFJHp21pUTHatjrdXD1xLs9bGN7LLQb/c20f6gjyGSTGQ==`。构建日志确认 `pnpm v10.33.0` |
| 工作区 npm 依赖 | `pnpm-lock.yaml` | 文件未改 | 锁文件里的 `integrity`，安装使用 `--frozen-lockfile` |
| `@playwright/cli` | `npm install -g @playwright/cli@0.1.1` | `docker/playwright-cli/package-lock.json` 中的 0.1.1 | lockfile `integrity`。`npm ci --ignore-scripts` |
| `playwright` | 原先作为 cli 的未在 Dockerfile 写出版本的依赖 | `1.59.0-alpha-1771104257000` | 同上 |
| `playwright-core` | 同上 | `1.59.0-alpha-1771104257000` | 同上 |
| `minimist` | 同上，范围 `^1.2.5` | `1.2.8` | 同上 |
| Typst amd64 | `v0.14.2` 的 GitHub tarball，无校验和 | `typst-x86_64-unknown-linux-musl.tar.xz` | sha256 `a6044cbad2a954deb921167e257e120ac0a16b20339ec01121194ff9d394996d` |
| Typst arm64 | 同上 | `typst-aarch64-unknown-linux-musl.tar.xz` | sha256 `491b101aa40a3a7ea82a3f8a6232cabb4e6a7e233810082e5ac812d43fdcd47a`。本机下载校验过，没有做 arm64 镜像构建 |
| Chrome for Testing amd64 | `playwright-cli install --skills` 自行下载，版本不在 Dockerfile 里 | `146.0.7680.0` 的 `linux64/chrome-linux64.zip` | sha256 `6b3550372c9d912dd016d3333a8821e903f97277fb1fab503c9fa6ad426dd2a7` |
| Chrome for Testing arm64 | 同上 | revision `1212` 的 `chromium-linux-arm64.zip` | sha256 `da0e6af6376948fa868d2fc01cf1ebb68b8ac7f083590a676a07d7d93c87debb`。本机下载校验过，没有做 arm64 镜像构建 |
| apk 直接包和闭包 | `apk add` 只写包名 | `docker/apk-builder.lock` 58 个，`docker/apk-runtime.lock` 192 个 | 见下表。`apk add` 使用 `包=版本` |

`npm` 这个包名在 Wolfi 里解析成 `npm-12`。`python3` 解析成 `python-3.13`。锁文件写的是实际安装的包名。

Dockerfile 原来点名的包：

| 原包名 | 阶段 | 锁定值 |
| --- | --- | --- |
| build-base | builder | 1-r10 |
| wget | builder | 1.25.0-r21 |
| git | builder 与 runtime | 2.56.1-r1 |
| curl | builder 与 runtime | 8.23.0-r3 |
| ca-certificates | builder 与 runtime | 20261020-r0 |
| nodejs-22 | builder 与 runtime | 22.23.2-r1 |
| npm | builder 与 runtime | npm-12=12.2.2-r1 |
| bash | builder 与 runtime | 5.3-r14 |
| shadow | runtime | 4.20.3-r4 |
| xz | runtime | 5.8.4-r2 |
| python3 | runtime | python-3.13=3.13.18_git20261115-r1，python-3.13-base 同版本 |
| chromium | runtime | 149.0.7827.53-r0 |
| nss | runtime | 3.133-r0 |
| freetype | runtime | 2.15.0-r0 |
| harfbuzz | runtime | 15.1.0-r0 |
| libx11 | runtime | 1.8.14-r4 |
| libxcomposite | runtime | 0.4.7-r6 |
| libxdamage | runtime | 1.1.7-r5 |
| libxext | runtime | 1.3.7-r5 |
| libxfixes | runtime | 6.0.2-r4 |
| libxrandr | runtime | 1.5.5-r7 |
| mesa-gbm | runtime | 26.3.0-r0 |
| fontconfig | runtime | 2.18.3-r5 |

这些版本来自锁定前一次 amd64 构建的 apk 安装日志，不是估计。完整闭包如下。基础镜像里已有、且这次 `apk add` 没有再安装的包，没有单独写进行。它们由上面的 Wolfi digest 固定。

| 包 | 阶段 | 锁定版本 | 校验方式 |
| --- | --- | --- | --- |
| alsa-lib | runtime | 1.2.16.1-r6 | apk 版本号 |
| aom-libs | runtime | 3.15.3-r1 | apk 版本号 |
| at-spi2-core | runtime | 2.62.1-r1 | apk 版本号 |
| avahi-libs | runtime | 0.9_rc5-r4 | apk 版本号 |
| bash | 两边 | 5.3-r14 | apk 版本号 |
| binutils | builder | 2.47-r4 | apk 版本号 |
| brotli | runtime | 1.2.1-r3 | apk 版本号 |
| brotli-dev | runtime | 1.2.1-r3 | apk 版本号 |
| bubblewrap | runtime | 0.13.1-r1 | apk 版本号 |
| build-base | builder | 1-r10 | apk 版本号 |
| c-ares | 两边 | 1.34.9-r0 | apk 版本号 |
| ca-certificates | 两边 | 20261020-r0 | apk 版本号 |
| cairo | runtime | 1.18.6-r2 | apk 版本号 |
| cairo-gobject | runtime | 1.18.6-r2 | apk 版本号 |
| chromium | runtime | 149.0.7827.53-r0 | apk 版本号 |
| crc32c | runtime | 1.1.2-r7 | apk 版本号 |
| cryptsetup | runtime | 2.8.8-r4 | apk 版本号 |
| cups-libs | runtime | 2.4.20-r0 | apk 版本号 |
| curl | 两边 | 8.23.0-r3 | apk 版本号 |
| cyrus-sasl-heimdal-libs | 两边 | 2.1.28-r58 | apk 版本号 |
| dbus | runtime | 1.16.4-r0 | apk 版本号 |
| dbus-libs | runtime | 1.16.4-r0 | apk 版本号 |
| device-mapper-libs | runtime | 2.03.44-r1 | apk 版本号 |
| double-conversion | runtime | 3.4.0-r5 | apk 版本号 |
| e2fsprogs-libs | runtime | 1.47.4-r6 | apk 版本号 |
| font-opensans | runtime | 0_git20210927-r3 | apk 版本号 |
| fontconfig | runtime | 2.18.3-r5 | apk 版本号 |
| fontconfig-config | runtime | 2.18.3-r5 | apk 版本号 |
| freetype | runtime | 2.15.0-r0 | apk 版本号 |
| fribidi | runtime | 1.0.18-r3 | apk 版本号 |
| gcc | builder | 16.2.0-r4 | apk 版本号 |
| gdbm | 两边 | 1.26-r10 | apk 版本号 |
| gdk-pixbuf | runtime | 2.44.8-r7 | apk 版本号 |
| git | 两边 | 2.56.1-r1 | apk 版本号 |
| glib | runtime | 2.90.1-r2 | apk 版本号 |
| glibc-2.44-dev | builder | 2.44-r20 | apk 版本号 |
| glycin-2 | runtime | 2.2.6-r0 | apk 版本号 |
| glycin-2-libs | runtime | 2.2.6-r0 | apk 版本号 |
| gmp | builder | 6.3.0-r13 | apk 版本号 |
| graphite2 | runtime | 1.3.15-r7 | apk 版本号 |
| gtk-3 | runtime | 3.24.52-r6 | apk 版本号 |
| gtk-3-update-icon-cache | runtime | 3.24.52-r6 | apk 版本号 |
| harfbuzz | runtime | 15.1.0-r0 | apk 版本号 |
| heimdal-libs | 两边 | 7.8.0-r56 | apk 版本号 |
| icu78-data-full | 两边 | 78.3-r4 | apk 版本号 |
| isl | builder | 0.28-r6 | apk 版本号 |
| json-c | runtime | 0.19-r2 | apk 版本号 |
| keyutils-libs | 两边 | 1.6.3-r42 | apk 版本号 |
| kmod | runtime | 34.3-r1 | apk 版本号 |
| kmod-libs | runtime | 34.3-r1 | apk 版本号 |
| krb5-conf | 两边 | 1.0-r10 | apk 版本号 |
| krb5-libs | 两边 | 1.22.2-r6 | apk 版本号 |
| lcms2 | runtime | 2.20-r0 | apk 版本号 |
| libLLVM-23 | runtime | 23.1.5-r0 | apk 版本号 |
| libacl1 | runtime | 2.4.0-r6 | apk 版本号 |
| libarchive | runtime | 3.8.11-r0 | apk 版本号 |
| libasyncns | runtime | 0.8-r10 | apk 版本号 |
| libatk-1.0 | runtime | 2.62.1-r1 | apk 版本号 |
| libatk-bridge-2.0 | runtime | 2.62.1-r1 | apk 版本号 |
| libatomic | builder | 16.2.0-r4 | apk 版本号 |
| libaudit | runtime | 4.2.1-r5 | apk 版本号 |
| libblkid | runtime | 2.42.4-r3 | apk 版本号 |
| libbsd | runtime | 0.12.2-r11 | apk 版本号 |
| libbz2-1 | runtime | 1.0.8-r31 | apk 版本号 |
| libcap | runtime | 2.78-r5 | apk 版本号 |
| libcap-ng | runtime | 0.9.6-r2 | apk 版本号 |
| libcom_err | 两边 | 1.47.4-r6 | apk 版本号 |
| libcurl-openssl4 | 两边 | 8.23.0-r3 | apk 版本号 |
| libdav1d | runtime | 1.5.4-r4 | apk 版本号 |
| libde265 | runtime | 1.1.3-r1 | apk 版本号 |
| libdrm | runtime | 2.4.134-r0 | apk 版本号 |
| libelf | runtime | 0.197-r1 | apk 版本号 |
| libepoxy | runtime | 1.5.10-r12 | apk 版本号 |
| libexpat1 | 两边 | 2.10.0-r1 | apk 版本号 |
| libfdisk | runtime | 2.42.4-r3 | apk 版本号 |
| libffi | runtime | 3.8.0-r2 | apk 版本号 |
| libflac | runtime | 1.5.0-r3 | apk 版本号 |
| libfontconfig1 | runtime | 2.18.3-r5 | apk 版本号 |
| libglvnd | runtime | 1.7.0-r13 | apk 版本号 |
| libgomp | 两边 | 16.2.0-r4 | apk 版本号 |
| libheif | runtime | 1.23.7-r2 | apk 版本号 |
| libicu78 | 两边 | 78.3-r4 | apk 版本号 |
| libidn2 | 两边 | 2.3.8-r13 | apk 版本号 |
| libjpeg-turbo | runtime | 3.2.1-r0 | apk 版本号 |
| libjxl | runtime | 0.12.0-r3 | apk 版本号 |
| libldap-2.6 | 两边 | 2.6.14-r0 | apk 版本号 |
| libltdl | runtime | 2.5.4-r6 | apk 版本号 |
| liblz4-1 | runtime | 1.11.1-r0 | apk 版本号 |
| libmd | runtime | 1.3.0-r2 | apk 版本号 |
| libmount | runtime | 2.42.4-r3 | apk 版本号 |
| libnghttp2-14 | 两边 | 1.71.0-r0 | apk 版本号 |
| libnspr | runtime | 4.40-r3 | apk 版本号 |
| libnss | runtime | 3.133-r0 | apk 版本号 |
| libogg | runtime | 1.3.6-r5 | apk 版本号 |
| libopenjph0.33 | runtime | 0.33.0-r1 | apk 版本号 |
| libpciaccess | runtime | 0.19-r4 | apk 版本号 |
| libpcre2-16-0 | runtime | 10.49-r3 | apk 版本号 |
| libpcre2-8-0 | 两边 | 10.49-r3 | apk 版本号 |
| libpkgconf8 | builder | 3.0.11-r0 | apk 版本号 |
| libpng | runtime | 1.6.59-r0 | apk 版本号 |
| libpsl | 两边 | 0.23.3-r4 | apk 版本号 |
| libpulse | runtime | 17.0-r14 | apk 版本号 |
| libquadmath | builder | 16.2.0-r4 | apk 版本号 |
| librsvg | runtime | 2.63.4-r4 | apk 版本号 |
| libsdl2 | runtime | 2.32.10-r5 | apk 版本号 |
| libseccomp | runtime | 2.6.1-r5 | apk 版本号 |
| libselinux | runtime | 3.11-r3 | apk 版本号 |
| libsemanage | runtime | 3.11-r4 | apk 版本号 |
| libsepol | runtime | 3.11-r4 | apk 版本号 |
| libsndfile | runtime | 1.2.2-r7 | apk 版本号 |
| libssh | runtime | 0.12.2-r4 | apk 版本号 |
| libstdc++ | 两边 | 16.2.0-r4 | apk 版本号 |
| libstdc++-dev | builder | 16.2.0-r4 | apk 版本号 |
| libsvtav1enc4 | runtime | 4.3.0-r0 | apk 版本号 |
| libsystemd | runtime | 262.2-r2 | apk 版本号 |
| libsystemd-compression-libs | runtime | 262.2-r2 | apk 版本号 |
| libsystemd-shared | runtime | 262.2-r2 | apk 版本号 |
| libudev | runtime | 262.2-r2 | apk 版本号 |
| libunistring | 两边 | 1.5-r1 | apk 版本号 |
| libuuid | runtime | 2.42.4-r3 | apk 版本号 |
| libuv | 两边 | 1.53.0-r0 | apk 版本号 |
| libverto | 两边 | 0.3.2-r11 | apk 版本号 |
| libvorbis | runtime | 1.3.7-r14 | apk 版本号 |
| libwebp | runtime | 1.6.0-r7 | apk 版本号 |
| libx11 | runtime | 1.8.14-r4 | apk 版本号 |
| libx11-6 | runtime | 1.8.14-r4 | apk 版本号 |
| libx11-data | runtime | 1.8.14-r4 | apk 版本号 |
| libx11-xcb1 | runtime | 1.8.14-r4 | apk 版本号 |
| libx265-216 | runtime | 4.2-r4 | apk 版本号 |
| libxau | runtime | 1.0.12-r11 | apk 版本号 |
| libxcb | runtime | 1.17.0-r19 | apk 版本号 |
| libxcomposite | runtime | 0.4.7-r6 | apk 版本号 |
| libxcrypt-dev | builder | 4.5.2-r8 | apk 版本号 |
| libxcursor | runtime | 1.2.3-r7 | apk 版本号 |
| libxdamage | runtime | 1.1.7-r5 | apk 版本号 |
| libxdmcp | runtime | 1.1.5-r14 | apk 版本号 |
| libxext | runtime | 1.3.7-r5 | apk 版本号 |
| libxext6 | runtime | 1.3.7-r5 | apk 版本号 |
| libxfixes | runtime | 6.0.2-r4 | apk 版本号 |
| libxft | runtime | 2.3.9-r8 | apk 版本号 |
| libxi | runtime | 1.8.4-r0 | apk 版本号 |
| libxinerama | runtime | 1.1.6-r2 | apk 版本号 |
| libxkbcommon | runtime | 1.13.2-r4 | apk 版本号 |
| libxml2 | runtime | 2.15.0-r0 | apk 版本号 |
| libxrandr | runtime | 1.5.5-r7 | apk 版本号 |
| libxrender | runtime | 0.9.13-r0 | apk 版本号 |
| libxshmfence | runtime | 1.3.3-r7 | apk 版本号 |
| libxslt | runtime | 1.1.45-r8 | apk 版本号 |
| libxtst | runtime | 1.2.6-r0 | apk 版本号 |
| libxxf86vm | runtime | 1.1.7-r5 | apk 版本号 |
| libzstd1 | 两边 | 1.5.7-r14 | apk 版本号 |
| linux-headers | builder | 7.3.4-r0 | apk 版本号 |
| linux-pam | runtime | 1.7.3-r3 | apk 版本号 |
| lmdb | 两边 | 0.9.35-r4 | apk 版本号 |
| lz4 | runtime | 1.11.1-r0 | apk 版本号 |
| make | builder | 4.4.1-r16 | apk 版本号 |
| mesa | runtime | 26.3.0-r0 | apk 版本号 |
| mesa-gbm | runtime | 26.3.0-r0 | apk 版本号 |
| mesa-glx | runtime | 26.3.0-r0 | apk 版本号 |
| mesa-libgallium | runtime | 26.3.0-r0 | apk 版本号 |
| minizip | runtime | 1.4-r0 | apk 版本号 |
| mpc | builder | 1.4.1-r4 | apk 版本号 |
| mpdecimal | runtime | 4.0.1-r6 | apk 版本号 |
| mpfr | builder | 4.2.2-r6 | apk 版本号 |
| ncurses | 两边 | 6.6.20261107-r0 | apk 版本号 |
| ncurses-terminfo-base | 两边 | 6.6.20261107-r0 | apk 版本号 |
| nghttp3 | 两边 | 1.19.0-r0 | apk 版本号 |
| ngtcp2 | 两边 | 1.26.0-r0 | apk 版本号 |
| node-gyp | 两边 | 13.1.0-r1 | apk 版本号 |
| nodejs-22 | 两边 | 22.23.2-r1 | apk 版本号 |
| npm-12 | 两边 | 12.2.2-r1 | apk 版本号 |
| nss | runtime | 3.133-r0 | apk 版本号 |
| openh264 | runtime | 2.7.0-r0 | apk 版本号 |
| openjpeg | runtime | 2.5.4-r4 | apk 版本号 |
| openssf-compiler-options | builder | 20250904-r12 | apk 版本号 |
| openssl-3.6-libcrypto | 两边 | 3.6.5-r6 | apk 版本号 |
| openssl-3.6-libssl | 两边 | 3.6.5-r6 | apk 版本号 |
| opus | runtime | 1.6.1-r5 | apk 版本号 |
| orc | runtime | 0.4.44-r0 | apk 版本号 |
| pango | runtime | 1.58.2-r2 | apk 版本号 |
| pixman | runtime | 0.46.4-r9 | apk 版本号 |
| pkgconf | builder | 3.0.11-r0 | apk 版本号 |
| popt | runtime | 1.19-r13 | apk 版本号 |
| posix-cc-wrappers | builder | 2-r10 | apk 版本号 |
| py3-pip-wheel | runtime | 26.2.2-r3 | apk 版本号 |
| python-3.13 | runtime | 3.13.18_git20261115-r1 | apk 版本号 |
| python-3.13-base | runtime | 3.13.18_git20261115-r1 | apk 版本号 |
| qt6-qtbase | runtime | 6.12.0-r2 | apk 版本号 |
| qt6-qtbase-x11 | runtime | 6.12.0-r2 | apk 版本号 |
| quota-tools | runtime | 4.11-r4 | apk 版本号 |
| rav1e | runtime | 0.8.1-r14 | apk 版本号 |
| readline | 两边 | 8.3-r4 | apk 版本号 |
| shadow | runtime | 4.20.3-r4 | apk 版本号 |
| shared-mime-info | runtime | 2.5.1-r6 | apk 版本号 |
| soxr | runtime | 0.1.3-r11 | apk 版本号 |
| speexdsp | runtime | 1.2.1-r7 | apk 版本号 |
| sqlite-libs | 两边 | 3.54.1-r0 | apk 版本号 |
| systemd | runtime | 262.2-r2 | apk 版本号 |
| systemd-boot | runtime | 262.2-r2 | apk 版本号 |
| systemd-systemctl | runtime | 262.2-r2 | apk 版本号 |
| tdb | runtime | 1.4.15-r7 | apk 版本号 |
| tiff | runtime | 4.7.2-r5 | apk 版本号 |
| wayland-libs-client | runtime | 1.26.0-r3 | apk 版本号 |
| wayland-libs-cursor | runtime | 1.26.0-r3 | apk 版本号 |
| wayland-libs-egl | runtime | 1.26.0-r3 | apk 版本号 |
| wayland-protocols | runtime | 1.50-r0 | apk 版本号 |
| wget | builder | 1.25.0-r21 | apk 版本号 |
| xdg-utils | runtime | 1.2.1-r9 | apk 版本号 |
| xkeyboard-config | runtime | 2.49-r0 | apk 版本号 |
| xz | runtime | 5.8.4-r2 | apk 版本号 |
| zstd | runtime | 1.5.7-r14 | apk 版本号 |

## 无法锁定的项

- apk 索引 `https://apk.cgr.dev/chainguard/x86_64/APKINDEX.tar.gz` 没有 digest。锁的是包版本。索引仍是滚动的。若同一个版本号被换成不同的包文件，本次构建不会发现，因为包文件的校验和没有写进仓库。若该版本从索引消失，`apk add` 会失败。
- 镜像层里的目录 mtime 没有被 `SOURCE_DATE_EPOCH` 固定。所以上面两次清单 digest 不同。config 的 `Created` 已被固定成同一个时间。
- npx 钉住的是已发布镜像 `sha256:c31b05cd9273816e7ccb3c5a76658b17debd9c433a615a87c19607dee867be02`。本次自建镜像没有推送，不能把 `sha256:f0235743b7a55e147fc32bcb32a54854b95013bde4e9f2721b6d53c80ecd7f19` 或 `sha256:b86abab70c9ba9d085afb5b7036d9cc7e1ea4139e1f201edd2efa8b06c0869b5` 写成 npx 的拉取目标。本地模式继续构建 `shannon-worker`，不从 Docker Hub 拉 worker。
- arm64 的 Typst 与 Chrome 校验和是在这台 amd64 机器上下载文件后计算的。没有做 arm64 的 `docker build`，所以这两条没有在镜像构建里跑过。
- `package-lock.json` 里有可选依赖 `fsevents` 2.3.2，只用于 darwin。这次 linux 构建的 `npm ci` 输出是 `added 4 packages`，没有安装它。
