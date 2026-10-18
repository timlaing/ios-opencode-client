import SwiftUI
import OpenCodeDomain
import OpenCodeTransport

/// S12 question/form detail (W10, docs/navigation-screens.md S08/S12):
/// the full title, every defined field in host order, and the
/// validation/visibility rules the schema declares. Fields render by
/// kind — text (options constrain to a picker; `custom` adds typed
/// input), numbers, toggles, independently selectable multiselect
/// rows, and external links that open the SYSTEM browser (never an
/// answer). Conditions (`when`) update visibility live, and inactive
/// fields are omitted from the answer entirely — never submitted with
/// stale values. Validation errors sit beside the field plus an
/// accessible summary; the host's rejected-answer message (400) is
/// shown the same way and the draft is RETAINED. Submission and cancel
/// buttons are disabled while one is submitting. A settled form is
/// never editable: opened onto one, or after a 409 re-read, the
/// buttons are replaced by the host's authoritative state and a
/// Return to Chat action — and a reply that raced a settlement says
/// so explicitly: nothing was submitted. Several pending forms count
/// in the header; settling one advances to the next in place.
struct FormSheetView: View {
    let host: OpenCodeDomain.Host
    /// The conversation's live forms — passed INTO the sheet's
    /// closure: state on the presenting view does not reach a sheet.
    let forms: FormLibrary

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// The single-form detail (with `state`) the sheet renders.
    @State private var detail: FormDetail?
    @State private var loadError: String?
    @State private var isLoading = true
    /// The editing state, rebuilt whenever a fresh detail loads.
    @State private var draft = FormDraft(fields: [])
    /// Per-field local validation errors, cleared on the next edit.
    @State private var validationErrors: [String: FormDraft.FieldError] = [:]
    /// The host's rejection message (400) or transport failure — kept
    /// until the next submit attempt; the draft is never discarded.
    @State private var submitError: String?
    @State private var submitting = false
    /// Free-text buffer for `custom` multiselect additions, per key.
    @State private var customText: [String: String] = [:]
    /// Frozen terminal presentation — once set, nothing reloads over it.
    @State private var settledNote: SettledNote?
    /// The form this sheet is PINNED to — adopted from the dock head
    /// once, then advanced only by `advanceAfterSettle()`. The watch
    /// and refreshes may insert or reorder dock entries while the
    /// sheet is open; they must never re-target an edit in progress
    /// (a `.task` keyed to a shifting queue head would replace the
    /// draft, and the submit guard would silently no-op).
    @State private var presented: FormLibrary.Entry?

    /// The terminal presentation: exact title + body, sourced from the
    /// host's authoritative state whenever it was readable, and honest
    /// about whether the user's input was submitted (never a false
    /// local success — docs/api-contract.md W09/W10).
    struct SettledNote: Equatable {
        var title: String
        var body: String
    }

    private enum Scene: Equatable {
        case loading
        case editing(FormDetail)
        case settled(SettledNote)
        case unavailable(String)
        case empty
    }

    private var scene: Scene {
        if let settledNote { return .settled(settledNote) }
        if let detail {
            switch detail.state {
            case .pending:
                return .editing(detail)
            case .answered:
                return .settled(Self.answeredNote(submitted: false))
            case .cancelled(let message):
                return .settled(Self.cancelledNote(message, submitted: false))
            case .unknown:
                return .settled(SettledNote(
                    title: "No Longer Pending",
                    body: "This question's state changed on the host — it is no longer editable."
                ))
            }
        }
        if let loadError { return .unavailable(loadError) }
        if isLoading { return .loading }
        return .empty
    }

    var body: some View {
        NavigationStack {
            Group {
                switch scene {
                case .loading:
                    ProgressView("Loading Question…")
                case .editing(let detail):
                    editor(for: detail)
                case .settled(let note):
                    settledView(note)
                case .unavailable(let message):
                    unavailableView(message)
                case .empty:
                    emptyView
                }
            }
            .navigationTitle("Question")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // Reload whenever the PINNED question changes (settling advances
        // to the next question in place) — but never over a frozen
        // terminal presentation. Keyed to `presented`, not the dock
        // head: entries inserted or reordered by the watch while the
        // sheet is open must not re-target an edit in progress.
        .task(id: presented?.id) {
            await loadDetail()
        }
        .onChange(of: draft) { _, _ in
            // Editing invalidates stale local validation feedback; the
            // host's message (submitError) stays until the next attempt.
            if !validationErrors.isEmpty { validationErrors = [:] }
        }
    }

    // MARK: - Scenes

    private func editor(for detail: FormDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if forms.pendingCount > 1 {
                    Label("\(forms.pendingCount) waiting", systemImage: "list.bullet.rectangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let entry = presented, entry.isLinked {
                    // Linked entry: the actual owner session ID stays
                    // visible — this question belongs to that session.
                    Label("Child session \(entry.ownerSessionID)",
                          systemImage: "arrow.turn.down.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Full title first — then every field in host order.
                Text(detail.title)
                    .font(.title3.weight(.semibold))
                if let metadataDescription = metadataDescription {
                    Text(metadataDescription)
                }

                // Validation summary beside the fields, accessible.
                if !validationErrors.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Check your answers")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.red)
                        ForEach(validationErrors.keys.sorted(), id: \.self) { key in
                            Text("\(draft.title(for: key)): \(validationErrors[key]?.message ?? "")")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("S12.form.errors")
                }
                if let submitError {
                    Text(submitError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("S12.form.error")
                }

                ForEach(Array(detail.fields.enumerated()), id: \.offset) { _, field in
                    if draft.isActive(field) {
                        fieldEditor(field)
                    }
                }

                if let refreshError = forms.refreshError {
                    Text(refreshError)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                VStack(spacing: 10) {
                    Button {
                        submit(entryID: detail.id)
                    } label: {
                        if submitting { ProgressView() } else { Text("Submit") }
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .disabled(submitting)
                    .accessibilityIdentifier("S12.form.submit")

                    Button(role: .destructive) {
                        cancel()
                    } label: {
                        Text("Cancel Question")
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .disabled(submitting)
                    .accessibilityIdentifier("S12.form.cancel")
                }
            }
            .padding()
        }
    }

    /// A question's `description` metadata rides as body text when the
    /// host sends it as a plain string.
    private var metadataDescription: String? {
        guard case .string(let text)? = detail?.metadata?["description"] else { return nil }
        return text
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "No Pending Questions",
                systemImage: "questionmark.circle",
                description: Text("This session has no open questions right now.")
            )
            Button("Return to Chat") { dismiss() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("S12.form.return")
        }
        .padding()
    }

    private func unavailableView(_ message: String) -> some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "Question Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            Button("Try Again") {
                Task { await loadDetail() }
            }
            .accessibilityIdentifier("S12.form.retry")
            Button("Return to Chat") { dismiss() }
                .accessibilityIdentifier("S12.form.return")
        }
        .padding()
    }

    private func settledView(_ note: SettledNote) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(note.title)
                .font(.headline)
            Text(note.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Button("Return to Chat") { dismiss() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("S12.form.return")
        }
        .padding()
    }

    // MARK: - Field editors

    @ViewBuilder
    private func fieldEditor(_ field: FormField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch field {
            case .string(let f):
                Text(f.title ?? f.key)
                    .font(.subheadline.weight(.semibold))
                if let description = f.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let constraints = FormDraft.constraints(for: field) {
                    Text(constraints)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let options = f.options, !options.isEmpty, f.custom != true {
                    // Constrained choice: the options ARE the answer —
                    // a picker, never free typing.
                    Picker(selection: textBinding(f.key)) {
                        Text("Not set").tag("")
                        ForEach(options, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    } label: { EmptyView() }
                        .labelsHidden()
                        .pickerStyle(.menu)
                } else if f.options != nil {
                    // Options + custom: type freely, or tap an option
                    // to fill the field — the last interaction wins.
                    TextField(f.placeholder ?? (f.title ?? f.key), text: textBinding(f.key))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(f.options ?? [], id: \.value) { option in
                                Button(option.label) {
                                    draft.setText(f.key, option.value)
                                }
                                .buttonStyle(.bordered)
                                .font(.caption)
                            }
                        }
                    }
                } else {
                    TextField(f.placeholder ?? (f.title ?? f.key), text: textBinding(f.key))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }

            case .number(let f):
                numericEditor(field, title: f.title ?? f.key, description: f.description)
            case .integer(let f):
                numericEditor(field, title: f.title ?? f.key, description: f.description)

            case .boolean(let f):
                Text(f.title ?? f.key)
                    .font(.subheadline.weight(.semibold))
                if let description = f.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if f.required == true {
                    // A required boolean without a host default must be
                    // chosen explicitly — “Not set” has no answer.
                    Picker(selection: toggleBinding(f.key)) {
                        Text("Not set").tag(FormDraft.Toggle.unset)
                        Text("Yes").tag(FormDraft.Toggle.on)
                        Text("No").tag(FormDraft.Toggle.off)
                    } label: { EmptyView() }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                } else {
                    Toggle(isOn: boolBinding(f.key)) {
                        Text(f.title ?? f.key)
                    }
                    .labelsHidden()
                }

            case .multiselect(let f):
                Text(f.title ?? f.key)
                    .font(.subheadline.weight(.semibold))
                if let description = f.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let constraints = FormDraft.constraints(for: field) {
                    Text(constraints)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // Independently selectable rows — no group container
                // that would force a single choice.
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(f.options, id: \.value) { option in
                        Button {
                            draft.toggle(f.key, option.value)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: draft.picks[f.key]?.contains(option.value) == true
                                      ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(option.label)
                                    if let description = option.description {
                                        Text(description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("S12.form.option.\(f.key).\(option.value)")
                    }
                }
                if f.custom == true {
                    HStack(spacing: 8) {
                        TextField("Add your own value", text: customBinding(f.key))
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                        Button("Add") {
                            draft.addCustom(f.key, customText[f.key] ?? "")
                            customText[f.key] = ""
                        }
                        .disabled((customText[f.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

            case .external(let f):
                // The system browser answers this — the client never
                // claims native handling (docs/navigation-screens.md
                // S09 rule carried into S12), and only the web does:
                // a non-http(s) scheme (javascript:, file:, a custom
                // app scheme) never reaches openURL.
                Button {
                    if let url = Self.browserURL(f.url) { openURL(url) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "safari")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.title ?? f.key)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            if let description = f.description {
                                Text(description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(f.url)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(Self.browserURL(f.url) == nil)
                .accessibilityIdentifier("S12.form.external.\(f.key)")

            case .unknown(let type, _):
                // Honest unsupported row — never dropped, never guessed.
                HStack(spacing: 10) {
                    Image(systemName: "questionmark.square.dashed")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(field.title ?? field.key)
                            .font(.subheadline)
                        Text("This field type (\(type)) is not supported by the app yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }

            if let error = validationErrors[field.key] {
                Text(error.message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("S12.form.error.\(field.key)")
            }
        }
    }

    /// Number/integer fields share one layout (title, description,
    /// schema constraints, typed-value buffer).
    private func numericEditor(
        _ field: FormField, title: String, description: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            if let description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let constraints = FormDraft.constraints(for: field) {
                Text(constraints)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("Value", text: numberBinding(field.key))
                .textFieldStyle(.roundedBorder)
                .keyboardType(.decimalPad)
        }
    }

    // MARK: - Bindings

    private func textBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { draft.texts[key] ?? "" },
            set: { draft.setText(key, $0) }
        )
    }

    private func numberBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { draft.numbers[key] ?? "" },
            set: { draft.setNumber(key, $0) }
        )
    }

    private func toggleBinding(_ key: String) -> Binding<FormDraft.Toggle> {
        Binding(
            get: { draft.bools[key] ?? .unset },
            set: { draft.setBoolean(key, $0) }
        )
    }

    /// The plain switch for an optional boolean: reads OFF for an
    /// untouched default-off field and always writes a definite value
    /// (an optional toggle never has “unset”).
    private func boolBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { draft.bools[key] == .on },
            set: { draft.setBoolean(key, $0 ? .on : .off) }
        )
    }

    private func customBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { customText[key] ?? "" },
            set: { customText[key] = $0 }
        )
    }

    // MARK: - Loading

    private func loadDetail() async {
        // A frozen terminal presentation never reloads underneath the
        // user, and a cancelled reload publishes nothing.
        guard settledNote == nil else { return }
        // Adopt the dock head ONCE; from then on only
        // `advanceAfterSettle()` re-targets the sheet. If the queue was
        // empty on arrival there is nothing to ask — finish loading so
        // the scene resolves to `empty` instead of spinning.
        if presented == nil { presented = forms.entries.first }
        guard let entry = presented else {
            isLoading = false
            return
        }
        isLoading = true
        loadError = nil
        let outcome = await forms.detail(
            host: host, sessionID: entry.ownerSessionID, formID: entry.id
        )
        // The PINNED id must match — the dock may have reordered around
        // an edit this load never belonged to.
        guard !Task.isCancelled, settledNote == nil,
              presented?.id == entry.id else { return }
        switch outcome {
        case .loaded(let fresh):
            detail = fresh
            draft = FormDraft(fields: fresh.fields)
            customText = [:]
            validationErrors = [:]
            submitError = nil
        case .gone:
            // Docked as pending but gone by the time the sheet read it:
            // settle the dock entry and say so.
            settledNote = SettledNote(
                title: "No Longer Pending",
                body: "This question is no longer pending — it was already handled or withdrawn."
            )
            forms.settleGone(entry.id)
        case .unavailable(let message):
            detail = nil
            loadError = message
        }
        isLoading = false
    }

    // MARK: - Actions

    private func submit(entryID: String) {
        guard !submitting else { return }
        // The pinned question is the one being edited — if it is gone
        // (or the caller names another), say so honestly instead of
        // silently swallowing the tap.
        guard let entry = presented, entry.id == entryID else {
            settledNote = SettledNote(
                title: "No Longer Pending",
                body: "This question is no longer pending — your answer was not submitted."
            )
            return
        }
        // Local validation first — the host stays authoritative for
        // everything the client cannot check.
        let errors = draft.validate()
        guard errors.isEmpty else {
            validationErrors = errors
            return
        }
        submitting = true
        submitError = nil
        validationErrors = [:]
        let answer = draft.answer()
        Task {
            let outcome = await forms.submit(entry, answer: answer, host: host)
            submitting = false
            switch outcome {
            case .accepted:
                advanceAfterSettle()
            case .alreadySettled:
                // Freeze FIRST (synchronously, before the next render
                // sees the shrunken queue), then refine from the host's
                // own state — the 409 is authoritative either way.
                settledNote = SettledNote(
                    title: "Already Settled",
                    body: "Your answer was not submitted — this question was already answered or cancelled."
                )
                await refineSettledNote(entry)
            case .gone:
                settledNote = SettledNote(
                    title: "No Longer Pending",
                    body: "Your answer was not submitted — this question is no longer pending."
                )
            case .failed(let reason):
                // Rejected answer (400) or transport failure: the draft
                // is intact — fix and retry in place.
                submitError = reason
            }
        }
    }

    private func cancel() {
        guard !submitting else { return }
        guard let entry = presented else {
            settledNote = SettledNote(
                title: "No Longer Pending",
                body: "This question is no longer pending."
            )
            return
        }
        submitting = true
        submitError = nil
        Task {
            let outcome = await forms.cancel(entry, message: nil, host: host)
            submitting = false
            switch outcome {
            case .accepted:
                advanceAfterSettle()
            case .alreadySettled:
                settledNote = SettledNote(
                    title: "Already Settled",
                    body: "This question was already answered or cancelled."
                )
            case .gone:
                settledNote = SettledNote(
                    title: "No Longer Pending",
                    body: "This question is no longer pending."
                )
            case .failed(let reason):
                submitError = reason
            }
        }
    }

    /// After a settled reply/cancel: back to the chat when the dock is
    /// empty; otherwise the next question loads in place (its id change
    /// re-runs the load task — with the fresh, empty draft).
    private func advanceAfterSettle() {
        if forms.entries.isEmpty {
            dismiss()
        } else {
            // Re-pin to the new head (the settled entry has left the
            // dock) and rebuild every per-form state together — the id
            // change re-runs the load task with a fresh, empty draft.
            // Loading is claimed SYNCHRONOUSLY: with detail cleared the
            // scene would otherwise resolve to `empty` (a bogus "No
            // Pending Questions" flash) in the gap before the re-keyed
            // task gets scheduled.
            presented = forms.entries.first
            detail = nil
            loadError = nil
            isLoading = true
            draft = FormDraft(fields: [])
            customText = [:]
            validationErrors = [:]
            submitError = nil
            settledNote = nil
        }
    }

    /// The 409 re-read: refine the frozen note with the host's exact
    /// state when it is readable; the generic note stands otherwise.
    private func refineSettledNote(_ entry: FormLibrary.Entry) async {
        let outcome = await forms.detail(
            host: host, sessionID: entry.ownerSessionID, formID: entry.id
        )
        guard !Task.isCancelled else { return }
        switch outcome {
        case .loaded(let fresh):
            switch fresh.state {
            case .answered:
                settledNote = Self.answeredNote(submitted: false)
            case .cancelled(let message):
                settledNote = Self.cancelledNote(message, submitted: false)
            case .pending, .unknown:
                break // the 409 itself is authoritative — keep the generic note
            }
        case .gone, .unavailable:
            break
        }
    }

    /// A URL the sheet will actually open: parseable AND web-only.
    /// `URL(string:)` happily accepts `javascript:`, `file:`, or a
    /// custom app scheme, and the system would hand those straight to
    /// `openURL` — external fields must reach the browser over
    /// http(s) or not at all (button action AND its disabled state,
    /// so the two can never disagree).
    private static func browserURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    private static func answeredNote(submitted: Bool) -> SettledNote {
        SettledNote(
            title: "Answered",
            body: submitted
                ? "Your answer was submitted."
                : "This question was already answered — it is no longer editable, and nothing was submitted by this reply."
        )
    }

    private static func cancelledNote(_ message: String?, submitted: Bool) -> SettledNote {
        SettledNote(
            title: "Cancelled",
            body: (submitted
                   ? "This question was cancelled."
                   : "This question was cancelled elsewhere — nothing was submitted by this reply.")
                + (message.map { " The host reported: \($0)" } ?? "")
        )
    }
}
