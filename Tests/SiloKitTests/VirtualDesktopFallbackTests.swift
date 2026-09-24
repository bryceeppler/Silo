import Foundation
import Testing
@testable import SiloKit

/// A game that saved a resolution this Mac cannot produce (Alien Swarm ships 640x480; a Retina display
/// offers no such mode) quits on `EnterFullscreenMode`. Wine's virtual desktop satisfies the mode change
/// itself, so the fix is a launch wrapper — not `-windowed`, and NOT another graphics backend.
@Suite("Virtual-desktop fallback")
struct VirtualDesktopFallbackTests {

    /// Captured verbatim from Alien Swarm's DXVK log.
    private let failed = """
    info:  Setting display mode: 640x480@0
    err:   D3D9: EnterFullscreenMode: Failed to change display mode
    err:   D3D9: Failed to set initial fullscreen state
    """

    @Test("the display-mode failure is detected, and a healthy fullscreen launch is not")
    func detectsOnlyTheFailure() {
        #expect(GraphicsFallback.requestedUnavailableDisplayMode(failed))
        // Measured on-device: fullscreen at a mode the display DOES offer succeeds and logs no error.
        #expect(!GraphicsFallback.requestedUnavailableDisplayMode("info:  Setting display mode: 1512x982@120"))
        #expect(!GraphicsFallback.requestedUnavailableDisplayMode(""))
    }

    /// It must NOT be mistaken for a backend problem — rerouting DXVK→anything cannot help, and DXVK is
    /// the only backend that can run these DirectX 9 games at all.
    @Test("a display-mode failure is not a graphics fallback")
    func notAGraphicsFallback() {
        #expect(GraphicsFallback.classify(failed, backend: .dxvk) != .fallback)
    }

    @Test("the wrapper runs the game inside wine's desktop, preserving its own arguments")
    func wrapsTheInvocation() {
        let exe = URL(fileURLWithPath: "/games/Alien Swarm/swarm.exe")
        let plain = LaunchOrchestrator.invocation(for: exe)
        #expect(plain == [exe.path])
        let wrapped = LaunchOrchestrator.invocation(for: exe, virtualDesktop: true)
        #expect(wrapped.first == "explorer")
        #expect(wrapped.contains { $0.hasPrefix("/desktop=SiloGame,") })
        #expect(wrapped.last == exe.path)      // the game stays the final argument
    }

    /// `explorer` scopes a desktop by NAME. If a game reused the Steam client's `Silo` desktop it would
    /// join that existing window and silently inherit the client's size. In the shared bottle, where the
    /// client is always up, that would make the resolved geometry below a no-op.
    @Test("a game's desktop is a DIFFERENT desktop from the Steam client's, so it can have its own size")
    func gameDesktopIsNotTheSteamClientDesktop() {
        #expect(LaunchOrchestrator.gameDesktopName != "Silo")
        #expect(LaunchOrchestrator.fallbackGameDesktopGeometry != SteamBottle.fallbackDesktopGeometry)
    }

    @Test("the real screen's pixel geometry is what the desktop is sized to, with a sane fallback")
    func usesResolvedGeometry() {
        let exe = URL(fileURLWithPath: "/games/Tekken 8/tekken.exe")
        let retina = LaunchOrchestrator.invocation(
            for: exe, virtualDesktop: true, geometry: "3024x1964")
        #expect(retina.contains("/desktop=SiloGame,3024x1964"))

        // No screen to ask (headless / off-main): the fallback stands in — and it is deliberately NOT the
        // Steam client's CEF-workaround size, which would cap the game at a fraction of a Retina panel.
        for missing in [nil, ""] as [String?] {
            let fallback = LaunchOrchestrator.invocation(
                for: exe, virtualDesktop: true, geometry: missing)
            #expect(fallback.contains(
                "/desktop=SiloGame,\(LaunchOrchestrator.fallbackGameDesktopGeometry)"))
        }
    }

    @Test("geometry is irrelevant when the game runs rootless — no explorer wrapper at all")
    func geometryIgnoredWithoutVirtualDesktop() {
        let exe = URL(fileURLWithPath: "/games/Tekken 8/tekken.exe")
        let rootless = LaunchOrchestrator.invocation(for: exe, geometry: "3024x1964")
        #expect(rootless == [exe.path])
    }
}

/// The points→pixels conversion is the whole reason this type exists: wine sizes its desktop window in real
/// pixels, so handing it `NSScreen.frame` unscaled would give a Retina game a quarter of the panel.
@Suite("Desktop geometry resolution")
struct DesktopGeometryTests {

    @Test("a Retina panel resolves to its BACKING pixels, not its point size")
    func retinaScales() {
        // The dev box's own panel: 1512x982 points at 2x is 3024x1964 real pixels.
        #expect(DesktopGeometry.geometry(points: CGSize(width: 1512, height: 982), scale: 2) == "3024x1964")
    }

    @Test("a 1x display passes through unscaled")
    func nonRetinaPassesThrough() {
        // A 1x external panel (the display in the 1440x900-cap report) must not be doubled.
        #expect(DesktopGeometry.geometry(points: CGSize(width: 2560, height: 1440), scale: 1) == "2560x1440")
    }

    @Test("a fractional scale rounds to whole pixels — wine's geometry takes integers only")
    func fractionalScaleRounds() {
        #expect(DesktopGeometry.geometry(points: CGSize(width: 1440, height: 900), scale: 1.5)
            == "2160x1350")
        // A scaled-mode panel whose product isn't whole still yields integers, never "1707.5x960".
        #expect(DesktopGeometry.geometry(points: CGSize(width: 1138, height: 640), scale: 1.5)
            == "1707x960")
    }

    @Test("a screen reporting nothing usable is nil — the caller's fallback, not a 0x0 desktop")
    func nonPositiveIsNil() {
        #expect(DesktopGeometry.geometry(points: .zero, scale: 2) == nil)
        #expect(DesktopGeometry.geometry(points: CGSize(width: 1512, height: 982), scale: 0) == nil)
        #expect(DesktopGeometry.geometry(points: CGSize(width: -1512, height: 982), scale: 2) == nil)
    }

    @MainActor
    @Test("no screen at all resolves to nil, so the launch falls back instead of throwing")
    func noScreenIsNil() {
        #expect(DesktopGeometry.mainScreen(nil) == nil)
    }
}

/// Silo's launch logs APPEND across runs. Reading the whole file would re-detect a one-off failure forever,
/// so the check must look only at the most recent launch.
@Suite("Launch log sectioning")
struct LaunchLogSectionTests {

    @Test("only the last launch is considered, so a fixed game stops being pinned")
    func lastSectionOnly() {
        let log = """
        ===== Silo launch @ 2026-08-04 17:09:04 =====
        err:   D3D9: EnterFullscreenMode: Failed to change display mode
        ===== Silo launch @ 2026-08-04 18:00:00 =====
        info:  Setting display mode: 1512x982@120
        """
        let last = LaunchPlan.lastLaunchSection(of: log)
        #expect(!last.contains("Failed to change display mode"))
        #expect(!GraphicsFallback.requestedUnavailableDisplayMode(last))
        // …and a log whose LAST run failed is still caught.
        let stillFailing = log + "\n===== Silo launch @ 2026-08-04 19:00:00 =====\nerr:   D3D9: EnterFullscreenMode: Failed to change display mode"
        #expect(GraphicsFallback.requestedUnavailableDisplayMode(LaunchPlan.lastLaunchSection(of: stillFailing)))
    }

    @Test("a log with no header is returned whole")
    func noHeader() {
        #expect(LaunchPlan.lastLaunchSection(of: "some old log") == "some old log")
        #expect(LaunchPlan.lastLaunchSection(of: "").isEmpty)
    }
}

/// The decision must PERSIST, not be re-derived from the log each launch.
@Suite("Virtual-desktop persistence")
struct VirtualDesktopPersistenceTests {

    /// REGRESSION: a wrapped launch runs the game under `explorer /desktop=`, whose child's output never
    /// reaches Silo's log — verified on-device, where a working wrapped Alien Swarm launch captured 39 KB of
    /// wine output and ZERO DXVK lines. Deriving the flag from the log alone therefore oscillates:
    /// wrapped run succeeds → no failure in the log → next run unwrapped → fails → wrapped → …
    @Test("once set, the flag alone wraps the launch — no log evidence required")
    func flagAloneIsEnough() {
        let exe = URL(fileURLWithPath: "/games/Alien Swarm/swarm.exe")
        var config = GameConfig(appID: 630)
        #expect(LaunchOrchestrator.invocation(for: exe, virtualDesktop: config.needsVirtualDesktop).first != "explorer")
        config.needsVirtualDesktop = true
        #expect(LaunchOrchestrator.invocation(for: exe, virtualDesktop: config.needsVirtualDesktop).first == "explorer")
    }

    /// And it survives a config round-trip, so the game is not re-broken on the next app launch.
    @Test("the flag round-trips through config.json, and old configs default to false")
    func roundTrips() throws {
        var config = GameConfig(appID: 630)
        config.needsVirtualDesktop = true
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(GameConfig.self, from: data).needsVirtualDesktop)
        // A config written before this field existed must decode, defaulting to false.
        let legacy = Data(#"{"appID":630,"customArgs":[]}"#.utf8)
        #expect(try JSONDecoder().decode(GameConfig.self, from: legacy).needsVirtualDesktop == false)
    }
}
