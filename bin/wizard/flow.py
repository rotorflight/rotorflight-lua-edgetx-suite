"""Generate the helicopter wizard flow from Lua sources and the traceability map.

Python 3 / standard library only. No Lua execution, radio, reference checkout or
network is needed. Conditional cards are static templates, not a session trace.
"""
import argparse
import difflib
import hashlib
import html
import json
from pathlib import Path
import re
import sys

# The Lua source reader is shared with the documentation generators in bin/docs.
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'docs'))
from lua_source import Lua, Token, expression, literal  # noqa: E402
from wizard_source import load_mapping  # noqa: E402


BASE = Path('src/rfsuite/app/pages/helicopter_setup')
OUTPUT = Path('docs/reference/helicopter-wizard-flow')
KINDS = ('pilot sets', 'read', 'pilot confirms', 'MSP write', 'gate')
COLORS = ('#dbeafe', '#dcfce7', '#ffedd5', '#fee2e2', '#f3f4f6')


def unique(items):
    return list(dict.fromkeys(items))


def resolve(ts, env):
    """Substitute lexical constants and literal table indexes, never run Lua."""
    out, i = [], 0
    while i < len(ts):
        t = ts[i]
        value = env.get(t.value) if i == 0 or ts[i-1].value not in ('.', ':') else None
        if value is not None:
            value = list(value)
            j = i+1
            while j+2 < len(ts) and ts[j].value == '[' and ts[j+2].value == ']' and ts[j+1].value.isdigit():
                if not value or value[0].value != '{':
                    break
                table = Lua(value)
                parts = table.split(1, table.pairs[0])
                index = int(ts[j+1].value)-1
                if not 0 <= index < len(parts):
                    break
                value = parts[index]; j += 3
            out.extend(value); i = j
        else:
            out.append(t); i += 1
    # Fold simple numeric arithmetic and constant concatenation in field names.
    for operator in ('..', '+', '-'):
        i = 1
        while i+1 < len(out):
            a, op, b = out[i-1:i+2]
            av, bv = literal([a]), literal([b])
            if op.value == operator and operator == '..' and (av is not None or a.value.isdigit()) and (bv is not None or b.value.isdigit()):
                out[i-1:i+2] = [Token(json.dumps(str(av if av is not None else a.value)+str(bv if bv is not None else b.value)), a.offset, a.line)]
                i = max(1, i-1)
            elif op.value == operator and operator in ('+', '-') and a.value.isdigit() and b.value.isdigit():
                out[i-1:i+2] = [Token(str(int(a.value)+(1 if operator == '+' else -1)*int(b.value)), a.offset, a.line)]
                i = max(1, i-1)
            else:
                i += 1
    if len(out) == 3 and out[1].value in ('==', '~='):
        left, right = literal(out[:1]), literal(out[2:])
        if left is not None and right is not None:
            return [Token('true' if (left == right) == (out[1].value == '==') else 'false')]
    # Statically known boolean alternatives (e.g. cyclic/tail servo groups).
    for i in range(len(out)-1):
        if out[i].value in ('true', 'false') and out[i+1].value == 'and':
            rest = out[i+2:]
            if any(t.value == 'or' for t in rest):
                at = next(j for j, t in enumerate(rest) if t.value == 'or')
                if i == 0:
                    return rest[:at] if out[i].value == 'true' else rest[at+1:]
    if any(t.value in ('and', 'or') for t in out):
        p = Lua(out)
        parts = p.split(0, len(out), 'or')
        if len(parts) > 1:
            first = resolve(parts[0], {})
            if first and first[0].value in ('false', 'nil') and len(first) == 1:
                return resolve([t for part in parts[1:] for t in part], {}) if len(parts) == 2 else out
            if literal(first) is not None or (len(first)==1 and first[0].value == 'true'):
                return first
        parts = p.split(0, len(out), 'and')
        if len(parts) > 1:
            first = resolve(parts[0], {})
            if len(first)==1 and first[0].value in ('false', 'nil'):
                return first
            if literal(first) is not None or (len(first)==1 and first[0].value == 'true'):
                return resolve(parts[1], {}) if len(parts)==2 else out
    return out


def constant(ts):
    # Literal tables and label expressions are safe to substitute. Mutable UI
    # row tables and FC/session values must keep their identity.
    if len(ts)==2 and ts[0].value=='{' and ts[1].value=='}':
        return False  # Empty tables are mutable accumulators, never loop bounds.
    if any(t.value == 'L' for t in ts) and not any(t.value in ('w', 'self', 'function', '=', ':') for t in ts):
        return True  # A symbolic label expression can retain runtime placeholders.
    return bool(ts) and not any(t.value in ('w', 'self', 'function', '=', ':') for t in ts) and all(
        t.value == 'L' or t.value in ('true', 'false', 'nil', '.', ',', '{', '}', '[', ']', '..', '+', '-')
        or t.value.isdigit() or literal([t]) is not None
        or (i and ts[i-1].value == '.') for i, t in enumerate(ts))


def expand(source, bindings=None):
    """Expand local UI factories and finite literal loops into source templates.

    Both sides of runtime conditions survive. Unknown loop bounds survive once.
    This handles shared row/card factories rather than maintaining card lists.
    """
    parsed = Lua(source)
    factories = {}
    functions = list(parsed.functions())
    for _, _, name, params, body in functions:
        if name and re.fullmatch(r'\w+', name):
            factories[name] = (params, body)
    ui = {name for name, (_, body) in factories.items()
          if any(t.value == 'cardDef' for t in body)
          or re.search(r'kind\s*=\s*["\'](?:choice|number|text)["\']', expression(body))}
    while True:
        more = {name for name, (_, body) in factories.items()
                if any(t.value in ui and i+1 < len(body) and body[i+1].value == '(' for i, t in enumerate(body))}
        if more <= ui:
            break
        ui |= more

    def walk(ts, bindings=None, stack=(), frozen=None):
        p = Lua(ts); ts = p.tokens
        env = dict(bindings or {})
        frozen = set(env) if frozen is None else frozen
        out, i = [], 0
        local_functions = {a: (b, name) for a, b, name, _, _ in p.functions() if name in ui}
        while i < len(ts):
            if i in local_functions:
                i = local_functions[i][0]; continue
            t = ts[i]
            if t.value == 'if':
                end = p.pairs[i]
                then = i+1
                while ts[then].value != 'then':
                    then = p.pairs.get(then, then)+1
                condition = resolve(ts[i+1:then], env)
                identifiers = {x.value for x in ts[i+1:then] if re.fullmatch(r'[A-Za-z_]\w*', x.value)
                               and x.value not in ('true', 'false', 'nil', 'and', 'or')}
                known = identifiers <= frozen and len(condition)==1 and (condition[0].value in ('true', 'false', 'nil') or literal(condition) is not None)
                if known:
                    alternate, j = None, then+1
                    while j < end:
                        if ts[j].value in ('else', 'elseif'):
                            alternate = j; break
                        j = p.pairs.get(j, j)+1
                    # Retain unknown elseif chains; both branches are templates.
                    if alternate is None or ts[alternate].value == 'else':
                        truth = condition[0].value not in ('false', 'nil')
                        branch = ts[then+1:alternate or end] if truth else ts[alternate+1:end] if alternate else []
                        out.extend(walk(branch, env, stack, frozen)); i = end+1; continue
            if t.value == 'for':
                end = p.pairs[i]
                do = i+1
                while ts[do].value != 'do':
                    do = p.pairs.get(do, do)+1
                header = resolve(ts[i+1:do], env)
                hp = Lua(header)
                values, names = None, []
                inv = next((j for j, x in enumerate(header) if x.value == 'in'), None)
                if inv is not None and header[inv+1].value == 'ipairs' and header[inv+3].value == '{':
                    names = [x.value for x in header[:inv] if x.value != ',']
                    vals = hp.split(inv+4, hp.pairs[inv+3])
                    values = [([Token(str(n+1))], v) for n, v in enumerate(vals)]
                elif len(header)>2 and header[1].value == '=':
                    parts = Lua(header).split(2, len(header))
                    if all(len(x)==1 and x[0].value.isdigit() for x in parts):
                        nums = [int(x[0].value) for x in parts]
                        lo, hi = nums[:2]; stride = nums[2] if len(nums)>2 else 1
                        if stride > 0 and 0 <= (hi-lo)//stride < 8:
                            names = [header[0].value]
                            values = [([Token(str(n))],) for n in range(lo, hi+1, stride)]
                if values is not None:
                    for vals in values:
                        out.extend(walk(ts[do+1:end], dict(env, **dict(zip(names, vals))), stack, frozen | set(names)))
                else:
                    loop_env = dict(env)
                    for x in ts[i+1:do]:
                        if x.value in ('in', '='):
                            break
                        loop_env.pop(x.value, None)
                    out.extend(ts[i:do+1]); out.extend(walk(ts[do+1:end], loop_env, stack, frozen)); out.append(ts[end])
                i = end+1; continue
            if t.value in ui and t.value not in stack and i+1 < len(ts) and ts[i+1].value == '(' and (i == 0 or ts[i-1].value not in (':', '.', 'function')):
                end = p.pairs[i+1]
                args = [resolve(a, env) for a in p.split(i+2, end)]
                params, body = factories[t.value]
                out.extend(walk(body, dict(env, **dict(zip(params, args))), stack+(t.value,), frozen | set(params)))
                i = end+1; continue
            if t.value == 'local' and i+2 < len(ts) and ts[i+1].value != 'function':
                j = i+1
                while j < len(ts) and (re.fullmatch(r'\w+', ts[j].value) or ts[j].value == ',') and ts[j].line == t.line:
                    j += 1
                if j < len(ts) and ts[j].value == '=':
                    k = j+1
                    while k < len(ts) and ts[k].line == ts[j].line and ts[k].value != ';':
                        k = p.pairs.get(k, k)+1
                    # A statement after an inline local declaration is not its RHS.
                    stop = j+1
                    while stop < k and ts[stop].value not in ('return', 'if', 'end', 'else', 'local'):
                        stop = p.pairs.get(stop, stop)+1
                    rhs = ts[j+1:stop]
                    parts = Lua(rhs).split(0, len(rhs)) if rhs else []
                    names = [x.value for x in ts[i+1:j] if x.value != ',']
                    for name, part in zip(names, parts):
                        value = resolve(part, env)
                        if constant(value):
                            env[name] = value
                    # Keep declarations intact; substitutions apply to uses only.
                    out.extend(ts[i:j+1]); i = j+1; continue
            if t.value in env and (i == 0 or ts[i-1].value not in ('.', ':')):
                j = i+1
                while j+2 < len(ts) and ts[j].value == '[' and ts[j+2].value == ']' and ts[j+1].value.isdigit():
                    j += 3
                # Do not substitute assignment targets or named table keys.
                if j >= len(ts) or ts[j].value != '=':
                    out.extend(resolve(ts[i:j], env)); i = j; continue
                if not i or ts[i-1].value not in ('{', ','):
                    env.pop(t.value, None)  # A mutable local is no longer a constant.
            out.append(t); i += 1
        return resolve(out, {})
    return Lua(walk(parsed.tokens, bindings))


def english(root):
    p = Lua((root/'src/rfsuite/i18n/en.lua').read_text(encoding='utf-8'))
    result = {}

    def table(at, prefix=''):
        for key, value in p.fields(at).items():
            path = prefix+key
            if value[0].value == '{':
                # Token offsets identify the original nested table.
                index = next(i for i, t in enumerate(p.tokens) if t is value[0])
                table(index, path+'.')
            else:
                text = literal(value)
                if text is not None:
                    result[path] = text
    table(next(i for i, t in enumerate(p.tokens) if t.value == '{'))
    labels = Lua((root/BASE/'labels.lua').read_text(encoding='utf-8'))
    values = labels.fields(next(i for i, t in enumerate(labels.tokens) if t.value == '{'))
    out = {}
    for key, value in values.items():
        tag = literal(value)
        match = re.fullmatch(r'@i18n\((.*?)\)@', tag or '')
        assert match and match[1] in result, f'Unresolved English label: {key}'
        out[key] = result[match[1]]
    return out


def label(ts, labels):
    raw = literal(ts)
    if raw is not None:
        return raw
    keys = re.findall(r'(?:\bL|self\s*\.\s*L)\s*\.\s*(\w+)', expression(ts))
    texts = unique(labels[k] for k in keys)
    if not texts:
        return '{'+expression(ts)+'}'
    # Retain profile placeholders instead of inventing a runtime profile count.
    return ' / '.join(re.sub(r'%[-+\d.]*[dfs]', '{n}', text) for text in texts)


def references(mapping, paths):
    return [f for f in mapping['files'] if set(f['targets']) & set(paths)]


def status_for(mapping, path, api=None, field=None, title_expression=''):
    additions = []
    for item in mapping.get('additions', []):
        if path not in item['targets']:
            continue
        card_keys = set(re.findall(r'\bL\s*\.\s*(\w+)', title_expression))
        card_match = bool(card_keys & set(item.get('flow_cards', {}).get(path, [])))
        matched = card_match or (api is None and '/steps/' not in path) or any(api == a and field is not None and (field in fs or
                    any(str(field).startswith(f.split('0..')[0]) for f in fs if '0..' in f))
                    for group in ('writes', 'reads') for a, fs in item.get(group, {}).items())
        if matched and item.get('beyond_configurator'):
            additions.append(item['id'])
    differs = [f['source'] for f in references(mapping, [path])
               if 'deviation' in f.get('adaptation', '').lower()]
    return unique((['beyond the Configurator'] if additions else [])+
                  (['differs from the Configurator'] if differs else [])), additions


def extract(source, path, labels, mapping, bindings=None, effects_only=False):
    p = expand(source, bindings); ts = p.tokens
    calls = [(a, b, method, [resolve(arg, {}) for arg in args]) for a, b, method, args in p.calls()]
    card_calls = [c for c in calls if c[2] == 'cardDef']
    assert card_calls or effects_only, f'No cards extracted: {path}'
    refs = [f['source'] for f in references(mapping, [path])]

    def row(kind, text, start, end, api=None, field=None):
        status, additions = status_for(mapping, path, api, field)
        return dict(kind=kind, label=text, api=api, field=field,
                    deviation=bool(status), configurator_status=status or ['same'],
                    configurator_reference=refs, additions=additions,
                    source=path, expression=expression(ts[start:end]))

    cards = []
    for start, end, _, args in card_calls:
        status, additions = status_for(mapping, path, title_expression=expression(args[0]))
        cards.append(dict(title=label(args[0], labels), title_expression=expression(args[0]),
                          source=path, configurator_reference=refs,
                          configurator_status=status or ['same'], additions=additions, rows=[]))
    if effects_only:
        cards = [dict(title='Shared transport', source=path, configurator_reference=refs,
                      configurator_status=['same'], additions=[], rows=[])]

    def owner(start, end):
        if effects_only:
            return 0
        inside = [(i, b-a) for i, (a, b, _, _) in enumerate(card_calls) if a <= start and end <= b]
        if inside:
            return min(inside, key=lambda x: x[1])[0]
        # Rows are often prepared in locals before cardDef. A symbol referenced by
        # the card's rows argument links it to its declaration, including appends.
        name = None
        for j in range(start-1, max(-1, start-12), -1):
            if ts[j].value == '=':
                k = j-1
                if ts[k].value == ']':
                    while k >= 0 and ts[k].value != '[':
                        k -= 1
                    k -= 1
                if k >= 0:
                    name = ts[k].value
                break
        if name:
            candidates = [i for i, (a, _, _, args) in enumerate(card_calls)
                          if a > start and len(args)>2 and any(t.value == name for t in args[2])]
            if candidates:
                return candidates[0]
        following = [i for i, (a, _, _, _) in enumerate(card_calls) if a >= start]
        return following[0] if following else len(cards)-1

    def add(kind, text, start, end, api=None, field=None):
        card = cards[owner(start, end)]
        item = row(kind, text, start, end, api, field)
        if 'beyond the Configurator' in card['configurator_status']:
            item['deviation'] = True
            item['configurator_status'] = unique([s for s in item['configurator_status'] if s!='same']+['beyond the Configurator'])
            item['additions'] = unique(item['additions']+card['additions'])
        card['rows'].append(item)

    for start, end, method, args in calls:
        arg = lambda n: literal(args[n]) if len(args)>n else None
        expr = lambda n: arg(n) or expression(args[n]) if len(args)>n else None
        if method in ('n', 'enum', 'c', 'field'):
            api, field = expr(0), expr(1)
            if arg(1) is None:
                field = '{'+str(field)+'}'
            if method != 'field':
                add('pilot sets', label(args[2], labels), start, end, api, field)
            add('MSP write', f'{api}.{field}', start, end, api, field)
        elif method == 'check':
            add('pilot confirms', label(args[1], labels), start, end, None, expr(0))
        elif method == 'value':
            add('read', label(args[0], labels), start, end)
        elif method in ('write', 'action', 'read', 'touch'):
            api = expr(0)
            if method == 'read':
                add('read', 'MSP '+str(api), start, end, api)
            else:
                fields = []
                if method == 'write' and len(args)>1 and args[1] and args[1][0].value == '{':
                    fields = list(Lua(args[1]).fields(0))
                for field in fields or [None]:
                    add('MSP write', api+('.'+field if field else ' (record/payload)'), start, end, api, field)
        elif method == 'ack':
            add('gate', 'ack '+str(expr(0)), start, end, None, expr(0))
        elif method == 'startTrial':
            for kind in ('read', 'MSP write'):
                add(kind, 'MSP '+str(expr(0))+' (trial)', start, end, expr(0))
        elif method == 'port':
            add('pilot sets', label(args[0], labels), start, end, 'serial_config', 'port_{n}_function_mask')
            add('MSP write', 'serial_config.port_{n}_function_mask', start, end, 'serial_config', 'port_{n}_function_mask')
        elif method == 'feature':
            add('MSP write', 'feature_config.enabledFeatures', start, end, 'feature_config', 'enabledFeatures')
    for start, t in enumerate(ts):
        if t.value == '{':
            fields = p.fields(start)
            kind = literal(fields.get('kind', []))
            if kind in ('choice', 'number', 'text'):
                add('pilot sets', label(fields.get('label', []), labels), start, p.pairs[start]+1)
            elif kind == 'toggle':
                safety = any(t.value in ('bladesOff', 'checks') for part in fields.values() for t in part)
                add('pilot confirms' if safety else 'pilot sets', label(fields.get('label', []), labels), start, p.pairs[start]+1)
            api = literal(fields.get('api', []))
            if api:
                write = expression(fields.get('write', [])) == 'true'
                payload = fields.get('data', [])
                names = list(Lua(payload).fields(0)) if payload and payload[0].value == '{' else []
                for name in names or [None]:
                    add('MSP write' if write else 'read', 'MSP '+api, start, p.pairs[start]+1, api, name)
        elif t.value == 'validate' and start+2 < len(ts) and ts[start+1].value == '=' and ts[start+2].value == 'function':
            add('gate', 'validation', start, p.pairs[start+2]+1)
        elif t.value == 'rebootPending':
            add('gate', 'reboot pending', start, start+1)
    # The servo grid uses callbacks rather than standard row factories. Preserve
    # confirmations written directly into checks and fields edited through local
    # aliases of w.data records (also used by pitch/servo helper callbacks).
    aliases = {}
    for i in range(len(ts)-5):
        if ts[i].value == 'local' and ts[i+2].value == '=':
            aliases.pop(ts[i+1].value, None)
            j = i+3
            if ts[j].value in ('w', 'self') and ts[j+1].value == '.' and ts[j+2].value == 'data' and ts[j+3].value == '.':
                aliases[ts[i+1].value] = ts[j+4].value
        assignment = False
        if ts[i].value in aliases and ts[i+1].value == '.':
            j = i+3
            while j < len(ts) and ts[j].value == ',' and j+3<len(ts):
                j += 1
                if ts[j+1].value != '.':
                    break
                j += 3
            assignment = j < len(ts) and ts[j].value == '='
        if assignment:
            api, field = aliases[ts[i].value], ts[i+2].value
            add('MSP write', api+'.'+field, i, i+4, api, field)
            if any(t.value == 'grid' for t in ts):
                add('pilot sets', cards[0]['title']+' ('+field+')', i, i+4, api, field)
        if ts[i].value in ('w', 'self') and ts[i+1].value == '.' and ts[i+2].value == 'checks' and ts[i+3].value == '[':
            end = p.pairs[i+3]
            if end+2 < len(ts) and ts[end+1].value == '=' and ts[end+2].value == 'true':
                key = expression(ts[i+4:end])
                add('pilot confirms', cards[0]['title'], i, end+3, None, key)
    for card in cards:
        # Preserve distinct labels/fields while collapsing repeated references.
        card['rows'] = list({json.dumps(r, sort_keys=True): r for r in card['rows']}.values())
    return cards


def helper_effects(source, functions, labels, mapping):
    """Follow wizard method calls to their transport operations with bound APIs.

    Navigation and save/cleanup are shared lifecycle operations, recorded once in
    the model. Following them back into scene construction would turn a step's
    inventory into the inventory of the entire wizard.
    """
    primitives = {'field', 'n', 'c', 'enum', 'check', 'value', 'read', 'write', 'action',
                  'touch', 'cardDef', 'button', 'ack', 'port', 'feature', 'startTrial'}
    lifecycle = {'navigate', 'rebuild', 'loadModule', 'save', 'reboot', 'close', 'release',
                 'fail', 'run', 'applyEdit', 'escRefresh'}
    seen, rows = set(), []

    def deferred_hold(args):
        if not args or literal(args[0]) is None or 'tick' not in functions:
            return
        path, _, body = functions['tick']
        # The held kind is consumed later by tick's queue table. Resolve its
        # descriptor expression, rather than maintaining an override API list.
        bound, i = [], 0
        while i < len(body):
            if i+2<len(body) and [t.value for t in body[i:i+3]] == ['h', '.', 'kind']:
                bound.extend(args[0]); i += 3
            else:
                bound.append(body[i]); i += 1
        p = Lua(bound)
        for at, t in enumerate(bound):
            if t.value != '{':
                continue
            fields = p.fields(at)
            if expression(fields.get('write', [])) != 'true':
                continue
            api_expr = fields.get('api', [])
            if not any(t.value == '..' for t in api_expr):
                continue
            api = literal(resolve(api_expr, {}))
            if api:
                rows.append(dict(kind='MSP write', label='MSP '+api, api=api, field=None,
                    deviation=False, configurator_status=['same'], configurator_reference=unique(
                        f['source'] for f in references(mapping, [path])), additions=[], source=path,
                    expression=expression(bound[at:p.pairs[at]+1]), scope='deferred hold in tick'))

    def visit(p, depth=0):
        assert depth < 24, 'Recursive transport helper expansion'
        for _, _, method, args in p.calls():
            if method == 'hold':
                deferred_hold(args)
            if method in primitives or method in lifecycle or method not in functions:
                continue
            path, params, body = functions[method]
            bindings = dict(zip(params, args))
            signature = method, tuple(expression(a) for a in args[:2])
            if signature in seen:
                continue
            seen.add(signature)
            resolved = expand(body, bindings)
            effects = extract(resolved.tokens, path, labels, mapping, effects_only=True)[0]['rows']
            # A profile callback mutates the selected complete record before the
            # shared transport writes it. Its named assignments are field writes.
            if method == 'profileLoop' and len(args)>2 and args[2] and args[2][0].value == 'function':
                callback = Lua(args[2])
                _, _, _, params, callback_body = next(callback.functions())
                apis = unique(r['api'] for r in effects if r['kind']=='MSP write' and r['field'] is None and r['api']!='set_pid_profile')
                for j in range(len(callback_body)-3):
                    if callback_body[j].value == params[0] and callback_body[j+1].value == '.' and callback_body[j+3].value == '=':
                        for api in apis:
                            field = callback_body[j+2].value
                            status, ids = status_for(mapping, path, api, field)
                            effects.append(dict(kind='MSP write', label=api+'.'+field, api=api, field=field,
                                deviation=bool(status), configurator_status=status or ['same'], configurator_reference=unique(
                                    f['source'] for f in references(mapping, [path])), additions=ids, source=path,
                                expression=expression(args[2]), scope='profile callback'))
            for r in effects:
                if r['kind'] in ('MSP write', 'read') and r['api']:
                    # A controller-wide adaptation does not make every caller a
                    # step-order deviation. Step/card mappings own that status.
                    r['configurator_status'] = [s for s in r['configurator_status'] if s != 'differs from the Configurator'] or ['same']
                    r['deviation'] = r['configurator_status'] != ['same']
                    rows.append(r)
            visit(resolved, depth+1)
    visit(Lua(source))
    return rows


def poll_reads(controller, number):
    """Read the indexed per-step poll table and its explicit conditional override.

    STATUS/servo are the common poll slots. The indexed branch and conditional
    assignments are scanned, so adding a step-specific API changes the inventory.
    The complete poll expression is also retained in shared_transport.
    """
    p = Lua(controller)
    body = next(b for _, _, n, _, b in p.functions() if n == 'w:poll')
    p = Lua(body); ts = p.tokens
    result = []
    # APIs outside the indexed table are the shared slot alternatives.
    api_at = next(i for i in range(len(ts)-2) if ts[i].value == 'local' and ts[i+1].value == 'api')
    table_at = next(i for i in range(api_at, len(ts)) if ts[i].value == '{' and i+1<len(ts) and ts[i+1].value == '[')
    prefix = ts[api_at:table_at]
    common = unique(literal([t]) for t in prefix if literal([t]) is not None)
    # A conditional branch before the shared pollIndex slots is enabled only for
    # the step IDs in the corresponding local flag definition.
    flag_steps = {}
    for i in range(api_at):
        if ts[i].value == 'local' and i+2<api_at and ts[i+2].value == '=':
            end = i+3
            while end < api_at and ts[end].line == ts[i].line:
                end += 1
            ids = re.findall(r'self\s*\.\s*step\s*==\s*(\d+)', expression(ts[i+3:end]))
            if ids:
                flag_steps[ts[i+1].value] = {int(n) for n in ids}
    # Segment each flag's and/or branch before the unconditional poll slots.
    for flag, ids in flag_steps.items():
        match = next((i for i, t in enumerate(prefix) if t.value == flag), None)
        if match is not None and number not in ids:
            end = match+1
            if end<len(prefix) and prefix[end].value == 'and':
                end += 1
                if end<len(prefix) and prefix[end].value == '(':
                    span = p.pairs[api_at+end]-api_at
                    excluded = [literal([t]) for t in prefix[end:span+1] if literal([t]) is not None]
                    # STATUS/servo remain the ordinary common slots.
                    common = [v for v in common if v not in excluded or v in ('status', 'servo')]
    result.extend(common)
    for part in p.split(table_at+1, p.pairs[table_at]):
        if len(part)>4 and part[0].value=='[' and part[1].value==str(number):
            result.extend(literal([t]) for t in part[4:] if literal([t]) is not None)
    for i in range(p.pairs[table_at]+1, len(ts)-2):
        if ts[i].value == 'if':
            end = p.pairs[i]
            branch = ts[i:end]
            ids = re.findall(r'self\s*\.\s*step\s*==\s*(\d+)', expression(branch))
            if str(number) in ids:
                result.extend(literal([branch[j+2]]) for j in range(len(branch)-2)
                              if branch[j].value == 'api' and branch[j+1].value == '=' and literal([branch[j+2]]) is not None)
    return unique(v for v in result if v)


def build_model(root):
    mapping = load_mapping(root); labels = english(root)
    sources = {}

    def read(path):
        name = Path(path).as_posix()
        data = (root/path).read_bytes()
        text = data.decode('utf-8').replace('\r\n', '\n')
        sources[name] = hashlib.sha256(text.encode('utf-8')).hexdigest()
        return text

    controller = read(BASE/'controller.lua')
    label_source = read(BASE/'labels.lua')
    read(Path('src/rfsuite/i18n/en.lua')); read(Path('bin/wizard/source-map.json'))
    order = re.search(r'local STEPS\s*=\s*(\{.*?\})', controller, re.S)[1]
    step_ids = [literal(a) for a in Lua(order).split(1, len(Lua(order).tokens)-1)]
    title_keys = re.findall(r'L\.(\w+)', re.search(r'L.steps\s*=\s*\{(.*?)\}', label_source, re.S)[1])
    assert len(step_ids) == len(title_keys)
    modules = sorted((root/BASE/'steps').glob('*.lua'))
    assert {p.stem for p in modules} == set(step_ids), 'Unordered or missing step module'
    # Shared implementation sources are inputs too: helper changes must not hide
    # behind unchanged call sites. They are never fetched from a reference clone.
    shared = {}
    for path in sorted((root/BASE).glob('*.lua')):
        if path.name not in ('controller.lua', 'labels.lua'):
            shared[path.stem] = read(path.relative_to(root))
    for addition in mapping.get('additions', []):
        for target in addition['targets']:
            if target.startswith('src/'):
                read(Path(target))

    navigation = Lua(shared['navigation'])
    functions = {}
    card_methods = {}
    for name, text in dict(controller=controller, **shared).items():
        for _, _, method, params, body in Lua(text).functions():
            if method.startswith('w:'):
                functions[method[2:]] = ((BASE/f'{name}.lua').as_posix(), params, body)
                if name != 'controller' and any(t.value == 'cardDef' for t in body):
                    card_methods[method[2:]] = name
    model_body = next(body for _, _, name, _, body in navigation.functions() if name == 'w:buildModelPreparation')
    model_cards = extract(expression(model_body), (BASE/'navigation.lua').as_posix(), labels, mapping)
    steps = [dict(number=0, id='model', title=labels['modelPreparationTitle'], phase='A',
                  cards=model_cards, msp_reads=[], msp_writes=[], configurator_status=[])]
    model_cards[-1]['rows'].extend(helper_effects(model_body, functions, labels, mapping))
    for number, (step_id, key) in enumerate(zip(step_ids, title_keys), 1):
        path = BASE/'steps'/f'{step_id}.lua'
        source = read(path)
        cards = extract(source, path.as_posix(), labels, mapping)
        # Follow card-producing modules loaded by this step, and attached card
        # methods, rather than naming the added ESC/Power cards here.
        included = set()
        for _, _, method, args in Lua(source).calls():
            candidates = []
            if method == 'loadModule' and args:
                module = literal(args[0]) or ''
                if module.startswith('app/pages/helicopter_setup/'):
                    candidates.append(Path(module).stem)
            if method in card_methods:
                candidates.append(card_methods[method])
            for name in candidates:
                if name not in included and name in shared and 'cardDef' in shared[name]:
                    cards.extend(extract(shared[name], (BASE/f'{name}.lua').as_posix(), labels, mapping))
                    included.add(name)
        effects = helper_effects(source, functions, labels, mapping)
        cards[0]['rows'].extend(effects)
        phase = 'A' if number <= 5 else 'B' if number <= 10 else 'C' if number <= 12 else 'D'
        status, _ = status_for(mapping, path.as_posix())
        steps.append(dict(number=number, id=step_id, title=labels[key], phase=phase, cards=cards,
                          msp_reads=[], msp_writes=[], configurator_status=status or ['same']))
    # Keep the complete map metadata for comparison, including prose deviations
    # and additions whose dynamic fields are expressed through shared descriptors.
    for step in steps:
        paths = unique(c['source'] for c in step['cards'])
        for addition in mapping.get('additions', []):
            relevant = [p for p in paths if p in addition['targets']]
            if not relevant:
                continue
            path = relevant[-1]
            candidates = [c for c in step['cards'] if c['source'] in relevant]
            for group, kind in (('reads', 'read'), ('writes', 'MSP write')):
                for api, fields in addition.get(group, {}).items():
                    for field in fields:
                        def score(card):
                            return sum(r['api']==api and r['field']==field for r in card['rows'])
                        card = max(candidates, key=score)
                        # The audit verifies these dependency/transaction fields
                        # against the source and API modules, including indexed
                        # descriptor-driven writes that have no literal callsite.
                        status, ids = status_for(mapping, path, api, field)
                        card['rows'].append(dict(kind=kind, label=f'{api}.{field}', api=api, field=field,
                            deviation=True, configurator_status=status, configurator_reference=unique(
                                f['source'] for f in references(mapping, relevant)), additions=ids,
                            source=path, expression='source-map additions: '+addition['id'],
                            scope='mapped dependency' if kind=='read' else 'mapped transaction'))
        if step['number']:
            card = step['cards'][0]
            for api in poll_reads(controller, step['number']):
                card['rows'].append(dict(kind='read', label='MSP '+api, api=api, field=None,
                    deviation=False, configurator_status=['same'], configurator_reference=[], additions=[],
                    source=(BASE/'controller.lua').as_posix(), expression='w:poll', scope='live poll'))
        rows = [r for c in step['cards'] for r in c['rows']]
        for card in step['cards']:
            card['configurator_status'] = unique(card['configurator_status']+
                [s for r in card['rows'] for s in r['configurator_status'] if s!='same'])
            if len(card['configurator_status'])>1 and 'same' in card['configurator_status']:
                card['configurator_status'].remove('same')
        step['configurator_status'] = unique(s for c in step['cards'] for s in c['configurator_status'])
        if len(step['configurator_status'])>1 and 'same' in step['configurator_status']:
            step['configurator_status'].remove('same')
        step['msp_reads'] = unique(r['api']+('.'+r['field'] if r['field'] else '') for r in rows if r['kind']=='read' and r['api'])
        step['msp_writes'] = unique(r['api']+('.'+r['field'] if r['field'] else '') for r in rows if r['kind']=='MSP write' and r['api'])
    startup = re.search(r'local READS\s*=\s*(\{.*?\})', controller, re.S)[1]
    startup = [literal(a) for a in Lua(startup).split(1, len(Lua(startup).tokens)-1)]
    return dict(schema_version=1, configurator_revision=mapping['reference'],
                semantics='Static source templates; conditional branches and runtime repetitions are alternatives, not a session trace.',
                inputs=dict(sorted(sources.items())), shared_transport=dict(startup_reads=startup,
                    functions={name: expression(data[2]) for name, data in functions.items()
                               if name in ('load', 'save', 'poll', 'tick', 'next', 'release', 'profileLoop')}),
                traceability=mapping, steps=steps)


def short(text, limit=48):
    text = ' '.join(text.split())
    return text if len(text) <= limit else text[:limit-1].rstrip()+'…'


def mermaid_text(text):
    return html.escape(text, quote=True).replace('#', '#35;').replace('&quot;', '#quot;').replace('&amp;', '#amp;').replace('&lt;', '#lt;').replace('&gt;', '#gt;')


def short_list(items, limit=40):
    text = ', '.join(unique(' '.join(item.split()) for item in items if item))
    if len(text) <= limit:
        return text
    # Leave the complete inventory in the table/JSON; keep diagram lines compact.
    return text[:limit-3].rstrip(' ,')+'...'


def step_gate(step):
    """Distinguish conditional step validation from plain confirmations.

    A bare rebootPending occurrence can be an assignment requesting a later
    reboot. Only its use in validation establishes a step-level blocker here.
    """
    rows = [r for c in step['cards'] for r in c['rows']]
    validations = unique(r['expression'] for r in rows if r['kind']=='gate' and r['label']=='validation')
    conditional = any(re.search(r'\breturn\s+(?:false|not)\b', v) or
                      re.search(r'\bif\b.*\brebootPending\b', v) for v in validations)
    confirmations = {r['field']: r['label'] for r in rows if r['kind']=='pilot confirms'}
    required = []
    for row in rows:
        if row['kind'] != 'gate' or not row['label'].startswith('ack '):
            continue
        text = confirmations.get(row['field'])
        if text is None:
            # Grid confirmations use a runtime servo index in both expressions.
            key = literal(Lua(row['field']).tokens[:1])
            text = next((r['label'] for r in rows if r['kind']=='pilot confirms' and r['field']
                         and key and literal(Lua(r['field']).tokens[:1]) == key), None)
        required.append(text or 'required confirmations')
    return conditional, short_list(required)


def card_node(card, blocks_until=''):
    rows = card['rows']
    strength = ('MSP write', 'pilot confirms', 'pilot sets', 'read', 'gate')
    kinds = [kind for kind in strength if any(r['kind']==kind for r in rows)]
    strongest = kinds[0] if kinds else 'gate'
    prefixes = {'pilot sets': 'sets', 'pilot confirms': 'confirms', 'read': 'reads', 'MSP write': 'writes'}
    # Reserve the last of the three detail lines for a simple confirmation gate.
    actions = [kind for kind in kinds if kind != 'gate']
    if blocks_until and len(actions)>2 and short_list(r['label'] for r in rows if r['kind']=='pilot confirms') == blocks_until:
        # The gate already names this confirmation; retain the editable values
        # instead of spending two of three lines on the same physical answer.
        actions.remove('pilot confirms')
    selected = actions[:2 if blocks_until else 3]
    lines = []
    for kind in ('pilot sets', 'pilot confirms', 'read', 'MSP write'):
        if kind not in selected:
            continue
        matching = [r for r in rows if r['kind']==kind]
        if kind == 'MSP write':
            fields = unique(r['api']+('.'+r['field'] if r['field'] else '')
                            for r in matching if r['api'])
            items = unique(r['api'] for r in matching if r['api']) if len(fields)>3 else fields
        elif kind == 'read':
            # Displayed English readings take precedence over transport inventory.
            matching.sort(key=lambda r: r['api'] is not None)
            items = []
            for row in matching:
                text = row['label']
                if text.startswith('{') and text.endswith('}'):
                    # Dynamic channel captions are expressions in the model;
                    # show their literal English stem and runtime placeholder.
                    stem = literal(Lua(text[1:-1]).tokens[:1])
                    if stem:
                        text = stem+'{n}'
                items.append(text)
        else:
            items = [r['label'] for r in matching]
        lines.append(prefixes[kind]+': '+short_list(items))
    if blocks_until:
        lines.append('blocks until: '+blocks_until)
    text = '<b>'+mermaid_text(short(card['title']))+'</b>'
    return text+''.join('<br/>'+mermaid_text(line) for line in lines), strongest


def markdown(model):
    out = ['---', 'title: Helicopter wizard flow', '---', '', '# Helicopter wizard flow', '',
           'Generated by bin/wizard/flow.py - do not edit by hand.', '',
           'The diagram follows the current model card and all 19 steps in controller order. '
           'Cards built by loops or runtime conditions are templates: alternatives can appear together here. '
           'Full source expressions and Configurator references are in [the JSON model](helicopter-wizard-flow.json).', '',
           'Legend: blue = pilot sets; green = read; orange = pilot confirms; red = MSP write; grey = gate. '
           'A dashed purple border means **differs from the Configurator** or **beyond the Configurator** '
           'as recorded in source-map.json; a thin grey border means the mapped flow is the same. '
           'Each card is one node, colored by its strongest kind: write, confirms, sets, read, then gate. '
           'Details name up to three action groups; long lists end in "...". '
           'Diamonds mark conditional step validation; simple confirmation gates use a final "blocks until" line. '
           'Arrows between cards show source order, '
           'including conditional alternatives, rather than callback execution order.', '', '```mermaid', 'flowchart LR']
    count = 0
    for phase in 'ABCD':
        out += [f'  subgraph {phase}["Phase {phase}"]', '    direction TB']
        previous_step = None
        for step in (s for s in model['steps'] if s['phase']==phase):
            sid = 'S'+str(step['number'])
            title = ('Model: ' if not step['number'] else str(step['number'])+'. ')+step['title']
            out += [f'    subgraph {sid}["{mermaid_text(title)}"]', '      direction TB']
            previous = None
            conditional_gate, confirmations = step_gate(step)
            for ci, card in enumerate(step['cards']):
                node = f'{sid}c{ci}'
                blocks = confirmations if not conditional_gate and ci==len(step['cards'])-1 else ''
                text, kind = card_node(card, blocks)
                out.append(f'      {node}["{text}"]:::k{KINDS.index(kind)}')
                if any(r['deviation'] for r in card['rows']) or any(s!='same' for s in card['configurator_status']):
                    out.append(f'      class {node} deviation')
                if previous:
                    out.append(f'      {previous} --> {node}')
                previous = node; count += 1
            if conditional_gate:
                node = f'{sid}gate'
                text = 'Advance?<br/>validation passes'
                if confirmations:
                    text += '<br/>'+mermaid_text(confirmations)
                out.append(f'      {node}{{"{text}"}}:::k4')
                if any(r['deviation'] for c in step['cards'] for r in c['rows'] if r['kind']=='gate'):
                    out.append(f'      class {node} deviation')
                out += [f'      {previous} --> {node}', f'      {node} -->|blocked| {node}']
                count += 1
            out.append('    end')
            if previous_step:
                out.append(f'    {previous_step} --> {sid}')
            previous_step = sid
        out.append('  end')
    out += ['  A --> B --> C --> D']
    for i, color in enumerate(COLORS):
        out.append(f'  classDef k{i} fill:{color},stroke:#9ca3af,stroke-width:1px')
    out += ['  classDef deviation stroke:#7e22ce,stroke-width:2px,stroke-dasharray:5 3', '```', '',
            'MSP writes include deferred dirty records and immediate commands. The inventory below '
            'lists source-level writes; the JSON retains each originating expression. '
            'MSP reads here distinguish step-triggered reads from the shared startup/poll transport.', '',
            '| Step | Cards | Pilot sets | Pilot confirms | MSP reads | MSP writes | Configurator status |',
            '| --- | --- | --- | --- | --- | --- | --- |']
    def cell(values):
        return '<br/>'.join(unique(v.replace('|', '&#124;').replace('\n', ' ') for v in values)) or '—'
    for step in model['steps']:
        rows = [r for c in step['cards'] for r in c['rows']]
        values = [f"{step['number'] or 'Model'}. {step['title']}", cell(c['title'] for c in step['cards']),
                  cell(r['label'] for r in rows if r['kind']=='pilot sets'),
                  cell(r['label'] for r in rows if r['kind']=='pilot confirms'),
                  cell(step['msp_reads']), cell(step['msp_writes']),
                  cell(unique(step['configurator_status']+[s for c in step['cards'] for s in c['configurator_status'] if s!='same']))]
        out.append('| '+' | '.join(values)+' |')
    out += ['', f'Diagram: {count} nodes; {len(model["steps"])-1} numbered steps plus the model card.', '']
    return '\n'.join(out), count


def generate(root):
    model = build_model(root)
    md, count = markdown(model)
    return {OUTPUT.as_posix()+'.md': md, OUTPUT.as_posix()+'.json': json.dumps(model, ensure_ascii=False, indent=2)+'\n'}, count


def check(root, outputs, stream=sys.stdout):
    okay = True
    for name, expected in outputs.items():
        path = root/name
        actual = path.read_bytes().decode('utf-8') if path.exists() else ''
        if actual != expected:
            okay = False
            stream.writelines(difflib.unified_diff(actual.splitlines(True), expected.splitlines(True),
                                                  fromfile=name, tofile=name+' (generated)'))
    return okay


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Compare both files in memory; print unified diffs and exit 1 on drift')
    args = parser.parse_args()
    root = Path.cwd()
    outputs, count = generate(root)
    if args.check:
        if not check(root, outputs):
            return 1
    else:
        for name, text in outputs.items():
            (root/name).write_bytes(text.encode('utf-8'))
    print(f'Wizard flow: 19 steps + model, {count} nodes; '+('both generated files match' if args.check else 'Markdown and JSON generated'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
