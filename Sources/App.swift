import EventKit
import SwiftUI

@main
struct CalSyncApp: App {
  @StateObject private var model = Model()

  init() { runCommandLineModes() }

  var body: some Scene {
    MenuBarExtra {
      PopoverView(model: model)
    } label: {
      Image(systemName: model.iconName)
    }
    .menuBarExtraStyle(.window)
  }
}

/// `--selftest` checks the planner; `--dry-run [--select "Account/Calendar,…"]` prints the plan for real calendars, writes nothing.
func runCommandLineModes() {
  let args = CommandLine.arguments
  if args.contains("--selftest") { exit(runSelfTest() ? 0 : 1) }
  guard args.contains("--dry-run") else { return }

  let store = Store()
  guard store.requestAccessBlocking() else { print("no calendar access"); exit(1) }
  var wanted: [String] = []
  if let i = args.firstIndex(of: "--select"), i + 1 < args.count { wanted = args[i + 1].split(separator: ",").map(String.init) }
  let ids = store.infos().filter { wanted.contains("\($0.source)/\($0.title)") }.map(\.id)
  print("selected \(ids.count)/\(wanted.count): \(wanted)")
  let snap = store.snapshot(selected: Set(ids))
  let plan = planSync(selected: Set(ids), missing: snap.missing, sources: snap.sources, copies: snap.copies)
  print("sources=\(snap.sources.count) copies=\(snap.copies.count)")
  print("creates=\(plan.creates.count) updates=\(plan.updates.count) stale=\(plan.staleDeletes.count) legacy=\(plan.legacyDeletes.count) orphan=\(plan.orphanDeletes.count)")
  exit(0)
}
