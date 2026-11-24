#!/usr/bin/env python3
#
# Download one export template of the Godot release pinned in
# scripts/GODOT_VERSION.txt, without downloading the rest.
#
# Godot publishes its export templates as a single archive of over a gigabyte
# (Godot_v<version>_export_templates.tpz, a zip). The Web demo that
# build-pages.{sh,ps1} exports needs one member of it, about a hundredth of the
# size, so this reads the archive's directory and that one member over HTTP
# range requests, and zipfile checks the member's CRC as it reads it.
#
# Usage: scripts/fetch-godot-template.py <template> [out=<dir>] [force=yes]
#   template : the member's name under templates/ in the archive,
#              e.g. web_dlink_nothreads_release.zip
#   out      : directory to write it to
#              (default: scripts/.godot-cache/templates/<version>/)
#   force    : yes to download it again when it is already there
#
# The path of the template is the last line on stdout; everything else goes
# to stderr. Standard library only.
import io
import os
import sys
import urllib.error
import urllib.request
import zipfile

APP = os.path.basename(sys.argv[0])
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


def fail(message, code=1):
    print(f"{APP}: {message}", file=sys.stderr)
    sys.exit(code)


def usage():
    with open(os.path.abspath(__file__), encoding="utf-8") as f:
        lines = f.read().splitlines()
    start = next(i for i, line in enumerate(lines) if line.startswith("# Usage:"))
    for line in lines[start:]:
        if not line.startswith("#"):
            break
        print(line[2:])


class RangeFile(io.RawIOBase):
    """A read-only, seekable view of a remote file, read in blocks by HTTP Range."""

    BLOCK = 8 << 20

    def __init__(self, url):
        self.url = url
        self.pos = 0
        self.block_start = 0
        self.block = b""
        request = urllib.request.Request(url, method="HEAD")
        with urllib.request.urlopen(request) as response:
            self.size = int(response.headers["Content-Length"])

    def readable(self):
        return True

    def seekable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, offset, whence=io.SEEK_SET):
        base = {io.SEEK_SET: 0, io.SEEK_CUR: self.pos, io.SEEK_END: self.size}[whence]
        self.pos = base + offset
        return self.pos

    def _fetch(self, start):
        end = min(start + self.BLOCK, self.size) - 1
        request = urllib.request.Request(self.url, headers={"Range": f"bytes={start}-{end}"})
        with urllib.request.urlopen(request) as response:
            # A server that ignores Range answers 200 with the whole archive.
            if response.status != 206:
                fail(f"the server ignored a range request (HTTP {response.status}): {self.url}")
            self.block = response.read()
        self.block_start = start

    def read(self, n=-1):
        if n is None or n < 0:
            n = self.size - self.pos
        out = bytearray()
        while n > 0 and self.pos < self.size:
            offset = self.pos - self.block_start
            if not 0 <= offset < len(self.block):
                self._fetch(self.pos)
                offset = 0
            chunk = self.block[offset:offset + n]
            out += chunk
            self.pos += len(chunk)
            n -= len(chunk)
        return bytes(out)


def main(argv):
    template = None
    out_dir = None
    force = "no"
    for item in argv:
        if item in ("-h", "--help", "help"):
            usage()
            return
        if item.startswith("out="):
            out_dir = item[len("out="):]
        elif item.startswith("force="):
            force = item[len("force="):].lower()
        elif "=" in item or template is not None:
            fail(f"unknown argument '{item}' (see {APP} --help)", 2)
        else:
            template = item
    if template is None:
        fail(f"name the template to fetch (see {APP} --help)", 2)
    if force not in ("yes", "no"):
        fail(f"force must be yes or no (got '{force}')", 2)

    with open(os.path.join(SCRIPT_DIR, "GODOT_VERSION.txt"), encoding="utf-8") as f:
        version = f.read().strip()
    if out_dir is None:
        out_dir = os.path.join(SCRIPT_DIR, ".godot-cache", "templates", version)
    path = os.path.join(out_dir, template)

    if os.path.isfile(path) and force != "yes":
        print(f"{APP}: {template} ({version}) is already in {out_dir}", file=sys.stderr)
        print(path)
        return

    url = (f"https://github.com/godotengine/godot-builds/releases/download/"
           f"{version}/Godot_v{version}_export_templates.tpz")
    print(f"{APP}: reading {template} out of {url}", file=sys.stderr)
    try:
        with zipfile.ZipFile(RangeFile(url)) as archive:
            try:
                info = archive.getinfo(f"templates/{template}")
            except KeyError:
                fail(f"Godot {version}'s export templates have no {template}")
            os.makedirs(out_dir, exist_ok=True)
            part = path + ".part"
            with archive.open(info) as src, open(part, "wb") as dst:
                dst.write(src.read())
            os.replace(part, path)
    except urllib.error.URLError as e:
        fail(f"could not read {url}: {e}")
    print(f"{APP}: {template} ({info.file_size} bytes) -> {out_dir}", file=sys.stderr)
    print(path)


if __name__ == "__main__":
    main(sys.argv[1:])
