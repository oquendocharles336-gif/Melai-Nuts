# Implementation Plan - Remove Middle Initial (M.I.)

Remove the Middle Initial (M.I.) across the Melai Nuts app so accounts only have First Name and Last Name.

## User Review Required

> [!IMPORTANT]
> The database schema (`full_name`) remains unchanged. Stored names like "Juan D. Dela Cruz" will have the middle initial parsed out/ignored for display, showing "Juan Dela Cruz". Saving profile/registration will format as "First Last".

## Proposed Changes

### Core Utils & Widgets
#### [MODIFY] [person_name.dart](file:///C:/Users/chach/Melai-Nuts-Retail-main-master/lib/core/utils/person_name.dart)
- Remove `middleInitial` field and parsing.
- Update `fullName` getter to return `"First Last"`.
- Update `PersonName.parse(String fullName)` to filter out lone single-letter middle tokens when parsing existing names like "Juan D. Dela Cruz".

#### [MODIFY] [person_name_fields.dart](file:///C:/Users/chach/Melai-Nuts-Retail-main-master/lib/core/widgets/person_name_fields.dart)
- Remove `middleInitial` controller and M.I. `TextFormField`.
- Keep First Name and Last Name fields cleanly laid out.

### Features & Screens
#### [MODIFY] [register_screen.dart](file:///C:/Users/chach/Melai-Nuts-Retail-main-master/lib/features/auth/screens/register_screen.dart)
- Remove `_middleInitialController`, disposal, and usage.

#### [MODIFY] [edit_profile_screen.dart](file:///C:/Users/chach/Melai-Nuts-Retail-main-master/lib/features/customer/screens/edit_profile_screen.dart)
- Remove `_middleInitialController`, listeners, disposal, and usage.

#### [MODIFY] [customer_profile_screen.dart](file:///C:/Users/chach/Melai-Nuts-Retail-main-master/lib/features/customer/screens/customer_profile_screen.dart)
- Remove the "MIDDLE INITIAL" `_FieldRow`.

### Tests
#### [MODIFY] [person_name_test.dart](file:///C:/Users/chach/Melai-Nuts-Retail-main-master/test/person_name_test.dart)
- Update tests for new `PersonName` behavior (no `middleInitial`, parsing "Juan D. Dela Cruz" -> "Juan" / "Dela Cruz", single-word name, empty string).

## Verification Plan

### Automated Tests
- Run `flutter test test/person_name_test.dart`.
- Run `flutter analyze`.

### Manual Verification
- Review updated code.
