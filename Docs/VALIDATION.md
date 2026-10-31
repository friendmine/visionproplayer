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

## 3D 棋盘格闪烁与斜视条纹修复

用户在确认立体感后补充反馈：2D 正常，3D 正面有棋盘格式闪烁，侧面有竖条纹。代码检查发现视频平面位于窗口平面，与 SwiftUI 黑色背景同深度，存在共面深度冲突风险。

修复将视频实体沿本地 +Z 向前分离 5 毫米，并由同一个布局方法在初始创建和后续更新中保持该间隔。仍将 RealityView 布局深度固定为 0，以免恢复默认窗口深度后把画面放大到控制栏上。纹理更新和解码路径保持原样，以隔离验证这一个因素。

签名真机编译、安装通过。用户观看新版后明确反馈「修改后的这个版本表现非常好，没有任何问题了」，支持本次共面深度冲突诊断和修复有效。原生与 VLC 的真实影片自动播放回归也通过。原生第一次暂停断言未通过，原因未确定；未改播放逻辑的复测通过，首轮失败报告仍保留，不能忽略为已证实的用户操作干扰。

报告位于 `ValidationResults/PhysicalDevice/FlickerRegression/`。自动报告仅验证播放控制和帧提交，闪烁消失的结论来自用户对新版的实际观察。

## H.265 与 Half SBS 兼容性验证（自动检查及人工观看通过）

已从同一官方 BBB 上下立体片源提取 00:20–00:50，生成六个 30 秒文件：

| 检查名称 | 编码 / 容器 | 布局 | 播放路径 |
|---|---|---|---|
| `hevc-mp4` | H.265 Main / MP4（hvc1） | 2D | 原生 |
| `hevc-mkv` | H.265 Main / MKV | 2D | VLC |
| `half-h264-native` | H.264 High / MP4 | Half SBS | 原生 |
| `half-h264-vlc` | H.264 High / MKV | Half SBS | VLC |
| `half-hevc-native` | H.265 Main / MP4（hvc1） | Half SBS | 原生 |
| `half-hevc-vlc` | H.265 Main / MKV | Half SBS | VLC |

所有文件均为 1920×1080、30 fps、8-bit 4:2:0 SDR、AAC 双声道。Half SBS 每眼 960×1080，显示恢复为 16:9。使用 `prepare_compatibility_samples.py` 核验编码、HEVC Main profile、尺寸、方形像素、时长并完成六文件解码；结果与 SHA-256 见 `ValidationResults/PhysicalDevice/HEVCHalfSBS/fixtures.json`。已抽取 HEVC Half SBS 左眼并恢复宽高比检查图像。

新版签名真机构建与安装成功，六个文件已传到 App Documents。开发自动检查新增 Half SBS 尺寸、实际视频实体宽高比、跳转及恢复后的新增帧计数；仍保留上一轮已确认有效的 5 毫米深度间隔。

首次启动检查因头显锁定而超时；设备报告 `passcodeRequired: true`，未生成播放报告。用户解锁后，2026-10-31 14:00–14:01（Asia/Shanghai）六组真机自动检查全部通过，报告中的系统版本为 visionOS 27.0.1。结果保存在 `ValidationResults/PhysicalDevice/HEVCHalfSBS/` 的六个对应 JSON 文件中，每份均有独立 runID。

- 六组均成功启动、跳转到约 15 秒、暂停保持并恢复时间推进，未报告播放或渲染错误。
- 四组 Half SBS 均提交了视频帧，跳转和恢复后帧计数继续增长；解码尺寸 1920×1080，每眼 960×1080，实际视频实体宽高比约 1.777778（16:9）。累计帧数来自短测试区间，不是帧率或流畅度基准。
- 2D 使用系统或 VLC 的直接显示路径，报告中的 `submittedStereoFrames: 0` 和 `displayAspect: 0` 为不适用，不代表无画面；自动检查不能独立确认 2D 图像和声音可见可听。
- 本轮未发现新的自动检查失败，无需更改解码或立体显示逻辑。新增的是样片、菜单入口、诊断数据与测试断言；保留上一轮闪烁修复。

在头显保持唤醒时，对上表每项执行以下命令可复现：

```sh
python3 Scripts/device_smoke_test.py <UDID> <检查名称>
```

自动检查结束后，用户分别观看并反馈：H.265 2D MP4/MKV 的画面和声音「两种都正常」；四组 Half SBS 的立体层次、物体比例、声音及无闪烁、竖纹或明显卡顿「四种都正常」。人工记录见同目录 `manual-observation.json`。

本次仅测试上述 1080p SDR Main 8-bit 短片，不覆盖 Main 10、HDR、4K/8K 或高码率长片。人工确认不代表已测量帧率、长时稳定性或客观音画同步精度。

## 自动引擎选择与原生失败回退

2026-10-31 14:25（Asia/Shanghai），签名构建、安装及真机自动检查通过，报告位于 `ValidationResults/PhysicalDevice/AutoEngine/`。

- 默认 `.automatic`：AVI/MKV 等直接走 VLC，其余先尝试原生；原生明确打开失败或播放失败时，只切到 VLC 一次。保留 URL、2D/SBS 布局及文件访问权限，尝试恢复可跳转媒体的播放位置。缓冲不会直接触发回退；显式指定原生/VLC 和测试预设保持指定路径。
- 内置、真实 BBB 和兼容性测试按钮均通过 `openSample` 打开，只设置当前测试请求，不写入自己的影片使用的引擎与布局选项。下次文件或 URL 导入仍使用原有选择。
- `routing.json` 的七项检查全部通过：测试预设不改变用户选项；随后导入 AVI 自动使用 VLC/2D；真实原生失败切到 VLC 且跳转/暂停/恢复有效；SBS 回退后保留布局并提交视频帧；两种引擎都失败时稳定报错、不循环；停止取消待处理播放；新文件不受旧失败事件影响。
- H.265 MP4 原生、H.265 Half SBS MKV/VLC 的播放控制与帧检查，以及原生/VLC 连续切换、释放检查均通过，见同目录另外三份报告。

首次连续测试未在超时内取得报告（保留 `initial-timeout.log`）。随后增加逐步诊断，发现并修复两处问题：旧 RealityView 取消材质加载产生的 `CancellationError` 会写入新请求的错误状态；VLC 错误随后进入 Stopped，轮询会漏报错误。现在忽略已取消/过期画面的错误，并通过 libVLC 4 的 `on_media_stopping` 错误原因保留失败状态。修复前报告亦保留，最终结果以 `routing.json` 为准。

复现样片完全来自项目自主生成的彩条测试片，不含用户影片。AVI 与改为 `.mp4` 后缀的副本字节相同，后者用于触发原生实际失败，不是可供正常发布的 MP4 文件。SBS 回退检查使用这一诊断片裁切验证布局与帧更新，不用于证明立体观感。网络中途故障、外部文件访问授权及长片中途恢复未通过本轮端到端验证。

```sh
python3 Scripts/prepare_routing_sample.py
xcrun devicectl device copy to --device <UDID> \
  --domain-type appDataContainer --domain-identifier com.jeff.visionproplayer \
  --source .build/TestMedia/FallbackProbe.avi \
  --source .build/TestMedia/FallbackProbe.mp4 --destination Documents/
python3 Scripts/device_smoke_test.py <UDID> routing
```

## 仍需人工 / 真机验收

- 打开「左右眼检查」，分别闭眼确认左红右蓝；关闭后观看景深片，确认金球在近处、青球在中间、紫球在远处，并检查两条 SBS 路径与交换左右眼功能。
- 更多 Half SBS 片源、不同分辨率、HEVC Main 10 / AV1 / VP9、多音轨、多字幕，以及高码率长片。
- 主观听音、音画同步、空间音频；本次自动报告未确认声音可听和同步精度。
- 文件选择器中的外部文件 / iCloud 文件、网络视频和不稳定网络。
- 真机发热、功耗、内存与长时间运行。
- HDR、Dolby Vision、MV-HEVC 原生空间视频尚未通过本项目验收。

当前 VLC SBS 明确使用 SDR 软件解码并将输出最长边限制在 1920，不能据此宣称支持高码率 4K/8K 或所有 MKV 文件。
