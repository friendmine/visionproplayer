import Foundation
import Metal

func check(_ condition: Bool, _ message: String = "GPU operation failed") {
    if !condition { FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8)); exit(1) }
}
let device = MTLCreateSystemDefaultDevice()!, queue = device.makeCommandQueue()!
let sourceCode = try ["DepthStereo.metal", "DepthEdges.metal"].map {
    try String(contentsOfFile: "VisionProPlayer/Rendering/" + $0, encoding: .utf8)
}.joined(separator: "\n")
let library = try device.makeLibrary(source: sourceCode, options: nil)
let refiner = try DepthEdgeRefiner(device: device, library: library)
let projector = try StereoReprojector(device: device, library: library)
func texture(_ format: MTLPixelFormat,_ w:Int,_ h:Int)->MTLTexture {
    let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:w,height:h,mipmapped:false)
    d.storageMode = .shared; d.usage = [.shaderRead,.shaderWrite,.renderTarget]
    return device.makeTexture(descriptor:d)!
}
func upload(_ values:[Float],_ t:MTLTexture,_ channels:Int) {
    values.withUnsafeBytes { t.replace(region:MTLRegionMake2D(0,0,t.width,t.height),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:t.width*channels*4) }
}
func read(_ t:MTLTexture,_ channels:Int)->[Float] {
    let staging=texture(t.pixelFormat,t.width,t.height)
    let cb=queue.makeCommandBuffer()!,b=cb.makeBlitCommandEncoder()!
    b.copy(from:t,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),sourceSize:MTLSize(width:t.width,height:t.height,depth:1),to:staging,destinationSlice:0,destinationLevel:0,destinationOrigin:MTLOrigin(x:0,y:0,z:0))
    b.endEncoding();cb.commit();cb.waitUntilCompleted();check(cb.status == .completed)
    var p=[UInt16](repeating:0,count:t.width*t.height*channels)
    p.withUnsafeMutableBytes { staging.getBytes($0.baseAddress!,bytesPerRow:t.width*channels*2,from:MTLRegionMake2D(0,0,t.width,t.height),mipmapLevel:0) }
    return p.map {Float(Float16(bitPattern:$0))}
}
let w = 256, h = 144, dw = 64, dh = 36
let color = texture(.rgba32Float,w,h), depth = texture(.rg32Float,dw,dh)
func subject(_ x: Float, _ y: Float, _ shift: Float) -> Bool {
    let x = x - shift
    let head = pow((x-128)/21,2) + pow((y-38)/23,2) < 1
    let body = pow((x-128)/36,2) + pow((y-91)/36,2) < 1
    let arm = x > 64 && x < 119 && abs(y - (112 - x * 0.4)) < 5
    let fingers = x > 51 && x < 69 && y > 77 && y < 89 && (Int(y) % 5 < 3)
    return head || body || arm || fingers
}
func linearDepth(_ x: Float,_ y: Float,_ values: [Float]) -> Float {
    let gx=x*Float(dw)-0.5, gy=y*Float(dh)-0.5
    let bx=Int(floor(gx)),by=Int(floor(gy)),fx=gx-Float(bx),fy=gy-Float(by)
    func at(_ a:Int,_ b:Int)->Float {values[(max(0,min(dh-1,b))*dw+max(0,min(dw-1,a)))*2]}
    return (at(bx,by)*(1-fx)+at(bx+1,by)*fx)*(1-fy)+(at(bx,by+1)*(1-fx)+at(bx+1,by+1)*fx)*fy
}
func refine(_ colors:[Float],_ depths:[Float])->(MTLTexture,[Float]) {
    upload(colors,color,4);upload(depths,depth,2)
    let cb=queue.makeCommandBuffer()!
    let result=try! refiner.encode(color:color,depth:depth,hasConfidence:true,commands:cb)
    cb.commit();cb.waitUntilCompleted();check(cb.status == .completed)
    return (result,read(result,1))
}
func projected(_ source: MTLTexture) -> [Float] {
    let left=texture(.rgba16Float,w,h),right=texture(.rgba16Float,w,h)
    let cb=queue.makeCommandBuffer()!
    try! projector.encode(color:color,depth:source,parameters:[0.35,0.6,0.04,0.012],protectProportions:true,sourceIsLinear:true,left:left,right:right,commands:cb)
    cb.commit();cb.waitUntilCompleted();check(cb.status == .completed)
    return read(left,4)+read(right,4)
}
var imageImprovements:[Float]=[]
var improvements:[Float]=[]
var finalDepth:MTLTexture?, finalColors:[Float]=[]
for dark in [false,true] {for shift:Float in [-1,0,0.5,1] {
    var colors=[Float](repeating:1,count:w*h*4),depths=[Float](repeating:1,count:dw*dh*2)
    for y in 0..<h {for x in 0..<w {
        let near=subject(Float(x)+0.5,Float(y)+0.5,shift)
        let skin: [Float] = dark ? [0.035,0.012,0.007] : [0.6,0.3,0.18]
        let back: [Float] = dark ? [0.003,0.004,0.006] : [0.04,0.08,0.14]
        for c in 0..<3 {colors[(y*w+x)*4+c] = near ? skin[c] : back[c]}
    }}
    for y in 0..<dh {for x in 0..<dw {
        depths[(y*dw+x)*2]=subject((Float(x)+0.5)*4,(Float(y)+0.5)*4,shift) ? 0.8 : 0.2
    }}
    let (out,values)=refine(colors,depths)
    var oldError:Float=0,newError:Float=0
    for y in 0..<out.height {for x in 0..<out.width {
        let ux=(Float(x)+0.5)/Float(out.width),uy=(Float(y)+0.5)/Float(out.height)
        let expected:Float=subject(ux*Float(w),uy*Float(h),shift) ? 0.8 : 0.2
        oldError+=abs(linearDepth(ux,uy,depths)-expected);newError+=abs(values[y*out.width+x]-expected)
    }}
    let improvement=1-newError/oldError
    print("dark=\(dark) shift=\(shift) boundary error reduction=\(improvement)")
    check(improvement>0.10,"Visible contour depth must improve without flattening the subject")
    improvements.append(improvement)
    check(abs(values[(out.height/2)*out.width+out.width/2]-0.8)<0.001,"Interior relief preserved")
    let ideal=texture(.r32Float,w,h)
    let truth=(0..<(w*h)).map { subject(Float($0 % w)+0.5,Float($0/w)+0.5,shift) ? Float(0.8):Float(0.2) }
    upload(truth,ideal,1)
    let expectedEyes=projected(ideal), baselineEyes=projected(depth), refinedEyes=projected(out)
    var baselineImageError:Float=0, refinedImageError:Float=0
    for i in expectedEyes.indices where i % 4 != 3 {
        baselineImageError+=abs(baselineEyes[i]-expectedEyes[i])
        refinedImageError+=abs(refinedEyes[i]-expectedEyes[i])
    }
    let imageImprovement=1-refinedImageError/baselineImageError
    print("projected RGB error reduction=\(imageImprovement)")
    check(imageImprovement>0,"Final eye images must improve against the same projection with ideal depth")
    imageImprovements.append(imageImprovement)
    check(projected(out)==refinedEyes,"Repeated frozen input must produce identical eye pixels")
    finalDepth=out;finalColors=colors
}}
// Feed the refined depth through the actual existing projection pipeline.
let left=texture(.rgba16Float,w,h),right=texture(.rgba16Float,w,h)
let cb=queue.makeCommandBuffer()!
try projector.encode(color:color,depth:finalDepth!,parameters:[0.6,1,0.04,0.012],protectProportions:true,sourceIsLinear:true,left:left,right:right,commands:cb)
cb.commit();cb.waitUntilCompleted();check(cb.status == .completed)
for t in [left,right] {
    let values=read(t,4)
    check(values.allSatisfy(\.isFinite),"Finite eye output")
    check(values.enumerated().filter{$0.offset%4==3}.allSatisfy{$0.element==1},"No exposed holes at contours or borders")
}
let field=projector.outputDisparity!, staging=texture(.r32Float,field.width,field.height)
let copy=queue.makeCommandBuffer()!,blit=copy.makeBlitCommandEncoder()!
blit.copy(from:field,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),sourceSize:MTLSize(width:field.width,height:field.height,depth:1),to:staging,destinationSlice:0,destinationLevel:0,destinationOrigin:MTLOrigin(x:0,y:0,z:0));blit.endEncoding();copy.commit();copy.waitUntilCompleted()
var f=[Float](repeating:0,count:field.width*field.height)
f.withUnsafeMutableBytes{staging.getBytes($0.baseAddress!,bytesPerRow:field.width*4,from:MTLRegionMake2D(0,0,field.width,field.height),mipmapLevel:0)}
var sx:Float=0,sy:Float=0
for y in 0..<field.height {for x in 0..<field.width {
 if x>0 {sx=max(sx,abs(f[y*field.width+x]-f[y*field.width+x-1])*Float(field.width-1))}
 if y>0 {sy=max(sy,abs(f[y*field.width+x]-f[(y-1)*field.width+x])*Float(field.height-1)*Float(w)/Float(h))}
}}
check(sx<0.07001 && sy<0.07001,"Existing shape protection bounds retained")
// Flat depth + detailed color must not emboss face/clothing texture.
var flat=[Float](repeating:1,count:dw*dh*2)
for i in 0..<dw*dh {flat[i*2]=0.6}
let (_,constant)=refine(finalColors,flat)
check(constant.allSatisfy{abs($0-0.6)<0.001},"No texture-copy depth on planar people")
// An uncertain motion region must bypass refinement, preserving baseline depth.
var uncertain=[Float](repeating:0,count:dw*dh*2)
for y in 0..<dh {for x in 0..<dw {uncertain[(y*dw+x)*2]=x<dw/2 ? 0.2:0.8}}
let (out,uncertainValues)=refine(finalColors,uncertain)
var maxBypassError:Float=0
for y in 0..<out.height {for x in 0..<out.width {
    maxBypassError=max(maxBypassError,abs(uncertainValues[y*out.width+x]-linearDepth((Float(x)+0.5)/Float(out.width),(Float(y)+0.5)/Float(out.height),uncertain)))
}}
check(maxBypassError<0.001,"Rejected motion must not gain new depth edges")
// Color without a boundary must not blur or sharpen depth on its own.
for i in 0..<dw*dh {uncertain[i*2+1]=1}
let (_,unguided)=refine([Float](repeating:0.2,count:w*h*4),uncertain)
var maxFlatColorError:Float=0
for y in 0..<out.height {for x in 0..<out.width {
    maxFlatColorError=max(maxFlatColorError,abs(unguided[y*out.width+x]-linearDepth((Float(x)+0.5)/Float(out.width),(Float(y)+0.5)/Float(out.height),uncertain)))
}}
check(maxFlatColorError<0.001,"Do not change depth without color evidence")
let report:[String:Any]=["passed":true,"minimumBoundaryDepthErrorReduction":improvements.min()!,"minimumProjectedImageErrorReduction":imageImprovements.min()!,"maximumProtectedSlopeX":sx,"maximumProtectedSlopeY":sy,"unreliableMotionMaximumDifference":maxBypassError,"flatColorMaximumDifference":maxFlatColorError,"scope":"Synthetic visible silhouette and confidence tests, not recovered hidden detail or subjective improvement"]
print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
