import SwiftUI

// The few things that differ between the Mac and iOS apps, so the shared
// code can stay free of `#if os(...)`.

#if os(macOS)
import AppKit

typealias PlatformImage = NSImage

extension Image {
    init(platformImage: PlatformImage) { self.init(nsImage: platformImage) }
}

enum Platform {
    static let isMac = true

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func image(from data: Data) -> PlatformImage? { NSImage(data: data) }
}

#else
import UIKit

typealias PlatformImage = UIImage

extension Image {
    init(platformImage: PlatformImage) { self.init(uiImage: platformImage) }
}

enum Platform {
    static let isMac = false

    @MainActor
    static func open(_ url: URL) {
        UIApplication.shared.open(url)
    }

    @MainActor
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }

    static func image(from data: Data) -> PlatformImage? { UIImage(data: data) }
}
#endif

extension View {
    /// The window subtitle on the Mac; on iOS 26 and later, the navigation
    /// bar's subtitle.
    @ViewBuilder
    func navSubtitle(_ text: String) -> some View {
        #if os(macOS)
        navigationSubtitle(text)
        #else
        if #available(iOS 26, *) {
            navigationSubtitle(text)
        } else {
            self
        }
        #endif
    }

    /// A checkbox on the Mac, a switch on iOS.
    @ViewBuilder
    func checkboxToggleStyle() -> some View {
        #if os(macOS)
        toggleStyle(.checkbox)
        #else
        self
        #endif
    }

    /// A text-like button: `.link` on the Mac, plain tinted text on iOS.
    @ViewBuilder
    func linkButtonStyle() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        buttonStyle(.borderless)
        #endif
    }

    /// A fixed size for a sheet on the Mac; on iOS sheets fill the screen.
    @ViewBuilder
    func sheetFrame(width: CGFloat, height: CGFloat) -> some View {
        #if os(macOS)
        frame(width: width, height: height)
        #else
        self
        #endif
    }

    /// A fixed width for a small sheet on the Mac.
    @ViewBuilder
    func sheetWidth(_ width: CGFloat) -> some View {
        #if os(macOS)
        frame(width: width)
        #else
        self
        #endif
    }

    /// A fixed width on the Mac; on iOS the natural width, on one line.
    @ViewBuilder
    func macWidth(_ width: CGFloat) -> some View {
        #if os(macOS)
        frame(width: width)
        #else
        fixedSize()
        #endif
    }

    /// `minWidth`/`minHeight` on the Mac only.
    @ViewBuilder
    func macMinFrame(width: CGFloat, height: CGFloat) -> some View {
        #if os(macOS)
        frame(minWidth: width, minHeight: height)
        #else
        self
        #endif
    }
}
