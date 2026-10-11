const storeHash = "[0-9a-df-np-sv-z]{32}";
const narinfo = new RegExp(`^${storeHash}\\.narinfo$`);
const nar = /^nar\/[0-9a-z]+\.nar\.zst$/;
const ciMetadata = /^ci\/[a-z0-9-]+$/;

function validKey(key) {
  return key === "nix-cache-info" || narinfo.test(key) || nar.test(key) || ciMetadata.test(key);
}

function unauthorized() {
  return new Response("Authentication required", {
    status: 401,
    headers: { "WWW-Authenticate": 'Basic realm="nix-cache"' },
  });
}

function forbidden() {
  return new Response("Forbidden", { status: 403 });
}

async function upload(request, env, key, url) {
  if (!env.WRITE_TOKEN || request.headers.get("Authorization") !== `Bearer ${env.WRITE_TOKEN}`) {
    return forbidden();
  }

  const action = url.searchParams.get("multipart");
  if (!action && request.method === "PUT") {
    await env.CACHE.put(key, request.body);
    return new Response(null, { status: 204 });
  }
  if (action === "start" && request.method === "POST") {
    const upload = await env.CACHE.createMultipartUpload(key);
    return Response.json({ uploadId: upload.uploadId });
  }

  const uploadId = url.searchParams.get("uploadId");
  if (!uploadId || uploadId.length > 1024) {
    return new Response("Invalid upload ID", { status: 400 });
  }
  const upload = env.CACHE.resumeMultipartUpload(key, uploadId);

  if (action === "part" && request.method === "PUT") {
    const partNumber = Number(url.searchParams.get("partNumber"));
    if (!Number.isInteger(partNumber) || partNumber < 1 || partNumber > 10000) {
      return new Response("Invalid part number", { status: 400 });
    }
    const part = await upload.uploadPart(partNumber, request.body);
    return Response.json(part);
  }
  if (action === "complete" && request.method === "POST") {
    const body = await request.json();
    if (!Array.isArray(body.parts) || body.parts.length === 0) {
      return new Response("Invalid parts", { status: 400 });
    }
    await upload.complete(body.parts);
    return new Response(null, { status: 204 });
  }
  if (action === "abort" && request.method === "DELETE") {
    await upload.abort();
    return new Response(null, { status: 204 });
  }
  return new Response("Method not allowed", { status: 405 });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const isUpload = url.pathname.startsWith("/upload/");
    const key = decodeURIComponent(url.pathname.slice(isUpload ? 8 : 1));
    if (!validKey(key)) {
      return new Response("Not found", { status: 404 });
    }
    if (isUpload) {
      return upload(request, env, key, url);
    }
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method not allowed", { status: 405 });
    }
    if (!env.READ_TOKEN || request.headers.get("Authorization") !== `Basic ${btoa(`nix:${env.READ_TOKEN}`)}`) {
      return unauthorized();
    }
    const object = request.method === "HEAD" ? await env.CACHE.head(key) : await env.CACHE.get(key);
    if (!object) {
      return new Response("Not found", { status: 404 });
    }
    const headers = new Headers({
      "Content-Length": String(object.size),
      "Content-Type": key.endsWith(".nar.zst") ? "application/octet-stream" : "text/plain",
      "Cache-Control": "private, no-store",
      ETag: object.httpEtag,
    });
    return new Response(request.method === "HEAD" ? null : object.body, { status: 200, headers });
  },
};
