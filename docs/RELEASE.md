# Release 打包与分发

GitHub Release：Mac 提供 Developer ID 签名、Apple 公证的通用 DMG；iPhone 提供需使用者自行签名的 IPA。TestFlight 使用独立的 App Store 分发签名与测试组配置。

## 用户安装

- **Mac**：打开 DMG，把 Remote Microphone 拖到 Applications。首次打开遵循 macOS 提示；另行安装 BlackHole 2ch，并配置 Tailscale。
- **iPhone**：下载文件名含 `unsigned` 的 IPA，使用自己的 Apple 开发签名和设备描述文件重新签名安装，或按 README 用 Xcode 从源码安装。该 IPA 不能直接点击安装，不是 App Store / TestFlight 安装包，也不包含开发者的设备授权。
- 自行签名的工具兼容性、签名有效期和后台能力取决于所用账号与工具；仓库不附带证书、私钥或设备描述文件。
- 正式 Mac 包使用独立 Bundle ID 和存储命名空间。与早期自用开发版并存时，需要重新配对；同一时刻只运行一个接收服务。

## 首次打包前的失败清单

任何一项失败都不应公开为正式版：

1. 源码有未提交修改、打包来源无法对应 commit，或恢复目录的配置与本次不同。
2. 使用开发签名 / 临时签名冒充 Developer ID；证书团队、Bundle ID、版本或 CPU 架构不匹配。
3. Apple 公证尚在处理或被拒绝；把上传成功误当成公证通过；重试时丢失原提交 ID。
4. App 或 DMG 未附加票据，Gatekeeper 拒绝；DMG 内 App 与验证过的 App 不一致。
5. IPA 带入本机 provisioning profile、开发签名、私钥或个人数据；未清楚标注需自行签名。
6. 打包新版本覆盖当前自用版，或两个版本共用配对记录 / 诊断文件。
7. GitHub 下载后哈希不匹配，或覆盖同版本已公开附件。
8. 初次分发未经下载、隔离属性、拖拽安装、启动与原生操作验收就当成正式可用。

## 本机打包

需要完整 Xcode、XcodeGen、已有 Developer ID Application 证书，以及已经配置好的 `notarytool` 凭证 profile。脚本只引用 profile 名称，不读取或导出凭证。签名身份和团队通过参数传入，不写入公开工程。

先提交预期发布的源码，然后运行：

```sh
python3 scripts/prepare-release.py \
  --identity 'Developer ID Application: 你的组织 (TEAMID)' \
  --team TEAMID \
  --mac-bundle-id com.yourcompany.remotemicrophone.mac \
  --phone-bundle-id com.yourcompany.remotemicrophone.phone \
  --keychain-profile YOUR_NOTARY_PROFILE
```

脚本从 `git archive HEAD` 创建干净源码快照，不读取 `project.local.yml`；Mac 使用 Release、arm64 + x86_64、Hardened Runtime、时间戳签名。iPhone 使用 Release / iphoneos / arm64 编译，生成未签名 `Payload/*.app` IPA。

产物位于 `build/releases/<commit 前 12 位>/assets/`：

| 文件 | 用途 |
| --- | --- |
| `RemoteMicrophone-<版本>-macOS-universal.dmg` | Mac 拖拽安装包 |
| `RemoteMicrophone-<版本>-iOS-unsigned.ipa` | iPhone 自行签名输入文件 |
| `release-manifest.json` | 源码 commit、版本、平台及构建验证结果 |
| `SHA256SUMS` | 附件校验和 |

完整构建日志、公证回执和验收记录留在同级本机目录，不作为下载附件。公证处理较慢时，脚本有界等待后退出；使用完全相同的命令恢复，会继续查询已有提交，不重复上传未改变的文件。不要手动改写工作目录中的产物；需要重新构建时使用新的 `--output` 目录。

## GitHub 草稿

```sh
python3 scripts/draft-release.py build/releases/<commit 前 12 位> \
  --repo wherexml/remote-microphone
```

脚本检查本机验收记录与附件 SHA-256，创建草稿后重新下载全部附件逐一核对。相同草稿可重复核验；附件不一致时停止，不自动覆盖。不会将草稿切为公开、latest，也不创建 App Store Connect 记录。

首次正式发布还需完成浏览器下载、隔离属性、拖拽安装、原生启动与配对 / 接收验证，并将证据保存在 `artifacts/`。Apple 公证与编译通过不代表音频或手机签名安装已验收；Intel 包虽包含 x86_64，仍需标明是否做过 Intel 真机验证。

## 0.1.1（5）分发状态（2026-10-26）

Mac 0.1.1 已完成签名、公证、票据、Gatekeeper 与附件哈希核验，已在 GitHub 发布为 [Pre-release](https://github.com/wherexml/remote-microphone/releases/tag/v0.1.1)，尚未提升为 latest。内置浏览器下载的 DMG 带有系统隔离标记且通过 Gatekeeper；本机安装、启动、地址保存和接收服务启动已验收。Finder 拖拽安装与此次正式标识的完整传声尚未完成，因此保留预发布状态。

iOS 0.1.1（5）已上传 TestFlight、完成处理及加密问卷，加入 Internal Testing 和 Public Beta；内部测试者记录显示已安装 0.1.1（5），外部测试已提交并为 Waiting for Review。

两端均使用 `assets/brand/remote-microphone-master.png` 对应图标；本版新增应用内扫码、配对地址展示和无效链接反馈。证据目录：`artifacts/release-0.1.1/`（本机）。

## TestFlight

2026-10-26：iOS 0.1.0（4）已完成上传及加密问卷，内部测试状态为 **Testing**。外部组 **Public Beta** 已加入该构建并提交 Beta App Review，状态为 **Waiting for Review**。

公开链接：[加入 Remote Microphone 测试](https://testflight.apple.com/join/sYSTytKh)。设置为 Open to Anyone；Apple 页面明确提示本组获得已批准构建前，测试者不能通过公开链接加入。已启用新构建可用时自动通知测试者。

iPhone 17 Pro Max / iOS 27.0.1 已通过内部邀请安装并启动该 TestFlight 构建；已完成配对、加密连接、后台音频传输及 BlackHole 独立录音检查，停止后接收断开且输入归零。当前网络为蜂窝 5G + Tailscale 中继；用户暂不便发声，因此真人语音清晰度和听写准确率未验收。

使用固定 iOS Bundle ID 和 Apple 分发团队创建 App Store Connect 记录、归档上传，补齐隐私与测试说明，再安排外部测试。外部测试可能需要 Beta App Review；构建最长可测试 90 天。不能把 GitHub 上的 unsigned IPA 当成 TestFlight 构建。

### 上传检查与恢复

- 必须使用 Apple 当前接受的 Xcode / SDK。2026-10-26 实际上传拒绝了 Xcode 27 beta 4（27A5228h），不能把本地编译成功当成上传可用。通过 `DEVELOPER_DIR` 为单次构建指定正式工具链，无需修改全局 `xcode-select`。
- iPhone 保持竖屏；iPad 的 `UISupportedInterfaceOrientations~ipad` 必须包含四个方向，以满足当前工程的 iPad 多任务声明。修改 `project.yml` 后重新运行 XcodeGen，不能只修补已签名 IPA。
- 先在 App Store Connect 核对 Bundle ID 与 App 记录。Xcode 提示自动创建失败时，重新读取服务端页面，避免重复创建。
- 没有登记设备会阻止普通 Development 归档，但不代表无法进行 App Store 分发。可先用 `CODE_SIGNING_ALLOWED=NO` 归档，再通过 `xcodebuild -exportArchive -allowProvisioningUpdates` 和 `method=app-store-connect`、`signingStyle=automatic`、正确 `teamID` 完成分发签名；签名凭证由 Xcode 管理，不导出私钥。
- `destination=export` 只导出 IPA；`destination=upload` 才上传。上传成功后仍需等待 Apple 处理、回答加密合规问题、将构建加入测试组，并核对 TestFlight 页面状态。
- 内部测试与公开外部测试分开处理。新增外部测试者、公开链接及 Beta App Review 均不因内部构建上传成功而自动完成。
- 将归档、导出、上传日志和服务端最终截图留在 `artifacts/`；安装与音频真机验收另行记录。

官方参考：[Apple 公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)、[TestFlight 概览](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)。
