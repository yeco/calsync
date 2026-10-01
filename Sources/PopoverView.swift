import SwiftUI

/// Front: status + one row per pair (calendar, direction, calendar). Back (gear flips it): settings.
struct PopoverView: View {
  @ObservedObject var model: Model
  @State private var showBack = false
  @State private var angle = 0.0

  var body: some View {
    Group { if showBack { back } else { front } }
      .frame(width: 340)
      .padding(14)
      .background(.ultraThinMaterial)
      .rotation3DEffect(.degrees(angle), axis: (0, 1, 0), perspective: 0.5)
      .onAppear {
        showBack = false
        angle = 0
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

  // MARK: front

  private var front: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Circle().fill(healthColor).frame(width: 8, height: 8)
        Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        Spacer()
      }
      ScrollView {
        VStack(spacing: 10) {
          ForEach(model.rows) { row in pairRow(row) }
          Button { model.addRow() } label: { Label("Add pair", systemImage: "plus").font(.callout) }
            .buttonStyle(AddPairStyle())
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

  private func pairRow(_ row: PairRow) -> some View {
    HStack(spacing: 8) {
      picker(row, sideA: true)
      Button { model.setDir(row.id, next(row.dir)) } label: {
        Image(systemName: arrow(row.dir)).font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26)
          .background(.background.opacity(0.55), in: Circle())
      }
      .buttonStyle(.plain).help("Direction")
      picker(row, sideA: false)
      Button { model.removeRow(row.id) } label: {
        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).font(.system(size: 14))
      }
      .buttonStyle(.plain).help("Remove pair")
    }
    .padding(10)
    .frame(maxWidth: .infinity)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  /// Arrow points at the calendar that receives the Busy blocks.
  private func arrow(_ d: Direction) -> String {
    switch d {
    case .both: "arrow.left.arrow.right"
    case .forward: "arrow.right"
    case .backward: "arrow.left"
    }
  }

  private func next(_ d: Direction) -> Direction {
    switch d {
    case .both: .forward
    case .forward: .backward
    case .backward: .both
    }
  }

  private func picker(_ row: PairRow, sideA: Bool) -> some View {
    let ref = sideA ? row.a : row.b
    let blocked = model.disabled(row: row, sideA: sideA)
    let missing = model.isMissing(ref)
    return Menu {
      ForEach(model.groups, id: \.source) { group in
        Section(group.source) {
          ForEach(group.cals) { cal in
            Button(cal.title) { model.setCal(row.id, sideA: sideA, cal) }.disabled(blocked.contains(cal.id))
          }
        }
      }
    } label: {
      HStack(spacing: 4) {
        VStack(alignment: .leading, spacing: 1) {
          if let ref {
            Text(missing ? "Missing" : ref.source).font(.caption2).foregroundStyle(missing ? .orange : .secondary)
            Text(ref.title).foregroundStyle(missing ? .orange : .primary)
          } else {
            Text("Pick…").foregroundStyle(.secondary)
          }
        }
        .lineLimit(1).truncationMode(.tail)
        Spacer(minLength: 0)
        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
      }
      .font(.callout)
      .padding(.horizontal, 10).frame(height: 38)
      .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .contentShape(Rectangle())
    }
    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
    .frame(maxWidth: .infinity)
  }

  // MARK: back

  @ViewBuilder private var syncLabel: some View {
    switch model.phase {
    case .idle: Text("Sync now")
    case .syncing: HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Syncing…") }
    case .done: Label("Synced", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
    case .failed: Label("Failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
    case .notReady: Label("Add a pair", systemImage: "info.circle").foregroundStyle(.orange)
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
      Text("Copies events across each pair as untitled Busy blocks, \(windowDaysAhead) days ahead. The arrow points at the calendar that receives them. Nothing syncs until a pair is set.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Text("Icon by [Flat Icons Design](https://www.flaticon.com/free-icons/sync) on Flaticon")
        .font(.caption2).foregroundStyle(.secondary)
      Divider()
      HStack {
        Spacer()
        Button("Quit Dibs") { NSApplication.shared.terminate(nil) }
      }
    }
  }

  /// ScrollView has no intrinsic height in a menu bar window, so size it from the rows, up to a cap.
  private var listHeight: CGFloat { min(300, CGFloat(model.rows.count) * 68 + 40) }

  private var healthColor: Color {
    if model.failures >= 3 { return .red }
    if model.paused || model.activePairs == 0 { return .orange }
    return .green
  }
}

/// Dashed full-width button: the whole area is clickable, with hover and pressed fills.
private struct AddPairStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View { HoverBody(configuration: configuration) }

  private struct HoverBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovering = false

    var body: some View {
      let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
      configuration.label
        .foregroundStyle(hovering ? .primary : .secondary)
        .frame(maxWidth: .infinity).frame(height: 36)
        .background(.quaternary.opacity(configuration.isPressed ? 0.7 : (hovering ? 0.35 : 0)), in: shape)
        .overlay(shape.strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .contentShape(shape)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
  }
}
