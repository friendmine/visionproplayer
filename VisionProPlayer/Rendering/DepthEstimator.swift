@preconcurrency import CoreML
@preconcurrency import CoreImage
@preconcurrency import CoreVideo
import Foundation

// Pixel buffers are retained, read-only after publication, and processed serially.
struct DepthInput: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let requestID: UUID
    let revision: Int
    var subjectAccuracy: Bool = false
}
struct EstimatedDepth: @unchecked Sendable {
    let buffer: CVPixelBuffer
    // Retain the exact immutable decoded frame that produced this depth.
    // The reusable model input must never serve as a motion reference.
    let source: CVPixelBuffer
    let lower: Float
    let upper: Float
    let resetHistory: Bool
    let milliseconds: Double
    var contentRegion = SIMD4<Float>(0, 0, 1, 1)
    var subjectAccuracy: Bool = false
}

actor DepthEstimator {
    private var model: MLModel?
    private var inputBuffer: CVPixelBuffer?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var previousID: UUID?
    private var previousRevision = -1
    private var previousAccuracy = false
    private var lower: Float = 0
    private var upper: Float = 1

    func prepare() throws {
        guard model == nil else { return }
        guard let url = Bundle.main.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlmodelc") else {
            throw DepthError.modelMissing
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        model = try MLModel(contentsOf: url, configuration: config)
        guard let constraint = model?.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else {
            throw DepthError.invalidOutput
        }
        let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard CVPixelBufferCreate(nil, constraint.pixelsWide, constraint.pixelsHigh,
            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &inputBuffer) == kCVReturnSuccess else {
            throw DepthError.invalidOutput
        }
    }

    func estimate(_ input: DepthInput) throws -> EstimatedDepth {
        try Task.checkCancellation()
        try prepare()
        guard let model, let inputBuffer else { throw DepthError.modelMissing }
        let began = ProcessInfo.processInfo.systemUptime
        let width = CVPixelBufferGetWidth(inputBuffer), height = CVPixelBufferGetHeight(inputBuffer)
        let image = CIImage(cvPixelBuffer: input.buffer)
        let geometry = DepthInferenceGeometry(source: image.extent.size, canvas: CGSize(width: width, height: height))
        let region = input.subjectAccuracy ? geometry.normalizedContent : SIMD4<Float>(0, 0, 1, 1)
        let scaled = input.subjectAccuracy ? geometry.image(image)
            : image.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / image.extent.width,
                                                     y: CGFloat(height) / image.extent.height))
        context.render(scaled, to: inputBuffer, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: colorSpace)
        // The stream checks every offered video frame, including those skipped
        // by inference. Do not detect cuts again between sparse model inputs:
        // their larger motion used to trigger additional false resets.
        let reset = previousID != input.requestID || previousRevision != input.revision || previousAccuracy != input.subjectAccuracy
        let prediction = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: inputBuffer)]))
        try Task.checkCancellation()
        guard let depth = prediction.featureValue(for: "depth")?.imageBufferValue else { throw DepthError.invalidOutput }
        let values = try Self.depthSamples(depth, region: region).filter { $0.isFinite }.sorted()
        guard values.count > 20 else { throw DepthError.invalidOutput }
        let low = values[values.count / 20], high = max(low + 0.0001, values[values.count * 19 / 20])
        lower = reset ? low : lower * 0.85 + low * 0.15
        upper = reset ? high : upper * 0.85 + high * 0.15
        previousID = input.requestID; previousRevision = input.revision; previousAccuracy = input.subjectAccuracy
        return EstimatedDepth(buffer: depth, source: input.buffer, lower: lower, upper: max(lower + 0.0001, upper),
            resetHistory: reset, milliseconds: (ProcessInfo.processInfo.systemUptime - began) * 1000,
            contentRegion: region, subjectAccuracy: input.subjectAccuracy)
    }

    static func lumaSamples(_ buffer: CVPixelBuffer) -> [Float] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return [] }
        var result: [Float] = []
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for gy in 0..<DepthSceneChange.rows {
            for gx in 0..<DepthSceneChange.columns {
                // Sample a small area, not one aliased pixel of a moving texture.
                var sum: Float = 0
                for sy in 0..<3 { for sx in 0..<3 {
                    let x = min(width - 1, (gx * 6 + sx * 2 + 1) * width / (DepthSceneChange.columns * 6))
                    let y = min(height - 1, (gy * 6 + sy * 2 + 1) * height / (DepthSceneChange.rows * 6))
                    let p = y * stride + x * 4
                    sum += (Float(base[p]) + Float(base[p+1]) * 2 + Float(base[p+2])) / 1020
                }}
                result.append(sum / 9)
            }
        }
        return result
    }

    static func depthSamples(_ buffer: CVPixelBuffer, region: SIMD4<Float> = SIMD4(0, 0, 1, 1)) throws -> [Float] {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_OneComponent16Half || format == kCVPixelFormatType_OneComponent32Float else {
            throw DepthError.invalidOutput
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw DepthError.invalidOutput }
        var result: [Float] = []
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let x0 = max(0, Int(ceil(Float(w) * region.x))), x1 = min(w, Int(floor(Float(w) * (region.x + region.z))))
        let y0 = max(0, Int(ceil(Float(h) * region.y))), y1 = min(h, Int(floor(Float(h) * (region.y + region.w))))
        for y in stride(from: y0, to: y1, by: 12) {
            let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer))
            for x in stride(from: x0, to: x1, by: 12) {
                result.append(format == kCVPixelFormatType_OneComponent32Float
                    ? row.assumingMemoryBound(to: Float.self)[x]
                    : Float(Float16(bitPattern: row.assumingMemoryBound(to: UInt16.self)[x])))
            }
        }
        return result
    }

    enum DepthError: LocalizedError {
        case modelMissing, invalidOutput
        var errorDescription: String? {
            switch self {
            case .modelMissing: "未找到深度模型，请运行 Scripts/prepare_depth_model.py 后重新编译。"
            case .invalidOutput: "深度模型的输入或输出格式不符合预期。"
            }
        }
    }
}

/// One prediction in flight, no queued frames. Display uses only a recent depth
/// from this request/seek/scene; old results cannot overwrite a new scene.
@MainActor
final class DepthStream {
    struct Result {
        let depth: EstimatedDepth
        let capturedAt: Double
    }
    private let estimator: DepthEstimator
    private let requestID: UUID
    private let onPrediction: (Double) -> Void
    private let onSceneReset: () -> Void
    private var job: Task<Void, Never>?
    private var token = 0
    var generation: Int { token }
    private var revision = -1
    private var subjectAccuracy = false
    private var signature: [Float] = []
    private(set) var latest: Result?
    private(set) var version = 0
    private(set) var error: String?

    init(estimator: DepthEstimator, requestID: UUID, onSceneReset: @escaping () -> Void = {}, onPrediction: @escaping (Double) -> Void) {
        self.estimator = estimator; self.requestID = requestID; self.onPrediction = onPrediction; self.onSceneReset = onSceneReset
    }
    func reset(revision: Int) {
        self.revision = revision; token += 1; latest = nil; signature = []; version += 1
    }
    func offer(_ buffer: CVPixelBuffer, revision: Int, subjectAccuracy: Bool = false) {
        if self.revision != revision || self.subjectAccuracy != subjectAccuracy {
            self.subjectAccuracy = subjectAccuracy
            reset(revision: revision)
        }
        let newSignature = DepthEstimator.lumaSamples(buffer)
        if !signature.isEmpty, DepthSceneChange.detected(previous: signature, current: newSignature) {
            token += 1; latest = nil; version += 1
            onSceneReset()
        }
        signature = newSignature
        guard job == nil else { return }
        let submittedToken = token
        let capturedAt = ProcessInfo.processInfo.systemUptime
        let input = DepthInput(buffer: buffer, requestID: requestID, revision: submittedToken, subjectAccuracy: subjectAccuracy)
        job = Task { [weak self, estimator] in
            do {
                let result = try await estimator.estimate(input)
                guard let self else { return }
                self.job = nil
                guard !Task.isCancelled, self.token == submittedToken else { self.version += 1; return }
                self.latest = Result(depth: result, capturedAt: capturedAt)
                self.version += 1
                self.onPrediction(result.milliseconds)
            } catch {
                guard let self else { return }
                self.job = nil
                if !Task.isCancelled, self.token == submittedToken { self.error = error.localizedDescription }
            }
        }
    }
    func cancel() { token += 1; job?.cancel(); latest = nil }
}
