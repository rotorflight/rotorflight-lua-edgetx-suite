#!/usr/bin/env python3
"""The CI test jobs, read from one metadata file per test script.

A plain Lua test script that runs as a job of its own has a `<stem>.ci.json` file next to it:

    bin/telemetry/verify_system_state.ci.json
    bin/telemetry/verify_system_state.lua

A pull request that adds a test script adds those two files in the script's own
directory and nothing else, so two such pull requests no longer collide in a
shared job list. The shape follows rotorflight-lua-ethos-suite #2585 and #2587.

The file holds:

    id         unique, lower-case, used in the job's identity
    name       the job's display name in the Actions UI, unique
    commands   what the job runs, in order, stopping at the first failure. Each is
               `lua5.3 <directory>/<stem>.lua` for the `<stem>.ci.json` it sits
               in, optionally followed by ` --self-test`
    step       optional, the text of the step that runs them
    rationale  optional, why the test script exists

A job with steps of another kind stays written out in checks.yml or pr.yml.

The reader goes red rather than letting a check disappear quietly: on a bad file,
on fewer jobs than MIN_JOBS, and on a test script under bin/ that has no metadata
and that no workflow names. A script that is deliberately not a CI job goes in
NOT_CI_JOBS, with the reason.

Commands:

    python bin/ci/test_jobs.py --self-test      prove the reader can go red
    python bin/ci/test_jobs.py                  print the jobs as JSON
    python bin/ci/test_jobs.py --github-output  write the job matrix to $GITHUB_OUTPUT
"""

import json
import os
import re
import shutil
import sys
import tempfile
from collections import namedtuple

TestJob = namedtuple("TestJob", "id name step commands rationale")

REQUIRED = ("id", "name", "commands")
OPTIONAL = ("step", "rationale")
DEFAULT_STEP = "Run the check"
ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]*$")

# What counts as a test script, wherever it sits under bin/.
TEST_FILE = re.compile(r"^bin/(?:.+/)?(?:verify_[^/]+\.(?:lua|py)|[^/]+_test\.lua)$")
WORKFLOWS = (".github/workflows/checks.yml", ".github/workflows/pr.yml")
# A script a written-out step runs: the first argument of an interpreter, at the start of a command.
# A comment or a step's name that mentions a script runs nothing, so neither counts.
WORKFLOW_PATH = re.compile(r"(?m)^[ \t]*(?:-[ \t]+)?(?:run:[ \t]+)?(?:lua5\.3|python3?)[ \t]+(bin/[\w./-]+\.(?:lua|py))")

# A floor, not a count: it stays put when a test script is added, and only has to be
# raised by hand to tighten it. It catches a search that quietly finds too little.
MIN_JOBS = 75

# Test scripts that are deliberately not CI jobs: path -> why.
NOT_CI_JOBS = {}


class RegisterError(Exception):
    pass


def _rel(path, root):
    return os.path.relpath(path, root).replace("\\", "/")


def _text(rel, data, key):
    value = data.get(key)
    if not isinstance(value, str):
        raise RegisterError("%s: %r must be a string" % (rel, key))
    if key != "rationale" and (not value.strip() or "\n" in value):
        raise RegisterError("%s: %r must be one line of text" % (rel, key))
    return value


def load_one(path, root):
    """Parse and check one `<stem>.ci.json`. Returns a TestJob or raises RegisterError."""
    rel = _rel(path, root)
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as err:
        raise RegisterError("%s: not readable JSON (%s)" % (rel, err))
    if not isinstance(data, dict):
        raise RegisterError("%s: must be a JSON object" % rel)

    missing = [key for key in REQUIRED if key not in data]
    if missing:
        raise RegisterError("%s: missing %s" % (rel, ", ".join(missing)))
    extra = sorted(set(data) - set(REQUIRED) - set(OPTIONAL))
    if extra:
        raise RegisterError("%s: unknown keys %s" % (rel, ", ".join(extra)))

    job_id = _text(rel, data, "id")
    if not ID_PATTERN.match(job_id):
        raise RegisterError("%s: id %r must be lower-case letters, digits and dashes" % (rel, job_id))
    name = _text(rel, data, "name")
    step = _text(rel, data, "step") if "step" in data else DEFAULT_STEP
    rationale = _text(rel, data, "rationale") if "rationale" in data else ""

    script = rel[: -len(".ci.json")] + ".lua"
    if not os.path.isfile(os.path.join(root, script)):
        raise RegisterError("%s: script %s does not exist" % (rel, script))
    commands = data["commands"]
    allowed = ("lua5.3 " + script, "lua5.3 " + script + " --self-test")
    if not isinstance(commands, list) or not commands:
        raise RegisterError("%s: 'commands' must be a list of at least one" % rel)
    for command in commands:
        if command not in allowed:
            raise RegisterError("%s: a command must be one of %s, got %r" % (rel, " | ".join(allowed), command))
    if len(set(commands)) != len(commands):
        raise RegisterError("%s: 'commands' repeats itself" % rel)

    return TestJob(job_id, name, step, commands, rationale)


def _files_under(root, subdir):
    found = []
    for dirpath, _, files in os.walk(os.path.join(root, subdir)):
        found.extend(os.path.join(dirpath, f) for f in files)
    return sorted(found)


def discover(root):
    """Every CI test script anywhere under bin/, sorted by path. Raises RegisterError on the first bad file."""
    jobs, ids, names = [], {}, {}
    for path in _files_under(root, "bin"):
        if not path.endswith(".ci.json"):
            continue
        rel = _rel(path, root)
        job = load_one(path, root)
        if job.id in ids:
            raise RegisterError("id %r is used twice: %s and %s" % (job.id, ids[job.id], rel))
        if job.name in names:
            raise RegisterError("name %r is used twice: %s and %s" % (job.name, names[job.name], rel))
        ids[job.id] = names[job.name] = rel
        jobs.append(job)
    return jobs


def check_complete(root, jobs, not_ci_jobs=None):
    """Refuse a test script under bin/ that no job and no workflow runs."""
    not_ci_jobs = NOT_CI_JOBS if not_ci_jobs is None else not_ci_jobs
    tests = {_rel(p, root) for p in _files_under(root, "bin")}
    tests = {p for p in tests if TEST_FILE.match(p)}
    covered = set()
    for job in jobs:
        for command in job.commands:
            covered.add(command.split()[1])
    for workflow in WORKFLOWS:
        path = os.path.join(root, workflow)
        if os.path.isfile(path):
            with open(path, "r", encoding="utf-8") as f:
                covered.update(WORKFLOW_PATH.findall(f.read()))
    stale = sorted(p for p in not_ci_jobs if p not in tests or p in covered)
    if stale:
        raise RegisterError("NOT_CI_JOBS names %s, which is gone or does run" % ", ".join(stale))
    lost = sorted(tests - covered - set(not_ci_jobs))
    if lost:
        raise RegisterError("no CI job runs %s: add a `.ci.json` beside it, or say why not in NOT_CI_JOBS"
                           % ", ".join(lost))


def load_register(root, min_jobs=None, not_ci_jobs=None):
    """The jobs of a tree, refused if the search found too little."""
    min_jobs = MIN_JOBS if min_jobs is None else min_jobs
    jobs = discover(root)
    if not jobs:
        raise RegisterError("no `.ci.json` found under bin/")
    if len(jobs) < min_jobs:
        raise RegisterError("%d test jobs found, expected at least %d" % (len(jobs), min_jobs))
    check_complete(root, jobs, not_ci_jobs)
    return jobs


def entry(job):
    return {"id": job.id, "name": job.name, "step": job.step, "run": "\n".join(job.commands)}


def matrix_for(jobs):
    """The strategy.matrix value for the test job.

    A strategy.matrix is an object, so the jobs go under "include". GitHub refuses a
    bare list, and then the test job never starts.
    """
    return {"include": [entry(j) for j in jobs]}


def _write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        if isinstance(data, str):
            f.write(data)
        else:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.write("\n")


SAMPLE_SCRIPT = "bin/sample/verify_sample.lua"
SAMPLE_META = "bin/sample/verify_sample.ci.json"
_VALID = {
    "id": "sample-job",
    "name": "A sample job",
    "commands": ["lua5.3 " + SAMPLE_SCRIPT + " --self-test", "lua5.3 " + SAMPLE_SCRIPT],
}


def self_test():
    """Check that the reader accepts a good tree and refuses each bad one, on scratch trees and on this one."""
    failures = []
    roots = []

    def report(label, ok):
        if not ok:
            failures.append(label)
        print("  %s  %s" % ("ok  " if ok else "FAIL", label))

    def tree(files):
        root = tempfile.mkdtemp(prefix="testjobs-selftest-")
        roots.append(root)
        for rel, data in files.items():
            _write(os.path.join(root, *rel.split("/")), data)
        return root

    def accepts(root, min_jobs, not_ci_jobs):
        try:
            load_register(root, min_jobs, not_ci_jobs)
            return True
        except RegisterError:
            return False

    def check(label, ok, metadata=_VALID, script=True, extra=None, min_jobs=1, not_ci_jobs=None):
        files = {}
        if script:
            files[SAMPLE_SCRIPT] = "-- sample\n"
        if metadata is not None:
            files[SAMPLE_META] = metadata
        files.update(extra or {})
        report(label, accepts(tree(files), min_jobs, not_ci_jobs or {}) == ok)

    check("a valid test script is accepted", True)
    check("only the required fields are enough", True, {k: _VALID[k] for k in REQUIRED})
    check("a test script one directory deeper is found", True, None, False, {
        "bin/a/b/verify_c.lua": "-- c\n",
        "bin/a/b/verify_c.ci.json": dict(_VALID, commands=["lua5.3 bin/a/b/verify_c.lua"]),
    })
    check("no test job at all is refused", False, None, False)
    check("fewer jobs than the floor are refused", False, min_jobs=2)
    check("a missing field is refused", False, {k: v for k, v in _VALID.items() if k != "commands"})
    check("an unknown field is refused", False, dict(_VALID, extra="x"))
    check("broken JSON is refused", False, "{ not json")
    check("an empty name is refused", False, dict(_VALID, name="  "))
    check("a multi-line step is refused", False, dict(_VALID, step="a\nb"))
    check("an id with capitals is refused", False, dict(_VALID, id="Sample"))
    check("empty commands are refused", False, dict(_VALID, commands=[]))
    check("a command for another script is refused", False,
          dict(_VALID, commands=["lua5.3 bin/sample/other.lua"]))
    check("a command with shell in it is refused", False,
          dict(_VALID, commands=["lua5.3 " + SAMPLE_SCRIPT + " || true"]))
    check("a repeated command is refused", False,
          dict(_VALID, commands=["lua5.3 " + SAMPLE_SCRIPT, "lua5.3 " + SAMPLE_SCRIPT]))
    check("a script that does not exist is refused", False, script=False)

    two = {
        "bin/a/verify_a.lua": "-- a\n",
        "bin/b/verify_b.lua": "-- b\n",
        "bin/a/verify_a.ci.json": dict(_VALID, id="a", name="A", commands=["lua5.3 bin/a/verify_a.lua"]),
        "bin/b/verify_b.ci.json": dict(_VALID, id="b", name="B", commands=["lua5.3 bin/b/verify_b.lua"]),
    }
    check("two distinct test scripts are accepted", True, None, False, two)
    check("two test scripts with the same id are refused", False, None, False,
          dict(two, **{"bin/b/verify_b.ci.json": dict(two["bin/b/verify_b.ci.json"], id="a")}))
    check("two test scripts with the same name are refused", False, None, False,
          dict(two, **{"bin/b/verify_b.ci.json": dict(two["bin/b/verify_b.ci.json"], name="A")}))

    lost = {"bin/sample/verify_lost.lua": "-- lost\n"}
    check("a test script no job runs is refused", False, extra=lost)
    check("a _test.lua no job runs is refused", False, extra={"bin/sample/lost_test.lua": "-- lost\n"})
    check("a helper that is no test script is ignored", True, extra={"bin/sample/helper.lua": "-- helper\n"})
    check("a test script a workflow names is accepted", True, extra=dict(lost, **{
        WORKFLOWS[0]: "      - run: lua5.3 bin/sample/verify_lost.lua\n"}))
    check("a test script only a comment names is refused", False, extra=dict(lost, **{
        WORKFLOWS[0]: "      # - run: lua5.3 bin/sample/verify_lost.lua\n"}))
    check("a test script only a step's name mentions is refused", False, extra=dict(lost, **{
        WORKFLOWS[0]: "      - name: lua5.3 bin/sample/verify_lost.lua\n        run: echo disabled\n"}))
    check("a test script a multi-line run block names is accepted", True, extra=dict(lost, **{
        WORKFLOWS[0]: "      - run: |\n          lua5.3 bin/sample/verify_lost.lua\n"}))
    check("a test script named in NOT_CI_JOBS is accepted", True, extra=lost,
          not_ci_jobs={"bin/sample/verify_lost.lua": "why"})
    check("NOT_CI_JOBS naming a script that is gone is refused", False,
          not_ci_jobs={"bin/sample/verify_gone.lua": "why"})
    check("NOT_CI_JOBS naming a script that does run is refused", False,
          not_ci_jobs={SAMPLE_SCRIPT: "why"})

    # The matrix the workflow gets: an object with the jobs under "include".
    matrix = matrix_for(discover(tree({SAMPLE_SCRIPT: "-- sample\n", SAMPLE_META: _VALID})))
    report("the matrix is an object with the jobs under include",
           isinstance(matrix, dict) and list(matrix) == ["include"] and len(matrix["include"]) == 1)
    report("the matrix runs the commands in order, one per line",
           matrix["include"][0]["run"] == "\n".join(_VALID["commands"]))
    report("a step that names no text gets the default", matrix["include"][0]["step"] == DEFAULT_STEP)

    # This tree's own register, not a fixture: taking any one job away must be noticed.
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    jobs = discover(root)
    try:
        check_complete(root, jobs)
        report("this tree's register is complete", True)
    except RegisterError as err:
        report("this tree's register is complete (%s)" % err, False)
    try:
        check_complete(root, jobs[1:])
        report("this tree's register without its first job is refused", False)
    except RegisterError:
        report("this tree's register without its first job is refused", True)

    for scratch in roots:
        shutil.rmtree(scratch, ignore_errors=True)

    if failures:
        print("FAILED: %s" % ", ".join(failures))
        return 1
    print("ALL CHECKS PASSED")
    return 0


def main(argv):
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    if "--self-test" in argv:
        return self_test()
    try:
        jobs = load_register(root)
    except RegisterError as err:
        print("test job metadata: %s" % err, file=sys.stderr)
        return 1
    if "--github-output" in argv:
        out = os.environ.get("GITHUB_OUTPUT")
        line = "matrix=%s\n" % json.dumps(matrix_for(jobs), separators=(",", ":"))
        if out:
            with open(out, "a", encoding="utf-8") as f:
                f.write(line)
        else:
            sys.stdout.write(line)
        print("%d test jobs" % len(jobs))
        return 0
    print(json.dumps([entry(j) for j in jobs], indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
