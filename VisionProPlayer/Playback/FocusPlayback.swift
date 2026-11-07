import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class FocusPlayback {
    private(set) var visible = true
    @ObservationIgnored private var lastInteraction = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored private var holds: Set<String> = []

    func reveal(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if !visible { visible = true }
        lastInteraction = time
    }
    func hold(_ key: String, _ active: Bool, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if active { holds.insert(key) } else { holds.remove(key) }
        reveal(at: time)
    }
    func update(enabled: Bool, playing: Bool, blocked: Bool, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if !enabled || !playing || blocked || !holds.isEmpty { reveal(at: time) }
        else if visible && time - lastInteraction >= 3 { visible = false }
    }
}

struct FocusPlaybackModifier: ViewModifier {
    let model: PlayerModel
    func body(content: Content) -> some View {
        content
            .onChange(of: model.isPlaying) { _, _ in model.focus.reveal() }
            .onChange(of: model.request?.id) { _, _ in model.focus.reveal() }
            .task {
                model.focus.reveal()
                while !Task.isCancelled {
                    model.focus.update(enabled: model.library.focusViewing, playing: model.isPlaying,
                        blocked: model.hasEnded || model.request == nil || model.errorMessage != nil
                            || model.rendererError != nil || model.loadingTitle != nil)
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
    }
}
