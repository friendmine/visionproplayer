import SwiftUI

@main
struct VisionProPlayerApp: App {
    @State private var model = PlayerModel()

    var body: some Scene {
        WindowGroup {
            LibraryView(model: model)
        }
        .defaultSize(width: 1080, height: 760)
    }
}
