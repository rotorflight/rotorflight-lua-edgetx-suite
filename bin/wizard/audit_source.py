"""Check wizard source traceability and optional pinned-source fingerprints.

No reference clone is a build input. --source is a maintainer comparison against
an explicitly supplied snapshot; CI validates the checked-in map by itself.
"""
import argparse
import hashlib
from pathlib import Path
import re
import sys

# The Lua source reader is shared with the documentation generators in bin/docs.
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'docs'))
from wizard_source import i18n_keys, load_mapping, string_calls  # noqa: E402


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path)
    args=parser.parse_args()
    mapping=load_mapping()
    contracts=set(string_calls(Path('bin/wizard/contracts.lua').read_text(encoding='utf-8'), 'case'))
    files=mapping['files']
    additions=mapping.get('additions',[])
    written=set()
    read=set()
    for addition in additions:
        assert addition['beyond_configurator'] is True, 'Suite additions must not claim Configurator parity'
        assert addition['adaptation'] and addition['targets'] and addition['contracts'], 'Unmapped Suite addition'
        for target in addition['targets']:
            assert Path(target).is_file(), f'Missing addition target: {target}'
        for target, keys in addition.get('flow_cards', {}).items():
            assert target in addition['targets'], f'Flow cards outside addition targets: {target}'
            source=Path(target).read_text(encoding='utf-8')
            for key in keys:
                assert re.search(r'\bL\.'+re.escape(key)+r'\b',source), f'Untraceable added card: {target}:{key}'
        for contract in addition['contracts']:
            assert contract in contracts, f'Missing addition contract: {contract}'
        wizard='\n'.join(Path(p).read_text(encoding='utf-8') for p in addition['targets'])
        for api,fields in addition['writes'].items():
            source=Path(f'src/rfsuite/tasks/msp/api/{api}.lua').read_text(encoding='utf-8')
            for field in fields:
                indexed=re.fullmatch(r'(\w+_)0\.\.5',field)
                token=indexed[1] if indexed else field
                assert token in source and token in wizard, f'Untraceable added write: {api}.{field}'
                written.add(f'{api}.{field}')
        for api,fields in addition.get('reads',{}).items():
            source=Path(f'src/rfsuite/tasks/msp/api/{api}.lua').read_text(encoding='utf-8')
            for field in fields:
                # Indexed RPM fields have their own behavioral contracts.
                if '..' not in field:
                    assert field in source and field in wizard, f'Untraceable added read: {api}.{field}'
                read.add(f'{api}.{field}')
    expected={'governor_profile.governor_headspeed','governor_config.gov_spoolup_time',
              'governor_config.gov_spooldown_time','governor_config.gov_recovery_time',
              'esc_parameters_yge.governor','esc_parameters_yge.stick_zero_us','esc_parameters_yge.stick_range_us',
              'esc_parameters_hw5.flight_mode','motor_config.mincommand','motor_config.minthrottle','motor_config.maxthrottle',
              'battery_config.voltageMeterSource','battery_config.currentMeterSource','battery_config.batteryCellCount',
              'battery_config.batteryCapacity','battery_config.batteryCapacity_0..5','battery_config.batteryCellCount_0..5',
              'smartfuel_config.smartfuel_mode'}
    assert written==expected, f'Added MSP write inventory changed: {written ^ expected}'
    assert not any(field.startswith(('filter_config.','rpm_filter_v2.')) for field in written), 'Filter check must be read-only'
    power=Path('src/rfsuite/app/pages/helicopter_setup/power_cards.lua').read_text(encoding='utf-8')
    assert 'tasks/msp/api/' not in power and 'buildWritePayload' not in power, 'Power cards must use wizard transport'
    assert 'battery_profile.batteryProfile' not in written, 'Power cards must not switch the active battery profile'
    for page,call in [('sources','sourceOptions'),('smartfuel','modeOptions')]:
        source=Path(f'src/rfsuite/app/pages/setup/power/{page}/page.lua').read_text(encoding='utf-8')
        assert f'PowerFields.{call}' in source, f'Power {page} page must share choices with wizard'
        assert f'fields.{call}' in power, f'Wizard must share Power {page} choices'
    battery=Path('src/rfsuite/app/pages/setup/power/battery/page.lua').read_text(encoding='utf-8')
    for spec in ('capacity','cellCount'):
        for bound in ('min','max'):
            assert f'PowerFields.{spec}.{bound}' in battery and f'fields.{spec}.{bound}' in power, 'Battery limits duplicated'
    for api,fields in {'analog':('voltage','current'),'battery_profile':('batteryProfile',),
                       'smartfuel_config':('smartfuel_mode','voltage_drop_rate','charge_drop_rate','sag_gain')}.items():
        assert all(f'{api}.{field}' in read for field in fields), f'Missing Power read inventory: {api}'
    shared=Path('src/rfsuite/lib/esc_params.lua').read_text(encoding='utf-8')
    link=Path('src/rfsuite/app/pages/helicopter_setup/esc_link.lua').read_text(encoding='utf-8')
    for source in (shared,link):
        assert not re.search(r'0x(?:A5|FD|FF)|\b(?:217|218|255)\b|FIELD_SPEC|buildWritePayload|\.parse\(',source), 'ESC codec duplicated outside existing APIs'
    assert 'status.decode(signature)' in shared, 'Restart detection must use esc_status'
    mode_keys=i18n_keys(shared, 'app.pages.setup_esc_motors.mode_')
    assert len(mode_keys)==len(set(mode_keys))==11, 'Mode option keys must have one family descriptor definition'
    assert 'family.modes[value]' in link and 'local names =' not in link, 'Wizard must use descriptor mode options'
    throttle=Path('src/rfsuite/app/pages/setup/esc_motors/throttle/page.lua').read_text(encoding='utf-8')
    # A help text may name the range; a duplicated limit is a number in the code.
    throttle_code=re.sub(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'','""',throttle)
    assert '2250' not in throttle_code, 'Pulse limits must not be duplicated on the throttle page'
    for field in ('mincommand','minthrottle','maxthrottle'):
        for bound in ('min','max'):
            assert f'MotorConfigApi.limits.{field}.{bound}' in throttle, f'Throttle page does not share {field}.{bound}'
    assert 'retryOnErrorReply = j.retryOnErrorReply' in Path('src/rfsuite/app/pages/helicopter_setup/transport.lua').read_text(), 'Generic transport retry option missing'
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
    print(f'Suite additions beyond Configurator: {len(additions)}; {len(written)} added MSP fields: '+', '.join(sorted(written)))
    print(f'Additional read inventory: {len(read)} API field dependencies; ESC codec/restart and Power choice/limit reuse checked')
    if args.source:
        print(f'Pinned source: all {len(files)} SHA-256 fingerprints match; complete wizard directory accounted for')


if __name__=='__main__':
    main()
