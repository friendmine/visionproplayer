# 播放验证记录

日期：2026-10-31（Asia/Shanghai）。这是验证工程，结论仅适用于下述环境和片源。

## 环境

- Xcode 27.0，Build 27A266a。
- visionOS 27 SDK，最低部署版本 visionOS 2.0。
- Apple Vision Pro 模拟器，visionOS 26.5，arm64。
- Apple Vision Pro 实体机，visionOS 27.0.1（24M372），Wi-Fi 连接，开发者模式已启用。
- 官方 VLCKit 固定提交及二进制版本见 README 和 THIRD_PARTY.md。

## 模拟器与离线检查

| 验证 | 结果 | 范围 |
|---|---|---|
| 模拟器 Debug 编译 | 通过 | Swift、Objective-C、官方 VLCKit 链接及资源打包 |
| 真机目标 Debug 编译 | 通过 | 关闭签名的编译检查，不代表真机已安装或运行 |
| 2D MP4 / 原生 | 通过 | 时间推进、精确跳转、暂停、继续；截图可见正确测试画面 |
| MKV / VLC | 通过 | H.264 + FLAC 片源的时间推进、跳转、暂停、继续；截图可见画面 |
| Full SBS MP4 / 原生 | 通过 | 1280×360 拆为两眼各 640×360；持续 GPU 帧提交；单眼截图正向且未覆盖控制栏 |
| Full SBS MKV / VLC | 通过 | 软件解码与可见尺寸处理；两眼各 640×360；时间与帧输出正常 |
| 连续切换和停止 | 通过 | VLC 平面 → VLC SBS → 原生 SBS → VLC 平面；停止后播放器引用与请求释放 |
| 引擎选择、Half/Full SBS 比例 | 通过 | 大小写扩展名、URL 查询参数、手动覆盖、两种 SBS 宽高比 |
| 四个测试片完整解码 | 通过 | ffprobe 检查编码/尺寸/时长；ffmpeg 完整解码无错误 |
| USDA 材质语法 | 通过 | usdcat 解析；运行时 RealityKit 实际加载 |

测试 JSON 保存在 `Docs/ValidationResults/`。本次运行的完整截图保存在 `.build/validation/`（不加入版本管理）。

自动播放测试检查到达第 1 秒、跳转到约第 6 秒、暂停后时间保持、恢复后时间继续、SBS 帧数和尺寸；**自动计时通过本身不能证明画面正确**。因此同时检查实际截图，修正了垂直翻转、色彩采样、默认窗口深度导致的控件遮挡，以及 VLC 解码填充尺寸影响宽高比的问题。

## 实体机执行结果

2026-10-31 12:44–12:46（Asia/Shanghai），开发签名构建、Wi-Fi 安装和启动均成功。首次启动被系统信任检查阻止；用户在头显上信任开发者后，启动成功。

| 真机检查 | 结果 | 证据 |
|---|---|---|
| 2D MP4 / 原生 | 通过 | 跳转后 6.81 秒；暂停保持、继续播放正常 |
| MKV / VLC | 通过 | 跳转后 6.47 秒；暂停保持、继续播放正常 |
| Full SBS MP4 / 原生 | 通过 | 提交 59 帧；两眼各 640×360；播放控制正常 |
| Full SBS MKV / VLC | 通过 | 提交 77 帧；两眼各 640×360；播放控制正常 |
| 连续切换和停止 | 通过 | 四次切换均开始播放；停止后会话引用释放 |

五份原始报告保存在 `Docs/ValidationResults/PhysicalDevice/`，均记录 `physical-device`、系统版本、时间和独立 runID。帧数是短测试期间的提交数量，不是帧率或性能基准。

以上属于真机自动播放控制与帧提交验证。用户确认 2D 可以观看，最初反馈彩条版 SBS 的 LEFT / RIGHT 同时出现、3D 显示不符合预期。后续换用景深片后，用户已确认原生 SBS 有前后层次，见下节。已增加独立于视频纹理的「左右眼检查」：左眼纯红、右眼纯蓝、单眼渲染回退为绿色；该纯色检查尚未收到人工结果，不能将自动通过等同于完整视觉和听觉验收。

### 测试素材澄清与更新

用户随后提供头显截图：独立播放器窗口内显示 LEFT 彩条，进度为 00:12 / 00:12。该画面与旧版测试片内容相符，不能据此认定解码花屏或左右眼混合；同屏存在 Mac 远程桌面也不足以证明它是原因。纯色眼别检查尚未获得用户结果。

旧 SBS 片仅将同一彩条图整体平移，左右眼还放置不同文字，缺少清晰的多层深度线索，容易引起误解。现已改为原创三层景深演示：金色近景球、青色中景球、紫色远景球，平行双视点加离轴投影，中景零视差，两眼文字一致。12 秒、1280×360、H.264/AAC 保持不变；MP4 与 MKV 完整解码检查通过。此项修改改善测试素材，**不代表已经修复或证实任何左右眼渲染问题**。先前报告对应旧彩条素材。

景深版签名构建、真机安装成功，打包资源 SHA-256 与源文件一致，记录见 `PhysicalDevice/depth-scene-assets.json`。更新后曾因设备需要解锁而发生远程启动超时。

用户随后按「SBS · 原生」观看，明确反馈「能看到三个球，也有前后层次」，并在「SBS · VLC」中再次确认「VLC 也有前后层次」。因此原生 SBS MP4 和 VLC SBS MKV 的景深显示均获得真机人工确认；交换左右眼、纯色眼别和主观听音仍需分别确认。没有证据表明旁边的远程电脑屏幕造成先前的观感问题，本次没有修改每眼渲染机制。

景深片 VLC 真机复测通过：跳转到 6.52 秒、暂停保持、恢复推进，提交 76 帧，两眼各 640×360，无报告错误，见 `PhysicalDevice/depth-scene-vlc.json`。原生景深片的补充自动复测未在 55 秒内拿到对应 runID 的报告，已记录为未完成；原生人工观看确认有效，但不能把旧素材或旧 runID 的自动报告当成本次成功证据。

## 复现

```sh
./Scripts/build.sh
xcrun simctl list devices available
# 使用上一步已有的 Apple Vision Pro 模拟器 UDID
xcrun simctl boot <UDID>
xcrun simctl bootstatus <UDID> -b
./Scripts/smoke_test.sh <UDID>
./Scripts/smoke_test.sh <UDID> lifecycle
python3 Scripts/verify_samples.py
swiftc VisionProPlayer/Playback/PlaybackOptions.swift Scripts/test_options.swift -o /tmp/vision-player-options
/tmp/vision-player-options
```

`smoke_test.sh` 会安装 Debug 应用并覆盖该应用已有的同名测试报告；不会读取用户影片。应用只在 Debug 且显式传入 `--smoke` 时自动测试。脚本依赖 ffmpeg 的仅是 `verify_samples.py` 和测试片生成脚本。

## 真机复现

在 Xcode 中选择自己的开发团队，对已配对的 Vision Pro 构建并安装 Debug 版本。首次运行若提示开发者未受信任，需要在头显的「设置 → 通用 → VPN 与设备管理」中信任本次签名对应的开发者。

```sh
xcrun devicectl list devices
# 使用实体 Vision Pro 的 UDID；保持头显唤醒、解锁且 App 可见
python3 Scripts/device_smoke_test.py <UDID> 2d
python3 Scripts/device_smoke_test.py <UDID> mkv
python3 Scripts/device_smoke_test.py <UDID> sbs-native
python3 Scripts/device_smoke_test.py <UDID> sbs-vlc
python3 Scripts/device_smoke_test.py <UDID> lifecycle
```

该脚本要求 App 已安装，会重启本项目 App，并读取其 Documents 中的测试报告。它拒绝模拟器和其他平台，仅接受与本次启动 runID 一致的真机报告，结果保存在 `.build/physical-validation/`。新报告同时记录运行环境、系统版本和时间。未拿到当前报告或断言不通过时，脚本返回非零状态。

## 下载的真实立体影片：Big Buck Bunny

来源为 Blender 官方 Sunflower 立体版，原始容器元数据也标注 CC BY 3.0 和制作者；许可、来源、修改说明和 SHA-256 见 `THIRD_PARTY.md` 及 `ValidationResults/PhysicalDevice/bbb-source.json`。

- 从原片 00:20–01:20 提取一分钟。原片 1920×2160 上下立体、上方左眼；重排并缩放为 1920×540 Full SBS，每眼 960×540，30 fps。
- MP4 使用 H.264/AAC，MKV 直接重封装；每个约 18 MB。两份文件均完整解码无错误，已传入真机 App 的 Documents，未替换内置合成测试片。
- 2026-10-31 13:38–13:39（Asia/Shanghai），原生与 VLC 真机自动检查均通过：启动推进、跳转、暂停保持、继续、SBS 帧尺寸与帧提交。
- 原生：60 秒，跳转后 30.74 秒，提交 78 帧；VLC：60.021 秒，跳转后 30.48 秒，提交 76 帧。帧数是短测试区间的累计值，不是性能基准。
- 原始报告：`PhysicalDevice/bbb-native.json`、`PhysicalDevice/bbb-vlc.json`。自动测试后用户观看真实片段，明确反馈「立体感和声音都正常」。这是本次片段的主观确认，未扩展为全部编码、高分辨率或长片兼容性结论。

在首页「真实 3D 短片」菜单选择原生或 VLC 即可重播，格式自动设为 Full SBS 并关闭诊断纯色模式。

```sh
# 从官方解压的上下立体 MP4 制作短片
python3 Scripts/prepare_bbb_sample.py <source.mp4>
# 向已安装的 App 传入片段和署名文件
xcrun devicectl device copy to --device <UDID> \
  --domain-type appDataContainer --domain-identifier com.jeff.visionproplayer \
  --source .build/TestMedia/BBB-SBS-60s.mp4 \
  --source .build/TestMedia/BBB-SBS-60s.mkv \
  --source .build/TestMedia/BBB-SBS-60s-LICENSE.txt --destination Documents/
python3 Scripts/device_smoke_test.py <UDID> bbb-native
python3 Scripts/device_smoke_test.py <UDID> bbb-vlc
```

## 仍需人工 / 真机验收

- 打开「左右眼检查」，分别闭眼确认左红右蓝；关闭后观看景深片，确认金球在近处、青球在中间、紫球在远处，并检查两条 SBS 路径与交换左右眼功能。
- 真实 Half SBS 片源、不同分辨率、HEVC / AV1 / VP9、多音轨、多字幕，以及高码率长片。
- 主观听音、音画同步、空间音频；本次自动报告未确认声音可听和同步精度。
- 文件选择器中的外部文件 / iCloud 文件、网络视频和不稳定网络。
- 真机发热、功耗、内存与长时间运行。
- HDR、Dolby Vision、MV-HEVC 原生空间视频尚未通过本项目验收。

当前 VLC SBS 明确使用 SDR 软件解码并将输出最长边限制在 1920，不能据此宣称支持高码率 4K/8K 或所有 MKV 文件。
