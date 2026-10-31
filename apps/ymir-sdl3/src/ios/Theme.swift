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

/// The rows of a glass form section: translucent, so that the backdrop shows through.
struct GlassRowBackground: View {
    var body: some View {
        Rectangle().fill(.ultraThinMaterial)
    }
}

/// A `Section` for forms and lists whose rows sit on translucent glass over the app's backdrop, in the style of the
/// cards of the settings home. Used like `Section`.
struct GlassSection<Content: View, Header: View, Footer: View>: View {
    private let content: Content
    private let header: Header
    private let footer: Footer

    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer) {
        self.content = content()
        self.header = header()
        self.footer = footer()
    }

    var body: some View {
        Section {
            content
        } header: {
            header
        } footer: {
            footer
        }
        .listRowBackground(GlassRowBackground())
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
    /// Shows a form or list on the app's backdrop instead of the plain grouped background (see `GlassSection`).
    func ymirGlassForm() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(YmirBackdrop())
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
