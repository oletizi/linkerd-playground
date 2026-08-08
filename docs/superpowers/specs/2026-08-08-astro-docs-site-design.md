---
title: Astro documentation site — design record
roadmap-item: design:feature/astro-docs-site
date: 2026-08-08
status: awaiting-approval
---

# Astro documentation site — design record

## Problem domain

`linkerd-playground` is a **collection of hands-on demos** exploring Linkerd,
service-mesh identity, and cross-infrastructure trust. The SPIFFE/RetailCloud demo
is the **first of many**; the collection will grow.

The project needs a documentation website. The **core value is the deep, from-scratch
technical manual** — the kind written for the SPIFFE demo
(`demos/spiffe-cross-boundary/MANUAL.md`): a by-hand walkthrough that explains every
config file, field, and command and *why it exists*. Each future demo will have a
similar manual. The site exists to present those manuals well and let a reader move
between them.

Explicit non-goals (operator-stated):
- The site is **not "about SPIFFE"** — it is demo-neutral at the top level and must
  scale to many demos, mirroring how the repo itself is demo-neutral.
- The **demo frontends are not the interesting part.** No screenshot galleries, no
  showcasing of demo UIs as the draw. The manuals are.

Audience: practitioners (platform/infra/mesh engineers) who want to *deeply
understand and reproduce* these setups — not skim marketing.

Success looks like: a reader lands, sees the collection, opens a demo's manual, and
can follow a long config-heavy walkthrough comfortably — code and explanation legible,
trade-offs and gotchas surfaced, easy to navigate within and across manuals.

## Solution space

### Chosen — Astro + Starlight, themed via frontend-design, manual-centric

Build on **Astro's Starlight** docs framework (sidebar nav, search, multi-section
structure, good long-form + code rendering out of the box) and **theme it via
/frontend-design** (palette, type, code blocks, callouts, landing). Content is the
**existing markdown** (each demo's `MANUAL.md` and supporting concepts) rendered as
Starlight pages, plus a demo-neutral landing. Deploy to **Netlify**.

- *Why:* the product is long-form technical reading; Starlight is purpose-built for
  exactly that and scales to N demos naturally, so design effort goes into the
  reading experience and identity rather than re-inventing docs plumbing.
- *Cost:* Starlight's layout constrains bespoke design to theming + the landing.
  Acceptable — the operator chose "Starlight, themed."

### Rejected — fully custom Astro

/frontend-design owns every page end to end. Maximum bespoke control, but for a
reading-first docs site it's a large build for little gain over a well-themed
Starlight, and re-implements nav/search/TOC that Starlight gives free.

### Rejected — plain minimal docs theme

The generic docs look (light bg, one accent, sans-serif, sidebar). Accurate but
forgettable — the exact default /frontend-design exists to avoid.

### Rejected — dark terminal / neon console

Reads as an AI-cluster default and is poor for long-form technical reading.

### Rejected (content) — demo-UI showcase

A site built around screenshots/recordings of the demo frontends. Operator-rejected:
the frontends aren't the point; the manuals are.

## Decisions

1. **Framework:** Astro + **Starlight**, themed. Not custom, not plain-default.
2. **Deploy target:** **Netlify** (static build).
3. **Content model:** manual-centric. Per demo, a Starlight section whose centerpiece
   is the **from-scratch manual**, with a brief overview/concepts intro and a
   reference as supporting pages. Sourced from the existing markdown; new demos slot
   in as sibling sections. Top level is **demo-neutral** (landing + demo index).
4. **Reading experience is the priority** (this is where /frontend-design invests):
   the "config block + per-field explanation" pattern, distinct command-vs-prose
   treatment, trade-off / gotcha / consequence **callouts** (the manual already uses
   these), monospace for identifiers/paths/SPIFFE IDs, an in-page TOC for long
   manuals, and comfortable long-form measure and hierarchy across many numbered
   parts/steps.
5. **Visual direction — "mesh schematic":** the collection presented as a mesh —
   nodes + edges on a dot-grid substrate, a cool engineered palette (cool paper,
   slate ink, a single signal-green/teal accent, wire-gray edges), a technical
   display grotesque + readable body + characterful mono. **Signature:** the landing's
   **demo index rendered as a small mesh** (each demo a node; grows with the
   collection). Distinct from the RetailCloud demo's warm receipt-paper aesthetic,
   which stays demo-specific.
6. **No demo-UI screenshot galleries.** The demo frontend is referenced/linked at
   most, not showcased.

## Open questions

- **Exact visual tokens** (hex, type scale, contrast validation) — finalized during
  the build (execute phase) with /frontend-design, not pinned here.
- **Per-demo content template** — the precise page set (Overview / Concepts / Manual /
  Reference?) and how the current in-app tutorial's "Learn" concepts map onto it
  (fold into the manual's intro, or a separate Concepts page?).
- **Content migration** — how the existing markdown (`MANUAL.md`, tutorial concepts,
  connectivity recipe) maps into Starlight content collections without drifting from
  the in-repo source of truth.
- **Live-demo embedding (future, not now):** a genuinely embeddable/runnable demo
  would depend on a **public deployment** of a demo — which is what the pending
  cloud-VPC variant (`the pure cloud-VPC version`) could unlock. Out of scope for v1;
  noted as a dependency for later.
- **Repo location** for the site (e.g. `site/` at repo root vs a subtree) and CI
  wiring to Netlify — settle in the spec.

## Provenance

- Roadmap item `design:feature/astro-docs-site` (stack-control), design phase.
- Design conversation (this session): operator chose **Starlight, themed**;
  reframed the site as a **demo-neutral, multi-demo** hub (SPIFFE is demo #1);
  set **Netlify** as the target; rejected screenshots / demo-UI showcasing; named
  the **deep manuals** as the core product.
- UX/UI direction produced under the **/frontend-design** mandate (operator: all
  UX/UI design + implementation goes through frontend-design).
- Grounding content: `demos/spiffe-cross-boundary/MANUAL.md`, the in-app tutorial,
  the README, and `connectivity-tailscale.md`.
