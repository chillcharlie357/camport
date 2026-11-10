# Sony 相机导入

用于浏览和导入 Sony 相机原片的跨平台应用。首版以第一代 ZV-E10 为兼容验证目标，Android 优先，架构覆盖 iOS、Android、macOS、Windows。

## 文档与验收

- [需求与验收标准](docs/requirements/sony-camera-requirements-and-acceptance.md)：功能、预览性能、安全隐私、可靠性、后台恢复、兼容和发布门槛。
- [文档目录](docs/README.md)、[已批准的 v2 设计基线](docs/design/baselines/sony-transfer-v2-approved/index.html)。
- [同名合并和评分设计](docs/superpowers/specs/2026-11-10-raw-jpeg-rating-design.md)。

## 当前进度

已建立 Flutter 四平台工程、共享模型/接口、示例图库与单张预览。支持同名 RAW 与 JPG/JPEG/PNG 合并显示、统一 0–5 星期望评分、独立物理文件选择，以及右上角“…”中的筛选和显示设置。

图库现已接入按需缩略图调度：仅可见区域及下一行，最多 2 个并发请求，32 MiB 会话内 LRU 缓存，单张预览复用缓存，显式失败重试；导入资源竞争控制已在调度器中提供，尚待真实导入队列接入。41 项逻辑/界面测试通过，包括 100 文件图库的请求范围、滚动跳转、缓存返回、并发与退出处理；这些检查不代表相机性能实测。

相机协议、真实缩略图与原片传输仍待接通，预览速度尚未相机实测。设计稿中的照片、连接和速度为演示数据。

当前缓存只在图库会话内生效；持久化磁盘缓存待稳定的相机/存储卡/文件版本身份确认后接入。[协议研究线索与未验证项](docs/research/android-protocol-evidence.md)单独记录，不把参考应用包含某个协议当作 ZV-E10 已支持的证明。

## 预览性能原则

浏览只读文件信息和按需缩略图；禁止进入图库便全量下载相机原图。无线连接优先可见区和缓存，限制并发与预取范围；只有用户明确载入或导入时才请求原片。具体请求预算、测量定义与发布门槛见需求文档。

合并和筛选保持只读；用户已允许评分写回本机及相机原文件的评分元数据，图像数据保持不变。当前仅暂存期望评分，两处写回尚未实现。导入阶段保持源字节，不自动缩小或转码。仅宣传已通过实机验收的机型和能力。

## 本地开发

使用满足 `pubspec.yaml` Dart 约束的 Flutter SDK：

```sh
flutter pub get
flutter test
flutter analyze
flutter run -d macos
```

Android、iOS 和 Windows 分别使用对应平台工具链构建。应用中的连接与导入目前显示未实现提示，示例图库不会连接设备或传输原片。
