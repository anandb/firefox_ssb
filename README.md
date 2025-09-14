# firefox_ssb

Creates a custom firefox profile for a Site-Specific Browser (SSB), and creates a shortcut for desktop environments on Linux (KDE/GNOME/MATE etc). The profile hides the toolbar and address bar making it seem like a standalone application.

```sh

Usage:
    ./create-ssb.sh [-r | REMOVE PROFILE] [-l | LIST PROFILEs] <URL> [CUSTOM_ICON_PATH]

Examples:
    ./create-ssb.sh https://en.wikipedia.org
    ./create-ssb.sh https://en.wikipedia.org  /path/to/custom-icon.png
    ./create-ssb.sh -r https://en.wikipedia.org
    ./create-ssb.sh -l

```

If no custom icon is provided, the script attempts to download the favicon configured on the site.
