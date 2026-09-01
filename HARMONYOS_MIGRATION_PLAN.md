# DanXi（旦挞）HarmonyOS NEXT 重构与迁移方案

> 分析基线：`main` 分支 `53e47f34831184cef9f322e3dc8bf48187da77d9`（2026-08-30）
> 分析范围：手机主应用。Wearable/手表端作为独立项目估算，不计入首版。

## 1. 结论摘要

DanXi 不是 Android 原生应用，而是 Flutter/Dart 多端应用。`android/` 只是很薄的 Flutter 宿主，`MainActivity` 没有 Kotlin 业务代码。因此本项目不存在一条有意义的“Kotlin/Java 转 ArkTS”迁移路径。

建议采用：

1. **长期主线：使用 ArkTS + ArkUI + Stage 模型原生重写 HarmonyOS NEXT 客户端。**
2. **迁移方法：按可独立发布的纵向业务切片迁移，不做逐文件、逐 Widget 翻译。**
3. **复用对象：后端 API 契约、DTO 字段、解析规则、领域算法、脱敏 fixture 和交互规格，而不是 Dart 源文件。**
4. **先做 2 周技术验证：**覆盖 MVP 实际使用的 Neo、Neo2FA、UISLegacy 认证，ArkWeb 2FA、Web/HTTP Cookie 同步、Asset Store/HUKS、安全存储、HTTP/HTML 解析和 Push Token。`UISNeo` 当前没有业务调用，登记兼容性但不阻塞首版。任何一个 MVP P0 门槛失败，都应先解决平台基础能力，不能进入页面批量开发。
5. **Flutter for OpenHarmony 仅作为短期备选验证，不建议直接作为生产主线。**项目 README 指定 Flutter 3.47.2（`README.md:114-120`），依赖锁要求 Flutter `>=3.44.0`（`pubspec.lock:2428-2430`）；公开仓库当前可见的 OHOS 命名分支最高为 `br_3.27.4-ohos-1.0.4`。项目还依赖大量没有 OHOS 实现的平台插件。要走这条路线，需要同时维护 Flutter 引擎版本、插件和平台桥接，长期风险高。

预估：

- **MVP**：登录、基础设置、Dashboard 核心校园服务、课表、考试、茶楼只读；4-6 名工程师约 16-22 周。若要求 12-16 周，必须增加并行团队，并在 P0 Spike 后按实测吞吐重新估算。
- **手机端完整功能对齐**：约 89-127 人周（含约 20% 风险缓冲），4 人团队约 6-8 个月。
- **Wearable、桌面卡片、实况窗等鸿蒙增强功能**：完整对齐后单独排期，不阻塞手机首版。

## 2. 当前代码画像

### 2.1 规模

| 区域 | 文件/行数 | 说明 |
|---|---:|---|
| 全部 Dart | 206 文件，约 43,023 行 | `lib/` 约 42,686 行 |
| `lib/page` | 33 文件，约 15,962 行 | 页面和大量业务编排 |
| `lib/widget` | 51 文件，约 9,705 行 | 通用组件、论坛渲染、课表等 |
| `lib/repository` | 23 文件，约 5,825 行 | 网络、认证、Cookie、抓取解析 |
| `lib/util` | 40 文件，约 4,406 行 | WebVPN、WebView、平台、缓存 |
| `lib/model` | 31 文件，约 2,238 行 | DTO 与领域对象，但并非纯模型层 |
| 测试 | 2 文件，约 132 行 | 基本没有业务、网络和平台测试 |

表现层 `page + widget + feature` 约占 `lib` 的 65%，原生 ArkUI 路线下这部分需要重写。

### 2.2 主要业务

- 复旦统一认证：新 ID、旧 UIS、UIS-Neo 混合认证、2FA、Cookie 持久化、WebVPN。
- Dashboard：校园卡、食堂/图书馆人数、宿舍电量、教务通知、空教室、校车、体育锻炼、付款/身份二维码等。
- 课表与考试：本科/研究生课表、手工课程、考试、成绩、GPA、ICS 导出。
- 茶楼 Forum：登录注册、分页、搜索、Markdown/LaTeX/代码高亮、图片、贴纸、AI 总结、消息、收藏、订阅、管理操作。
- Danke 评教：课程搜索、评价增删改、投票，与 Forum 共用 JWT。
- 平台能力：推送、深链、快捷方式、分享、文件、图库、亮度、截图监听、设备标识、WebView、通知权限。

Forum 至少约 13,793 行，占 `lib` 约 32%，是最大的单个迁移 Epic。

## 3. 关键代码发现

### 3.1 Android 不是业务实现

- `android/app/src/main/kotlin/io/github/w568w/dan_xi/MainActivity.kt:18-23` 只有一个空的 `FlutterActivity`。
- Android Manifest 主要声明网络、MiPush、通知、文件和深链能力：`android/app/src/main/AndroidManifest.xml:4-76`。
- 启动、路由、状态和功能入口均在 Dart：`lib/main.dart:81-215`。

结论：所谓“Android 迁鸿蒙”实际上是“Flutter 应用重构并新增 HarmonyOS 客户端”。

### 3.2 架构边界不够干净

当前名义上是 `Page/Feature -> Repository -> Model/Util`，实际存在大量反向引用：

- Model 引用 Flutter UI、Provider、Repository。
- Repository 引用 Provider、页面枚举和 Widget 类型。
- Provider 缓存页面层编辑器对象。
- 页面直接调用 Repository 单例和静态全局状态。

状态同时使用 `StatefulWidget`、Provider、Riverpod、Hook、EventBus、ValueNotifier、GlobalKey 和 Repository 内部状态。`SettingsProvider.getInstance()` 和 `ForumRepository.getInstance()` 分散在大量调用点。

迁移时不能复制这种依赖结构。旧项目只做“为迁移服务的最小解耦”：抽 API 契约、fixture 和纯算法，不建议先在 Flutter 仓库做一次完整架构重写再迁移。

### 3.3 路由无类型

`lib/main.dart:163-215` 用 `Map<String, Function>` 注册 28 条字符串路由，参数大量使用 `Map<String, dynamic>`。

迁移要求：每个 HarmonyOS 目的页面定义稳定的 destination 名称和参数类型，统一由 `NavPathStack` 管理，禁止在新端继续传动态 Map。

### 3.4 认证是最大技术风险

`lib/repository/fdu/neo_login_tool.dart:56-330` 同时承担：

- HTTP 客户端和共享 CookieJar；
- 手工重定向；
- 四种认证模式；
- 并发登录队列和自动重试；
- 2FA UI 协调；
- WebView Cookie 导入；
- Session 持久化。

`lib/util/browser_util.dart:140-174,279-429` 会在 ArkWeb 对应场景中：

- 打开 2FA 页面；
- 注入账号密码；
- 等待跳转到目标服务；
- 读取目标站和 `id.fudan.edu.cn` Cookie；
- 将 Cookie 导回 HTTP 客户端。

HarmonyOS 的 ArkWeb 官方提供 `WebCookieManager.configCookie*` 和 `fetchCookie*`，技术上具备 Cookie 同步基础，但存在重要版本约束：API 11 的 `fetchCookie*` 只按 URL 返回 `name=value` 字符串，不能无损导出 Domain、Path、Expires、Secure、HttpOnly、SameSite 等属性；完整结构化读取 `fetchAllCookies` 从 API 23 才提供。

因此 P0 Spike 必须先确定最低 API：

- API 23 及以上可评估结构化双向同步。
- API 23 以下只能按明确的复旦域名白名单将认证结果收敛为 host-scoped Cookie，并用真实 fixture 验证；不能实现或宣称通用、无损的 Cookie 桥。
- 无论目标版本如何，都必须真机验证 HttpOnly、同名 Cookie、多 Domain/Path、SameSite、Session Cookie 和多重重定向。

### 3.5 平台判断无法容纳 HarmonyOS

`lib/util/platform_universal.dart:31-51` 只识别 Android、iOS、Linux、macOS、Windows、Web，并定义：

```text
isMobile = Android || iOS
isDesktop = !isMobile
```

如果直接接入 OHOS Flutter，HarmonyOS 很可能被误判为桌面平台，导致 WebView、文件选择、ICS 分享、亮度、通知、设备 ID 等能力走错分支。这里应改成基于 capability 的接口，而不是继续增加 `isHarmony` 条件。

### 3.6 插件生态是 Flutter 路线的硬阻塞

`pubspec.yaml:17-113` 中的平台插件包括：

- P0：`flutter_secure_storage`、`shared_preferences`、`path_provider`、`flutter_inappwebview`。
- P1：`permission_handler`、`share_plus`、`file_picker`、`image_picker`、`gal`、`open_file`、`url_launcher`、`app_links`、`device_info_plus`、`no_screenshot`。
- 平台专用且不可直接复用：`xiao_mi_push_plugin`、`receive_intent`、`device_identity`、iOS CoreML 和 WatchConnectivity。

Lock 文件只明确出现了 `screen_brightness_ohos`；这不足以让应用启动和完成认证。

### 3.7 推送必须改服务端

`lib/repository/forum/forum_repository.dart:1109-1145,1192-1204` 只支持：

```text
APNS -> apns
MIPUSH -> mipush
```

HarmonyOS Push Kit 需要新增 provider 类型、Token 注册/删除、服务端派发、通知 payload、点击落地参数和回执监控。它不是单纯客户端替换。

### 3.8 迁移前必须修复的安全问题

这些问题不应被复制到 HarmonyOS 版本：

1. Cookie Domain/Path/Secure/过期判断不符合标准：`lib/repository/cookie/independent_cookie_jar.dart:58-99,158-164`。
2. `PersonInfo.toString()` 输出明文密码：`lib/model/person.dart:45-64`。
3. 本地加密使用固定 IV，且 IV 等于 AES Key，没有认证标签：`lib/util/shared_preferences.dart:166-192`。
4. 随机数失败时退化为普通 `Random()`：`lib/util/shared_preferences.dart:47-53`。
5. 远程 Banner 可把 Forum Access Token 放入任意 URL：`lib/widget/forum/auto_banner.dart:55-107`。
6. 诊断日志导出完整本地存储、请求头、响应头和正文，未统一脱敏：`lib/page/settings/diagnostic_console.dart:90-139,178-207,213-304`。
7. Android 当前全局允许明文流量并关闭 WebView Safe Browsing：`android/app/src/main/AndroidManifest.xml:28-35,70-76`。

## 4. 技术路线比较

| 方案 | 优点 | 主要问题 | 建议 |
|---|---|---|---|
| A. Flutter OHOS 直接迁移 | 理论上 UI/Dart 复用最多 | Flutter 3.47 与公开 OHOS 3.27.4 分支存在版本缺口；插件缺失；WebView/Push/安全存储仍需原生；长期维护引擎 fork | 仅做 2 周 Spike，不作为默认生产主线 |
| B. ArkTS/ArkUI 原生重写 | 平台能力完整；长期维护和上架风险最低；能充分适配折叠屏/平板/卡片 | UI 和 Dart 业务实现需要重写；初期成本较高 | **推荐主线** |
| C. 原生壳 + Flutter 混合 | 可分步替换页面 | 同时承担两套 UI/生命周期/状态/路由；认证 Cookie 桥接更复杂；包体和调试成本高 | 除非已有稳定的 Harmony Flutter 基座，否则不推荐 |

### Flutter Spike 的退出条件

只有以下条件全部满足，才允许重新评估 Flutter 作为主线：

- 能在维护中的 OHOS Flutter SDK 上无大规模降级地解析当前依赖。
- P0 插件均有可维护实现：安全存储、Preferences、目录、ArkWeb/Cookie。
- 2FA 完成后可稳定同步 HttpOnly Cookie 到 Dart HTTP 客户端。
- Forum 复杂长列表、Markdown/LaTeX、图片和输入法性能通过真机测试。
- Push、深链、分享、文件和通知具备明确维护方。
- CI 可重复构建签名 HAP，且 SDK/插件版本能锁定。

基于当前证据，预计该 Spike 更可能得出“不适合作为生产主线”的结论；它的价值是用实测而不是印象关闭路线争议。

## 5. 推荐目标架构

### 5.1 工程结构

采用 Stage 模型、单个 Entry HAP、多个 HAR。DanXi 手机端是单窗口应用，没有首版按需加载诉求，不需要为了“模块化”引入大量 HSP。

```text
entry/                         # Entry HAP
  EntryAbility
  App lifecycle
  Navigation / typed destinations
  Push and App Linking entry

core_domain/                   # HAR
  models / value objects
  use-case contracts
  typed errors

core_data/                     # HAR
  HTTP session
  cookie store
  API clients
  HTML/JSON/TOML parsers
  cache

core_security/                 # HAR
  Asset Store credential vault
  HUKS bulk-data crypto
  token/session policy
  log redaction

core_platform/                 # HAR
  ArkWeb auth adapter
  Push / Notification
  Share / File / Calendar
  Preferences
  device-scoped installation ID

design_system/                 # HAR
  theme / typography / reusable ArkUI components

feature_auth/                  # HAR
feature_dashboard/             # HAR
feature_timetable/             # HAR
feature_exam/                  # HAR
feature_forum/                 # HAR
feature_danke/                 # HAR
feature_settings/              # HAR
```

依赖方向：

```text
Entry -> Feature -> UseCase/Domain contracts
Feature data adapter -> Core Data / Core Platform
Core Data -> Domain
Core Platform -> Domain capability contracts
```

禁止：

- Domain/DTO 引用 ArkUI 组件、颜色、Context 或 Store。
- Repository 直接触发弹窗、路由或全局事件。
- Feature 直接读取其他 Feature 的 Store。
- 页面直接拼接 URL、Header、Cookie 或持久化 Key。

### 5.2 认证边界

把当前 `FudanSession` 拆成明确协作对象：

```text
CredentialVault (Asset Store)
FudanAuthSession
AuthStrategy (Neo / Neo2FA / UISNeo / UISLegacy)
SecondFactorHandler
SessionCookieStore
AuthenticatedHttpClient
WebVpnRoutePolicy
```

`FudanAuthSession` 只通过 `SecondFactorHandler` 请求 UI 完成 2FA，不依赖页面、EventBus 或全局变量。Web/HTTP Cookie 转换必须拥有独立 RFC 行为测试，并按目标 API 明确区分“结构化同步”和“白名单 host-scoped 兼容模式”。

### 5.3 导航与大屏

- 使用官方推荐的 `Navigation + NavDestination + NavPathStack`。
- 手机使用单栏，宽屏使用 `NavigationMode.Auto/Split`。
- 现有 Flutter 在 `840dp` 切换主从视图；HarmonyOS 官方建议的宽度断点为 `sm [320,600)`、`md [600,840)`、`lg [840,1440)`，可将 600vp 作为 Navigation 单/双栏起点，再按 Forum、课表等页面实测调整。
- Dashboard、Forum 列表/详情、Danke 列表/详情应优先做主从布局，避免只复刻手机底栏。
- 将现有 28 条路由整理为 typed destination 清单，并建立冷启动、热启动和推送/链接拉起的统一路由恢复逻辑。

### 5.4 状态管理

- 每个 Feature 一个 Store/ViewModel，页面状态、请求状态和持久化状态分离。
- 统一使用目标 SDK 支持的 ArkUI 状态观测机制，不混用全局单例、事件总线和页面引用。
- 请求状态统一为 `Idle / Loading / Content / Empty / Error / Refreshing`。
- 跨 Feature 只共享稳定会话：`CampusSession`、`CommunitySession`、`AppSettings`。

## 6. HarmonyOS 能力映射

| 当前能力 | HarmonyOS 目标 | 优先级 | 说明 |
|---|---|---:|---|
| Flutter App 壳 | Stage 模型 `UIAbility` | P0 | 处理生命周期、冷/热启动 Want |
| Flutter 字符串路由 | `Navigation`、`NavDestination`、`NavPathStack` | P0 | 使用类型化目的页面和参数 |
| Dio + 拦截器 | Remote Communication Kit session/fetch，或经验证的 Network Kit 封装 | P0 | 需要重定向、拦截器、超时、上传、代理策略 |
| 自定义 CookieJar | 独立 `SessionCookieStore` | P0 | 严格实现 Domain/Path/Secure/Expires/SameSite |
| InAppWebView | ArkWeb `Web` + `WebviewController` | P0 | 2FA、JS、导航回调、下载、Cookie |
| Web/HTTP Cookie 桥 | `WebCookieManager.configCookie* / fetchCookie*` | P0 | API 23 以下不能无损导出完整属性；需白名单兼容方案 |
| FlutterSecureStorage | Asset Store Kit | P0 | 存账号、密码、Token 等不超过 1KB 的短敏感数据 |
| 大块敏感本地数据 | HUKS + AEAD + Preferences/文件 | P0 | 自行负责密文版本、随机 nonce、轮换和损坏恢复 |
| SharedPreferences | ArkData Preferences | P0 | 仅存设置或密文；Preferences 自身不加密 |
| MiPush/APNs | Push Kit + 服务端 provider | P0 | 获取 Token、上报、派发、回执、通知授权 |
| `danxi://` 自定义 Scheme | Deep Linking + `skills` + UIAbility Want | P1 | `onCreate/onNewWant` 解析并转 typed route |
| HTTPS 应用链接 | App Linking + UIAbility Want | P1 | 需要域名校验，优先用于外部分享链接 |
| ICS 分享/打开 | Core File Kit + Share Kit | P1 | 使用系统 URI，禁止自行拼 file URI |
| 课表/考试日历 | Calendar Kit | P1 | 可直接写入课程日程；需读写日历权限 |
| 图片选择/保存 | Photo Picker / PhotoAccessHelper | P1 | 使用系统选择器，最小权限 |
| 设备 ID | 应用级安装 ID + Preferences/HUKS | P1 | 不使用不可控硬件标识；卸载重置可接受 |
| 屏幕亮度 | Window/显示能力适配 | P1 | 二维码页进入/退出必须恢复亮度 |
| 截屏/录屏 | 窗口隐私和截屏事件能力 | P1 | 不支持时明确降级，不能启动即抛错 |
| APK 升级数据继承 | Core File Kit `BackupExtensionAbility` | P1 | 仅适用于官方支持的系统升级场景，需验证旧密钥可用性 |
| 快捷方式 | 桌面快捷方式；后续可加 Form Kit | P2 | 首版不阻塞 |
| iOS CoreML 标签推荐 | 服务端预测或 HarmonyOS AI 能力 | P2 | 首版可关闭，避免阻塞编辑器 |
| Apple Watch | 独立 Wearable HAP | P2 | 使用短期可撤销 wearable token |

## 7. 分阶段实施计划

### 阶段 0：范围冻结与行为基线（2-3 周，4-6 人周）

产物：

- 形成 28 条路由、主要页面、API endpoint 和设置 Key 清单。
- 为认证重定向、Cookie、WebVPN、课表、考试、校园卡 HTML/JSON 解析建立脱敏 fixture。
- 建立 Android/iOS 行为录屏和关键页面截图基线。
- 定义 MVP 与完整对齐范围；首版不包含 Wearable、CoreML 标签推荐和低频管理员增强功能。
- 修复前述高危安全问题，至少阻止 Token URL 泄漏和诊断日志泄漏。
- 在 AppGallery Connect 创建项目并开通 Push Kit，准备含推送能力的调试 Profile；Community MVP 前完成通知自分类权益申请。

退出条件：核心 API 响应均有可离线运行的契约测试样例。

### 阶段 1：平台 P0 Spike（2 周，4-6 人周）

只实现无业务 UI 的最小工程：

- Entry HAP、签名、真机安装和 CI。
- RCP/HTTP 重定向、Cookie 读写、表单提交、HTML 解析。
- ArkWeb 打开复旦登录、完成 2FA，并按目标 API 验证结构化或白名单 host-scoped Cookie 导入 HTTP 会话。
- 分别验证 MVP 当前使用的 Neo、Neo2FA、UISLegacy，以及验证码、用户取消、并发等待和失败重试；`UISNeo` 仅在确认有业务调用后升级为 P0。
- Asset Store 保存短凭据；HUKS + AEAD 保护较大敏感数据；Preferences 只保存设置或密文。
- 使用含 Push Kit 权益的签名 Profile 获取 Token，并由测试服务端向设备发送一条可点击通知。
- HTTP 内网站点和 WebVPN 连通性。

退出条件：同一真机上能分别通过 MVP 实际使用的认证模式调用代表接口；Neo2FA 能完成 Web/HTTP Cookie 桥接；杀进程后能按策略恢复或安全重新认证。若最低 API 小于 23，还必须证明白名单 host-scoped Cookie 方案覆盖现网认证响应。

### 阶段 2：应用骨架与基础设施（3-4 周，6-8 人周）

- 单 Entry HAP + HAR 模块结构。
- 设计系统、国际化、深浅色、字体缩放、错误页。
- Navigation、类型化路由、手机/平板分栏。
- `CredentialVault`、`SessionCookieStore`、日志脱敏、缓存版本化和密文版本/轮换策略。
- 设置、登录、退出、清除数据、诊断最小版。
- CI：静态检查、单元测试、HAP 构建、签名隔离、产物留存。

### 阶段 3：Campus MVP（5-7 周，18-26 人周，可并行）

按纵向切片逐个交付：

1. 欢迎卡、校园卡余额、食堂/图书馆人数。
2. 校车、教务通知、宿舍电量、体育锻炼。
3. 空教室、付款/身份二维码、亮度恢复。
4. 课表、手工课程、下一节课。
5. 考试、成绩、GPA、ICS/Calendar Kit。

每个切片必须同时包含 API、Store、UI、缓存、错误态、单测和真机验收，禁止先把所有 Repository 写完再集中开发 UI。

### 阶段 4：Community MVP（4-6 周，14-20 人周）

- `CommunitySession` 和 JWT 刷新。
- Forum 登录、分区、列表、详情、分页、搜索。
- Markdown、链接、图片、基础 LaTeX/代码展示。
- Danke 课程搜索、详情、评价浏览。
- Push Kit 通知和详情页深链。

MVP 可在此阶段开放测试。

### 阶段 5：完整功能对齐（6-9 周，20-28 人周）

- Forum 发帖/回复/编辑、图片上传、贴纸、草稿持久化。
- 收藏、订阅、消息、历史、举报和管理功能。
- AI 总结、跳转楼层、反馈。
- Danke 评价增删改和投票。
- Dashboard 排序、背景、自定义 URL 和完整设置。
- 分享、图库、文件、截图检测、快捷方式等 P1/P2 能力。

### 阶段 6：稳定性与上架（3-4 周，8-12 人周）

- 性能：启动、长列表、内存、图片缓存、ArkWeb。
- 安全：凭据、Cookie、网络白名单、日志脱敏、Web 页面白名单、证书错误策略。
- 隐私和权限审查；Push Kit 分类权益与通知频控。
- 手机、折叠屏、平板，多窗口、横竖屏、深浅色、字体放大。
- 灰度、崩溃/网络错误监控、回滚和版本升级策略。

## 8. 数据迁移策略

Android 与 HarmonyOS 应用沙箱不同，不应假设能直接读取旧 SharedPreferences。需要区分两种场景：

1. **原 HarmonyOS 设备从可运行 APK 的系统升级到 HarmonyOS NEXT：**优先评估官方数据迁移框架和 `BackupExtensionAbility`，由新应用在恢复进程中转换旧 APK 沙箱数据。
2. **普通 Android 设备到新 HarmonyOS 设备，或官方映射条件不满足：**使用旧 App 主动导出、用户确认后导入的产品方案。

即使使用 `BackupExtensionAbility`，当前加密 Preferences 的主密钥由 FlutterSecureStorage/旧平台安全能力保护，且现有 Android 备份规则排除了 FlutterSecureStorage 数据。旧密钥在 HarmonyOS 恢复进程中是否可用必须实测，不能假设可解密；无法解密时仍需重新登录或提前由旧版 App 生成版本化迁移包。

| 数据 | 策略 |
|---|---|
| 复旦账号密码 | 默认不迁移，首次启动重新登录 |
| Fudan Session Cookie | 不迁移，重新认证 |
| Forum access/refresh token | 默认不迁移；由用户重新登录 |
| 课表缓存 | 可从服务端重建；无需迁移 |
| 手工课程 | 必须提供用户确认的一次性 JSON 导出/导入 |
| Dashboard 布局、校区、语言、主题 | 可迁移，使用稳定字符串，不使用 Dart enum index/toString |
| 搜索/浏览历史、隐藏内容 | 用户可选迁移，单独说明隐私范围 |
| 背景图片 | 重新选择或通过导入包复制 |
| 图片、贴纸缓存 | 不迁移，重新下载 |
| Forum/Danke 服务端数据 | 登录后从服务端恢复 |

如果产品要求“无感迁移”，应先验证 APK 与 HarmonyOS 应用的映射、`BackupExtensionAbility` 和旧密钥可用性；不满足官方迁移条件时，必须改旧 Android App：用户主动确认后，将允许迁移的数据解密、按版本化 schema 导出，并通过一次性加密通道导入 HarmonyOS。不能由新应用绕过沙箱直接读取旧应用数据。

## 9. 测试与验收

### 9.1 测试金字塔

- 领域单测：课表周次、下一节课、校车、拥挤度、GPA、ICS、WebVPN 编码。
- 契约测试：每个 API/HTML parser 使用脱敏 fixture，Dart 与 ArkTS 对同一 fixture 产出一致语义。
- 认证集成测试：重定向、Cookie Domain/Path、Secure、过期、2FA 取消/重试、并发请求合并。
- Store 测试：Loading/Empty/Error/Refresh/分页/鉴权失效。
- ArkUI 测试：导航、回退、分栏、深色、字体缩放。
- 真机 E2E：登录、课表、考试、二维码、Forum 浏览/发布、Push 点击。

### 9.2 发布门槛

- 不在日志、URL、剪贴板或诊断包中出现密码、JWT、Cookie、CAS ticket、成绩和个人信息。
- 所有明文 HTTP 仅允许明确的内网域名，并有最小范围网络配置。
- ArkWeb 只允许业务白名单页面执行敏感交互；Release 关闭网页调试；SSL 错误默认取消。
- P0 流程在真实手机完成；Push Kit 不以云真机结果作为验收依据。
- 关键行为与 Flutter 基线一致，差异必须有产品确认。
- 崩溃率、ANR/appfreeze、启动时间、列表滚动和内存达到发布门槛。

## 10. 人力与排期

### 建议团队

- 1 名 HarmonyOS 技术负责人：架构、认证、安全、平台能力。
- 2 名 ArkTS/ArkUI 工程师：Campus 与 Community 并行。
- 1 名全栈/后端工程师：Push、设备注册、远程配置、安全改造。
- 0.5-1 名 QA：fixture、真机矩阵、回归和上架。
- 原 Flutter 维护者需要持续参与行为确认和接口变更评审。

### 工作量

| 工作包 | 人周 |
|---|---:|
| 基线、fixture、安全前置 | 4-6 |
| P0 Spike | 4-6 |
| 工程骨架与基础设施 | 6-8 |
| Campus MVP | 18-26 |
| Community MVP | 14-20 |
| 完整功能对齐 | 20-28 |
| 稳定性与上架 | 8-12 |
| 小计 | 74-106 |
| 约 20% 风险缓冲 | 15-21 |
| 总计 | **89-127** |

最大不确定性来自复旦认证页面变化、HTML 抓取接口、ArkWeb Cookie 行为、Push 服务端接入和 Forum 富文本/长列表性能。

## 11. 决策门槛与风险控制

### Go/No-Go 1：第 2 周

- Go：MVP 实际使用的认证链路通过；ArkWeb 2FA + HTTP Cookie 方案覆盖目标 API；Asset Store/HUKS 和 Push Token 成功。
- No-Go：任一 P0 无可维护实现。停止页面开发，优先解决基础能力或调整认证方案。

### Go/No-Go 2：MVP 中点

- Go：Campus 主要接口成功率、缓存、重新认证达到要求。
- No-Go：学校接口变化导致 fixture 与实网长期失配。先增加后端适配层/代理服务，而不是在客户端继续堆解析补丁。

### Go/No-Go 3：Community MVP

- Go：Forum 千楼分页、富文本、图片和输入法性能通过真机基线。
- No-Go：ArkUI 原生渲染成本过高时，可仅对富文本正文评估受控 Web 渲染，但登录和 Token 不得暴露给不可信页面。

## 12. 建议立即执行的 10 项工作

1. 明确目标为 HarmonyOS NEXT 原生应用，确定最低系统/API 版本和上架渠道；Cookie 方案必须随最低 API 一起决策。
2. 建立 `migration/fixtures`，收集并脱敏认证和各校园服务响应。
3. 为 Cookie、WebVPN、课表和 API DTO 补当前 Dart 契约测试。
4. 修复 Cookie 判断、Token URL、密码 `toString()` 和诊断日志泄漏。
5. 创建最小 Stage/ArkTS 工程，打通签名和 CI。
6. 完成 ArkWeb 2FA/Cookie Spike，这是第一优先级。
7. 完成 Asset Store 短凭据与 HUKS + AEAD 大块数据保护 Spike。
8. 开通 Push Kit、准备签名 Profile、申请通知自分类权益；后端增加 `harmony_push` provider 和测试派发链路。
9. 固化 typed routes、API 契约、错误码和迁移 schema。
10. 以“登录 -> 校园卡余额 -> Dashboard 卡片”作为第一条端到端 tracer bullet。

## 13. 官方参考

- [Stage 模型开发概述](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/stage-model-development-overview)
- [Navigation 基础架构](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-navigation-architecture)
- [Navigation 分栏开发](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-navigation-split-mode)
- [响应式布局](https://developer.huawei.com/consumer/cn/doc/best-practices/bpta-multi-device-responsive-layout)
- [管理 ArkWeb Cookie 及数据存储](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/web-cookie-and-data-storage-mgmt)
- [网络 Cookie 同步到 ArkWeb](https://developer.huawei.com/consumer/cn/doc/harmonyos-faqs/faqs-arkweb-24)
- [WebCookieManager API](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-webview-webcookiemanager)
- [ArkWeb 组件安全开发](https://developer.huawei.com/consumer/cn/doc/best-practices/bpta-arkweb-component-security)
- [Remote Communication Kit 发送网络请求](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/remote-communication-netsend-arkts)
- [Preferences 数据持久化](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/data-persistence-by-preferences)
- [HUKS 本地密钥管理](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/huks-local-key-management)
- [Asset Store Kit 简介](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/asset-store-kit-overview)
- [Push Kit 简介](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/push-kit-introduction)
- [Calendar Kit 日历服务实践](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/calendarmanager-practice-developer)
- [Core File Kit 应用文件分享](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/share-app-file)
- [APK 到 HarmonyOS NEXT 应用数据迁移](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/app-data-migration-overview)
- [BackupExtensionAbility 数据迁移适配](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/app-data-migration-adaptation)
- [Deep Linking 应用间跳转](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/deep-linking-startup)
- [HarmonyOS 模块化设计](https://developer.huawei.com/consumer/cn/doc/best-practices/bpta-modular-design)
