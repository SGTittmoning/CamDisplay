#!/usr/bin/env python3
"""Sucht die set-e-Falle in Shell-Skripten: eine Funktion oder ein ganzes Skript,
dessen LETZTE Anweisung "[ cond ] && cmd" ist.

Ist cond falsch (ein voellig normaler Fall), liefert die Zeile Exit-Code 1. Das
wird zum Rueckgabewert der Funktion bzw. des Skripts - und unter "set -e" bricht
ein blanker Funktionsaufruf den Aufrufer dann sofort ab, BEVOR der eigentlich
beabsichtigte Rest laeuft (z.B. der reboot im Reboot-Guard). Ein Skript, das so
endet, meldet ausserdem Exit 1 und macht einen Type=oneshot-Dienst "failed".
Mitten in einer Funktion ist das Muster harmlos. Fix: abschliessendes
"return 0" (Funktion) bzw. "exit 0" (Skript).

shellcheck erkennt das nicht. Heuristik, kein vollstaendiger Shell-Parser -
reicht fuer die hier verwendete Schreibweise.

Aufruf: trap-scan.py <skript>...   Exit 1, wenn etwas gefunden wurde.
"""
import re
import sys

FUNC = re.compile(r'^(\s*)([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{(.*)$')


def strip_comment(line):
    return re.sub(r'\s+#.*$', '', line.rstrip())


def risky(stmt):
    s = strip_comment(stmt).strip().rstrip(';').strip()
    if not s or s.startswith('#'):
        return False
    if re.match(r'(if|elif|while|until|for|case)\b', s):
        return False
    if '&&' not in s:
        return False
    # "a && b || c" endet immer im letzten Zweig (z.B. "|| echo nein" / "|| true"):
    # definierter Status, keine Falle. Nur ein reines "a && b" liefert bei
    # falschem a den Exit-Code 1.
    return '||' not in s


def scan(path):
    lines = open(path, errors='ignore').read().split('\n')
    found, i, top_last = [], 0, None
    while i < len(lines):
        m = FUNC.match(lines[i])
        if m:
            indent, name, rest = m.groups()
            rest = strip_comment(rest).strip()
            if rest.endswith('}'):                                   # Einzeiler
                last_cmd = rest[:-1].strip().rstrip(';').split(';')[-1]
                if risky(last_cmd):
                    found.append((i + 1, 'Funktion ' + name, lines[i].strip()))
                i += 1
                continue
            j, last = i + 1, None
            while j < len(lines) and not re.match('^' + re.escape(indent) + r'\}\s*$', lines[j]):
                if lines[j].strip() and not lines[j].strip().startswith('#'):
                    last = (j + 1, lines[j])
                j += 1
            if last and risky(last[1]):
                found.append((last[0], 'Funktion ' + name, last[1].strip()))
            i = j + 1
            continue
        stripped = lines[i].strip()
        if stripped and not stripped.startswith('#') and not lines[i].startswith((' ', '\t')):
            top_last = (i + 1, lines[i])
        i += 1
    if top_last and risky(top_last[1]):
        found.append((top_last[0], 'Skriptende', top_last[1].strip()))
    return found


def main(paths):
    bad = 0
    for path in paths:
        for lineno, what, text in scan(path):
            print(f'{path}:{lineno}: {what} endet mit "[ cond ] && cmd" '
                  f'(set -e-Falle, "return 0"/"exit 0" ergaenzen): {text}')
            bad += 1
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
