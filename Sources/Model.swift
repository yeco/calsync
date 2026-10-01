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
  @Published var rows: [PairRow] = []
  @Published var status = "Starting…"
  @Published var paused: Bool { didSet { defaults.set(paused, forKey: "paused"); if !paused { requestSync("resume") } } }
  @Published var failures = 0
  @Published var phase: SyncPhase = .idle
  @Published var loginStatus: SMAppService.Status = SMAppService.mainApp.status

  private var hasAccess = false
  private var debounce: Task<Void, Never>?
  private var observer: NSObjectProtocol?

  var iconName: String { failures >= 3 ? "exclamationmark.triangle" : (paused ? "pause.circle" : "calendar") }

  var groups: [(source: String, cals: [CalInfo])] {
    Dictionary(grouping: calendars, by: \.source).map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
  }

  /// Directed links from the complete rows.
  private func edges(_ rows: [PairRow]) -> Set<Edge> {
    var out = Set<Edge>()
    for r in rows {
      guard let a = r.a?.id, let b = r.b?.id else { continue }
      if r.dir != .backward { out.insert(Edge(src: a, dst: b)) }
      if r.dir != .forward { out.insert(Edge(src: b, dst: a)) }
    }
    return out
  }

  private func endpoints(_ rows: [PairRow]) -> Set<String> {
    Set(rows.flatMap { [$0.a?.id, $0.b?.id].compactMap { $0 } })
  }

  var activePairs: Int { rows.filter { $0.a != nil && $0.b != nil }.count }

  func isMissing(_ ref: SelRef?) -> Bool {
    guard let ref else { return false }
    return hasAccess && !calendars.contains { $0.id == ref.id }
  }

  init() {
    paused = defaults.bool(forKey: "paused")
    rows = loadRows()
    Task { await start() }
  }

  /// Saved pairs; first launch after the pairs upgrade turns the old ticked list into all-pairs two-way rows.
  private func loadRows() -> [PairRow] {
    if let data = defaults.data(forKey: "pairs"), let saved = try? JSONDecoder().decode([PairRow].self, from: data) { return saved }
    guard let data = defaults.data(forKey: "selection"), let old = try? JSONDecoder().decode([SelRef].self, from: data) else { return [] }
    let migrated = old.indices.flatMap { i in old.indices.filter { $0 > i }.map { PairRow(a: old[i], b: old[$0], dir: .both) } }
    if let data = try? JSONEncoder().encode(migrated) { defaults.set(data, forKey: "pairs") }
    return migrated
  }

  private func start() async {
    hasAccess = await store.requestAccess()
    guard hasAccess else { status = "Calendar access denied — allow it in System Settings"; failures = 3; return }
    resolveRows()
    observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.requestSync("change", delay: 10) }
    }
    Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in Task { @MainActor in self?.requestSync("hourly") } }
    requestSync("launch", delay: 1)
  }

  /// Match saved refs to live calendars: by id, then by account + title. Unmatched refs stay as they are and show as missing.
  private func resolveRows() {
    calendars = store.infos()
    func fix(_ ref: SelRef?) -> SelRef? {
      guard let ref else { return nil }
      guard let c = calendars.first(where: { $0.id == ref.id }) ?? calendars.first(where: { $0.source == ref.source && $0.title == ref.title }) else { return ref }
      return SelRef(id: c.id, source: c.source, title: c.title)
    }
    rows = rows.map { PairRow(id: $0.id, a: fix($0.a), b: fix($0.b), dir: $0.dir) }
    persist()
  }

  /// Incomplete rows are not saved: a half-filled row is gone after a relaunch.
  private func persist() {
    let complete = rows.filter { $0.a != nil && $0.b != nil }
    if let data = try? JSONEncoder().encode(complete) { defaults.set(data, forKey: "pairs") }
  }

  // MARK: pairs

  func addRow() { rows.append(PairRow(a: nil, b: nil, dir: .both)) }

  func removeRow(_ id: UUID) { commit(rows.filter { $0.id != id }) }

  func setDir(_ id: UUID, _ dir: Direction) { commit(rows.map { $0.id == id ? PairRow(id: id, a: $0.a, b: $0.b, dir: dir) : $0 }) }

  func setCal(_ id: UUID, sideA: Bool, _ cal: CalInfo) {
    let ref = SelRef(id: cal.id, source: cal.source, title: cal.title)
    commit(rows.map { r in
      guard r.id == id else { return r }
      return PairRow(id: id, a: sideA ? ref : r.a, b: sideA ? r.b : ref, dir: r.dir)
    })
  }

  /// Calendars a dropdown must not offer: the other side, and anything already paired with it in another row.
  func disabled(row: PairRow, sideA: Bool) -> Set<String> {
    guard let other = sideA ? row.b?.id : row.a?.id else { return [] }
    var ids: Set<String> = [other]
    for r in rows where r.id != row.id {
      if r.a?.id == other, let x = r.b?.id { ids.insert(x) }
      if r.b?.id == other, let x = r.a?.id { ids.insert(x) }
    }
    return ids
  }

  /// Apply a new row list. If it orphans Busy blocks, ask first; Cancel leaves everything as it was.
  private func commit(_ next: [PairRow]) {
    let snap = store.snapshot(selected: endpoints(next))
    let plan = planSync(edges: edges(next), missing: snap.missing, sources: snap.sources, copies: snap.copies)
    if plan.orphanDeletes.count > 0 {
      NSApp.activate(ignoringOtherApps: true)
      let alert = NSAlert()
      alert.messageText = "Remove \(plan.orphanDeletes.count) blocks?"
      alert.informativeText = "This change deletes the Busy blocks that the removed link created."
      alert.addButton(withTitle: "Remove")
      alert.addButton(withTitle: "Cancel")
      if alert.runModal() != .alertFirstButtonReturn { objectWillChange.send(); return }
    }
    rows = next
    persist()
    requestSync("pairs")
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
    guard activePairs > 0 else { flash(.notReady); return }
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
    guard activePairs > 0 else { status = "Add a calendar pair"; return }
    guard !paused else { status = "Paused"; return }

    let snap = store.snapshot(selected: endpoints(rows))
    let plan = planSync(edges: edges(rows), missing: snap.missing, sources: snap.sources, copies: snap.copies)
    var errors = 0
    if !plan.isEmpty {
      retireOldScript()
      errors = store.apply(plan)
    }
    failures = errors > 0 ? failures + 1 : 0
    let f = DateFormatter(); f.dateFormat = "HH:mm"
    let changes = plan.isEmpty ? "no changes" : "+\(plan.creates.count) ~\(plan.updates.count) −\(plan.deleteCount)"
    status = "\(errors > 0 ? "Error" : "OK") · \(f.string(from: Date())) · \(activePairs) pairs · \(changes)"
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
