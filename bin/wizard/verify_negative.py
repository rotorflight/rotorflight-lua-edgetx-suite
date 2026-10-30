"""Prove the source contracts reject concrete former defects, offline."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

# The Lua source reader is shared with the documentation generators in bin/docs.
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'docs'))
from flow import BASE, generate  # noqa: E402
from lua_source import literal  # noqa: E402


def verify_flow_layout(model):
    markdown = Path('docs/reference/helicopter-wizard-flow.md').read_text(encoding='utf-8')
    diagram = markdown.split('```mermaid\n', 1)[1].split('\n```', 1)[0]
    cards = {node: (text, kind) for node, text, kind in re.findall(
        r'^\s+(S\d+c\d+)\["(.*?)"\]:::k(\d)', diagram, re.M)}
    expected = {f'S{s["number"]}c{i}' for s in model['steps'] for i in range(len(s['cards']))}
    assert set(cards) == expected, 'Exactly one rectangle per model card is required'
    assert all(text.startswith('<b>') and '</b>' in text and text.count('<br/>')<=3
               for text, _ in cards.values()), 'Card title plus at most three detail lines'
    assert 'sets: Roll, Pitch, Yaw' in cards['S1c2'][0] and cards['S1c2'][1]=='3', 'Concrete inputs and strongest write fill'
    assert 'writes: board_auto_align, board_alignment_config' in cards['S1c2'][0], 'More than three write fields collapse to API names'
    assert 'reads: Accelerometer, Calibrated' in cards['S1c1'][0], 'Displayed English read labels'
    assert 'confirms: All blades removed, Servos unplugged' in cards['S1c0'][0] and cards['S1c0'][1]=='2', 'Confirmations take precedence over reads'
    assert 'blocks until: Direction is correct' in cards['S1c3'][0], 'Simple confirmation gate stays on its card'
    assert 'sets: Degrees' in cards['S16c3'][0] and 'blocks until: Full travel without binding' in cards['S16c3'][0], 'A duplicate confirmation must not hide editable values'
    diamonds = re.findall(r'^\s+(S\d+gate)\{".*?"\}:::k4$', diagram, re.M)
    assert diamonds and not re.search(r'c\d+k\d+', diagram), 'Conditional gates replace the old per-kind nodes'
    count = len(cards)+len(diamonds)
    assert count < 120 and f'Diagram: {count} nodes;' in markdown, 'Compact diagram count must match its declarations'
    print(f'flow layout: {len(cards)} card nodes + {len(diamonds)} gate diamonds = {count} nodes; concrete labels and fills checked', flush=True)


def verify_flow():
    """Exercise the actual CLI on an isolated worktree-local fixture."""
    root = Path.cwd()
    positive = subprocess.run([sys.executable, 'bin/wizard/flow.py', '--check'],
                              text=True, capture_output=True, encoding='utf-8')
    assert positive.returncode == 0 and 'both generated files match' in positive.stdout, positive.stdout+positive.stderr
    print('flow positive control: expected exit 0, both generated files match', flush=True)
    model = json.loads((root/'docs/reference/helicopter-wizard-flow.json').read_text(encoding='utf-8'))
    with tempfile.TemporaryDirectory(prefix='.wizard-flow-control-', dir=root) as folder:
        fixture = Path(folder)
        names = list(model['inputs']) + ['bin/wizard/flow.py', 'bin/wizard/wizard_source.py', 'bin/docs/lua_source.py',
                 'docs/reference/helicopter-wizard-flow.md', 'docs/reference/helicopter-wizard-flow.json']
        for name in names:
            target = fixture/name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(root/name, target)
        step = fixture/BASE/'steps/sensors.lua'
        source = step.read_text(encoding='utf-8')
        anchor = 'w:check("orientation", L.directionCorrect)'
        assert source.count(anchor) == 1, 'Negative control anchor changed'
        step.write_bytes(source.replace(anchor, anchor+', w:check("flowNegativeControl", L.finalCheck)').encode('utf-8'))
        generated, _ = generate(fixture)
        changed = json.loads(generated['docs/reference/helicopter-wizard-flow.json'])
        confirmations = lambda m: [r for s in m['steps'] for c in s['cards'] for r in c['rows'] if r['kind']=='pilot confirms']
        assert len(confirmations(changed)) == len(confirmations(model))+1, 'Added check must be a semantic row, not just a changed fingerprint'
        assert any(r['field']=='flowNegativeControl' for r in confirmations(changed)), 'Added confirmation missing from model'
        assert generated['docs/reference/helicopter-wizard-flow.md'] != (root/'docs/reference/helicopter-wizard-flow.md').read_text(encoding='utf-8'), 'Added confirmation must change the Markdown inventory'
        negative = subprocess.run([sys.executable, 'bin/wizard/flow.py', '--check'], cwd=fixture,
                                  text=True, capture_output=True, encoding='utf-8')
        assert negative.returncode == 1 and '--- docs/reference/helicopter-wizard-flow' in negative.stdout, negative.stdout+negative.stderr
        assert 'flowNegativeControl' in negative.stdout, 'Expected the confirmation in the unified diff'
    print('flow added w:check: expected exit 1, semantic confirmation and unified diff observed', flush=True)
    # A comment/string must not create an action, and a mutable flag in an
    # unknown loop must not erase a conditional card during static extraction.
    from flow import expand
    sample = '''-- w:check("comment", L.no)
local text = 'w:check("string", L.no)'
local present=false
for _,v in ipairs(runtime) do if v then present=true end end
if present then w:cardDef(L.sensors, L.prepare, {w:check("real",L.yes)}) end'''
    calls = list(expand(sample).calls())
    assert [literal(a[0]) for _, _, n, a in calls if n=='check'] == ['real']
    assert sum(n=='cardDef' for _, _, n, _ in calls) == 1
    print('flow scanner: comments/strings ignored; runtime conditional card retained', flush=True)
    verify_flow_layout(model)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lua',default='lua5.3')
    args=parser.parse_args()
    checks=[(None,'0 failures'),('rx-ids','FAIL S02 FBUS wire ID'),
            ('mode-flag','FAIL S03 rescue requires actual mode flag'),
            ('bulk-read','FAIL CORE paged startup reaches ready on telemetry'),
            ('history-early','FAIL CORE unconfirmed step cannot enter history'),
            ('stale-status','FAIL CORE stale status releases holds before bus wait'),
            ('retry-stale','FAIL CORE retry requires new arming lock proof'),
            ('pitch-discard','FAIL REVIEW discarded pitch draft cannot return'),
            ('back-commit','FAIL REVIEW Back Save runs the originating commit'),
            ('stale-blades','FAIL REVIEW ESC calibration requires its own blade confirmation'),
            ('shared-timeout-probe','FAIL REVIEW servo capability cannot authorize mixer timeouts'),
            ('cleanup-unlock','FAIL REVIEW failed cleanup never re-enables arming'),
            ('drop-stale-edit','FAIL CORE an edit made while a list was open applies after fresh STATUS'),
            ('governor-headspeed','FAIL S08 headspeed payload preserves every other profile field'),
            ('rpm-custom-off','FAIL S08 custom/preset filter enablement includes every axis'),
            ('esc-family','FAIL S11 route c not offered for non-YGE protocols'),
            ('esc-incomplete','FAIL S11 truncated YGE read is incomplete'),
            ('battery-slots','FAIL POWER battery write preserves every profile block')]
    def verify(control):
        mutation,marker=control
        command=[args.lua,'bin/wizard/verify.lua']
        if mutation:command+=['--mutation',mutation]
        result=subprocess.run(command,text=True,capture_output=True,encoding='utf-8')
        expected=1 if mutation else 0
        if result.returncode!=expected or marker not in result.stdout or 'Wizard:' not in result.stdout:
            raise AssertionError(f'{mutation or "positive control"}: exit={result.returncode}\n{result.stdout}\n{result.stderr}')
        return f'{mutation or "positive control"}: expected exit {expected}, named assertion observed'

    # Every Lua process has isolated fixtures and reads the same sources without exports.
    with ThreadPoolExecutor(max_workers=3) as executor:
        for result in executor.map(verify,checks):
            print(result,flush=True)
    verify_flow()


if __name__=='__main__':
    main()
