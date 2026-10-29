import sys
from pathlib import Path

import pytest

TOOLS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOOLS))

FIXTURES = TOOLS.parent / "BarPath" / "BarPathKit" / "Tests" / "BarPathKitTests" / "Fixtures"


@pytest.fixture(scope="session")
def fixtures_dir():
    return FIXTURES
