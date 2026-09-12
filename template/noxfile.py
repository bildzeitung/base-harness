"""Nox sessions the agent harness invokes as its quality gates.

The harness treats these as opaque commands behind a 0/1/2 exit contract
(0 = passed, 1 = found a real problem, 2 = COULD NOT RUN). A session that lets
nox report a failed command exits 1, which is correct for `fix` and `tests`: a
missing formatter is a setup error the agent should surface, not a gate verdict.
Sessions that shell out to something that can be *absent* (docker, the network,
uv) must distinguish exit 2 themselves, by raising it through `sys.exit(2)`,
which nox passes through unchanged -- `lock_currency` below is the worked
example, and scripts/validate-mermaid.sh the shell-side reference.

Replace the bodies with your project's real tooling; keep the NAMES and the `fix`
tag, since the agent files invoke `nox -t fix`, `nox -s tests`, and
`nox -s lock_currency` by those exact handles.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

import nox

nox.options.default_venv_backend = "none"  # the harness owns ./venv

#: Test-worker count. scripts/code-concurrency-cap.sh greps THIS FILE for the
#: literal below to size its per-agent memory budget, so keep the shape
#: `os.environ.get("HARNESS_TEST_WORKERS") or "<n>"` if you change the default.
TEST_WORKERS = os.environ.get("HARNESS_TEST_WORKERS") or "8"


def _venv_tool(name: str) -> str:
    """Resolve a tool under ./venv/bin without requiring activation.

    Load-bearing: the isolation guard refuses any sourced command, so agents call
    `./venv/bin/nox` directly and never activate. Resolving tools here is what
    makes that work.
    """
    return os.path.join(".", "venv", "bin", name)


@nox.session(tags=["fix"])
def format_and_lint(session: nox.Session) -> None:
    """Format and lint, fixing in place."""
    session.run(_venv_tool("ruff"), "format", ".", external=True)
    session.run(_venv_tool("ruff"), "check", "--fix", ".", external=True)


@nox.session
def tests(session: nox.Session) -> None:
    """The test suite.

    Two invocations that exhaustively partition the suite on
    ``@pytest.mark.serial`` (registered in tests/conftest.py): everything else
    in the pytest-xdist parallel pool, then the serial tests with no workers at
    all. A ``serial`` test asserts a wall-clock budget that sibling workers'
    scheduler noise would make flaky. No test is skipped and none runs twice —
    the partition is the only thing the marker changes.
    """
    pytest = _venv_tool("pytest")
    session.run(
        pytest,
        "-q",
        "-m",
        "not serial",
        "-n",
        TEST_WORKERS,
        *session.posargs,
        external=True,
    )
    session.run(
        pytest, "-q", "-m", "serial", "-n", "0", *session.posargs, external=True
    )


def _lock_pins(path: Path) -> list[str]:
    """The pin lines of a lock file: uv writes its own invocation into the
    header, so comparing bytes would never match two compiles."""
    return [
        line
        for line in path.read_text().splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


@nox.session
def lock_currency(session: nox.Session) -> None:
    """Fail if requirements.lock is stale against pyproject.toml.

    Recompiles through scripts/compile-lock.sh (the single copy of the
    command) into a scratch file SEEDED from the committed lock -- uv keeps an
    existing output file's pins wherever they still satisfy pyproject.toml, so
    only a changed intent moves the result; an upstream release alone does not
    (that is scripts/update-deps.sh's job, on purpose). Exit 1 = stale, a real
    finding. Exit 2 = could not answer: no ./venv/bin/uv, no .python-version,
    a failed compile. Raised with sys.exit so it reaches the caller intact.

    /land runs this LAST in its re-gate `&&` chain: an `&&` chain reports its
    last-run command's status, so anything after it would mask an exit 2.
    """
    uv = Path(_venv_tool("uv")).resolve()
    if not uv.exists():
        session.log("lock_currency: %s is missing -- run scripts/python-init.sh", uv)
        sys.exit(2)
    lock = Path("requirements.lock")
    if not lock.exists():
        session.error(
            "lock_currency: requirements.lock is missing -- scripts/compile-lock.sh -o requirements.lock"
        )
    with tempfile.TemporaryDirectory() as tmp:
        candidate = Path(tmp) / "requirements.lock"
        candidate.write_text(lock.read_text())
        # compile-lock.sh finds uv on PATH; the venv's is the one that matches
        # the lock, so it goes first.
        env = {
            **os.environ,
            "PATH": os.pathsep.join([str(uv.parent), os.environ.get("PATH", "")]),
        }
        proc = subprocess.run(
            ["bash", "scripts/compile-lock.sh", "-q", "-o", str(candidate)],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode != 0:
            session.log(
                "lock_currency: compile-lock.sh failed (exit %d):\n%s",
                proc.returncode,
                proc.stderr.strip(),
            )
            sys.exit(2)
        if _lock_pins(candidate) != _lock_pins(lock):
            session.error(
                "requirements.lock is stale against pyproject.toml -- "
                "regenerate: scripts/compile-lock.sh -o requirements.lock"
            )
