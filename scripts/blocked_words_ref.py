"""Reference implementation of the Melai Nuts blocked-words check (moderation/README.md).

The website (PHP + JavaScript), the app (Dart) and the database (SQL) each carry a port of this
same algorithm; scripts/test_blocked_words.py runs moderation/test_cases.json against all of them.
"""
import json
import os
import re

ACCENTS = str.maketrans('áàâäãéèêëíìîïóòôöõúùûüñ', 'aaaaaeeeeiiiiooooouuuun')
LEET = str.maketrans('@41!|03$57', 'aaiiioesst')
LEET_TRIGGER = re.compile(r'[a-z@$!|]')


def collapse(s: str) -> str:
    return re.sub(r'(.)\1+', r'\1', s)


class BlockedWords:
    def __init__(self, data: dict):
        self.allow = set(data.get('allow', []))
        self.word_min = {}
        for w in data.get('words', []):
            c = collapse(w)
            self.word_min[c] = min(self.word_min.get(c, 10**6), len(w))
        self.roots = [collapse(r) for r in data.get('roots', [])]
        self.long_words = [collapse(w) for w in data.get('words', []) if len(w) >= 4]
        self.phrases = [' '.join(collapse(p) for p in ph.split()) for ph in data.get('phrases', [])]

    def is_word(self, w: str) -> bool:
        if not w or w in self.allow:
            return False
        forms = [w]
        if len(w) >= 4 and w.endswith('s'):
            forms.append(w[:-1])
        if len(w) >= 5 and w.endswith('es'):
            forms.append(w[:-2])
        for f in forms:
            m = self.word_min.get(collapse(f))
            if m is not None and len(f) >= m:
                return True
        cw = collapse(w)
        return any(r in cw for r in self.roots)

    def _sequences(self, text: str):
        t = text.lower().translate(ACCENTS)
        plain, leet, squeezed = [], [], []
        for chunk in t.split():
            variants = [chunk]
            if LEET_TRIGGER.search(chunk):
                variants.append(chunk.translate(LEET))
            for i, v in enumerate(variants):
                parts = [p for p in re.split(r'[^a-z]+', v) if p]
                if i == 0:
                    plain.extend(parts)
                    if len(variants) == 1:
                        leet.extend(parts)
                else:
                    leet.extend(parts)
                squeezed.append(re.sub(r'[^a-z]+', '', v))
        return plain, leet, squeezed

    def _runs(self, seq):
        run = []
        for tok in seq + ['']:
            if len(tok) == 1:
                run.append(tok)
                continue
            if len(run) >= 3:
                yield ''.join(run)
            run = []

    def contains(self, text) -> bool:
        if not isinstance(text, str) or not text.strip():
            return False
        plain, leet, squeezed = self._sequences(text)
        for w in plain + leet + squeezed:
            if self.is_word(w):
                return True
        for seq in (plain, leet):
            for joined in self._runs(seq):
                cj = collapse(joined)
                if joined not in self.allow and (self.is_word(joined) or any(x in cj for x in self.long_words)):
                    return True
            line = ' ' + ' '.join(collapse(w) for w in seq) + ' '
            if any(' ' + p + ' ' in line for p in self.phrases):
                return True
        return False


def load(path=None) -> BlockedWords:
    path = path or os.path.join(os.path.dirname(__file__), '..', 'moderation', 'blocked_words.json')
    with open(path, encoding='utf-8') as f:
        return BlockedWords(json.load(f))


if __name__ == '__main__':
    import sys
    bw = load()
    for arg in sys.argv[1:]:
        print(arg, '->', bw.contains(arg))
