import AppKit

/// The `"<width>x<height>"` string wine's `explorer /desktop=<name>,<geometry>` expects.
///
/// Deliberately isolated in its own AppKit file so `LaunchOrchestrator` stays AppKit-free: `makePlan` is a
/// **pure**, exhaustively table-tested function, and keeping `NSScreen` out of it means those tests never
/// need a real display or a MainActor hop. Callers resolve the geometry at the UI layer (the view models
/// are already `@MainActor`) and pass the resulting string down.
public enum DesktopGeometry {
    /// The main display's native **pixel** resolution, or nil when there's no screen to ask (a genuinely
    /// headless session, or a call that isn't on the main actor).
    ///
    /// `NSScreen.main` is the screen holding the **key window**, not the primary display — and it is nil
    /// when Silo owns no key window, which is exactly the `silo://` deep-link path (a desktop shortcut can
    /// start a game without ever focusing a Silo window). Falling through to the primary display there
    /// beats handing the game `fallbackGameDesktopGeometry`: on a Retina panel that fallback is smaller
    /// than the display, which is the very capping this resolution exists to undo.
    ///
    /// `NSScreen.frame` reports **points**; a Retina panel's real pixel count is that times
    /// `backingScaleFactor` (a 1512×982-point MacBook Pro panel at 2x is 3024×1964 pixels). Pixels are what
    /// the virtual desktop needs — wine renders its desktop window at the panel's native resolution, not at
    /// its point size, so passing points would hand the game a quarter of the display.
    @MainActor
    public static func mainScreen(_ screen: NSScreen? = NSScreen.main ?? NSScreen.screens.first) -> String? {
        guard let screen else { return nil }
        return geometry(points: screen.frame.size, scale: screen.backingScaleFactor)
    }

    /// The pixel-geometry arithmetic, split out from `NSScreen` so it is testable without a display: an
    /// `NSScreen` cannot be constructed, so a test that could only pass `nil` or the real panel would never
    /// pin the points→pixels conversion this whole type exists for.
    ///
    /// Nil for a non-positive size — a screen that reports nothing usable is the "no screen to ask" answer,
    /// not a `0x0` desktop wine would refuse.
    static func geometry(points: CGSize, scale: CGFloat) -> String? {
        let width = Int((points.width * scale).rounded())
        let height = Int((points.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }
        return "\(width)x\(height)"
    }
}
