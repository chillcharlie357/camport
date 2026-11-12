# Sony PTP/IP 协议交叉核对

日期：2026-11-11。本文把 CamPort 的 `SonyPtpCameraAdapter` 与已公开的独立逆向成果逐项核对，用于收敛“连接/图传到底走什么协议”这一关键不确定性。所有结论都来自静态交叉比对，没有真机验证；不能据此把 ZV-E10 一代标注为“已兼容”。

## 交叉核对来源

- `peiyuanix/zv-e10-creators-app-patcher`（`docs/en/01-how-it-works.md`、`docs/en/02-patches.md`）：针对 ZV-E10 一代与 Creators' App 的逆向，类名未混淆，含真实 PTP/IP 请求日志。
- `profitpioneer/iphone-protocol-sniffer`（`docs/sony-a7m4-case-study.md`）：对 A7 IV 的抓包记录，证明 Wi-Fi 控制通道走 PTP/IP，实时取景是端口 60152 的 HTTP 流。
- `gphoto/libgphoto2`（`camlibs/ptp2/ptp.h`、`library.c`）：PlayMemories / Imaging Edge Mobile 时代的 Sony PTP 扩展命名。

## 已确认的连接流程（Smartphone Connect / 内容传输）

Creators' App 在 Smartphone Connect 下按此顺序建链，CamPort 已对齐：

```
GetDeviceInfo (0x1001)
→ SDIO_OpenSession (0x9210, [1, 1])
→ SDIO_Connect (0x9201, [1,0,0])
→ SDIO_Connect (0x9201, [2,0,0])
→ SDIO_GetExtDeviceInfo (0x9202, [300])
→ SDIO_Connect (0x9201, [3,0,0])
→ SDIO_SetContentsTransferMode (0x9212, [2,1,0])
→ GetStorageIDs / GetObjectHandles / GetObjectPropList
```

## 关键修正：分块下载操作码

Creators' App 与 ZV-E10 用 `SDIO_GetPartialLargeObject (0x9219)` 做卡内文件分块下载，参数为 `[handle, offsetLow, offsetHigh, count]`。抓包实例如 `params=[33, 0, 0, 3145728]`（3 MiB 块）。

libgphoto2（IEM 时代）把同一角色命名为 `SDIO_GetPartialLargeObject = 0x9211`。二者代码不同，说明 Sony 在不同固件/App 代际间改过此扩展。CamPort 现在优先使用相机在 GetDeviceInfo 中实际报告的 0x9219，其次 0x9211，再退回标准 GetPartialObject (0x101B) 与 GetObject (0x1009)，避免对旧固件硬编码单一操作码。

## 仍需真机确认的差异

- 缩略图：Creators' App 用 `GetObjectPropList (0x9805)` 取缩略图位图；CamPort 目前用标准 `GetThumb (0x100A)`。GetThumb 是标准 PTP 操作，ZV-E10 是否仍支持需真机确认；不支持时应增加 0x9805 路径。
- 元数据：Creators' App 用 `GetObjectPropList (0x9805)` 列卡内文件；CamPort 用标准 `GetObjectInfo (0x1008)`。二者语义不同，GetObjectInfo 是否对卡内文件返回完整 ObjectInfo 需真机确认。
- GetObjectHandles 第三参：抓包为 `[65537, 0, 1073742000]`，CamPort 传标准 `[storageId, 0, 0]`（association=0 表示全部）。0 通常可工作，但需真机确认 Sony 是否要求特定关联过滤值。

## 边界

本文件只建立“实现与公开逆向成果一致”的静态事实，不证明真机可用。C-01（第一代 ZV-E10 真机文件列表/缩略图/预览/原片/恢复）仍是唯一能闭合“真实可用”的门槛。
