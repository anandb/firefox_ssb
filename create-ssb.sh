#!/bin/bash
#
# Site-Specific Browser (SSB) Creator - Creates Firefox profiles for web applications similar to ice-ssb utility
# See https://en.wikipedia.org/wiki/Site-specific_browser
#

set -euo pipefail

readonly ICON_SIZE=128
readonly MOZILLA_USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36"
readonly APP_DIR=$HOME/.local/share/ssb

function usage {
    echo "Usage: $0 [-r | REMOVE PROFILE] [-l | LIST PROFILEs] <URL> [ICON_PATH]"
    echo "Example: $0 https://en.wikipedia.org"
    echo "Example: $0 https://en.wikipedia.org  /path/to/custom-icon.png"
    echo "Example: $0 -r https://en.wikipedia.org"
    echo "Example: $0 -l"
    exit 1
}

function verify_dependencies {  # ()
    # Check OS compatibility
    if [[ ! "$OSTYPE" =~ ^linux ]]; then
        echo "Script designed for Linux. Current OS: $OSTYPE" 1>&2
        exit 1
    fi

    # Check available disk space (need at least 100MB for profiles)
    local available_space=$(df ~/ | awk 'NR==2 {print $4}')
    if [[ $available_space -lt 102400 ]]; then
        echo "Insufficient disk space. Need at least 100MB, available: $((available_space/1024))MB" 1>&2
        exit 1
    fi

    # These applications are required
    local missing=''
    for cmd in curl magick firefox sed grep head tr file; do
        if ! command -v $cmd >& /dev/null; then
            missing="$missing $cmd"
        fi
    done

    if [[ -n $missing ]]; then
        echo "Dependencies missing from PATH: $missing" 1>&2
        exit 1
    fi
}

function curl_link {  # (url, output_file, timeout_seconds)
    local url="$1"
    local outfile=${2:-$(mktemp --tmpdir=$TEMP_DIR)}
    local timeout=${3:-30}  # Default 30 seconds timeout

    local curl_opts=(
        --silent
        --location
        --fail
        --connect-timeout 10
        --max-time "$timeout"
        --retry 2
        --retry-delay 1
        --retry-connrefused
        --compressed
        --progress-bar
    )

    # Some sites require a referrer and a user agent, so try multiple combinations
    local strategies=(
        ""  # No extra headers
        "-H \"Referer: https://google.com\""
        "-A \"$MOZILLA_USER_AGENT\""
        "-H \"Referer: https://google.com\" -A \"$MOZILLA_USER_AGENT\""
    )

    for strategy in "${strategies[@]}"; do
        local cmd="curl ${curl_opts[*]} $strategy \"$url\" -o \"$outfile\""

        if eval "$cmd" 2>/dev/null; then
            if [[ -s "$outfile" ]]; then
                cat "$outfile"
                return 0
            fi
        fi

        # Clean up failed attempt
        [[ -f "$outfile" ]] && rm -f "$outfile"
    done

    # All strategies failed
    echo "Failed to download after ${#strategies[@]} attempts" 1>&2
    return 1
}

function remove_profile {  # ()
    echo "Removing Firefox Profile ..."
    local profile_dir="$APP_DIR/firefox/${PROFILE_NAME}"
    if [[ -f "$profile_dir/user.js" ]]; then
        rm -rfv "$profile_dir"
    fi

    echo "Removing Icon ..."
    local icon_dir="$APP_DIR/icons"
    rm -fv "$icon_dir/${PROFILE_NAME}.*"

    echo "Removing Desktop Shortcut ..."
    local desktop_dir="$HOME/.local/share/applications"
    rm -fv "$desktop_dir/${PROFILE_NAME}.desktop"
}

function list_profiles {  #()
    local desktop_dir="$HOME/.local/share/applications"
    grep -hPo 'SSBFirefox=(.*)' $desktop_dir/*.desktop | sed -E 's/[a-z]{3}Firefox=//ig'
}

function print_summary {
    echo "
        SSB created successfully!
        URL: $URL
        Profile: $PROFILE_DIR
        Desktop file: $DESKTOP_FILE
        Icon: $PROFILE_ICON

        You can now launch the SSB from your application menu or run:
        firefox --class SSB-$HOSTNAME --profile '$PROFILE_DIR' --no-remote '$URL'
    " | sed -E 's/^\s+//g'
}

function extract_hostname { # ()
    # Extract hostname from URL and Sanitize hostname for use as profile name
    if [[ $URL =~ ^https?://([^/]+) ]]; then
        # 'https://wiki.c2.com/?WelcomeVisitors' => 'https://wiki.c2.com'
        BASE_URL=$(echo "$URL" | sed -E 's#(https?://[^/?]+).*#\1#g')

        # 'https://wiki.c2.com/?WelcomeVisitors' => 'https://'
        PROTOCOL=$(echo "$URL" | sed -E 's#(https?://).*#\1#g')

        # 'https://wiki.c2.com' => 'wiki.c2.com'
        HOSTNAME=$(echo "$BASE_URL" | sed -E 's#https?://([^/]+).*#\1#g;s/^www\.//ig')

        # 'WIKI.C2.COM' => 'wiki-c2-com'
        PROFILE_NAME=$(echo "$HOSTNAME" | sed 's/[^a-zA-Z0-9]/-/g' | tr '[:upper:]' '[:lower:]')
    else
        echo "Error: Invalid URL format. Please provide a valid HTTP/HTTPS URL."
        exit 1
    fi
}

function skim_website { # ()
    # Get just the protocol and hostname from the URL
    # 'https://en.wikipedia.org/wiki/Twin_prime' => 'https://en.wikipedia.org'
    local html_url=$(echo $URL | sed -E 's/([^:\/])\/.*/\1/g')
    echo "Checking for favicon link in HTML... $html_url"

    # Fetch the first 1000 lines
    HTML_CONTENT=$(curl_link "$html_url" | head -n 1000 | tr -d '\000-\010\013\014\016-\037\177-\377') || true
    if [[ ${DEBUG:-} -eq 1 ]]; then
        echo "$HTML_CONTENT" | tr -d '\000-\010\013\014\016-\037\177-\377'
    fi
}

function examine_favicon_pattern_links { #(html_url, html_content)
    local html_url=$1
    local html_content=$2

    # Look at <link rel=""> tags within the HTML
    for rel in 'apple-touch-icon-precomposed' 'apple-touch-icon' 'fluid-icon' 'shortcut icon' 'favicon' 'mask-icon' 'image_src'; do
        local url=$(echo "$html_content" | sed 's/>/>\n/g' | grep -iE "rel=\"$rel\"" | head -n 1 | sed -n 's/.*href="\([^"]*\)".*/\1/p' | xargs) || true
        download_icon_check_quality "$html_url" "$url"
        if [[ -n ${FAVICON_URL:-} ]]; then
            return
        fi
    done

    for size in 'sizes="512x512"' 'sizes="256x156"' 'sizes="128x128"' '$'; do
        echo "Looking for Icon Size $size"
        local url=$(echo "$html_content" | sed 's/>/>\n/g' | grep -iE "rel=\"icon\".*$size" | head -n 1 | sed -n 's/.*href="\([^"]*\)".*/\1/p' | xargs) || true
        download_icon_check_quality "$html_url" "$url"
        if [[ -n ${FAVICON_URL:-} ]]; then
            return
        fi
    done;

    # Look at <meta property=""> tags within the HTML
    for property in 'twitter:image' 'og:image'; do
        local url=$(echo "$html_content" | sed 's/>/>\n/g' | grep -iE "meta property=\"$property\".*content=\"?[^\"]" | head -n 1 | sed -nE 's/.*content="?([^"\\ ]*)"?.*/\1/p' | xargs) || true
        download_icon_check_quality "$html_url" "$url"
        if [[ -n ${FAVICON_URL:-} ]]; then
            return
        fi
    done
}

function delta_icon_link { # (hostname)
    local domain=$1
    local domain_without_www=${domain#www.*}
    local service=${domain_without_www%.*}
    local provider=''

    if [[ $service =~ ^([^.]+).(yahoo|google|zoho|apple)$ ]]; then
        service=${BASH_REMATCH[1]}
        provider=${BASH_REMATCH[2]}
    else
        # For other domains, just use the main domain name
        service=${domain_without_www%%.*}
        provider=''
    fi

    echo "https://delta-icons.github.io/assets/img/icons/${provider}${provider:+_}${service}.png"
}

function google_icon_link { # (hostname)
    local domain=$1
    echo "https://www.google.com/s2/favicons?sz=${ICON_SIZE}&domain=${domain}&format=.png"
}

function process_custom_icon {  # ()
    # Check if custom favicon file exists
    if [ ! -s "$CUSTOM_FAVICON" ]; then
        echo "Error: Custom favicon file '$CUSTOM_FAVICON' not found"
        exit 1
    fi

    # Use custom favicon provided as command line argument
    echo "Using custom favicon: $CUSTOM_FAVICON"

    # Get file extension
    local extension="${CUSTOM_FAVICON##*.}"
    FAVICON_FILE="favicon.$extension"

    # Copy custom favicon to temp directory
    cp -fv "$CUSTOM_FAVICON" "$TEMP_DIR/$FAVICON_FILE"
}

function relative_url_to_abs {  # (full_url, url)
    local full_url=$1
    local url=$2

    local protocol=$(echo "$full_url" | sed -n 's/^\(https\?\):\/\/.*/\1/p')
    local base_url=$(echo "$full_url" | sed -n 's/^\(https\?:\/\/[^\/]*\).*/\1/p')

    if [[ $url =~ ^https?:// ]]; then
        # Already absolute URL
        echo "Found absolute favicon URL in HTML: $url" 1>&2
    elif [[ $url =~ ^// ]]; then
        # Protocol-relative URL
        url="${protocol}:${url}"
        echo "Found protocol relative favicon URL in HTML: $url"  1>&2
    elif [[ $url =~ ^/ ]]; then
        # Root-relative URL
        url="${base_url}${url}"
        echo "Found root favicon URL in HTML: $url"  1>&2
    else
        # Relative URL
        url=$(echo $url | sed -E 's/(^[^\/])/\/\1/')
        url="${base_url}${url}"
        echo "Found relative favicon URL in HTML: $url"  1>&2
    fi

    echo "$url"
}

function install_icon { # (icon_filesystem_path)
    local src_path=$1
    local file_name="${src_path##*/}"

    # Create icon directory structure
    local icon_dir="$APP_DIR/icons"
    mkdir -p "$icon_dir"

    echo "Installing icon..."
    cp -f "$src_path" "$icon_dir/$file_name"
    PROFILE_ICON="$icon_dir/$file_name"
}

function create_desktop_shortcut {
    # Create .desktop file
    DESKTOP_DIR="$HOME/.local/share/applications"
    mkdir -p "$DESKTOP_DIR"
    DESKTOP_FILE="$DESKTOP_DIR/${PROFILE_NAME}.desktop"

    echo "Creating desktop entry..."
    echo "[Desktop Entry]
          Version=1.0
		  Name=$HOSTNAME
		  Comment=$HOSTNAME (SSB)
		  Exec=firefox --class SSB-$HOSTNAME --profile $PROFILE_DIR --no-remote $URL
		  SSBFirefox=${PROTOCOL}${HOSTNAME}
		  Terminal=false
		  X-MultipleArgs=false
		  Type=Application
		  Icon=$PROFILE_ICON
		  Categories=GTK;Network;KDE;Qt;GNOME
		  MimeType=text/html;text/xml;application/xhtml_xml;
		  StartupWMClass=SSB-$HOSTNAME
		  StartupNotify=true
    " | sed -E 's/^\s+//g' > "$DESKTOP_FILE"

    chmod +x "$DESKTOP_FILE"
}

# Create user.js
function create_user_options {
    echo "Creating user.js..."
    echo '
        user_pref("browser.cache.disk.capacity", 256000);
        user_pref("browser.cache.disk.enable", true);
        user_pref("browser.cache.disk.smart_size.enabled", false);
        user_pref("browser.cache.disk.smart_size.first_run", false);
        user_pref("browser.cache.disk.smart_size.use_old_max", false);
        user_pref("browser.ctrlTab.previews", true);
        user_pref("browser.tabs.warnOnClose", true);
        user_pref("browser.restoreWindowState.disabled", true);
        user_pref("toolkit.telemetry.enabled", false);
        user_pref("datareporting.healthreport.service.enabled", false);
        user_pref("datareporting.healthreport.uploadEnabled", false);
        user_pref("datareporting.policy.dataSubmissionEnabled", false);
        user_pref("toolkit.telemetry.archive.enabled", false);
        user_pref("toolkit.telemetry.bhrPing.enabled", false);
        user_pref("toolkit.telemetry.shutdownPingSender.enabled", false);
        user_pref("toolkit.telemetry.unified", false);
        user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);
    ' | sed -E 's/^\s+//g' > "$PROFILE_DIR/user.js"
}

function create_user_chrome {
    CHROME_DIR="$PROFILE_DIR/chrome"
    mkdir -p "$CHROME_DIR"

    # Create userChrome.css
    echo "Creating userChrome.css..."
    echo '
        #nav-bar, #identity-box, #tabbrowser-tabs { visibility: collapse !important; }
    ' | sed 's/^\s+//g' > "$CHROME_DIR/userChrome.css"
}

function probe_default_icon_urls {
    local icon_pack_link=$(delta_icon_link $HOSTNAME)
    echo Trying $icon_pack_link

    local result=$(curl_link $icon_pack_link)
    if [[ -n "$result" ]]; then
        download_icon_check_quality "$URL" "$icon_pack_link"
        if [[ -n ${FAVICON_URL:-} ]]; then
            return
        fi
    fi

    local google_link=$(google_icon_link $HOSTNAME)
    echo Trying $google_link

    local result=$(curl_link $google_link)
    if [[ -n "$result" ]]; then
        download_icon_check_quality "$URL" "$google_link"
        if [[ -n ${FAVICON_URL:-} ]]; then
            return
        fi
    fi

    local possible_resources=(
        'apple-touch-icon-precomposed.png'
        'apple-touch-icon.png'
        'favicon.png'
        'favicon.jpg'
        'favicon.ico'
        'favicon.svg'
    )

    for icon_url in "${possible_resources[@]}"; do
        echo Trying "${BASE_URL}/$icon_url"
        result=$(curl_link "${BASE_URL}/$icon_url")
        if [[ -n "$result" ]]; then
            download_icon_check_quality ${BASE_URL} "${BASE_URL}/$icon_url"
            if [[ -n ${FAVICON_URL:-} ]]; then
                return
            fi
        fi
    done
}

function convert_and_resize_icon { # ()
    # Convert and resize favicon
    local extension="${FAVICON_FILE##*.}"

    if [[ ! $extension == "png" && ! $extension == "svg"  ]]; then
        echo Running magick, converting favicon to PNG...
        extension=png
        magick "$TEMP_DIR/${FAVICON_FILE}[0]" "$TEMP_DIR/${PROFILE_NAME}.$extension" || true
    else
        cp -f "$TEMP_DIR/$FAVICON_FILE" $TEMP_DIR/${PROFILE_NAME}.$extension
    fi

    # Check if conversion was successful
    if [[ ! -s "$TEMP_DIR/${PROFILE_NAME}.$extension" ]]; then
        echo "Error: Failed to convert favicon to PNG" $(file "$TEMP_DIR/$FAVICON_FILE")
        exit 1
    fi

    PROFILE_ICON="$TEMP_DIR/${PROFILE_NAME}.$extension"
}

function create_firefox_profile {
    echo "Creating Firefox profile..."
    PROFILE_DIR="$APP_DIR/firefox/${PROFILE_NAME}"
    mkdir -p "$PROFILE_DIR"
    firefox -CreateProfile "$PROFILE_NAME $PROFILE_DIR" -headless

    echo Waiting for profile creation . .
    sleep 5

    create_user_options
    create_user_chrome
}

function install_profile {  # ()
    if [[ -s "$CUSTOM_FAVICON" ]]; then
        process_custom_icon
    else
        skim_website
        examine_favicon_pattern_links "$URL" "$HTML_CONTENT"

        if [ -z "${FAVICON_URL:-}" ]; then
            # Look for well known paths like /favicon.ico
            echo "No favicon link found in HTML, trying defaults"
            probe_default_icon_urls
        fi

        if [[ -z "${FAVICON_URL:-}" ]]; then
            echo "No Favicon Found"
            exit 1
        fi
    fi

    [[ ${DEBUG:-} -eq 1 ]] && cp -f  "$TEMP_DIR/$FAVICON_FILE" .
    convert_and_resize_icon

    # If in Debug, exit now and don't create the profile
    [[ ${DEBUG:-} -eq 1 ]] && cp -f "$PROFILE_ICON" .
    [[ ${DEBUG:-} -eq 1 ]] && exit

    # Install icon
    install_icon "$PROFILE_ICON"

    # Create Firefox profile
    create_firefox_profile
    create_desktop_shortcut

    print_summary
}

function download_icon_check_quality { #(base_url, url)
    if [[ -z "${1:-}" || -z "${2:-}" ]]; then
        return
    fi

    local url=$(relative_url_to_abs "${1:-}" "${2:-}")
    local file_extension="${url##*.}"
    file_extension="${file_extension%%\?*}"

    if [[ $file_extension =~ ^(svg)$ ]]; then
        FAVICON_URL="$url"
        FAVICON_FILE="favicon.$file_extension"
        curl_link "$url" "$TEMP_DIR/favicon.$file_extension" >& /dev/null
    elif [[ ! $file_extension =~ ^(png|jpg|jpeg|gif|ico|webp|avif)$ ]]; then
        echo "Unknown Image Extension $file_extension"
        return
    else
        curl_link "$url" "$TEMP_DIR/favicon.$file_extension" >& /dev/null
        if [[ ! -s "$TEMP_DIR/favicon.$file_extension" ]]; then
            echo "Failed to download favicon"
            return
        fi

        local quality=$(file "$TEMP_DIR/favicon.$file_extension" | grep -oP '\b(\d{2,})\s?x\s?\1\b' | tr 'x' ' ' | awk '{print $NF;exit}')
        file "$TEMP_DIR/favicon.$file_extension"
        if [[ $((quality)) -ge $ICON_SIZE ]]; then
            FAVICON_URL="$url"
            FAVICON_FILE="favicon.$file_extension"
        fi
    fi
}

function main {
    # Debug mode ?
    if [[ ${1:-} == "-n" ]]; then
        DEBUG=1
        shift
    fi

    if [[ ${1:-} == "-r" ]]; then
        local remove_profile=1
        shift
    elif [[ ${1:-} == "-l" ]]; then
        list_profiles
        exit
    fi

    URL="${1:-}"
    CUSTOM_FAVICON="${2:-}"

    # No Args ?
    [[ -n $URL  ]] || usage

    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" EXIT

    verify_dependencies
    extract_hostname

    if [[ ${remove_profile:-} -eq 1 ]]; then
        remove_profile
    else
        echo "Creating SSB for: $HOSTNAME with Profile name: $PROFILE_NAME"
        install_profile
    fi
}

main "$@"
