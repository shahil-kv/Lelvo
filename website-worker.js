// Sends old and alternate addresses to lelvo.app, keeping the path. Older app builds link to the workers.dev address,
// so that redirect has to stay. Exact hostnames only: pull request previews live on *-lelvo.mshahilkv.workers.dev.
const REDIRECT_HOSTS = new Set(["www.lelvo.app", "lelvo.mshahilkv.workers.dev"]);

export default {
  fetch(request, env) {
    const url = new URL(request.url);
    if (REDIRECT_HOSTS.has(url.hostname)) {
      return Response.redirect(`https://lelvo.app${url.pathname}${url.search}`, 301);
    }
    return env.ASSETS.fetch(request);
  },
};
