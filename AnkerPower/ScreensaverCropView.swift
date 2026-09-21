import AppKit
import SwiftUI

struct ScreensaverCropView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var preferences: AppPreferences
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isScreenshotExport) private var isScreenshotExport

    @State private var crop = ScreensaverImage.Crop.identity
    @State private var dragStart = CGSize.zero
    @State private var magnifyStart: CGFloat = 1

    init(model: AppModel) {
        self.model = model
        _preferences = ObservedObject(wrappedValue: model.preferences)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Screensaver")
                .font(.headline)
            Text("Drag to pan, scroll or pinch to zoom. A square \(ScreensaverImage.pixelSize)×\(ScreensaverImage.pixelSize) photo is ideal; larger images are cropped. The charger keeps four images; a fifth replaces the oldest.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            cropCanvas
                .frame(width: 280, height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )

            HStack(alignment: .top, spacing: 12) {
                previewThumb
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(
                        "Soft black border",
                        isOn: Binding(
                            get: { preferences.screensaverVignetteEnabled },
                            set: { preferences.setScreensaverVignetteEnabled($0) }
                        )
                    )
                    .disabled(isBusy)
                    if let counts = model.screensaverProgress.uploadCounts {
                        ProgressView(value: Double(counts.current), total: Double(counts.total))
                    }
                    if let label = model.screensaverProgress.label {
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(failed ? .red : .secondary)
                    }
                }
            }

            HStack {
                Button("Cancel") {
                    model.cancelScreensaverCrop()
                    dismiss()
                }
                .disabled(isBusy)
                Spacer()
                Button("Send to charger") {
                    send()
                }
                .disabled(!model.canControlPorts || isBusy || model.screensaverCropImage == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onChange(of: model.screensaverProgress) { _, progress in
            if progress == .succeeded {
                dismiss()
            }
        }
        .onChange(of: model.screensaverCropImage) { _, image in
            if image == nil { dismiss() }
        }
    }

    private var isBusy: Bool {
        switch model.screensaverProgress {
        case .selecting, .uploading, .verifying: return true
        default: return false
        }
    }

    private var failed: Bool {
        if case .failed = model.screensaverProgress { return true }
        return false
    }

    private var cropCanvas: some View {
        let canvasSize = CGSize(width: 280, height: 280)
        return ZStack {
            Color.black
            if let rendered = renderedPreview {
                Image(decorative: rendered, scale: 1)
                    .resizable()
                    .interpolation(.high)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .contentShape(Rectangle())
        .gesture(dragGesture(in: canvasSize))
        .gesture(magnifyGesture)
        .overlay {
            if !isScreenshotExport {
                ScrollWheelCatcher { delta in
                    crop.zoom = min(6, max(1, crop.zoom + CGFloat(delta) * 0.02))
                    clampPan()
                }
                .allowsHitTesting(false)
            }
        }
    }

    private var renderedPreview: CGImage? {
        guard let image = model.screensaverCropImage else { return nil }
        return ScreensaverImage.render(
            image: image,
            crop: crop,
            vignette: preferences.screensaverVignetteEnabled
        )
    }

    private var previewThumb: some View {
        Group {
            if let rendered = renderedPreview {
                Image(decorative: rendered, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: 64, height: 64)
            }
        }
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let dx = -value.translation.width / max(size.width / 2, 1)
                let dy = -value.translation.height / max(size.height / 2, 1)
                crop.pan = CGSize(
                    width: dragStart.width + dx,
                    height: dragStart.height + dy
                )
                clampPan()
            }
            .onEnded { _ in
                dragStart = crop.pan
            }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                crop.zoom = min(6, max(1, magnifyStart * value))
                clampPan()
            }
            .onEnded { _ in
                magnifyStart = crop.zoom
            }
    }

    private func clampPan() {
        crop.pan.width = min(max(crop.pan.width, -1), 1)
        crop.pan.height = min(max(crop.pan.height, -1), 1)
    }

    private func send() {
        guard let image = model.screensaverCropImage else { return }
        model.uploadScreensaver(
            image: image,
            crop: crop,
            vignette: preferences.screensaverVignetteEnabled
        )
    }
}

private struct ScrollWheelCatcher: NSViewRepresentable {
    var onScroll: (Double) -> Void

    func makeNSView(context: Context) -> ScrollWheelView {
        let view = ScrollWheelView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollWheelView, context: Context) {
        nsView.onScroll = onScroll
    }
}

private final class ScrollWheelView: NSView {
    var onScroll: ((Double) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

#Preview("Screensaver crop") {
    let model = PreviewSample.connectedModel()
    if let image = PreviewSample.screensaverPreviewImage().screensaverCGImage {
        model.beginScreensaverCrop(image: image)
    }
    return ScreensaverCropView(model: model)
}
