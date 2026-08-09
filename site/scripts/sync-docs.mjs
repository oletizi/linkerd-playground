/**
 * sync-docs — the demo's long-form docs have one source of truth: the canonical
 * markdown under demos/<slug>/ at the repo root. This regenerates the matching
 * site pages from it, so the site never drifts from the docs a reader would
 * follow against the actual code.
 *
 * Per demo section under src/content/docs/demos/<slug>/, for each entry in DOCS
 * that has a matching ../../demos/<slug>/<src>, it strips the source H1
 * (Starlight renders the title from frontmatter), rewrites cross-document links
 * to the right target (sibling site page, or a stable GitHub URL for files with
 * no site page), prepends Starlight frontmatter, and writes the page.
 *
 * Runs as the `prebuild` / `predev` npm hooks (and can be run by hand).
 */
import { readFileSync, writeFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, '..', '..');
const siteDemosDir = join(here, '..', 'src', 'content', 'docs', 'demos');
const repoDemosDir = join(repoRoot, 'demos');
const ghBlobBase = 'https://github.com/oletizi/linkerd-playground/blob/main/demos';

// Source markdown -> generated site page. Keyed by source filename.
const DOCS = [
	{
		src: 'MANUAL.md',
		dest: 'manual.md',
		page: 'manual',
		title: 'The manual',
		description:
			'A from-scratch, no-scripts walkthrough of every config file, field, and command behind this demo.',
	},
	{
		src: 'PRODUCTION-NOTES.md',
		dest: 'production-notes.md',
		page: 'production-notes',
		title: 'Production notes',
		description:
			'How this teaching demo deviates from production best practices, and what to do instead.',
	},
];

// Source files that have a site page get their links rewritten to that page;
// everything else (e.g. README.md) points at a stable GitHub URL.
const sitePageBySrc = Object.fromEntries(DOCS.map((d) => [d.src, d.page]));

function escapeRe(s) {
	return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function frontmatter({ title, description }) {
	return ['---', `title: ${title}`, `description: ${description}`, '---', '', ''].join('\n');
}

function transform(markdown, slug) {
	// Starlight renders the page title from frontmatter — drop the source H1.
	let out = markdown.replace(/^#\s.*\r?\n/, '');

	// Cross-document links to a doc that has a site page -> that site page,
	// preserving any #anchor. `](MANUAL.md#foo)` -> `](/demos/<slug>/manual/#foo)`.
	for (const [srcName, page] of Object.entries(sitePageBySrc)) {
		const re = new RegExp(`\\]\\(${escapeRe(srcName)}(#[^)]*)?\\)`, 'g');
		out = out.replace(re, (_m, anchor) => `](/demos/${slug}/${page}/${anchor || ''})`);
	}

	// README has no site page -> stable GitHub URL (preserve any #anchor).
	out = out.replace(
		/\]\(README\.md(#[^)]*)?\)/g,
		(_m, anchor) => `](${ghBlobBase}/${slug}/README.md${anchor || ''})`,
	);

	return out.replace(/^\s+/, '');
}

const slugs = readdirSync(siteDemosDir).filter((name) =>
	statSync(join(siteDemosDir, name)).isDirectory(),
);

let written = 0;
for (const slug of slugs) {
	for (const doc of DOCS) {
		const source = join(repoDemosDir, slug, doc.src);
		if (!existsSync(source)) {
			// A site section without a source doc is a real gap — surface it.
			console.warn(`[sync-docs] no ${doc.src} for demo "${slug}" at ${source}`);
			continue;
		}
		const out = join(siteDemosDir, slug, doc.dest);
		writeFileSync(out, frontmatter(doc) + transform(readFileSync(source, 'utf8'), slug));
		console.log(`[sync-docs] ${slug}/${doc.dest} <- ${doc.src}`);
		written += 1;
	}
}
console.log(`[sync-docs] done (${written} page${written === 1 ? '' : 's'}).`);
