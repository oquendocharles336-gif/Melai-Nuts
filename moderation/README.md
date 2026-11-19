# Blocked words (reviews and special instructions)

Customers cannot post offensive or cursed words (English and Filipino / Tagalog) in:

- a product review comment ("Leave a review"), and
- the special instructions of an order ("Notes for the branch" on the website).

While they type, the field says **"Please keep your message respectful."** and the submit button is
disabled. The website server and the database check again, so the API cannot be used to get around it.

## The one list to edit: `blocked_words.json`

| key       | what it does                                                                                     |
|-----------|--------------------------------------------------------------------------------------------------|
| `words`   | blocked as **whole words** only (`ass` blocks "ass", "a$$", "asss", not "class" or "assess")       |
| `roots`   | blocked **anywhere inside** a word. Only for roots that never appear in innocent words (`fuck`, `tangina`) |
| `phrases` | several words in a row (`tang ina`, `anak ng puta`)                                                |
| `allow`   | never blocked, even if a rule above would match                                                  |
| `message` | the message shown to the customer                                                                |

Write terms in lowercase letters `a-z` only (no accents, digits or symbols): the check already reads
`@ 4` as `a`, `1 ! |` as `i`, `0` as `o`, `3` as `e`, `$ 5` as `s`, `7` as `t`, `ñ` as `n`, ignores
case and repeated letters (`fuuuuck`), and joins letters split by spaces or symbols (`f u c k`, `f.u.c.k`).

### After editing

```bash
python3 scripts/sync_blocked_words.py      # updates the app's copy and the SQL file
python3 scripts/test_blocked_words.py      # checks every copy against test_cases.json
```

Then run `supabase/repair/sync_blocked_words.sql` in the Supabase SQL editor so the database blocks the
same words. The website reads the JSON directly (nothing to do). Rebuild the app for its copy.

Add a line to `test_cases.json` for every tricky word (something that must be blocked, or an innocent
word that must stay allowed): every copy is tested against it.

## Where the check lives

| place                    | file                                                        |
|--------------------------|-------------------------------------------------------------|
| website server (Laravel) | `admin/app/Support/BlockedWords.php` (`Rules::respectful()`)  |
| website browser          | `admin/resources/js/blocked-words.js` (used by `shop.js`)     |
| app                      | `lib/core/moderation/blocked_words.dart` + generated list     |
| database (cannot be skipped) | `public.contains_blocked_words()` and two triggers, migration `20261119030000_blocked_words.sql` |

The database only checks **new or changed** text: old reviews and orders are left as they are.
