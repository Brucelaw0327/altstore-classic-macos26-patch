# AltServer 自编译：让 AltStore 在 macOS 26 / Intel 黑苹果上重新能登录

2026-11-26 实测通过：自编译 AltServer 在 macOS 26.7.1 x86_64 上完成 Apple ID 登录 → 2FA 短信 → 安装/刷新全流程。**本机 AOSKit 的 ADI 有效，远程 anisette 只作兜底。**

---

## 1. 根因（按出现顺序，共三个）

| # | 故障 | 根因 | 修复 |
|---|---|---|---|
| 1 | 官方 1.8.4 在 macOS 26 上只能走 AOSKit，且无兜底 | `if #available(macOS 27, *)` 把已写好的远程客户端锁死；Intel 机器上不了 27 | **AOSKit 优先，失败才回落远程 anisette v3** |
| 2 | 认证请求拿到 **503 + 190 字节** | `X-MMe-Client-Info` 用了 `<macOS;…>`，Apple 边缘直接丢弃（只有 `Mac OS X` 能过） | `osName` 恒为 `"Mac OS X"`（AltStore#1875） |
| 3 | 请求短信验证码拿到 **415** | AltSign 用 XML plist 发 SMS 请求，Apple 现在要 JSON | 换 `PUT /auth/verify/phone` + JSON body（AltSign#62 / #1844） |

**重要更正**：早期判断“本机 AOSKit 的 ADI 被 Apple 拒绝”是**错的** —— 那次实验混入了请求头变量。实际 ADI 一直是好的，Alice 用本机路径一次通过，远程兜底未被触发。

**190 字节响应是边缘丢弃的指纹**，和“凭据错误”的 503 完全不是一回事；排错时先看字节数。

```swift
// requestAnisetteData: 先把本机 AOSKit 作为主路径，失败才回落远程
self.requestAnisetteDataFromAOSKit { result in
    switch result {
    case .success(let data): completion(.success(data))
    case .failure(let e):
        // fall back to RemoteAnisetteDataFetcher (macOS 13+)
    }
}

// requestAnisetteDataFromAOSKit 内
let osName = "Mac OS X"    // 原: (majorVersion < 11) ? "Mac OS X" : "macOS"
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

## 5. 装完之后：关掉 Sparkle 自动更新 ★

**这一步不能省，否则补丁会在某天被静默覆盖回 503。**

自编译版的版本号来自源码，写死在 `project.pbxproj`：

```
MARKETING_VERSION      = 1.8.2      # 编出来就是 1.8.2
CURRENT_PROJECT_VERSION = 99        # build 99
```

而官方最新发布是 **1.8.4**，Sparkle 的更新源是 `https://altstore.io/altserver/sparkle-macos.xml`。于是自编译版会被 Sparkle 判定为"需要更新"，一旦装上官方 1.8.4，`#available(macOS 27)` 那道门槛就回来了 —— 现象和"补丁没生效"完全一样（HTTP 503），但原因和责任完全不同。

装完立刻执行：

```bash
defaults write com.rileytestut.AltServer SUEnableAutomaticChecks -bool false
defaults write com.rileytestut.AltServer SUSkippedVersion -string "1.8.4"
osascript -e 'quit app "AltServer"'; open /Applications/AltServer.app
```

Sparkle 只在启动时读这些键，必须重启一次 app。

更彻底的做法是让它自认最新（连手动「检查更新」都不提示）—— 注意签名顺序，**先签内层 helper 再签外层**：

```bash
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.8.99" /Applications/AltServer.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 9999" /Applications/AltServer.app/Contents/Info.plist
codesign --force --sign - --options runtime /Applications/AltServer.app/Contents/Library/LoginItems/LaunchAtLoginHelper.app
codesign --force --sign - --options runtime /Applications/AltServer.app
```

改过 Info.plist 原签名必然失效，必须重签。这里不建议用 `--deep`：Xcode 构建出来的 `LaunchAtLoginHelper.app` 本身就是 `invalid Info.plist` 状态（它内层 info 在签名后被改写），`--deep` 不能把它纠正过来，显式先签内层才能让 `codesign --verify --deep --strict` 全绿。

**排错时先认版本**，不要急着怀疑补丁：

```bash
defaults read /Applications/AltServer.app/Contents/Info.plist CFBundleShortVersionString
```

- `1.8.2` → 是你的自编译版，503 就往代理 / anisette 服务器方向查
- `1.8.4` → 已被官方版覆盖，补丁没了，装回自编译版

---

## 6. 已知副作用

登录时 AltStore 弹 **"Multiple AltServers Not Supported"**：换 AltServer 实例 = 换签名证书，旧 AltServer 装的 App 无法刷新。点 Continue，用新 AltServer 重装即可。免费账号有证书/App ID 额度，必要时在 AltStore 设置里清理旧证书。

---

## 7. 产物

```
AltServer.app   27 MB   x86_64   adhoc + hardened runtime
                     identifier: com.rileytestut.AltServer
```

---

## 8. License

本仓库内容是从 [rileytestut/AltStore](https://github.com/rileytestut/AltStore)（classic 分支）派生的补丁与文档，`files/` 下的文件为上游源码的修改版本，因此沿用 **AGPLv3**（见 `LICENSE`）。不包含任何预编译二进制。

