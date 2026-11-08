import { defineConfig } from 'vite';
import laravel from 'laravel-vite-plugin';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
    plugins: [
        laravel({
            input: ['resources/css/app.css', 'resources/css/melai.css', 'resources/js/app.js', 'resources/css/shop.css', 'resources/js/shop.js'],
            refresh: true,
        }),
        tailwindcss(),
    ],
});
