import DisplayBridgeCore
import SwiftUI

/// The source's display, edge to edge, with a small button to leave.
struct StreamScreen: View {
    @EnvironmentObject private var model: SinkModel

    var body: some View {
        SinkSurface(view: model.surface)
            .ignoresSafeArea()
            .overlay(alignment: .topTrailing) {
                Button {
                    model.disconnect()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(12)
                }
                .accessibilityLabel("Disconnect")
            }
            .hideSystemChrome()
    }
}

/// Puts the model's `DisplaySinkView` into the SwiftUI hierarchy.
#if os(iOS)
private struct SinkSurface: UIViewRepresentable {
    let view: DisplaySinkView
    func makeUIView(context: Context) -> DisplaySinkView { view }
    func updateUIView(_ uiView: DisplaySinkView, context: Context) {}
}
#else
private struct SinkSurface: NSViewRepresentable {
    let view: DisplaySinkView
    func makeNSView(context: Context) -> DisplaySinkView { view }
    func updateNSView(_ nsView: DisplaySinkView, context: Context) {}
}
#endif

private extension View {
    /// A monitor shows no status bar and no home indicator.
    func hideSystemChrome() -> some View {
        #if os(iOS)
        return statusBarHidden().persistentSystemOverlays(.hidden)
        #else
        return self
        #endif
    }
}
