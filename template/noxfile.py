"""Nox sessions the agent harness invokes as its quality gates.

The harness treats these as opaque commands behind a 0/1/2 exit contract
(0 = passed, 1 = found a real problem, 2 = COULD NOT RUN). Nox itself only ever
returns 0 or 1, which is correct for `fix` and `tests`: a missing formatter is a
setup error the agent should surface, not a gate verdict. Sessions that shell out
to something that can be *absent* (docker, the network) must distinguish exit 2
themselves -- see scripts/validate-mermaid.sh for the reference implementation.

Replace the bodies with your project's real tooling; keep the NAMES and the `fix`
tag, since the agent files invoke `nox -t fix`, `nox -s tests`, and
`nox -s lock_currency` by those exact handles.
"""

from __future__ import annotations

import os

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
    """The test suite."""
    session.run(_venv_tool("pytest"), "-q", "-n", TEST_WORKERS, *session.posargs, external=True)


@nox.session
def lock_currency(session: nox.Session) -> None:
    """Fail if requirements.lock is stale against pyproject.toml.

    /land runs this LAST in its re-gate `&&` chain: an `&&` chain reports its
    last-run command's status, so anything after it would mask an exit 2.
    """
    session.run(_venv_tool("python"), "scripts/compile-lock.sh", "--check", external=True, success_codes=[0, 1, 2])
