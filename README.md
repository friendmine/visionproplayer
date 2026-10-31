# Vision Player Lab

原生 visionOS 播放器验证工程：Apple AVPlayer / AVKit + 官方 VLCKit 4。

## 打开和运行

1. 用 Xcode 打开 `VisionProPlayer.xcodeproj`，选择 `VisionProPlayer` scheme。
2. 等待 Swift Package 解析官方 VLCKit。初次下载约 880 MiB，展开后占用更多空间。
3. 选择 Apple Vision Pro 模拟器并运行；真机运行需在 Signing & Capabilities 选择自己的开发团队。
4. 首页提供 **2D 测试、MKV 测试、SBS · 原生、SBS · VLC** 四个入口。
5. **真实 3D 短片** 菜单可播放已传入 Documents 的 Big Buck Bunny 60 秒立体片段，分别选择原生 MP4 或 VLC MKV；自动使用 Full SBS。片源与署名见 `Docs/THIRD_PARTY.md`。

当前最低部署版本为 visionOS 2.0。开发和编译使用 Xcode 27 / visionOS 27 SDK；旧版本运行兼容性尚未验证。

已在 visionOS 27.0.1 的实体 Vision Pro 上完成签名安装，并通过初始四条内置播放路径及连续切换的自动检查。用户确认 2D 可以观看，并在换用三球景深片后分别确认原生 SBS MP4 和 VLC SBS MKV 都有前后层次；新版 VLC 自动复测也通过。具体证据及复现限制见 `Docs/VALIDATION.md`。

另外已将官方 Big Buck Bunny 立体版制作成一分钟 Full SBS 片段并传入真机：原生 MP4 与 VLC MKV 自动检查通过，用户观看后确认立体感和声音正常。

也可执行：

```sh
./Scripts/build.sh
```

## 已实现

- 本地文件选择、HTTP(S) 地址输入、自动或手动引擎选择。
- 原生普通视频使用全屏 `AVPlayerViewController`。
- MKV 等扩展名自动选择 VLCKit；普通格式默认原生。**自动选择只是扩展名策略，不是完整媒体能力探测，也不会自动失败重试。**
- VLCKit 平面播放直接嵌入 UIView；自定义 SBS 使用官方框架导出的 libVLC C API。
- SBS 的原生和 VLC 两种来源共用 RealityKit 左右眼材质；支持 Full SBS、Half SBS、交换左右眼。
- 播放 / 暂停、进度跳转、状态和错误提示；后台暂停，关闭时释放播放资源及文件访问权限。
- 内置四段自主生成的 12 秒测试片，无需下载外部影片。

| 按钮 | 文件内容 | 路径 |
|---|---|---|
| 2D 测试 | MP4 / H.264 / AAC / 960×540 | AVPlayer → AVKit |
| MKV 测试 | MKV / H.264 / FLAC / 960×540 | libVLC → UIView |
| SBS · 原生 | MP4 / H.264 / AAC / 1280×360 Full SBS | AVPlayerItemVideoOutput → RealityKit |
| SBS · VLC | MKV / H.264 / AAC / 1280×360 Full SBS | libVLC vmem → RealityKit |

2D 测试片含移动彩条和低音量测试音。SBS 测试片为原创景深场景：金球在近处、青球在中间、紫球在远处；使用两个平行视点及离轴投影，屏幕平面位于中景。旧版 SBS 彩条及 LEFT / RIGHT 大字已替换，避免把眼别标记的重影误当成播放错误。

播放 SBS 后可点「左右眼检查」，分别闭眼观察纯色：左眼应为红色，右眼应为蓝色，绿色代表单眼渲染回退。此模式独立于视频纹理，关闭后恢复影片；它不证明视频裁切本身正确。

## SBS 的边界

这是真正的每眼纹理选择：每帧从拼接视频提取左、右半幅，通过 Shader Graph 的 Camera Index Switch 分别送到左右眼，不是把拼接画面放大成普通屏幕。模拟器的单眼画面不能证明立体感，必须真机检查。

当前 SBS 为 **SDR 验证路径**：

- 原生：AVPlayerItemVideoOutput 请求 BGRA 帧，Core Image 转换至两张线性 RGBA16Float GPU 纹理，通过 LowLevelTexture 更新。
- VLC：明确使用软件解码，输出 BGRA，最长边限制为 1920；内存中只保留最新待显示帧。音频由 VLC 自身播放和计时。
- GPU 最多保留一组提交中的立体帧，慢时丢帧，不积压视频帧。
- Full SBS 的显示宽高比是输入宽高比的一半；Half SBS 使用输入宽高比。支持常规方形像素、水平编码的 SBS；旋转元数据、非方形像素暂未处理。
- 尚未实现 HDR / Dolby Vision 保真、上下格式、蓝光 MVC、180° / 360°、外置字幕和音轨选择 UI。SBS 内嵌字幕也未做每眼重新排版。
- 自定义纹理路径不是 `VideoPlayerComponent(avPlayer:)`；后者不能直接接收这个 VLC 播放器。

原生空间视频可尝试系统全屏播放器，但本工程没有附带 MV-HEVC 测试片，也没有将其列为已验证能力。

HTTP 地址可能受 Apple 网络安全策略限制，优先使用 HTTPS；本项目没有全局关闭系统网络安全限制。

## 源码结构

- `App/`：应用入口、窗口和配置。
- `Playback/PlayerModel.swift`：播放会话、切换、生命周期与状态。
- `Playback/PlaybackOptions.swift`：引擎路由和立体布局。
- `Bridge/VPPVLCSession.m`：官方 VLCKit 内的 libVLC 4 接口封装、异步停止、帧缓冲。
- `Rendering/StereoRenderer.swift`：同一时间戳的两眼裁切、GPU 上传和 RealityKit 渲染。
- `Resources/StereoMaterial.usda`：每眼材质。
- `Views/`：文件选择、测试入口、控制栏和播放器视图。

上述目录均在 `VisionProPlayer/` 下。

## 依赖与复现

依赖固定到 VideoLAN 官方仓库提交 `2e0868f5ed40fe59cd92f377645fdcc260c6e759`，包引用 2026-09-29 的 VLCKit 4 开发版二进制；由 Swift Package Manager 验证 SHA-256。

- 官方仓库：https://github.com/videolan/vlckit
- 不要直接切换到 master；libVLC 4 的 C API 仍会变化。
- `Scripts/generate_project.py` 用 Python 标准库生成项目，不需要安装 XcodeGen。添加源文件后重新运行即可；自定义签名配置后不要无意覆盖项目。
- `Scripts/generate_samples.sh` 需要本机 ffmpeg 和 Python Pillow，仅用于重新生成测试片，不是 App 运行依赖。`Scripts/generate_stereo_sample.py` 可单独生成 SBS 演示片。
- Debug 构建支持 `--smoke 2d|mkv|sbs-native|sbs-vlc|lifecycle` 开发验证参数；Release 不执行此逻辑。

详见 `Docs/VALIDATION.md` 的实际验证结果和真机检查表。第三方信息见 `Docs/THIRD_PARTY.md`。
