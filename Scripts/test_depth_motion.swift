import Foundation
import Metal

func check(_ condition: Bool, _ message: String = "GPU operation failed") {
    if !condition { FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8)); exit(1) }
}

let device = MTLCreateSystemDefaultDevice()!, queue = device.makeCommandQueue()!
let sourceCode = try ["DepthStereo.metal","DepthMotion.metal"].map {
    try String(contentsOfFile:"VisionProPlayer/Rendering/"+$0,encoding:.utf8)
}.joined(separator:"\n")
let library = try device.makeLibrary(source:sourceCode,options:nil)
let aligner = try DepthMotionAligner(device:device,library:library)
let projector = try StereoReprojector(device:device,library:library)
let filter = try device.makeComputePipelineState(function:library.makeFunction(name:"stabilizeMotionDepth")!)
let w=128,h=72,dw=256,dh=144
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
let reference=texture(.rgba32Float,w,h),target=texture(.rgba32Float,w,h),depth=texture(.r32Float,dw,dh)
func pattern(_ x:Float,_ y:Float)->Float {
    0.5+0.14*sin(x*0.49+y*0.31)+0.12*cos(y*0.71-x*0.23)+0.16*sin(x*x*0.013+y*y*0.019)
}
func rgba(_ dx:Float,_ dy:Float, unrelated:Bool=false)->[Float] {
    var a=[Float](repeating:1,count:w*h*4)
    for y in 0..<h {for x in 0..<w {
        let l=unrelated ? 0.5+0.4*sin(Float(x)*2.1+Float(y)*2.7) : pattern(Float(x)-dx,Float(y)-dy)
        for c in 0..<3 {a[(y*w+x)*4+c]=l}
    }}
    return a
}
func actualDepth(_ x:Float,_ y:Float)->Float {
    // Sloped background plus an oval subject to exercise both transport axes.
    let near = pow((x-64)/24,2)+pow((y-36)/20,2)<1
    return near ? 0.8 : 0.15+0.002*x
}
let depths=(0..<(dw*dh)).map { actualDepth((Float($0 % dw)+0.5)*0.5-0.5,(Float($0/dw)+0.5)*0.5-0.5) }
upload(rgba(0,0),reference,4);upload(depths,depth,1)
var improvements:[Float]=[], confidences:[Float]=[], gpu:[Double]=[]
func aligned(_ conservative:Bool)->(MTLTexture,[Float]) {
    let cb=queue.makeCommandBuffer()!
    let out=try! aligner.encode(source:reference,target:target,depth:depth,neutral:0.41,conservative:conservative,commands:cb)
    cb.commit();cb.waitUntilCompleted();check(cb.status == .completed)
    gpu.append((cb.gpuEndTime-cb.gpuStartTime)*1000)
    return (out,read(out,2))
}
for (dx,dy):(Float,Float) in [(0,0),(3,-2),(-3,2),(1.5,0.5)] {
    upload(rgba(dx,dy),target,4)
    let (_,values)=aligned(false)
    let flow=read(aligner.diagnosticMotion!,4)
    let fi=(18*64+32)*4
    print("center flow \(flow[fi]*128),\(flow[fi+1]*72), GPU \(gpu.last!) ms")
    var baseline:Float=0,error:Float=0,confidence:Float=0,count:Float=0
    for y in 24..<(dh-24) {for x in 24..<(dw-24) {
        let i=y*dw+x
        let expected=actualDepth((Float(x)+0.5)*0.5-0.5-dx,(Float(y)+0.5)*0.5-0.5-dy)
        baseline+=abs(depths[i]-expected);error+=abs(values[i*2]-expected);confidence+=values[i*2+1];count+=1
    }}
    print("shift \(dx),\(dy): depth error baseline \(baseline/count), aligned \(error/count), confidence \(confidence/count)")
    if dx == 0 && dy == 0 {check(error/count<0.0003,"Unchanged frames must preserve depth")}
    else {check(error < baseline*0.65,"Known motion must improve alignment rather than flatten depth");improvements.append(1-error/baseline)}
    confidences.append(confidence/count)
}
// Motion outside the search range must not be reported as a trusted match.
upload(rgba(12,9),target,4)
let (_,outOfRange)=aligned(false)
let rangeConfidence=stride(from:1,to:outOfRange.count,by:2).reduce(Float(0)){$0+outOfRange[$1]}/Float(dw*dh)
print("outside-range mean confidence \(rangeConfidence)")
check(rangeConfidence<0.2,"Outside-range motion must reduce confidence")
// Preserve the original adversarial repeated-texture fixture. There is no
// unique correspondence: reject competing lookalikes instead of claiming that
// choosing the nearest candidate makes it reliable.
func repeated(_ dx: Float, _ dy: Float) -> [Float] {
    var a=[Float](repeating:1,count:w*h*4)
    for y in 0..<h {for x in 0..<w {
        let px=Float(x)-dx,py=Float(y)-dy
        let l=0.5+0.18*sin(px*0.79+py*0.31)+0.12*cos(py*0.91-px*0.23)+0.08*sin(px*1.73-py*1.37)
        for c in 0..<3 {a[(y*w+x)*4+c]=l}
    }}
    return a
}
upload(repeated(0,0),reference,4);upload(repeated(1.5,0.5),target,4)
let (_,ambiguous)=aligned(false)
let ambiguousConfidence=stride(from:1,to:ambiguous.count,by:2).reduce(Float(0)){$0+ambiguous[$1]}/Float(dw*dh)
print("ambiguous texture mean confidence \(ambiguousConfidence)")
check(ambiguousConfidence<0.5,"Repeated lookalikes must not be called reliable")
upload(rgba(0,0),reference,4)
// An unrelated image must not be treated as a reliable history match.
upload(rgba(0,0,unrelated:true),target,4)
let (_,rejected)=aligned(false)
let meanRejected=stride(from:1,to:rejected.count,by:2).reduce(Float(0)){$0+rejected[$1]}/Float(dw*dh)
check(meanRejected<0.15,"Unrelated images must reject history")
// New high-confidence prediction must replace rejected history, not inherit it.
let currentPrediction=texture(.r32Float,dw,dh)
upload([Float](repeating:0.78,count:dw*dh),currentPrediction,1)
let filtered=texture(.r16Float,dw,dh),cb=queue.makeCommandBuffer()!
let uncertain=try aligner.encode(source:reference,target:target,depth:depth,neutral:0.41,conservative:false,commands:cb)
let enc=cb.makeComputeCommandEncoder()!
enc.setComputePipelineState(filter);enc.setTexture(currentPrediction,index:0);enc.setTexture(uncertain,index:1);enc.setTexture(filtered,index:2)
var params=SIMD4<Float>(0,1,0,0)
enc.setBytes(&params,length:16,index:0)
enc.dispatchThreads(MTLSize(width:dw,height:dh,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:8,depth:1))
enc.endEncoding();cb.commit();cb.waitUntilCompleted();check(cb.status == .completed)
let resetPixels=read(filtered,1)
check(abs(resetPixels[72*dw+128]-0.78)<0.001,"Unreliable history must not blend even when its depth difference is small")
// Occlusion/newly exposed region: photometric mismatch lowers trust while
// unchanged areas retain the original relief. No old RGB is ever rendered.
var occlusion=rgba(0,0)
for y in 24..<48 {for x in 48..<80 {for c in 0..<3 {occlusion[(y*w+x)*4+c]=0.02}}}
upload(occlusion,target,4)
let (occluded,p)=aligned(true)
let subjectIndex=(72*dw+128)*2
check(p[subjectIndex+1]<0.2,"Occluded region must have low confidence")
check(abs(p[subjectIndex]-0.41)<abs(0.8-0.41)*0.6,"Risky region must reduce old relief")
check(abs(p[(30*dw+30)*2]-depths[30*dw+30])<0.003,"Unchanged region keeps relief")
// Keep exact border coverage and verify actual projected triangle bounds after
// confidence control, rather than relying on nominal settings alone.
let color=texture(.rgba32Float,dw,dh),left=texture(.rgba16Float,dw,dh),right=texture(.rgba16Float,dw,dh)
var colors=[Float](repeating:1,count:dw*dh*4)
for i in 0..<(dw*dh) {colors[i*4]=Float(i%dw)/Float(dw);colors[i*4+1]=0.3;colors[i*4+2]=0.2}
upload(colors,color,4)
let render=queue.makeCommandBuffer()!
try projector.encode(color:color,depth:occluded,parameters:[0.6,1,0.04,0.012],protectProportions:true,sourceIsLinear:true,left:left,right:right,commands:render)
render.commit();render.waitUntilCompleted();check(render.status == .completed)
for eye in [left,right] {
 let values=read(eye,4)
 check(values.allSatisfy(\.isFinite))
 check(values.enumerated().filter{$0.offset%4==3}.allSatisfy{$0.element==1},"No holes after alignment")
}
// outputDisparity is Float32; copy it to CPU and measure both derivatives.
let field=projector.outputDisparity!,staging=texture(.r32Float,field.width,field.height)
let copy=queue.makeCommandBuffer()!,blit=copy.makeBlitCommandEncoder()!
blit.copy(from:field,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),sourceSize:MTLSize(width:field.width,height:field.height,depth:1),to:staging,destinationSlice:0,destinationLevel:0,destinationOrigin:MTLOrigin(x:0,y:0,z:0));blit.endEncoding();copy.commit();copy.waitUntilCompleted()
var f=[Float](repeating:0,count:field.width*field.height)
f.withUnsafeMutableBytes{staging.getBytes($0.baseAddress!,bytesPerRow:field.width*4,from:MTLRegionMake2D(0,0,field.width,field.height),mipmapLevel:0)}
var sx:Float=0,sy:Float=0
for y in 0..<field.height {for x in 0..<field.width {
 if x>0 {sx=max(sx,abs(f[y*field.width+x]-f[y*field.width+x-1])*Float(field.width-1))}
 if y>0 {sy=max(sy,abs(f[y*field.width+x]-f[(y-1)*field.width+x])*Float(field.height-1)*Float(dw)/Float(dh))}
}}
check(sx<0.07001 && sy<0.07001,"Motion alignment must retain proportion limits")
let report:[String:Any]=["passed":true,"minimumKnownMotionErrorReduction":improvements.min()!,"rejectedSceneMeanConfidence":meanRejected,"outOfRangeMeanConfidence":rangeConfidence,"ambiguousTextureMeanConfidence":ambiguousConfidence,"maximumProtectedSlopeX":sx,"maximumProtectedSlopeY":sy,"gpuMeanMS":gpu.reduce(0,+)/Double(gpu.count),"scope":"Synthetic GPU transport, rejection, coverage and warp-bound checks; not wearable performance or perceptual acceptance"]
print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
