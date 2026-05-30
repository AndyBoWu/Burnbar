import BurnbarCore
import SwiftUI

/// Placeholder popover content for the M1.1.1 skeleton.
///
/// Provider tiles, burn bars, and reset countdowns replace this in Epic 1.5;
/// the "no data yet" copy is the fresh-install state described in 1.5.2.
struct BurnbarMenuContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "flame.fill")
                    .foregroundStyle(.orange)
                Text("Burnbar")
                    .font(.headline)
            }
            Text("No data yet — Claude/Codex parsers land in Epic 1.2 / 1.3.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Button("Quit Burnbar") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
    }
}
