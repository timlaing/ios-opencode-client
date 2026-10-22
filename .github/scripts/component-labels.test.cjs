const { test } = require("node:test");
const assert = require("node:assert/strict");
const handler = require("./component-labels.cjs");
const { classify } = handler;

test("comma-separated and Markdown list selections override inference", () => {
  for (const selection of [
    "component: storage, component: transport",
    "- component: storage\n- component: transport",
    "* [x] component: storage\n* [x] component: transport",
  ]) {
    assert.deepEqual(
      classify({
        issue: true,
        title: "iPhone mock",
        body: `### Affected component\n\n${selection}\n\n### Problem\nCI`,
      }),
      ["component: transport", "component: storage"],
    );
  }
});
test("Unknown selection falls back to report text", () => {
  assert.ok(
    classify({
      issue: true,
      title: "SSE reconnect",
      body: "### Affected component\n\nUnknown\n\n### Problem\nconnection drops",
    }).includes("component: transport"),
  );
});
test("null bodies, unrelated text and CI checker paths", () => {
  assert.ok(
    classify({ title: "SSE reconnect", body: null }).includes(
      "component: transport",
    ),
  );
  assert.deepEqual(classify({ title: "hello" }), []);
  assert.deepEqual(classify({ files: ["scripts/check_action_refs.py"] }), [
    "component: ci",
  ]);
});
function fixture({ issue = false, items, changes = [], labels = [] }) {
  let reads = 0;
  const added = [],
    removed = [];
  const get = async () => ({
    data: items[Math.min(reads++, items.length - 1)],
  });
  const listFiles = () => {};
  const listLabelsOnIssue = () => {};
  return {
    added,
    removed,
    context: {
      repo: { owner: "owner", repo: "repo" },
      payload: {
        action: "edited",
        [issue ? "issue" : "pull_request"]: { number: 3, title: "stale event" },
      },
    },
    github: {
      rest: {
        pulls: { get, listFiles },
        issues: {
          get,
          listLabelsOnIssue,
          addLabels: async (x) => added.push(...x.labels),
          removeLabel: async (x) => removed.push(x.name),
        },
      },
      paginate: async (method) =>
        method === listFiles ? changes : labels.map((name) => ({ name })),
    },
  };
}
test("handler includes previous filename for renamed PRs", async () => {
  const item = {
    number: 3,
    title: "rename",
    body: null,
    updated_at: "now",
    head: { sha: "a" },
  };
  const f = fixture({
    items: [item],
    changes: [
      {
        filename: "unmatched.txt",
        previous_filename: "OpenCodeRemote/project.yml",
      },
    ],
  });
  await handler(f);
  assert.ok(f.added.includes("component: app"));
});
test("handler reconciles only managed component labels using live issue state", async () => {
  const item = {
    number: 3,
    title: "issue",
    body: "### Affected component\n\ncomponent: storage",
    updated_at: "now",
  };
  const f = fixture({
    issue: true,
    items: [item],
    labels: ["component: app", "security", "roadmap", "custom"],
  });
  await handler(f);
  assert.deepEqual(f.removed, ["component: app"]);
  assert.deepEqual(f.added, ["component: storage"]);
});
test("concurrent edits are left for the next serialized run", async () => {
  const first = { number: 3, title: "issue", body: null, updated_at: "before" };
  const f = fixture({
    issue: true,
    items: [
      first,
      { ...first, updated_at: "after", body: "Changed description" },
    ],
    labels: ["component: app"],
  });
  await handler(f);
  assert.deepEqual(f.added, []);
  assert.deepEqual(f.removed, []);
});
test("older event uses latest API data and preserves manual lifecycle labels", async () => {
  const item = {
    number: 3,
    title: "feat!: CI changes",
    body: null,
    updated_at: "now",
    head: { sha: "a" },
    user: { login: "dependabot[bot]" },
  };
  const f = fixture({
    items: [item],
    changes: [{ filename: "scripts/check_action_refs.py" }],
    labels: ["component: storage", "security"],
  });
  await handler(f);
  for (const name of [
    "component: ci",
    "enhancement",
    "breaking-change",
    "dependencies",
  ])
    assert.ok(f.added.includes(name));
  assert.deepEqual(f.removed, ["component: storage"]);
});
