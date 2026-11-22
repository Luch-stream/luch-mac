// Reserved regions on iPhone Duo: the cameras are occlusions, the fold is a division.
// A region's `frame` already includes the system margins, so keeping interactive content out of
// the frame is enough; the extra clearance is only our own visual breathing room.
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

enum ReservedSpace {
    /// How far interactive content must move to clear every active occlusion region: the closed
    /// Duo's camera is always there, the inner one appears only while that camera is in use.
    static func occlusionInsets(in proxy: GeometryProxy, clearance: CGFloat = 12) -> EdgeInsets {
        guard #available(iOS 27.1, *) else { return EdgeInsets() }
        let bounds = CGRect(origin: .zero, size: proxy.size)
        var insets = EdgeInsets()

        let regions = proxy.reservedRegions(
            kind: .occlusion,
            options: [.includeInactive],
            layoutDirectionBehavior: .fixed)

        for region in regions where region.isActive {
            let frame = region.frame.intersection(bounds)
            guard !frame.isNull, frame.width > 0, frame.height > 0 else { continue }
            // A camera that reaches an edge pushes the HUD past it; a corner region can do both.
            if frame.minY <= bounds.minY + 1 {
                insets.top = max(insets.top, frame.maxY - bounds.minY + clearance)
            }
            if frame.maxY >= bounds.maxY - 1 {
                insets.bottom = max(insets.bottom, bounds.maxY - frame.minY + clearance)
            }
            if frame.minX <= bounds.minX + 1 {
                insets.leading = max(insets.leading, frame.maxX - bounds.minX + clearance)
            }
            if frame.maxX >= bounds.maxX - 1 {
                insets.trailing = max(insets.trailing, bounds.maxX - frame.minX + clearance)
            }
        }

        // The simulator paints the cover-display camera into the screen mask and does not report
        // it as a reserved region. The wide trailing side-control inset is the signature of that
        // display, so keep the top-trailing corner (where the camera lives) clear anyway.
        if proxy.safeAreaInsets.trailing >= 70 {
            insets.top = max(insets.top, 56)
        }
        return insets
    }

    /// Debug helper: prints the geometry and both kinds of reserved regions for a debug launch.
    /// Runs once per launch so a screenshot session can record what the simulator reported.
    static func probeUntilChanged(_ proxy: GeometryProxy) {
        guard UIDebugLaunch.state != nil else { return }
        #if DEBUG
        var lines = ["LUCH-DIAG bounds=\(proxy.size) safe=\(proxy.safeAreaInsets)"]
        if #available(iOS 27.1, *) {
            for kind in [ReservedRegion.Kind.division, .occlusion] {
                let regions = proxy.reservedRegions(
                    kind: kind,
                    options: [.includeInactive],
                    layoutDirectionBehavior: .fixed)
                let described = regions.map {
                    "frame=\($0.frame) active=\($0.isActive) margins=\($0.margins)"
                }
                lines.append("LUCH-DIAG \(kind) \(described)")
            }
        }
        let insets = occlusionInsets(in: proxy)
        lines.append("LUCH-DIAG insets=\(insets)")
        NSLog("%@", lines.joined(separator: "\n"))
        #endif
    }
}
