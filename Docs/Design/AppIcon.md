# Vision Player 图标

设计日期：2026-11-04。

白色悬浮播放键、冰蓝光学玻璃银幕与深蓝背景。采用两层 1024×1024 visionOS 图标：前层保留透明度，后层不透明；圆形裁切由系统完成。使用内置 image_gen 生成，两张原图仅通过 sips 缩放至资源要求尺寸，未手动改绘。

项目资源：
- `VisionProPlayer/Resources/Assets.xcassets/AppIcon.solidimagestack/Front.solidimagestacklayer/Content.imageset/front.png`
- `VisionProPlayer/Resources/Assets.xcassets/AppIcon.solidimagestack/Back.solidimagestacklayer/Content.imageset/back.png`

项目生成脚本将 xcassets 作为整体编译，不将内部 PNG/JSON 重复打包；Debug/Release 均指定 AppIcon。资源结构参考当前 Xcode 的 visionOS Foveated Streaming App 模板；设计要求参考 [Apple 图标指南](https://developer.apple.com/design/human-interface-guidelines/app-icons)。

## 生成提示词（原文）

### 前景（transparent_background=true）

Use case: logo-brand. Asset type: actual foreground artwork for a visionOS spatial video player app icon, not a mockup. Create one premium, exceptionally clean 1024x1024 square icon foreground on a genuinely transparent background. A bold luminous pearl-white right-pointing play triangle floats just in front of a single softly rounded widescreen glass frame. The frame has substantial polished optical-glass edges with restrained ice-blue and cyan refraction, a subtle darker blue back edge slightly offset to suggest stereo depth. The white triangle is the strongest and simplest feature. Front-facing composition with only a tiny perspective hint, no dramatic tilt. Everything centered and comfortably within the central 68 percent of the square; broad transparent margins so the OS can apply its circular mask. Sophisticated quiet cinematic material rendering, crisp silhouette, smooth surfaces, no fine decorative details. No outer app tile, no circle badge, no opaque backdrop, no text, no letters, no watermark, no device, no scene, no floating particles, no long cast shadow. Deliver only this finished icon foreground at high resolution with real alpha.

### 背景（transparent_background=false）

Use case: logo-brand. Asset type: background layer only for a visionOS video player app icon. Create a square full-bleed opaque 1024x1024 background, extremely smooth deep midnight-blue optical material. Very subtle broad cool blue illumination at the center, darker navy toward the perimeter, with a gentle restrained cyan-blue ambient glow near the lower center. Almost plain, elegant, dark enough for a pearl-white and ice-blue foreground to read strongly. No object, no symbol, no triangle, no glass frame, no text, no border, no rounded corners, no circle mask, no vignette that goes fully black, no texture grain, no stars or particles. This is solely the quiet opaque square underlay, not a complete icon.


## 验证

Debug 真机构建成功；编译产物包含 AppIcon 的两层 1024×1024 资源，后层不透明、前层透明，Info.plist 指定 AppIcon。已安装至 Vision Pro（2026-11-04）；系统主屏的实际显示仍待用户查看。原始摘要见 `Docs/ValidationResults/AppIcon/`。
