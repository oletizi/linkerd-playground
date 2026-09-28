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

/**
 * Bump this to invalidate every cached response.
 *
 * A workers.dev hostname is not a zone, so there is no cache-purge button. The
 * cache key carries this version instead: changing it and redeploying makes every
 * previously cached entry unreachable. That is the escape hatch for a response
 * cached in error — which has already happened once, when an early version of this
 * Worker cached a 404 for a year.
 */
const CACHE_VERSION = 'v2';

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
    const range = request.headers.get('Range');

    // The cache is managed explicitly rather than through `cf.cacheKey`, which is
    // an Enterprise-only feature and is silently ignored on other plans. Owning the
    // key means CACHE_VERSION genuinely invalidates, and it means only a complete,
    // successful body is ever stored.
    const cache = caches.default;
    const cacheKey = new Request(`${url.origin}/${CACHE_VERSION}/${key}`, { method: 'GET' });

    if (!range) {
      const cached = await cache.match(cacheKey);
      if (cached) {
        const hit = new Response(request.method === 'HEAD' ? null : cached.body, cached);
        hit.headers.set('x-evidence-cache', 'hit');
        return hit;
      }
    }

    // Range requests go straight to the origin: a reader may want one slice of a
    // large log, and a partial body must never become the cached copy of a file.
    const forwarded = new Headers();
    if (range) forwarded.set('Range', range);

    const response = await fetch(origin, { method: range ? 'GET' : 'GET', headers: forwarded });

    const headers = new Headers(response.headers);
    // Only a successful body is immutable. Caching a 404 for a year would mean a
    // file uploaded later stays invisible until the cache expires — so errors are
    // never cached, and a miss is always re-checked against the origin.
    if (response.ok || response.status === 206 || response.status === 304) {
      headers.set('Cache-Control', IMMUTABLE);
    } else {
      headers.set('Cache-Control', 'no-store');
    }
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

    const result = new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers,
    });
    result.headers.set('x-evidence-cache', 'miss');

    // Store only a whole, successful body. A 404 is never cached, so a file
    // uploaded after someone looked for it becomes visible immediately.
    if (response.ok && !range) {
      ctx.waitUntil(cache.put(cacheKey, result.clone()));
    }

    return request.method === 'HEAD'
      ? new Response(null, { status: result.status, headers: result.headers })
      : result;
  },
};
