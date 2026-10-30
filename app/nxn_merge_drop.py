"""Run nxn_merge.py with some games left out: Switch Pad's "remove a game from a merged package".

Usage: python nxn_merge_drop.py <nxn_merge.py> <title IDs, comma-separated> <nxn_merge.py's own arguments...>

nxn_merge.py takes every game of every input. This loads it as a module and filters the games it reads from the
inputs, so the rest (the picker icon, Info.plist, each game's files copied without recompressing) is nxn_merge.py's
own work, whichever version of it Switch Pad found.
"""
import importlib.util
import sys

merge, drop = sys.argv[1], {t.strip().upper() for t in sys.argv[2].split(',') if t.strip()}
spec = importlib.util.spec_from_file_location('nxn_merge', merge)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
games_in = m.games_in
m.games_in = lambda z: [g for g in games_in(z) if g.tid.upper() not in drop]
sys.argv = [merge] + sys.argv[3:]
m.main()
