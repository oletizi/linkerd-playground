/**
 * sync-manuals — the demo manuals have one source of truth: the canonical
 * demos/<slug>/MANUAL.md at the repo root. This regenerates each demo's
 * site `manual.md` page from it, so the site never drifts from the manual a
 * reader would follow against the actual code.
 *
 * Runs as the `prebuild` npm hook (and can be run by hand). For every demo
 * section under src/content/docs/demos/<slug>/ that has a matching
 * ../../demos/<slug>/MANUAL.md, it strips the source H1 (Starlight renders the
 * title from frontmatter), rewrites the repo-relative README link to a stable
 * GitHub URL, prepends Starlight frontmatter, and writes manual.md.
 */
import { readFileSync, writeFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, '..', '..');
const siteDemosDir = join(here, '..', 'src', 'content', 'docs', 'demos');
const repoDemosDir = join(repoRoot, 'demos');
const ghBlobBase = 'https://github.com/oletizi/linkerd-playground/blob/main/demos';

const FRONTMATTER = [
	'---',
	'title: The manual',
	'description: A from-scratch, no-scripts walkthrough of every config file, field, and command behind this demo.',
	'---',
	'',
	'',
].join('\n');

function transform(markdown, slug) {
	return (
		markdown
			// Starlight renders the page title from frontmatter — drop the source H1.
			.replace(/^#\s.*\r?\n/, '')
			// repo-relative README link -> stable GitHub URL
			.replaceAll('](README.md)', `](${ghBlobBase}/${slug}/README.md)`)
			.replace(/^\s+/, '')
	);
}

const slugs = readdirSync(siteDemosDir).filter((name) =>
	statSync(join(siteDemosDir, name)).isDirectory(),
);

let written = 0;
for (const slug of slugs) {
	const source = join(repoDemosDir, slug, 'MANUAL.md');
	if (!existsSync(source)) {
		// A site section without a source manual is a real gap — surface it,
		// don't silently paper over it.
		console.warn(`[sync-manuals] no MANUAL.md for demo "${slug}" at ${source}`);
		continue;
	}
	const out = join(siteDemosDir, slug, 'manual.md');
	writeFileSync(out, FRONTMATTER + transform(readFileSync(source, 'utf8'), slug));
	console.log(`[sync-manuals] ${slug}: wrote manual.md from ${source}`);
	written += 1;
}
console.log(`[sync-manuals] done (${written} manual${written === 1 ? '' : 's'}).`);
