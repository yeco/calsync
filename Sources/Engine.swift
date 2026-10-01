import Foundation

// Pure planning: given what is on the calendars, decide what to create/update/delete.
// No EventKit in here so it can be self-checked (`Dibs --selftest`).

let markerV2 = "calsync:v2|"

struct Span: Hashable {
  let start: Int
  let end: Int
  init(_ s: Date, _ e: Date) { start = Int(s.timeIntervalSince1970); end = Int(e.timeIntervalSince1970) }
}

struct SrcEvent {
  let id: String
  let cal: String
  let start: Date
  let end: Date
}

/// A block we created earlier. `key == nil` means the pre-mesh (v1) format, always removed.
struct CopyEvent {
  let copyId: String
  let cal: String
  let key: String?
  let start: Date
  let end: Date
}

struct Create {
  let dst: String
  let key: String
  let start: Date
  let end: Date
}

struct Update {
  let copyId: String
  let start: Date
  let end: Date
}

struct Plan {
  var creates: [Create] = []
  var updates: [Update] = []
  var staleDeletes: [String] = []   // source gone/moved, duplicates, overlap-rule skips
  var legacyDeletes: [String] = []  // v1 blocks from the old script
  var orphanDeletes: [String] = []  // involve a calendar that is no longer ticked
  var isEmpty: Bool { creates.isEmpty && updates.isEmpty && staleDeletes.isEmpty && legacyDeletes.isEmpty && orphanDeletes.isEmpty }
  var deleteCount: Int { staleDeletes.count + legacyDeletes.count + orphanDeletes.count }
}

func makeKey(src: String, dst: String, eventId: String, start: Date) -> String {
  "\(markerV2)\(src)|\(dst)|\(eventId)|\(Int(start.timeIntervalSince1970))"
}

/// Source calendar id out of a v2 key.
func keySource(_ key: String) -> String? {
  let parts = key.dropFirst(markerV2.count).split(separator: "|", omittingEmptySubsequences: false)
  return parts.count >= 4 ? String(parts[0]) : nil
}

/// One direction of a pair: `src`'s events become Busy blocks in `dst`.
struct Edge: Hashable {
  let src: String
  let dst: String
}

/// - edges: the directed links the user configured. missing: calendar ids that no longer exist (their blocks are left alone).
/// - sources: real, mirrorable events on calendars in any edge. copies: every block we made, on any calendar.
func planSync(edges: Set<Edge>, missing: Set<String>, sources: [SrcEvent], copies: [CopyEvent]) -> Plan {
  var plan = Plan()
  let live = edges.filter { !missing.contains($0.src) && !missing.contains($0.dst) }
  let outgoing = Dictionary(grouping: live, by: \.src).mapValues { $0.map(\.dst).sorted() }

  // What each calendar already has for real, so we don't stack a Busy block on an identical event.
  var occupied: [String: Set<Span>] = [:]
  for s in sources { occupied[s.cal, default: []].insert(Span(s.start, s.end)) }

  var candidates: [Create] = []
  for s in sources {
    for dst in outgoing[s.cal] ?? [] {
      candidates.append(Create(dst: dst, key: makeKey(src: s.cal, dst: dst, eventId: s.id, start: s.start), start: s.start, end: s.end))
    }
  }
  candidates.sort { $0.key < $1.key }  // deterministic winner when two sources collide on one target

  var desired: [String: Create] = [:]
  for c in candidates {
    let span = Span(c.start, c.end)
    if occupied[c.dst, default: []].contains(span) { continue }
    occupied[c.dst, default: []].insert(span)
    desired[c.key] = c
  }

  var existing: [String: [CopyEvent]] = [:]
  for c in copies.sorted(by: { $0.copyId < $1.copyId }) {
    guard let key = c.key, let src = keySource(key) else { plan.legacyDeletes.append(c.copyId); continue }
    if missing.contains(src) || missing.contains(c.cal) { continue }
    if !edges.contains(Edge(src: src, dst: c.cal)) { plan.orphanDeletes.append(c.copyId); continue }
    existing[key, default: []].append(c)
  }

  for key in existing.keys.sorted() {
    let group = existing[key]!
    plan.staleDeletes.append(contentsOf: group.dropFirst().map(\.copyId))
    guard let want = desired[key] else { plan.staleDeletes.append(group[0].copyId); continue }
    if Span(group[0].start, group[0].end) != Span(want.start, want.end) {
      plan.updates.append(Update(copyId: group[0].copyId, start: want.start, end: want.end))
    }
  }
  plan.creates = desired.keys.sorted().filter { existing[$0] == nil }.map { desired[$0]! }
  return plan
}

// MARK: - self-check

func runSelfTest() -> Bool {
  var failures = 0
  func mesh(_ ids: [String]) -> Set<Edge> { Set(ids.flatMap { a in ids.filter { $0 != a }.map { Edge(src: a, dst: $0) } }) }
  func check(_ ok: Bool, _ name: String) { if !ok { failures += 1; print("FAIL:", name) } }
  func d(_ h: Int) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + Double(h) * 3600) }

  /// Apply a plan to a simulated world so we can replan and expect a no-op.
  func apply(_ p: Plan, to copies: inout [CopyEvent], counter: inout Int) {
    let dead = Set(p.staleDeletes + p.legacyDeletes + p.orphanDeletes)
    copies.removeAll { dead.contains($0.copyId) }
    for u in p.updates { if let i = copies.firstIndex(where: { $0.copyId == u.copyId }) { copies[i] = CopyEvent(copyId: u.copyId, cal: copies[i].cal, key: copies[i].key, start: u.start, end: u.end) } }
    for c in p.creates { counter += 1; copies.append(CopyEvent(copyId: "c\(counter)", cal: c.dst, key: c.key, start: c.start, end: c.end)) }
  }

  var n = 0
  var copies: [CopyEvent] = []

  // 1. two calendars: mirrored both ways, then a second pass is a no-op
  var src = [SrcEvent(id: "e1", cal: "A", start: d(1), end: d(2)), SrcEvent(id: "e2", cal: "B", start: d(5), end: d(6))]
  var p = planSync(edges: mesh(["A", "B"]), missing: [], sources: src, copies: copies)
  check(p.creates.count == 2 && p.deleteCount == 0, "two-way creates")
  apply(p, to: &copies, counter: &n)
  check(planSync(edges: mesh(["A", "B"]), missing: [], sources: src, copies: copies).isEmpty, "second run is a no-op")

  // 2. same meeting on A and B in a three-way mesh: C gets one block, A and B get none
  copies = []; n = 0
  src = [SrcEvent(id: "x", cal: "A", start: d(1), end: d(2)), SrcEvent(id: "y", cal: "B", start: d(1), end: d(2))]
  p = planSync(edges: mesh(["A", "B", "C"]), missing: [], sources: src, copies: copies)
  check(p.creates.count == 1 && p.creates[0].dst == "C", "overlap: one block on C only")
  apply(p, to: &copies, counter: &n)
  check(planSync(edges: mesh(["A", "B", "C"]), missing: [], sources: src, copies: copies).isEmpty, "overlap plan is stable")

  // 3. determinism
  let p1 = planSync(edges: mesh(["A", "B", "C"]), missing: [], sources: src, copies: [])
  let p2 = planSync(edges: mesh(["A", "B", "C"]), missing: [], sources: src.reversed(), copies: [])
  check(p1.creates.map(\.key) == p2.creates.map(\.key), "deterministic regardless of input order")

  // 4. moved source updates, then no-op; removed source deletes
  copies = []; n = 0
  src = [SrcEvent(id: "e1", cal: "A", start: d(1), end: d(2))]
  apply(planSync(edges: mesh(["A", "B"]), missing: [], sources: src, copies: copies), to: &copies, counter: &n)
  src = [SrcEvent(id: "e1", cal: "A", start: d(1), end: d(3))]
  p = planSync(edges: mesh(["A", "B"]), missing: [], sources: src, copies: copies)
  // a moved end keeps the key (same start), so it must be an update, not delete+create
  check(p.updates.count == 1 && p.creates.isEmpty && p.deleteCount == 0, "moved end updates in place")
  apply(p, to: &copies, counter: &n)
  p = planSync(edges: mesh(["A", "B"]), missing: [], sources: [], copies: copies)
  check(p.staleDeletes.count == 1, "removed source deletes its copy")

  // 5. missing calendar: nothing created for it, nothing of its deleted
  copies = []; n = 0
  src = [SrcEvent(id: "e1", cal: "A", start: d(1), end: d(2)), SrcEvent(id: "e2", cal: "B", start: d(4), end: d(5))]
  apply(planSync(edges: mesh(["A", "B"]), missing: [], sources: src, copies: copies), to: &copies, counter: &n)
  p = planSync(edges: mesh(["A", "B"]), missing: ["B"], sources: [SrcEvent(id: "e1", cal: "A", start: d(1), end: d(2))], copies: copies)
  check(p.deleteCount == 0 && p.creates.isEmpty, "missing calendar deletes nothing")

  // 6. unticking C removes blocks it made elsewhere and blocks inside it
  copies = []; n = 0
  src = [SrcEvent(id: "a", cal: "A", start: d(1), end: d(2)), SrcEvent(id: "c", cal: "C", start: d(7), end: d(8))]
  apply(planSync(edges: mesh(["A", "B", "C"]), missing: [], sources: src, copies: copies), to: &copies, counter: &n)
  p = planSync(edges: mesh(["A", "B"]), missing: [], sources: [SrcEvent(id: "a", cal: "A", start: d(1), end: d(2))], copies: copies)
  check(p.orphanDeletes.count == 3, "untick removes 3 orphans (A->C, plus C's block on A and B)")
  apply(p, to: &copies, counter: &n)
  check(planSync(edges: mesh(["A", "B"]), missing: [], sources: [SrcEvent(id: "a", cal: "A", start: d(1), end: d(2))], copies: copies).isEmpty, "after untick cleanup, no-op")

  // 7. legacy v1 blocks and duplicates of one key
  copies = [CopyEvent(copyId: "old", cal: "A", key: nil, start: d(1), end: d(2))]
  p = planSync(edges: mesh(["A", "B"]), missing: [], sources: [], copies: copies)
  check(p.legacyDeletes == ["old"], "legacy blocks deleted")
  let k = makeKey(src: "A", dst: "B", eventId: "e", start: d(1))
  copies = [CopyEvent(copyId: "z1", cal: "B", key: k, start: d(1), end: d(2)), CopyEvent(copyId: "z2", cal: "B", key: k, start: d(1), end: d(2))]
  p = planSync(edges: mesh(["A", "B"]), missing: [], sources: [SrcEvent(id: "e", cal: "A", start: d(1), end: d(2))], copies: copies)
  check(p.staleDeletes == ["z2"] && p.creates.isEmpty, "duplicate copies collapse to one")

  // 8. one-way pair: only A's events go to B; flipping the direction removes the old blocks and mirrors the other way
  copies = []; n = 0
  src = [SrcEvent(id: "a", cal: "A", start: d(1), end: d(2)), SrcEvent(id: "b", cal: "B", start: d(5), end: d(6))]
  let aToB: Set<Edge> = [Edge(src: "A", dst: "B")]
  p = planSync(edges: aToB, missing: [], sources: src, copies: copies)
  check(p.creates.count == 1 && p.creates[0].dst == "B", "A->B creates only on B")
  apply(p, to: &copies, counter: &n)
  p = planSync(edges: [Edge(src: "B", dst: "A")], missing: [], sources: src, copies: copies)
  check(p.orphanDeletes.count == 1 && p.creates.count == 1 && p.creates[0].dst == "A", "flip A->B to B->A: orphan removed, new block on A")
  p = planSync(edges: aToB, missing: [], sources: src, copies: copies)
  check(p.isEmpty, "A->B stable")

  // 9. blocks never chain: A->B and B->C give C only B's real events
  p = planSync(edges: [Edge(src: "A", dst: "B"), Edge(src: "B", dst: "C")], missing: [], sources: [SrcEvent(id: "a", cal: "A", start: d(1), end: d(2))], copies: [])
  check(p.creates.count == 1 && p.creates[0].dst == "B", "no chaining")

  print(failures == 0 ? "selftest OK" : "selftest FAILED (\(failures))")
  return failures == 0
}
