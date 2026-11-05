# VLC AI 输出计时验证

版本 `0.8ok`，2026-11-05，实体 Vision Pro / visionOS 27.2（24N120）。

本轮只改变本地文件经 VLC 做 AI 2D 转 3D 时的时钟策略；保留 0.7.2ok 及 Debug 旧时钟对照。用户最终确认窗口与影院中卡顿改善，声音、人体比例和边缘正常。

| 报告 | 用途 | 结果 |
|---|---|---|
| `baseline-motion.json` | 0.7.2ok 加诊断记录 | 最长提交间隔 87.78 ms |
| `auto-decoder-motion.json` | 自动解码选项实验，未采用 | 最长 91.44 ms |
| `monotonic-motion-experiment.json` | 单调时钟实验 | 最长 42.11 ms，17 项通过 |
| `final-motion.json` | 正式策略，H.264 运动片 | 最长 49.91 ms，17 项通过 |
| `final-hevc-initial.json` | H.265 初测，用户中途打开系统界面 | 保留失败状态；约 6 秒暂停，不作为持续前台性能结果 |
| `final-hevc.json` | H.265 保持前台复测 | 最长 39.94 ms，17 项通过 |
| `summary.json` | 原始报告计算出的汇总 | 包含实验、异常及正式结果 |

测量窗口为预热后的 10 秒，输入为 1080p SDR / 30 fps。结果是 App 提交节奏，不等于头显扫描帧率，不代表长时间、所有编码或网络播放表现。原始记录不包含私人影片名称、路径或画面。

## 重跑短测

安装 Debug 构建并让头显保持解锁、应用可见后，使用已准备好的测试片：

```sh
python3 Scripts/device_smoke_test.py DEVICE_UDID depth-motion-vlc
python3 Scripts/device_smoke_test.py DEVICE_UDID depth-motion-vlc --vlc-clock-reference
python3 Scripts/device_smoke_test.py DEVICE_UDID depth-vlc
```

`--vlc-clock-reference` 仅本次进程使用旧时钟，不改变片库偏好。普通启动不带此参数。后台暂停记录与测试结果一并保留，不从失败报告中剔除长间隔。

在仓库根目录重新计算汇总，输出另存后再与归档的 `summary.json` 比较：

```sh
python3 Scripts/summarize_vlc_cadence.py \
  Docs/ValidationResults/VLCCadence/auto-decoder-motion.json \
  Docs/ValidationResults/VLCCadence/baseline-motion.json \
  Docs/ValidationResults/VLCCadence/final-hevc-initial.json \
  Docs/ValidationResults/VLCCadence/final-hevc.json \
  Docs/ValidationResults/VLCCadence/final-motion.json \
  Docs/ValidationResults/VLCCadence/monotonic-motion-experiment.json
```

`vlcFrameTrace` 每项为 `[单调时间秒, 事件编号]`：0 输出转换完成，1 VLC 显示回调开始，2 快照完成，3 消费者取帧，4 字幕选择调用。回调记录上限 2048 条；上述 30 fps 短测均未达到上限。事件 0 位于解码及颜色转换之后，不能单独当作解码耗时。
