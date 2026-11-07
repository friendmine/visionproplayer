# SMB 本机验证（2026-11-06）

当前结果：visionOS Debug 目标构建通过；本机路径和钥匙串存储回归通过；隔离 SMB2 联调 12 项全部通过。**尚未在 Vision Pro 或真实 NAS 上测试。** 用户暂无 SMB 环境，真机测试延期。测试没有添加真实账户或影片，也没有更改系统共享设置。

## 报告范围

- `final-loopback.json`：实际产品目录浏览和预览桥接代码，配合固定版本 macOS VLCKit 进行认证、Unicode/嵌套目录、错误和取消测试；预览确实解码得到一帧。无界面 libVLC 检查时间推进、跳转、暂停与恢复，不代表已确认可见画面、音画同步或头显交互。
- `initial-loopback.json`：保留初次失败。VLC 过滤文本条目使原先数量断言不正确；已认证会话可能被缓存，故错误密码应在成功认证之前测试。临时服务的 READ EOF 响应使用了错误的消息体，导致 libsmb2 拒绝；修复测试服务响应，而非放宽产品解析或关闭认证。最终还单独检查未知账户被拒绝。
- `module-alias-attempt.json`：保留 `smb2://` 强制模块实验失败。固定依赖的解析器不接受该别名，正式实现已恢复 `smb://` 和 VLC 正常模块选择，不声称禁用了旧协议回退。

`Scripts/test_network_sources.swift` 覆盖地址规范化、特殊字符、同服务器直接子项限制、越界拒绝、无凭据 URL/元数据和 VLC 路由。`Scripts/test_network_store.swift` 使用临时目录及随机钥匙串条目，验证存取、重新加载、访客删除凭据、磁盘失败回滚、移除和损坏资料保护；结束时清理条目。两项均已执行通过。

## 本机复现

在仓库根目录运行。Swift 测试仅依赖系统框架：

```sh
swiftc -module-cache-path /tmp/vpp-swift-cache VisionProPlayer/Network/NetworkServer.swift VisionProPlayer/Playback/PlaybackOptions.swift Scripts/test_network_sources.swift -o /tmp/vpp-network-tests
/tmp/vpp-network-tests
swiftc -module-cache-path /tmp/vpp-swift-cache VisionProPlayer/Network/NetworkServer.swift VisionProPlayer/Network/NetworkServerStore.swift Scripts/test_network_store.swift -o /tmp/vpp-network-store-tests
/tmp/vpp-network-store-tests
```

SMB 集成需要已解析的 macOS VLCKit artifact，以及独立 Python 环境中的可选测试依赖 `impacket`（不是 App 运行依赖）。`Scripts/serve_smb_fixture.py` 整理自本次工作的临时服务脚本；整理后的入口已检查语法，最终报告来自临时脚本运行。它只监听回环地址，提供程序生成的只读短片，生成权限为 0600 的临时配置；使用 Ctrl-C 正常退出会删除配置。

```sh
python3 Scripts/serve_smb_fixture.py --config /tmp/vpp-smb-fixture.json
```

在另一个终端编译并测试：

```sh
vpp_framework_dir="$PWD/.build/SourcePackages/artifacts/vlckit/VLCKit/VLCKit.xcframework/macos-arm64_x86_64"
clang -fobjc-arc -fmodules -Wno-nullability-completeness \
  -F "$vpp_framework_dir" -I "$vpp_framework_dir/VLCKit.framework/Headers" \
  -framework Foundation -framework VLCKit -Wl,-rpath,"$vpp_framework_dir" \
  Scripts/test_smb_integration.m VisionProPlayer/Bridge/VPPNetworkBrowser.m \
  VisionProPlayer/Bridge/VPPSeekThumbnails.m -o /tmp/vpp-smb-integration
/tmp/vpp-smb-integration /tmp/vpp-smb-fixture.json /tmp/vpp-smb-report.json
```

测试结束关闭服务；异常终止时手动删除临时配置。不要提交配置、原始认证日志或新增视频。仓库中的报告仅保留检查名称及结果。

## 待完成

头显本地网络授权、实际目录交互、NAS 音画表现、预览、重开续播及偏好、影院、断网重连、高码率和 SMB3 加密尚未验证。原生空间视频通过本地文件/相册入口播放，不能用本机 SMB 2D 测试推断其支持情况。
