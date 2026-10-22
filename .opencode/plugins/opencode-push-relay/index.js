// SPDX-License-Identifier: MPL-2.0
//
// Local-load shim: OpenCode v2.0.30 auto-discovers plugins from
// `.opencode/plugins/<dir>/index.js`, but does NOT load `plugins[]`
// entries declared in a project opencode.json(c) (verified against a
// real `opencode serve`; see plugins/opencode-push-relay/README.md).
// This re-exports the real package entry so running opencode inside
// this repo loads the plugin — inert, since auto-discovered plugins
// receive no options. Configure via plugins[].options once your
// opencode version honors project-level declarations.
export { default } from "../../../plugins/opencode-push-relay/src/index.ts"
