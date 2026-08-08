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
			customCss: [
				// Self-hosted faces (bundled at build — no runtime font CDN).
				'@fontsource/space-grotesk/500.css',
				'@fontsource/space-grotesk/700.css',
				'@fontsource/ibm-plex-sans/400.css',
				'@fontsource/ibm-plex-sans/500.css',
				'@fontsource/ibm-plex-sans/600.css',
				'@fontsource/ibm-plex-mono/400.css',
				'@fontsource/ibm-plex-mono/500.css',
				// The mesh-schematic theme (last, so it wins the cascade).
				'./src/styles/theme.css',
			],
			social: [
				{
					icon: 'github',
					label: 'GitHub',
					href: 'https://github.com/oletizi/linkerd-playground',
				},
			],
			// One group per demo; the collection grows as demos are added.
			sidebar: [
				{
					label: 'SPIFFE across a boundary',
					items: [
						'demos/spiffe-cross-boundary/overview',
						'demos/spiffe-cross-boundary/concepts',
						'demos/spiffe-cross-boundary/manual',
						'demos/spiffe-cross-boundary/reference',
					],
				},
			],
		}),
	],
});
