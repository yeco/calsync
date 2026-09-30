import SwiftUI

/// Front: status + one collapsible section per account with the calendar ticks. Back (gear flips it): settings.
struct PopoverView: View {
  @ObservedObject var model: Model
  @State private var showBack = false
  @State private var angle = 0.0
  @State private var open = Set<String>()

  var body: some View {
    Group { if showBack { back } else { front } }
      .frame(width: 250)
      .padding(12)
      .rotation3DEffect(.degrees(angle), axis: (0, 1, 0), perspective: 0.5)
      .onAppear {
        showBack = false
        angle = 0
        open = Set(model.groups.filter { g in g.cals.contains { model.selected.contains($0.id) } }.map(\.source))
      }
  }

  /// Turn to edge-on, swap sides, turn back to flat. The card is unrotated when at rest, so its buttons stay clickable.
  private func flip() {
    withAnimation(.easeIn(duration: 0.18)) { angle = 90 }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
      showBack.toggle()
      angle = -90
      withAnimation(.easeOut(duration: 0.18)) { angle = 0 }
    }
  }

  private func expandedBinding(_ source: String) -> Binding<Bool> {
    Binding(
      get: { open.contains(source) },
      set: { isOpen in
        if isOpen { open.insert(source) } else { open.remove(source) }
      }
    )
  }

  // MARK: front

  private var front: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Circle().fill(healthColor).frame(width: 8, height: 8)
        Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        Spacer()
      }
      ScrollView {
       VStack(spacing: 4) {
        ForEach(model.groups, id: \.source) { group in
          DisclosureGroup(isExpanded: expandedBinding(group.source)) {
            VStack(alignment: .leading, spacing: 2) {
              ForEach(group.cals) { cal in
                Toggle(cal.title, isOn: Binding(get: { model.selected.contains(cal.id) }, set: { model.setSelected(cal.id, $0) }))
                  .toggleStyle(.checkbox)
              }
            }
            .padding(.leading, 4).padding(.top, 4)
          } label: {
            HStack {
              Text(group.source).font(.subheadline.weight(.medium))
              Spacer()
              let n = group.cals.filter { model.selected.contains($0.id) }.count
              if n > 0 { Text("\(n)").font(.caption2.monospacedDigit()).padding(.horizontal, 6).padding(.vertical, 1).background(.quaternary, in: Capsule()) }
            }
          }
        }
        ForEach(model.missing, id: \.self) { ref in
          Text("Missing: \(ref.source) / \(ref.title)").font(.caption).foregroundStyle(.orange)
        }
       }
      }
      .frame(height: listHeight)
      Divider()
      HStack {
        Button { model.manualSync() } label: { syncLabel }.disabled(model.paused || model.phase == .syncing)
        Spacer()
        Button { flip() } label: { Image(systemName: "gearshape") }.buttonStyle(.borderless).help("Settings")
      }
    }
  }

  // MARK: back

  @ViewBuilder private var syncLabel: some View {
    switch model.phase {
    case .idle: Text("Sync now")
    case .syncing: HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Syncing…") }
    case .done: Label("Synced", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
    case .failed: Label("Failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
    case .notReady: Label("Tick 2+ calendars", systemImage: "info.circle").foregroundStyle(.orange)
    }
  }

  private var back: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Button { flip() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless).help("Back")
        Text("Settings").font(.headline)
        Spacer()
      }
      Toggle("Pause syncing", isOn: $model.paused)
      Toggle(model.loginLabel, isOn: Binding(get: { model.loginOn }, set: { model.setLogin($0) }))
      Text("Copies each ticked calendar's events into the others as untitled Busy blocks, \(windowDaysAhead) days ahead. Nothing syncs until two or more are ticked.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Divider()
      HStack {
        Spacer()
        Button("Quit CalSync") { NSApplication.shared.terminate(nil) }
      }
    }
  }

  /// ScrollView has no intrinsic height in a menu bar window, so size it from the rows, up to a cap.
  private var listHeight: CGFloat {
    let rows = model.groups.reduce(0) { $0 + 1 + (open.contains($1.source) ? $1.cals.count : 0) } + model.missing.count
    return min(300, max(28, CGFloat(rows) * 26))
  }

  private var healthColor: Color {
    if model.failures >= 3 { return .red }
    if model.paused || model.selected.count < 2 { return .orange }
    return .green
  }
}
