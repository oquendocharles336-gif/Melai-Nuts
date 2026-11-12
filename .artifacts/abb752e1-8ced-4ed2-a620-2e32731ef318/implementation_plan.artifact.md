# Implementation Plan - Product Photos Feature

Add comprehensive product photo management: Supabase storage bucket & RLS policies, Flutter admin owner UI for uploading/managing photos, Laravel admin web interface updates, and client-side (Flutter customer/staff & Blade web shop) photo rendering across lists, details, cart, checkout, orders, and receipts.

## User Review Required

> [!IMPORTANT]
> - A new Supabase migration will create the `product-images` public storage bucket and set up RLS security policies allowing public read and owner/admin insert/update/delete.
> - Up to 5 photos per product are supported, stored as public URLs in `products.images`.

## Proposed Changes

### 1. Supabase Migration
#### [NEW] [20261110000000_product_images_bucket.sql](file:///C:/Users/chach/Melai-Nuts-Retail-main-master/supabase/migrations/20261110000000_product_images_bucket.sql)
- Create public bucket `product-images`.
- Add storage policies for public read and owner/admin write/delete.

### 2. Flutter App (Admin / Owner & Widgets)
#### [MODIFY] [add_product_screen.dart](file:///C:/Users/chach/Melai-Nuts-Retail-main-master/lib/features/products/screens/add_product_screen.dart) & [edit_product_screen.dart](file:///C:/Users/chach/Melai-Nuts-Retail-main-master/lib/features/products/screens/edit_product_screen.dart)
- Add "Photos" section using `image_picker`, thumbnail grid, main photo selection, removal, and compression/resize before uploading to Supabase storage.
#### [MODIFY] [product_variant_saver.dart](file:///C:/Users/chach/Melai-Nuts-Retail-main-master/lib/features/products/product_variant_saver.dart) & [product_pricing_screen.dart](file:///C:/Users/chach/Melai-Nuts-Retail-main-master/lib/features/products/screens/product_pricing_screen.dart)
- Ensure existing images are preserved across variant and pricing steps.

### 3. Laravel Admin Website
#### [MODIFY] [ops/products.blade.php](file:///C:/Users/chach/Melai-Nuts-Retail-main-master/admin/resources/views/ops/products.blade.php) & [OperationsController.php](file:///C:/Users/chach/Melai-Nuts-Retail-main-master/admin/app/Http/Controllers/Ops/OperationsController.php)
- Add photo thumbnails and admin-only "Edit photos" action, route, controller logic, FormRequest validation, Supabase upload via service, activity logging, and catalog cache clearing.

### 4. Client Display (Customer, Staff & Web Shop)
#### [MODIFY] Customer screens, widgets, staff POS/inventory screens, and Laravel web shop views
- Render product photos with cached network image, fallback art, gallery view on product details, and small thumbnails in orders/receipts.

### 5. Localization & Tests
- Add l10n strings in `app_en.arb` & `app_fil.arb`.
- Add Laravel feature test and Flutter widget tests.

## Verification Plan

### Automated Tests
- Run Laravel feature tests and Flutter tests.
- Run `flutter analyze`.

### Manual Verification
- Deploy migration (`supabase db test` or SQL editor).
- Test admin product photo upload in Flutter app and Laravel admin.
- Verify photo rendering in customer storefront and staff POS.
