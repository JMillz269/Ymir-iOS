import SwiftUI
import UniformTypeIdentifiers

// MARK: - Setting bindings

/// Bindings to the emulator's settings. Every value is read from, and written straight to, the emulator.
final class SettingStore: ObservableObject {
    static let shared = SettingStore()

    func bool(_ key: String, default defaultValue: Bool = false) -> Binding<Bool> {
        Binding(
            get: { YmirHost.boolValue(key: key, default: defaultValue) },
            set: { [weak self] value in
                YmirHost.setBoolValue(value, key: key)
                self?.objectWillChange.send()
            }
        )
    }

    func int(_ key: String, default defaultValue: Int = 0) -> Binding<Int> {
        Binding(
            get: { YmirHost.intValue(key: key, default: defaultValue) },
            set: { [weak self] value in
                YmirHost.setIntValue(value, key: key)
                self?.objectWillChange.send()
            }
        )
    }

    /// An integer setting edited with a slider.
    func intSlider(_ key: String, default defaultValue: Int = 0) -> Binding<Double> {
        Binding(
            get: { Double(YmirHost.intValue(key: key, default: defaultValue)) },
            set: { [weak self] value in
                YmirHost.setIntValue(Int(value.rounded()), key: key)
                self?.objectWillChange.send()
            }
        )
    }

    func float(_ key: String, default defaultValue: Double = 0) -> Binding<Double> {
        Binding(
            get: { Double(YmirHost.floatValue(key: key, default: Float(defaultValue))) },
            set: { [weak self] value in
                YmirHost.setFloatValue(Float(value), key: key)
                self?.objectWillChange.send()
            }
        )
    }
}

// MARK: - Reusable rows

/// A slider with a title and the current value on top.
private struct SettingSlider: View {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    var step: Double = 0.01
    var format: (Double) -> String = { String(format: "%.0f%%", $0 * 100) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
        .padding(.vertical, 2)
    }
}

private func percent(_ value: Double) -> String {
    String(format: "%.0f%%", value * 100)
}

// MARK: - Settings home

/// A one-tap bundle of speed and accuracy options. The same bundles back the presets in Advanced.
enum PerformanceProfile: String, CaseIterable, Identifiable {
    case speed, balanced, accuracy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .speed: return "Speed"
        case .balanced: return "Balanced"
        case .accuracy: return "Accuracy"
        }
    }

    func apply(to store: SettingStore) {
        let values: (sh2Cache: Bool, interpolation: Int, granularity: Int, smooth: Bool)
        switch self {
        case .speed: values = (false, 0, 0, true)
        case .balanced: values = (false, 1, 0, true)
        case .accuracy: values = (true, 1, 5, false)
        }
        let (sh2Cache, interpolation, granularity, smooth) = values
        store.bool("audio.threadedSCSP").wrappedValue = smooth
        store.int("video.framePacing").wrappedValue = smooth ? 1 : 0
        store.int("video.frameDelay").wrappedValue = smooth ? 1 : 0
        store.bool("system.emulateSH2Cache").wrappedValue = sh2Cache
        store.intSlider("system.sh2ClockFactor").wrappedValue = 100
        store.int("audio.interpolation").wrappedValue = interpolation
        store.int("audio.stepGranularity").wrappedValue = granularity
        store.intSlider("cdblock.readSpeed").wrappedValue = 2
        store.bool("cdblock.useLLE").wrappedValue = false
    }

    /// The profile the current options match, or nil when they have been tuned by hand.
    static var current: PerformanceProfile? {
        let cache = YmirHost.boolValue(key: "system.emulateSH2Cache", default: false)
        let pacing = YmirHost.intValue(key: "video.framePacing", default: 1)
        let interpolation = YmirHost.intValue(key: "audio.interpolation", default: 1)
        let granularity = YmirHost.intValue(key: "audio.stepGranularity", default: 0)
        if cache && pacing == 0 && granularity == 5 { return .accuracy }
        if !cache && pacing == 1 && interpolation == 0 { return .speed }
        if !cache && pacing == 1 && interpolation == 1 && granularity == 0 { return .balanced }
        return nil
    }
}

/// A rounded, coloured icon tile in the style of the iOS Settings app.
private struct SettingsIcon: View {
    let systemName: String
    let tint: Color
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(tint)
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5)
            Image(systemName: systemName)
                .font(.system(size: size * 0.54, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

/// The content of a row inside a glass settings group: icon, title, current value and a chevron.
private struct SettingsRowLabel: View {
    let icon: String
    let tint: Color
    let title: String
    var value: String?
    var showsChevron = true

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(systemName: icon, tint: tint)
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

private struct SettingsNavRow<Destination: View>: View {
    let icon: String
    let tint: Color
    let title: String
    var value: String?
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            SettingsRowLabel(icon: icon, tint: tint, title: title, value: value)
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsRowDivider: View {
    var body: some View {
        Divider().padding(.leading, 56)
    }
}

/// A titled group of rows on one Liquid Glass card, with an optional footnote underneath.
private struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.leading, 16)
            }
            VStack(spacing: 0) {
                content()
            }
            .ymirGlassCard()
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
        }
    }
}

/// The app's settings. Everything that was in the desktop frontend's menus and settings window lives here.
struct SettingsView: View {
    @ObservedObject private var store = SettingStore.shared
    @State private var hasBIOS = YmirHost.hasBIOS
    @State private var biosName = YmirHost.biosName
    @State private var showImporter = false
    @State private var isImporting = false
    @State private var biosAlert: String?

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private var profile: Binding<PerformanceProfile?> {
        Binding(
            get: { PerformanceProfile.current },
            set: { newValue in
                if let newValue {
                    newValue.apply(to: store)
                }
            }
        )
    }

    private var displayValue: String {
        let renderer = YmirHost.boolValue(key: "video.metalRenderer", default: false) ? "Metal" : "Software"
        return YmirHost.boolValue(key: "video.sharpPixels", default: false) ? renderer + " · Sharp" : renderer
    }

    private var audioValue: String {
        if YmirHost.boolValue(key: "audio.mute", default: false) { return "Muted" }
        let volume = Double(YmirHost.floatValue(key: "audio.volume", default: 1))
        return String(format: "%.0f%%", volume * 100)
    }

    private var controlsValue: String {
        YmirHost.boolValue(key: "touch.enabled", default: true) ? "Touch" : "Off"
    }

    private var emulationValue: String {
        if YmirHost.boolValue(key: "general.rewind", default: false) { return "Rewind on" }
        return YmirHost.boolValue(key: "general.useAltSpeed", default: false) ? "Alt speed" : "Normal"
    }

    private var systemValue: String {
        YmirHost.boolValue(key: "system.autodetectRegion", default: true) ? "Auto" : "Manual"
    }

    private var advancedValue: String {
        YmirHost.jitAvailable && YmirHost.boolValue(key: "system.useRecompiler", default: false) ? "JIT" : "Interpreter"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                biosCard

                SettingsGroup(
                    title: "Performance profile",
                    footer: "Sets several speed and accuracy options at once. Fine-tune them under Advanced."
                ) {
                    Picker("Performance profile", selection: profile) {
                        ForEach(PerformanceProfile.allCases) { item in
                            Text(item.label).tag(Optional(item))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(10)
                }

                SettingsGroup {
                    SettingsNavRow(icon: "tv", tint: .blue, title: "Display", value: displayValue) {
                        DisplaySettingsView()
                    }
                    SettingsRowDivider()
                    SettingsNavRow(icon: "speaker.wave.2.fill", tint: .red, title: "Audio", value: audioValue) {
                        AudioSettingsView()
                    }
                    SettingsRowDivider()
                    SettingsNavRow(icon: "gamecontroller.fill", tint: .gray, title: "Controls", value: controlsValue) {
                        ControlsSettingsView()
                    }
                    SettingsRowDivider()
                    SettingsNavRow(icon: "forward.frame.fill", tint: .green, title: "Emulation", value: emulationValue) {
                        EmulationSettingsView()
                    }
                }

                SettingsGroup(title: "Console") {
                    SettingsNavRow(icon: "globe", tint: .purple, title: "System & Region", value: systemValue) {
                        SystemSettingsView()
                    }
                    SettingsRowDivider()
                    SettingsNavRow(icon: "memorychip", tint: .indigo, title: "Cartridge") {
                        CartridgeSettingsView()
                    }
                    SettingsRowDivider()
                    SettingsNavRow(icon: "opticaldisc", tint: .cyan, title: "CD Drive") {
                        CDBlockSettingsView()
                    }
                }

                SettingsGroup(title: "More") {
                    SettingsNavRow(icon: "speedometer", tint: .orange, title: "Advanced", value: advancedValue) {
                        PerformanceSettingsView()
                    }
                    SettingsRowDivider()
                    SettingsNavRow(icon: "rectangle.on.rectangle", tint: .pink, title: "Interface") {
                        InterfaceSettingsView()
                    }
                }

                SettingsGroup(
                    title: "Files",
                    footer: "Games, BIOS images, save data and screenshots live in the Ymir folder, which is visible in the Files app."
                ) {
                    SettingsNavRow(icon: "clock.arrow.circlepath", tint: .teal, title: "Save States") {
                        SaveStateManagerView()
                    }
                    SettingsRowDivider()
                    Button {
                        FilesApp.openDocuments()
                    } label: {
                        SettingsRowLabel(icon: "folder.fill", tint: .gray, title: "Open Ymir Folder in Files", showsChevron: false)
                    }
                    .buttonStyle(.plain)
                }

                Text("Ymir \(version) · Sega Saturn emulator")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(YmirBackdrop())
        .onAppear {
            hasBIOS = YmirHost.hasBIOS
            biosName = YmirHost.biosName
        }
        .overlay {
            if isImporting {
                ProgressView("Loading BIOS…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            importBIOS(urls)
        }
        .alert("BIOS Not Recognized", isPresented: Binding(get: { biosAlert != nil }, set: { if !$0 { biosAlert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(biosAlert ?? "")
        }
    }

    /// The BIOS is the one thing the app can't run without, so its state sits on top as a status card.
    private var biosCard: some View {
        HStack(spacing: 12) {
            SettingsIcon(systemName: "cpu", tint: hasBIOS ? .green : .orange, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(hasBIOS ? "Saturn BIOS ready" : "BIOS required")
                    .font(.headline)
                Text(hasBIOS ? biosName : "Import a Sega Saturn BIOS (IPL ROM) to run games.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(hasBIOS ? "Replace" : "Import") {
                showImporter = true
            }
            .ymirSecondaryButton()
            .controlSize(.small)
        }
        .padding(14)
        .ymirGlassCard()
    }

    private func importBIOS(_ urls: [URL]) {
        isImporting = true
        Task {
            _ = await Task.detached(priority: .userInitiated) { () -> ImportService.Outcome in
                ImportService.copy(urls, to: AppPaths.bios)
            }.value
            let error = YmirHost.reloadBIOS()
            hasBIOS = YmirHost.hasBIOS
            biosName = YmirHost.biosName
            isImporting = false
            if !hasBIOS {
                biosAlert = error ?? "That file doesn't look like a valid Sega Saturn BIOS. Try a different image."
            }
        }
    }
}

// MARK: - Display

struct DisplaySettingsView: View {
    @ObservedObject private var store = SettingStore.shared

    var body: some View {
        Form {
            Section("Scaling") {
                Toggle("Stretch to Fill Screen", isOn: store.bool("video.forceStretch"))
                SettingSlider(title: "Extra Portrait Height", value: store.float("video.portraitStretch", default: 0),
                              range: 0...1, format: percent)
                    .disabled(!YmirHost.boolValue(key: "video.forceStretch", default: false))
                Toggle("Integer Scaling", isOn: store.bool("video.forceIntegerScaling"))
                    .disabled(YmirHost.boolValue(key: "video.forceStretch", default: false))
                Toggle("Force Aspect Ratio", isOn: store.bool("video.forceAspectRatio", default: true))
                Picker("Aspect Ratio", selection: store.int("video.aspect")) {
                    Text("4:3").tag(0)
                    Text("3:2").tag(1)
                    Text("16:10").tag(2)
                    Text("16:9").tag(3)
                }
                .disabled(!YmirHost.boolValue(key: "video.forceAspectRatio", default: true)
                    || YmirHost.boolValue(key: "video.forceStretch", default: false))
                Picker("Rotation", selection: store.int("video.rotation")) {
                    Text("None").tag(0)
                    Text("90° Clockwise").tag(1)
                    Text("180°").tag(2)
                    Text("90° Counterclockwise").tag(3)
                }
            }

            Section {
                Picker("MetalFX", selection: store.int("video.upscaling")) {
                    Text("Off").tag(0)
                    Text("Spatial").tag(1)
                    Text("Temporal").tag(2)
                }
                .disabled(!YmirHost.boolValue(key: "video.upscalingSupported", default: false))
            } header: {
                Text("Upscaling")
            } footer: {
                Text("MetalFX upscales the game's image with the GPU. Spatial works on each frame on its own and looks cleaner and sharper than plain scaling. Temporal also blends in previous frames for extra stability, but the Saturn's 2D video has no motion data, so fast movement can show slight ghosting.")
            }

            Section {
                Toggle("Sharp Pixels", isOn: store.bool("video.sharpPixels"))
                SettingSlider(title: "Sharpening", value: store.float("video.sharpness"), range: 0...1, format: percent)
                SettingSlider(title: "Scanlines", value: store.float("video.scanlines"), range: 0...1, format: percent)
                SettingSlider(title: "Aperture Grille", value: store.float("video.mask"), range: 0...1, format: percent)
            } header: {
                Text("Picture Filters")
            } footer: {
                Text("Sharp Pixels keeps every game pixel crisp and only smooths its edges, which looks better than plain smooth scaling. Sharpening adds crispness after upscaling. Scanlines and the aperture grille imitate a CRT TV; they look best on a high resolution screen like yours.")
            }

            Section {
                Toggle("Metal Renderer (Experimental)", isOn: store.bool("video.metalRenderer"))
                Toggle("Draw Polygons and Sprites on GPU (Experimental)", isOn: store.bool("video.metalVDP1"))
                    .disabled(!store.bool("video.metalRenderer").wrappedValue)
                Toggle("Direct Display", isOn: store.bool("video.metalDirectDisplay"))
                    .disabled(!store.bool("video.metalRenderer").wrappedValue)
            } header: {
                Text("Graphics Chip")
            } footer: {
                Text("The Metal renderer draws the Saturn's second video chip (backgrounds, the sprite layer and the final mix) with the GPU, which takes a lot of work off the processor and reduces heat. The second switch moves the first video chip (polygons, sprites and lines) to the GPU as well; it needs the Metal renderer. Direct Display hands the picture straight to the screen on the GPU instead of copying it through the processor, which is faster and saves a frame of delay; turn it off if the picture misbehaves. Internal Resolution, Transparent Meshes and Deinterlacing need the first two switches on.")
            }

            Section {
                Picker("Internal Resolution", selection: store.int("video.internalResolution", default: 1)) {
                    Text("Native").tag(1)
                    Text("2×").tag(2)
                    Text("3×").tag(3)
                    Text("4×").tag(4)
                }
                Toggle("Skip Native Drawing (Experimental)", isOn: store.bool("video.skipNativeVDP1"))
            } header: {
                Text("Resolution")
            } footer: {
                Text("Draws the game's 3D models, sprites and lines at several times the Saturn's own resolution, so their edges are smooth and detailed instead of blocky. Backgrounds drawn by the Saturn's second video chip stay at their original sharpness. Higher values need much more processing power. Modes that can't be enlarged (high resolution screens, interlaced video, 8-bit or rotated sprite buffers) are drawn at native resolution. Skip Native Drawing saves processing power by no longer drawing everything a second time at the original size; the original-size picture the game can read back is then copied from the enlarged one at the end of each frame, so games that read the picture while it is still being drawn may misbehave.")
            }

            Section {
                Toggle("Deinterlacing", isOn: store.bool("video.deinterlace"))
                Toggle("Transparent Meshes", isOn: store.bool("video.transparentMeshes"))
            } header: {
                Text("Enhancements")
            } footer: {
                Text("Deinterlacing smooths high resolution interlaced video. Transparent meshes replaces the checkerboard patterns games use for transparency with real transparency.")
            }

            Section {
                Toggle("Video Sync", isOn: store.bool("video.sync", default: true))
                Picker("Frame Pacing", selection: store.int("video.framePacing", default: 1)) {
                    Text("Exact Speed").tag(0)
                    Text("Match Display").tag(1)
                }
                .disabled(!store.bool("video.sync", default: true).wrappedValue)
                Picker("Frame Delay", selection: store.int("video.frameDelay")) {
                    Text("Off").tag(0)
                    Text("Auto").tag(1)
                }
                .disabled(!store.bool("video.sync", default: true).wrappedValue)
                Toggle("Use Full Refresh Rate", isOn: store.bool("video.fullRefreshRate"))
                Toggle("Reduce Latency", isOn: store.bool("video.reduceLatency"))
            } header: {
                Text("Synchronization")
            } footer: {
                Text("Video sync paces emulation to the display. Frame Pacing picks how: Exact Speed runs the game at the Saturn's own rate (59.83 frames per second), so about every 6 seconds one frame stays on the screen twice as long. Match Display shows exactly one game frame per display refresh for the smoothest motion; the game and its sound then run 0.3% faster, which you can't hear. Frame Delay lowers input lag: Auto starts emulating each frame as late as the spare time allows (the phone usually finishes a frame in a third of the time it has), so the game reads your controls closer to when the picture is shown, up to 12 ms later. It backs off by itself in heavy scenes; turn it off if you see stutter. Use Full Refresh Rate does nothing with Match Display. Reduce Latency helps on displays with a low refresh rate.")
            }
        }
        .navigationTitle("Display")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Audio

struct AudioSettingsView: View {
    @ObservedObject private var store = SettingStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("Mute", isOn: store.bool("audio.mute"))
                SettingSlider(title: "Volume", value: store.float("audio.volume", default: 1), range: 0...1, format: percent)
            }

            Section {
                Picker("Interpolation", selection: store.int("audio.interpolation", default: 1)) {
                    Text("Nearest Neighbor").tag(0)
                    Text("Linear").tag(1)
                }
                Toggle("Multithreaded SCSP", isOn: store.bool("audio.threadedSCSP"))
                Stepper(
                    "Step Granularity: \(store.int("audio.stepGranularity").wrappedValue)",
                    value: store.int("audio.stepGranularity"),
                    in: 0...5
                )
            } header: {
                Text("Sound Chip")
            } footer: {
                Text("Linear interpolation matches the real SCSP. Higher step granularity is more accurate and slower.")
            }
        }
        .navigationTitle("Audio")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Controls

struct ControlsSettingsView: View {
    @ObservedObject private var store = SettingStore.shared

    private static let peripherals = [
        (0, "None"), (1, "Saturn Control Pad"), (2, "Saturn 3D Control Pad"), (3, "Arcade Racer"),
        (4, "Mission Stick"), (5, "Virtua Gun"), (6, "Shuttle Mouse"),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("On-Screen Controls", isOn: store.bool("touch.enabled", default: true))
                Button {
                    YmirShell.beginTouchEditing()
                } label: {
                    Label("Customize Layout…", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                }
                SettingSlider(title: "Size", value: store.float("touch.globalScale", default: 1), range: 0.5...1.6,
                              format: percent)
                SettingSlider(title: "Opacity", value: store.float("touch.opacity", default: 0.9), range: 0.1...1,
                              format: percent)
            } footer: {
                Text("MFi, Xbox, PlayStation and other Bluetooth controllers work automatically, using the default bindings. On-screen controls hide while a controller is connected. Press Select on a controller to open the menu.")
            }

            Section {
                ForEach(1...2, id: \.self) { port in
                    Picker("Port \(port)", selection: store.int("input.port\(port)Type", default: port == 1 ? 1 : 0)) {
                        ForEach(Self.peripherals, id: \.0) { entry in
                            Text(entry.1).tag(entry.0)
                        }
                    }
                }
            } header: {
                Text("Connected Peripherals")
            } footer: {
                Text("Touch controls and the default controller bindings drive the Saturn Control Pad on port 1.")
            }

            Section {
                SettingSlider(title: "Left Stick Deadzone", value: store.float("input.lsDeadzone", default: 0.15),
                              range: 0.05...0.9, format: percent)
                SettingSlider(title: "Right Stick Deadzone", value: store.float("input.rsDeadzone", default: 0.15),
                              range: 0.05...0.9, format: percent)
                SettingSlider(title: "Analog to Digital Sensitivity",
                              value: store.float("input.analogToDigital", default: 0.5), range: 0.05...0.9, format: percent)
            } header: {
                Text("Controller")
            } footer: {
                Text("The deadzone is the stick travel that is ignored. Analog to digital sensitivity is how far a stick must move to press a digital button.")
            }
        }
        .navigationTitle("Controls")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Emulation

struct EmulationSettingsView: View {
    @ObservedObject private var store = SettingStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("Use Alternate Speed", isOn: store.bool("general.useAltSpeed"))
                SettingSlider(title: "Primary Speed", value: store.float("general.speedMain", default: 1),
                              range: 0.1...5, step: 0.1, format: percent)
                SettingSlider(title: "Alternate Speed", value: store.float("general.speedAlt", default: 0.5),
                              range: 0.1...5, step: 0.1, format: percent)
            } header: {
                Text("Speed")
            } footer: {
                Text("Switch between the two speeds to slow the game down or run it faster. Fast forward in the in-game menu ignores them.")
            }

            Section {
                Toggle("Unpause After Loading a Game", isOn: store.bool("general.unpauseOnDiscLoad", default: true))
                Toggle("Pause When Interrupted", isOn: store.bool("general.pauseWhenUnfocused", default: true))
                Toggle("Autosave When Leaving a Game", isOn: store.bool("general.autoSaveState", default: true))
                Toggle("Preload Disc Images to RAM", isOn: store.bool("general.preloadDiscImages"))
            } header: {
                Text("Behavior")
            } footer: {
                Text("Pause When Interrupted pauses the game while something covers it (the control center, a notification, a call, the app switcher). Autosave keeps a state of the game in its own slot whenever you leave it: the app goes to the background, you close the game, or you start or load something else. Find it in Save States.")
            }

            Section {
                Toggle("Rewind Buffer", isOn: store.bool("general.rewind"))
                SettingSlider(title: "Compression", value: store.intSlider("general.rewindCompression"),
                              range: 0...16, step: 1, format: { String(format: "%.0f", $0) })
            } header: {
                Text("Rewind")
            } footer: {
                Text("Lets you step back in time, at the cost of memory and some performance. Higher compression uses less memory but is slower.")
            }

            Section {
                Stepper(
                    "Screenshot Scale: \(store.int("general.screenshotScale", default: 1).wrappedValue)×",
                    value: store.int("general.screenshotScale", default: 1),
                    in: 1...4
                )
            } header: {
                Text("Screenshots")
            } footer: {
                Text("Screenshots are saved in the Ymir folder under screenshots.")
            }
        }
        .navigationTitle("Emulation")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - System

struct SystemSettingsView: View {
    @ObservedObject private var store = SettingStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("Autodetect Region from Games", isOn: store.bool("system.autodetectRegion", default: true))
                Picker("Video Standard", selection: store.int("system.videoStandard")) {
                    Text("NTSC").tag(0)
                    Text("PAL").tag(1)
                }
                Picker("Preferred BIOS", selection: store.int("system.iplVariant")) {
                    Text("Any").tag(0)
                    Text("Saturn").tag(1)
                    Text("Hi-Saturn").tag(2)
                    Text("V-Saturn").tag(3)
                    Text("Dev Kit").tag(4)
                }
            } header: {
                Text("Region")
            } footer: {
                Text("With autodetection on, the region and video standard follow the loaded game. Reset the console after changing them.")
            }

            Section {
                Picker("Mode", selection: store.int("system.rtcMode")) {
                    Text("Host Clock").tag(0)
                    Text("Virtual").tag(1)
                }
                if store.int("system.rtcMode").wrappedValue == 1 {
                    Picker("On Hard Reset", selection: store.int("system.rtcResetStrategy")) {
                        Text("Sync to Host").tag(0)
                        Text("Reset to Fixed Time").tag(1)
                        Text("Preserve").tag(2)
                    }
                }
            } header: {
                Text("Clock")
            } footer: {
                Text("The virtual clock is deterministic and only moves while the emulator runs.")
            }

            Section {
                Toggle("Separate Backup Memory per Game", isOn: store.bool("system.backupRAMPerGame"))
            } header: {
                Text("Saves")
            } footer: {
                Text("Creates an internal backup memory image for each game. Backup files are in the Ymir folder under backup.")
            }
        }
        .navigationTitle("System & Region")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Cartridge

struct CartridgeSettingsView: View {
    @ObservedObject private var store = SettingStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("Switch to Recommended Cartridges", isOn: store.bool("cartridge.autoLoad", default: true))
            } footer: {
                Text("Automatically inserts the cartridge a game needs, such as a RAM expansion.")
            }

            Section {
                Picker("Cartridge", selection: store.int("cartridge.type")) {
                    Text("None").tag(0)
                    Text("Backup RAM").tag(1)
                    Text("DRAM Expansion").tag(2)
                    Text("ROM").tag(3)
                }

                switch store.int("cartridge.type").wrappedValue {
                case 1:
                    Picker("Capacity", selection: store.int("cartridge.backupCapacity")) {
                        Text("4 Mbit").tag(0)
                        Text("8 Mbit").tag(1)
                        Text("16 Mbit").tag(2)
                        Text("32 Mbit").tag(3)
                    }
                    FileSettingRow(title: "Image", key: "cartridge.backupPath",
                                   folder: AppPaths.documents.appendingPathComponent("backup", isDirectory: true))
                case 2:
                    Picker("Capacity", selection: store.int("cartridge.dramCapacity")) {
                        Text("48 Mbit").tag(0)
                        Text("32 Mbit").tag(1)
                        Text("8 Mbit").tag(2)
                    }
                case 3:
                    FileSettingRow(title: "ROM Image", key: "cartridge.romPath",
                                   folder: AppPaths.documents.appendingPathComponent("roms/cart", isDirectory: true))
                default:
                    EmptyView()
                }
            } header: {
                Text("Inserted Cartridge")
            } footer: {
                Text("Chosen files are copied into the Ymir folder, under roms/cart and backup.")
            }
        }
        .navigationTitle("Cartridge")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - CD drive

struct CDBlockSettingsView: View {
    @ObservedObject private var store = SettingStore.shared

    var body: some View {
        Form {
            Section {
                SettingSlider(title: "Read Speed", value: store.intSlider("cdblock.readSpeed", default: 2),
                              range: 2...200, step: 1, format: { String(format: "%.0f×", $0) })
            } footer: {
                Text("The maximum read speed of the emulated drive. 2× is how fast a real Saturn reads discs.")
            }

            Section {
                Toggle("Low Level Emulation", isOn: store.bool("cdblock.useLLE"))
                FileSettingRow(title: "CD Block ROM", key: "cdblock.romPath",
                               folder: AppPaths.documents.appendingPathComponent("roms/cdb", isDirectory: true))
            } header: {
                Text("Accuracy")
            } footer: {
                Text("Emulates the CD block's own CPU. Needs a CD block ROM image, and is much slower.")
            }
        }
        .navigationTitle("CD Drive")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Performance

struct PerformanceSettingsView: View {
    @ObservedObject private var store = SettingStore.shared
    @State private var jitAvailable = YmirHost.jitAvailable
    @State private var jitStatus = YmirHost.jitStatus
    @State private var jitReport = YmirHost.jitReport

    var body: some View {
        Form {
            Section {
                Button("Recommended") {
                    PerformanceProfile.balanced.apply(to: store)
                }
                Button("Best Accuracy") {
                    PerformanceProfile.accuracy.apply(to: store)
                }
                Button("Best Performance") {
                    PerformanceProfile.speed.apply(to: store)
                }
            } header: {
                Text("Presets")
            } footer: {
                Text("Presets change the options below, the sound chip settings in Audio and, in Display, Frame Pacing and Frame Delay: Recommended and Best Performance use Match Display and Auto with the sound chip on its own thread; Best Accuracy keeps the Saturn's exact speed and no delay.")
            }

            Section {
                Picker("CPU Execution", selection: store.bool("system.useRecompiler")) {
                    Text("Interpreter").tag(false)
                    Text("Recompiler (JIT)").tag(true)
                }
                .disabled(!jitAvailable || store.bool("system.emulateSH2Cache").wrappedValue)

                HStack(spacing: 10) {
                    Image(systemName: jitAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(jitAvailable ? Color.green : Color.orange)
                    Text(jitStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if jitAvailable && store.bool("system.useRecompiler").wrappedValue {
                    Text(jitReport)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                            jitReport = YmirHost.jitReport
                        }
                }
                if jitAvailable && store.bool("system.useRecompiler").wrappedValue {
                    Toggle("Keep Registers in CPU Registers", isOn: store.bool("system.jitRegisterCache", default: true))
                    Toggle("Link Blocks Directly", isOn: store.bool("system.jitBlockLinking", default: true))
                    Toggle("Skip Idle Waiting (Experimental)", isOn: store.bool("system.jitIdleDetection"))
                }
                if !jitAvailable {
                    Button {
                        requestJIT()
                    } label: {
                        Label("Enable JIT…", systemImage: "bolt.fill")
                    }
                }
            } header: {
                Text("CPU")
            } footer: {
                Text(recompilerFooter)
            }

            Section {
                Toggle("Emulate SH-2 Cache", isOn: store.bool("system.emulateSH2Cache"))
                SettingSlider(title: "SH-2 Clock", value: store.intSlider("system.sh2ClockFactor", default: 100),
                              range: 25...500, step: 5, format: { String(format: "%.0f%%", $0) })
                Button("Reset Clock to 100%") {
                    store.intSlider("system.sh2ClockFactor").wrappedValue = 100
                }
            } header: {
                Text("Accuracy")
            } footer: {
                Text("A few games need the SH-2 cache. Changing the clock may break games, desync audio or cause crashes: above 100% reduces slowdowns, below 100% helps slower devices.")
            }

            Section {
                Toggle("Threaded VDP1", isOn: store.bool("video.threadedVDP1", default: true))
                Toggle("Threaded VDP2", isOn: store.bool("video.threadedVDP2", default: true))
                Toggle("Threaded Deinterlacer", isOn: store.bool("video.threadedDeinterlacer", default: true))
                Toggle("Threaded Sound Chip", isOn: store.bool("audio.threadedSCSP"))
            } header: {
                Text("Multithreading")
            } footer: {
                Text("Spreads emulation over several CPU cores for speed.")
            }

            Section {
                Toggle("Boost Emulator Thread Priority", isOn: store.bool("general.boostEmuThread"))
            } footer: {
                Text("May reduce stuttering, at the cost of more battery use.")
            }

            Section {
                Toggle("Performance Log", isOn: store.bool("general.performanceLog"))
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Measures every frame in detail (frame times, CPU time per thread, GPU time, when frames reach the screen) and writes it to metal-vdp-log.txt in the app's Documents folder every 5 seconds. Nothing is logged while it is off. Leave it off for normal play: measuring costs a little time and battery. Turn it on before the session you want a log of, when sending logs.")
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshJIT() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refreshJIT()
        }
    }

    private var recompilerFooter: String {
        if store.bool("system.emulateSH2Cache").wrappedValue {
            return "The recompiler is not used while SH-2 cache emulation is on."
        }
        return "Translates the Saturn's SH-2 processors to native code instead of interpreting them. Experimental: games "
            + "may run faster, or may misbehave; turn it off if something looks wrong. It needs a JIT enabler "
            + "(StikDebug, StosDebug, ...) attached to Ymir, and the change applies to the running game immediately. "
            + "Skip Idle Waiting lets both processors run in longer steps while they are only waiting for something "
            + "in RAM (no writes, no hardware access), and moves loops that keep reading the SH-2's own timer along in time "
            + "instead of running every identical iteration. This saves power but changes timing slightly."
    }

    private func refreshJIT() {
        jitAvailable = YmirHost.jitAvailable
        jitStatus = YmirHost.jitStatus
    }

    /// Asks a JIT enabler app to attach to Ymir. Tries the URL schemes of the common enablers in turn.
    private func requestJIT() {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let schemes = ["stikdebug", "stikjit", "stosdebug"]
        func attempt(_ index: Int) {
            guard index < schemes.count, let url = URL(string: "\(schemes[index])://enable-jit?bundle-id=\(bundleID)") else {
                jitStatus = "Couldn't reach a JIT enabler. Open StikDebug (or a similar app) and enable JIT for Ymir there."
                return
            }
            UIApplication.shared.open(url, options: [:]) { opened in
                if !opened {
                    attempt(index + 1)
                }
            }
        }
        attempt(0)
    }
}

// MARK: - Interface

struct InterfaceSettingsView: View {
    @ObservedObject private var store = SettingStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("Show Frame Rate", isOn: store.bool("gui.showFrameRate"))
                Picker("Position", selection: store.int("gui.frameRatePosition")) {
                    Text("Top Left").tag(0)
                    Text("Top Right").tag(1)
                    Text("Bottom Left").tag(2)
                    Text("Bottom Right").tag(3)
                }
                .disabled(!YmirHost.boolValue(key: "gui.showFrameRate", default: false))
            } header: {
                Text("Frame Rate")
            }

            Section {
                Toggle("Show Messages", isOn: store.bool("gui.showMessages", default: true))
                Toggle("Always Show Speed Indicator", isOn: store.bool("gui.showSpeedIndicator"))
            } header: {
                Text("On-Screen Display")
            }
        }
        .navigationTitle("Interface")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - File settings

/// A setting that points to a file (a cartridge image, a ROM...). Picked files are copied into the Ymir folder.
private struct FileSettingRow: View {
    let title: String
    let key: String
    let folder: URL

    @State private var showImporter = false
    @State private var name = URL(fileURLWithPath: "").lastPathComponent

    init(title: String, key: String, folder: URL) {
        self.title = title
        self.key = key
        self.folder = folder
        _name = State(initialValue: URL(fileURLWithPath: YmirHost.pathValue(key: key)).lastPathComponent)
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(name.isEmpty ? "None" : name)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        Button {
            showImporter = true
        } label: {
            Label("Choose File…", systemImage: "doc.badge.plus")
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let folder = self.folder
            Task {
                _ = await Task.detached(priority: .userInitiated) { () -> ImportService.Outcome in
                    ImportService.copy([url], to: folder)
                }.value
                let destination = folder.appendingPathComponent(url.lastPathComponent)
                YmirHost.setPathValue(destination.path, key: key)
                name = destination.lastPathComponent
                SettingStore.shared.objectWillChange.send()
            }
        }
    }
}
