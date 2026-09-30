"""Add project root to sys.path so tests can import backend modules."""
import os
import sys

# Get the absolute path to the project root (one level above this 'tests/' dir)
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)
