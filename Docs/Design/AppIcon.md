# Vision Player 图标

更新日期：2026-11-06。

新版采用深靛蓝背景、青蓝光学圆环、银白播放符号。去掉原版厚重的玻璃矩形框，将主体、圆环和背景拆为三个层次，供 visionOS 呈现层间视差。图形保持正面构图和宽裕边距，圆形遮罩交给系统。

使用内置 image_gen 生成三张素材，保留生成的透明度；仅通过 sips 缩放至 1024×1024。前景与中景透明、背景不透明。AppIcon-preview.png 是实际资源的静态叠加及圆形遮罩，包含 400、80、48、32 像素大小检查，不模拟头显高光和动态视差。原版图标可从 Git 历史恢复。

## 项目资源

- `VisionProPlayer/Resources/Assets.xcassets/AppIcon.solidimagestack/Front.solidimagestacklayer/Content.imageset/front.png`
- `VisionProPlayer/Resources/Assets.xcassets/AppIcon.solidimagestack/Middle.solidimagestacklayer/Content.imageset/middle.png`
- `VisionProPlayer/Resources/Assets.xcassets/AppIcon.solidimagestack/Back.solidimagestacklayer/Content.imageset/back.png`

项目沿用 AppIcon 配置。参考 [Apple 图标指南](https://developer.apple.com/design/human-interface-guidelines/app-icons)。

## 生成提示词（内置工具，原文）

### front

Use case: logo-brand. Asset type: production foreground layer for a visionOS spatial movie player icon. Create a square 1024x1024 PNG with a genuinely transparent background. Exactly one beautifully proportioned right-pointing PLAY triangle, optically centered, occupying central 42 percent width and 48 percent height, with generously softly rounded corners. Front facing, symmetrical upright, no tilt. Pearl silver-white satin ceramic with a very subtle pale cyan reflection along its lower bevel, slim dimensional beveled edge visible on lower-right, elegant premium industrial design. The main face is bright clean white with gentle restrained shading, crisp silhouette at small size. Plenty of completely empty transparent margin. No frame, no ring, no disk, no outer icon tile, no backdrop, no text, no decorative streaks, no glow outside the object, no drop shadow, no watermark. It will float above a separate cyan halo and dark indigo background. Deliver only the single finished triangle with real alpha, not a presentation or mockup.

### middle

Use case: logo-brand. Asset type: middle transparent layer for a premium visionOS spatial movie player icon. Square 1024x1024 canvas, real transparent background. Exactly one centered slender circular optical halo, front-facing circular silhouette outer diameter 72 percent canvas width, perfectly centered. Ring band only 3 percent canvas width thick, empty transparent center and broad transparent outer margins. Polished cyan-turquoise glass with restrained cobalt-blue shading on lower left and a soft ice-blue specular rim upper right. Subtle dimensional bevel suggests a precise machined optical lens rim, very clean and simple, sophisticated, satin instead of blinding neon. Keep light confined near the ring; no large bloom. This layer sits behind a separate pearl-white play triangle, but DO NOT include that triangle here. No interior disk, no opaque fill, no backdrop, no additional rings, no text, no stars, no particles, no shadows, no rectangular tile. Deliver finished transparent halo layer only.

### back

Use case: logo-brand. Asset type: opaque background layer ONLY for a visionOS spatial cinema app icon. Square 1024x1024 full-bleed, completely opaque edge to edge. Exquisitely smooth deep midnight indigo surface, broad very subdued blue illumination in center, subtle dark violet shade near upper left and slightly lighter deep ocean blue near lower right. Quiet luxurious almost-solid gradient, dark enough for a white play symbol and cyan ring on separate layers. NO symbol, no triangle, no ring, no circle, no tile edges, no framing, no texture, no grain, no stars, no objects, no lens flare, no text, no transparency. Do not pre-mask or round the corners; the operating system supplies the circular mask. Deliver only the square dark background.

## 验证

2026-11-06：visionOS Debug 签名构建通过；编译后的 Assets.car 确认三层均为 1024×1024，前、中层透明，后层不透明。静态圆形预览与 80/48/32 像素缩略检查通过。构建仅有无 AppIntents 依赖的元数据提取提示。记录位于 `Docs/ValidationResults/AppIcon/Refresh-2026-11-06/`。本轮没有安装到头显，主屏动态图标观感待验收；旧目录中的两层图标报告属于 2026-11-04，不代表本次新版验收。

后续安装：2026-11-06 应用户要求覆盖安装至实体 Vision Pro，并正常启动成功。主屏动态图标观感仍待用户确认。
