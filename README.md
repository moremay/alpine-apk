# alpine-apk

为 [docker-php](https://github.com/moremay/docker-php) 构建**版本固定 + 安全补丁**的 Alpine APK。

上游 Alpine 仓库里的包不保证满足镜像需求（版本漂移、CVE 未 backport、ABI/so 版本变化），
这个仓库把这些包固定下来，以 `pkgrel=100` 重新打包，供 Dockerfile 用 `pkg=ver-r100` 精确安装。

## 包含的包

| 目录 | 版本 | 说明 |
| --- | --- | --- |
| `wolfssl/` | 5.9.4 | curl 的 TLS 后端，构建顺序上必须先于 curl |
| `curl/` | 8.23.0 | 依赖 wolfssl，`update-curl-ssl.sh` 会自动把 wolfssl 的版本拼成 `wolfssl-dev=<ver>-r100` |
| `libxml2/` | 2.13.9 | 上游 `main/libxml2` 长期停在 2.13.9-r2，2.15.4 修复的一批 CVE 未 backport（[alpine/aports#18550](https://gitlab.alpinelinux.org/alpine/aports/-/issues/18550)） |

`libxml2-backports/` 是手工维护的补丁源，`libxml2/` 由脚本生成并提交入库。
所有包 `pkgrel` 统一为 `100`，既能与官方仓库区分，也便于在 Dockerfile 中锁定版本。

## 快速开始

依赖：docker。编译全部在 `alpine` 容器内完成（自动 `apk add alpine-sdk`）。

```bash
./build-apk.sh              # 默认构建 wolfssl curl libxml2
./build-apk.sh curl         # 只构建指定包
./build-apk.sh 2>&1 | tee build.log
```

产物：

- `x86_64/*.apk` —— 构建结果（不入库，见 `.gitignore`）
- `x86_64/APKINDEX.tar.gz` —— 每次构建后用当前密钥重签
- `.abuild/` —— 首次运行自动生成的签名密钥与 `abuild.conf`（不入库）

构建脚本 `bin/build.sh` 在容器内执行，宿主机只负责挂载：
`docker run -it --rm -v ./:/root alpine /root/bin/build.sh <pkg...>`。

## 目录结构

```
.
├── bin/build.sh          # 容器内构建脚本：装 alpine-sdk、管理密钥、逐包 abuild、重签索引
├── build-apk.sh          # 宿主机入口
├── wolfssl/APKBUILD
├── curl/APKBUILD
├── libxml2/              # 生成结果：APKBUILD + 全部补丁（提交入库）
├── libxml2-backports/    # 手工维护的 libxml2 CVE 补丁源
├── update-curl-ssl.sh    # 从上游 aports 刷新 wolfssl + curl
├── update-libxml2.sh     # 从上游 aports 刷新 libxml2 并附加 backport
└── .abuild/  x86_64/     # 本地生成物，均被忽略
```

## 更新上游 / 应用补丁

```bash
./update-curl-ssl.sh     # wolfssl → curl，按依赖顺序
./update-libxml2.sh      # libxml2 + libxml2-backports/
```

两个脚本流程一致：

1. 通过 GitLab API 列出 `main/<pkg>` 下的文件并逐个下载到 `<pkg>.tmp/`
   （`ALPINE_GITLAB_API` / `ALPINE_GITLAB_RAW`）；
2. 修改 APKBUILD：`pkgrel=100`、固定依赖版本、调整 configure 开关；
3. libxml2 额外复制 `libxml2-backports/*.patch`，并追加 `source=`、`sha512sums=`、
   `secfixes` 条目；
4. 自检（APKBUILD 非空、`pkgrel=100`、每个补丁同时出现在 `source` 与 `sha512sums`）；
5. 原子替换：原目录改名为 `<pkg>.bak`，`.tmp` 转正。

任一步失败都会清理 `.tmp` 并保留原目录，脚本可重复执行（幂等），重跑结果一致。

> 注意：`set -e` 在 `func || { ... }` 上下文中会失效，脚本内所有关键调用都显式写了
> `if ! func; then return 1; fi`，新增逻辑请保持同样风格。

### libxml2 backport 内容

补丁全部取自上游 2.15.4 的安全修复 commit：

| 补丁 | 说明 | 上游 commit |
| --- | --- | --- |
| `CVE-2026-86137.patch` | xmlregexp NXT 越界读 | `76fe08d97de88bfaef2f7d5cd27f11954cc5bee2` |
| `CVE-2026-86138.patch` | dict.c `xmlDictAddQString` 溢出 | `a4cba4b5b5a8c42e155ed42d2d2a44955465a2e4` |
| `CVE-2026-86139.patch` | uri.c `xmlURIEscapeStr` 溢出 | `8edbbdb09f24d26a2f900141fddc2b9d014f53b0` |
| `CVE-2026-86140.patch` | valid.c `xmlSnprintfElements` 栈溢出 | `d1686f91dbda141a752200419d35639fd6b38340` |
| `CVE-2026-86141.patch` | xmlregexp NULL 解引用（**须排在 86137 之后**） | `e89a8aae4c9b40cdafcf66b3f9e57c62db37bb55` |
| `CVE-2026-86142.patch` | xpointer `xmlXPtrEvalXPtrPart` 溢出 | `6b3a736c0edc74ceec3d82f5252499d7911b3a58` |
| `CVE-2026-86143.patch` | xmlIO 写回调整数溢出（**按 2.13 手工适配**） | `90f293ba74d28b1d570920382e707586f68ebf35` |
| `CVE-2026-86144.patch` | xinclude 不传播 parseFlags（按 Alpine MR !109669 适配） | `b63cd517afecb76582dd9488c55e54ceaf50de61` |

另含 Alpine 自己维护的 `CVE-2026-6732.patch` / `CVE-2026-6732-test.patch`（随 APKBUILD 一起拉取）。

## 签名

- 首次构建自动执行 `abuild-keygen -an` 生成 `.abuild/*.rsa`，并把公钥复制进构建容器的
  `/etc/apk/keys/`；
- 每次构建完成后用同一密钥重签 `x86_64/APKINDEX.tar.gz`；
- 密钥不入库。使用方（docker-php）需要 `.abuild/*.pub` 才能信任这些包。

## 与 docker-php 的关系

本仓库以 **git submodule** 形式挂在 docker-php 的 `apk/` 路径下：

```bash
git clone --recurse-submodules git@github.com:moremay/docker-php.git
# 已 clone 的仓库：
git submodule update --init
```

Dockerfile 通过 `COPY apk/x86_64 /usr/src/repo/x86_64` 和 `COPY apk/.abuild/*.pub /etc/apk/keys/`
使用这些包。注意 `x86_64/` 不入库，**必须先在本仓库构建**，否则 docker-php 镜像构建会在
COPY 阶段失败。

## 验证

```bash
# 直接检查产物元信息
for f in x86_64/*.apk; do tar -xzOf "$f" .PKGINFO | head -5; done

# 在 alpine 容器里以本地仓库方式查询（等价于 docker-php 的 ./check-apk.sh）
docker run --rm -v "$PWD:/usr/src/repo" alpine sh -c '
  cp /usr/src/repo/.abuild/*.pub /etc/apk/keys/
  echo /usr/src/repo/ >> /etc/apk/repositories
  apk update && apk query --all-matches libxml2 --fields version,repositories'
```

## 已知限制

- 只构建 `x86_64`（产物目录写死 `x86_64/`）。
- 构建容器固定用 `alpine`（latest）的默认仓库，与下游镜像的基础镜像版本（3.24）解耦；
  上游 APKBUILD 结构或 configure 开关变化时需要人工跟进。
- 仓库不再包含 CI 工作流，构建需本地执行或自建流水线。

## License

[MIT](./LICENSE)
