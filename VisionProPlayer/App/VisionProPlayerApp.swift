import SwiftUI

@main
struct VisionProPlayerApp: App {
    @State private var model = PlayerModel()
    @State private var immersionStyle: ImmersionStyle = .mixed

    var body: some Scene {
        WindowGroup(id: "main") {
            LibraryView(model: model)
                .onChange(of: model.library.darkCinema, initial: true) { _, dark in immersionStyle = dark ? .full : .mixed }
        }
        .defaultSize(width: 1080, height: 760)
        ImmersiveSpace(id: "Cinema") { CinemaScene(model: model) }
            .immersionStyle(selection: $immersionStyle, in: .mixed, .full)
    }
}
