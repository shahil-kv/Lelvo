// Sends old and alternate addresses to lelvo.app, keeping the path. Older app builds link to the workers.dev address,
// so that redirect has to stay. Exact hostnames only: pull request previews live on *-lelvo.mshahilkv.workers.dev.
const REDIRECT_HOSTS = new Set(["www.lelvo.app", "lelvo.mshahilkv.workers.dev"]);

export default {
  fetch(request, env) {
    const url = new URL(request.url);
    // Google indexed http://lelvo.app/changelog; plain HTTP gets the same permanent redirect. Not for localhost (wrangler dev).
    if (url.protocol === "http:" && url.hostname === "lelvo.app") {
      return Response.redirect(`https://lelvo.app${url.pathname}${url.search}`, 301);
    }
    if (REDIRECT_HOSTS.has(url.hostname)) {
      return Response.redirect(`https://lelvo.app${url.pathname}${url.search}`, 301);
    }
    return env.ASSETS.fetch(request);
  },
};
