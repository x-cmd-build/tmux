#!/usr/bin/env python3
"""Extract a Windows zip into a target subdir, normalizing backslashes
to forward slashes and creating a top-level dir layout that matches
the Linux/macOS tarball.

Used by: .github/workflows/release-test.yml (x86_64-windows)
"""
import sys, os, zipfile

src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as z:
    for name in z.namelist():
        # Normalize backslashes (Windows-zip uses \ as path sep)
        n = name.replace("\\", "/")
        if n.endswith("/"):
            os.makedirs(os.path.join(dst, n), exist_ok=True)
        else:
            target = os.path.join(dst, n)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with z.open(name) as src_f, open(target, "wb") as dst_f:
                dst_f.write(src_f.read())