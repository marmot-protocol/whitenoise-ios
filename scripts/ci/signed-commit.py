#!/usr/bin/env python3
"""Commit working-tree changes on a new branch through GitHub's API, so GitHub signs them.

Every branch in this repository requires signed commits, and a plain `git commit` in
Actions is unsigned. `createCommitOnBranch` makes a commit GitHub signs, from the
files' current contents on disk.

Usage (needs `gh` authenticated, e.g. GH_TOKEN):
  scripts/ci/signed-commit.py --repo OWNER/NAME --branch BRANCH --base SHA \
      --message "Headline" [--body-file FILE] PATH...

BRANCH must not exist: it is created at SHA and gets one commit holding every PATH (a
PATH that exists is added with its current contents, a missing one is deleted). Prints
the new commit's SHA. The caller moves the branch it means to update onto that commit
with a lease (`git push --force-with-lease`), so nothing pushed meanwhile is lost, and
deletes BRANCH.
"""

import argparse
import base64
import json
import pathlib
import subprocess
import sys
import tempfile


def gh(*args, input_text=None):
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True, input=input_text).stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--branch", required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--message", required=True)
    parser.add_argument("--body-file")
    parser.add_argument("paths", nargs="+")
    args = parser.parse_args()

    gh("api", "-X", "POST", f"repos/{args.repo}/git/refs", "-f", f"ref=refs/heads/{args.branch}", "-f", f"sha={args.base}")

    additions, deletions = [], []
    for path in args.paths:
        file = pathlib.Path(path)
        if file.is_file():
            additions.append({"path": path, "contents": base64.b64encode(file.read_bytes()).decode()})
        else:
            deletions.append({"path": path})

    message = {"headline": args.message}
    if args.body_file:
        message["body"] = pathlib.Path(args.body_file).read_text()
    request = {
        "query": """
            mutation($input: CreateCommitOnBranchInput!) {
              createCommitOnBranch(input: $input) { commit { oid } }
            }""",
        "variables": {
            "input": {
                "branch": {"repositoryNameWithOwner": args.repo, "branchName": args.branch},
                "message": message,
                "fileChanges": {"additions": additions, "deletions": deletions},
                "expectedHeadOid": args.base,
            }
        },
    }
    with tempfile.NamedTemporaryFile("w", suffix=".json") as body:
        json.dump(request, body)
        body.flush()
        result = json.loads(gh("api", "graphql", "--input", body.name))
    if result.get("errors"):
        print(json.dumps(result["errors"]), file=sys.stderr)
        sys.exit(1)
    print(result["data"]["createCommitOnBranch"]["commit"]["oid"])


if __name__ == "__main__":
    main()
