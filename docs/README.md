# Sony 相机导入文档

## 需求与验收

- [完整需求与验收标准](requirements/sony-camera-requirements-and-acceptance.md)：功能、无线预览专项、性能、安全隐私、可靠性、后台恢复、四平台兼容、易用性与发布门槛。需求编号用于实现和测试追踪。
- [产品与架构设计](superpowers/specs/2026-11-10-sony-camera-transfer-design.md)：首版范围、Flutter 架构与相机协议边界。
- [同名合并与评分](superpowers/specs/2026-11-10-raw-jpeg-rating-design.md)：RAW/JPG/PNG 的简单合并规则与本机评分。

## 设计稿与基线

- [已批准的 v2 快照](design/baselines/sony-transfer-v2-approved/index.html)，[校验清单](design/baselines/sony-transfer-v2-approved/BASELINE.json)，Git 提交 `6c4db3b`。
- [工作设计稿](design/sony-transfer/index.html)：在基线上增补功能，不覆盖批准快照。
- [v2.1 完整 PDF](design/sony-transfer/exports/v2.1/sony-camera-design-v2.1.pdf)，[同名合并/评分图](design/sony-transfer/exports/v2.1/merge-rating.png)。

最新用户决策及需求/验收文档优先于历史图稿和旧计划；设计数据不代表真实相机连接或性能实测。
