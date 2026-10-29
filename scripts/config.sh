# Project settings shared by the build and release scripts.
# Personal, machine-specific settings (such as SIGN_IDENTITY) go in scripts/config.local.sh,
# which is not committed. See scripts/config.local.sh.example.

APP_NAME="GitLab Client"
EXECUTABLE="GitLabClient"            # SwiftPM product, and CFBundleExecutable
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

REPO_OWNER="cheesepulab"             # GitHub owner of this repo and its releases
REPO_NAME="gitlab-client-for-mac"
TAP_OWNER="cheesepulab"              # users install from $TAP_OWNER/$TAP_NAME (repo: $TAP_OWNER/homebrew-$TAP_NAME)
TAP_NAME="tap"
CASK_TOKEN="gitlab-client-for-mac"
ZIP_PREFIX="GitLab-Client"           # release asset: ${ZIP_PREFIX}-<version>.zip

COPYRIGHT_NAME="Nguyen Manh Duc"

# Changing it makes macOS treat the app as a new one, and settings reset once.
BUNDLE_ID="io.github.cheesepulab.gitlabclient"
# Tokens are stored as generic passwords under this service, one item per domain. Changing it
# signs everyone out, so keep it once released.
KEYCHAIN_SERVICE="${BUNDLE_ID}"
REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"

# Leave empty for ad-hoc signing. Set it in scripts/config.local.sh to sign with your
# free "Apple Development" certificate instead.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
