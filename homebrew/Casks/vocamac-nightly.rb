# TypeFlow — nightly cask. See Casks/vocamac.rb for the naming rationale and
# the same ⚠️ caveat: the `url` still points at the UPSTREAM
# jatinkrmalik/vocamac nightly, which publishes VocaMac.app, not this fork's
# TypeFlow build. Repoint it at the fork's own release repo before publishing.
cask "vocamac-nightly" do
  version :latest
  sha256 :no_check

  url "https://github.com/jatinkrmalik/vocamac/releases/download/nightly/TypeFlow-nightly-arm64.dmg",
      verified: "github.com/jatinkrmalik/vocamac/"
  name "TypeFlow Nightly"
  name "VocaMac Nightly"
  desc "Nightly build of TypeFlow — local voice-to-text dictation"
  homepage "https://vocamac.com/"

  conflicts_with cask: "vocamac"
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
