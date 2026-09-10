# 可寻 / Kexun

快速收藏，需要时找回。SwiftUI 原生的本地收藏实验项目，尚非发布版本。

## 项目状态

2026-09-10：暂停功能开发。现有实现以 [MIT 许可证](LICENSE) 开源，供试用与技术参考，不承诺后续功能、发布日期或问题响应时效。开源不代表 App Store 发布或完整产品验收。

图标为本项目使用 AI 生成的开发期素材；系统图标使用 Apple SF Symbols。MIT 许可证不授予 Apple 或其他第三方的商标及素材权利。测试中的外部网址用于兼容性检查，不表示与对应网站存在关联。

## 如何使用

1. 点击资料库右下角“收藏”，选择链接、文字、照片或文件。链接与文字须手动保存；照片和文件选取后即导入，结果页显示成功及未保存项。
2. 在其他 App 的系统分享菜单选择“可寻”；如果来源只支持复制链接，回到可寻点击系统粘贴按钮，核对标题、来源与收藏夹再保存。
3. 用顶部搜索找资料，点击标题切换收藏夹；类型、来源、时间等条件在筛选面板，列表／卡片及批量操作在更多菜单。
4. 打开收藏查看正文、附件、识别文字或原链接。网页纯文本副本需要主动保存，不保证所有网站可用。
5. 换机或卸载前，进入设置 → 数据与备份，导出完整备份到应用以外。Markdown／原始附件导出方便阅读，但不能作为应用恢复包。

## 运行条件与已知限制

- 当前工程最低系统版本为 iOS 26.5，需要支持该 SDK 的 Xcode。构建方式见下文；目前没有正式安装包或 App Store 发布承诺。
- 资料保存在本机，无账号、云同步或自动云备份。不要把未经真机完整验收的实验版本作为重要资料的唯一副本。
- 链接补全和主动保存网页正文会联网；OCR／PDF 文本提取在设备上进行。无法保证小红书等平台的完整正文、封面或失效链接可恢复，不抓取登录内容或绕过限制。
- 界面目前仅提供简体中文。本文英文说明不代表应用已支持英文界面。
- 代码仍保留免费100条及 StoreKit Pro 解锁流程；本次暂停没有移除额度或改造为无限量版本。真实沙盒购买未完成验收，不应把它当作可用购买服务。
- 已有本地及模拟器定向验证、真机安装记录；不等于全部设备、来源平台、辅助功能、购买或生产环境验收通过。

使用截图将在后续整理，只采用隔离示例资料的真实应用截图，不使用个人收藏或把预览图当成已验证功能。当前 README 暂不放占位图。

正常启动使用真实 SQLite/App Group 数据库，示例数据仅用于显式预览。当前已接入四类收集、本地搜索与管理、图片 OCR/PDF 文本提取、链接信息补全、备份恢复和分享扩展；StoreKit 2 购买服务已接入，但真实沙盒及端到端验收尚未完成。V1 不做 iCloud 或自建账号。

当前为内容优先的单页资料库：默认紧凑列表，标题切换收藏夹，右上角进入设置和更多操作；类型、来源、时间与归档状态按需筛选，搜索保持当前范围，列表/卡片选择会保留。新增文字正文编辑与未保存保护、详情搜索命中及文本型 PDF 定位、会话内失败项重试、单层收藏夹、公开网页纯文本副本、完整备份状态、免费 Markdown/原始附件整库或选中导出、大附件查看。收藏夹名称随记录保存，空组不保留；移除组只清分类，不删除收藏。网页正文需主动保存，不保留网页图片/版式，不登录、不执行脚本、不绕过付费墙；失败保留原链接及旧正文副本。通用导出不用于备份恢复。

在 Xcode 打开 `Kexun.xcodeproj`，选择 Kexun scheme 和 iPhone 模拟器运行。使用 `--search-preview` 或 `--detail-preview` 启动参数可直达截图预览状态。

右下角“收藏”分为链接、文字、照片与文件四个入口：链接/文字编辑后保存，附件选完即导入，独立结果页用“完成 / 查看已保存资料”收尾。未保存队列须重试或明确放弃，不能被下一批覆盖。详情草稿按字段合并后台更新，真正冲突保留输入；备份处理中锁定导航，大附件列表跟随所属收藏更新。

复制链接后回到资料库可使用轻提示中的系统粘贴按钮，确认预览标题、来源和收藏夹后保存。应用只自动检测可能的链接模式，不自动读取剪贴板值、不自动收藏或提前访问链接；检测漏报时可从保存链接表单直接粘贴。分享原文、URL参数与片段完整保留，小红书来源仅通过域名白名单显示，不补猜截断正文。

模拟器也需要携带 App Group entitlement。本地命令行构建可使用：

```sh
xcodebuild -project Kexun.xcodeproj -scheme Kexun -sdk iphonesimulator -configuration Debug -derivedDataPath /private/tmp/KexunUIPreview CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual build
```

真机需在自己的 Apple Team 配置 `group.com.wangxp.Kexun`，主 App 与扩展共享该组。商品标识为 `com.wangxp.Kexun.pro.lifetime`，需要真实 App Store Connect 配置后验证。不要将本地签名或模拟商品测试等同于真实上架可用。

数据测试位于 `Tests/`，测试使用独立临时目录，不应指向用户数据。数据库打不开时不会自动清库。升级从旧 Application Support 数据库迁入共享容器，旧文件暂保留用于恢复。

Debug 参数 `--library-scale-fixture` 用于资料库交互与滚动验收：每次启动在独立临时库生成1,000条混合资料、250份图片和250份文件，复用真实资料库界面，不把这些记录写入正常App Group库，也不授予Pro。图片按640×480点和设备缩放比例生成；测量时需记录实际像素尺寸。Release不包含此入口。

Debug 参数 `--network-failure-fixture` 使用独立临时库及 URLProtocol 受控传输，针对 `https://example.com/KexunNetworkFixture` 依次提供503、不响应、200。第二次请求由正式12秒请求计时器超时；其余两次通过底部测试按钮释放响应。正式URL校验、HTTP检查、HTML解析与存储逻辑保持执行；这不是公网断网测试，正常App Group库和购买权益不被fixture修改。Release不包含该入口。

与该入口同时传入 `--reject-open-url`，会在Debug场景中通过SwiftUI的OpenURLAction拒绝打开，用于验证失败提示、草稿保留和复制链接；它不表示Safari或系统浏览器实际故障，也不会修改正式打开行为。

Debug参数 `--import-stop-fixture` 使用空的独立临时库，只在批次第二项复制前加入可取消的30秒等待，用于操作真实“停止剩余导入”按钮。系统选取、文件复制、写入、取消报告和后续单项重试仍走实际流程；这不是慢速文件提供者或复制中断的测量。入口及等待钩子不进入Release。源文件可用 `Tests/PrepareSystemFileBatch.swift` 在专用模拟器的本地Files provider中准备，不能指向个人设备。

主应用与分享扩展分别维护 `Localizable.xcstrings`，源语言为简体中文，目前未提供英文翻译。新增文案使用 SwiftUI 本地化字面量或 `String(localized:)`；用户内容、持久化字段和协议标识不作为翻译键。更新目录时先按上述命令构建 Release（将 Debug 改为 Release），再运行 `bash Tests/sync-localizations.sh /private/tmp/KexunUIPreview`，最后重新构建以打包资源。同步脚本需要 Node.js，仅使用 Release 编译器提取结果，排除 Debug 测试入口文案。

Debug参数 `--extraction-search-fixture` 在独立临时库实际导入自建PNG，在处理状态落盘后、调用Vision前等待底部按钮放行（最多120秒）。用于验证处理中按标题搜索、打开详情及随后真实中英文OCR/搜索，不预填识别结果，不测CPU繁忙时的性能；入口和可选钩子不进入Release，不改正常App Group数据或Pro权益。

同时传入 `--extraction-delayed-release` 时，按钮改为45秒后放行真实 Vision，用于在等待期间打开详情、输入备注并验证后台完成后草稿安全合并。默认按钮行为不变。

## English

Save things quickly and find them later. An experimental, local-first SwiftUI collection app, not a release-ready build.

### Project status

Feature development is paused as of September 10, 2026. The implementation is open source under the [MIT License](LICENSE) for experimentation and technical reference, without commitments to future features, releases, or support response times. Open-source availability does not imply an App Store release or complete product acceptance.

The development app icon was AI-generated for this project; system icons use Apple SF Symbols. The MIT License does not grant rights to Apple or other third-party trademarks or assets. External URLs in tests are compatibility examples, not endorsements or affiliations.

### Usage

1. Choose Add at the bottom right of the Library, then select a link, text, photos, or files. Links and text require explicit saving; selected attachments import immediately and report saved and pending items.
2. Select Kexun in another app's system share sheet. If the source only offers Copy Link, return to Kexun, use the system Paste button, and review the title, source, and folder before saving.
3. Search at the top and select folders from the title menu. Additional filters are in the filter sheet; list/grid switching and batch actions are in More.
4. Open a record to view its text, attachments, recognized text, or original link. Public-page text copies require an explicit action and are not available for every website.
5. Before switching devices or uninstalling, export a full backup through Settings → Data and Backup to a location outside the app. Markdown/original-attachment exports are readable archives, not restorable app backups.

### Requirements and limitations

- The project currently targets iOS 26.5 or later and requires Xcode with the corresponding SDK. Build instructions follow below; no production installer or App Store release is promised.
- Data stays on the device, without accounts, cloud synchronization, or automatic cloud backup. Do not use an experimental build as the only copy of important material.
- Link enrichment and explicitly saved web text make network requests. OCR/PDF extraction is on-device. Complete content, covers, and recovery of dead links are not guaranteed for Xiaohongshu or other platforms; login requirements and access restrictions are not bypassed.
- The app interface is Simplified Chinese only. English documentation does not imply an English interface.
- The code retains the 100-record free limit and StoreKit Pro flow. Pausing development has not removed these limits or converted the app into an unlimited edition. Real sandbox purchases remain unverified; do not treat this as an operational purchase service.
- Targeted local/simulator checks and physical-device installation do not establish complete device, source-platform, accessibility, purchase, or production acceptance.

Usage screenshots will be prepared later using real app screens and isolated sample data, not personal collections or previews presented as validated features. No placeholder images are included.

With the extraction fixture, `--extraction-delayed-release` makes its button schedule real Vision extraction 45 seconds later, allowing a detail note to be entered before the background update. It verifies draft merging, not device-load performance, and is excluded from Release.

Normal launches use a persistent SQLite database in an App Group. Sample content is isolated to explicit preview launch arguments. Capture, local search, organization, image OCR/PDF text extraction, link metadata, backups, and a share extension are connected. StoreKit 2 is integrated but sandbox purchases and end-to-end acceptance remain unverified. V1 has no iCloud synchronization or custom account system.

The content-first Library is a single workspace: a persistent list/grid preference, folders in the title menu, Settings and More at the top, and on-demand filters for type, source, time, and archive status. Search preserves the current scope. New capabilities include text-body editing with unsaved-change protection, detail search matches and text-PDF positioning, in-session failed-item retries, single-level folders, manually saved public-page text copies, full-backup status, free whole-library or selected Markdown/original-attachment exports, and large-attachment browsing. Folder names are stored on records; empty folders are not retained and removing a folder never deletes its records. Web copies contain plain text, not images or page layout, and never log in, execute scripts, or bypass paywalls. Failed refreshes preserve the original link and previously saved text. Readable exports are not restorable backups.

Open `Kexun.xcodeproj`, select the Kexun scheme, and run on an iPhone simulator. Launch arguments `--search-preview` and `--detail-preview` open presentation states for screenshots.

The bottom-right Add action has separate link, text, photo, and file entries. Links/text require saving; attachments import immediately and finish on a dedicated Done / View Saved screen. Pending items must be retried or explicitly discarded before another batch. Detail drafts merge nonconflicting background updates while preserving genuine conflicts. Backup operations lock navigation, and attachment owners refresh after edits.

After copying a link, a dismissible hint may offer the system Paste button. Review the title, source, and folder before saving. The app only detects a probable URL pattern automatically; it does not read clipboard values, save content, or fetch the link before explicit user actions. The link form also provides system paste when detection misses. Original share text and URL parameters/fragments are retained; Xiaohongshu is recognized only through an exact domain/subdomain allowlist, without guessing truncated content.

The build command above uses local simulator signing to include App Group entitlements. Real devices require configuring `group.com.wangxp.Kexun` for both targets in your Apple Team. The non-consumable product ID is `com.wangxp.Kexun.pro.lifetime`; configure and verify it in App Store Connect before release. Tests in `Tests/` use isolated temporary data. Failed database initialization never resets user data; legacy migration retains the original files for recovery.

The Debug-only `--library-scale-fixture` argument creates a separate temporary library with 1,000 mixed records, 250 images, and 250 files for interaction and scrolling checks. It uses the real library interface without seeding the normal App Group collection store or granting Pro. Images are rendered at 640×480 points using the device scale; record their actual pixel dimensions when measuring. This entry point is excluded from Release.

The Debug-only `--network-failure-fixture` uses a separate temporary store and a controlled URLProtocol transport for `https://example.com/KexunNetworkFixture`: HTTP 503, no response, then HTTP 200. The second request times out using the production 12-second request timer; a fixture button releases the other responses. The normal URL validator, HTTP checks, HTML parser and persistence pipeline still execute. This is not a live internet outage test, does not seed the normal App Group collection store or grant Pro, and is excluded from Release.

Adding `--reject-open-url` to that entry point makes SwiftUI's OpenURLAction refuse opening in the Debug fixture, for checking the error message, draft preservation and URL copying. It does not simulate a verified Safari/system-browser outage or alter the production opening behavior.

The Debug-only `--import-stop-fixture` uses an empty separate temporary store and a cancellable 30-second pause before copying the second item. System selection, file copying, persistence, cancellation reporting and a later single-item retry use the real pipeline. It tests the Stop action, not a slow file provider or an interrupted copy. Both the entry point and pause hook are excluded from Release. `Tests/PrepareSystemFileBatch.swift` prepares sources in a dedicated simulator's local Files provider; do not target a personal device.

The app and share extension each maintain a `Localizable.xcstrings` catalog with Simplified Chinese as the source language; English translations are not included yet. Use SwiftUI localized literals or `String(localized:)` for new interface copy, not for user content, persisted fields, or protocol identifiers. To refresh catalogs, build Release with the command above (replace Debug with Release), run `bash Tests/sync-localizations.sh /private/tmp/KexunUIPreview`, then rebuild to package the resources. The sync script requires Node.js and uses Release compiler extraction to exclude Debug fixture copy.

The Debug-only `--extraction-search-fixture` imports a generated PNG into separate temporary storage. After processing state is persisted, it waits for a fixture button before invoking real Vision extraction (120-second maximum). It verifies title search and detail access during processing, followed by actual Chinese/English OCR and search. No OCR results are seeded; it is not a CPU-load performance measurement. The entry point and optional hook are excluded from Release and do not change normal App Group data or Pro entitlements.
