import CoreGraphics
import Foundation

/// A display attached to the MacBook, as far as sharing is concerned.
public struct DisplayInfo: Equatable {
    public let id: CGDirectDisplayID
    public let isBuiltin: Bool
    /// Size in points (what the user sees as the resolution).
    public let width: Int, height: Int
    /// Backing pixels of the current mode (Retina = 2x points).
    public let pixelWidth: Int, pixelHeight: Int

    public init(id: CGDirectDisplayID, isBuiltin: Bool, width: Int, height: Int, pixelWidth: Int, pixelHeight: Int) {
        self.id = id; self.isBuiltin = isBuiltin; self.width = width; self.height = height
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }

    public var label: String { "\(isBuiltin ? "Built-in" : "External") \(width)x\(height)" }
}

/// Which display the user wants to share.
public enum DisplayChoice: String, CaseIterable {
    /// External display (e.g. HDMI dummy plug) if present, otherwise the built-in one.
    case automatic
    case builtin
    case external

    public var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .builtin: return "Built-in display"
        case .external: return "External display"
        }
    }
}

public enum Displays {
    /// Active displays right now.
    public static func current() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            let mode = CGDisplayCopyDisplayMode(id)
            let b = CGDisplayBounds(id)
            return DisplayInfo(id: id, isBuiltin: CGDisplayIsBuiltin(id) != 0,
                               width: mode?.width ?? Int(b.width), height: mode?.height ?? Int(b.height),
                               pixelWidth: mode?.pixelWidth ?? Int(b.width), pixelHeight: mode?.pixelHeight ?? Int(b.height))
        }
    }

    /// Pure selection policy (unit-tested). With the lid closed the built-in display
    /// is gone, so `automatic` naturally ends up on the external one.
    public static func choose(_ displays: [DisplayInfo], _ choice: DisplayChoice) -> DisplayInfo? {
        let builtin = displays.first { $0.isBuiltin }
        let external = displays.first { !$0.isBuiltin }
        switch choice {
        case .automatic: return external ?? builtin ?? displays.first
        case .builtin: return builtin ?? displays.first
        case .external: return external ?? displays.first
        }
    }

    // MARK: Fitting the iMac (16:9)

    public struct Mode: Equatable {
        public let width: Int, height: Int, pixelWidth: Int, pixelHeight: Int
        public init(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int) {
            self.width = width; self.height = height; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        }
        var isHiDPI: Bool { pixelWidth == width * 2 && pixelHeight == height * 2 }
        var is16x9: Bool { abs(Double(width) / Double(height) - 16.0 / 9.0) < 0.01 }
    }

    /// Best mode to fill a 16:9 5K iMac: HiDPI 16:9, preferring 2560x1440 (exactly 2x on
    /// 5120x2880), else the largest HiDPI 16:9, else the largest 16:9. Pure, unit-tested.
    public static func bestModeForIMac(_ modes: [Mode]) -> Mode? {
        let wide = modes.filter(\.is16x9)
        if let exact = wide.first(where: { $0.isHiDPI && $0.width == 2560 && $0.height == 1440 }) { return exact }
        if let hidpi = wide.filter(\.isHiDPI).max(by: { $0.width < $1.width }) { return hidpi }
        return wide.max(by: { $0.width < $1.width })
    }

    /// Switches an external display to the best 16:9 mode for the iMac.
    /// Returns a description of what changed, or nil if nothing to do / not possible.
    @discardableResult
    public static func fitForIMac(_ id: CGDirectDisplayID) -> String? {
        guard CGDisplayIsBuiltin(id) == 0 else { return nil }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let all = CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode] else { return nil }
        let modes = all.map { Mode(width: $0.width, height: $0.height, pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight) }
        guard let best = bestModeForIMac(modes),
              let target = all.first(where: { $0.width == best.width && $0.height == best.height
                                              && $0.pixelWidth == best.pixelWidth && $0.pixelHeight == best.pixelHeight }) else { return nil }
        if let cur = CGDisplayCopyDisplayMode(id), cur.width == best.width, cur.height == best.height,
           cur.pixelWidth == best.pixelWidth { return nil }
        guard CGDisplaySetDisplayMode(id, target, nil) == .success else { return nil }
        return "\(best.width)x\(best.height) (\(best.pixelWidth)x\(best.pixelHeight) pixels)"
    }
}
