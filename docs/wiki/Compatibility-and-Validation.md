# 兼容与验证状态

## 目标矩阵

| 平台 | 状态 | 说明 |
| --- | --- | --- |
| Android | 首版优先 | 已有前台服务与 Wi-Fi 路由代码，尚未真机验收 |
| iOS | 工程可编译 | 本地网络权限与后台传输待物理设备验证 |
| macOS | 工程可编译 | ad-hoc 签名，未公证；桌面保存待验证 |
| Windows | 工程可编译 | 未做 Authenticode 签名；桌面保存待验证 |

## 相机兼容

| 相机 | 状态 |
| --- | --- |
| Sony ZV-E10 一代 | 首版目标，未完成真机验收 |
| 其他 Sony 机型 | 未验证，不宣称兼容 |
| 其他品牌 | 仅保留扩展接口，未实现 |

## 验证边界

- 当前自动化测试验证的是协议编解码、传输状态机、适配器逻辑、队列和界面行为，使用模拟数据和真实 `ServerSocket`，不代表相机性能。
- 以下结论必须等待真实设备验收后再写：
  - 连接成功率和耗时。
  - 冷图库首图时间。
  - 原片导入速度和字节完整性。
  - 后台切换后的连接保持和恢复。
  - 具体机型和固件组合。

## 证据来源

- [需求与验收标准](../requirements/sony-camera-requirements-and-acceptance.md)
- [产品与架构设计](../superpowers/specs/2026-11-10-sony-camera-transfer-design.md)
- [Android 参考应用静态协议线索](../research/android-protocol-evidence.md)
