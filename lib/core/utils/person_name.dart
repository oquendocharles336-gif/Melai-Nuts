/// A customer's name as First Name and Last Name.
///
/// The database keeps one `full_name` value, so this composes it
/// and splits it back for forms and display.
class PersonName {
  final String first;
  final String last;

  const PersonName({this.first = '', this.last = ''});

  /// Words that begin a Filipino / Spanish surname ("Dela Cruz", "De los Reyes").
  static const Set<String> _surnameParticles = {
    'de', 'del', 'dela', 'delos', 'la', 'las', 'los', 'san', 'santa', 'sta', 'sta.', 'sto', 'sto.', 'santo',
  };
  static final RegExp _initial = RegExp(r'^\p{L}\.?$', unicode: true);

  /// Splits [fullName]. A lone initial (e.g. "D.") is ignored/dropped.
  factory PersonName.parse(String fullName) {
    var words = fullName.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return const PersonName();
    if (words.length == 1) return PersonName(first: words.first);

    // If there is a lone single-letter middle token (e.g. "Juan D. Dela Cruz"), filter it out.
    for (var i = 1; i < words.length - 1; i++) {
      if (_initial.hasMatch(words[i])) {
        words.removeAt(i);
        break;
      }
    }

    if (words.length == 1) return PersonName(first: words.first);

    var lastStart = words.length - 1;
    while (lastStart > 1 && _surnameParticles.contains(words[lastStart - 1].toLowerCase())) {
      lastStart--;
    }
    return PersonName(
      first: words.sublist(0, lastStart).join(' '),
      last: words.sublist(lastStart).join(' '),
    );
  }

  /// The single value stored in the database.
  String get fullName {
    return [
      first.trim(),
      last.trim(),
    ].where((part) => part.isNotEmpty).join(' ');
  }
}
