# CamPort

CamPort 是一个本地优先、跨平台的 Sony 相机原片浏览与导入应用。首版以第一代 Sony ZV-E10 为验证目标，Android 优先，同时覆盖 iOS、macOS 和 Windows。

它只按需读取文件信息与缩略图，不把相机内的图片整卡传到设备；原片只在用户明确打开预览或导入时下载。

## 为什么做 CamPort

- Imaging Edge Mobile：连接和图传偏慢，回到后台容易断开。
- Monitor+：存在付费功能，连接慢、经常失败，连接后的图库预览慢。
- Creators' App：不支持 ZV-E10 一代这类老机型。

CamPort 聚焦连接、浏览、筛选与原片导入；遥控拍摄和实时监看是后续能力。

## 当前状态

已经落地 Flutter 四平台工程、共享相机/传输模型、按需缩略图调度、格式筛选、同名 RAW/JPG/PNG 合并显示、持久化导入队列和 Android/iOS 平台后台通道。协议层包含 PTP/IP 传输、Sony PTP/IP 适配器、SSDP 发现和原片部分读取，并有自动化测试覆盖。

真实 ZV-E10 尚未完成硬件验收。当前不能宣称“已兼容某机型”或“比 IEM/Monitor+ 更快”；连接成功率、冷图库首图时间、导入速度和后台恢复仍需在真机建立基线。

首版已移除评分展示与评分写回，历史评分数据仅保留用于未来迁移。

## 标识

| 范围 | 值 |
| --- | --- |
| 用户可见名称 | CamPort |
| 仓库 | `chillcharlie357/camport` |
| Dart 包名 | `camport` |
| Android applicationId / namespace | `com.example.camport` |
| iOS / macOS bundle identifier | `com.example.camport` |
| 原生方法通道 | `camport/transfer_background` |

包名与应用 ID 已统一到 `camport`；未使用 Sony 或 Imaging Edge 作为商标。

## 文档

- [需求与验收标准](docs/requirements/sony-camera-requirements-and-acceptance.md)
- [产品与架构设计](docs/superpowers/specs/2026-11-10-sony-camera-transfer-design.md)
- [功能与限制](docs/wiki/Features-and-Limitations.md)
- [路线图](docs/wiki/Roadmap.md)
- [相机连接与协议](docs/wiki/Camera-Connection-and-Protocol.md)
- [兼容与验证状态](docs/wiki/Compatibility-and-Validation.md)
- [Android 参考应用静态协议线索](docs/research/android-protocol-evidence.md)
- [CI/CD 与自动 Release](docs/superpowers/specs/2026-11-10-cicd-release-design.md)

## 本地开发

使用满足 `pubspec.yaml` Dart 约束的 Flutter SDK：

```sh
flutter pub get
flutter test
flutter analyze
flutter run -d macos
```

Android、iOS 和 Windows 分别使用对应平台工具链构建。相机连接与导入需要真实相机或对应平台权限；示例图库不连接设备。

## 自动检查与发布

指向 main 的 PR 执行格式、分析、测试和原生构建检查。PR 合并到 main 后，自动生成递增版本并发布签名 Android APK、macOS 压缩包和 Windows x64 运行包；iOS 只做无签名编译检查。
