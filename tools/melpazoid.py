"""Run melpazoid's checks of a recipe, but for its container build.

Run by `make melpazoid' in our image, so melpazoid.py, the emacs it calls
and the network it uses are not the host's.  Where melpazoid would build
and run its own image, from the host, this only writes what that image
is built from into the working directory: the package in pkg/,
_requirements.el, _native_deps, and package-main, the main file's name
when there are several.  The Makefile builds and runs the image from
those, as melpazoid's own Makefile does.

Usage: python3 -I tools/melpazoid.py MELPAZOID-CHECKOUT
with RECIPE and LOCAL_REPO set, as for melpazoid.py.
"""

import importlib.util
import os
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    'melpazoid', Path(sys.argv[1]) / 'melpazoid' / 'melpazoid.py'
)
melpazoid = importlib.util.module_from_spec(spec)
spec.loader.exec_module(melpazoid)
melpazoid._PKG_PATH = Path.cwd() / 'pkg'


def write_build_files(recipe: str, repo: Path) -> None:
    """Do what `check_containerized_build' does up to building the image."""
    files = melpazoid._extract_files_to_pkg(recipe, repo)
    if not files:
        return
    melpazoid._write_requirements(melpazoid.package_name(recipe), files)
    main_file = melpazoid._main_file(files, recipe)
    several = sum(f.name.endswith('.el') for f in melpazoid._PKG_PATH.iterdir()) > 1
    Path('package-main').write_text(main_file.name if main_file and several else '')


melpazoid.check_containerized_build = write_build_files
melpazoid.check_melpa_recipe(os.environ['RECIPE'])
sys.exit(melpazoid._return_code())
