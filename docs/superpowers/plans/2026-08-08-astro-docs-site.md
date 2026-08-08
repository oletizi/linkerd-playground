# Astro documentation site — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax. **Every UX/UI step is produced via /frontend-design.**

**Goal:** A themed Astro + Starlight documentation site for `linkerd-playground` — a demo-neutral, multi-demo hub whose product is the deep from-scratch manuals — deployed to Netlify.

**Architecture:** Astro + `@astrojs/starlight` in `site/`. Starlight provides the docs shell (sidebar, search, TOC, long-form + code rendering); /frontend-design owns the theme (the "mesh-schematic" visual identity) and the landing (the demo-index-as-a-mesh signature). Content is authored in Starlight's content collection; the SPIFFE/RetailCloud demo is demo #1.

**Tech Stack:** Astro, Starlight, Netlify (static). Node 20+. No demo-UI screenshot galleries.

**Design record:** `docs/superpowers/specs/2026-08-08-astro-docs-site-design.md` (approved). This plan implements it.

## Testing model (read first)

No unit suite. Each task's check is a **verification command / observation**: `npm run build` exits 0, `npm run dev` serves the page, the sidebar/nav resolves, links aren't broken, the page renders in a browser (captured via the browser tool). Mechanical checks (build, link-check) gate; visual checks are screenshots reviewed against the design direction.

## Global Constraints

- **Starlight, themed** — do not fork the docs shell; theme via custom CSS + component overrides only. Bespoke design lives in the theme + the landing.
- **Demo-neutral top level; scales to N demos.** Nothing SPIFFE-specific in the hub/nav chrome. The SPIFFE/RetailCloud demo is one section under `demos/`.
- **The manuals are the product.** Optimize for long, code-heavy reading: the "config block + per-field explanation" pattern, command-vs-prose treatment, trade-off/gotcha/consequence callouts, monospace identifiers, in-page TOC.
- **All UX/UI via /frontend-design**, following the design record's "mesh-schematic" direction (cool paper, slate ink, one signal accent, wire-gray edges, dot-grid substrate; technical display grotesque + readable body + characterful mono). Distinct from the RetailCloud receipt-paper aesthetic.
- **No demo-frontend screenshot galleries.** The demo UI is referenced/linked at most.
- **Deploy to Netlify** (static build).
- Site lives in `site/`. House rules: no `#` in heredocs (write files), no `sed` writes, **no AI attribution in commits**, source files 300–500 lines.

## File structure

```
site/
  package.json            astro + starlight deps, scripts
  astro.config.mjs        starlight integration: title, sidebar, customCss, social
  netlify.toml            build command + publish dir (site/dist)
  tsconfig.json
  src/
    content/docs/
      index.mdx           landing (custom hero → demo mesh)
      demos/spiffe-cross-boundary/
        overview.md       what the demo shows (short)
        concepts.md       the SPIFFE story (from the tutorial's "Learn")
        manual.md         the from-scratch manual (from demos/.../MANUAL.md)
        reference.md      the config/commands reference
    styles/theme.css      /frontend-design: mesh-schematic tokens + code/callout styling
    components/
      DemoMesh.astro      /frontend-design: the signature landing mesh (demos as nodes)
  public/                 favicon, og image
```

> **Open decision (flag to operator, do not silently resolve):** single source of truth for manuals — the site content collection vs the in-repo `demos/*/MANUAL.md`. For v1 the site content is authored/seeded here; keeping it in sync with the demo dir (a sync script vs making the site canonical) is a follow-up. Noted, not decided.

---

## Phase 0 — Scaffold a building Starlight site

### Task 1: Create the Astro + Starlight project

**Files:** Create `site/package.json`, `site/astro.config.mjs`, `site/tsconfig.json`, `site/src/content/docs/index.mdx` (placeholder), `.gitignore` additions.

- [ ] **Step 1: Scaffold via the Starlight starter, in `site/`**

Run (non-interactive):
```bash
npm create astro@latest site -- --template starlight --no-install --no-git --yes
```
Expected: `site/` created with `package.json`, `astro.config.mjs`, `src/content/docs/`.

- [ ] **Step 2: Install deps**

Run: `cd site && npm install`
Expected: `node_modules/` populated, no errors.

- [ ] **Step 3: Set the site identity in `astro.config.mjs`**

Set Starlight `title: 'linkerd-playground'`, a demo-neutral `tagline`/description, and an initial empty `sidebar` + `customCss: ['./src/styles/theme.css']` (create an empty `theme.css` so the build resolves). Remove the starter's demo content/sidebar.

- [ ] **Step 4: Verify the build**

Run: `cd site && npm run build`
Expected: exits 0; `site/dist/` produced.

- [ ] **Step 5: Ignore build artifacts + commit**

Add `site/node_modules/`, `site/dist/`, `site/.astro/` to `.gitignore`.
```bash
git add site .gitignore && git commit -m "site: scaffold Astro + Starlight (builds clean)"
```

---

## Phase 1 — The SPIFFE/RetailCloud demo section (content)

### Task 2: Author the demo's doc pages

**Files:** Create `site/src/content/docs/demos/spiffe-cross-boundary/{overview,concepts,manual,reference}.md`.

Each page needs Starlight frontmatter (`title`, `description`). Content sources:
- `overview.md` — a short "what this demo shows" (2–3 paragraphs from the demo README intro; the store-pushes-to-cloud framing).
- `concepts.md` — the SPIFFE story, adapted from the in-app tutorial's **Learn** tab (problem → SPIFFE → mesh expansion → mTLS → authorization by identity).
- `manual.md` — the from-scratch manual, **content copied from `demos/spiffe-cross-boundary/MANUAL.md`** with Starlight frontmatter prepended and the top `# H1` removed (Starlight renders the title from frontmatter).
- `reference.md` — a condensed reference: the key config artifacts (SPIRE cfgs, proxy env, ExternalWorkload, authz) as a lookup, cross-linked to the manual.

- [ ] **Step 1: Write the four pages** with correct frontmatter and the sourced content (verbatim technical content from `MANUAL.md` for the manual; adapted concepts from the tutorial).

- [ ] **Step 2: Wire the sidebar** in `astro.config.mjs`:
```js
sidebar: [
  { label: 'SPIFFE across a boundary', items: [
    'demos/spiffe-cross-boundary/overview',
    'demos/spiffe-cross-boundary/concepts',
    'demos/spiffe-cross-boundary/manual',
    'demos/spiffe-cross-boundary/reference',
  ]},
]
```

- [ ] **Step 3: Verify build + links**

Run: `cd site && npm run build`
Expected: exits 0; the four pages built; no broken-link warnings for the sidebar entries. Spot-check `npm run dev` and load `/demos/spiffe-cross-boundary/manual/`.

- [ ] **Step 4: Commit**
```bash
git add site/src/content && git commit -m "site: SPIFFE demo section (overview, concepts, manual, reference)"
```

---

## Phase 2 — Theme the shell (/frontend-design)

### Task 3: The "mesh-schematic" theme

**Files:** `site/src/styles/theme.css` (+ any Starlight component overrides under `site/src/components/`).

**This is a /frontend-design task.** Invoke /frontend-design and produce the theme following the design record's direction. Deliverables:

- [ ] **Step 1 (/frontend-design): Token pass.** Finalize the palette (cool paper, slate ink, one signal accent, wire-gray), the type pairing (technical display grotesque, readable body, characterful mono — loaded via Starlight's font support / self-hosted), and the dot-grid substrate. Override Starlight's CSS custom properties (`--sl-color-*`, accent, fonts) in `theme.css`. Validate contrast (light + dark).

- [ ] **Step 2 (/frontend-design): Reading experience.** Style the manual's core patterns: code blocks, inline `code`/identifiers (mono), Starlight asides/callouts mapped to the manual's *trade-off / gotcha / consequence* notes, tables, and the in-page TOC. The long manual must read beautifully.

- [ ] **Step 3: Verify.** `npm run build` clean; load the manual page in the browser (both color schemes) and screenshot; confirm it matches the direction and is legible for long-form.

- [ ] **Step 4: Commit**
```bash
git add site/src/styles site/src/components && git commit -m "site: mesh-schematic theme + manual reading experience (frontend-design)"
```

---

## Phase 3 — The landing + demo-mesh signature (/frontend-design)

### Task 4: Landing page with the demo mesh

**Files:** `site/src/content/docs/index.mdx`, `site/src/components/DemoMesh.astro`.

**This is a /frontend-design task.** The signature element from the design record: the demo index rendered as a small mesh (each demo a node on the dot-grid, lightly connected), scaling as demos are added.

- [ ] **Step 1 (/frontend-design): Design + build `DemoMesh.astro`.** A self-contained component that renders demos as connected nodes (data-driven from a small `demos` array so new demos append). Each node links to that demo's overview. Accessible (real links, keyboard focus, reduced-motion). Echoes the topology motif without copying RetailCloud's palette.

- [ ] **Step 2 (/frontend-design): The landing `index.mdx`.** A demo-neutral hero (what linkerd-playground is: hands-on Linkerd / mesh-identity / cross-infra-trust demos) with the `DemoMesh` as the centerpiece. No SPIFFE-specific chrome; no screenshots.

- [ ] **Step 3: Verify.** `npm run build` clean; load `/` in the browser, screenshot; the mesh renders, the node links to the SPIFFE demo, responsive down to mobile.

- [ ] **Step 4: Commit**
```bash
git add site/src/content/docs/index.mdx site/src/components/DemoMesh.astro && git commit -m "site: landing + demo-mesh signature (frontend-design)"
```

---

## Phase 4 — Netlify deploy

### Task 5: Netlify build config

**Files:** `site/netlify.toml`.

- [ ] **Step 1: Write `site/netlify.toml`**
```toml
[build]
  base = "site"
  command = "npm run build"
  publish = "dist"

[build.environment]
  NODE_VERSION = "20"
```

- [ ] **Step 2: Verify the exact Netlify build locally**

Run: `cd site && npm run build`
Expected: exits 0; `site/dist/index.html` and the demo pages exist.

- [ ] **Step 3: Connect + deploy (operator step).** Connecting the GitHub repo to a Netlify site (or `netlify deploy` via the Netlify CLI) needs the operator's Netlify account. Document the two paths in `site/README.md`: (a) Netlify UI → "Import from Git" → base `site/`; (b) `netlify deploy --build` from `site/` if the CLI is authed. **Do not assume Netlify auth.**

- [ ] **Step 4: Commit**
```bash
git add site/netlify.toml site/README.md && git commit -m "site: Netlify build config + deploy instructions"
```

---

## Phase 5 — Verify the whole site

### Task 6: Final verification pass

- [ ] **Step 1: Clean build from scratch.** `cd site && rm -rf dist .astro && npm run build` → exits 0.
- [ ] **Step 2: Link + nav check.** Load `dev` server; from the landing, click through to the SPIFFE demo's overview → concepts → manual → reference; confirm sidebar, TOC, and search work.
- [ ] **Step 3: Quality floor.** Responsive to mobile; visible keyboard focus; `prefers-reduced-motion` respected on the mesh; light + dark both legible. Screenshot the landing + a manual page for the record.
- [ ] **Step 4: Commit any fixes** and open a PR for the whole `site/`.

---

## Self-review (against the design record)

- **Starlight, themed** → Phase 0 (scaffold) + Phase 2 (theme only, no fork). ✅
- **Demo-neutral, scales to N** → landing `DemoMesh` is data-driven; sidebar groups per demo. ✅
- **Manuals are the product** → Phase 1 brings the manual in; Phase 2 Step 2 optimizes the reading experience. ✅
- **All UX/UI via /frontend-design** → Phases 2 & 3 are explicitly frontend-design tasks; called out. ✅
- **Netlify** → Phase 4. ✅
- **No screenshot galleries** → stated in Global Constraints; landing uses the mesh, not screenshots. ✅
- **Placeholder scan:** the only deferred item is the operator-owned source-of-truth/sync decision and the Netlify account connection — both flagged explicitly with the reason, not silent TODOs.
- **Open decision surfaced:** manual source-of-truth (site vs `demos/*/MANUAL.md`) — flagged in File structure, to resolve with the operator.
