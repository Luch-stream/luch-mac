// Live playback: immersive on a phone, padded on a tablet, and split around an iPhone Duo fold.
// The Duo is a content-first device here: the picture keeps the large area, the controls take a
// narrow column or a compact strip, and nothing interactive sits in the fold or under the camera.
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit

struct StreamView: View {
    let viewer: Viewer
    @Binding var settingsPresented: Bool
    /// Debug `-luchUI` launches: start with the HUD hidden, or keep it on screen for a screenshot.
    var startsWithControlsHidden = false
    var autoHidesControls = true

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Tablets get a framed picture; phones (including the Duo's displays) stay immersive.
    private var padded: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
    }

    var body: some View {
        NavigationStack {
            videoPane
                .ignoresSafeArea()
                .navigationTitle(viewer.senderName.isEmpty ? "Luch" : viewer.senderName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbarBackground(.hidden, for: .bottomBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    // The system owns where these live: a bottom bar on a phone, the vertical side
                    // region on a closed Duo, the same items on the inner display.
                    ToolbarItem(placement: .bottomBar) {
                        HStack(spacing: 10) {
                            LiveBadge()
                            StatsLine(fps: viewer.fps, latency: viewer.latencyMs)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 8)
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button {
                            viewer.requestKeyframe()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .frame(width: 24, height: 24)
                        }
                        .accessibilityLabel("Запросить ключевой кадр")

                        Button {
                            settingsPresented = true
                        } label: {
                            Image(systemName: "gearshape")
                                .frame(width: 24, height: 24)
                        }
                        .accessibilityLabel("Настройки")

                        Button {
                            viewer.disconnect()
                        } label: {
                            Image(systemName: "arrow.right.square")
                                .frame(width: 24, height: 24)
                        }
                        .accessibilityLabel("Отключиться")
                    }
                }
                .sheet(isPresented: $settingsPresented) { SettingsView() }
        }
        .environment(\.colorScheme, .dark)
    }

    private var videoPane: some View {
        VideoSurface(onReady: { viewer.attach($0) }, onDismantle: { viewer.detach($0) })
            .background(Color.black)
    }
}

// MARK: - closed Duo: the vertical side region

/// On the closed Duo the display is wide and short: toolbars belong on the right side, where the
/// thumb reaches, and the picture keeps the rest. Nothing here is a "side panel" we invented —
/// it is the region the system lays out for controls.
private struct SideRailLayout: View {
    let viewer: Viewer
    @Binding var settingsPresented: Bool
    let occlusion: EdgeInsets

    var body: some View {
        HStack(spacing: 0) {
            VideoSurface(onReady: { viewer.attach($0) }, onDismantle: { viewer.detach($0) })
                .ignoresSafeArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 16) {
                PulseDot(diameter: 7)
                    .padding(.top, 2)

                VStack(spacing: 3) {
                    Text(String(format: "%.0f", viewer.fps))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(LuchStyle.primaryText)
                    Text("fps")
                        .font(.caption2)
                        .foregroundStyle(LuchStyle.secondaryText)
                    Text(String(format: "%.0f мс", viewer.latencyMs))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(LuchStyle.accent)
                }

                Rectangle()
                    .fill(LuchStyle.separator)
                    .frame(width: 32, height: 0.5)

                VStack(spacing: 10) {
                    railButton("arrow.clockwise", "Запросить ключевой кадр") { viewer.requestKeyframe() }
                    railButton("gearshape", "Настройки") { settingsPresented = true }
                }

                Spacer(minLength: 0)

                railButton("rectangle.portrait.and.arrow.right", "Отключиться") { viewer.disconnect() }
            }
            .padding(.vertical, 14 + occlusion.top)
            .padding(.horizontal, 6)
            // The Duo's side region is a narrow strip for the status bar, not a column of its own.
            .frame(width: 58)
            .frame(maxHeight: .infinity)
            .background(LuchStyle.surface)
        }
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }

    private func railButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LuchStyle.primaryText)
                .frame(width: 40, height: 40)
                .background(LuchStyle.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Duo layout selection

/// How a Duo wants its stream laid out. An open Duo still reports its fold region with
/// `.includeInactive`, which is how the device is recognized even when nothing is folded yet.
@available(iOS 27.1, *)
enum DuoLayout: Equatable {
    /// Fully open inner display: picture plus a narrow control column.
    case open
    /// Partially folded: the fold splits the inner display into two usable halves.
    case folded(axis: FoldGuide.Axis, gap: CGFloat)

    static func query(in proxy: GeometryProxy) -> DuoLayout? {
        // The debug launch can force a pose even where the simulator reports no hinge.
        if UIDebugLaunch.fold == .open { return .open }
        if let guide = FoldGuide.query(in: proxy) {
            let gap = guide.axis == .vertical ? guide.fold.width : guide.fold.height
            return .folded(axis: guide.axis, gap: max(24, gap))
        }
        let divisions = proxy.reservedRegions(
            kind: .division,
            options: [.includeInactive],
            layoutDirectionBehavior: .fixed)
        guard !divisions.isEmpty else { return nil }
        return .open
    }
}

// MARK: - Fold geometry

/// The usable halves around an active iPhone Duo fold. Reserved regions include the system's
/// margins, so keeping content inside the halves is enough.
struct FoldGuide {
    enum Axis: Equatable { case vertical, horizontal }

    let axis: Axis
    let leading: CGRect
    let trailing: CGRect
    let fold: CGRect

    @available(iOS 27.1, *)
    static func query(in proxy: GeometryProxy) -> FoldGuide? {
        let bounds = CGRect(origin: .zero, size: proxy.size)

        // A `-luchFold` launch draws a synthetic fold: a simulator Duo reports no reserved region.
        if let pose = UIDebugLaunch.fold, pose != .open {
            return synthetic(pose: pose, in: bounds)
        }

        let regions = proxy.reservedRegions(
            kind: .division,
            options: [.includeInactive],
            layoutDirectionBehavior: .fixed)
        guard let region = regions.first(where: { $0.isActive }) else { return nil }

        let fold = region.frame.intersection(bounds)
        guard !fold.isNull, fold.width > 0, fold.height > 0 else { return nil }

        // A book-like fold is a tall strip; tabletop and tent poses give a wide strip.
        if fold.width < fold.height {
            guard fold.minX > 160, bounds.maxX - fold.maxX > 160 else { return nil }
            return FoldGuide(
                axis: .vertical,
                leading: CGRect(x: 0, y: 0, width: fold.minX, height: bounds.height),
                trailing: CGRect(x: fold.maxX, y: 0, width: bounds.maxX - fold.maxX, height: bounds.height),
                fold: fold)
        } else {
            guard fold.minY > 140, bounds.maxY - fold.maxY > 140 else { return nil }
            return FoldGuide(
                axis: .horizontal,
                leading: CGRect(x: 0, y: 0, width: bounds.width, height: fold.minY),
                trailing: CGRect(x: 0, y: fold.maxY, width: bounds.width, height: bounds.maxY - fold.maxY),
                fold: fold)
        }
    }

    /// The fold the debug launch asks for: a strip through the centre, halves on the edges.
    /// `book` is vertical (left/right), `tabletop` and `tent` are horizontal (top/bottom).
    private static func synthetic(pose: UIDebugLaunch.Pose, in bounds: CGRect) -> FoldGuide {
        switch pose {
        case .open:
            return FoldGuide(
                axis: .vertical,
                leading: bounds,
                trailing: .zero,
                fold: .zero)
        case .book:
            let width: CGFloat = 56
            let fold = CGRect(x: (bounds.width - width) / 2, y: 0, width: width, height: bounds.height)
            return FoldGuide(
                axis: .vertical,
                leading: CGRect(x: 0, y: 0, width: fold.minX, height: bounds.height),
                trailing: CGRect(x: fold.maxX, y: 0, width: bounds.maxX - fold.maxX, height: bounds.height),
                fold: fold)
        case .tabletop, .tent:
            let height: CGFloat = 56
            let fold = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
            return FoldGuide(
                axis: .horizontal,
                leading: CGRect(x: 0, y: 0, width: bounds.width, height: fold.minY),
                trailing: CGRect(x: 0, y: fold.maxY, width: bounds.width, height: bounds.maxY - fold.maxY),
                fold: fold)
        }
    }
}

// MARK: - Duo layout

/// Content first: the picture owns the large area, controls take only the column or strip they
/// need. Interactive controls are pushed clear of the active camera occlusion region.
@available(iOS 27.1, *)
private struct DuoStreamLayout: View {
    let viewer: Viewer
    @Binding var settingsPresented: Bool
    let mode: DuoLayout

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var keyframeFeedback = 0

    private var compactHeight: Bool { verticalSizeClass == .compact }

    var body: some View {
        GeometryReader { proxy in
            let insets = ReservedSpace.occlusionInsets(in: proxy)
            Group {
                switch mode {
                case .open:
                    openLayout(insets: insets, size: proxy.size)
                case .folded(let axis, let gap):
                    foldedLayout(axis: axis, gap: gap, size: proxy.size)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(Color.black)
        .sensoryFeedback(.impact(weight: .light), trigger: keyframeFeedback)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: mode)
    }

    // MARK: open inner display

    private func openLayout(insets: EdgeInsets, size: CGSize) -> some View {
        // 30-35% for the controls, capped: the picture must not shrink for the sidebar.
        let sidebar = min(360, size.width * 0.33)
        return HStack(spacing: 0) {
            videoPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            openSidebar(insets: insets)
                .frame(width: sidebar, height: size.height)
        }
    }

    private func openSidebar(insets: EdgeInsets) -> some View {
        VStack(spacing: 14) {
            LiveBadge()

            // The name is rotated instead of truncated: a sidebar is narrow, a name is long.
            Text(viewer.senderName)
                .font(.headline)
                .foregroundStyle(LuchStyle.primaryText)
                .fixedSize()
                .rotationEffect(.degrees(90))
                .frame(width: 40, height: 200)

            StatsLine(fps: viewer.fps, latency: viewer.latencyMs)

            Rectangle()
                .fill(LuchStyle.separator)
                .frame(width: 56, height: 0.5)

            // A side panel reads top to bottom: its actions stack, they never sit side by side.
            VStack(spacing: 12) {
                BarIconButton(systemImage: "arrow.clockwise", label: "Запросить ключевой кадр") {
                    requestKeyframe()
                }
                BarIconButton(systemImage: "gearshape", label: "Настройки") {
                    settingsPresented = true
                }
            }

            Spacer(minLength: 0)

            InlineDisconnectButton(compact: true) { viewer.disconnect() }
        }
        .padding(.horizontal, 12)
        .padding(.top, 20 + insets.top)
        .padding(.bottom, 20 + insets.bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassSurface(cornerRadius: 0, tint: LuchStyle.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Управление трансляцией")
    }

    // MARK: folded inner display

    @ViewBuilder
    private func foldedLayout(axis: FoldGuide.Axis, gap: CGFloat, size: CGSize) -> some View {
        switch axis {
        case .vertical:
            let half = max(120, (size.width - gap) / 2)
            HStack(spacing: 0) {
                videoPane
                    .frame(width: half, height: size.height)
                Color.black.frame(width: gap)
                foldedPanel(vertical: true)
                    .frame(width: half, height: size.height)
            }
        case .horizontal:
            let half = max(100, (size.height - gap) / 2)
            VStack(spacing: 0) {
                videoPane
                    .frame(width: size.width, height: half)
                Color.black.frame(height: gap)
                foldedPanel(vertical: false)
                    .frame(width: size.width, height: half)
            }
        }
    }

    /// The card is centred in its half on both axes; the fold gap keeps it away from the picture.
    private func foldedPanel(vertical: Bool) -> some View {
        Group {
            if vertical {
                verticalPanelCard
            } else {
                horizontalPanelBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(16)
    }

    private var verticalPanelCard: some View {
        ViewThatFits(in: .horizontal) {
            verticalPanelFull
            verticalPanelCompact
        }
        // The card keeps its own size and is centred by the half, never pinned to an edge.
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, alignment: .center)
        .glassSurface(cornerRadius: 28, tint: LuchStyle.panel)
    }

    private var verticalPanelFull: some View {
        VStack(spacing: compactHeight ? 14 : 18) {
            VStack(spacing: 8) {
                PulseDot(diameter: 7)
                    .padding(.top, 2)
                senderName(font: .title3.weight(.semibold))
                statsText(font: .subheadline.monospacedDigit())
            }

            VStack(spacing: 8) {
                PanelActionButton(title: "Ключевой кадр", systemImage: "arrow.clockwise") {
                    requestKeyframe()
                }
                PanelActionButton(title: "Настройки", systemImage: "gearshape") {
                    settingsPresented = true
                }
            }

            InlineDisconnectButton { viewer.disconnect() }
        }
        .padding(compactHeight ? 18 : 24)
    }

    /// The panel gives up text before it steals space from the picture.
    private var verticalPanelCompact: some View {
        VStack(spacing: 12) {
            LiveBadge()
            senderName(font: .subheadline.weight(.semibold))
            statsText(font: .caption.monospacedDigit())

            // A vertical card reads top to bottom, so its two actions stack instead of sharing a row.
            VStack(spacing: 8) {
                BarIconButton(systemImage: "arrow.clockwise", label: "Запросить ключевой кадр") {
                    requestKeyframe()
                }
                BarIconButton(systemImage: "gearshape", label: "Настройки") {
                    settingsPresented = true
                }
            }

            InlineDisconnectButton(compact: true) { viewer.disconnect() }
        }
        .padding(16)
    }

    private var horizontalPanelBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                PulseDot(diameter: 7)
                    .padding(.top, 2)
                senderName(font: .headline)
                statsText(font: .caption.monospacedDigit())
                Spacer(minLength: 8)
                actions
                InlineDisconnectButton { viewer.disconnect() }
            }

            HStack(spacing: 10) {
                PulseDot(diameter: 7)
                    .padding(.top, 2)
                statsText(font: .caption.monospacedDigit())
                Spacer(minLength: 8)
                actions
                InlineDisconnectButton(compact: true) { viewer.disconnect() }
            }

            HStack(spacing: 8) {
                PulseDot(diameter: 8)
                Spacer(minLength: 8)
                actions
                InlineDisconnectButton(compact: true) { viewer.disconnect() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 680)
        .glassSurface(cornerRadius: 24, tint: LuchStyle.panel)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            BarIconButton(systemImage: "arrow.clockwise", label: "Запросить ключевой кадр") {
                requestKeyframe()
            }
            BarIconButton(systemImage: "gearshape", label: "Настройки") {
                settingsPresented = true
            }
        }
        .fixedSize()
    }

    private var videoPane: some View {
        VideoSurface(
            onReady: { viewer.attach($0) },
            onDismantle: { viewer.detach($0) })
            .background(Color.black)
            .overlay {
                Rectangle()
                    .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
            }
            .accessibilityElement()
            .accessibilityLabel("Трансляция экрана")
            .accessibilityAddTraits(.isImage)
    }

    private func senderName(font: Font) -> some View {
        Text(viewer.senderName)
            .font(font)
            .foregroundStyle(.white)
            .lineLimit(1)
            .truncationMode(.tail)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
    }

    private func statsText(font: Font) -> some View {
        Text("\(StatsFormat.fps(viewer.fps)) · \(StatsFormat.latency(viewer.latencyMs))")
            .font(font)
            .foregroundStyle(.white.opacity(0.70))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func requestKeyframe() {
        viewer.requestKeyframe()
        keyframeFeedback += 1
    }
}

// MARK: - Immersive layout

/// The normal layout: video fills the screen and a floating HUD fades away after three seconds.
private struct OverlayStreamLayout: View {
    let viewer: Viewer
    let padded: Bool
    @Binding var settingsPresented: Bool
    let autoHidesControls: Bool
    let occlusion: EdgeInsets

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var controlsVisible: Bool
    @State private var keyframeFeedback = 0

    init(
        viewer: Viewer,
        padded: Bool,
        settingsPresented: Binding<Bool>,
        startsWithControlsHidden: Bool,
        autoHidesControls: Bool,
        occlusion: EdgeInsets
    ) {
        self.viewer = viewer
        self.padded = padded
        self._settingsPresented = settingsPresented
        self.autoHidesControls = autoHidesControls
        self.occlusion = occlusion
        self._controlsVisible = State(initialValue: !startsWithControlsHidden)
    }

    private struct AutoHide: Equatable {
        var controlsVisible: Bool
        var settingsPresented: Bool
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }

            video
                .onTapGesture { toggleControls() }
                .accessibilityElement()
                .accessibilityLabel("Трансляция экрана")
                .accessibilityAddTraits(.isImage)
                .accessibilityAction { setControls(visible: true) }

            controls
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: AutoHide(controlsVisible: controlsVisible, settingsPresented: settingsPresented)) {
            guard autoHidesControls, controlsVisible, !settingsPresented else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            setControls(visible: false)
        }
    }

    @ViewBuilder
    private var video: some View {
        if padded {
            VideoSurface(
                onReady: { viewer.attach($0) },
                onDismantle: { viewer.detach($0) })
                .clipShape(RoundedRectangle(cornerRadius: LuchStyle.videoCorner, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: LuchStyle.videoCorner, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.55), radius: 30, y: 16)
                .padding(.horizontal, 26)
                .padding(.vertical, 20)
        } else {
            VideoSurface(
                onReady: { viewer.attach($0) },
                onDismantle: { viewer.detach($0) })
                .ignoresSafeArea()
        }
    }

    private var controls: some View {
        VStack {
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                LiveBadge()
                ViewThatFits(in: .horizontal) {
                    Text(viewer.senderName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LuchStyle.primaryText)
                        .lineLimit(1)
                    EmptyView()
                }
                StatsLine(fps: viewer.fps, latency: viewer.latencyMs)
                Spacer(minLength: 6)
                BarIconButton(systemImage: "arrow.clockwise", label: "Запросить ключевой кадр") {
                    requestKeyframe()
                }
                BarIconButton(systemImage: "gearshape", label: "Настройки") {
                    settingsPresented = true
                }
                InlineDisconnectButton(compact: true) { viewer.disconnect() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: padded ? 620 : .infinity)
            .glassSurface(cornerRadius: LuchStyle.panelCorner, tint: LuchStyle.panel)
            .padding(.horizontal, padded ? 30 : 12)
            .padding(.bottom, max(10, occlusion.bottom + 6))
            .padding(.top, 6)
        }
        .opacity(controlsVisible ? 1 : 0)
        .offset(y: controlsVisible ? 0 : 20)
        .allowsHitTesting(controlsVisible)
        .accessibilityHidden(!controlsVisible)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.26), value: controlsVisible)
        .sensoryFeedback(.impact(weight: .light), trigger: keyframeFeedback)
    }

    private func toggleControls() {
        setControls(visible: !controlsVisible)
    }

    private func setControls(visible: Bool) {
        controlsVisible = visible
    }

    private func requestKeyframe() {
        viewer.requestKeyframe()
        keyframeFeedback += 1
    }
}

// MARK: - Shared HUD pieces

/// The top HUD, with three densities so narrow windows lose text instead of wrapping it.
private struct StreamTopBar: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let senderName: String
    let fps: Double
    let latency: Double
    let onKeyframe: () -> Void
    let onSettings: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            full
            medium
            minimal
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .glassSurface(cornerRadius: LuchStyle.panelCorner, tint: LuchStyle.panel)
    }

    private var full: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    PulseDot(diameter: 7)
                    .padding(.top, 2)
                    name
                }
                StatsLine(fps: fps, latency: latency)
            }

            Spacer(minLength: 6)

            actions
        }
    }

    private var medium: some View {
        HStack(spacing: 10) {
            LiveBadge()
            name
                .frame(maxWidth: 120, alignment: .leading)
            Spacer(minLength: 6)
            actions
        }
    }

    private var minimal: some View {
        HStack(spacing: 10) {
            PulseDot(diameter: 8)
            Spacer(minLength: 6)
            actions
        }
    }

    private var name: some View {
        Text(senderName)
            .font(.headline)
            .foregroundStyle(.white)
            .lineLimit(1)
            .truncationMode(.tail)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: horizontalSizeClass == .regular ? 260 : 150, alignment: .leading)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            BarIconButton(systemImage: "arrow.clockwise", label: "Запросить ключевой кадр", action: onKeyframe)
            BarIconButton(systemImage: "gearshape", label: "Настройки", action: onSettings)
        }
        .fixedSize()
    }
}

private struct BarIconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.14), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Standalone button over the video: a real glass button on iOS 26, a material capsule before it.
/// On a narrow window it keeps only the icon, with the same accessible name.
private struct GlassDisconnectButton: View {
    let action: () -> Void

    var body: some View {
        if #available(iOS 26, *) {
            Button(action: action) {
                disconnectLabel
            }
            .buttonStyle(.glass)
            .accessibilityHint("Завершить просмотр и вернуться к ожиданию")
        } else {
            Button(action: action) {
                disconnectLabel
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .glassSurface(cornerRadius: 22, tint: LuchStyle.panel)
            .accessibilityHint("Завершить просмотр и вернуться к ожиданию")
        }
    }

    private var disconnectLabel: some View {
        ViewThatFits(in: .horizontal) {
            Label("Отключиться", systemImage: "rectangle.portrait.and.arrow.right")
                .lineLimit(1)
                .fixedSize()
            Image(systemName: "rectangle.portrait.and.arrow.right")
                .accessibilityLabel("Отключиться")
        }
        .font(.subheadline.weight(.semibold))
    }
}

/// Button that already sits on glass, so it only adds a soft fill instead of a second glass layer.
/// `compact` drops the word on widths where it would be squeezed, keeping the accessible name.
private struct InlineDisconnectButton: View {
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if compact {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.12), in: Circle())
                    .contentShape(Circle())
            } else {
                ViewThatFits(in: .horizontal) {
                    Label("Отключиться", systemImage: "rectangle.portrait.and.arrow.right")
                        .lineLimit(1)
                        .fixedSize()
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .accessibilityLabel("Отключиться")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.white.opacity(0.12), in: Capsule())
                .contentShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Отключиться")
        .accessibilityHint("Завершить просмотр и вернуться к ожиданию")
    }
}

private struct PanelActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ViewThatFits(in: .horizontal) {
                Label(title, systemImage: systemImage)
                    .lineLimit(1)
                    .fixedSize()
                Image(systemName: systemImage)
                    .accessibilityLabel(title)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
