import 'blocked_words_list.g.dart';

/// The profanity check for product reviews and order special instructions
/// (English and Filipino / Tagalog).
///
/// The list is ONE shared file, moderation/blocked_words.json, copied into
/// [blocked_words_list.g.dart] by `python3 scripts/sync_blocked_words.py`.
/// The same algorithm runs on the website (admin/app/Support/BlockedWords.php,
/// admin/resources/js/blocked-words.js) and in the database
/// (public.contains_blocked_words, migration 20261119030000), which refuses the
/// write even if this check were skipped. moderation/test_cases.json is run
/// against every copy (test/blocked_words_test.dart for this one).
///
/// It catches any case, repeated letters (fuuuck), letters split by spaces or
/// symbols (f u c k, f.u.c.k), leetspeak (@ 4 = a, 1 ! | = i, 0 = o, 3 = e,
/// $ 5 = s, 7 = t) and accents (puñeta). Ordinary words match whole words only,
/// so "class", "assess" or "Batangas" pass; only the few roots also match
/// inside longer words.
class BlockedWords {
  BlockedWords._();

  /// "Please keep your message respectful."
  static const String message = blockedWordsMessage;

  static const Map<String, String> _accents = {
    'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
    'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i', 'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o',
    'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u', 'ñ': 'n',
  };
  static const Map<String, String> _leet = {
    '@': 'a', '4': 'a', '1': 'i', '!': 'i', '|': 'i', '0': 'o', '3': 'e', r'$': 's', '5': 's', '7': 't',
  };
  static final RegExp _space = RegExp(r'\s+');
  static final RegExp _nonLetters = RegExp(r'[^a-z]+');
  static final RegExp _leetTrigger = RegExp(r'[a-z@$!|]');
  static final RegExp _repeats = RegExp(r'(.)\1+');

  static final Set<String> _allow = blockedWordsAllow.toSet();
  static final Map<String, int> _wordMin = () {
    final m = <String, int>{};
    for (final w in blockedWordsWords) {
      final k = _collapse(w);
      final prev = m[k];
      if (prev == null || w.length < prev) m[k] = w.length;
    }
    return m;
  }();
  static final List<String> _roots = blockedWordsRoots.map(_collapse).toList();
  static final List<String> _longWords =
      blockedWordsWords.where((w) => w.length >= 4).map(_collapse).toList();
  static final List<String> _phrases =
      blockedWordsPhrases.map((p) => p.split(_space).map(_collapse).join(' ')).toList();

  /// True when [text] contains a blocked word.
  static bool contains(String? text) {
    if (text == null || text.trim().isEmpty) return false;
    final plain = <String>[];
    final leet = <String>[];
    final squeezed = <String>[];
    final t = _map(text.toLowerCase(), _accents);
    for (final chunk in t.split(_space)) {
      if (chunk.isEmpty) continue;
      final variants = <String>[chunk];
      if (_leetTrigger.hasMatch(chunk)) variants.add(_map(chunk, _leet));
      for (var i = 0; i < variants.length; i++) {
        final v = variants[i];
        final parts = v.split(_nonLetters).where((p) => p.isNotEmpty).toList();
        if (i == 0) {
          plain.addAll(parts);
          if (variants.length == 1) leet.addAll(parts);
        } else {
          leet.addAll(parts);
        }
        squeezed.add(v.replaceAll(_nonLetters, ''));
      }
    }
    for (final w in [...plain, ...leet, ...squeezed]) {
      if (_isWord(w)) return true;
    }
    for (final seq in [plain, leet]) {
      for (final joined in _runs(seq)) {
        if (_allow.contains(joined)) continue;
        final cj = _collapse(joined);
        if (_isWord(joined) || _longWords.any(cj.contains)) return true;
      }
      final line = ' ${seq.map(_collapse).join(' ')} ';
      if (_phrases.any((p) => line.contains(' $p '))) return true;
    }
    return false;
  }

  static bool _isWord(String w) {
    if (w.isEmpty || _allow.contains(w)) return false;
    final forms = <String>[w];
    if (w.length >= 4 && w.endsWith('s')) forms.add(w.substring(0, w.length - 1));
    if (w.length >= 5 && w.endsWith('es')) forms.add(w.substring(0, w.length - 2));
    for (final f in forms) {
      final min = _wordMin[_collapse(f)];
      if (min != null && f.length >= min) return true;
    }
    final cw = _collapse(w);
    return _roots.any(cw.contains);
  }

  /// Three or more single letters in a row (f u c k), joined.
  static List<String> _runs(List<String> seq) {
    final out = <String>[];
    var run = <String>[];
    for (final tok in [...seq, '']) {
      if (tok.length == 1) {
        run.add(tok);
        continue;
      }
      if (run.length >= 3) out.add(run.join());
      run = <String>[];
    }
    return out;
  }

  static String _collapse(String s) => s.replaceAllMapped(_repeats, (m) => m[1]!);

  static String _map(String s, Map<String, String> table) {
    final b = StringBuffer();
    for (final rune in s.runes) {
      final ch = String.fromCharCode(rune);
      b.write(table[ch] ?? ch);
    }
    return b.toString();
  }
}
