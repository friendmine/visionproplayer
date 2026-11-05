import Foundation
import Metal

// Test the actual app encoder. A constant input plane must not acquire curvature
// merely to cover the frame. No assertion here measures real-world model depth.
let device = MTLCreateSystemDefaultDevice()!, queue = device.makeCommandQueue()!
let library = try device.makeLibrary(source: String(contentsOfFile: "VisionProPlayer/Rendering/DepthStereo.metal", encoding: .utf8), options: nil)
let projector = try StereoReprojector(device: device, library: library)
func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: \(message)"); exit(1) }
}
func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
    d.storageMode = .shared; d.usage = [.shaderRead, .shaderWrite, .renderTarget]
    return device.makeTexture(descriptor: d)!
}
func upload(_ values: [Float], _ t: MTLTexture, _ channels: Int) {
    values.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0,0,t.width,t.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: t.width*channels*4) }
}
var cases = 0, oldFlatSpan: Float = 0, newFlatSpan: Float = 0, maxSlope: Float = 0, maxScale: Float = 1
var maximumShapeRatioError: Float = 0
for (w,h) in [(640,360), (360,640), (641,359)] {
    let color = texture(.rgba32Float,w,h), depth = texture(.r32Float,w,h)
    let left = texture(.rgba16Float,w,h), right = texture(.rgba16Float,w,h)
    var colors = [Float](repeating: 0, count: w*h*4)
    for y in 0..<h { for x in 0..<w {
        let i = (y*w+x)*4
        colors[i] = (Float(x)+0.5)/Float(w); colors[i+1] = (Float(y)+0.5)/Float(h)
        colors[i+2] = 0.5; colors[i+3] = 1
    }}
    upload(colors,color,4)
    for pattern in 0..<6 {
        var depths = [Float](repeating: 0, count: w*h)
        for y in 0..<h { for x in 0..<w {
            let u = Float(x)/Float(w-1), v = Float(y)/Float(h-1)
            switch pattern {
            case 0: depths[y*w+x] = 0
            case 1: depths[y*w+x] = 0.25
            case 2: depths[y*w+x] = 1
            case 3: depths[y*w+x] = u
            case 4: depths[y*w+x] = (u > 0.3 && u < 0.7 && v > 0.2 && v < 0.85) ? 0.9 : 0.1
            default: depths[y*w+x] = Float((x*13+y*29+(x/7)*53)%101)/100
            }
        }}
        upload(depths,depth,1)
        for p in [SIMD4<Float>(0,1,0.04,0.012), [0.35,0,0.04,0.012], [0.35,0.6,0.04,0.012], [0.35,1,0.04,0.012], [1,1,0.03,0.012], [0.35,1,0.002,0.012]] {
            for planar in [false,true] {
                let command = queue.makeCommandBuffer()!
                try projector.encode(color: color, depth: depth, parameters: p, sourceIsLinear: true,
                    preserveDepthPlanes: planar, left: left, right: right, commands: command)
                let field = projector.outputDisparity!, copy = texture(.r32Float,field.width,field.height)
                let blit = command.makeBlitCommandEncoder()!
                blit.copy(from: field, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x:0,y:0,z:0), sourceSize: MTLSize(width:field.width,height:field.height,depth:1), to: copy, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x:0,y:0,z:0))
                blit.endEncoding();command.commit();command.waitUntilCompleted()
                check(command.status == .completed,"GPU completed")
                let fw = field.width, fh = field.height
                var values = [Float](repeating: 0,count:fw*fh)
                values.withUnsafeMutableBytes { copy.getBytes($0.baseAddress!, bytesPerRow: fw*4, from: MTLRegionMake2D(0,0,fw,fh), mipmapLevel: 0) }
                check(values.allSatisfy { $0.isFinite && $0 >= -p.w*0.5-0.000001 && $0 <= p.z*0.5+0.000001 },"Finite capped disparity")
                let zoom = planar ? StereoReprojector.coverageScale(parameters:p) : 1
                maxScale = max(maxScale,zoom)
                if p.x == 0 { check(zoom == 1 && values.allSatisfy{$0==0},"Zero strength has no crop or warp") }
                if pattern < 3 {
                    let span = values.max()! - values.min()!
                    if planar { newFlatSpan = max(newFlatSpan,span); check(span<0.000001,"Constant depth must remain planar across whole frame") }
                    else { oldFlatSpan = max(oldFlatSpan,span) }
                }
                if planar && pattern == 3 && p.x > 0 { check(values[fw/2]>values[0] && values[fw-1]>values[fw/2],"Real depth ramp retains order and separation") }
                if planar && pattern == 4 && p.x > 0 { check(values[(fh/2)*fw+fw/2]>values[(fh/2)*fw+fw/10],"Foreground remains in front of background") }
                for y in 0..<(fh-1) { for x in 0..<(fw-1) {
                    let a=values[y*fw+x],b=values[y*fw+x+1],c=values[(y+1)*fw+x]
                    let dx=abs(b-a)*Float(fw-1),dy=abs(c-a)*Float(fh-1)*Float(w)/Float(h)
                    maxSlope=max(maxSlope,max(dx,dy))
                    check(dx<=0.07002 && dy<=0.07002,"Proportion protection remains bounded")
                }}
                for eye in [left,right] {
                    var pixels=[UInt16](repeating:0,count:w*h*4)
                    pixels.withUnsafeMutableBytes { eye.getBytes($0.baseAddress!,bytesPerRow:w*8,from:MTLRegionMake2D(0,0,w,h),mipmapLevel:0) }
                    check(pixels.allSatisfy{Float16(bitPattern:$0).isFinite},"Finite eye image")
                    check(stride(from:3,to:pixels.count,by:4).allSatisfy{Float16(bitPattern:pixels[$0])==1},"Full opaque eye coverage without taper")
                    if planar && pattern < 3 {
                        func sample(_ x:Int,_ y:Int,_ channel:Int)->Float {Float(Float16(bitPattern:pixels[(y*w+x)*4+channel]))}
                        let sx=(sample(3*w/4,h/2,0)-sample(w/4,h/2,0))*Float(w)/Float(3*w/4-w/4)
                        let sy=(sample(w/2,3*h/4,1)-sample(w/2,h/4,1))*Float(h)/Float(3*h/4-h/4)
                        maximumShapeRatioError=max(maximumShapeRatioError,abs(sx/sy-1))
                        check(abs(sx/sy-1)<0.004,"Eye image has uniform x/y scale, not widened people")
                        check(abs(sx-1/zoom)<0.003 && abs(sy-1/zoom)<0.003,"Only declared overscan crops the image")
                    }
                }
                cases+=1
            }
        }
    }
}
check(oldFlatSpan>0.01,"Fixture reproduces baseline artificial curvature")
let report:[String:Any] = ["passed":true,"cases":cases,"baselineMaximumFlatPlaneDisparitySpan":oldFlatSpan,"revisedMaximumFlatPlaneDisparitySpan":newFlatSpan,"maximumProtectedPixelSlope":maxSlope,"maximumCoverageScale":maxScale,"maximumUniformShapeRatioError":maximumShapeRatioError,"scope":"Actual GPU synthetic planar/ramp/foreground/noisy projection and final RGB checks; not proof of the user's scene root cause or ground-truth depth accuracy"]
print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
