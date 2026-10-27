import CastMirrorCore
import ReplayKit
import SwiftUI

/// The container app only finds the Chromecast (which also makes iOS ask for
/// Local Network access) and starts the broadcast. The broadcast extension
/// does the streaming.
struct ContentView: View {
    @StateObject private var finder = ChromecastFinder()
    @StateObject private var relay = SettingsRelay()
    @AppStorage(SettingsRelay.showStatsKey) private var showStats = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                Section("1. Find your Chromecast") {
                    if finder.devices.isEmpty {
                        Text(finder.searching
                             ? "Looking…"
                             : "None found. Check the phone is on the same Wi-Fi as the TV. If iOS asked about Local Network access, it needs to be allowed.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(finder.devices, id: \.self) { device in
                        VStack(alignment: .leading) {
                            Text(device.name)
                            if !device.model.isEmpty {
                                Text(device.model).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button(finder.searching ? "Searching…" : "Search again") { finder.search() }
                        .disabled(finder.searching)
                }

                Section("2. Start mirroring") {
                    HStack(spacing: 16) {
                        BroadcastButton()
                            .frame(width: 56, height: 56)
                        Text("Tap the button, then Start Broadcast.")
                    }
                    Text("You can also long-press Screen Recording in Control Center and choose CastMirror.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("3. Watch") {
                    Text("Open your video app. The picture shows on the TV about half a second behind the phone. Sound plays from the phone.")
                    Text("To stop, tap the red recording indicator at the top of the screen.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Show stats on the TV", isOn: $showStats)
                } footer: {
                    Text("Frame rate, buffer and network figures over the picture, for checking the delay. Changes apply straight away while mirroring.")
                }
            }
            .navigationTitle("CastMirror")
        }
        .onAppear {
            finder.search()
            relay.start()
        }
        .onChange(of: showStats) { _, show in OptionsChannel.post(showStats: show) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { relay.send() }
        }
    }
}

/// Sends the app's settings to the broadcast extension, which can't read
/// them itself: on each change, when the app comes back, and when a
/// broadcast starts (the app is still open behind the broadcast sheet then).
final class SettingsRelay: ObservableObject {
    static let showStatsKey = "showStats"

    private var observation: OptionsChannel.Observation?

    func start() {
        guard observation == nil else { return }
        observation = OptionsChannel.observeStarted(queue: .main) { [weak self] in self?.send() }
    }

    func send() {
        OptionsChannel.post(showStats: UserDefaults.standard.bool(forKey: Self.showStatsKey))
    }
}

final class ChromecastFinder: ObservableObject {
    @Published var devices: [Chromecast] = []
    @Published var searching = false

    private let browser = ChromecastBrowser()

    func search() {
        searching = true
        browser.stop()
        browser.onChange = { [weak self] devices in
            DispatchQueue.main.async { self?.devices = devices }
        }
        browser.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.searching = false
        }
    }
}

/// The system broadcast picker, pointed at CastMirror's extension.
struct BroadcastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 56, height: 56))
        picker.preferredExtension = Self.extensionBundleID
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ view: RPSystemBroadcastPickerView, context: Context) {}

    /// Read from the app bundle rather than hard-coded, because sideloading
    /// tools can change bundle IDs when they sign the app.
    static var extensionBundleID: String? {
        guard let plugIns = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil) else { return nil }
        return items.filter { $0.pathExtension == "appex" }.compactMap { Bundle(url: $0)?.bundleIdentifier }.first
    }
}
