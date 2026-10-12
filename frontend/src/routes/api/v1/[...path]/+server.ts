import { env } from '$env/dynamic/private';
import type { RequestHandler } from './$types';
const hop = ['connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization', 'te', 'trailer', 'transfer-encoding', 'upgrade', 'host', 'content-length'];
const handle: RequestHandler = async ({ request, params, url }) => {
  const headers = new Headers(request.headers); for (const name of hop) headers.delete(name);
  const target = `${(env.BACKEND_API_URL || 'http://127.0.0.1:8085').replace(/\/+$/, '')}/api/v1/${params.path}${url.search}`;
  try {
    const upstream = await fetch(target, { method: request.method, headers, body: ['GET', 'HEAD'].includes(request.method) ? undefined : await request.arrayBuffer(), signal: request.signal, redirect: 'manual' });
    const out = new Headers(upstream.headers); for (const name of hop) out.delete(name);
    return new Response(upstream.body, { status: upstream.status, headers: out });
  } catch { return Response.json({ error: 'The remote backend is unavailable.' }, { status: 502 }); }
};
export const GET = handle; export const POST = handle; export const PUT = handle; export const DELETE = handle;
