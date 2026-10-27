# Checkout reconciliation — 24 October 2026

The original checkout remains on `codex/pr2-review-fixes` at `28e2938`, with
its existing uncommitted work preserved. New documentation corrections are
isolated in the `repo-state-reconcile` worktree, based on current main
`0a172d6798eba5704f595716b49bae9c20173d04`. The corrections are maintained on
`codex/reconcile-repo-state`; main and the original checkout were not changed.

## Existing local changes

- README product rewrite and Xcode Cloud link: already incorporated into main,
  which additionally documents publishing and contributions.
- `project.yml` coverage setting: already on main. Main also has version/build
  settings and an Analyze configuration absent from the old checkout.
- Post-clone script and Xcode workspace `Package.resolved`: byte-identical to
  main.
- Local Xcode Cloud guide: superseded by main's expanded workflow guide.
- Generated project/scheme: differ from main in Xcode metadata and build
  settings. Do not copy these over main; use its `project.yml` and regenerate
  with XcodeGen when project configuration changes.

The old working tree should be retained until its owner is ready to discard
these superseded edits. No reset, stash deletion or force checkout was used.
Continue new work from the isolated current-main worktree.

## Outstanding work

See [verification](verification.md) for hosted CI failures and remaining
real-host/device acceptance. The warning-fix PR that was open when this note
was written merged to `main` as `6b3a361` on 24 October 2026, so its results
are no longer separate from `main`; the reconciliation itself changed no
product code. Hosted CI still fails — see the 25 October evidence in
[verification](verification.md#hosted-ci--checked-25-october-2026) and
[xcode-cloud](xcode-cloud.md#hosted-status--checked-25-october-2026).
