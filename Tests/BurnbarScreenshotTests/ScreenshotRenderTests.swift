import AppKit
@testable import Burnbar
@testable import BurnbarCore
import SwiftUI
import XCTest

/// Renders the Burnbar UI to PNGs for the landing page (issue #177) using SwiftUI's
/// `ImageRenderer` — entirely in-process, with **no Screen Recording permission and
/// no `screencapture`**.
///
/// ## What is rendered, and how faithful it is
///
/// `ImageRenderer` draws SwiftUI's own primitives (text, images, shapes, stacks,
/// default `Button`s) but **cannot** draw AppKit-backed controls — `Form`,
/// `Picker(.segmented)`, `Toggle`, `TextField`, `.buttonStyle(.link)` render as
/// blank or as a placeholder box. (Verified empirically against the shipping views.)
///
/// So:
/// - **popover / empty-state** reuse the *real* data-bearing components —
///   `ProviderTileView` and `BurnBarView`, the substance of the popover — laid out
///   exactly as `PopoverContentView` lays them out (same header, same "Limits" card,
///   same footer literals). Only the one AppKit control in that view (the
///   `This Mac | All Macs` segmented `Picker`, which `ImageRenderer` can't draw) is
///   replaced with a pixel-faithful SwiftUI segmented stand-in, and the
///   `.buttonStyle(.link)` "Learn more" with a plain styled link. Everything with
///   real data — the tiles, the costs, the breakdown asymmetry, the burn bars — is
///   the genuine production view fed synthetic records priced through the real
///   `CostCalculator` + `TimeWindowAggregator`.
/// - **settings** mirrors the real `LeaderboardSettingsView`'s content (its exact
///   literal copy and section order) in a `Form`-free, ImageRenderer-drawable layout,
///   since `Form` itself renders blank. Clearly representative of the shipping tab.
/// - **menubar** is a tasteful SwiftUI mock of the `NSStatusItem` (AppKit, not a
///   SwiftUI view): the brand flame + today's spend among neighbouring glyphs.
///
/// ## Privacy
///
/// Every value is synthetic — token counts and known model ids only, never a prompt,
/// path, project name, or user identifier. The privacy thesis holds even though
/// these PNGs are published.
@MainActor
final class ScreenshotRenderTests: XCTestCase {
    private static let scale: CGFloat = 2

    private lazy var outputDir: URL = {
        if let override = ProcessInfo.processInfo.environment["BURNBAR_SHOTS_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-screenshots", isDirectory: true)
    }()

    override func setUp() {
        super.setUp()
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    }

    // MARK: - Tests (one per shipped image)

    func testRenderPopoverWithData() throws {
        let today = SampleData.today()
        let view = framed(width: 300) {
            PopoverShot(
                today: today,
                week: SampleData.week(),
                month: SampleData.month(),
                updatedText: "Updated 1 min. ago"
            )
        }
        try render(view, to: "popover.png")
    }

    func testRenderEmptyStatePopover() throws {
        let view = framed(width: 300) { EmptyStateShot() }
        try render(view, to: "empty-state.png")
    }

    func testRenderSettingsWindow() throws {
        let view = window(width: 460, height: 410, title: "Settings") {
            LeaderboardSettingsShot()
        }
        try render(view, to: "settings.png")
    }

    func testRenderMenuBar() throws {
        try render(MenuBarMock(), to: "menubar.png")
    }

    // MARK: - Rendering

    private func render(_ view: some View, to name: String) throws {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = Self.scale

        guard let nsImage = renderer.nsImage else {
            return XCTFail("ImageRenderer produced no image for \(name)")
        }
        guard
            let tiff = nsImage.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            return XCTFail("Failed to encode PNG for \(name)")
        }

        let url = outputDir.appendingPathComponent(name)
        try png.write(to: url)

        XCTAssertGreaterThan(png.count, 1000, "\(name) is suspiciously small")
        XCTAssertGreaterThan(bitmap.pixelsWide, 0, "\(name) has no width")
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0, "\(name) has no height")
        print("RENDERED \(name) -> \(url.path) (\(bitmap.pixelsWide)x\(bitmap.pixelsHigh)px, \(png.count) bytes)")
    }

    // MARK: - Chrome

    private func framed(width: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(width: width)
            .background(Color(red: 0.11, green: 0.11, blue: 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
            .padding(20)
            .background(BrandBackground())
    }

    private func window(
        width: CGFloat,
        height: CGFloat,
        title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 8) {
                    Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 11, height: 11)
                    Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 11, height: 11)
                    Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 11, height: 11)
                    Spacer()
                }
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Color(red: 0.16, green: 0.16, blue: 0.17))

            content()
                .frame(width: width, height: height, alignment: .top)
                .background(Color(red: 0.13, green: 0.13, blue: 0.14))
        }
        .frame(width: width)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .padding(24)
        .background(BrandBackground())
    }
}

// MARK: - Brand backdrop

private struct BrandBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.06, green: 0.06, blue: 0.07),
                Color(red: 0.10, green: 0.07, blue: 0.06),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Popover (real tiles + bars; ImageRenderer-safe chrome)

/// Reproduces `PopoverContentView`'s populated layout using its *real* subviews —
/// `ProviderTileView` (one per provider) and `BurnBarView` (weekly + monthly) — so
/// every data-bearing pixel is the genuine production view. The header, the "Limits"
/// card wrapper, and the footer match the shipping view's structure and literals.
/// The one AppKit control `PopoverContentView` carries (the segmented mode `Picker`)
/// is drawn here as a SwiftUI stand-in because `ImageRenderer` can't render the real
/// one.
private struct PopoverShot: View {
    let today: WindowAggregate
    let week: WindowAggregate
    let month: WindowAggregate
    let updatedText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PopoverHeader()
            SegmentedModePicker()

            ForEach(Provider.allCases) { provider in
                ProviderTileView(provider: provider, model: ProviderTileModel.make(provider: provider, from: today))
            }

            limitsCard

            Divider()
            PopoverFooter(updatedText: updatedText)
        }
        .padding(12)
        .frame(width: 300)
    }

    private var limitsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Limits")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            // The real BurnBarView — pure SwiftUI (its TimelineView countdown renders
            // its current snapshot), so ImageRenderer draws it faithfully.
            BurnBarView(value: week.totalTokens, limit: BurnBudget.weeklyTokens, window: .weekly)
            BurnBarView(value: month.totalTokens, limit: BurnBudget.monthlyTokens, window: .monthly)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The popover's empty state, reproducing `PopoverContentView.emptyState`'s exact
/// copy and layout (the only swap is the `.buttonStyle(.link)` "Learn more", which
/// `ImageRenderer` can't draw, rendered as a plain styled link).
private struct EmptyStateShot: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PopoverHeader()
            SegmentedModePicker()

            VStack(spacing: 8) {
                Image(systemName: "flame").font(.title2).foregroundStyle(.tertiary)
                Text("No data yet")
                    .font(.subheadline.weight(.medium))
                Text("Run Claude Code or Codex and your burn shows up here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(
                    "Burnbar reads only your local Claude Code (~/.claude) and Codex "
                        + "(~/.codex) logs — no account or permissions needed."
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    PillButton(title: "Refresh")
                    PillButton(title: "Open Settings")
                }
                .padding(.top, 2)

                Text("Learn more")
                    .font(.caption2)
                    .foregroundStyle(Color(red: 0.30, green: 0.62, blue: 1.0))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)

            Divider()
            PopoverFooter(updatedText: "Not loaded yet")
        }
        .padding(12)
        .frame(width: 300)
    }
}

private struct PopoverHeader: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "flame.fill").foregroundStyle(.orange)
            Text("Burnbar").font(.headline)
            Spacer()
            Text("Today").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct PopoverFooter: View {
    let updatedText: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(updatedText)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                PillButton(title: "Refresh now", systemImage: "arrow.clockwise")
                PillButton(title: "Settings…", systemImage: "gearshape")
                Spacer()
                PillButton(title: "Quit", systemImage: "power")
            }
        }
    }
}

/// A SwiftUI-drawn stand-in for `PopoverContentView`'s `.pickerStyle(.segmented)`
/// `This Mac | All Macs` control (the real one is AppKit-backed and won't render).
private struct SegmentedModePicker: View {
    var body: some View {
        HStack(spacing: 0) {
            segment("This Mac", selected: true)
            segment("All Macs", selected: false)
        }
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .frame(maxWidth: .infinity)
    }

    private func segment(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.caption.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(
                selected ? Color.white.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
            .padding(2)
    }
}

/// A small pill mimicking the popover's `.controlSize(.small)` text buttons (the
/// real `Button`s render, but this keeps the dark frame consistent and crisp).
private struct PillButton: View {
    let title: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.caption2) }
            Text(title).font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }
}

// MARK: - Settings (Leaderboard tab, Form-free recreation)

/// Mirrors `LeaderboardSettingsView`'s content — the same readiness line, account
/// section, opt-in toggle, and privacy footer copy — in an `ImageRenderer`-drawable
/// layout (the real view's `Form`/`Toggle` render blank). Clearly representative of
/// the shipping Leaderboard tab.
private struct LeaderboardSettingsShot: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            tabBar

            ScrollViewReaderless {
                groupCard {
                    Label(
                        "The public leaderboard is rolling out soon. Your opt-in choice is saved "
                            + "now — once it's live, your opted-in totals will appear publicly.",
                        systemImage: "clock.badge"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                sectionHeader("Account")
                groupCard {
                    HStack {
                        Label("Signed in to GitHub", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        PillButton(title: "Sign out")
                    }
                }

                sectionHeader("Publishing")
                groupCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Publish to the leaderboard")
                            Spacer()
                            ToggleMock(on: true)
                        }
                        Divider().overlay(Color.white.opacity(0.08))
                        HStack {
                            Text("Last uploaded").foregroundStyle(.secondary)
                            Spacer()
                            Text("2 hours ago").foregroundStyle(.secondary)
                        }
                        PillButton(title: "Upload now")
                    }
                }

                Text(
                    "Off by default. When on, each uploaded row is only "
                        + "{ date, provider, tokens, cost_usd } — never your prompts, projects, paths, "
                        + "machine ids, or raw model names."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tabBar: some View {
        HStack(spacing: 22) {
            tab("General", "gearshape")
            tab("Providers", "cpu")
            tab("Devices", "laptopcomputer")
            tab("Leaderboard", "trophy", selected: true)
            tab("About", "info.circle")
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }

    private func tab(_ title: String, _ icon: String, selected: Bool = false) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 16))
            Text(title).font(.caption2)
        }
        .foregroundStyle(selected ? Color(red: 0.30, green: 0.62, blue: 1.0) : Color.secondary)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
    }

    private func groupCard(@ViewBuilder content: () -> some View) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
    }
}

/// A vertical stack used in place of SwiftUI's `Form`, which renders blank under
/// `ImageRenderer`.
private struct ScrollViewReaderless<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
    }
}

/// A SwiftUI-drawn "on" toggle (the real `Toggle` renders blank under ImageRenderer).
private struct ToggleMock: View {
    let on: Bool
    var body: some View {
        Capsule()
            .fill(on ? Color.green : Color.secondary.opacity(0.4))
            .frame(width: 38, height: 22)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(.white).frame(width: 18, height: 18).padding(2)
            }
    }
}

// MARK: - Menu bar mock

/// A representative SwiftUI mock of Burnbar's menu-bar `NSStatusItem` (AppKit, not a
/// SwiftUI view): the brand flame + today's spend among neighbouring glyphs + a
/// fixed demo clock. Wide banner aspect for the hero frame.
private struct MenuBarMock: View {
    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            menuGlyph("wifi")
            menuGlyph("battery.100")
            menuGlyph("magnifyingglass")
            menuGlyph("control")

            HStack(spacing: 5) {
                Image(systemName: "flame.fill")
                    .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.16))
                Text("$8.47").monospacedDigit().foregroundStyle(.white)
            }
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            .padding(.leading, 6)
            .padding(.trailing, 14)

            Text("9:41 AM")
                .font(.system(size: 14, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.trailing, 18)
        }
        .frame(width: 800, height: 38)
        .background(
            LinearGradient(
                colors: [Color(red: 0.13, green: 0.13, blue: 0.14), Color(red: 0.17, green: 0.15, blue: 0.14)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }
    }

    private func menuGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 9)
    }
}

// MARK: - Synthetic sample data

/// Deterministic, privacy-safe sample usage: token counts + known model ids only —
/// no prompts, paths, project names, or identifiers. Priced + aggregated through the
/// real engine so the rendered tiles/bars are self-consistent and sit at a healthy
/// sub-limit fill.
private enum SampleData {
    private static let aggregator = TimeWindowAggregator()
    private static let calculator = CostCalculator()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar.current
        f.timeZone = Calendar.current.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func day(daysAgo: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return dayFormatter.string(from: date)
    }

    private static func todayRecords() -> [UsageRecord] {
        [
            UsageRecord(
                provider: .claude, model: "claude-opus-4-7", day: day(daysAgo: 0),
                inputTokens: 184_500, outputTokens: 96_200,
                cacheReadTokens: 2_410_000, cacheCreationTokens: 312_000
            ),
            UsageRecord(
                provider: .claude, model: "claude-sonnet-4-6", day: day(daysAgo: 0),
                inputTokens: 58_300, outputTokens: 41_700,
                cacheReadTokens: 690_000, cacheCreationTokens: 74_000
            ),
            UsageRecord(
                provider: .codex, model: "gpt-5.5", day: day(daysAgo: 0),
                inputTokens: 432_000
            ),
        ]
    }

    /// Modest prior-day usage so weekly/monthly bars fill to a believable ~40–60%
    /// (green/orange), not 0% and not over-limit red.
    private static func priorDays(count: Int) -> [UsageRecord] {
        var records: [UsageRecord] = []
        for offset in 1 ... count {
            let dayKey = day(daysAgo: offset)
            records.append(
                UsageRecord(
                    provider: .claude, model: "claude-opus-4-7", day: dayKey,
                    inputTokens: 40_000, outputTokens: 24_000,
                    cacheReadTokens: 360_000, cacheCreationTokens: 48_000
                )
            )
            records.append(
                UsageRecord(provider: .codex, model: "gpt-5.5", day: dayKey, inputTokens: 70_000)
            )
        }
        return records
    }

    static func today() -> WindowAggregate {
        aggregator.aggregate(calculator.priced(todayRecords()), window: .today)
    }

    static func week() -> WindowAggregate {
        aggregator.aggregate(calculator.priced(todayRecords() + priorDays(count: 6)), window: .week)
    }

    static func month() -> WindowAggregate {
        aggregator.aggregate(calculator.priced(todayRecords() + priorDays(count: 27)), window: .month)
    }
}
