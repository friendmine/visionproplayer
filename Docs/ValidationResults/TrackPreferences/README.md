# 播放偏好短测

2026-11-06，实体 Vision Pro，visionOS 27.2（24N120）。

- `initial.json`：首次检查，36 项中 6 项失败，保留原始状态。
- `selection-wait.json`：等待实际选轨后，37 项中仅暂停位置复合检查失败；报告含实际音轨/字幕和播放状态。
- `final.json`：39 项全部通过。先等待实际选轨与暂停完成，再分别检查选轨和暂停位置，包含 VLC 启动前字幕关闭保护。

片源是本地程序生成的 ProductTracks MP4/MKV（双音轨和内嵌字幕）及 ProductCaptions SRT，不提交影片、设备标识或用户片库数据。探针只使用自己的临时影片记录，结束后删除。

运行本地匹配回归：

```sh
swiftc -module-cache-path /tmp/vpp-swift-cache VisionProPlayer/Playback/TrackPreferences.swift Scripts/test_track_preferences.swift -o /tmp/vpp-track-preference-tests
/tmp/vpp-track-preference-tests
```

安装 Debug App 并准备好上述三个测试文件后，在已解锁、前台可见的真机运行：

```sh
python3 Scripts/device_smoke_test.py <device-id> track-preferences
```

自动测试验证磁盘保存和实际解码器选择。真实影院界面、配音与字幕的佩戴验收另记于 `Docs/VALIDATION.md`，不能用自动通过替代。

最终佩戴验收已通过：用户确认重开恢复音轨和字幕、关闭状态保持，以及引擎切换和进出影院均正常。对应版本标签 `0.81ok`。
