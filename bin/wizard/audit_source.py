"""Check wizard source traceability and optional pinned-source fingerprints.

No reference clone is a build input. --source is a maintainer comparison against
an explicitly supplied snapshot; CI validates the checked-in map by itself.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path)
    args=parser.parse_args()
    mapping=json.loads(Path('bin/wizard/source-map.json').read_text(encoding='utf-8'))
    contracts=set(re.findall(r'case\("([^"\n]+)"',Path('bin/wizard/contracts.lua').read_text(encoding='utf-8')))
    files=mapping['files']
    assert len({f['source'] for f in files})==len(files),'Duplicate source file'
    for entry in files:
        assert entry['targets'] and entry['contracts'],f'Unmapped source: {entry["source"]}'
        for target in entry['targets']:
            assert Path(target).is_file(),f'Missing Lua target: {target}'
        for contract in entry['contracts']:
            assert contract in contracts,f'Missing contract: {contract}'
        if args.source:
            source=args.source/entry['source']
            assert source.is_file(),f'Missing reference file: {source}'
            assert hashlib.sha256(source.read_bytes()).hexdigest()==entry['sha256'],f'Reference changed: {entry["source"]}'
    if args.source:
        actual={p.relative_to(args.source).as_posix() for p in (args.source/'tabs/setup_wizard').iterdir() if p.suffix in ('.svelte','.js')}
        covered={f['source'] for f in files if f['source'].startswith('tabs/setup_wizard/')}
        assert actual==covered,f'Unmapped/removed wizard files: {actual ^ covered}'
    print(f'Traceability: {len(files)} files, {sum(len(f["functions"]) for f in files)} named functions, {len(contracts)} scenario groups; no missing targets/contracts')
    if args.source:
        print(f'Pinned source: all {len(files)} SHA-256 fingerprints match; complete wizard directory accounted for')


if __name__=='__main__':
    main()
