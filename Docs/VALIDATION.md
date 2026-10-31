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


## 实验性 2D 转 3D（Depth Anything V2 Small）

2026-10-31 17:28–17:40，实体 Vision Pro / visionOS 27.0.1，Debug 开发构建。模型为 Apple Core ML 转换的 Depth Anything V2 Small F16，使用 CPU / Neural Engine。片源为已验证的 `BBB-HEVC-2D-30s.mp4/.mkv`（1080p、30 fps、SDR、HEVC Main 8-bit、AAC），只取原始左眼作为普通 2D 输入，没有读取原片另一眼。

加入默认关闭的实验开关及 0–100% 强度滑块（默认 35%）。普通原生 2D 全屏内也可开启；原生与 VLC 均能合成左右眼，SBS 不重复转换。测试按钮不改动导入影片时的引擎、布局或转换偏好。

本轮实际发现并修复：

- 逐帧等待模型使视频提交降至原生 20.15 / VLC 23.07 fps。改为单个推理任务、无待处理帧队列，显示独立刷新并使用最近深度。播放中深度超过 150 ms 暂用平面画面；跳转与检测到镜头切换会清空历史。该取舍保留视频流畅度，但深度可能稍滞后于运动。
- 新 Metal 合成初版多翻转了一次，截图上下颠倒，自动计时检查未发现。增加与已有 Core Image 路径的逐像素方向、颜色对照，移除多余翻转；修复后重新编译、安装并完成两条转换路径的真机检查，导出左右眼图像均已查看，方向和整帧内容正常。数值测试还检查零强度双眼一致、近物视差方向及边缘有限值。
- 暂停后调节强度会重画，零强度停止新深度推理；开关切换保留位置和播放/暂停状态。保留原 SBS 屏幕离背景 5 mm 的间隔，避免此前的棋盘格/侧面条纹。

17:38 的修复后结果（每条路径预热后测量 10 秒，强度 35%）：

| 指标 | 原生 MP4 | VLC MKV |
|---|---:|---:|
| 视频提交速率 | 30.00 fps | 29.89 fps |
| 其中有有效深度的合成帧 | 297 / 约 10 秒 | 296 / 约 10 秒 |
| 模型处理平均耗时 | 42.89 ms | 40.16 ms |
| 模型处理 P95 | 48.47 ms | 45.97 ms |
| 使用的深度年龄 P95 | 101.80 ms | 103.36 ms |
| 结束时系统热状态 | nominal | nominal |
| 启动、持续转换、跳转、暂停调强度、继续、关闭保留位置、重新开启 | 全部通过 | 全部通过 |

这里的模型耗时含输入缩放与深度采样，不含首次模型加载。深度年龄从读取待推理视频帧算起，不等于音画延迟。提交速率不是头显扫描刷新率，偶尔的平面回退计入视频提交但不计入有效深度合成帧；不能据此宣称每帧都重新推理。两条路径也不是 4K 或 60fps 性能证明。

原有 Half SBS H.265 原生/VLC、自动引擎路由和原生失败回退 VLC 的回归检查通过。模型、源文件哈希、优化前后自动报告及 GPU 数值测试结果在 `ValidationResults/PhysicalDevice/DepthConversion/`。初版报告仅说明当时自动断言通过，不代表方向和视觉验收通过。最终构建还保留了原项目的原地文件访问、文档浏览器和局域网说明配置；编译、安装和启动成功。

人工验收：已请佩戴者分别观看「2D 转 3D · 原生 / VLC」，对比 0%、35%、60% 的景深、流畅度、运动边缘和声音同步。用户明确回复「两条路径效果、流畅度和声音都正常」，因此本次普通 2D 片源的 AI 转换已获得真机人工确认；这与先前原生 SBS 的人工确认分开记录。快速运动、透明物体、遮挡边缘仍可能出现深度错误或拉伸；未进行长时间热稳定性和舒适度验证。

复现：先执行 `python3 Scripts/prepare_depth_model.py`，编译安装 Debug 版本，并把两段普通 2D 文件放到 app Documents。执行 `python3 Scripts/device_smoke_test.py <device-id> depth-native` 或 `depth-vlc`；可加 `--capture` 保存左右眼纹理到 app Documents，截图不代表佩戴观感。独立 GPU 数值检查用 `swiftc -Onone Scripts/test_depth_warp.swift -o .build/test-depth-warp` 后运行该程序（需允许 Metal 设备访问）。模型权重、私人影片和导出的电影截图均未加入 Git。


## 产品界面改版（0.2，2026-10-31）

实际安装于上述 Vision Pro，另通过 visionOS 27 模拟器构建。原测试首页改为片库，新增统一窗口播放、每片设置、字幕音轨面板、网络来源管理和空间影院。旧记录保留为历史证据，以下报告位于 `ValidationResults/PhysicalDevice/ProductUI/`。

| 检查 | 结果与范围 |
|---|---|
| 2D / MKV / 原生 SBS / VLC SBS | 四条真机回归通过，包含启动、跳转、暂停、继续和 SBS 帧提交 |
| 产品流程 | `product.json` 中 23 项通过：片库去重（含容器迁移）、损坏记录备份、持久化、书签、每片设置隔离、网络记录保存、移除不删源、失效文件重新定位、字幕解析和跳转、双引擎音轨/字幕选择、暂停换格式保持位置、返回续播、后台暂停 |
| 原生 2D 转 3D | 约 30.00 fps，短时提交速率；新界面未导致明显性能回退 |
| VLC 2D 转 3D | 约 29.90 fps，同上 |
| 自动引擎切换 | `routing.json` 回归通过 |
| 空间影院与界面可用性 | 用户佩戴确认：片库续播、画面切换正常；影院画面、声音、立体感、屏幕调整、返回窗口续播全部正常；字幕清晰、时间正确、音轨切换有效 |

产品流程测试使用 `Scripts/prepare_product_samples.py` 生成两条音轨与内嵌字幕的 12 秒 MP4/MKV，并生成 SRT；原视频为自主生成测试素材。将 `ProductTracks.mp4`、`ProductTracks.mkv`、`ProductCaptions.srt` 复制到 App Documents 后运行：

```sh
python3 Scripts/device_smoke_test.py <UDID> product
```

测试在自己的临时目录与临时影片记录上运行，结束时移除这些记录；不读取或删除用户原始影片。网络项只验证来源记录保存，不代表真实网络流已测试。内嵌字幕验证包括原生文本输出回调、VLC 选择状态；视觉、声音和空间影院体验单独由佩戴者确认。

开发参数 `--product-demo` 将 Documents 中已有的 BBB 2D / SBS / MKV 和双音轨片加入片库，按 URL 去重，不自动播放，不改变已有记录的设置。Release 不执行演示注入或自动测试。

上述三组人工验收来自本轮用户分别回复「都正常」「全部正常」「全部正常」。随后只修正片库海报在横向宽图下可能超出卡片边界的布局，以及异步音轨任务和损坏记录保存保护；不改变已验收的播放/影院渲染。暗色环境、超长片源、网络流稳定性仍需单独测试。


## 上下 3D 支持（2026-10-31）

用户提供 `bbb_sunflower_1080p_30fps_stereo_abl.mp4`。本机 ffprobe 检查：H.264、1920×2160、方形像素，音轨为 MP3 和 AC-3。它是全高上下排列，每眼 1920×1080；此前只有 SBS 选项，不能按上下排列分眼。

新增 Full OU / Half OU 的裁切、显示比例、影片设置持久化和海报处理；窗口与空间影院共用。默认上左下右，支持交换。新导入时识别明确的上下命名；已有记录不强制覆盖用户选项，在「画面 → 影片格式」切换一次即可。

GPU 检查 `Scripts/test_stereo_regions.swift` 直接建立含不同眼别颜色及纵向梯度的 BGRA 帧，通过与播放器相同的 Core Image 方向转换和共享裁切坐标写入 Metal 纹理，读回确认眼别和垂直方向。Full / Half OU、Full / Half SBS、普通 2D 五种均通过。`Scripts/test_options.swift` 另验证每眼区域、显示比例和布局编码恢复；真机及模拟器目标编译通过。

用 `Scripts/prepare_ou_samples.py` 从该文件制作探针：Full OU 保留原始 H.264 和第一条 MP3 音轨，复制前置关键帧后约 33.84 秒；Half OU 缩至 1920×1080 并编码 H.264/AAC。源文件未改动。片段校验与真机报告位于 `ValidationResults/PhysicalDevice/OverUnder/`。

- Full OU 原生：通过启动、跳转、暂停、恢复，输出每眼 1920×1080，显示比例 16:9。
- Full OU VLC：通过同样检查；现有最长边 1920 的软件解码限制使输出为 1706×1920，每眼 1706×960，比例误差小于 0.01。
- Half OU 原生与 VLC：均通过启动、跳转、暂停、恢复，每眼 1920×540，显示恢复为 16:9。
- 原生 Full SBS 回归通过，每眼 640×360，原有比例与播放控制正常。

半高测试第一次因头显锁定未取得报告；用户解锁后，使用新 runID 重新运行上述测试并全部通过。

上述检查不能替代佩戴者对立体感、声音及长片稳定性的判断，也未对原片第二条 AC-3 音轨作专项检查。

用户随后在头显观看 Full OU 示例，明确确认「立体感、比例和声音都正常」。人工结论对应本次打开的全高上下原生示例；Half OU 与 VLC 路径的自动结果见上述报告，不扩展为原片所有音轨或长时间播放已验收。


## 相册导入与原生空间视频（2026-10-31）

新增系统 PhotosPicker 视频选择入口，`.current` 编码与文件 Transferable，保留系统提供文件中的视频轨；导入副本保存到片库，记录只存相对文件名以承受容器路径变化。未新增相册全量读写权限或 PHAsset 枚举。新增 MV-HEVC 轨特征识别与 RealityKit VideoPlayerComponent 原生双眼播放，在窗口/影院使用同一播放器时间线，避免单眼纹理提取和静默 VLC 降级。

真机编译、安装通过。`Photos/product.json` 的 27 项检查通过，包括新增的四项：导入后字节不变、容器迁移后可读取、删除 App 副本保留原文件、放弃的暂存文件被清理；其余 23 项为片库、音轨字幕和续播回归。`Photos/routing.json` 自动引擎回退回归通过。

这些自动测试使用自有测试视频并直接执行导入存储逻辑，不冒充点击了系统相册。系统选择器、真实相册文件与空间视频立体感由下面的佩戴验收覆盖；iCloud 下载仍须专项验证。开发版空间播放报告只记录检测结果、RealityKit 实际 viewingMode 和运行环境，不包含视频内容、文件名或相册标识。

模拟器目标也已编译、安装成功，并向模拟器相册加入自有 12 秒测试视频；远程界面操作未成功打开选择器，因此不将这次尝试记为系统相册 UI 验收。iCloud 下载与大文件导入还需专项测试。

2026-10-31 用户完成真机佩戴验收：

- 普通视频：通过「打开影片 → 从相册导入」选择、导入，画面与声音正常，返回片库后继续观看正常；用户反馈「都正常」。
- 空间视频：从相册导入后显示「空间视频 · 原生 3D」，立体感与声音正常，进入影院及返回窗口画面正常；用户反馈「全部正常」。
- `Photos/spatial-window.json` 的真机报告时间为 2026-10-31T11:08:07Z，检测到多视图轨，RealityKit 实际 `viewingMode=stereo`，未使用单眼纹理输出。与上述佩戴反馈相互印证。
- 本次未取得 `spatial-cinema.json`；影院结论来自用户实际观看确认，不记作自动报告通过。未扩展为所有相册编码、iCloud 下载或长时间播放均已验证。
