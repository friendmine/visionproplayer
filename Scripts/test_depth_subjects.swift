import Foundation
import CoreImage
import CoreVideo
import Metal

func check(_ condition: Bool, _ message: String = "GPU operation failed") {
    if !condition { FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8)); exit(1) }
}
let device = MTLCreateSystemDefaultDevice()!, queue = device.makeCommandQueue()!
let code = try ["DepthStereo.metal", "DepthSubjects.metal"].map { try String(contentsOfFile: "VisionProPlayer/Rendering/"+$0, encoding: .utf8) }.joined(separator: "\n")
let library = try device.makeLibrary(source: code, options: nil)
let preparer = try DepthSubjectPreparer(device: device, library: library)
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

let width=518,height=392
let context=CIContext(options:[.cacheIntermediates:false])
var shapeErrors:[Double]=[],cropErrors:[Float]=[]
func buffer(_ w:Int,_ h:Int,_ format:OSType)->CVPixelBuffer {
    var out:CVPixelBuffer?
    check(CVPixelBufferCreate(nil,w,h,format,[kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,&out)==kCVReturnSuccess)
    return out!
}
func preprocess(_ w:Int,_ h:Int,_ accuracy:Bool)->(CVPixelBuffer,DepthInferenceGeometry) {
    let geometry=DepthInferenceGeometry(source:CGSize(width:w,height:h),canvas:CGSize(width:width,height:height))
    // A centered white square acts as a shape/axis marker in both orientations.
    let side=CGFloat(min(w,h))/3
    let black=CIImage(color:CIColor(red:0,green:0,blue:0)).cropped(to:CGRect(x:0,y:0,width:w,height:h))
    let square=CIImage(color:CIColor(red:1,green:1,blue:1)).cropped(to:CGRect(x:(CGFloat(w)-side)/2,y:(CGFloat(h)-side)/2,width:side,height:side))
    let image=square.composited(over:black)
    let mapped=accuracy ? geometry.image(image) : image.transformed(by:CGAffineTransform(scaleX:CGFloat(width)/CGFloat(w),y:CGFloat(height)/CGFloat(h)))
    let output=buffer(width,height,kCVPixelFormatType_32BGRA)
    context.render(mapped,to:output,bounds:CGRect(x:0,y:0,width:width,height:height),colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
    return(output,geometry)
}
func shapeRatio(_ b:CVPixelBuffer)->Double {
    CVPixelBufferLockBaseAddress(b,.readOnly);defer{CVPixelBufferUnlockBaseAddress(b,.readOnly)}
    let ptr=CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to:UInt8.self),stride=CVPixelBufferGetBytesPerRow(b)
    let horizontal=(0..<width).filter{ptr[(height/2)*stride+$0*4]>128}.count
    let vertical=(0..<height).filter{ptr[$0*stride+(width/2)*4]>128}.count
    return Double(horizontal)/Double(vertical)
}
for (w,h) in [(1920,1080),(1080,1920),(3840,1600),(1600,3840),(518,392)] {
    let (input,geometry)=preprocess(w,h,true), (baseline,_)=preprocess(w,h,false)
    let ratio=shapeRatio(input), oldRatio=shapeRatio(baseline)
    print("\(w)x\(h): model input square ratio old=\(oldRatio) new=\(ratio)")
    check(abs(ratio-1)<0.015,"Model must see undistorted shapes")
    shapeErrors.append(abs(ratio-1))
    if w != 518 {check(abs(oldRatio-1)>0.2,"Fixture must expose baseline anisotropic input")}
    let crop=geometry.normalizedContent
    let raw=texture(.r32Float,width,height)
    var values=[Float](repeating:100,count:width*height)
    for y in 0..<height {for x in 0..<width {
        let u=(Float(x)+0.5)/Float(width),v=(Float(y)+0.5)/Float(height)
        if u>=crop.x && u<=crop.x+crop.z && v>=crop.y && v<=crop.y+crop.w {
            values[y*width+x]=(u-crop.x)/crop.z*0.2+(v-crop.y)/crop.w*0.4
        }
    }}
    upload(values,raw,1)
    // Padding must not influence CPU quantiles either.
    let rawBuffer=buffer(width,height,kCVPixelFormatType_OneComponent32Float)
    CVPixelBufferLockBaseAddress(rawBuffer,[])
    for y in 0..<height {
        let row=CVPixelBufferGetBaseAddress(rawBuffer)!.advanced(by:y*CVPixelBufferGetBytesPerRow(rawBuffer)).assumingMemoryBound(to:Float.self)
        for x in 0..<width {row[x]=values[y*width+x]}
    }
    CVPixelBufferUnlockBaseAddress(rawBuffer,[])
    let samples=try DepthEstimator.depthSamples(rawBuffer,region:crop)
    check(samples.count>20 && samples.max()!<0.61,"Exclude artificial padding from range estimation")
    let cb=queue.makeCommandBuffer()!
    let out=try preparer.encode(raw:raw,crop:crop,lower:0,upper:1,commands:cb)
    cb.commit();cb.waitUntilCompleted();check(cb.status == .completed)
    let actual=read(out,1)
    var error:Float=0
    for y in 2..<(height-2) {for x in 2..<(width-2) {
        let expected=(Float(x)+0.5)/Float(width)*0.2+(Float(y)+0.5)/Float(height)*0.4
        error=max(error,abs(actual[y*width+x]-expected))
    }}
    print("restored depth maximum error \(error)")
    check(error<0.003,"Correct full-frame orientation, aspect and padding exclusion")
    cropErrors.append(error)
}
// A foreground ramp beyond the old 95th-percentile endpoint must retain order.
let raw=texture(.r32Float,width,height)
let values=(0..<(width*height)).map {Float($0 % width)/Float(width-1)*1.5}
upload(values,raw,1)
let cb=queue.makeCommandBuffer()!
let out=try preparer.encode(raw:raw,crop:[0,0,1,1],lower:0,upper:1,commands:cb)
cb.commit();cb.waitUntilCompleted();check(cb.status == .completed)
let normalized=read(out,1)
check(normalized.allSatisfy{$0.isFinite && $0>=0 && $0<=1},"Finite bounded near-tail")
for x in 1..<width {check(normalized[x]>=normalized[x-1],"No depth order reversal")}
let near1=normalized[Int(Float(width-1)*1.05/1.5)],near2=normalized[Int(Float(width-1)*1.25/1.5)]
check(near2-near1>0.025,"Restore near-subject layers that both clipped to one before")
let shoulder=Int(Float(width-1)*0.8/1.5)
check(abs(normalized[shoulder+1]-normalized[shoulder-1])<0.008,"Continuous shoulder without a depth step")
let color=texture(.rgba32Float,width,height),left=texture(.rgba16Float,width,height),right=texture(.rgba16Float,width,height)
upload([Float](repeating:0.3,count:width*height*4),color,4)
let render=queue.makeCommandBuffer()!
try projector.encode(color:color,depth:out,parameters:[0.35,0.6,0.04,0.012],protectProportions:true,sourceIsLinear:true,left:left,right:right,commands:render)
render.commit();render.waitUntilCompleted();check(render.status == .completed)
for eye in [left,right] {let v=read(eye,4);check(v.allSatisfy(\.isFinite));check(v.enumerated().filter{$0.offset%4==3}.allSatisfy{$0.element==1},"Full eye coverage")}
let report:[String:Any]=["passed":true,"maximumModelInputShapeRatioError":shapeErrors.max()!,"maximumRestoredDepthError":cropErrors.max()!,"preservedNearTailSeparation":near2-near1,"scope":"Preprocessing geometry, padding, monotonic near-tail and projection coverage; not measured human depth accuracy or headset performance"]
print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
