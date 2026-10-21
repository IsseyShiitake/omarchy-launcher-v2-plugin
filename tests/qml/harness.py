"""Build (once) and locate the QML harness the tests load."""
import hashlib
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))


def build():
    """Return the directory holding Harness.qml, building it if needed.

    The harness is derived from files/Menu.qml, so it is cached under the
    system temp directory keyed by that file's mtime and size: editing Menu.qml
    rebuilds it, running the suite twice does not.
    """
    src = os.path.join(REPO, "files", "Menu.qml")
    if not os.path.isfile(src):
        sys.exit("Menu.qml not found at " + src + " — run this from the repository")
    stat = os.stat(src)
    key = hashlib.sha1(("%s:%s:%s" % (src, int(stat.st_mtime), stat.st_size)).encode()).hexdigest()[:12]
    out = os.path.join(tempfile.gettempdir(), "omarchy-launcher-harness", key)
    if not os.path.isfile(os.path.join(out, "Harness.qml")):
        subprocess.check_call([sys.executable, os.path.join(HERE, "extract.py"), src, out])
    return out
