# Third-party dependencies

## VLCKit / libVLC

- Provider: VideoLAN
- Source: https://github.com/videolan/vlckit
- Pinned revision: `2e0868f5ed40fe59cd92f377645fdcc260c6e759`
- Binary referenced by that revision: `VLCKit-4.0-20260929-1631.zip`
- Expected SHA-256: `f37c8dbdd4427d1a3f5d75dc4b8bd1ae863cef4426f9a405a2fd1c5c9012f1fb`
- VLCKit repository license: LGPL 2.1 or later; consult the exact upstream COPYING and licenses of bundled components before redistribution.
- Binaries are fetched by Swift Package Manager; they are not checked into this repository.

This document records dependency provenance, not a determination that a particular distribution satisfies all third-party obligations.

## Depth Anything V2 Small

- Authors: Lihe Yang, Bingyi Kang, Zilong Huang, Xiaogang Xu, Jiashi Feng, Hengshuang Zhao.
- Upstream: https://github.com/DepthAnything/Depth-Anything-V2
- Apple Core ML conversion/model card: https://huggingface.co/apple/coreml-depth-anything-v2-small
- Download: https://ml-assets.apple.com/coreml/models/Image/DepthEstimation/DepthAnything/DepthAnythingV2SmallF16.mlpackage.zip
- Pinned archive SHA-256: `8e875979ec82fa46f292468a7567a520b2aa07c41008c32141f3396da05a4067`.
- Small model license: Apache 2.0. Full upstream license is retained in `Licenses/DepthAnythingV2-Apache-2.0.txt` and bundled as `DepthAnythingV2-License.txt`. Other model sizes have different licensing; this project only uses Small.
- `Scripts/prepare_depth_model.py` downloads, verifies and compiles the F16 package. Downloaded weights and compiled model remain in ignored `.build/Models/`; the compiled model is bundled into the app at build time. No model weights are committed to Git.
- Runtime metadata: BGRA image input 518×392; one-component Float16 depth image output 518×392. Uses Core ML CPU/Neural Engine, not a network inference service.
- Metal warping, temporal smoothing, scheduling and UI are project-authored; this does not reproduce or claim access to Apple's private spatial-photo conversion pipeline.

## Reference documentation

- Apple: https://developer.apple.com/documentation/visionos/displaying-a-stereoscopic-image-in-visionos
- Apple: https://developer.apple.com/documentation/avkit/adopting-the-system-player-interface-in-visionos
- Apple: https://developer.apple.com/documentation/shadergraph/realitykit/camera-index-switch-(realitykit)

The small StereoMaterial.usda graph is authored for this project using documented shader node identifiers. No Apple sample image assets are bundled.

## Synthetic media

The four bundled test clips are generated locally by Scripts/generate_samples.py and Scripts/generate_stereo_sample.py using FFmpeg test patterns, sine tones and a project-authored stereo depth scene. No downloaded film is bundled inside the app. FFmpeg and Pillow are development-time generators only.

## Downloaded Big Buck Bunny stereo test excerpt

- Original: Big Buck Bunny, © 2008 Blender Foundation / www.bigbuckbunny.org.
- Sunflower stereoscopic release: Janus Kristensen, 2013.
- Source: https://download.blender.org/demo/movies/BBB/bbb_sunflower_1080p_30fps_stereo_abl.mp4.zip
- License: Creative Commons Attribution 3.0, https://creativecommons.org/licenses/by/3.0/
- Original license statement: https://peach.blender.org/about/
- Changes: excerpt 00:20–01:20; above/below left-first stereo rearranged to Full SBS left-first; resized to 1920×540 (960×540 per eye); encoded H.264/AAC; MP4 and remuxed MKV.
- The full download is about 434 MB. Only the source prefix needed for this excerpt was retrieved and extracted; the remaining download was stopped. The derived 60-second files each passed complete decoding. The partial archive is explicitly named `.zip.partial`.
- Local files: `.build/TestMedia/BBB-SBS-60s.mp4`, `.mkv`, `BBB-SBS-60s-LICENSE.txt`. These are copied to the installed app's Documents directory, not added to its bundle.
- Attribution is included in the playback UI, media metadata, and the companion license text. Provenance and SHA-256 values are recorded in `ValidationResults/PhysicalDevice/bbb-source.json`.
- Reproduce from the official extracted stereo MP4 using `python3 Scripts/prepare_bbb_sample.py <source.mp4>`.

### H.265 and Half SBS compatibility excerpts

- Same source, authors and CC BY 3.0 license. Excerpt 00:20–00:50, 30 fps, AAC stereo audio.
- `BBB-HEVC-2D-30s`: original left-eye view, 1920×1080, H.265 Main 8-bit, MP4 (`hvc1`) and remuxed MKV.
- `BBB-H264-HalfSBS-30s` / `BBB-HEVC-HalfSBS-30s`: left-first Half SBS, 1920×1080 total, 960×1080 horizontally squeezed per eye. H.264 High / H.265 Main 8-bit respectively, MP4 and remuxed MKV. Playback restores each eye to 16:9.
- Reproduce using `python3 Scripts/prepare_compatibility_samples.py <source.mp4>`. Requires macOS FFmpeg with VideoToolbox HEVC, libx264 and stereo3d support. The script checks codec, profile, dimensions, pixel format, square pixels, duration and complete decoding of all six files.
- Files remain in `.build/TestMedia/` and device Documents. Attribution is present in the media metadata and UI; `compatibility-samples.json` accompanies the copied files. Provenance and hashes: `ValidationResults/PhysicalDevice/HEVCHalfSBS/fixtures.json`.
