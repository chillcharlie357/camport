import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tool.release import build_version, eligible_pr, prepare, publish, tag_commit
import json


SHA = "a" * 40


class ReleaseTests(unittest.TestCase):
    def test_main_push_waits_for_merged_pr_and_emits_one_version(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            event = directory / 'event.json'
            output = directory / 'output'
            pubspec = directory / 'pubspec.yaml'
            pubspec.write_text('version: 0.1.0+1\n')
            event.write_text(json.dumps({'ref': 'refs/heads/main'}))
            pr = {'number': 12, 'merged_at': '2026-11-10T10:00:00Z',
                  'merge_commit_sha': SHA,
                  'base': {'ref': 'main', 'repo': {'full_name': 'owner/repo'}}}
            environment = {'GITHUB_EVENT_PATH': str(event), 'GITHUB_OUTPUT': str(output),
                           'GITHUB_REPOSITORY': 'owner/repo', 'GITHUB_SHA': SHA,
                           'GITHUB_RUN_NUMBER': '3'}
            with patch.dict('os.environ', environment), \
                    patch('tool.release.gh_command', side_effect=[[], [pr]]), \
                    patch('tool.release.time.sleep') as sleep:
                prepare(pubspec)
            self.assertIn('version=0.1.3\n', output.read_text())
            self.assertIn(f'sha={SHA}\n', output.read_text())
            self.assertIn('publish=true\n', output.read_text())
            sleep.assert_called_once()

    def test_direct_main_push_has_no_release_outputs(self):
        with tempfile.TemporaryDirectory() as temp:
            event = Path(temp) / 'event.json'
            output = Path(temp) / 'output'
            event.write_text('{"ref":"refs/heads/main"}')
            with patch.dict('os.environ', {'GITHUB_EVENT_PATH': str(event),
                            'GITHUB_OUTPUT': str(output), 'GITHUB_REPOSITORY': 'owner/repo',
                            'GITHUB_SHA': SHA}), \
                    patch('tool.release.gh_command', return_value=[]), \
                    patch('tool.release.time.sleep'):
                prepare()
            self.assertEqual(output.read_text(), 'publish=false\n')

    def test_non_main_push_cannot_prepare_release(self):
        with tempfile.TemporaryDirectory() as temp:
            event = Path(temp) / 'event.json'
            event.write_text('{"ref":"refs/heads/develop"}')
            with patch.dict('os.environ', {'GITHUB_EVENT_PATH': str(event),
                            'GITHUB_REPOSITORY': 'owner/repo', 'GITHUB_SHA': SHA}):
                with self.assertRaises(ValueError):
                    prepare()

    def test_only_merged_main_pr_matching_push_is_eligible(self):
        valid = {"number": 12, "merged_at": "2026-11-10T10:00:00Z",
                 "base": {"ref": "main"}, "merge_commit_sha": SHA}
        self.assertEqual(eligible_pr([valid], SHA), 12)
        for change in ({"merged_at": None}, {"base": {"ref": "develop"}},
                       {"merge_commit_sha": "b" * 40}):
            self.assertIsNone(eligible_pr([{**valid, **change}], SHA))
        self.assertIsNone(eligible_pr([], SHA))

    def test_versions_are_deterministic_and_accept_gaps(self):
        self.assertEqual(build_version("version: 0.1.0+1\n", 1), "0.1.1")
        self.assertEqual(build_version("version: 1.2.3+4\n", 9), "1.2.12")
        self.assertEqual(build_version("version: 1.2.3+4\n", 9), "1.2.12")
        for run in (0, -1, 2_100_000_001):
            with self.assertRaises(ValueError):
                build_version("version: 0.1.0+1", run)
        for content in ("", "version: invalid", "version: 1.0.0-dev.1",
                        "version: 1.2.3\nversion: 1.2.4"):
            with self.assertRaises(ValueError):
                build_version(content, 1)

    def assets(self, directory):
        names = [f"sony-camera-0.1.1-{platform}" for platform in
                 ("android.apk", "macos.zip", "windows-x64.zip")]
        for name in names:
            (directory / name).write_bytes(name.encode())
        return set(names) | {"SHA256SUMS.txt", "BUILD-INFO.json"}

    def test_missing_platform_prevents_release_creation(self):
        with tempfile.TemporaryDirectory() as temp:
            calls = []
            with self.assertRaises(ValueError):
                publish(Path(temp), "0.1.1", SHA, "owner/repo", 12,
                        gh=lambda *args: calls.append(args))
            self.assertEqual(calls, [])

    def test_all_assets_upload_to_draft_before_publication(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            expected = self.assets(directory)
            calls = []
            def gh(*args):
                calls.append(args)
                if args[0] == "api" and "/git/ref/tags/" in args[1]:
                    return None
                if args[0] == "api" and "/releases/tags/" in args[1]:
                    if not any(c[:2] == ("release", "upload") for c in calls):
                        return None
                    return {"id": 1, "draft": True, "target_commitish": SHA,
                            "assets": [{"name": n} for n in expected]}
                return {}
            publish(directory, "0.1.1", SHA, "owner/repo", 12, gh=gh)
            create = next(c for c in calls if c[:2] == ("release", "create"))
            self.assertIn("--draft", create)
            self.assertLess(next(i for i, c in enumerate(calls)
                                 if c[:2] == ("release", "upload")), len(calls)-1)
            self.assertIn("draft=false", calls[-1])
            self.assertIn("make_latest=legacy", calls[-1])
            self.assertTrue((directory / "SHA256SUMS.txt").is_file())

    def test_tag_collision_and_incomplete_published_release_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            self.assets(directory)
            for commit, release in (("b" * 40, None), (SHA, {
                    "id": 1, "draft": False, "target_commitish": SHA, "assets": []})):
                calls = []
                def gh(*args):
                    calls.append(args)
                    return {"object": {"type": "commit", "sha": commit}} if "/git/ref/tags/" in args[1] else release
                with self.assertRaises(ValueError):
                    publish(directory, "0.1.1", SHA, "owner/repo", 12, gh=gh)
                self.assertTrue(all(c[0] == "api" for c in calls))

    def test_completed_rerun_is_read_only(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            names = self.assets(directory)
            calls = []
            def gh(*args):
                calls.append(args)
                if "/git/ref/tags/" in args[1]:
                    return {"object": {"type": "commit", "sha": SHA}}
                return {"id": 1, "draft": False, "target_commitish": SHA,
                        "assets": [{"name": n} for n in names]}
            publish(directory, "0.1.1", SHA, "owner/repo", 12, gh=gh)
            self.assertTrue(all(c[0] == "api" for c in calls))

    def test_failed_upload_leaves_release_as_draft(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            self.assets(directory)
            calls = []
            def gh(*args):
                calls.append(args)
                if args[:2] == ('release', 'upload'):
                    raise RuntimeError('network interruption')
                if args[0] == 'api':
                    return None
                return {}
            with self.assertRaises(RuntimeError):
                publish(directory, '0.1.1', SHA, 'owner/repo', 12, gh=gh)
            self.assertFalse(any('--method' in c for c in calls))

    def test_draft_rerun_resumes_without_creating_another_release(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            expected = self.assets(directory)
            calls = []
            def gh(*args):
                calls.append(args)
                if args[0] == 'api' and '/git/ref/tags/' in args[1]:
                    return {'object': {'type': 'commit', 'sha': SHA}}
                if args[0] == 'api' and '/releases/tags/' in args[1]:
                    return {'id': 1, 'draft': True, 'target_commitish': SHA,
                            'assets': [{'name': n} for n in expected]}
                return {}
            publish(directory, '0.1.1', SHA, 'owner/repo', 12, gh=gh)
            self.assertFalse(any(c[:2] == ('release', 'create') for c in calls))
            self.assertTrue(any(c[:2] == ('release', 'upload') for c in calls))
            self.assertIn('draft=false', calls[-1])

    def test_annotated_tag_is_peeled_using_tag_namespace(self):
        calls = []
        def gh(*args):
            calls.append(args)
            if '/git/ref/tags/' in args[1]:
                return {'object': {'type': 'tag', 'sha': 'c' * 40}}
            return {'object': {'type': 'commit', 'sha': SHA}}
        self.assertEqual(tag_commit('owner/repo', 'v0.1.1', gh), SHA)
        self.assertIn('/git/ref/tags/v0.1.1', calls[0][1])
        self.assertIn('/git/tags/', calls[1][1])


if __name__ == "__main__":
    unittest.main()
