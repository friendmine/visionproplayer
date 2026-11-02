import Foundation
import Metal

func check(_ condition: Bool, _ message: String) { precondition(condition, message) }
let w = DepthSceneChange.columns, h = DepthSceneChange.rows
var seed: UInt64 = 381
func random() -> Float { seed = seed &* 6364136223846793005 &+ 1; return Float((seed >> 32) % 10000) / 10000 }
let scene = (0..<(w*h)).map { _ in random() > 0.5 ? Float(0.75) : Float(0.20) }
func translate(_ dx: Float, _ dy: Int) -> [Float] {
    (0..<(w*h)).map { i in
        let x = max(0, min(Float(w-1), Float(i % w) + dx)), y = max(0, min(h-1, i/w+dy))
        let a = Int(x), b = min(w-1,a+1), t = x-Float(a)
        return scene[y*w+a]*(1-t)+scene[y*w+b]*t
    }
}
var oldFalseCuts = 0
for dy in -1...1 { for dx: Float in [-2,-1,-0.5,0.5,1,2] {
    let moved = translate(dx,dy)
    let difference = zip(scene,moved).reduce(Float(0)) { $0+abs($1.0-$1.1) } / Float(scene.count)
    if difference > 0.16 { oldFalseCuts += 1 }
    check(!DepthSceneChange.detected(previous:scene,current:moved),"Translation mistaken for cut \(dx),\(dy)")
}}
check(oldFalseCuts > 0,"Fixture must expose old pan false positives")
check(!DepthSceneChange.detected(previous:scene,current:scene.map { $0+0.18 }),"Exposure change is not a cut")
for _ in 0..<8 {
    let next = (0..<(w*h)).map { _ in random() > 0.5 ? Float(0.8) : Float(0.1) }
    check(DepthSceneChange.detected(previous:scene,current:next),"Unrelated scene must reset")
}
check(DepthSceneChange.detected(previous:scene,current:[Float](repeating:0,count:w*h)),"Black transition resets")
check(DepthSceneChange.detected(previous:[],current:scene),"Missing signature resets")
for fps in [24.0,30,60] {
    var e = DepthPresentationEnvelope(), previous: Float = 0
    for frame in 0..<Int(fps) {
        let now = Double(frame)/fps
        let gain = e.update(now:now,capturedAt:now-0.08,generation:0,playing:true)
        check(gain >= previous && gain-previous <= 0.18,"Recovery must be bounded and monotonic")
        previous = gain
    }
    check(previous == 1,"Must retain full steady-state relief")
    let fading = e.update(now:2,capturedAt:1.86,generation:0,playing:true)
    check(fading > 0 && fading < 0.3,"Old depth fades before expiry")
    check(e.update(now:2.1,capturedAt:1.86,generation:0,playing:true)==0,"Never display expired depth")
    let recovered = e.update(now:2.133,capturedAt:2.1,generation:0,playing:true)
    check(recovered > 0 && recovered < 0.2,"No snap on recovery")
    check(e.update(now:2.2,capturedAt:nil,generation:1,playing:true)==0,"Cut discards old geometry")
    check(e.update(now:2.25,capturedAt:2.2,generation:1,playing:true)<0.25,"New scene fades in")
    check(e.update(now:20,capturedAt:2.2,generation:1,playing:false)==1,"Paused adjustment is immediate")
}
let device = MTLCreateSystemDefaultDevice()!, queue = device.makeCommandQueue()!
let source = try String(contentsOfFile:"VisionProPlayer/Rendering/DepthStereo.metal",encoding:.utf8)
let library = try device.makeLibrary(source:source,options:nil)
let pipeline = try device.makeComputePipelineState(function:library.makeFunction(name:"stabilizeDepth")!)
func tex(_ format: MTLPixelFormat, _ w: Int = 256, _ h: Int = 64) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:w,height:h,mipmapped:false)
    d.storageMode = .shared; d.usage = [.shaderRead,.shaderWrite,.renderTarget]
    return device.makeTexture(descriptor:d)!
}
let raw = tex(.r32Float)
var history = tex(.r16Float), next = tex(.r16Float)
func upload(_ values: [Float]) {
    values.withUnsafeBytes { raw.replace(region:MTLRegionMake2D(0,0,256,64),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:256*4) }
}
func pixels(_ t: MTLTexture, channels: Int = 1) -> [Float] {
    var values = [UInt16](repeating:0,count:t.width*t.height*channels)
    values.withUnsafeMutableBytes { t.getBytes($0.baseAddress!,bytesPerRow:t.width*2*channels,from:MTLRegionMake2D(0,0,t.width,t.height),mipmapLevel:0) }
    return values.map { Float(Float16(bitPattern:$0)) }
}
func stabilize(_ reset: Bool = false) -> [Float] {
    let cb = queue.makeCommandBuffer()!, enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pipeline)
    enc.setTexture(raw,index:0); enc.setTexture(history,index:1); enc.setTexture(next,index:2)
    var params = SIMD4<Float>(0,1,reset ? 1 : 0,0)
    enc.setBytes(&params,length:16,index:0)
    enc.dispatchThreads(MTLSize(width:256,height:64,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:8,depth:1))
    enc.endEncoding();cb.commit();cb.waitUntilCompleted();check(cb.status == .completed,"GPU completion")
    swap(&history,&next);return pixels(history)
}
var rawNoise: Float = 0, outputNoise: Float = 0
upload([Float](repeating:0.5,count:256*64));_ = stabilize(true)
for frame in 0..<60 {
    let noise: Float = frame.isMultiple(of:2) ? 0.015 : -0.015
    upload([Float](repeating:0.5+noise,count:256*64))
    let result = stabilize()
    if frame > 10 { rawNoise += noise*noise; outputNoise += pow(result[128]-0.5,2) }
}
let noiseRatio = sqrt(outputNoise/rawNoise)
check(noiseRatio < 0.3,"Small stationary depth noise should be suppressed")
var thresholdValues: [Float] = []
for offset: Float in [0.079,0.081] {
    upload([Float](repeating:0.5,count:256*64));_ = stabilize(true)
    upload([Float](repeating:0.5+offset,count:256*64));thresholdValues.append(stabilize()[128])
}
check(abs(thresholdValues[1]-thresholdValues[0]) < 0.005,"History must not jump around the former threshold")
for boundary in stride(from:60,to:180,by:7) {
    upload((0..<(256*64)).map { $0 % 256 < boundary ? Float(0.8) : Float(0.2) })
    let p = stabilize(boundary == 60)
    check(abs(p[boundary-3]-0.8)<0.002 && abs(p[boundary+3]-0.2)<0.002,"Moving boundary must not leave depth trails")
}
upload([Float](repeating:0.35,count:256*64));let cut = stabilize(true)
check(cut.allSatisfy { abs($0-0.35)<0.001 },"Cut must not blend previous scene")
let projector = try StereoReprojector(device:device,library:library)
let color = tex(.rgba32Float), left = tex(.rgba16Float), right = tex(.rgba16Float)
var colors = [Float](repeating:0,count:256*64*4)
for i in 0..<(256*64) { colors[i*4]=Float(i%256)/255;colors[i*4+1]=0.4;colors[i*4+3]=1 }
colors.withUnsafeBytes { color.replace(region:MTLRegionMake2D(0,0,256,64),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:256*16) }
upload([Float](repeating:0.8,count:256*64));_ = stabilize(true)
var eyeDifferences: [Float] = []
for gain: Float in [0,0.25,0.5,1] {
    let cb = queue.makeCommandBuffer()!
    try projector.encode(color:color,depth:history,parameters:[0.35,0.6,0.04,0.012],sourceIsLinear:true,disparityGain:gain,left:left,right:right,commands:cb)
    cb.commit();cb.waitUntilCompleted();check(cb.status == .completed,"Projection completion")
    let a = pixels(left,channels:4), b = pixels(right,channels:4)
    check(a.enumerated().filter { $0.offset%4==3 }.allSatisfy { $0.element==1 },"Fade must not create holes")
    if gain == 0 {check(a == b,"Zero gain gives exact flat eyes")}
    eyeDifferences.append(b[(32*256+128)*4]-a[(32*256+128)*4])
}
check(eyeDifferences[3]>0.005,"Full gain retains relief")
check(abs(eyeDifferences[1]/eyeDifferences[3]-0.25)<0.03 && abs(eyeDifferences[2]/eyeDifferences[3]-0.5)<0.03,"Recovery scales actual disparity linearly")
print("PASS: 18 translated scenes (old false cuts: \(oldFalseCuts)), exposure, 8 cuts, black/missing signatures")
print("PASS: 24/30/60 fps recovery, stale-depth expiry, cut reset and paused adjustment")
print("PASS: GPU noise RMS ratio \(noiseRatio), continuous threshold, moving edges, cut reset, linear disparity recovery and coverage")
