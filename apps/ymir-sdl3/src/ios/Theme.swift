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
struct YmirBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                (scheme == .dark ? Color(red: 0.04, green: 0.04, blue: 0.12) : Color(red: 0.93, green: 0.94, blue: 1.0))
                blob(.indigo, size: w * 0.9, x: -w * 0.25, y: -h * 0.18)
                blob(.pink, size: w * 0.8, x: w * 0.35, y: h * 0.05)
                blob(.cyan, size: w * 0.85, x: -w * 0.3, y: h * 0.28)
                blob(.orange, size: w * 0.7, x: w * 0.3, y: h * 0.42)
            }
            .frame(width: w, height: h)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func blob(_ color: Color, size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(color.opacity(scheme == .dark ? 0.45 : 0.35))
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

    static var covers: URL {
        documents.appendingPathComponent("covers", isDirectory: true)
    }
}
