"""Exercise the native PR/branch publication boundary with the actual guard script."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1] / "workflows"
DOCUMENT = yaml.safe_load((ROOT / "native-tests.yml").read_text())


class NativeSonarBoundaryTests(unittest.TestCase):
    """Unprivileged PR coverage and trusted scan credentials must remain separate."""

    def test_pr_coverage_never_receives_scanner_credentials(self) -> None:
        """Dependabot does not need an Actions or Dependabot analysis token."""
        coverage = DOCUMENT["jobs"]["coverage"]
        self.assertNotIn("SONAR_TOKEN", str(coverage))
        self.assertIn(
            "github.event_name != 'pull_request'", DOCUMENT["jobs"]["sonar"]["if"]
        )
        receiver = yaml.safe_load((ROOT / "sonarqube.yml").read_text())
        analysis = receiver["jobs"]["analysis"]
        self.assertEqual(analysis["runs-on"], "ubuntu-latest")
        scanner = [step for step in analysis["steps"] if "SONAR_TOKEN" in str(step)]
        self.assertEqual(len(scanner), 1)
        self.assertTrue(
            scanner[0]["uses"].startswith("SonarSource/sonarqube-scan-action@")
        )
        self.assertIn(
            "Analysis passed", (ROOT.parent / "workflow-policy.json").read_text()
        )

    def test_required_ci_preserves_branch_scan_and_pr_coverage_gates(self) -> None:
        """Run the committed guard: PR scan skipping cannot weaken branch publication."""
        script = DOCUMENT["jobs"]["required"]["steps"][0]["run"]
        for event, scan, coverage, succeeds in [
            ("pull_request", "skipped", "success", True),
            ("pull_request", "success", "success", False),
            ("push", "skipped", "success", False),
            ("push", "success", "success", True),
            ("push", "success", "failure", False),
        ]:
            with self.subTest(event=event, scan=scan, coverage=coverage):
                result = subprocess.run(
                    ["/bin/bash", "-c", script],
                    env={
                        "VALIDATE_RESULT": "success",
                        "NATIVE_RESULT": "success",
                        "COVERAGE_RESULT": coverage,
                        "SONAR_RESULT": scan,
                        "EVENT_NAME": event,
                    },
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(
                    result.returncode == 0, succeeds, result.stdout + result.stderr
                )

    def test_branch_scan_consumes_only_validated_data_artifacts(self) -> None:
        """The real validator rejects script injection, partial coverage and stale revisions."""
        step = next(step for step in DOCUMENT["jobs"]["sonar"]["steps"] if step.get("name") == "Validate trusted branch coverage")
        script = "\n".join(step["run"].splitlines()[1:-1])
        required = ["reports/coverage.xml", "coverage/coverage-python.xml", "coverage/coverage.lcov", "coverage/coverage-classifier.lcov", "coverage/coverage-bridge.lcov"]
        for attack in ["valid", "script", "missing", "revision", "entity", "symlink"]:
            with self.subTest(attack=attack), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                inputs = root / "inputs"
                inputs.mkdir()
                for relative in required:
                    report = inputs / relative
                    report.parent.mkdir(parents=True, exist_ok=True)
                    report.write_text("<coverage/>" if report.suffix == ".xml" else "TN:\n")
                (inputs / "coverage-revision.txt").write_text("a" * 40)
                if attack == "script":
                    (inputs / "injected.py").write_text("raise RuntimeError('Executed artifact')")
                if attack == "missing":
                    (inputs / required[0]).unlink()
                if attack == "revision":
                    (inputs / "coverage-revision.txt").write_text("b" * 40)
                if attack == "entity":
                    (inputs / required[0]).write_text('<!ENTITY bad "bad"><coverage/>')
                if attack == "symlink":
                    (inputs / "linked").symlink_to(root)
                result = subprocess.run(  # noqa: S603 - execute the committed isolated validator
                    [sys.executable, "-I", "-c", script], cwd=root,
                    env={"INPUTS": str(inputs), "HEAD_SHA": "a" * 40},
                    capture_output=True, text=True, check=False, timeout=10,
                )
                self.assertEqual(result.returncode == 0, attack == "valid", result.stderr)
                self.assertFalse((root / "injected.py").exists())


if __name__ == "__main__":
    unittest.main()
