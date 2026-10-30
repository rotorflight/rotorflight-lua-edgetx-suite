"""Wizard-only helpers on top of the shared Lua source reader.

The reader itself is `bin/docs/lua_source.py`; a script importing this module puts
`bin/docs` on `sys.path` first. What stays here is specific to the wizard: its source
map, its i18n key prefix and the literal-argument inventory of the audit.
"""
import json
from pathlib import Path
import re

from lua_source import Lua, literal


def load_mapping(root=Path('.')):
    return json.loads((root / 'bin/wizard/source-map.json').read_text(encoding='utf-8'))


def i18n_keys(source, prefix):
    return re.findall(r'@i18n\((' + re.escape(prefix) + r'\w+)\)@', source)


def string_calls(source, receiver):
    """First literal arguments, used by the audit's contract inventory."""
    parsed = Lua(source)
    ts = parsed.tokens
    return [literal(parsed.split(i+2, parsed.pairs[i+1])[0])
            for i in range(len(ts)-2)
            if ts[i].value == receiver and ts[i+1].value == '('
            and (i == 0 or ts[i-1].value != 'function')
            and parsed.split(i+2, parsed.pairs[i+1])]
