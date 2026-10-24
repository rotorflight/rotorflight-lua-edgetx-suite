"""Prove the source contracts reject concrete former defects, offline."""
import argparse
import subprocess


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
            ('drop-stale-edit','FAIL CORE an edit made while a list was open applies after fresh STATUS')]
    for mutation,marker in checks:
        command=[args.lua,'bin/wizard/verify.lua']
        if mutation:command+=['--mutation',mutation]
        result=subprocess.run(command,text=True,capture_output=True,encoding='utf-8')
        expected=1 if mutation else 0
        if result.returncode!=expected or marker not in result.stdout or 'Wizard:' not in result.stdout:
            raise AssertionError(f'{mutation or "positive control"}: exit={result.returncode}\n{result.stdout}\n{result.stderr}')
        print(f'{mutation or "positive control"}: expected exit {expected}, named assertion observed')


if __name__=='__main__':
    main()
