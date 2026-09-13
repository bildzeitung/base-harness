"""Dev-only tests of the harness's internals -- run from the export checkout,
never installed into a project.

The modules here import the same helpers the shipped suite uses
(``from conftest import ...``, ``_gitrepo``, ``_hookharness``), so this
conftest puts ``template/tests/harness`` on ``sys.path`` and re-exports the
shipped conftest wholesale under this module's name. ``REPO_ROOT`` therefore
resolves to ``template/`` -- the harness under test -- exactly as it does for
the shipped suite once installed.

Run:

    cd template && uv run --frozen pytest ../dev-tests -q
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

_HARNESS_TESTS = (
    Path(__file__).resolve().parent.parent / "template" / "tests" / "harness"
)
if str(_HARNESS_TESTS) not in sys.path:
    sys.path.insert(0, str(_HARNESS_TESTS))

_spec = importlib.util.spec_from_file_location(
    "_harness_conftest", _HARNESS_TESTS / "conftest.py"
)
assert _spec is not None and _spec.loader is not None
_shipped = importlib.util.module_from_spec(_spec)
sys.modules["_harness_conftest"] = _shipped
_spec.loader.exec_module(_shipped)

# Re-export everything public, including the pytest hooks (``pytest_configure``
# registers the ``serial`` marker) and fixtures, so a dev module reads exactly
# like a shipped one.
globals().update(
    {name: value for name, value in vars(_shipped).items() if not name.startswith("__")}
)
