import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import Metal

// Compare actual output pixels across AI, depth-unavailable fallback and zero
// strength. Include tagged video; the older warp fixture was untagged sRGB only.
let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
let library = try device.makeLibrary(source: String(contentsOfFile: "VisionProPlayer/Rendering/DepthStereo.metal", encoding: .utf8), options: nil)
let projector = try StereoReprojector(device: device, library: library)
let converter = VideoColorConverter(device: device)
func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
    d.storageMode = .shared; d.usage = [.shaderRead, .shaderWrite, .renderTarget]
    return device.makeTexture(descriptor: d)!
}
func pixels(_ t: MTLTexture) -> [Float] {
    var p = [UInt16](repeating: 0, count: t.width*t.height*4)
    p.withUnsafeMutableBytes { t.getBytes($0.baseAddress!, bytesPerRow: t.width*8, from: MTLRegionMake2D(0,0,t.width,t.height), mipmapLevel: 0) }
    return p.map { Float(Float16(bitPattern: $0)) }
}
var cases = 0
var worstError: Float = 0
func verify(_ buffer: CVPixelBuffer, name: String, uniform: Bool = false) throws {
    let scale = min(1.0, 1920.0 / Double(max(CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))))
    let w = max(2, Int(Double(CVPixelBufferGetWidth(buffer))*scale)), h = max(2, Int(Double(CVPixelBufferGetHeight(buffer))*scale))
    let baseline = texture(.rgba16Float,w,h), left = texture(.rgba16Float,w,h), right = texture(.rgba16Float,w,h)
    let depth = texture(.r32Float,17,13)
    let d = (0..<221).map { Float($0 % 17) / 16 }
    d.withUnsafeBytes { depth.replace(region: MTLRegionMake2D(0,0,17,13), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 17*4) }
    let command = queue.makeCommandBuffer()!
    let destination = CIRenderDestination(mtlTexture: baseline, commandBuffer: command)
    destination.colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
    _ = try context.startTask(toRender: CIImage(cvPixelBuffer: buffer).oriented(.downMirrored)
        .transformed(by: CGAffineTransform(scaleX: scale, y: scale)), to: destination)
    command.commit(); command.waitUntilCompleted()
    precondition(command.status == .completed)
    let expected = pixels(baseline)
    // Compare different AI strengths against the flat fallback reference.
    // This isolates brightness, alpha and orientation from scheduling. Uniform
    // input also permits full-strength comparison without spatial differences.
    for strength: Float in (uniform ? [0,0.35,0,1,0.35] : [0,0]) {
        let cb = queue.makeCommandBuffer()!
        let color = try converter.encode(buffer,width:w,height:h,scale:scale,context:context,commands:cb)
        try projector.encode(color:color,depth:depth,parameters:[strength,1,0.04,0.012],sourceIsLinear:true,left:left,right:right,commands:cb)
        cb.commit(); cb.waitUntilCompleted()
        precondition(cb.status == .completed)
        for eye in [left,right] {
            let values = pixels(eye)
            precondition(values.allSatisfy(\.isFinite))
            let error = zip(expected,values).map { abs($0 - $1) }.max()!
            worstError = max(worstError,error)
            precondition(error < 0.002, "Color/alpha/orientation jump for \(name), strength \(strength): \(error)")
            precondition(values.enumerated().filter { $0.offset % 4 == 3 }.allSatisfy { $0.element == 1 }, "No transparent holes")
        }
        cases += 1
    }
    print("PASS: \(name)")
}
for uniform in [false,true] {
    var optional: CVPixelBuffer?
    precondition(CVPixelBufferCreate(nil,129,73,kCVPixelFormatType_32BGRA,nil,&optional) == kCVReturnSuccess)
    let b = optional!
    CVPixelBufferLockBaseAddress(b,[])
    let base = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to:UInt8.self)
    for y in 0..<73 { for x in 0..<129 {
        let p = y*CVPixelBufferGetBytesPerRow(b)+x*4
        base[p] = uniform ? 83 : UInt8(x); base[p+1] = uniform ? 129 : UInt8(y*3)
        base[p+2] = uniform ? 175 : UInt8(255-x); base[p+3] = 255
    }}
    CVPixelBufferUnlockBaseAddress(b,[])
    for (name,space) in [("untagged",nil),("sRGB",CGColorSpace(name:CGColorSpace.sRGB)),("Rec709",CGColorSpace(name:CGColorSpace.itur_709)),("P3",CGColorSpace(name:CGColorSpace.displayP3))] {
        CVBufferRemoveAllAttachments(b)
        if let space { CVBufferSetAttachment(b,kCVImageBufferCGColorSpaceKey,space,.shouldPropagate) }
        try verify(b,name:"\(name) uniform=\(uniform)",uniform:uniform)
    }
    CVBufferRemoveAllAttachments(b)
    CVBufferSetAttachment(b,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
    CVBufferSetAttachment(b,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,.shouldPropagate)
    CVBufferSetAttachment(b,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,.shouldPropagate)
    try verify(b,name:"video Rec709 attachments uniform=\(uniform)",uniform:uniform)
}
// Decode a real bundled/local video as BGRA and retain its color attachments.
if let path = CommandLine.arguments.dropFirst().first {
    let asset = AVURLAsset(url: URL(fileURLWithPath:path))
    let reader = try AVAssetReader(asset:asset)
    let output = AVAssetReaderTrackOutput(track:asset.tracks(withMediaType:.video).first!,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
    reader.add(output); precondition(reader.startReading())
    for n in 0..<3 {
        guard let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) else { fatalError("Missing decoded frame") }
        try verify(buffer,name:"decoded frame \(n)")
    }
    reader.cancelReading()
}
print("PASS: \(cases) render comparisons, worst linear RGBA error \(worstError)")
