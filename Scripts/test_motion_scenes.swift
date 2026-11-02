import Foundation
import AVFoundation
import CoreVideo
func oldSamples(_ buffer: CVPixelBuffer) -> [Float] {
    CVPixelBufferLockBaseAddress(buffer,.readOnly);defer{CVPixelBufferUnlockBaseAddress(buffer,.readOnly)}
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to:UInt8.self)
    var v:[Float]=[]
    for y in 0..<12 {for x in 0..<16 {
        let p = (y*CVPixelBufferGetHeight(buffer)/12)*CVPixelBufferGetBytesPerRow(buffer)+(x*CVPixelBufferGetWidth(buffer)/16)*4
        v.append((Float(base[p])+Float(base[p+1])*2+Float(base[p+2]))/1020)
    }}
    return v
}
let asset=AVURLAsset(url:URL(fileURLWithPath:CommandLine.arguments[1]))
let reader=try AVAssetReader(asset:asset)
let output=AVAssetReaderTrackOutput(track:asset.tracks(withMediaType:.video).first!,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
reader.add(output);precondition(reader.startReading())
var old:[Float]=[],previous:[Float]=[],newCuts:[Double]=[],oldCuts:[Double]=[]
var frames=0
while let sample=output.copyNextSampleBuffer(),let b=CMSampleBufferGetImageBuffer(sample) {
    let time=CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
    let signature=DepthEstimator.lumaSamples(b),legacy=oldSamples(b)
    if !previous.isEmpty && DepthSceneChange.detected(previous:previous,current:signature) {newCuts.append(time)}
    if !old.isEmpty && zip(old,legacy).reduce(Float(0),{$0+abs($1.0-$1.1)})/Float(old.count)>0.16 {oldCuts.append(time)}
    previous=signature;old=legacy;frames+=1
}
let insertedCuts = [6.0,12,18,24]
precondition(reader.status == .completed && frames == 900, "Must decode the complete 30-second fixture")
precondition(insertedCuts.allSatisfy { expected in newCuts.contains { abs($0-expected) < 1.0/30 } }, "Must detect every inserted hard cut")
let report:[String:Any]=["passed":true,"scope":"Offline decoded motion fixture; does not measure headset perception", "insertedCuts":insertedCuts,"frames":frames,"newCuts":newCuts,"oldCuts":oldCuts,"readerStatus":reader.status.rawValue]
print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
