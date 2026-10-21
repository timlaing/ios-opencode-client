import Foundation
import OpenCodeStorage

/// W17 draft persistence (docs/implementation-defaults.md I1 and
/// "Drafts"): the composer's durable text behind one value, so
/// restore/save/clear/expiry rules are testable without the view. A
/// plain value over an injected `DraftStore` — the conversation opens
/// its handle over the app-private drafts database.
///
/// Attachment BYTES never ride along: the tray's staged references
/// stay the attachment pipeline's own concern (I1/I7), and the draft
/// record holds text only.
///
/// Main-actor isolated: the retention rules live in `SettingsLibrary`,
/// which is main-actor state, and every caller (composer, shell sweep,
/// tests) already runs there.
@MainActor
struct ComposerDraftStore {
    let drafts: DraftStore

    /// The durable id for one conversation's draft — stable across
    /// saves so an edit replaces rather than stacks, and unique per
    /// host+session even when server IDs collide across hosts.
    static func draftID(hostUUID: String, sessionID: String) -> String {
        "\(hostUUID)/\(sessionID)"
    }

    /// What a restore found: the text plus WHEN IT WAS LAST EDITED —
    /// the composer shows the retention expiry beside restored text
    /// ("show expiry date when enabled", follow-on 4a), and the
    /// caption derives that date from the live setting, so it never
    /// pins one at restore time.
    struct RestoredDraft: Equatable {
        let text: String
        let lastEdit: Date
    }

    /// The persisted text for this conversation, or nil when there is
    /// none or it has EXPIRED under the current retention — an
    /// expired record is removed on sight: expiry is a fact, not a
    /// cleanup pass.
    func restore(
        hostUUID: String,
        sessionID: String,
        settings: SettingsLibrary,
        now: Date = Date()
    ) -> RestoredDraft? {
        let id = Self.draftID(hostUUID: hostUUID, sessionID: sessionID)
        guard let draft = try? drafts.draft(id: id) else { return nil }
        if let expiry = settings.draftExpiry(lastEdit: draft.updatedAt), expiry <= now {
            try? drafts.deleteDraft(id: id)
            return nil
        }
        return draft.text.isEmpty ? nil : RestoredDraft(text: draft.text, lastEdit: draft.updatedAt)
    }

    /// One debounced save from the composer. Empty text means the
    /// draft is gone — sent or discarded — so the record is deleted,
    /// never kept as an empty husk. Text is stored exactly as typed.
    func save(_ text: String, hostUUID: String, sessionID: String) {
        let id = Self.draftID(hostUUID: hostUUID, sessionID: sessionID)
        guard !text.isEmpty else {
            try? drafts.deleteDraft(id: id)
            return
        }
        try? drafts.upsert(
            Draft(id: id, hostUUID: hostUUID, sessionID: sessionID, text: text)
        )
    }

    /// The retention sweep: with a limited retention active, drafts
    /// last edited before the cutoff die across every scope.
    /// Until-discarded (the default) sweeps nothing.
    func applyRetention(_ settings: SettingsLibrary, now: Date = Date()) {
        switch settings.state.draftRetention {
        case .untilDiscarded:
            return
        case .days(let days):
            try? drafts.deleteDrafts(olderThan: now.addingTimeInterval(-Double(days) * 86_400))
        }
    }
}
