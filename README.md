# Vision Player

**许可证：[MIT](LICENSE)** · 第三方依赖、模型及素材遵循[各自许可证](Docs/THIRD_PARTY.md)。

为 Apple Vision Pro 开发的原生视频播放器，支持普通 2D、左右 / 上下 3D、原生空间视频，以及在设备上运行的实验性 AI 2D 转 3D。

项目使用 SwiftUI、RealityKit、Metal 和 Core ML 构建观影体验，通过 Apple AVPlayer 与 VideoLAN VLCKit 提供双引擎播放。你可以在窗口中观看，也可以进入空间影院，调整屏幕并隐藏播放控件。

[开始构建](#快速开始) · [功能与格式](#功能与格式) · [开发规划](Docs/ROADMAP.md) · [测试记录](Docs/VALIDATION.md) · [反馈问题](https://github.com/friendmine/visionproplayer/issues)

目前处于持续开发阶段。最近完成真机验收的版本为 [`0.8ok`](https://github.com/friendmine/visionproplayer/tree/0.8ok)，包含 VLC 本地 AI 立体播放的卡顿优化。版本标签及测试结果不代表所有片源的兼容性保证。

## 功能与格式

- **双引擎播放**：自动选择 Apple 原生或 VLC 引擎；普通影片在原生播放明确失败时，自动尝试 VLC。
- **片库与续播**：本地文件、相册导入、网络地址、搜索、收藏、最近观看，以及每部影片独立的进度和画面设置。
- **立体视频**：Full / Half SBS（左右）、Full / Half OU（上下），支持交换左右眼。
- **原生空间视频**：识别 MP4 / MOV 中的 MV-HEVC 空间视频，使用 Apple 原生双眼播放，支持窗口与影院。
- **AI 立体效果**：本机深度估计、立体强度、出屏程度、比例保护，以及「自然」「突出前景」「自定义」预设；可保存新影片的默认效果。
- **空间影院与专注观影**：现实 / 暗色环境，可调整屏幕大小、距离和高度；无操作时隐藏控件，点选影片唤回。
- **播放控制**：进度拖动预览、前后跳转、每部影片的音轨与字幕选择记忆、SRT / WebVTT 外挂字幕、字幕时间偏移、字号和位置。
- **观看历史管理**：清除最近观看和续播进度，保留影片、收藏及画面设置。

### 播放支持范围

| 内容 | 当前支持情况 |
|---|---|
| 普通 2D 视频 | MP4、MOV、MKV、AVI 等容器；实际兼容性取决于内部编码和所用引擎 |
| H.264 / H.265 | 已验证部分 MP4 / MKV 样片；H.265 验证主要覆盖 1080p SDR、Main 8-bit |
| 左右 3D（SBS） | Full SBS 与 Half SBS，Apple 原生和 VLC 均有真机验证 |
| 上下 3D（OU / Top-Bottom） | 全高与半高，Apple 原生和 VLC 均有真机验证 |
| MV-HEVC 空间视频 | Apple 原生路径；已验证从相册导入普通视频和空间视频 |
| 网络视频 | HTTP(S) 视频直链及引擎可播放的流地址；优先使用 HTTPS |
| 字幕 | SRT / WebVTT 外挂文本字幕；内嵌字幕支持受引擎和播放模式限制 |

自动路由优先为 MKV、AVI、WebM、TS、M2TS、FLV、WMV 选择 VLC，其他扩展名优先使用原生引擎。路由规则不代表这些格式的所有编码组合都已测试。原生空间视频解码失败时会显示错误，不自动降为 VLC 单眼播放。

## 快速开始

### 开发环境

- Apple Silicon Mac；当前项目配置面向 `arm64`。
- Xcode，包含 visionOS SDK；运行模拟器还需安装对应运行时。本项目的开发验证环境为 Xcode 27。
- Python 3.9 或更新版本，用于准备模型和生成工程。
- 首次构建需要网络连接，以下载 VLCKit 和 Core ML 模型。
- 真机测试需要已配对、开启开发者模式的 Vision Pro，以及 Xcode 中可用的签名团队。

工程最低部署目标为 **visionOS 2.0**，近期真机验收使用 **visionOS 27.2**；较旧系统的运行兼容性尚未完成验证。模拟器可用于界面和基础流程开发，双眼立体效果需要真机确认。

### 1. 获取源码与模型

```sh
git clone https://github.com/friendmine/visionproplayer.git
cd visionproplayer

# 可选：使用已完成验收的版本
# git checkout 0.8ok

python3 Scripts/prepare_depth_model.py
```

模型脚本会下载、校验并编译 Depth Anything V2 Small F16 的 Apple Core ML 转换版本，下载约 44 MB。生成文件位于 `.build/Models/`，构建时打包进 App，模型权重不存放在 Git 中。当前工程要求先完成此步骤，即使暂时只使用普通播放。

### 2. 在 Xcode 中运行

```sh
open VisionProPlayer.xcodeproj
```

1. 等待 Swift Package Manager 解析固定版本的 VLCKit。初次二进制下载约 880 MiB，解压和构建还需额外磁盘空间。
2. 选择 `VisionProPlayer` scheme 和 Vision Pro 模拟器或实体设备。
3. 真机运行时，在 **Signing & Capabilities** 选择自己的 Team，并按需使用自己的 Bundle Identifier。
4. 构建并运行。

仓库已包含 Xcode 工程，首次构建无需重新生成。若提示模型文件缺失，请先运行模型准备脚本。

也可从命令行构建模拟器版本：

```sh
./Scripts/build.sh
```

该脚本只执行构建，不会自动启动模拟器或安装到头显。

## 使用方法

### 打开影片

在片库选择「打开影片」，打开本地文件、从相册导入，或添加网络视频地址。默认使用自动引擎选择；需要排查兼容性时，可手动切换引擎并重新打开影片。

相册导入通过系统 PhotosPicker 选择指定视频，iCloud 内容可能需要先下载。导入后 App 保存独立副本，移除此副本不会删除原相册视频。本地文件通过访问书签重新打开，移除片库记录不会删除原文件。

### 观看 3D 或空间视频

在「画面 → 影片格式」选择与片源对应的布局：

| 布局 | 常见示例 | 每眼显示 |
|---|---|---|
| 左右 3D · 全宽 | 3840 × 1080 | 左右各 1920 × 1080 |
| 左右 3D · 半宽 | 1920 × 1080 | 每眼 960 × 1080，播放时恢复横向比例 |
| 上下 3D · 全高 | 1920 × 2160 | 上下各 1920 × 1080 |
| 上下 3D · 半高 | 1920 × 1080 | 每眼 1920 × 540，播放时恢复纵向比例 |

表格用于解释布局，不能仅凭分辨率判断影片格式。默认左侧 / 上侧为左眼，眼序相反时启用「交换左右眼」。部分明确标注布局的文件名可自动识别，其他片源请手动选择。

原生空间视频会自动识别，无需选择 SBS / OU，也无需开启 AI 转换。

### 开启 AI 立体

打开普通 2D 影片，在窗口的「画面」或影院的「立体效果」中开启 AI 立体：

- **自然**：立体强度 35%、出屏程度 0%，开启比例保护。
- **突出前景**：立体强度 35%、出屏程度 60%，开启比例保护。
- **自定义**：手动调整强度、出屏程度或比例保护后，保存当前组合。

暂停时也可调整并对比效果。每部影片记住自己的参数；点「设为新影片默认效果」后，新加入片库的影片会继承这组参数，已有影片保持各自设置。AI 默认关闭，需要主动开启。

AI 深度推理在设备上完成，不通过远程推理服务处理视频。效果为实时合成，不会将原片改写或导出为空间视频文件。

### 影院、字幕与专注观影

点击「影院」进入空间观影，调整屏幕宽度、距离和高度，退出后继续在窗口播放。窗口和影院均可拖动进度条查看预览，并在「字幕与音轨」中切换可用轨道或导入外挂字幕。

音轨、内嵌/外挂字幕选择和「关闭字幕」状态按影片保存，重开及进出影院时恢复。在「字幕与音轨 → 播放兼容性」切换引擎时，会按轨道名称和语言匹配；多个候选无法可靠区分时保留原选择并提示。VLC 纹理路径暂不显示内嵌字幕，返回支持的窗口模式后恢复；外挂文字字幕仍可使用。诊断样片的选择不会修改片库影片的偏好。

专注观影默认开启：播放中约 3 秒无操作后隐藏控件和窗口背景，字幕保留。点选影片可唤回控制；暂停、拖动或调整设置时保持显示。可在「设置 → 观看 → 专注观影」关闭。

## 已知限制

- **AI 立体仍属实验功能**。单目深度不是实测距离；头发、透明物体、快速运动和遮挡边缘可能产生深度错误或形变，部分场景仍可能有中央凹陷感。比例保护会收敛部分局部景深，当前没有生成式补洞。
- **自定义立体渲染采用 SDR 路径**。VLC 纹理输出最长边限制为 1920；HDR / Dolby Vision 保真、4K/60fps、长时间发热与稳定性尚需单独验证。
- **字幕能力随路径不同**。VLC 的自定义纹理路径（SBS、上下 3D、AI、影院）目前使用外挂文本字幕，内嵌字幕暂不启用。图片字幕并未全面支持。暂不支持或无法匹配的轨道会保留原选择并显示提示，不会用临时回退覆盖已保存的偏好。
- **尚未实现**蓝光 MVC 解码后的立体播放、180° / 360° 环绕视频，以及独立的 SMB / WebDAV 服务器浏览器。
- **特殊片源仍需验证**。打包立体视频的旋转元数据、非方形像素，以及未测试的容器 / 编码组合可能显示异常。

详细兼容性、已知问题及测试条件见 [验证记录](Docs/VALIDATION.md)。

## 开发与验证

```text
VisionProPlayer/
├── App/          应用入口与窗口配置
├── Views/        片库、播放控制、设置与影院
├── Library/      媒体记录、文件访问、偏好与持久化
├── Playback/     引擎路由、播放会话、字幕与诊断
├── Bridge/       libVLC 封装与视频帧传递
├── Rendering/    Core ML 深度估计、Metal 合成与 RealityKit 显示
└── Resources/    材质、图标、许可文本与基础测试片
Scripts/          构建、模型准备、样片生成与验证脚本
Docs/             开发规划、测试记录与第三方信息
```

核心入口为 [PlayerModel.swift](VisionProPlayer/Playback/PlayerModel.swift)、[VPPVLCSession.m](VisionProPlayer/Bridge/VPPVLCSession.m) 和 [StereoRenderer.swift](VisionProPlayer/Rendering/StereoRenderer.swift)。

添加源码或资源后，可执行以下命令更新 Xcode 工程；生成器只依赖 Python 标准库，无需 XcodeGen。它会重新生成工程配置，请注意保留自己的签名设置。

```sh
python3 Scripts/generate_project.py
```

VLCKit 固定到提交 `2e0868f5ed40fe59cd92f377645fdcc260c6e759`。请保持工程与 `Package.resolved` 的依赖一致；升级 libVLC 4 时需要检查桥接 API 并重新验证播放路径。

Debug 构建在「设置 → 诊断与测试」中提供基础样片和检查入口。仓库包含基础合成样片，其他 Big Buck Bunny 兼容性片段需按相应脚本准备，并放入设备的 App Documents 目录。样片生成使用 FFmpeg，部分脚本还需 Pillow；它们不是 App 的运行依赖。

- [开发规划](Docs/ROADMAP.md)：当前已完成事项。
- [验证记录](Docs/VALIDATION.md)：测试条件、结果与复现限制。
- [VLC AI 帧间隔对照](Docs/ValidationResults/VLCCadence/README.md)：短测方法、原始记录与汇总。
- [第三方来源](Docs/THIRD_PARTY.md)：依赖固定版本、模型校验值及样片署名。

## 参与与反馈

欢迎通过 [Issues](https://github.com/friendmine/visionproplayer/issues) 反馈问题或提出功能建议，也欢迎提交范围明确的 Pull Request。

反馈播放问题时，请尽量提供：

- App 标签或提交号、visionOS 版本，以及真机或模拟器环境。
- 使用的引擎、窗口或影院模式、2D / 原片 3D / AI 立体设置。
- 容器、视频编码、分辨率、帧率，以及最短复现步骤和时间位置。
- 错误提示；如需提供片源，请优先使用可公开分享的短样片，移除私人路径、访问令牌等信息。

提交改动时，请说明解决的问题与验证方式。涉及每眼渲染、深度或播放时序的改动，应区分模拟器检查与真机佩戴结果；只有模拟器结果时，请明确注明。

## 许可与致谢

本项目原创代码与文档采用 [MIT License](LICENSE)。允许使用、修改、分发及商业使用，分发时需保留版权声明和许可文本。

第三方库、模型和素材继续遵循各自许可证：VLCKit / libVLC 为 LGPL 2.1 或更新版本，Depth Anything V2 Small 模型为 Apache 2.0，Big Buck Bunny 测试素材为 CC BY 3.0。项目的 MIT 许可证不替代这些许可。分发包含第三方组件的 App 时，还需遵守其署名、许可文本、对应源码提供及适用的修改 / 重新链接要求，详见 [第三方说明](Docs/THIRD_PARTY.md)。

感谢 [VideoLAN VLCKit](https://github.com/videolan/vlckit)、[Depth Anything V2](https://github.com/DepthAnything/Depth-Anything-V2)、Apple 的 Core ML 模型转换，以及 Blender Foundation 的 Big Buck Bunny 测试素材。依赖、模型和样片的来源与许可记录见 [THIRD_PARTY.md](Docs/THIRD_PARTY.md)。
