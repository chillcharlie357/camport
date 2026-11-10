# Sony 相机导入

用于浏览和导入 Sony 相机原片的跨平台应用。首版以第一代 ZV-E10 为兼容验证目标，Android 优先，架构覆盖 iOS、Android、macOS、Windows。

## 文档与验收

- [需求与验收标准](docs/requirements/sony-camera-requirements-and-acceptance.md)：功能、预览性能、安全隐私、可靠性、后台恢复、兼容和发布门槛。
- [文档目录](docs/README.md)、[已批准的 v2 设计基线](docs/design/baselines/sony-transfer-v2-approved/index.html)。
- [同名合并和评分设计](docs/superpowers/specs/2026-11-10-raw-jpeg-rating-design.md)。

## 当前进度

已建立 Flutter 平台工程、共享模型/接口、示例图库与单张预览。支持同名 RAW 与 JPG/JPEG/PNG 合并显示、统一 0–5 星本机评分、独立物理文件选择，以及右上角“…”中的筛选和显示设置；19 项逻辑/界面测试通过。

相机协议、真实缩略图与原片传输仍待接通，预览速度尚未相机实测。设计稿中的照片、连接和速度为演示数据。

## 预览性能原则

浏览只读文件信息和按需缩略图；禁止进入图库便全量下载相机原图。无线连接优先可见区和缓存，限制并发与预取范围；只有用户明确载入或导入时才请求原片。具体请求预算、测量定义与发布门槛见需求文档。

评分、合并和筛选不修改相机或媒体原文件；原片导入保留原始字节，不自动缩小或转码。仅宣传已通过实机验收的机型和能力。
