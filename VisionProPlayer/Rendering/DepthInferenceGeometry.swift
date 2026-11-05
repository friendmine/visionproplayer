import CoreGraphics
import CoreImage

/// Maps the entire source into the fixed model canvas without changing shapes.
/// Edge extension supplies padding; only valid image pixels inform depth range.
struct DepthInferenceGeometry {
    let scale: CGFloat
    let content: CGRect
    let canvas: CGSize
    init(source: CGSize, canvas: CGSize) {
        self.canvas = canvas
        scale = min(canvas.width / source.width, canvas.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        content = CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                         width: size.width, height: size.height)
    }
    var normalizedContent: SIMD4<Float> {
        SIMD4(Float(content.minX / canvas.width), Float(content.minY / canvas.height),
              Float(content.width / canvas.width), Float(content.height / canvas.height))
    }
    func image(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: content.minX, y: content.minY))
            .clampedToExtent()
    }
}
