// All non-GET requests against this app's own backend MUST go through
// this helper. CloudFront's OAC + Lambda Function URL requires the
// client to compute SHA-256 of the body and send it in the
// `x-amz-content-sha256` header — without it, the Function URL rejects
// the request with `InvalidSignatureException` (HTTP 403) and Lambda
// never invokes.
//
// Plain `fetch()` works fine for GET/HEAD/OPTIONS (no body to hash) and
// for paths that don't go through CloudFront (third-party APIs).

async function bodyHashHex(bodyStr: string): Promise<string> {
  const buf = new TextEncoder().encode(bodyStr);
  const hash = await crypto.subtle.digest("SHA-256", buf);
  return [...new Uint8Array(hash)].map(b => b.toString(16).padStart(2, "0")).join("");
}

export async function api(
  method: string,
  path: string,
  body?: unknown,
  init?: RequestInit,
): Promise<Response> {
  const headers = new Headers(init?.headers);
  let bodyStr: string | undefined;

  if (body !== undefined) {
    bodyStr = JSON.stringify(body);
    headers.set("content-type", "application/json");
    headers.set("x-amz-content-sha256", await bodyHashHex(bodyStr));
  }

  return fetch(path, { ...init, method, headers, body: bodyStr });
}

export const apiGet = (path: string, init?: RequestInit) => fetch(path, init);
export const apiPost = (path: string, body: unknown, init?: RequestInit) => api("POST", path, body, init);
export const apiPut = (path: string, body: unknown, init?: RequestInit) => api("PUT", path, body, init);
export const apiPatch = (path: string, body: unknown, init?: RequestInit) => api("PATCH", path, body, init);
export const apiDelete = (path: string, init?: RequestInit) => api("DELETE", path, undefined, init);
