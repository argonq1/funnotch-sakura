#!/usr/bin/env python3
"""Sample macOS process CPU deltas and physical memory footprint locally."""
import argparse
import ctypes
import json
import subprocess
import time
from pathlib import Path

FIELDS = ['user', 'system', 'pkg_idle_wkups', 'interrupt_wkups', 'pageins', 'wired',
          'resident', 'footprint', 'start', 'exit', 'child_user', 'child_system',
          'child_pkg', 'child_interrupt', 'child_pageins', 'child_elapsed', 'read', 'written']
class Usage(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_ubyte * 16)] + [(s, ctypes.c_uint64) for s in FIELDS]
class Timebase(ctypes.Structure):
    _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]

parser = argparse.ArgumentParser()
parser.add_argument('--pid', type=int)
parser.add_argument('--seconds', type=int, default=20)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--label', default='')
args = parser.parse_args()
pid = args.pid or int(subprocess.check_output(['pgrep', '-x', 'FunNotch']).split()[0])
lib = ctypes.CDLL('/usr/lib/libproc.dylib')
base = Timebase()
ctypes.CDLL('/usr/lib/libSystem.B.dylib').mach_timebase_info(ctypes.byref(base))
ns_per_tick = base.numer / base.denom
rows = []
ps_before = subprocess.check_output(['ps', '-p', str(pid), '-o', 'time=']).decode().strip()
for i in range(args.seconds + 1):
    usage = Usage()
    if lib.proc_pid_rusage(pid, 2, ctypes.byref(usage)) != 0:
        raise RuntimeError('proc_pid_rusage failed')
    rows.append({'t': time.monotonic(), **{s: getattr(usage, s) for s in FIELDS}})
    if i < args.seconds:
        time.sleep(1)
ps_after = subprocess.check_output(['ps', '-p', str(pid), '-o', 'time=']).decode().strip()
a, b = rows[0], rows[-1]
elapsed = b['t'] - a['t']
result = {
    'label': args.label, 'pid': pid, 'seconds': elapsed, 'ns_per_tick': ns_per_tick,
    'cpu_percent': ((b['user'] + b['system']) - (a['user'] + a['system'])) * ns_per_tick / 1e9 / elapsed * 100,
    'footprint_MiB': round(b['footprint'] / 1048576, 2),
    'footprint_range_MiB': [round(min(r['footprint'] for r in rows) / 1048576, 2), round(max(r['footprint'] for r in rows) / 1048576, 2)],
    'resident_MiB': round(b['resident'] / 1048576, 2),
    'read_bytes': b['read'] - a['read'], 'written_bytes': b['written'] - a['written'],
    'wakeups_per_second': (b['interrupt_wkups'] - a['interrupt_wkups']) / elapsed,
    'ps_cpu_time': [ps_before, ps_after], 'samples': rows,
}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(result, indent=2))
print(json.dumps({k: v for k, v in result.items() if k != 'samples'}, ensure_ascii=False))
