# Android 参考应用静态协议线索

日期：2026-11-10。仅分析已下载的包，未安装或执行 APK，未连接手机或相机。本文记录后续适配器的研究入口，不能作为 ZV-E10 一代已兼容或已通过传输验收的证明。

## 包身份

版本和包名来自下载包的 `manifest.json`，下列 SHA-256 为本机重新计算的 base APK 哈希；哈希用于固定分析对象，不代表签名或来源真实性已经验证。

| 应用 | 包名 | 声明版本 | Base APK SHA-256 |
|---|---|---|---|
| Imaging Edge Mobile | `com.sony.playmemories.mobile` | 7.8.6 | `c466640e136e2fe4bc1a50a3ab995d028c96f71921b5f973594a7a7114ec3501` |
| Creators' App | `jp.co.sony.ips.portalapp` | 3.6.0 | `0ccd19a3d391218650d6013cf2b04e5b8e8644438f83a52e8d55302553708777` |
| Monitor+ | `com.uhi.monitorplusflutter.gstore` | 1.6.0 | `039bebd0dfbb849b26c16e92281c78fcfa91a46badf9a1922b0c8bb48df1bcef` |

本机包目录：`/private/tmp/sony-camera-apks/extracted/{iem,creators,monitor}/`。临时分析产物目录：`/private/tmp/sony-static-protocol/`。这些目录可能被系统清理，未将第三方 APK 或反编译源码纳入本项目。

## 工具覆盖与限制

REA 的 JADX 配置已存在。本轮 `inspect_android_package` 在 `ownership_preparation` 阶段失败：Swift 辅助程序无法使用默认模块缓存路径，同时报告 SDK/编译器不匹配；证据保存在本机 `/private/tmp/sony-iem-package-evidence.json`。这次失败发生在包分析启动前，不能把后续 CLI 结果称为 REA MCP 分析成功。

后续线索来自已有 JADX 引擎的定向静态反编译、已解出的资源和 DEX/native 字符串。JADX 日志含类型恢复失败，故不完整的方法不能当作准确源代码；这里只记录已经检查到的类、调用名及数据字段。未验证动态调用顺序、鉴权、握手、相机响应或机型分支。

## IEM 线索

以下类路径均相对于临时产物 `iem-code/`，可用上方 APK 哈希重新定位对象。

| 证据 | 位置 | 已观察内容 | 下一步需要证明 |
|---|---|---|---|
| IEM-01 | `com/sony/mexi/orb/client/avcontent/AvcontentClient.java`，`getContentCount` / `getContentList` | 调用名分别为 `getContentCount`、`getContentList`，版本字符串为 `1.2`、`1.3`；列表结果经 `Content.Converter` 转换 | 哪些机型和连接模式使用此分支，服务地址、发现过程、实际响应 |
| IEM-02 | `com/sony/scalar/webapi/service/avcontent/v1_3/common/struct/ContentListSource.java`，`Converter` | 列表参数包含 `uri`、`stIdx`、`cnt`、`type`、`target`、`view`、`sort`；解析默认起点 0、数量 50 | 分页边界、稳定排序、最大页大小、版本兼容；不能直接把默认值当作服务端保证 |
| IEM-03 | `com/sony/mexi/orb/client/OrbClient.java`，请求体构造和能力查询方法 | 请求体组织 `method`、`params`、`id`、`version`；存在 `getMethodTypes` / `getVersions` | 通过发现结果和能力查询选协议，不能硬编码推测地址 |
| IEM-04 | `com/sony/playmemories/mobile/ptpip/mtp/ThumbnailGetter.java`，`getOperation` | 缩略图分支使用 `GetThumb`，参数包含对象句柄；从接收缓冲区取得数据 | PTP/IP 建链、对象枚举、操作码、会话及响应校验；缩略图尺寸/实际流量 |
| IEM-05 | `com/sony/playmemories/mobile/cds/action/GetRootContainer.java`，`retrieveContainer`；DEX 字符串表 `classes.dex` 偏移 `0x682833` | 存在 XML container 解析，以及 `ContentDirectory:1` 的 `Browse` SOAP 模板 | 哪个设备发现结果启用此分支；DIDL 媒体资源中缩略图与原图如何区分 |
| IEM-06 | `com/sony/playmemories/mobile/contentviewer/detail/controller/exif/information/RatingInformation.java`，`getRating`；`transfer/mtp/detail/exif/information/RatingInformation.java` | 前者读取 XMP 工具中的评分值；后者读取传输项目已有 EXIF 评分用于展示 | 尚未形成相机评分写入调用证据；展示评分不等于卡内写回 |

由此可确认 IEM 包内并存多条媒体访问实现，而非所有相机共用一个 HTTP 路径。当前证据不足以选择 ZV-E10 一代的实际传输分支，也不足以实现原图 URL、缩略图 URL或评分写回命令。

## Monitor+ 与 Creators' App

Monitor+ 的 `libapp.so` 字符串中存在 `EnumContentRating.`、`ratingNone` 和 `rating1`–`rating5`：例如字符串表偏移 `0xce4e7`、`0xeac0a`、`0xab3ec`、`0xbfd46`、`0xd106d`、`0x70e06`、`0x118e9c`。这只支持“包内有评分表示”的结论，不能证明它写入本机元数据或相机存储卡，也不能据此推导写回命令。

Creators' App 本轮只固定了包身份并取得部分静态产物；尚无可据此实施的媒体协议证据。不能用其包含某个类、权限或机型名称宣称旧机型兼容。

## 实现边界与下一步

1. 先追踪 IEM 设备发现结果到各浏览器/传输实现的选择，确认适用于 ZV-E10 一代的协议。
2. 确认文件元数据、缩略图、预览与原片是不同请求；记录分页、对象身份和版本字段，然后实现能力型适配器。
3. 评分继续按“共同期望值 + 本机/相机、每个成员独立写回状态”设计。两处实际写入及读回都未实现，不能显示同步成功；不以整图下载再上传替代元数据命令。
4. 无线首图速度、缓存命中速度、后台连接及原图吞吐仍需之后获准的实机验证。本轮不提供虚构的性能数字。
