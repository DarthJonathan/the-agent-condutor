import adapter from '@sveltejs/adapter-node';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';
export default { preprocess: vitePreprocess(), kit: { adapter: adapter(), csp: { mode: 'auto', directives: { 'default-src': ['self'], 'script-src': ['self'], 'style-src': ['self', 'unsafe-inline'], 'connect-src': ['self'], 'img-src': ['self', 'data:'], 'object-src': ['none'], 'base-uri': ['self'], 'frame-ancestors': ['none'] } } } };
