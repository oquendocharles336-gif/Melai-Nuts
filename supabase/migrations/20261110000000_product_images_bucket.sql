-- Create public storage bucket for product images
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'product-images',
    'product-images',
    true,
    2097152, -- 2 MB
    ARRAY['image/jpeg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO UPDATE SET
    public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

-- Storage RLS policies for product-images bucket
-- Anyone can read product images
CREATE POLICY "Product images are publicly accessible"
ON storage.objects FOR SELECT
USING (bucket_id = 'product-images');

-- Only owner/admin staff accounts can insert, update, delete product images
CREATE POLICY "Admins can insert product images"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (
    bucket_id = 'product-images' AND
    EXISTS (
        SELECT 1 FROM public.staff_members s
        WHERE s.firebase_uid = public.current_firebase_uid()
          AND s.is_active
          AND s.role = 'owner'
    )
);

CREATE POLICY "Admins can update product images"
ON storage.objects FOR UPDATE
TO authenticated
USING (
    bucket_id = 'product-images' AND
    EXISTS (
        SELECT 1 FROM public.staff_members s
        WHERE s.firebase_uid = public.current_firebase_uid()
          AND s.is_active
          AND s.role = 'owner'
    )
);

CREATE POLICY "Admins can delete product images"
ON storage.objects FOR DELETE
TO authenticated
USING (
    bucket_id = 'product-images' AND
    EXISTS (
        SELECT 1 FROM public.staff_members s
        WHERE s.firebase_uid = public.current_firebase_uid()
          AND s.is_active
          AND s.role = 'owner'
    )
);
