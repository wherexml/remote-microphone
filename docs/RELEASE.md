# Release 打包与分发

首版使用 GitHub Release：Mac 提供 Developer ID 签名、Apple 公证的通用 DMG；iPhone 提供需使用者自行签名的 IPA。TestFlight 后续单独接入。

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

## 后续 TestFlight

使用固定 iOS Bundle ID 和 Apple 分发团队创建 App Store Connect 记录、归档上传，补齐隐私与测试说明，再安排外部测试。外部测试可能需要 Beta App Review；构建最长可测试 90 天。不能把 GitHub 上的 unsigned IPA 当成 TestFlight 构建。

官方参考：[Apple 公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)、[TestFlight 概览](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)。
