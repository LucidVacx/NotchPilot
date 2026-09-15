import AppKit
import Combine
import CoreGraphics
import ImageIO
import SwiftUI

enum NotchAppearanceMode: String, CaseIterable, Identifiable {
    case obsidian
    case wallpaperAdaptive
    case systemAccent
    case pureBlack

    var id: String { rawValue }

    var title: String {
        switch self {
        case .obsidian: return "Obsidian"
        case .wallpaperAdaptive: return "Wallpaper Adaptive"
        case .systemAccent: return "System Accent"
        case .pureBlack: return "Pure Black"
        }
    }
}

struct NotchThemePalette: Equatable {
    let accent: Color

    static let obsidian = make(accent: ThemeRGB(red: 0.27, green: 0.42, blue: 0.72))

    static func make(accent: ThemeRGB) -> NotchThemePalette {
        NotchThemePalette(accent: accent.normalized.color)
    }
}

struct ThemeRGB: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color { Color(red: red, green: green, blue: blue) }

    var normalized: ThemeRGB {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let saturation = maximum == 0 ? 0 : (maximum - minimum) / maximum
        let value = maximum
        guard saturation > 0.06, value > 0.10, value < 0.94 else {
            return ThemeRGB(red: 0.27, green: 0.42, blue: 0.72)
        }

        let targetValue = min(0.62, max(0.42, value))
        let targetSaturation = min(0.48, max(0.20, saturation * 0.62))
        return ThemeRGB.fromHSV(
            hue: hue,
            saturation: targetSaturation,
            value: targetValue
        )
    }

    private var hue: Double {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        guard delta > 0 else { return 0.62 }
        if maximum == red {
            return ((green - blue) / delta).truncatingRemainder(dividingBy: 6) / 6
        }
        if maximum == green {
            return ((blue - red) / delta + 2) / 6
        }
        return ((red - green) / delta + 4) / 6
    }

    private static func fromHSV(hue: Double, saturation: Double, value: Double) -> ThemeRGB {
        let wrappedHue = hue < 0 ? hue + 1 : hue
        let index = Int(floor(wrappedHue * 6))
        let fraction = wrappedHue * 6 - Double(index)
        let p = value * (1 - saturation)
        let q = value * (1 - fraction * saturation)
        let t = value * (1 - (1 - fraction) * saturation)
        switch index % 6 {
        case 0: return ThemeRGB(red: value, green: t, blue: p)
        case 1: return ThemeRGB(red: q, green: value, blue: p)
        case 2: return ThemeRGB(red: p, green: value, blue: t)
        case 3: return ThemeRGB(red: p, green: q, blue: value)
        case 4: return ThemeRGB(red: t, green: p, blue: value)
        default: return ThemeRGB(red: value, green: p, blue: q)
        }
    }
}

actor WallpaperPaletteProvider {
    private var cache: [String: ThemeRGB] = [:]

    func accent(for url: URL, signature: String) async -> ThemeRGB {
        if let cached = cache[signature] { return cached }
        let result = Self.extractAccent(from: url)
            ?? ThemeRGB(red: 0.27, green: 0.42, blue: 0.72)
        cache[signature] = result
        return result
    }

    private static func extractAccent(from url: URL) -> ThemeRGB? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 48,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ] as CFDictionary
              ) else { return nil }

        let width = 48
        let height = 48
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var totalWeight = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index]) / 255
            let g = Double(pixels[index + 1]) / 255
            let b = Double(pixels[index + 2]) / 255
            let maximum = max(r, g, b)
            let minimum = min(r, g, b)
            let saturation = maximum == 0 ? 0 : (maximum - minimum) / maximum
            let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
            guard saturation > 0.08, luminance > 0.12, luminance < 0.88 else { continue }
            let weight = 0.35 + min(saturation, 0.75)
            red += r * weight
            green += g * weight
            blue += b * weight
            totalWeight += weight
        }
        guard totalWeight > 8 else { return nil }
        return ThemeRGB(
            red: red / totalWeight,
            green: green / totalWeight,
            blue: blue / totalWeight
        ).normalized
    }
}

@MainActor
final class NotchThemeController: ObservableObject {
    @Published private(set) var mode: NotchAppearanceMode
    @Published private(set) var palette: NotchThemePalette

    private let provider = WallpaperPaletteProvider()
    private var activeDisplayID: CGDirectDisplayID?
    private var wallpaperSignature: String?
    private var refreshTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(defaults: UserDefaults = .standard) {
        let stored = defaults.string(forKey: "appearance.mode")
        mode = stored.flatMap(NotchAppearanceMode.init(rawValue:)) ?? .obsidian
        palette = .obsidian
        applyImmediatePalette()
        NotificationCenter.default.publisher(for: NSColor.systemColorsDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.mode == .systemAccent else { return }
                self.applyImmediatePalette()
            }
            .store(in: &cancellables)
    }

    func select(_ mode: NotchAppearanceMode, screen: NSScreen? = NSScreen.main) {
        guard self.mode != mode else { return }
        refreshTask?.cancel()
        wallpaperSignature = nil
        self.mode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "appearance.mode")
        applyImmediatePalette()
        if let screen { update(for: screen, force: true) }
    }

    func update(for screen: NSScreen, force: Bool = false) {
        let displayID = screen.displayIDForTheme
        guard mode == .wallpaperAdaptive else {
            if force || activeDisplayID != displayID {
                activeDisplayID = displayID
                applyImmediatePalette()
            }
            return
        }

        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            palette = .obsidian
            return
        }
        let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        let modification = resourceValues?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let signature = "\(displayID)|\(url.path)|\(modification)"
        guard force || signature != wallpaperSignature else { return }

        activeDisplayID = displayID
        wallpaperSignature = signature
        refreshTask?.cancel()
        refreshTask = Task { [weak self, provider] in
            let accent = await provider.accent(for: url, signature: signature)
            guard !Task.isCancelled, let self else { return }
            self.palette = NotchThemePalette.make(accent: accent)
        }
    }

    private func applyImmediatePalette() {
        switch mode {
        case .obsidian:
            palette = .obsidian
        case .wallpaperAdaptive:
            palette = .obsidian
        case .systemAccent:
            palette = NotchThemePalette.make(
                accent: ThemeRGB(nsColor: .controlAccentColor)
            )
        case .pureBlack:
            palette = NotchThemePalette.make(
                accent: ThemeRGB(red: 0.58, green: 0.58, blue: 0.60)
            )
        }
    }
}

private extension ThemeRGB {
    init(nsColor: NSColor) {
        let color = nsColor.usingColorSpace(.sRGB) ?? nsColor
        self.init(
            red: Double(color.redComponent),
            green: Double(color.greenComponent),
            blue: Double(color.blueComponent)
        )
    }
}

private extension NSScreen {
    var displayIDForTheme: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) } ?? 0
    }
}
