#!/bin/bash

# Site-Specific Browser (SSB) Creator - Creates Firefox profiles for web applications similar to ice-ssb utility

set -euo pipefail

ICON_SIZE=128
MOZILLA_USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36"

function usage {
    echo "Usage: $0 [-n | DEBUG MODE] [-r | REMOVE PROFILE] [-l | LIST PROFILEs] <URL> [FAVICON_PATH]"
    echo "Example: $0 https://en.wikipedia.org"
    echo "Example: $0 -n https://en.wikipedia.org"
    echo "Example: $0 https://en.wikipedia.org  /path/to/custom-icon.png"
    echo "Example: $0 -r https://en.wikipedia.org"
    echo "Example: $0 -l"
    exit 1
}

function verify_dependencies {
    # These are required
    local missing=''
    for cmd in curl magick firefox sed grep head tr; do
        if ! command -v $cmd >& /dev/null; then
            missing="$missing $cmd"
        fi
    done

    if [[ -n $missing ]]; then
        echo "Dependencies missing from PATH: $missing"
        exit 1
    fi
}

function curl_link {  # (url)
    local url="$1"
    local outfile=${2:-$(mktemp --tmpdir=$TEMP_DIR)}

    # Some sites require a referrer and a user agent, so try multiple combinations
    for arg in {0..3}; do
        case $arg in
            0) curl --silent --location --fail "$url" -o $outfile >& /dev/null ;;
            1) curl -H "Referer: https://google.com" --silent --location --fail "$url" -o $outfile >& /dev/null ;;
            2) curl -A "$MOZILLA_USER_AGENT" --silent --location --fail "$url" -o $outfile >& /dev/null ;;
            3) curl -H "Referer: https://google.com" -A "$MOZILLA_USER_AGENT" --silent --location --fail "$url" -o $outfile >& /dev/null ;;
        esac
        if [[ $? -eq 0 ]]; then
            cat $outfile
            return
        fi
    done
}

function skim_website {
    # Get just the domain part from the URL
    local html_url=$(echo $URL | sed -E 's/([^:\/])\/.*/\1/g')
    echo "Checking for favicon link in HTML... $html_url"

    # Fetch the first 1000 lines
    HTML_CONTENT=$(curl_link "$html_url" | head -n 1000) || true
    if [[ ${DEBUG:-} -eq 1 ]]; then
        echo "$HTML_CONTENT"
    fi
}

function examine_favicon_pattern_links { #(html_content)
    local html_content=$1

    # Look at <meta property=""> tags within the HTML
    for property in 'twitter:image' 'og:image'; do
        FAVICON_URL=$(echo "$html_content" | sed 's/>/>\n/g' | grep -iE "meta property=\"$property\".*content=\"?[^\"]" | head -n 1 | sed -nE 's/.*content="?([^"\\ ]*)"?.*/\1/p' | xargs) || true
        if [[ -n ${FAVICON_URL:-} ]]; then
            return
        fi
    done

    # Look at <link rel=""> tags within the HTML
    for rel in 'apple-touch-icon-precomposed' 'apple-touch-icon' 'fluid-icon' 'shortcut icon' 'favicon' 'image_src'; do
        FAVICON_URL=$(echo "$html_content" | sed 's/>/>\n/g' | grep -iE "rel=\"$rel\"" | head -n 1 | sed -n 's/.*href="\([^"]*\)".*/\1/p' | xargs) || true
        if [[ -n ${FAVICON_URL:-} ]]; then
            return
        fi
    done

    for size in 'sizes="512x512"' 'sizes="256x256"' 'sizes="192x192"' 'sizes="128x128"' 'sizes="64x64"' 'sizes="32x32"' ' '; do
        FAVICON_URL=$(echo "$html_content" | sed 's/>/>\n/g' | grep -iE "rel=\"icon\".*$size" | head -n 1 | sed -n 's/.*href="\([^"]*\)".*/\1/p' | xargs) || true
        if [[ -n ${FAVICON_URL:-} ]]; then
            return
        fi
    done;
}

function download_icon {
    local file_extension="${FAVICON_URL##*.}"
    file_extension="${file_extension%%\?*}"

    if [[ $file_extension =~ ^(png|jpg|jpeg|gif|svg|ico)$ ]]; then
        FAVICON_FILE="favicon.$file_extension"
    else
        echo "Unknown Image Extension $file_extension"
        exit 1
    fi

    curl_link "$FAVICON_URL" "$TEMP_DIR/$FAVICON_FILE" >& /dev/null
    if [[ ! -s "$TEMP_DIR/$FAVICON_FILE" ]]; then
        echo "Failed to download favicon"
        exit 1
    fi
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
    cp -f "$CUSTOM_FAVICON" "$TEMP_DIR/$FAVICON_FILE"
}

function relative_url_to_abs {  # ()
    local base_url=$(echo "$URL" | sed -n 's/^\(https\?:\/\/[^\/]*\).*/\1/p')
    local protocol=$(echo "$URL" | sed -n 's/^\(https\?\):\/\/.*/\1/p')

    if [[ $FAVICON_URL =~ ^https?:// ]]; then
        # Already absolute URL
        echo "Found absolute favicon URL in HTML: $FAVICON_URL"
    elif [[ $FAVICON_URL =~ ^// ]]; then
        # Protocol-relative URL
        FAVICON_URL="${protocol}:${FAVICON_URL}"
        echo "Found protocol relative favicon URL in HTML: $FAVICON_URL"
    elif [[ $FAVICON_URL =~ ^/ ]]; then
        # Root-relative URL
        FAVICON_URL="${base_url}${FAVICON_URL}"
        echo "Found root favicon URL in HTML: $FAVICON_URL"
    else
        # Relative URL
        FAVICON_URL=$(echo $FAVICON_URL | sed -E 's/(^[^\/])/\/\1/')
        FAVICON_URL="${base_url}${FAVICON_URL}"
        echo "Found relative favicon URL in HTML: $FAVICON_URL"
    fi
}

function parse_html {
     # Fetch the first 1000 lines
    local html_content=$(curl_link "$HTML_URL" | head -n 1000) || true

    # Look for various favicon link patterns
    examine_rel_links "$html_content"
}

function install_icon { # (icon_filesystem_path)
    local src_path=$1

    # Create icon directory structure
    local icon_dir="$HOME/.local/share/icons/hicolor/${ICON_SIZE}x${ICON_SIZE}/apps"
    mkdir -p "$icon_dir"

    echo "Installing icon..."
    cp -f "$src_path" "$icon_dir/"
    ICON_PATH="$icon_dir/${PROFILE_NAME}.png"
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
		  Comment=$HOSTNAME \(SSB\)
		  Exec=firefox --class SSB-$HOSTNAME --profile $PROFILE_DIR --no-remote $URL
		  SSBFirefox=$HOSTNAME
		  Terminal=false
		  X-MultipleArgs=false
		  Type=Application
		  Icon=$ICON_PATH
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
    echo "No favicon link found in HTML, trying defaults"
    local possible_urls=(
        'apple-touch-icon-precomposed.png'
        'apple-touch-icon.png'
        'favicon.png'
        'favicon.jpg'
        'favicon.ico'
        'favicon.svg'
    )

    for icon_url in "${possible_urls[@]}"; do
        echo Trying "${BASE_URL}/$icon_url"
        result=$(curl_link "${BASE_URL}/$icon_url")
        if [[ -n "$result" ]]; then
            FAVICON_URL="${BASE_URL}/$icon_url"
            break
        fi
    done
}

function convert_and_resize_icon { # ()
    # Convert and resize favicon
    echo "Converting favicon to ${ICON_SIZE}x${ICON_SIZE} PNG..."
    if [[ $FAVICON_FILE =~ .svg$ ]]; then
        if command -v inkscape >& /dev/null; then
            echo Running inkscape
            inkscape -w $ICON_SIZE -h $ICON_SIZE "$TEMP_DIR/$FAVICON_FILE" -o "$TEMP_DIR/${PROFILE_NAME}.png" || true
        else
            echo "inkscape is required to process SVG icons"
            exit 1
        fi
    else
        magick "$TEMP_DIR/$FAVICON_FILE[0]" -resize ${ICON_SIZE}x${ICON_SIZE} "$TEMP_DIR/${PROFILE_NAME}.png" || true
    fi

    # Check if conversion was successful
    if [[ ! -s "$TEMP_DIR/${PROFILE_NAME}.png" ]]; then
        echo "Error: Failed to convert favicon to PNG" $(file "$TEMP_DIR/$FAVICON_FILE")
        exit 1
    fi
}

function create_firefox_profile {
    echo "Creating Firefox profile..."
    PROFILE_DIR="$HOME/.local/share/ssb/${PROFILE_NAME}"
    mkdir -p "$PROFILE_DIR"
    firefox -CreateProfile "$PROFILE_NAME $PROFILE_DIR" -headless

    echo Waiting for profile creation . .
    sleep 5

    create_user_options
    create_user_chrome
}

function print_summary {
    echo "
        SSB created successfully!
        URL: $URL
        Profile: $PROFILE_DIR
        Desktop file: $DESKTOP_FILE
        Icon: $ICON_PATH

        You can now launch the SSB from your application menu or run:
        firefox --class SSB-$HOSTNAME --profile '$PROFILE_DIR' --no-remote '$URL'
    " | sed -E 's/^\s+//g'
}

function extract_hostname { # ()
    # Extract hostname from URL and Sanitize hostname for use as profile name
    if [[ $URL =~ ^https?://([^/]+) ]]; then
        BASE_URL=$(echo "$URL" | sed -E 's#(https?://[^/]+).*#\1#g')
        HOSTNAME=$(echo "$BASE_URL" | sed -E 's#https?://([^/]+).*#\1#g')
        PROFILE_NAME=$(echo "$HOSTNAME" | sed 's/[^a-zA-Z0-9]/-/g' | tr '[:upper:]' '[:lower:]')
    else
        echo "Error: Invalid URL format. Please provide a valid HTTP/HTTPS URL."
        exit 1
    fi
}

function install_profile {  # ()
    if [[ -s "$CUSTOM_FAVICON" ]]; then
        process_custom_icon
    else
        skim_website
        examine_favicon_pattern_links "$HTML_CONTENT"

        if [ -n "$FAVICON_URL" ]; then
            relative_url_to_abs
        else
            # Look for well known paths like /favicon.ico
            probe_default_icon_urls
        fi

        if [[ -z "$FAVICON_URL" ]]; then
            echo "No Favicon Found"
            exit 1
        fi

        # Download the favicon
        echo "Downloading favicon... $FAVICON_URL"
        download_icon
    fi

    convert_and_resize_icon

    # If in Debug, exit now and don't create the profile
    [[ ${DEBUG:-} -eq 1 ]] && exit

    # Install icon
    install_icon "$TEMP_DIR/${PROFILE_NAME}.png"

    # Create Firefox profile
    create_firefox_profile
    create_desktop_shortcut

    print_summary
}

function remove_profile {  # ()
    echo "Removing Firefox Profile ..."
    local profile_dir="$HOME/.local/share/ssb/${PROFILE_NAME}"
    if [[ -f "$profile_dir/user.js" ]]; then
        rm -rfv "$profile_dir"
    fi

    echo "Removing Icon ..."
    local icon_dir="$HOME/.local/share/icons/hicolor/${ICON_SIZE}x${ICON_SIZE}/apps"
    ICON_PATH="$icon_dir/${PROFILE_NAME}.png"
    rm -fv "$ICON_PATH"

    echo "Removing Desktop Shortcut ..."
    local desktop_dir="$HOME/.local/share/applications"
    rm -fv "$desktop_dir/${PROFILE_NAME}.desktop"
}

function list_profiles {  #()
    local desktop_dir="$HOME/.local/share/applications"
    grep -hPo '(SSBFirefox|IceFirefox)=(.*)' $desktop_dir/*.desktop | sed -E 's/[a-z]{3}Firefox=//ig'
}

function main {
    # Debug mode ?
    if [[ ${1:-} == "-n" ]]; then
        DEBUG=1
        set -x
        shift
    fi

    if [[ ${1:-} == "-r" ]]; then
        REMOVE_PROFILE=1
        shift
    elif [[ ${1:-} == "-l" ]]; then
        LIST_PROFILES=1
        shift
    fi

    URL="${1:-}"
    CUSTOM_FAVICON="${2:-}"

    # No Args ?
    [[ -n $URL || ${LIST_PROFILES:-} -eq 1 ]] || usage

    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" EXIT

    verify_dependencies
    if [[ ${LIST_PROFILES:-} -eq 1 ]]; then
        list_profiles
        exit
    fi

    extract_hostname
    if [[ ${REMOVE_PROFILE:-} -eq 1 ]]; then
        remove_profile
    else
        echo "Creating SSB for: $HOSTNAME with Profile name: $PROFILE_NAME"
        install_profile
    fi
}

main "$@"
