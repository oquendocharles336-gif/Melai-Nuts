# Melai Nuts — Design guide

One look across the customer, staff, owner and rider screens and the admin website. Use the tokens
below; **never hard-code a colour, font size or spacing in a screen** (grep for `Color(0x` in
`lib/features` should find nothing).

## 1. Colour tokens — `lib/core/theme/app_colors.dart`

| Token | Hex | Use |
|---|---|---|
| `canvas` | `#FDFBF7` | Screen background |
| `surface` | `#FFF8F4` | App bar / header strip |
| `surfaceContainer` | `#FAF6EE` | Cards, panels |
| `border` | `#E8E2D9` | Card borders, dividers |
| `primary` | `#A06235` | Main buttons, links, active states (peanut brown) |
| `primaryDark` | `#875129` | Pressed / hover |
| `primaryContainer` | `#FFDCC6` | Selected chips, unread rows |
| `darkBrown` | `#4A2C18` | Headings, loyalty card |
| `textPrimary` | `#201B15` | Body text |
| `textSecondary` | `#6B645D` | Labels, metadata (4.5:1 on every light surface) |
| `success` / `successBg` | `#33713E` / `#EAF3EC` | Completed, in stock, money received |
| `warning` / `warningBg` | `#91571C` / `#FDF1E3` | Low stock, saved (offline) data, pending |
| `error` / `errorBg` | `#B43939` / `#FFDAD6` | Errors, destructive buttons, out of stock |
| `roleOwner` / `roleStaff` / `roleDelivery` / `roleCustomer` | | Portal accents and role badges |
| `heroGradientStart` / `heroGradientEnd`, `primaryDeep`, `loyaltyGradientEnd`, `gold`, `productCardGradientStart` | | Banner and card gradients only |

Contrast: every text/background pair above meets WCAG AA (4.5:1); `test/accessibility_contrast_test.dart`
checks it. Never use colour alone to carry meaning — status chips also have a text label and icon.

## 2. Type — `lib/core/theme/app_text_styles.dart`

Plus Jakarta Sans (Google Fonts, with a system sans-serif fallback offline).

| Style | Size / weight | Use |
|---|---|---|
| `headlineLg` | 26 / bold | Screen hero numbers |
| `headlineMd` | 22 / bold | Screen titles inside the body |
| `headlineSm` | 18 / semibold | Section titles |
| `titleMd` | 16 / semibold | Card titles |
| `bodyLg` / `bodyMd` / `bodySm` | 16 / 14 / 12 | Text |
| `labelLg` / `labelMd` / `labelSm` | 14 / 12 / 11 | Buttons, chips, captions |

Text respects the system font size (no fixed `textScaler`); layouts use `Wrap`, `Expanded` and
`maxLines + ellipsis` so 130 % text does not overflow.

## 3. Spacing and shape — `lib/core/theme/app_spacing.dart`

`xs2 4 · xs 8 · sm 12 · md 16 (screen gutter) · lg 24 · xl 32 · xl2 48`.
Radius: `radiusSm 8` (inputs, chips) · `radiusMd 16` (cards) · `radiusLg 24` (sheets, dialogs).
Shadows: `AppShadows.sm` for cards only.

## 4. Components — `lib/core/widgets/`

| Need | Use | Not |
|---|---|---|
| Text input | `AppTextField` (label, hint, counter, formatters, autofill, next/submit action) | raw `TextField` without label |
| Date | `DateFormField` | free-typed dates |
| Main action | `PrimaryButton` (full width, shows a spinner while `loading`, disabled while busy) | two primary buttons side by side |
| Secondary action | `SecondaryButton` / `OutlinedButton` | |
| Destructive confirm | `ConfirmDialog.delete / remove / discard / show(destructive: true)` — Cancel is focused by default, the destructive button is red | `showDialog` with ad-hoc text |
| Leaving a dirty form | `UnsavedChangesGuard` | |
| Loading / empty / error | `DataStateView`, `StateLoadingView`, `StateEmptyView`, `StateErrorView` (with Retry) | a bare spinner or blank screen |
| Lists | `AppSearchBar` + `SortFilterButton` + `ActiveFilterChips`; `PagedListView` for server paging | `ListView(children: [...])` for long lists |
| Saved / offline data | `LastUpdatedBanner`, `OfflineBanner` | |
| Info / warning strip | `InfoBanner` | |
| Permission ask | `PermissionRationaleDialog` → system prompt → `PermissionDeniedDialog` | asking at app start |

Touch targets are at least **48 × 48 dp** (icon buttons have a `tooltip`, which is also the
screen-reader label).

## 5. Layout and responsiveness

* Phones first (360 dp wide). Gutter 16. One column.
* Grids use `SliverGridDelegateWithMaxCrossAxisExtent` (product cards ≈ 240 dp, categories ≈ 260 dp),
  so phones get 2 columns and tablets / web get 3–5 automatically.
* Long content scrolls (`ListView` / `SingleChildScrollView`); sheets use `isScrollControlled` and
  cap at 85 % of the height.
* `test/responsive_layout_test.dart` renders shared screens at **360, 768 and 1280** px and fails on
  any overflow.

## 6. Writing (microcopy)

* Plain words, sentence case, no jargon or error codes: “We couldn't reach the server. Check your
  internet and try again.”
* Buttons say what happens: “Delete address”, “Place order”, not “OK”.
* Errors say what to fix: “Phone must be 11 digits starting with 09.”
* Every new user-facing string goes into **both** `lib/l10n/app_en.arb` and `app_fil.arb`
  (`test/localization_test.dart` fails if one is missing).

## 7. Motion

`lib/core/widgets/motion.dart` — `FadeSlideIn` (≈450 ms, staggered), `Pressable` (120 ms press
scale), `SkeletonBox` (loading shimmer). `FadeSlideIn` is skipped when the system “reduce motion /
remove animations” setting is on.

## 8. Admin website

Tokens in `admin/resources/css/app.css` and `melai.css` (`--accent`, `--ok`, `--warn`, `--bad`, `--ink`, `--muted`,
`--line` …, Inter font); buttons `.btn`, `.btn.primary`, `.btn.danger-solid` (`melai.css`); destructive actions use
the shared confirm modal (`<x-confirm-modal />` in the panel layout + `data-confirm` attributes)
instead of the browser's `confirm()`.
