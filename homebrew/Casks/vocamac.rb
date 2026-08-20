# TypeFlow — stable cask.
#
# The .app bundle is TypeFlow.app and dist.sh names the DMG TypeFlow-<ver>-<arch>.dmg
# (see scripts/app-name.sh — DISPLAY_NAME drives both). The cask token stays
# "vocamac" so existing `brew upgrade` and the homebrew-vocamac tap keep working.
#
# ⚠️  UNPUBLISHABLE AS-IS: the `url` below still points at the UPSTREAM
# jatinkrmalik/vocamac releases, whose assets are named VocaMac-*.dmg and
# contain VocaMac.app — not this fork's TypeFlow build. This fork has no
# release repo of its own yet, so there is nothing correct to point at.
# Repoint `url`/`verified`/`homepage` at the fork's own repo before publishing.
# (Same root cause as the disabled update checker — see UpdateChecker.swift.)
cask "vocamac" do
  version "0.6.2"
  sha256 "9de43a316ac885deb7b84ead8fe292d16432cce9968d53941c855cc8ff3bed28"

  url "https://github.com/jatinkrmalik/vocamac/releases/download/v#{version}/TypeFlow-#{version}-arm64.dmg",
      verified: "github.com/jatinkrmalik/vocamac/"
  name "TypeFlow"
  name "VocaMac"
  desc "Local voice-to-text dictation powered by WhisperKit"
  homepage "https://vocamac.com/"

  livecheck do
    url :url
    strategy :github_latest
  end

  conflicts_with cask: "vocamac-nightly"
  depends_on arch: :arm64
  depends_on macos: :ventura

  app "TypeFlow.app"

  # Bundle id and support paths deliberately keep the old identifiers so
  # upgrading installs retain their models, history, and preferences.
  zap trash: [
    "~/Library/Application Support/VocaMac",
    "~/Library/Caches/com.vocamac.app",
    "~/Library/Preferences/com.vocamac.app.plist",
    "~/Library/Saved Application State/com.vocamac.app.savedState",
  ]
end
