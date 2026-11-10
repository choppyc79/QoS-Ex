# LuCI app source

The QoS-Ex LuCI app, one file each, laid out as the files sit on the router:

| Here | What it is |
|---|---|
| `www/luci-static/resources/view/qos-ex/` | the views (`_helpers.js` is shared by all of them) |
| `www/luci-static/resources/view/status/include/35_qos-ex.js` | the QoS-Ex box on LuCI's Status page |
| `www/luci-static/resources/qos-ex/qos-ex.css` | the stylesheet |
| `usr/share/luci/menu.d/luci-app-qos-ex.json` | the menu |
| `usr/share/rpcd/acl.d/luci-app-qos-ex.json` | the access list |
| `usr/libexec/rpcd/qos-ex` | the backend calls the views make |

These are packed into `qos-ex-luci.tar.gz` in the repo root. The installer,
`QoS-Ex-luci-app.sh`, unpacks that tarball on the router and copies the files
into place. It names the tarball by its sha256. The only other files it
installs are the map page's library (Leaflet 1.9.4), fetched once and checked
against pinned hashes.

## After editing anything here

```sh
sh tools/mkluci.sh          # repack the tarball, write its hash into the installer
sh tools/mkluci.sh check    # does the tarball hold exactly these files?
```

Commit the files you changed, `qos-ex-luci.tar.gz` and `QoS-Ex-luci-app.sh`
together. For a release, bump `VERSION=` in `QoS-Ex-luci-app.sh` first, and
finish with `sh tools/mkmanifest.sh` (commit `SHA256SUMS` last).

On the router the installer fills in `__VERSION__` and `__CACHEBUST__`, and
adds a token to each view's file name so browsers fetch the new copy.
