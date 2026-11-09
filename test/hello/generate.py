import sys

with open(sys.argv[1], "w") as f:
    v = sys.version_info
    f.write(f'#define HELLO_GENERATED "python {v.major}.{v.minor}"\n')
