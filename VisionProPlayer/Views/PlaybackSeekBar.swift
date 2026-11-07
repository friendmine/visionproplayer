import SwiftUI

struct PlaybackSeekBar: View {
    let model: PlayerModel
    let holdKey: String
    @State private var fraction = 0.0
    @State private var draggingID: UUID?
    @State private var released: SeekDestination?
    @State private var resultTime: Double?
    @State private var reachedTarget = false

    private struct SeekDestination: Identifiable {
        let id = UUID()
        let requestID: UUID
        let seconds: Double
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 2) {
                Text(draggingID != nil ? "目标" : resultTime != nil ? (reachedTarget ? "已跳至" : "当前位置") : "已播放")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(PlayerModel.clock(draggingID != nil ? fraction * model.duration : resultTime ?? model.elapsed))
                    .monospacedDigit()
            }.frame(minWidth: 64)
            Slider(value: Binding(get: { fraction }, set: { value in
                fraction = value
                preview()
                #if DEBUG
                model.seekPreview.recordUIEvent("slider-value", details: ["surface": holdKey, "dragging": draggingID != nil,
                    "playing": model.isPlaying, "fraction": value])
                #endif
            }), in: 0...1, onEditingChanged: edit)
                .disabled(!model.isSeekable)
                .frame(minHeight: 44)
                .accessibilityLabel("播放进度")
                .accessibilityValue(PlayerModel.clock(fraction * model.duration))
            Text(PlayerModel.clock(model.duration)).monospacedDigit().frame(minWidth: 60)
        }
        .onChange(of: model.progress, initial: true) { _, value in
            if draggingID == nil { fraction = value }
        }
        .onChange(of: model.request?.id) { _, _ in dismissPreview(); clearFeedback(); fraction = model.progress }
        .onChange(of: model.isSeekable) { _, seekable in if !seekable { dismissPreview() } }
        .task(id: released?.id) {
            guard let destination = released else { return }
            // Read the decoder clock, since progress is set optimistically by seek().
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, destination.requestID == model.request?.id else { return }
                if abs(model.elapsed - destination.seconds) < 1 { break }
            }
            resultTime = model.elapsed
            reachedTarget = abs(model.elapsed - destination.seconds) < 1
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { clearFeedback() }
        }
        .onDisappear { dismissPreview(); clearFeedback() }
    }

    private func edit(_ editing: Bool) {
        #if DEBUG
        model.seekPreview.recordUIEvent(editing ? "slider-begin" : "slider-end", details: ["surface": holdKey,
            "seekable": model.isSeekable, "playing": model.isPlaying])
        #endif
        if editing {
            guard let request = model.request, model.isSeekable else { return }
            clearFeedback()
            draggingID = request.id
            model.focus.hold(holdKey, true)
            preview()
        } else {
            let commit = draggingID != nil && draggingID == model.request?.id && model.isSeekable
            dismissPreview()
            if commit, let id = model.request?.id {
                released = SeekDestination(requestID: id, seconds: fraction * model.duration)
                model.seek(to: fraction)
            }
        }
    }

    private func clearFeedback() {
        released = nil
        resultTime = nil
    }

    private func preview() {
        guard let request = model.request, draggingID == request.id else { return }
        model.seekPreview.show(request: request, fraction: fraction, duration: model.duration, swapped: model.swapEyes, asset: model.nativePlayer?.currentItem?.asset)
    }

    private func dismissPreview() {
        guard let draggingID else { return }
        if model.seekPreview.activeID == draggingID { model.seekPreview.end() }
        self.draggingID = nil
        model.focus.hold(holdKey, false)
    }
}

struct SeekPreviewControlsRow<Controls: View>: View {
    let model: PlayerModel
    let surface: String
    @ViewBuilder var controls: () -> Controls

    private var active: Bool {
        model.seekPreview.activeID != nil && model.seekPreview.activeID == model.request?.id
    }

    var body: some View {
        ZStack {
            controls().opacity(active ? 0 : 1).allowsHitTesting(!active).accessibilityHidden(active)
            if active { SeekPreviewCard(preview: model.seekPreview, surface: surface) }
        }
        // Reserve the same row while dragging so neither the slider nor movie moves.
        .frame(height: 80)
        .frame(maxWidth: .infinity)
    }
}

struct SeekPreviewCard: View {
    let preview: SeekPreview
    let surface: String
    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let frame = preview.frame {
                    Image(decorative: frame.image, scale: 1)
                        .resizable().aspectRatio(frame.aspect, contentMode: .fit)
                } else if preview.unavailable {
                    Text("此处暂无预览").font(.caption)
                } else if preview.activeID != nil {
                    ProgressView()
                }
            }.frame(width: 132, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text("跳转到").font(.caption2).foregroundStyle(.secondary)
                Text(PlayerModel.clock(preview.requestedSeconds)).font(.headline).monospacedDigit()
                if let frame = preview.frame, abs(frame.seconds - preview.requestedSeconds) > 1 {
                    Text("预览 " + PlayerModel.clock(frame.seconds)).font(.caption2).monospacedDigit()
                }
            }.frame(minWidth: 76, alignment: .leading)
        }
        .padding(8)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.3)) }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        #if DEBUG
        .onAppear { preview.recordUIEvent("card-appeared", details: ["surface": surface]) }
        .onDisappear { preview.recordUIEvent("card-disappeared", details: ["surface": surface]) }
        .onChange(of: preview.frame?.seconds) { _, seconds in
            if let seconds { preview.recordUIEvent("card-frame", details: ["surface": surface, "displayTime": seconds]) }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            preview.recordUIEvent("card-size", details: ["surface": surface, "width": size.width, "height": size.height])
        }
        #endif
    }
}
