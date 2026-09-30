import AppKit
import EventKit
import ServiceManagement
import SwiftUI

enum SyncPhase { case idle, syncing, done, failed, notReady }

@MainActor
final class Model: ObservableObject {
  private let store = Store()
  private let defaults = UserDefaults.standard

  @Published var calendars: [CalInfo] = []
  @Published var selected: Set<String> = []
  @Published var missing: [SelRef] = []
  @Published var status = "Starting…"
  @Published var paused: Bool { didSet { defaults.set(paused, forKey: "paused"); if !paused { requestSync("resume") } } }
  @Published var failures = 0
  @Published var phase: SyncPhase = .idle
  @Published var loginStatus: SMAppService.Status = SMAppService.mainApp.status

  private var refs: [SelRef] = []
  private var hasAccess = false
  private var debounce: Task<Void, Never>?
  private var observer: NSObjectProtocol?

  var iconName: String { failures >= 3 ? "exclamationmark.triangle" : (paused ? "pause.circle" : "calendar") }

  var groups: [(source: String, cals: [CalInfo])] {
    Dictionary(grouping: calendars, by: \.source).map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
  }

  init() {
    paused = defaults.bool(forKey: "paused")
    if let data = defaults.data(forKey: "selection"), let saved = try? JSONDecoder().decode([SelRef].self, from: data) { refs = saved }
    Task { await start() }
  }

  private func start() async {
    hasAccess = await store.requestAccess()
    guard hasAccess else { status = "Calendar access denied — allow it in System Settings"; failures = 3; return }
    resolveSelection()
    observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.requestSync("change", delay: 10) }
    }
    Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in Task { @MainActor in self?.requestSync("hourly") } }
    requestSync("launch", delay: 1)
  }

  /// Match saved refs to live calendars: by id, then by account + title. Unmatched refs are "missing".
  private func resolveSelection() {
    calendars = store.infos()
    var ids = Set<String>(), gone: [SelRef] = [], fixed: [SelRef] = []
    for ref in refs {
      if let c = calendars.first(where: { $0.id == ref.id }) ?? calendars.first(where: { $0.source == ref.source && $0.title == ref.title }) {
        ids.insert(c.id); fixed.append(SelRef(id: c.id, source: c.source, title: c.title))
      } else { gone.append(ref); fixed.append(ref) }
    }
    refs = fixed
    missing = gone
    selected = ids
    persist()
  }

  private func persist() {
    if let data = try? JSONEncoder().encode(refs) { defaults.set(data, forKey: "selection") }
  }

  private var activeIds: Set<String> { selected }
  private var missingIds: Set<String> { Set(missing.map(\.id)) }

  // MARK: selection

  func setSelected(_ id: String, _ on: Bool) {
    guard let cal = calendars.first(where: { $0.id == id }) else { return }
    if !on {
      let next = selected.subtracting([id])
      let snap = store.snapshot(selected: next)
      let plan = planSync(selected: next.union(missingIds), missing: missingIds, sources: snap.sources, copies: snap.copies)
      if plan.orphanDeletes.count > 0 {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Remove \(plan.orphanDeletes.count) blocks?"
        alert.informativeText = "Unticking “\(cal.title)” deletes the Busy blocks it created in your other calendars and the ones inside it."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() != .alertFirstButtonReturn { objectWillChange.send(); return }
      }
      selected = next
      refs.removeAll { $0.id == id }
    } else {
      selected.insert(id)
      refs.append(SelRef(id: id, source: cal.source, title: cal.title))
    }
    persist()
    requestSync("selection")
  }

  // MARK: sync

  func requestSync(_ reason: String, delay: Double = 0) {
    debounce?.cancel()
    debounce = Task { [weak self] in
      if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
      guard !Task.isCancelled else { return }
      self?.sync(reason)
    }
  }

  /// "Sync now": show a spinner, run immediately, then flash the result for a moment.
  func manualSync() {
    guard phase == .idle else { return }
    guard selected.count >= 2 else { flash(.notReady); return }
    phase = .syncing
    Task {
      try? await Task.sleep(nanoseconds: 150_000_000)  // let the spinner draw before the (blocking) sync
      debounce?.cancel()
      let before = failures
      sync("manual")
      try? await Task.sleep(nanoseconds: 600_000_000)  // a run this fast would otherwise look like nothing happened
      flash(failures > before ? .failed : .done)
    }
  }

  private func flash(_ result: SyncPhase) {
    phase = result
    Task {
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      phase = .idle
    }
  }

  /// Runs to completion on the main actor with no awaits, so two syncs can never overlap.
  private func sync(_ reason: String) {
    guard hasAccess else { return }
    calendars = store.infos()
    let ticked = selected.union(missingIds)
    guard selected.count >= 2 else { status = "Tick at least two calendars"; return }
    guard !paused else { status = "Paused"; return }

    let snap = store.snapshot(selected: ticked)
    let plan = planSync(selected: ticked, missing: snap.missing.union(missingIds), sources: snap.sources, copies: snap.copies)
    var errors = 0
    if !plan.isEmpty {
      retireOldScript()
      errors = store.apply(plan)
    }
    failures = errors > 0 ? failures + 1 : 0
    let f = DateFormatter(); f.dateFormat = "HH:mm"
    let changes = plan.isEmpty ? "no changes" : "+\(plan.creates.count) ~\(plan.updates.count) −\(plan.deleteCount)"
    status = "\(errors > 0 ? "Error" : "OK") · \(f.string(from: Date())) · \(selected.count) calendars · \(changes)"
    print("sync(\(reason)): \(status)")
  }

  /// The v1 script must not keep running next to the app, or two writers would fight.
  private func retireOldScript() {
    let fm = FileManager.default
    let plist = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/me.yeco.calsync.plist")
    guard fm.fileExists(atPath: plist.path) else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["bootout", "gui/\(getuid())/me.yeco.calsync"]
    try? p.run(); p.waitUntilExit()
    try? fm.removeItem(at: plist)
    try? fm.removeItem(at: fm.homeDirectoryForCurrentUser.appendingPathComponent(".calsync/state.json"))
  }

  // MARK: launch at login

  var loginOn: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }
  var loginLabel: String { loginStatus == .requiresApproval ? "Launch at login (approve in System Settings)" : "Launch at login" }

  func setLogin(_ on: Bool) {
    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { print("login item: \(error)") }
    loginStatus = SMAppService.mainApp.status
  }
}
