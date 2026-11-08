# Melai Nuts — Design guide

One look across the customer, staff, owner and rider screens and the admin website. Use the tokens
below; **never hard-code a colour, font size or spacing in a screen** (grep for `Color(0x` in
`lib/features` should find nothing).

## 1. Colour tokens — `lib/core/theme/app_colors.dart`

"Warm Harvest": warm cream surfaces with a roasted-orange accent. The values below are copied from
`app_colors.dart`, which is the source of truth; if they ever differ, the code wins and this table
should be updated.

**Surfaces**

| Token | Hex | Use |
|---|---|---|
| `canvas` | `#FFF9F0` | Screen background (warm cream) |
| `surface` | `#FFF9F0` | Header strip |
| `surfaceContainer` | `#FFFFFF` | Cards, panels |
| `surfaceContainerHigh` | `#FFEFD6` | Raised fills, skeleton placeholders |
| `surfaceContainerLow` | `#FFFCF6` | Quiet panels, info banners |
| `ivory` | `#FFFCF6` | Chips, sheets and cards on dark backgrounds |
| `inputFill` | `#FFF6E8` | Filled text fields |
| `border` | `#F3E1C4` | Hairlines, card borders, dividers |
| `outlineButton` | `#E5B574` | Outlined secondary buttons |
| `outlineVariant` | `#D7C2B7` | Softer outlines |

**Brand**

| Token | Hex | Use |
|---|---|---|
| `primary` | `#BF4409` | Main buttons, links, active states, accent text (roasted orange) |
| `primaryDark` | `#9A3412` | Pressed / hover |
| `primaryContainer` | `#FFE6C2` | Selected chips, unread rows |
| `onPrimary` | `#FFFFFF` | Text and icons on `primary` and the orange hero |
| `ink` / `textPrimary` | `#1F120B` | Headings and body text (warm near-black) |
| `darkBrown` | `#2A1810` | High-emphasis headings |
| `secondaryBrown` | `#7B563F` | Secondary brown accents |
| `textSecondary` | `#6E5E50` | Labels, metadata |
| `textMuted` | `#52443B` | Supporting text (on-surface-variant) |

**Status**

| Token | Hex | Use |
|---|---|---|
| `success` / `successBg` | `#33713E` / `#EAF3EC` | Completed, in stock, money received |
| `warning` / `warningBg` | `#91571C` / `#FDF1E3` | Low stock, saved (offline) data, pending |
| `error` / `errorBg` | `#B43939` / `#FFDAD6` | Errors, destructive buttons, out of stock |

**Roles** — portal accents and role badges

| Token | Hex |
|---|---|
| `roleOwner` | `#BF4409` |
| `roleStaff` | `#0F766E` |
| `roleDelivery` | `#387B44` |
| `roleCustomer` | `#91571C` |

**Banners, gradients and accents** — only for these surfaces

| Token | Hex | Use |
|---|---|---|
| `heroGradientStart` (= `appBar`) / `heroGradientEnd` | `#C2410C` / `#C8480A` | Orange hero and app bar |
| `primaryDeep` | `#9A3412` | Deep end of promo gradients |
| `loyaltyGradientEnd` | `#C8480A` | Loyalty card gradient |
| `gold` | `#FFF9EC` | Cream text and icons on the orange hero and on dark brown |
| `honey` / `honeyDeep` | `#FFC94D` / `#F5A623` | Rewards card, promo badges, count badges (dark text on them) |
| `sunStart` / `sunEnd` | `#FFF6E3` / `#FFD98F` | Sunny full-screen background (splash, welcome, sign in) |
| `productCardGradientStart` | `#BE7B47` | Product card gradient |

Contrast: `test/accessibility_contrast_test.dart` checks that these pairs meet WCAG AA (4.5:1):
`textPrimary`, `textMuted`, `textSecondary`, `success`, `warning`, `error` and `darkBrown` on every
light surface (`ivory`, `canvas`, `surfaceContainerLow`, `inputFill`, and the three status
backgrounds); white on `primary`; `primary` on white and on `canvas`; white and `gold` on the hero
gradient; `ink`, `primaryDark` and `textMuted` on the sunny background; `ink` on `honey` /
`honeyDeep`; and `gold` on `darkBrown`. Add a check there before using a new text/background pair.
Never use colour alone to carry meaning — status chips also have a text label and icon.

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
| Product tile (storefront) | `ProductCard` with `onDecrease` (Add → − qty + stepper), `productGridDelegate` for grids | a card with its own add button |
| Loading a product grid | `DataStateView(loadingBuilder: (_) => const ProductGridSkeleton())` | a spinner where cards will be |
| Cart in an app bar | `CartIconButton` (count badge that bumps on change) | a hand-drawn badge `Stack` |
| Cart → Checkout → Confirmed | `CheckoutSteps(current: 0 / 1 / 2)` | |
| Customer-flow navigation | `FadeSlideRoute` | `MaterialPageRoute` in storefront screens |

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
