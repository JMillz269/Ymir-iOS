import SwiftUI
import UIKit

// MARK: - Liquid Glass helpers

extension View {
    /// Fills the view with Liquid Glass on iOS 26 and later, and with a translucent material on older systems.
    @ViewBuilder
    func ymirGlass<S: Shape>(in shape: S, interactive: Bool = true) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            if interactive {
                self.glassEffect(.regular.interactive(), in: shape)
            } else {
                self.glassEffect(.regular, in: shape)
            }
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
        #else
        self.background(.ultraThinMaterial, in: shape)
        #endif
    }

    /// Prominent call-to-action button style: a tinted glass button on iOS 26 and later, bordered prominent before.
    @ViewBuilder
    func ymirProminentButton() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
        #else
        self.buttonStyle(.borderedProminent)
        #endif
    }

    /// Secondary button style: a glass button on iOS 26 and later, bordered before.
    @ViewBuilder
    func ymirSecondaryButton() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
        #else
        self.buttonStyle(.bordered)
        #endif
    }
}


extension View {
    /// A rounded Liquid Glass card (a translucent material before iOS 26) for grouped content.
    func ymirGlassCard(cornerRadius: CGFloat = 22) -> some View {
        self.ymirGlass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), interactive: false)
    }
}

// MARK: - Glass forms

private struct GlassContentWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 340
}

extension EnvironmentValues {
    /// The width of the content of a glass form (the screen without its margins). The cards and the texts under and
    /// over them are given exactly this width: letting them negotiate it made them as wide as their longest line.
    var glassContentWidth: CGFloat {
        get { self[GlassContentWidthKey.self] }
        set { self[GlassContentWidthKey.self] = newValue }
    }
}

/// A settings page: a scrolling stack of `GlassSection`s on the app's backdrop, like the settings home. Used like `Form`.
struct GlassForm<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geo in
            let width = max(0, geo.size.width - 32)
            ScrollView {
                VStack(spacing: 22) {
                    content()
                }
                .environment(\.glassContentWidth, width)
                .frame(width: width)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .background(YmirBackdrop())
    }
}

/// Lays the rows of a glass section out with a divider between them.
private struct GlassRows: _VariadicView_UnaryViewRoot {
    @ViewBuilder
    func body(children: _VariadicView.Children) -> some View {
        let lastID = children.last?.id
        VStack(spacing: 0) {
            ForEach(children) { child in
                child
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if child.id != lastID {
                    Divider().padding(.leading, 16)
                }
            }
        }
    }
}

/// A titled group of rows on one Liquid Glass card, with an optional footnote underneath. Used like `Section`.
struct GlassSection<Content: View, Header: View, Footer: View>: View {
    @Environment(\.glassContentWidth) private var width
    private let content: Content
    private let header: Header
    private let footer: Footer
    private let hasContent: Bool
    private let hasHeader: Bool
    private let hasFooter: Bool

    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer) {
        self.content = content()
        self.header = header()
        self.footer = footer()
        hasContent = Content.self != EmptyView.self
        hasHeader = Header.self != EmptyView.self
        hasFooter = Footer.self != EmptyView.self
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if hasHeader {
                header
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .frame(width: max(0, width - 32), alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 16)
            }
            if hasContent {
                _VariadicView.Tree(GlassRows()) { content }
                    .frame(width: width)
                    .ymirGlassCard()
            }
            if hasFooter {
                footer
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: max(0, width - 32), alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 16)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

extension GlassSection where Header == EmptyView, Footer == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.init(content: content, header: { EmptyView() }, footer: { EmptyView() })
    }
}

extension GlassSection where Footer == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.init(content: content, header: header, footer: { EmptyView() })
    }
}

extension GlassSection where Header == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.init(content: content, header: { EmptyView() }, footer: footer)
    }
}

extension GlassSection where Header == Text, Footer == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { Text(title) }, footer: { EmptyView() })
    }
}

extension View {
    /// Makes a list row a free-standing card: no row background or separator, with some air around it. The view
    /// itself is expected to bring its own glass (see `ymirGlassCard`).
    func ymirGlassRow() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }
}

/// A footnote that wraps at the width of the glass content, drawn by UIKit. SwiftUI's own `Text` stayed on one line as wide
/// as the sentence here (the footers ran off the screen), whatever frame it was put in; a label that is told its width
/// and measures its height for it can't.
struct WrappedText: UIViewRepresentable {
    @Environment(\.glassContentWidth) private var contentWidth
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    /// The width the text has: the content width less the margin on each side
    private var width: CGFloat {
        max(1, contentWidth - 32)
    }

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.adjustsFontForContentSizeCategory = true
        label.font = UIFont.preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.backgroundColor = .clear
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        label.text = text
        label.preferredMaxLayoutWidth = width
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView label: UILabel, context: Context) -> CGSize? {
        let font = UIFont.preferredFont(forTextStyle: .footnote)
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil)
        return CGSize(width: width, height: ceil(bounds.height))
    }
}

/// A title that wraps at a width it is given, over up to `lines` lines, and always takes the height of all of them (so
/// the cards of a row are as tall as each other). SwiftUI's `Text` stayed on one line here and ran over the edge of
/// its card, as the footnotes did (see `WrappedText`), so a label that is told its width draws it.
struct FixedWidthTitle: UIViewRepresentable {
    let text: String
    let width: CGFloat
    var lines = 2
    var style = UIFont.TextStyle.subheadline
    var weight = UIFont.Weight.medium

    private var font: UIFont {
        let base = UIFont.preferredFont(forTextStyle: style)
        return UIFont.systemFont(ofSize: base.pointSize, weight: weight)
    }

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = lines
        label.lineBreakMode = .byTruncatingTail
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.backgroundColor = .clear
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        label.text = text
        label.font = font
        label.numberOfLines = lines
        label.preferredMaxLayoutWidth = width
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView label: UILabel, context: Context) -> CGSize? {
        CGSize(width: width, height: ceil(font.lineHeight) * CGFloat(lines))
    }
}

/// A picker row for glass forms: the title on the left and the choice, as a menu, on the right (a plain `Picker`
/// outside a `Form` puts them next to each other).
struct GlassPicker<SelectionValue: Hashable, Content: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    private let title: String
    private let selection: Binding<SelectionValue>
    private let content: Content

    init(_ title: String, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self.title = title
        self.selection = selection
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            Spacer(minLength: 8)
            Picker(title, selection: selection) {
                content
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }
}

// MARK: - Backdrop

/// A soft, colourful ambient background that gives glass something to refract.
/// The colours of the backdrop, kept between launches. The player picks how many are used and which they are
/// (Settings > Appearance); the positions of the blobs are fixed.
final class BackdropTheme: ObservableObject {
    static let shared = BackdropTheme()

    /// A named set of colours.
    struct Preset: Identifiable {
        let name: String
        let colors: [Color]
        var id: String { name }
    }

    static let maxColors = 5
    static let minColors = 2

    /// The colours of the backdrop as it has always looked, and the ones the extra slots start from.
    static let defaultColors: [Color] = [.indigo, .pink, .cyan, .orange, .purple]

    static let presets: [Preset] = [
        Preset(name: "Aurora", colors: [.indigo, .pink, .cyan, .orange]),
        Preset(name: "Sunset", colors: [Color(hex: "FF7A3D"), Color(hex: "E8456F"), Color(hex: "7A3FA0")]),
        Preset(name: "Ocean", colors: [Color(hex: "1565C0"), Color(hex: "16A3C8"), Color(hex: "0E7C66"), Color(hex: "4C5FD5")]),
        Preset(name: "Forest", colors: [Color(hex: "2E7D32"), Color(hex: "7CB342"), Color(hex: "0E8A7A")]),
        Preset(name: "Candy", colors: [Color(hex: "FF5FA2"), Color(hex: "9B5CFF"), Color(hex: "40D6D0"), Color(hex: "FFC14D")]),
        Preset(name: "Saturn", colors: [Color(hex: "1A237E"), Color(hex: "C62828")]),
        Preset(name: "Slate", colors: [Color(hex: "4A5568"), Color(hex: "2D3748")]),
    ]

    private static let countKey = "theme.backdropColorCount"
    private static let colorsKey = "theme.backdropColors"
    private static let intensityKey = "theme.backdropIntensity"

    /// How many of the colours are used.
    @Published var colorCount: Int {
        didSet { UserDefaults.standard.set(colorCount, forKey: Self.countKey) }
    }

    /// Always `maxColors` colours; the ones past `colorCount` are kept for when the player asks for more again.
    @Published var colors: [Color] {
        didSet { UserDefaults.standard.set(colors.map(\.hexString), forKey: Self.colorsKey) }
    }

    /// How strongly the colours show, 0 (a plain background) to 1.5.
    @Published var intensity: Double {
        didSet { UserDefaults.standard.set(intensity, forKey: Self.intensityKey) }
    }

    private init() {
        let defaults = UserDefaults.standard
        var list = (defaults.array(forKey: Self.colorsKey) as? [String] ?? []).map { Color(hex: $0) }
        if list.count > Self.maxColors {
            list = Array(list.prefix(Self.maxColors))
        } else if list.count < Self.maxColors {
            list.append(contentsOf: Self.defaultColors[list.count...])
        }
        colors = list
        let count = defaults.object(forKey: Self.countKey) as? Int ?? 4
        colorCount = min(max(count, Self.minColors), Self.maxColors)
        let strength = defaults.object(forKey: Self.intensityKey) as? Double ?? 1.0
        intensity = min(max(strength, 0.0), 1.5)
    }

    /// The colours that are drawn.
    var activeColors: [Color] {
        Array(colors.prefix(min(max(colorCount, Self.minColors), colors.count)))
    }

    /// The name of the theme the colours are those of, or nil when they were picked by hand.
    var presetName: String? {
        let active = activeColors.map(\.hexString)
        return Self.presets.first { $0.colors.map(\.hexString) == active }?.name
    }

    func apply(_ preset: Preset) {
        var list = preset.colors
        if list.count < Self.maxColors {
            list.append(contentsOf: Self.defaultColors[list.count...])
        }
        colors = Array(list.prefix(Self.maxColors))
        colorCount = min(max(preset.colors.count, Self.minColors), Self.maxColors)
    }

    func reset() {
        colors = Self.defaultColors
        colorCount = 4
        intensity = 1.0
    }
}

extension Color {
    /// A colour from "RRGGBB" (the way the colours of the backdrop are stored).
    init(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") {
            text.removeFirst()
        }
        let value = UInt64(text, radix: 16) ?? 0
        self.init(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ value: CGFloat) -> Int {
            Int((min(max(value, 0), 1) * 255).rounded())
        }
        return String(format: "%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}

/// A soft, colourful ambient background that gives glass something to refract. Its colours are the player's
/// (see `BackdropTheme`).
struct YmirBackdrop: View {
    /// Set for the preview in the settings: it stays inside its frame instead of covering the screen.
    var isPreview = false

    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var theme = BackdropTheme.shared

    /// Where the blobs sit, as fractions of the width and the height. The first ones are where they have always been.
    private static let placements: [(size: CGFloat, x: CGFloat, y: CGFloat)] = [
        (0.90, -0.25, -0.18),
        (0.80, 0.35, 0.05),
        (0.85, -0.30, 0.28),
        (0.70, 0.30, 0.42),
        (0.75, 0.05, -0.45),
    ]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                (scheme == .dark ? Color(red: 0.04, green: 0.04, blue: 0.12) : Color(red: 0.93, green: 0.94, blue: 1.0))
                ForEach(Array(theme.activeColors.enumerated()), id: \.offset) { index, color in
                    let spot = Self.placements[index % Self.placements.count]
                    blob(color, size: w * spot.size, x: w * spot.x, y: h * spot.y)
                }
            }
            .frame(width: w, height: h)
        }
        .ignoresSafeArea(edges: isPreview ? [] : .all)
        .allowsHitTesting(false)
    }

    private func blob(_ color: Color, size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(color.opacity((scheme == .dark ? 0.45 : 0.35) * theme.intensity))
            .frame(width: size, height: size)
            .blur(radius: 70)
            .offset(x: x, y: y)
    }
}

// MARK: - Paths

enum AppPaths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var games: URL {
        documents.appendingPathComponent("games", isDirectory: true)
    }

    static var bios: URL {
        documents.appendingPathComponent("roms", isDirectory: true).appendingPathComponent("ipl", isDirectory: true)
    }

    /// Where the originals of converted games are moved to when they are kept (the library doesn't list this folder).
    static var originals: URL {
        documents.appendingPathComponent("originals", isDirectory: true)
    }

    static var covers: URL {
        documents.appendingPathComponent("covers", isDirectory: true)
    }
}
