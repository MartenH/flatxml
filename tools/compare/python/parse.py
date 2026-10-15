"""The Python harness for tools/compare/run.sh: read the file, then time the parse of the bytes.

    python3 parse.py lxml|elementtree <file>
"""
import sys
import time

which, path = sys.argv[1], sys.argv[2]
if which == 'lxml':
    from lxml import etree as parser
else:
    import xml.etree.ElementTree as parser
with open(path, 'rb') as f:
    data = f.read()
t = time.perf_counter()
parser.fromstring(data)
s = time.perf_counter() - t
print(f'{which}: {s * 1e3:.1f} ms, {len(data) / 1048576 / s:.0f} MB/s')
