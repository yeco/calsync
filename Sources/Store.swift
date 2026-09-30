import EventKit
import Foundation

struct CalInfo: Identifiable, Hashable {
  let id: String
  let source: String
  let title: String
}

/// How a ticked calendar is remembered: id first, account + title as fallback if the id changed.
struct SelRef: Codable, Hashable {
  var id: String
  var source: String
  var title: String
}

struct Snapshot {
  var sources: [SrcEvent] = []
  var copies: [CopyEvent] = []
  var missing: Set<String> = []
}

let windowDaysBack = 1
let windowDaysAhead = 60

final class Store {
  let es = EKEventStore()

  func requestAccess() async -> Bool {
    (try? await es.requestFullAccessToEvents()) ?? false
  }

  func requestAccessBlocking() -> Bool {
    var ok = false
    let sem = DispatchSemaphore(value: 0)
    es.requestFullAccessToEvents { granted, _ in ok = granted; sem.signal() }
    sem.wait()
    return ok
  }

  func writable() -> [EKCalendar] {
    es.calendars(for: .event).filter { $0.allowsContentModifications }
  }

  func infos() -> [CalInfo] {
    writable().map { CalInfo(id: $0.calendarIdentifier, source: $0.source.title, title: $0.title) }
      .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
  }

  /// Real events worth blocking: not our own copies, timed, not cancelled, not free, not declined.
  private func mirrorable(_ e: EKEvent) -> Bool {
    if e.isAllDay || e.status == .canceled || e.availability == .free { return false }
    if let me = e.attendees?.first(where: { $0.isCurrentUser }), me.participantStatus == .declined { return false }
    return true
  }

  func snapshot(selected: Set<String>) -> Snapshot {
    let cals = writable()
    var snap = Snapshot()
    snap.missing = selected.subtracting(Set(cals.map(\.calendarIdentifier)))
    let cal = Calendar.current
    let from = cal.date(byAdding: .day, value: -windowDaysBack, to: Date())!
    let to = cal.date(byAdding: .day, value: windowDaysAhead, to: Date())!
    for e in es.events(matching: es.predicateForEvents(withStart: from, end: to, calendars: cals)) {
      let calId = e.calendar.calendarIdentifier
      if let notes = e.notes, notes.hasPrefix("calsync:"), let copyId = e.eventIdentifier {
        let line = notes.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? notes
        snap.copies.append(CopyEvent(copyId: copyId, cal: calId, key: line.hasPrefix(markerV2) ? line : nil, start: e.startDate, end: e.endDate))
        continue
      }
      guard selected.contains(calId), mirrorable(e) else { continue }
      snap.sources.append(SrcEvent(id: e.eventIdentifier ?? e.calendarItemIdentifier, cal: calId, start: e.startDate, end: e.endDate))
    }
    return snap
  }

  /// Applies a plan in one batch. Returns how many individual writes failed.
  func apply(_ plan: Plan) -> Int {
    var errors = 0
    let byId = Dictionary(uniqueKeysWithValues: writable().map { ($0.calendarIdentifier, $0) })
    for c in plan.creates {
      guard let target = byId[c.dst] else { errors += 1; continue }
      let e = EKEvent(eventStore: es)
      e.calendar = target
      e.title = "Busy"
      e.notes = c.key
      e.startDate = c.start
      e.endDate = c.end
      e.availability = .busy
      do { try es.save(e, span: .thisEvent, commit: false) } catch { errors += 1 }
    }
    for u in plan.updates {
      guard let e = es.event(withIdentifier: u.copyId) else { continue }
      e.startDate = u.start
      e.endDate = u.end
      do { try es.save(e, span: .thisEvent, commit: false) } catch { errors += 1 }
    }
    for id in plan.staleDeletes + plan.legacyDeletes + plan.orphanDeletes {
      guard let e = es.event(withIdentifier: id) else { continue }
      do { try es.remove(e, span: .thisEvent, commit: false) } catch { errors += 1 }
    }
    do { try es.commit() } catch { errors += 1 }
    return errors
  }
}
