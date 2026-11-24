# AltServer 自编译：让 AltStore 在 macOS 26 / Intel 黑苹果上重新能登录

2026-11-24 实测通过：自编译 AltServer 在 macOS 26.7.1（x86_64 / AMD 黑苹果 / OpenCore 1.0.8 / MacBookPro16,4）上成功登录 Apple ID，并安装 1.25 GB IPA。

---

## 1. 根因（一句话）

**AltStore classic 源码里已经写好了远程 anisette v3 客户端，但被 `if #available(macOS 27, *)` 挡住了。**

Apple 从 2026-10-14 起拒绝声明 Android 身份的 anisette，返回 503 + 472 字节 HTML；本机 AOSKit 生成的 ADI 也被一并拒绝。AltStore 1.8.4 为此加了 `RemoteAnisetteDataFetcher`（走 anisette v3 服务器），但只在 macOS 27+ 启用。于是：

- 官方 1.8.4 在 macOS 26 上 → 继续走 AOSKit → 503
- 升级到 macOS 27 → 才切远程 anisette（但 Intel 机器上不了 27）

**补丁本体只有一行**：把门槛从 27 降到 13（远程 anisette 客户端本身只要 macOS 13）。

```swift
-        if #available(macOS 27, *)
+        if #available(macOS 13, *) // PATCHED: remote anisette only needs 13+
```

这条也是"为什么必须在 macOS 26 上自编译"的全部理由：官方二进制里这段逻辑存在但不可达。

---

## 2. 编译环境

| 项 | 版本 / 说明 |
|---|---|
| Xcode | **26.6**（最后一个支持 Intel 的版本；27 仅 Apple Silicon） |
| 系统 | macOS 26.7.1，x86_64 |
| 架构参数 | `ARCHS=x86_64`（必须显式指定，否则会去编 arm64 OpenSSL 而失败） |
| 签名 | `CODE_SIGN_IDENTITY=-`，adhoc |

---

## 3. 踩过的坑（按出现顺序，11 个）

| # | 现象 | 根因 | 处理 |
|---|---|---|---|
| 1 | SPM 解析 SSL 失败 | 网络/代理拦截 GitHub | codeload 下载 zip → 本地 `git init` 仓库 → `revision` 锁 commit，pbxproj 改 `file://` |
| 2 | `binary target 'IDevice' could not be mapped` | checksum 与本地包不符 | 用官方 IDevice.xcframework 并对齐 checksum |
| 3 | `expectedSignature` 不匹配 | OpenSSL.xcframework 的签名者不是 pbxproj 里写的那位 | 删除该字段 |
| 4 | 编 arm64 OpenSSL 缺 `opensslconf-arm64.h` | 本地 OpenSSL 只有 x86_64 切片 | `ARCHS=x86_64` + 清 derivedData |
| 5 | corecrypto `-Werror` 隐式转换 | Xcode 26 更严 | 源码里显式 `(int8_t)` cast（工程设置无效，`-Werror` 硬编码在参数里） |
| 6 | `common/thread.c` not found | libusbmuxd 版本混用 | 整体替换为 **2.0.2**（含 `common/`） |
| 7 | `PACKAGE_VERSION is not defined!` | autotools 宏在 Xcode 构建下不存在 | `#ifndef` 兜底为 `"2.3.0"` |
| 8 | `PLIST_FORMAT_XML` 重定义 / 函数签名冲突 | libplist 头里多份 enum 定义 | 删重复 enum，声明与实现统一为 `plist_format_t` |
| 9 | `openssl/provider.h` not found、`ASN1_STRING_get0_data` 未声明 | AltSign 新代码按 OpenSSL **3.x** 写，而打包的 xcframework 是 **1.0.2u** | 用 `OPENSSL_VERSION_NUMBER` 宏做双向兼容（见下） |
| 10 | `no such file: AltSign-Dynamic.framework/Versions/A/AltSign-Dynamic` | `.dynamic` 产品在 Xcode 26 下产出 **codeless framework**（每个 target 各自成 framework，产品本身无二进制） | 产品改成 **static**，整条 framework 嵌入链绕开 |
| 11 | `'RemoteAnisetteDataFetcher' is only available in macOS 13 or newer` | AltServer 部署目标 12.0，补丁把 `if #available` 抹掉了 | 门槛设 13 + `resync` 补 `guard #available` |

### 第 9 条的兼容写法（OpenSSL 1.0.2u ↔ 3.x）

```objc
#include <openssl/opensslv.h>

#if OPENSSL_VERSION_NUMBER >= 0x30000000L
#include <openssl/provider.h>
#define ALT_HAS_OSSL_PROVIDER 1
#endif

#if OPENSSL_VERSION_NUMBER < 0x10100000L
#define ASN1_STRING_get0_data ASN1_STRING_data
#endif
```

`+load` 里的 `OSSL_PROVIDER_try_load(NULL, "legacy", 1)` 用 `#ifdef ALT_HAS_OSSL_PROVIDER` 包住。1.0.2 自带 RC2/3DES，读老 `.p12` 反而更省事。

### 第 10 条为什么必须改静态

日志里明确写着 `note: Signing codeless framework`，产物目录只有 `Info.plist` + `_CodeSignature`。这类 framework 既不能链接，也不能嵌入，运行时必然 `@rpath` 找不到。改成静态后：`Contents/Frameworks` 只剩 `OpenSSL` / `STPrivilegedTask` / `Sparkle`，AltSign 全部并入主二进制。

同时因为每个 target 被单独链接，还要给它们各自补链接参数：

```swift
// target "ldid" / "CAltSign"
linkerSettings: [ .linkedFramework("OpenSSL") ]

// target "AltSign"：corecrypto 是 corecrypto.xcodeproj 的产物，SwiftPM 看不见
linkerSettings: [
    .unsafeFlags(["-L/tmp/altstore-build/Build/Products/Release"]),
    .linkedLibrary("corecrypto_static"),
]
```

---

## 4. 运行时：Clash 必须关

关掉 Clash 之前，AltStore 报 **"No anisette server is currently available."**（`AnisetteError.remoteServerUnavailable`，serverURL 为空 = 所有服务器都失败）。

原因：provisioning 那一步是 **WSS WebSocket**（`wss://<server>/v3/provisioning_session`），MITM 代理会把 TLS 掐断。实测 6 个服务器里有 4 个在代理下直接 TLS/HTTP2 失败。

若必须开代理，至少让这些走直连：`gsa.apple.com`、`cdn.altstore.io`、`*.stikstore.app`、`ani.jkcoxson.com`。

服务器返回的身份（决定 Apple 是否放行）：

```json
{"client_info":"<MacBookPro13,3> <Mac OS X;10.12.6;16G29> <com.apple.AuthKit/1 (com.apple.akd/1.0)>",
 "user_agent":"akd/1.0 CFNetwork/811.5.4 Darwin/16.7.0"}
```

AltSign 的请求头 `X-MMe-Client-Info` 与 UA 都取自这份数据（`anisetteData.deviceDescription` / `authenticationUserAgent`），所以不会出现"anisette 是 Mac、请求头是 Android"的错配 —— 这是远程 anisette 能过 Apple 校验的关键。

---

## 5. 已知副作用

登录时 AltStore 弹 **"Multiple AltServers Not Supported"**：换 AltServer 实例 = 换签名证书，旧 AltServer 装的 App 无法刷新。点 Continue，用新 AltServer 重装即可。免费账号有证书/App ID 额度，必要时在 AltStore 设置里清理旧证书。

---

## 6. 产物

```
AltServer.app   27 MB   x86_64   adhoc + hardened runtime
                     identifier: com.rileytestut.AltServer
```

---

## 7. License

本仓库内容是从 [rileytestut/AltStore](https://github.com/rileytestut/AltStore)（classic 分支）派生的补丁与文档，`files/` 下的文件为上游源码的修改版本，因此沿用 **AGPLv3**（见 `LICENSE`）。不包含任何预编译二进制。

