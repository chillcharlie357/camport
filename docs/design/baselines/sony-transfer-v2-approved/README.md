# Sony 相机导入 · 完整设计稿

基于已批准的首版范围与 B 布局，覆盖 Android、iOS、macOS、Windows。

- `index.html`：可离线浏览的完整画板，包含 12 个移动页面、2 个桌面页面；点击按钮进入流程演示。
- `print.html`：五页打印版。
- `exports/`：高清图片与五页 PDF。

设计范围包括连接、相机图库、RAW/JPEG/MP4 直接筛选、原片预览、保存位置、导入进度、完成、断线恢复、权限补救、同名文件处理和设置。

iOS 使用其系统本地网络权限与文件/相册入口；Android 使用系统附近设备及 Wi-Fi 连接提示。桌面端默认保存到选定文件夹。稿件是产品目标界面，所有文件、连接状态和速度均为演示数据，不代表已经完成的协议能力或实测性能。移动端采用大图两列，界面随文本放大与窄屏重排。

## 示例照片

公开示例照片来自 Unsplash，仅用于设计示意，不作为相机样片或用户实际作品。

- https://images.unsplash.com/photo-1476514525535-07fb3b4ae5f1
- https://images.unsplash.com/photo-1464822759023-fed622ff2c3b
- https://images.unsplash.com/photo-1518837695005-2083093ee35b
- https://images.unsplash.com/photo-1441974231531-c6227db76b6e
- https://images.unsplash.com/photo-1500534623283-312aade485b7
- https://images.unsplash.com/photo-1509316785289-025f5b846b35

## v2 配色与字体更新

- 中性银灰画布、白面板、深灰主按钮，钢蓝限用于选中与进度。
- 中文 Noto Sans SC，西文 IBM Plex Sans；字体在 assets/fonts 中离线打包，附 OFL 许可证。
- 颜色和排版源定义在 theme-v2.css，视觉决策见 VISUAL-DIRECTION.md。
- 最新图片与五页 PDF 见 exports/v2；v1 的完整包保存在相邻 archive 目录。
