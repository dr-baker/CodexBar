#!/usr/bin/env python3
"""Exercise fork updates with contained Git repositories and fake app bundles."""

import http.server
import json
import os
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
UPDATE_SCRIPT = ROOT / "Scripts/update_fork.sh"
WORKFLOW = ROOT / ".github/workflows/fork-sync.yml"
REAL_GIT = shutil.which("git")
REAL_GH = shutil.which("gh")
DEVELOPER_HASH = "A" * 40
DEVELOPER_IDENTITY = "Developer ID Application: Fork Fixture (FORKTEAM01)"
DEVELOPMENT_IDENTITY = "Apple Development: Development Fixture (PERSONID01)"
DEFAULT_IDENTITIES = (f'  1) {DEVELOPER_HASH} "{DEVELOPER_IDENTITY}"\n'
                      f'  2) {"B" * 40} "{DEVELOPMENT_IDENTITY}"\n  2 valid identities found\n')


def pr_record(owner="dr-baker", repository="CodexBar", number=1):
    return {
        "url": f"https://github.com/dr-baker/CodexBar/pull/{number}",
        "headRepository": {
            "id": "fixture-repository",
            "name": repository,
            "nameWithOwner": f"{owner}/{repository}",
        },
        "headRepositoryOwner": {"id": "fixture-owner", "name": "Fixture", "login": owner},
    }


FOREIGN_PRS = [
    pr_record(owner="other-fork", number=99),
    pr_record(repository="OtherRepository", number=98),
]


def write_app(app, label="new", feed=""):
    for relative in (
        "Contents/MacOS/CodexBar",
        "Contents/Helpers/CodexBarCLI",
    ):
        executable = app / relative
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_text("#!/bin/sh\nexit 99\n")
        executable.chmod(0o755)
    for relative in (
        "Contents/Helpers/CodexBar_CodexBarCore.bundle",
        "Contents/Frameworks/Sparkle.framework",
    ):
        (app / relative).mkdir(parents=True, exist_ok=True)
    (app / "Contents/Info.plist").write_bytes(
        plistlib.dumps(
            {
                "CFBundleIdentifier": "com.steipete.codexbar",
                "SUFeedURL": feed,
                "SUEnableAutomaticChecks": False,
            }
        )
    )
    (app / "Contents/label").write_text(label)


def workflow_run(name):
    source = WORKFLOW.read_text()
    step = source.split(f"      - name: {name}\n", 1)[1]
    block = step.split("        run: |\n", 1)[1]
    lines = []
    for line in block.splitlines():
        if line and not line.startswith("          "):
            break
        lines.append(line[10:] if line else "")
    return "\n".join(lines) + "\n"


class ForkFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="codexbar-fork-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.repo = self.directory / "repo"
        self.repo.mkdir()
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.git_log = self.directory / "git-log"
        self.gh_log = self.directory / "gh-log"
        self.security_log = self.directory / "security-log"
        self.env = dict(
            GIT_CONFIG_GLOBAL=os.devnull,
            GIT_CONFIG_NOSYSTEM="1",
            GIT_TERMINAL_PROMPT="0",
            LC_ALL="C",
            PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
            TEST_GIT_LOG=str(self.git_log),
            TEST_GH_LOG=str(self.gh_log),
            TEST_SECURITY_LOG=str(self.security_log),
            MOCK_IDENTITIES=DEFAULT_IDENTITIES,
            TEST_GH_RESPONSE=str(self.directory / "gh-response.json"),
            GITHUB_REPOSITORY="dr-baker/CodexBar",
            GITHUB_SERVER_URL="https://github.com",
            GITHUB_RUN_ID="1234",
            SYNC_BRANCH="fork/upstream-sync",
            RUNNER_TEMP=str(self.directory),
        )
        self.git("init", "--initial-branch=main")
        self.git("config", "user.name", "Fork fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        (self.repo / "Scripts").mkdir()
        shutil.copy2(UPDATE_SCRIPT, self.repo / "Scripts/update_fork.sh")
        self.stub(
            "create-app",
            "#!/usr/bin/env python3\n"
            "import plistlib, sys\nfrom pathlib import Path\n"
            "app = Path(sys.argv[1])\n"
            "for relative in ['Contents/MacOS/CodexBar', 'Contents/Helpers/CodexBarCLI']:\n"
            "    path = app / relative\n"
            "    path.parent.mkdir(parents=True, exist_ok=True)\n"
            "    path.write_text('#!/bin/sh\\nexit 99\\n')\n"
            "    path.chmod(0o755)\n"
            "for relative in ['Contents/Helpers/CodexBar_CodexBarCore.bundle', "
            "'Contents/Frameworks/Sparkle.framework']:\n"
            "    (app / relative).mkdir(parents=True, exist_ok=True)\n"
            "(app / 'Contents/Info.plist').write_bytes(plistlib.dumps({"
            "'CFBundleIdentifier': 'com.steipete.codexbar', 'SUFeedURL': '', "
            "'SUEnableAutomaticChecks': False}))\n",
        )
        package = self.repo / "Scripts/package_app.sh"
        package.write_text(
            "#!/usr/bin/env bash\nset -euo pipefail\n"
            'root=$(cd "$(dirname "$0")/.." && pwd)\n'
            '[[ "$*" == release ]] || exit 99\n'
            'printf "%s|%s|%s|%s|%s|%s" "$CODEXBAR_SIGNING" "$APP_IDENTITY" "${APP_TEAM_ID:-}" '
            '"$CODEXBAR_SKIP_LAUNCH_SMOKE" "$CODEXBAR_ALLOW_LLDB" "$CODEXBAR_DISABLE_UPSTREAM_UPDATES" '
            '> "$root/.package-env"\n'
            '[[ "${MOCK_PACKAGE_FAILURE:-0}" == 0 ]] || exit 24\n'
            'create-app "$root/CodexBar.app"\n'
        )
        package.chmod(0o755)
        (self.repo / ".gitignore").write_text("CodexBar.app/\n.package-env\n")
        (self.repo / "shared").write_text("base\n")
        self.git("add", ".")
        self.git("commit", "-m", "Fixture base")
        self.base = self.git("rev-parse", "HEAD").stdout.strip()
        self.fork = self.directory / "fork.git"
        self.upstream = self.directory / "upstream.git"
        self.git("clone", "--bare", str(self.repo), str(self.fork))
        self.git("clone", "--bare", str(self.repo), str(self.upstream))
        self.git("remote", "add", "origin", "https://github.com/dr-baker/CodexBar.git")
        self.git("remote", "add", "upstream", "https://github.com/steipete/CodexBar.git")
        self.stub(
            "git",
            "#!/usr/bin/env bash\nset -euo pipefail\n"
            'printf "%s\\n" "$*" >> "$TEST_GIT_LOG"\n'
            'case "$1" in\n'
            "  fetch|ls-remote|push)\n"
            f"    exec {shlex.quote(REAL_GIT)} "
            f"-c {shlex.quote('url.' + str(self.fork) + '.insteadOf=https://github.com/dr-baker/CodexBar.git')} "
            f"-c {shlex.quote('url.' + str(self.upstream) + '.insteadOf=https://github.com/steipete/CodexBar.git')} "
            '"$@" ;;\n'
            f'  *) exec {shlex.quote(REAL_GIT)} "$@" ;;\nesac\n',
        )
        self.stub("uname", '#!/bin/bash\n[[ "$*" == -s ]] || exit 99\necho Darwin\n')
        self.stub("codesign", '#!/bin/bash\nexit "${MOCK_CODESIGN_EXIT:-0}"\n')
        self.stub(
            "ditto",
            '#!/bin/bash\nset -euo pipefail\n/bin/cp -R "$1" "$2"\n'
            'if [[ "${MOCK_DITTO_CORRUPT:-0}" == 1 ]]; then\n'
            '  printf "invalid plist" > "$2/Contents/Info.plist"\nfi\n',
        )
        self.stub(
            "mv",
            '#!/bin/bash\nset -euo pipefail\n'
            'if [[ "${MOCK_INSTALL_MOVE_FAILURE:-0}" == 1 '
            '&& "$1" == */.codexbar-fork-install.*/CodexBar.app ]]; then exit 24; fi\n'
            'exec /bin/mv "$@"\n',
        )
        self.stub(
            "gh",
            '#!/usr/bin/env python3\n'
            'import json, os, subprocess, sys\nfrom pathlib import Path\n'
            'args = sys.argv[1:]\n'
            'with open(os.environ["TEST_GH_LOG"], "a") as log:\n'
            '    log.write(" ".join(args) + "\\n")\n'
            'if args[:2] == ["pr", "list"]:\n'
            '    for flag, expected in [("--repo", "dr-baker/CodexBar"), '
            '("--base", "main"), ("--head", "fork/upstream-sync")]:\n'
            '        assert args[args.index(flag) + 1] == expected\n'
            '    fields = args[args.index("--json") + 1].split(",")\n'
            '    prs = json.loads(os.environ.get("MOCK_PRS_JSON", "[]"))\n'
            '    response = [{field: pr.get(field) for field in fields} for pr in prs]\n'
            '    Path(os.environ["TEST_GH_RESPONSE"]).write_text(json.dumps(response))\n'
            '    expression = args[args.index("--jq") + 1]\n'
            '    command = [os.environ["TEST_REAL_GH"], "api", os.environ["TEST_GH_API_URL"], '
            '"--method", "GET", "--jq", expression]\n'
            '    env = dict(os.environ, GH_TOKEN="contained-test", '
            'GH_CONFIG_DIR=os.environ["TEST_GH_CONFIG"], GH_PROMPT_DISABLED="1")\n'
            '    sys.exit(subprocess.run(command, env=env).returncode)\n'
            'elif args[:2] == ["pr", "create"]:\n'
            '    print("https://github.com/dr-baker/CodexBar/pull/1")\n'
            'elif args[:2] not in [["pr", "edit"], ["auth", "setup-git"]]:\n'
            '    sys.exit(99)\n',
        )
        self.stub(
            "security",
            '#!/bin/bash\n[[ "$*" == "find-identity -p codesigning -v" ]] || exit 99\n'
            'printf "%s\\n" "$*" >> "$TEST_SECURITY_LOG"\n'
            'printf "%s" "$MOCK_IDENTITIES"\nexit "${MOCK_SECURITY_EXIT:-0}"\n',
        )
        for name in ("open", "pkill"):
            self.stub(name, '#!/bin/bash\necho "Unexpected live command" >&2\nexit 99\n')

    def stub(self, name, source):
        path = self.bin / name
        path.write_text(source)
        path.chmod(0o755)

    def git(self, *arguments, cwd=None):
        return subprocess.run(
            [REAL_GIT, *arguments], cwd=cwd or self.repo, env=self.env,
            check=True, capture_output=True, text=True,
        )

    def advance_remote(self, remote, name="upstream-change", value="updated\n"):
        checkout = self.directory / (remote.name + "-edit")
        self.git("clone", str(remote), str(checkout))
        self.git("config", "user.name", "Remote fixture", cwd=checkout)
        self.git("config", "user.email", "remote@example.invalid", cwd=checkout)
        self.git("config", "commit.gpgsign", "false", cwd=checkout)
        changed_file = checkout / name
        changed_file.parent.mkdir(parents=True, exist_ok=True)
        changed_file.write_text(value)
        self.git("add", name, cwd=checkout)
        self.git("commit", "-m", "Remote change", cwd=checkout)
        self.git("push", "origin", "main", cwd=checkout)
        return self.git("rev-parse", "HEAD", cwd=checkout).stdout.strip()

    def local_change(self, name="custom-menu", value="custom\n"):
        (self.repo / name).write_text(value)
        self.git("add", name)
        self.git("commit", "-m", "Customize menu")
        return self.git("rev-parse", "HEAD").stdout.strip()

    def update(self, *arguments, overrides=None, shell="bash"):
        return subprocess.run(
            [shell, "Scripts/update_fork.sh", *arguments], cwd=self.repo,
            env=dict(self.env, **(overrides or {})), capture_output=True, text=True,
        )

    def assert_no_fetch(self):
        self.assertFalse((self.repo / ".package-env").exists())
        if self.git_log.exists():
            self.assertNotRegex(self.git_log.read_text(), r"(?m)^fetch ")

    def install(self, source, destination, shell="bash", **overrides):
        return subprocess.run(
            [shell, "-c", 'source "$1"; install_fork_app "$2" "$3"',
             "fixture", str(UPDATE_SCRIPT), str(source), str(destination)],
            env=dict(self.env, **overrides), capture_output=True, text=True,
        )

    def start_gh_api(self):
        if "TEST_GH_API_URL" in self.env:
            return
        if REAL_GH is None:
            self.skipTest("GitHub CLI is needed to evaluate the workflow's jq expression.")
        response = self.directory / "gh-response.json"

        class ResponseHandler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = response.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ResponseHandler)
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        thread.start()

        def stop_server():
            server.shutdown()
            server.server_close()
            thread.join()

        self.addCleanup(stop_server)
        self.env.update(
            TEST_REAL_GH=REAL_GH,
            TEST_GH_API_URL=f"http://127.0.0.1:{server.server_port}/prs",
            TEST_GH_CONFIG=str(self.directory / "gh-config"),
        )

    def prepare(self, **overrides):
        self.start_gh_api()
        if "upstream" in self.git("remote").stdout.splitlines():
            self.git("remote", "remove", "upstream")
        self.output = self.directory / "outputs"
        self.summary = self.directory / "summary"
        self.output.write_text("")
        self.summary.write_text("")
        result = subprocess.run(
            ["bash", "-c", workflow_run("Prepare upstream merge")], cwd=self.repo,
            env=dict(self.env, GITHUB_OUTPUT=str(self.output),
                     GITHUB_STEP_SUMMARY=str(self.summary), **overrides),
            capture_output=True, text=True,
        )
        outputs = dict(line.split("=", 1) for line in self.output.read_text().splitlines())
        return result, outputs

    def publish(self, outputs, **overrides):
        self.start_gh_api()
        return subprocess.run(
            ["bash", "-c", workflow_run("Publish one upstream sync PR")], cwd=self.repo,
            env=dict(self.env, BASE_SHA=outputs["base_sha"], UPSTREAM_SHA=outputs["upstream_sha"],
                     EXISTING_SHA=outputs["existing_sha"], GITHUB_STEP_SUMMARY=str(self.summary),
                     **overrides), capture_output=True, text=True,
        )


class LocalUpdateTests(ForkFixture):
    def test_behind_only_update_creates_a_merge_commit(self):
        fork_sha = self.advance_remote(self.fork)
        result = self.update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git("show", "-s", "--format=%P", "HEAD").stdout.strip(),
                         f"{self.base} {fork_sha}")

    def test_update_preserves_custom_commits_in_a_non_fast_forward_merge(self):
        fork_sha = self.advance_remote(self.fork)
        local_sha = self.local_change()
        result = self.update(overrides={"CODEXBAR_SIGNING": "identity", "CODEXBAR_ALLOW_LLDB": "1"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git("show", "-s", "--format=%P", "HEAD").stdout.strip(),
                         f"{local_sha} {fork_sha}")
        self.assertEqual((self.repo / "custom-menu").read_text(), "custom\n")
        self.assertEqual((self.repo / ".package-env").read_text(), f"identity|{DEVELOPER_HASH}||1|0|1")
        self.assertIn("Built ", result.stdout)
        self.assertNotIn("Installed ", result.stdout)

    def test_conflicts_abort_without_building_or_changing_local_commits(self):
        self.advance_remote(self.fork, "shared", "remote\n")
        local_sha = self.local_change("shared", "local\n")
        result = self.update()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("merge was aborted", result.stderr)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), local_sha)
        self.assertEqual(self.git("status", "--porcelain").stdout, "")
        self.assertFalse((self.repo / ".package-env").exists())

    def test_dirty_checkout_refuses_to_fetch(self):
        (self.repo / "untracked-change").write_text("work\n")
        result = self.update()
        self.assertIn("Commit or stash", result.stderr)
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_fetch()

    def test_wrong_branch_refuses_to_fetch(self):
        self.git("switch", "-c", "feature")
        result = self.update()
        self.assertIn("Switch to main", result.stderr)
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_fetch()

    def test_wrong_fetch_or_push_remote_refuses_to_fetch(self):
        for remote, push in (("origin", False), ("upstream", False), ("origin", True)):
            with self.subTest(remote=remote, push=push):
                command = ["remote", "set-url"] + (["--push"] if push else [])
                self.git(*command, remote, "https://github.com/wrong/CodexBar.git")
                result = self.update()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("must point to", result.stderr)
                self.assert_no_fetch()
                self.git("config", "--unset-all", f"remote.{remote}." + ("pushurl" if push else "url"))
                if not push:
                    owner = "dr-baker" if remote == "origin" else "steipete"
                    self.git("remote", "set-url", remote, f"https://github.com/{owner}/CodexBar.git")

    def test_ssh_remotes_are_accepted_without_using_network(self):
        self.git("remote", "set-url", "origin", "git@github.com:dr-baker/CodexBar.git")
        self.git("remote", "set-url", "upstream", "ssh://git@github.com/steipete/CodexBar.git")
        wrapper = self.bin / "git"
        source = wrapper.read_text().replace(
            '"$@" ;;',
            f"-c {shlex.quote('url.' + str(self.fork) + '.insteadOf=git@github.com:dr-baker/CodexBar.git')} "
            '"$@" ;;',
            1,
        )
        wrapper.write_text(source)
        result = self.update()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_build_failure_keeps_source_update_and_reports_no_install(self):
        fork_sha = self.advance_remote(self.fork)
        result = self.update(overrides={"MOCK_PACKAGE_FAILURE": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("installed app was not changed", result.stderr)
        self.git("merge-base", "--is-ancestor", fork_sha, "HEAD")
        self.assertFalse((self.repo / "CodexBar.app").exists())


class SigningTests(ForkFixture):
    def test_default_signing_selects_the_unique_developer_id(self):
        result = self.update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.repo / ".package-env").read_text(), f"identity|{DEVELOPER_HASH}||1|0|1")
        self.assertEqual(self.security_log.read_text(), "find-identity -p codesigning -v\n")

    def test_missing_ambiguous_or_unreadable_certificates_refuse_fetch(self):
        second_developer = f'  3) {"C" * 40} "Developer ID Application: Other Fixture (OTHERTEAM1)"\n'
        for label, identities, exit_code in (
            ("missing", "", "0"),
            ("development only", f'  1) {"B" * 40} "{DEVELOPMENT_IDENTITY}"\n', "0"),
            ("ambiguous", DEFAULT_IDENTITIES + second_developer, "0"),
            ("query failed", DEFAULT_IDENTITIES, "7"),
        ):
            with self.subTest(case=label):
                result = self.update(overrides={"MOCK_IDENTITIES": identities, "MOCK_SECURITY_EXIT": exit_code})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("APP_IDENTITY", result.stderr)
                self.assertIn("CODEXBAR_SIGNING=adhoc", result.stderr)
                self.assert_no_fetch()
                self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.base)

    def test_explicit_identity_resolves_by_hash_name_or_substring(self):
        for identity, team in ((DEVELOPER_IDENTITY, "FORKTEAM01"), (DEVELOPER_HASH, ""),
                               (DEVELOPER_HASH.lower(), ""), ("Fork Fixture", "")):
            with self.subTest(identity=identity):
                result = self.update(overrides={"APP_IDENTITY": identity, "APP_TEAM_ID": team})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((self.repo / ".package-env").read_text(),
                                 f"identity|{DEVELOPER_HASH}|{team}|1|0|1")

    def test_explicit_missing_ambiguous_or_wrong_team_identity_refuses_fetch(self):
        for label, identity, team in (
            ("missing", "Missing certificate", ""),
            ("ambiguous", "Fixture", ""),
            ("development", DEVELOPMENT_IDENTITY, ""),
            ("wrong team", DEVELOPER_IDENTITY, "WRONGTEAM1"),
        ):
            with self.subTest(case=label):
                result = self.update(overrides={"APP_IDENTITY": identity, "APP_TEAM_ID": team})
                self.assertNotEqual(result.returncode, 0)
                self.assert_no_fetch()
                self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.base)

    def test_explicit_adhoc_skips_identity_discovery(self):
        result = self.update(overrides={"CODEXBAR_SIGNING": "adhoc", "APP_IDENTITY": "Missing certificate",
                                       "MOCK_SECURITY_EXIT": "99", "CODEXBAR_ALLOW_LLDB": "1",
                                       "CODEXBAR_DISABLE_UPSTREAM_UPDATES": "0"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.repo / ".package-env").read_text(), "adhoc|||1|0|1")
        self.assertFalse(self.security_log.exists())

    def test_unknown_signing_modes_refuse_fetch(self):
        for mode in ("automatic", "none", "invalid"):
            with self.subTest(mode=mode):
                result = self.update(overrides={"CODEXBAR_SIGNING": mode})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Unsupported CODEXBAR_SIGNING", result.stderr)
                self.assert_no_fetch()
                self.assertFalse(self.security_log.exists())


@unittest.skipUnless(sys.platform == "darwin", "Apple Bash is available on macOS")
class AppleBashSigningTests(SigningTests):
    def update(self, *arguments, **options):
        return super().update(*arguments, shell="/bin/bash", **options)


class InstallTests(ForkFixture):
    def setUp(self):
        super().setUp()
        self.app = self.directory / "built/CodexBar.app"
        write_app(self.app)
        self.applications = self.directory / "Applications"
        self.applications.mkdir()
        self.destination = self.applications / "CodexBar.app"
        write_app(self.destination, label="old")

    def test_installs_validated_copy_and_keeps_recoverable_previous_bundle(self):
        result = self.install(self.app, self.applications)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.destination / "Contents/label").read_text(), "new")
        backups = list(self.applications.glob("CodexBar-previous-*.app"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "Contents/label").read_text(), "old")
        self.assertIn(str(backups[0]), result.stdout)
        self.assertEqual(list(self.applications.glob(".codexbar-fork-install.*")), [])

    def test_invalid_feed_signature_or_staged_copy_leaves_existing_app_untouched(self):
        for case in ("feed", "signature", "copy"):
            with self.subTest(case=case):
                write_app(self.app, feed="https://example.invalid/appcast.xml" if case == "feed" else "")
                result = self.install(
                    self.app, self.applications,
                    MOCK_CODESIGN_EXIT="1" if case == "signature" else "0",
                    MOCK_DITTO_CORRUPT="1" if case == "copy" else "0",
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((self.destination / "Contents/label").read_text(), "old")
                self.assertEqual(list(self.applications.glob("CodexBar-previous-*.app")), [])
                self.assertEqual(list(self.applications.glob(".codexbar-fork-install.*")), [])

    def test_failed_install_move_restores_previous_bundle(self):
        result = self.install(self.app, self.applications, MOCK_INSTALL_MOVE_FAILURE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.destination / "Contents/label").read_text(), "old")
        self.assertEqual(list(self.applications.glob("CodexBar-previous-*.app")), [])
        self.assertEqual(list(self.applications.glob(".codexbar-fork-install.*")), [])

    def test_symlinked_app_or_applications_directory_is_refused(self):
        alias = self.directory / "Applications-link"
        alias.symlink_to(self.applications, target_is_directory=True)
        result = self.install(self.app, alias)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symlinked Applications", result.stderr)
        shutil.rmtree(self.destination)
        self.destination.symlink_to(self.app, target_is_directory=True)
        result = self.install(self.app, self.applications)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symlinked app", result.stderr)
        self.assertEqual((self.app / "Contents/label").read_text(), "new")


@unittest.skipUnless(sys.platform == "darwin", "Apple Bash is available on macOS")
class AppleBashInstallTests(InstallTests):
    def install(self, source, destination, **overrides):
        return super().install(source, destination, shell="/bin/bash", **overrides)


class SyncWorkflowTests(ForkFixture):
    def test_workflow_changes_require_the_explicit_sync_token_before_publishing(self):
        self.advance_remote(self.upstream, ".github/workflows/new.yml", "name: Fixture\n")
        result, outputs = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Add FORK_SYNC_TOKEN", result.stdout)
        self.assertNotIn("changed", outputs)
        self.assertNotRegex(self.git_log.read_text(), r"(?m)^push ")
        self.git("reset", "--hard", self.base)
        result, outputs = self.prepare(HAS_SYNC_TOKEN="true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(outputs["changed"], "true")

    def test_no_upstream_changes_exits_without_a_sync_branch(self):
        result, outputs = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(outputs, {"changed": "false"})
        self.assertFalse(self.gh_log.exists())

    def test_candidate_merge_preserves_customizations_and_does_not_publish(self):
        upstream_sha = self.advance_remote(self.upstream)
        local_sha = self.local_change()
        result, outputs = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(outputs["changed"], "true")
        self.assertEqual(outputs["upstream_sha"], upstream_sha)
        self.assertEqual(self.git("show", "-s", "--format=%P", "HEAD").stdout.strip(),
                         f"{local_sha} {upstream_sha}")
        self.assertEqual((self.repo / "custom-menu").read_text(), "custom\n")
        self.assertNotRegex(self.git_log.read_text(), r"(?m)^push ")

    def test_conflict_aborts_without_publishing_invalid_merge(self):
        self.advance_remote(self.upstream, "shared", "upstream\n")
        local_sha = self.local_change("shared", "fork\n")
        result, _ = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), local_sha)
        self.assertEqual(self.git("status", "--porcelain").stdout, "")
        self.assertIn("shared", self.summary.read_text())
        self.assertNotRegex(self.git_log.read_text(), r"(?m)^push ")

    def test_reuses_existing_candidate_and_skips_duplicate_pr(self):
        self.advance_remote(self.upstream)
        result, _ = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        candidate = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("push", str(self.fork), "HEAD:refs/heads/fork/upstream-sync")
        self.git("reset", "--hard", self.base)
        result, outputs = self.prepare(MOCK_PRS_JSON=json.dumps(FOREIGN_PRS + [pr_record()]))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(outputs, {"changed": "false"})
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), candidate)
        self.assertNotRegex(self.gh_log.read_text(), r"(?m)^pr (create|edit) ")
        self.assertIn("/pull/1)", self.summary.read_text())
        self.assertNotIn("/pull/99)", self.summary.read_text())
        self.assertNotIn("/pull/98)", self.summary.read_text())

    def test_existing_candidate_does_not_skip_for_foreign_prs_only(self):
        self.advance_remote(self.upstream)
        result, _ = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        candidate = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("push", str(self.fork), "HEAD:refs/heads/fork/upstream-sync")
        self.git("reset", "--hard", self.base)
        result, outputs = self.prepare(MOCK_PRS_JSON=json.dumps(FOREIGN_PRS))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(outputs["changed"], "true")
        self.assertEqual(outputs["existing_sha"], candidate)
        self.assertNotIn("existing [upstream sync PR]", self.summary.read_text())

    def test_publish_refuses_main_changes_and_sync_branch_races(self):
        self.advance_remote(self.upstream)
        result, outputs = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.publish(dict(outputs, base_sha="0" * 40))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("main changed", result.stdout)
        self.git("push", str(self.fork), f"{self.base}:refs/heads/fork/upstream-sync")
        result = self.publish(outputs)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("stale info", result.stderr)
        self.assertNotRegex(self.gh_log.read_text(), r"(?m)^pr (create|edit) ")

    def test_publish_creates_or_updates_exactly_one_pr_with_validated_merge(self):
        self.advance_remote(self.upstream)
        result, outputs = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.publish(outputs)
        self.assertEqual(result.returncode, 0, result.stderr)
        log = self.gh_log.read_text()
        self.assertEqual(len(re.findall(r"(?m)^pr create ", log)), 1)
        self.assertEqual(len(re.findall(r"(?m)^pr edit ", log)), 0)
        outputs["existing_sha"] = self.git("rev-parse", "HEAD").stdout.strip()
        result = self.publish(outputs, MOCK_PRS_JSON=json.dumps(FOREIGN_PRS + [pr_record()]))
        self.assertEqual(result.returncode, 0, result.stderr)
        log = self.gh_log.read_text()
        self.assertEqual(len(re.findall(r"(?m)^pr create ", log)), 1)
        self.assertEqual(len(re.findall(r"(?m)^pr edit ", log)), 1)
        self.assertIn("pr edit https://github.com/dr-baker/CodexBar/pull/1 ", log)
        self.assertNotRegex(log, r"(?m)^pr edit https://github.com/dr-baker/CodexBar/pull/(98|99) ")
        body = (self.directory / "fork-sync-pr.md").read_text()
        self.assertIn("make check, and make test", body)
        self.assertIn(outputs["upstream_sha"], body)

    def test_publish_creates_own_pr_instead_of_editing_a_foreign_pr(self):
        self.advance_remote(self.upstream)
        result, outputs = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.publish(outputs, MOCK_PRS_JSON=json.dumps(FOREIGN_PRS))
        self.assertEqual(result.returncode, 0, result.stderr)
        log = self.gh_log.read_text()
        self.assertEqual(len(re.findall(r"(?m)^pr create ", log)), 1)
        self.assertNotRegex(log, r"(?m)^pr edit ")


if __name__ == "__main__":
    unittest.main()
