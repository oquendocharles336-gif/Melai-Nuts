/// A customer's name as First Name, Middle Initial and Last Name.
///
/// The database keeps one `full_name` value, so this composes it
/// ("Juan D. Dela Cruz") and splits it back for forms and display.
class PersonName {
  final String first;
  final String middleInitial;
  final String last;

  const PersonName({this.first = '', this.middleInitial = '', this.last = ''});

  /// Words that begin a Filipino / Spanish surname ("Dela Cruz", "De los Reyes").
  static const Set<String> _surnameParticles = {
    'de', 'del', 'dela', 'delos', 'la', 'las', 'los', 'san', 'santa', 'sta', 'sta.', 'sto', 'sto.', 'santo',
  };
  static final RegExp _initial = RegExp(r'^\p{L}\.?$', unicode: true);

  /// Splits [fullName]. A lone initial marks the boundary exactly. Without one,
  /// the surname is the last word, plus any particle words before it.
  factory PersonName.parse(String fullName) {
    final words = fullName.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return const PersonName();
    if (words.length == 1) return PersonName(first: words.first);

    for (var i = 1; i < words.length - 1; i++) {
      if (_initial.hasMatch(words[i])) {
        return PersonName(
          first: words.sublist(0, i).join(' '),
          middleInitial: words[i].substring(0, 1).toUpperCase(),
          last: words.sublist(i + 1).join(' '),
        );
      }
    }

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
    final initial = middleInitial.trim();
    return [
      first.trim(),
      if (initial.isNotEmpty) '${initial.toUpperCase()}.',
      last.trim(),
    ].where((part) => part.isNotEmpty).join(' ');
  }
}
