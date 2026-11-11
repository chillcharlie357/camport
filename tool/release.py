"""Release only complete artifacts from an exact, merged-main commit."""

import argparse
import hashlib
import json
import os
import re
import subprocess
import time
from pathlib import Path


def eligible_pr(prs, sha, repo=None):
    for pr in prs:
        base = pr.get("base", {})
        if (pr.get("merged_at") and base.get("ref") == "main"
                and pr.get("merge_commit_sha") == sha
                and type(pr.get("number")) is int
                and (repo is None or base.get("repo", {}).get("full_name") == repo)):
            return pr["number"]
    return None


def build_version(pubspec, run_number):
    if type(run_number) is not int or not 1 <= run_number <= 2_100_000_000:
        raise ValueError("Invalid release run number")
    matches = re.findall(r"^version:\s*(\S+)\s*$", pubspec, re.MULTILINE)
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:\+\d+)?", matches[0]) if len(matches) == 1 else None
    if not match:
        raise ValueError("pubspec.yaml must have one numeric major.minor.patch version")
    major, minor, patch = map(int, match.groups())
    return f"{major}.{minor}.{patch + run_number}"


def gh_command(*args):
    result = subprocess.run(["gh", *map(str, args)], text=True,
                            capture_output=True, check=False)
    if result.returncode:
        if (args[0] == "api" and args[1].startswith("repos/")
                and ("/releases/tags/" in args[1] or "/git/ref/tags/" in args[1])
                and "(HTTP 404)" in result.stderr):
            return None
        raise RuntimeError(result.stderr.strip() or "gh command failed")
    if args[0] == "api":
        return json.loads(result.stdout)
    return result.stdout


def digest(path):
    hasher = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def tag_commit(repo, tag, gh):
    ref = gh("api", f"repos/{repo}/git/ref/tags/{tag}")
    if not ref:
        return None
    obj = ref["object"]
    for _ in range(10):
        if obj["type"] == "commit":
            return obj["sha"]
        if obj["type"] != "tag":
            raise ValueError("Release tag does not reference a commit")
        obj = gh("api", f"repos/{repo}/git/tags/{obj['sha']}")["object"]
    raise ValueError("Too many nested annotated tags")


def publish(directory, version, sha, repo, pr_number, gh=gh_command):
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("Invalid version or commit SHA")
    package_names = {f"camport-{version}-{platform}" for platform in
                     ("android.apk", "macos.zip", "windows-x64.zip")}
    generated = {"SHA256SUMS.txt", "BUILD-INFO.json"}
    found = {p.name for p in directory.iterdir()}
    if not package_names <= found or found - package_names - generated:
        raise ValueError("Release requires exactly the Android, macOS and Windows packages")
    if any(p.is_symlink() or not p.is_file() or p.stat().st_size == 0
           for p in directory.iterdir()):
        raise ValueError("Release assets must be nonempty regular files")
    tag = f"v{version}"
    commit = tag_commit(repo, tag, gh)
    if commit and commit != sha:
        raise ValueError("Existing tag points to a different commit")
    release = gh("api", f"repos/{repo}/releases/tags/{tag}")
    expected = package_names | generated
    if release:
        if release["target_commitish"] != sha:
            raise ValueError("Existing release targets a different commit")
        if not release["draft"]:
            if {a["name"] for a in release["assets"]} != expected:
                raise ValueError("Published release is incomplete; refusing to overwrite it")
            print(f"{tag} already published; assets unchanged")
            return
    (directory / "BUILD-INFO.json").write_text(json.dumps({
        "version": version, "commit": sha, "pull_request": pr_number,
        "android": "release signed", "macos": "ad-hoc signed; not notarized",
        "windows": "unsigned x64 bundle", "ios": "compile check only",
    }, indent=2) + "\n", encoding="utf-8")
    checksummed = sorted(package_names | {"BUILD-INFO.json"})
    (directory / "SHA256SUMS.txt").write_text("".join(
        f"{digest(directory / name)}  {name}\n" for name in checksummed), encoding="utf-8")
    if not release:
        gh("release", "create", tag, "--repo", repo, "--target", sha,
           "--title", tag, "--draft", "--generate-notes", "--notes",
           f"PR #{pr_number} · commit `{sha}`\n\n"
           "Android 为固定签名 APK；macOS 为 ad-hoc 签名压缩包（未公证）；"
           "Windows 为未签名 x64 完整运行包。iOS 仅编译检查，无可安装 IPA。\n\n"
           "当前功能与已验证范围请参阅此提交的 README；自动构建不代表相机兼容性验收。")
    gh("release", "upload", tag, "--repo", repo, "--clobber",
       *[str(directory / name) for name in sorted(expected)])
    release = gh("api", f"repos/{repo}/releases/tags/{tag}")
    if not release or {a["name"] for a in release["assets"]} != expected:
        raise ValueError("Draft assets are incomplete; not publishing")
    gh("api", "--method", "PATCH", f"repos/{repo}/releases/{release['id']}",
       "-F", "draft=false", "-f", "make_latest=legacy")


def prepare(pubspec_path=Path("pubspec.yaml")):
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    repo = os.environ["GITHUB_REPOSITORY"]
    sha = os.environ["GITHUB_SHA"]
    if (event.get("ref") != "refs/heads/main" or event.get("deleted")
            or event.get("forced")):
        raise ValueError("Release preparation requires a main branch push")
    pr_number = None
    for attempt in range(6):
        prs = gh_command("api", f"repos/{repo}/commits/{sha}/pulls?per_page=100")
        pr_number = eligible_pr(prs or [], sha, repo)
        if pr_number is not None:
            break
        if attempt < 5:
            time.sleep(5)
    outputs = {"publish": "false"}
    if pr_number is not None:
        run_number = int(os.environ["GITHUB_RUN_NUMBER"])
        version = build_version(pubspec_path.read_text(), run_number)
        outputs.update(publish="true", version=version, build_number=str(run_number),
                       sha=sha, pr_number=str(pr_number))
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as target:
        for key, value in outputs.items():
            target.write(f"{key}={value}\n")
    print(json.dumps(outputs))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("prepare", "publish"))
    parser.add_argument("--assets", type=Path, default=Path("dist"))
    args = parser.parse_args()
    if args.command == "prepare":
        prepare()
    else:
        publish(args.assets, os.environ["RELEASE_VERSION"], os.environ["RELEASE_SHA"],
                os.environ["GITHUB_REPOSITORY"], int(os.environ["RELEASE_PR"]))
