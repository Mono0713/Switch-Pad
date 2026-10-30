"""Give an IPA with an empty RomFS a placeholder file.

The shell only accepts a non-empty romfs folder (dm/ios/Sources/main.m, romfs_locate under DM_SHELL),
but games whose assets live in main (ANIMAL WELL) have an empty RomFS by design, so the app stops at
"Game files not found". A placeholder file makes the folder non-empty; the game never reads it.
"""
import sys
import zipfile

ipa = sys.argv[1]
with zipfile.ZipFile(ipa) as z:
    names = z.namelist()
roots = [n for n in names if n.startswith('Payload/') and n.endswith('.app/romfs/')]
if not roots:
    print('no romfs folder in the IPA, nothing to do')
    sys.exit(0)
root = roots[0]
if any(n.startswith(root) and n != root for n in names):
    print('romfs is not empty, nothing to do')
    sys.exit(0)
with zipfile.ZipFile(ipa, 'a', zipfile.ZIP_DEFLATED) as z:
    z.writestr(root + 'placeholder.txt', 'This game has no RomFS; this file only keeps the folder non-empty.\n')
print('added ' + root + 'placeholder.txt')
