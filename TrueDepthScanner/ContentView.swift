import SwiftUI

struct ContentView: View {
    @StateObject private var model = DepthViewModel()
    @State private var dimmer = ScreenDimmer()
    /// Compact height = iPhone in landscape.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        Group {
            if verticalSizeClass == .compact {
                // Landscape: just the picture, full screen, no controls.
                picture
                    .ignoresSafeArea()
            } else {
                // Portrait: the picture fills everything from the top of the screen down to the controls.
                VStack(spacing: 0) {
                    picture
                        .ignoresSafeArea(edges: .top)
                    controls
                        .padding(.top, 6)
                        .padding(.bottom, 4)
                }
            }
        }
        .background(Color.black)
        .onAppear {
            model.watchOrientation()
            model.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .sheet(item: $model.exportFile) { file in
            ShareSheet(url: file.url)
        }
        .alert("Export failed",
               isPresented: Binding(get: { model.errorMessage != nil },
                                    set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// The lines, or a status message. The sides (or top and bottom) are cropped to fit.
    private var picture: some View {
        Color.black.overlay {
            switch model.status {
            case .starting:
                ProgressView("Starting camera…")
            case .denied:
                message("Camera access is off",
                        "Turn it on in Settings → Privacy & Security → Camera.")
            case .failed(let reason):
                message("Camera unavailable", reason)
            case .running:
                depthView
            }
        }
        .clipped()
    }

    private var depthView: some View {
        // The lines may be larger than the visible area; the parent crops the sides.
        Color.clear
            .overlay {
                if let lines = model.lines {
                    DepthLinesView(lines: lines, relief: model.relief, thickness: model.lineWidth,
                                   topRise: model.topRise, bottomRise: model.bottomRise,
                                   // Landscape screens are much wider than the camera's 4:3 picture;
                                   // filling would crop off the top and bottom, so show it whole.
                                   contentMode: verticalSizeClass == .compact ? .fit : .fill)
                        // The lines arrive mirrored like a selfie; flip them back when Mirror is off.
                        .scaleEffect(x: model.mirrored ? 1 : -1)
                }
            }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Height")
                Slider(value: $model.relief, in: 3...40)
            }
            HStack {
                Text("Thickness")
                Slider(value: $model.lineWidth, in: 0.1...0.9)
            }
            Toggle("Smooth depth", isOn: $model.smoothing)

            HStack {
                if model.isCaptured {
                    Button { model.resume() } label: {
                        Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button { model.export() } label: {
                        Label(model.isExporting ? "Exporting…" : "Export PLY",
                              systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isExporting || model.cloud.count == 0)
                } else {
                    Button { model.capture() } label: {
                        Label("Capture", systemImage: "camera.metering.matrix").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Toggle(isOn: $model.mirrored) {
                    Label("Mirror", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .labelStyle(.iconOnly)
            }
            .controlSize(.large)

            if model.isCaptured {
                Text("\(model.cloud.count.formatted()) points captured")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .disabled(model.status != .running)
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
