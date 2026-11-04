# Website

The site in `website/` is plain HTML, CSS and JS, deployed by Cloudflare on every push to `main`. Design tokens and
the theme toggle are in [DESIGN.md](DESIGN.md).

## What's already in place for search

- A title and description on every page, written for what people search ("free photo backup to your own Telegram").
- Canonical links, a sitemap with dates, and `robots.txt` pointing to it. The 404 page is `noindex`.
- Share previews (Open Graph and X cards) on every page, with `og.png` as the image.
- Structured data on the home page telling Google it's a free app for iOS and macOS.
- An About page and `llms.txt` saying what Lelvo is and who makes it, for search engines and AI assistants.
- A web manifest and icons, so the site has the Lelvo icon in search results and on home screens.
- Fast pages: no framework, images sized and lazy-loaded, nothing moves the layout while loading.

There are no analytics on purpose: the privacy policy promises no tracking. Search Console shows search traffic
without putting anything on the site.

## Addresses

The site lives at `https://lelvo.app`. `website-worker.js` sends `www.lelvo.app` and the old
`lelvo.mshahilkv.workers.dev` to it with a 301. The custom domains are set on the Worker in the Cloudflare dashboard.
Keep the old address redirecting, because older app builds link to it.

The FAQ answers also live in the structured data at the top of `website/index.html`. Change both together.

## Search engines

These are done by hand, once:

1. [Google Search Console](https://search.google.com/search-console): add a **Domain** property, verify it with the
   DNS record it gives you (add it in Cloudflare DNS), then **Sitemaps → submit `sitemap.xml`** and
   **URL inspection → Request indexing** for the home page.
2. [Bing Webmaster Tools](https://www.bing.com/webmasters): sign in and import the site from Search Console. This also
   covers DuckDuckGo and Yahoo.
3. Use `lelvo.app` in the App Store listing and every launch post.

Being indexed takes days to a couple of weeks. Ranking for searches takes months and grows with links from other
sites, such as launch posts, GitHub and articles.
