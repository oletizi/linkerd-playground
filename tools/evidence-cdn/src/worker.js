/**
 * Read-only CDN in front of the Backblaze B2 bucket that holds the cert-hygiene
 * lab's recorded evidence.
 *
 * Why this exists: B2's API rate-limits reads, so nothing should read evidence
 * through the B2 API. Every read — a citation someone follows, a run fetched for
 * local analysis, our own upload verification — goes through this Worker, which
 * serves from Cloudflare's edge cache and only reaches B2 on a cache miss.
 *
 * The bucket is public, so this Worker holds no credentials. It rewrites
 *   https://<worker-host>/<path>
 * to the bucket's download URL, and marks responses immutable: a recorded run is
 * never edited, so a cached copy can never be stale.
 */

const ALLOWED_METHODS = new Set(['GET', 'HEAD']);
const IMMUTABLE = 'public, max-age=31536000, immutable';

export default {
  async fetch(request, env, ctx) {
    if (!ALLOWED_METHODS.has(request.method)) {
      return new Response('method not allowed\n', {
        status: 405,
        headers: { Allow: 'GET, HEAD', 'Cache-Control': 'no-store' },
      });
    }

    const url = new URL(request.url);
    const key = decodeURIComponent(url.pathname).replace(/^\/+/, '');

    if (key === '' || key.endsWith('/')) {
      // B2 has no directory listings, and we do not want to imply otherwise:
      // every path is resolved from a manifest committed in the repository.
      return new Response('not found: this endpoint serves files, not listings\n', {
        status: 404,
        headers: { 'Cache-Control': 'no-store' },
      });
    }
    if (key.split('/').some((seg) => seg === '.' || seg === '..')) {
      return new Response('bad request\n', {
        status: 400,
        headers: { 'Cache-Control': 'no-store' },
      });
    }

    const origin = `${env.B2_DOWNLOAD_HOST}/file/${env.B2_BUCKET}/${key}`;

    // Range requests matter: a run archive is fetched whole, but a reader
    // following a citation may want one slice of a large log.
    const forwarded = new Headers();
    for (const header of ['Range', 'If-None-Match', 'If-Modified-Since']) {
      const value = request.headers.get(header);
      if (value) forwarded.set(header, value);
    }

    const response = await fetch(origin, {
      method: request.method,
      headers: forwarded,
      cf: { cacheEverything: true, cacheTtl: 31536000 },
    });

    const headers = new Headers(response.headers);
    headers.set('Cache-Control', IMMUTABLE);
    // B2 exposes internals that mean nothing to a reader of the evidence.
    for (const header of [
      'x-bz-file-id',
      'x-bz-upload-timestamp',
      'x-bz-info-src_last_modified_millis',
    ]) {
      headers.delete(header);
    }
    // The checksum B2 recorded, so a caller can verify a file without trusting
    // this Worker or the cache in front of it.
    const sha1 = response.headers.get('x-bz-content-sha1');
    if (sha1) headers.set('x-evidence-sha1', sha1.replace(/^unverified:/, ''));

    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers,
    });
  },
};
