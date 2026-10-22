const { test } = require("node:test");
const assert = require("node:assert/strict");
const { classify } = require("./component-labels.cjs");
test("explicit form selection is authoritative", () => {
  assert.deepEqual(
    classify({
      issue: true,
      title: "iPhone issue",
      body: "### Affected component\n\ncomponent: storage\n\n### Problem\ntext",
    }),
    ["component: storage"],
  );
});
test("unknown selection falls back to text and null bodies work", () => {
  assert.ok(
    classify({ title: "SSE reconnect", body: null }).includes(
      "component: transport",
    ),
  );
});
test("changed and renamed paths classify multiple components", () => {
  const result = classify({
    files: [
      "plugins/opencode-push-relay/src/index.ts",
      "docs/testing-mock.md",
      "OpenCodeRemote/project.yml",
    ],
  });
  for (const label of [
    "component: push-relay",
    "component: documentation",
    "component: app",
  ])
    assert.ok(result.includes(label));
});
test("unrelated text does not create labels", () =>
  assert.deepEqual(classify({ title: "hello" }), []));
