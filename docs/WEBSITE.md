# Website

The site in `website/` is plain HTML, CSS and JS, deployed by Cloudflare on every push to `main`. Design tokens and
the theme toggle are in [DESIGN.md](DESIGN.md).

## What's already in place for search

- A title and description on every page, written for what people search ("free photo backup to your own Telegram").
- Canonical links, a sitemap with dates, and `robots.txt` pointing to it. The 404 page is `noindex`.
- Share previews (Open Graph and X cards) on every page, with `og.png` as the image.
- Structured data on the home page telling Google it's a free app for iOS and macOS.
- A web manifest and icons, so the site has the Memvo icon in search results and on home screens.
- Fast pages: no framework, images sized and lazy-loaded, nothing moves the layout while loading.

There are no analytics on purpose: the privacy policy promises no tracking. Search Console shows search traffic
without putting anything on the site.

## After buying a domain

1. In Cloudflare, add the domain to the Worker or Pages project that serves `website/` (Custom domains), and wait
   until `https://<domain>/` shows the site.
2. Move every link to the new address, then commit:

   ```sh
   python3 Scripts/website-domain.py <domain>
   python3 Scripts/website-pages.py
   ```

3. Make the old `memvo.mshahilkv.workers.dev` address redirect (301) to the new domain, so links already shared keep
   working and Google moves its ranking over.
4. [Google Search Console](https://search.google.com/search-console): add a **Domain** property, verify it with the
   DNS record it gives you (add it in Cloudflare DNS), then **Sitemaps → submit `sitemap.xml`** and
   **URL inspection → Request indexing** for the home page.
5. [Bing Webmaster Tools](https://www.bing.com/webmasters): sign in and import the site from Search Console. This also
   covers DuckDuckGo and Yahoo.
6. Put the domain in the GitHub repo's **About → Website** field, the App Store listing, and every launch post.

Being indexed takes days to a couple of weeks. Ranking for searches takes months and grows with links from other
sites, such as launch posts, GitHub and articles.
