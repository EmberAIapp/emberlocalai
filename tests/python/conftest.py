"""Shared fixtures for ANEForge tests."""

import sys
from pathlib import Path

# Ensure aneforge is importable
project_root = Path(__file__).parent.parent.parent
python_dir = project_root / "python"
if str(python_dir) not in sys.path:
    sys.path.insert(0, str(python_dir))
