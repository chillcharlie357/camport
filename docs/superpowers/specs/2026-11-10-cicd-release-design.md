# CI/CD 与自动 Release

日期：2026-11-10。用户确认：发布 Android APK、macOS/Windows 压缩包；iOS 先做无签名编译检查。

## 触发与交付

PR 指向 main 时执行格式、分析、Flutter 测试、发布逻辑测试及原生构建检查。PR 阶段不读取项目发布签名、不创建 tag/Release。Android 使用一次性 CI 验证密钥检验真实 release 构建和签名路径，产物标记 `android-validation.apk`，不得作为正式版本发布；macOS/Windows 使用 release 构建，iOS 使用 `--no-codesign`，不把无签名 iOS 产物宣传为可安装 IPA。

发布入口监听 main 的 push，再查询该提交关联的 PR，要求其已经合并、目标为 main、合并提交匹配本次 SHA；直接 push 不发布。这样构建可信 main 提交，也覆盖来自 fork 的合并。API 状态传播允许短暂重试。所有构建及 tag 都绑定该 SHA，不在运行中换成更新后的 main。

发布前重新执行检查，三平台包和 iOS 编译必须全部成功，再汇总产物与 SHA-256 清单。先上传至草稿 Release，附件齐全才公开；重跑同一流水线使用同一 tag。已发布版本不覆盖附件；同名 tag 或 Release 指向其他提交时失败。

## 版本

`pubspec.yaml` 的主、次版本及补丁基数决定版本范围；本发布工作流的 `run_number` 加到补丁基数，形成 `v主.次.补丁`。例如基数 0.1.0、运行编号 1 得到 v0.1.1。未发布的运行也会消耗编号，允许跳号；重跑编号不变。不为修改版本再提交代码，避免递归构建。

应用的 build-name 使用上述版本，build-number 使用发布流水线 run_number。单次 workflow 中只分配一次，所有平台共用。后续调整主/次版本时，保持此工作流身份与编号连续。每个提交独立运行，不使用会丢弃旧 pending 任务的全局发布并发组。

## 签名与权限

Android 使用固定项目发布密钥，通过 GitHub Actions secrets 注入；不得使用每台 runner 临时生成的 debug 签名发布正式 APK。仓库没有现有签名 secrets 时，生成项目专用密钥，在本机忽略目录保存私密备份，再配置 secrets；不纳入 Git、不输出密码。发布构建缺少签名时明确失败。

Secrets：`ANDROID_KEYSTORE_BASE64`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`。临时密钥只供签名 job 使用，任务结束清理；上传目录只含分发包。

macOS 暂无 Developer ID/公证证书，产物标明 ad-hoc 签名；Windows 暂无 Authenticode 签名。它们是直接分发压缩包，不是商店上架包。Apple 签名准备好后再接入可安装 iOS 包与 macOS 公证。

当前项目签名备份位于实施 worktree 的 `.tools/release-signing/`（不入 Git），其中 `sony-camera-release.p12` 与 `keystore-password.txt` 必须一并保留，移除 worktree 前先另行备份。公开证书 SHA-256 为 `a1353154ca70fa3e9ca0acfe7a5f0cb96ef55c31d758bbfd0d06cada178a8938`。已配置四项仓库 Secrets。首次从 release 构建后，可对 APK 的签名证书指纹进行核对。

默认 token 只读；仅发布 job 有 `contents: write`。PR job 不继承签名 secrets。外部 Actions 固定提交 SHA，Flutter 固定为当前工程的 3.47.5，依赖按 lockfile 安装。

## 验收

- 普通 PR 更新只检查，不发布；关闭未合并的 PR 不发布；直接 push main 不发布。
- 合并到 main 的 PR 触发发布，版本唯一且四平台构建使用同一 SHA 和版本参数。
- 任一检查/构建失败不产生公开的缺附件 Release。
- 同次重跑不重复创建版本，不覆盖已公开资产，不接受 tag 指向其他提交。
- Android APK 签名可校验，Windows zip 包含运行依赖，macOS zip 保留 app bundle，附校验和。
- 必须区分本地静态/逻辑校验与 GitHub runner 的实际构建结果；合并前不伪称自动 Release 已端到端通过。

参考：[GitHub PR/工作流事件](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows)、[Flutter Android 发布签名](https://docs.flutter.dev/deployment/android)、[Release API](https://docs.github.com/en/rest/releases/releases)。

## 操作与恢复

1. PR 阶段的 APK 使用一次性验证签名，文件名含 `android-validation`；带项目固定签名的正式 APK 仅在 main 合并后生成。发布附件位于 GitHub Releases，CI 临时构建包保留 7 天。
2. 发布失败时，在 Actions 中对原 Release 运行选择重新运行失败任务，保留同一 run_number。检查失败要修复代码后通过新 PR 合并，不从旧失败提交造成功版本。
3. 如果公开前上传中断，重跑会补齐同一草稿 Release；检查附件齐全后才公开。已经公开的版本不会重新上传或修改附件。同名 tag/Release 指向其他提交时，需要人工核查，流水线不会强行覆盖。
4. 本地构建 release APK 时，设置 `ANDROID_KEYSTORE_PATH` 及上述三个密码/别名环境变量，再执行 `flutter build apk --release`。缺失配置时明确失败；日常 `flutter run` / debug 构建不需要发布私钥。
