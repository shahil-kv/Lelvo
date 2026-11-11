// Sends old and alternate addresses to lelvo.app, keeping the path. Older app builds link to the workers.dev address,
// so that redirect has to stay. Exact hostnames only: pull request previews live on *-lelvo.mshahilkv.workers.dev.
const REDIRECT_HOSTS = new Set(["www.lelvo.app", "lelvo.mshahilkv.workers.dev"]);

// Lets iPhones save a library's passphrase in the Passwords app for the Lelvo app (Associated Domains). Apple fetches it
// from lelvo.app over HTTPS with no redirect; served here so it's always JSON. The prefix is the Apple team that signs
// the app.
const APPLE_APP_SITE_ASSOCIATION = JSON.stringify({ webcredentials: { apps: ["47PTVGK8BJ.app.lelvo.ios"] } });

export default {
  fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/.well-known/apple-app-site-association" || url.pathname === "/apple-app-site-association") {
      return new Response(APPLE_APP_SITE_ASSOCIATION, {
        headers: { "Content-Type": "application/json", "Cache-Control": "public, max-age=3600" },
      });
    }
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
