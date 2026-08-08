// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// https://astro.build/config
export default defineConfig({
	// Update once the Netlify domain is known (used for sitemap + canonical URLs).
	site: 'https://linkerd-playground.netlify.app',
	integrations: [
		starlight({
			title: 'linkerd-playground',
			description:
				'Hands-on demos exploring Linkerd, service-mesh identity, and cross-infrastructure trust.',
			customCss: ['./src/styles/theme.css'],
			social: [
				{
					icon: 'github',
					label: 'GitHub',
					href: 'https://github.com/oletizi/linkerd-playground',
				},
			],
			// Sidebar is populated per demo section in Phase 1.
			sidebar: [],
		}),
	],
});
