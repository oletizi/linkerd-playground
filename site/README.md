# site — linkerd-playground documentation

The documentation site for [linkerd-playground](https://github.com/oletizi/linkerd-playground):
a hub of deep, hands-on manuals for the demos in this repo. Built with
[Astro](https://astro.build) + [Starlight](https://starlight.astro.build) and
themed with the "mesh-schematic" visual identity.

The manuals are the product. Each demo gets an Overview, Concepts, Manual, and
Reference; new demos slot in as sibling sections.

## Develop

```bash
cd site
npm install
npm run dev        # http://localhost:4321, live reload
```

| Command           | What it does                                      |
| ----------------- | ------------------------------------------------- |
| `npm run dev`     | Start the dev server with hot reload              |
| `npm run build`   | Build the static site to `dist/`                  |
| `npm run preview` | Serve the built `dist/` locally to verify a build |

## Structure

```
site/
  astro.config.mjs                     # Starlight config: fonts, sidebar, per-demo nav
  src/
    styles/theme.css                   # the mesh-schematic theme (palette, type, code)
    components/DemoMesh.astro           # landing signature: the demo index as a mesh
    content/docs/
      index.mdx                         # splash landing (demo-neutral)
      demos/<demo>/{overview,concepts,manual,reference}
```

Adding a demo: create `src/content/docs/demos/<demo>/` with its pages, add a
group to `sidebar` in `astro.config.mjs`, and add an entry to the `demos` array
in `DemoMesh.astro` — the landing mesh grows from that array.

## Deploy (Netlify)

`netlify.toml` at the **repo root** pins the build: base `site/`, command
`npm run build`, publish `dist/` (i.e. `site/dist`), Node 22. To deploy:

1. In Netlify, **Add new site → Import an existing project** and connect the
   `oletizi/linkerd-playground` repository. The root `netlify.toml` supplies the
   build settings, so the import form's fields auto-fill; no manual configuration
   is needed.
2. Deploy. Every push to the default branch publishes; pull requests get
   deploy previews.
3. Once the production domain is known, set it as `site` in `astro.config.mjs`
   so the sitemap and canonical URLs are correct.
