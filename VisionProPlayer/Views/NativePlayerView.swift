import AVKit
import SwiftUI

struct NativePlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
    }
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player = nil
    }
}

struct VLCPlayerView: UIViewRepresentable {
    let model: PlayerModel
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        model.attachVLC(to: view)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}


final class NativeVideoUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var videoLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
struct NativeVideoSurface: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> NativeVideoUIView {
        let view = NativeVideoUIView(); view.videoLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black; view.videoLayer.player = player
        return view
    }
    func updateUIView(_ view: NativeVideoUIView, context: Context) { view.videoLayer.player = player }
    static func dismantleUIView(_ view: NativeVideoUIView, coordinator: ()) { view.videoLayer.player = nil }
}
