const rules = require("../component-labels.json");
const componentNames = new Set(rules.map((rule) => rule.label));

/** Explicit form choices override inference; Unknown falls back to text. */
function classify({ title = "", body = "", files = [], issue = false }) {
  body = body ?? "";
  const section = issue
    ? body.match(
        /(?:^|\n)### Affected component\s*\n([\s\S]*?)(?=\n### |$)/,
      )?.[1]
    : undefined;
  const selected = (section ?? "").split(/[,\n]/).map((value) =>
    value
      .trim()
      .replace(/^[-*+]\s+(?:\[[ xX]\]\s*)?/, "")
      .trim(),
  );
  const explicit = selected.some((label) => componentNames.has(label));
  const text = `${title}\n${body}`;
  return rules
    .filter((rule) =>
      explicit
        ? selected.includes(rule.label)
        : new RegExp(rule.text, "i").test(text) ||
          files.some((file) => new RegExp(rule.paths).test(file)),
    )
    .map((rule) => rule.label);
}

module.exports = async ({ github, context }) => {
  const issue = Boolean(context.payload.issue);
  const number = (context.payload.issue || context.payload.pull_request).number;
  // Serialized workflow runs always re-read live data, not delayed event snapshots.
  const get = () =>
    (issue ? github.rest.issues.get : github.rest.pulls.get)({
      ...context.repo,
      ...(issue ? { issue_number: number } : { pull_number: number }),
    });
  const { data: item } = await get();
  const files = [];
  if (!issue) {
    const changes = await github.paginate(github.rest.pulls.listFiles, {
      ...context.repo,
      pull_number: number,
      per_page: 100,
    });
    for (const change of changes) {
      files.push(change.filename);
      if (change.previous_filename) files.push(change.previous_filename);
    }
  }
  const components = classify({ ...item, files, issue });
  // If edited while listing files, the next serialized event will reconcile it.
  const { data: latest } = await get();
  if (
    latest.title !== item.title ||
    (latest.body ?? "") !== (item.body ?? "") ||
    (!issue && latest.head.sha !== item.head.sha)
  )
    return;
  const current = await github.paginate(github.rest.issues.listLabelsOnIssue, {
    ...context.repo,
    issue_number: number,
    per_page: 100,
  });
  const wanted = new Set(components);
  for (const { name } of current) {
    if (componentNames.has(name) && !wanted.has(name)) {
      await github.rest.issues.removeLabel({
        ...context.repo,
        issue_number: number,
        name,
      });
    }
  }
  const labels = [...components];
  if (!issue) {
    if (/^fix(?:\([^)]*\))?!?:/i.test(item.title)) labels.push("bug");
    if (/^feat(?:\([^)]*\))?!?:/i.test(item.title)) labels.push("enhancement");
    if (/^[a-z]+(?:\([^)]*\))?!:/i.test(item.title))
      labels.push("breaking-change");
    if (item.user?.login === "dependabot[bot]") labels.push("dependencies");
  }
  if (issue && context.payload.action !== "edited") labels.push("needs-triage");
  if (labels.length)
    await github.rest.issues.addLabels({
      ...context.repo,
      issue_number: number,
      labels,
    });
};
module.exports.classify = classify;
