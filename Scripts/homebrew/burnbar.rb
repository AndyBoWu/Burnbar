# Homebrew cask for Burnbar — copy this into the PUBLIC tap repo
# `andybowu/homebrew-tap` at `Casks/burnbar.rb`, then run
# `./Scripts/update_cask.sh <version> <path-to-tap-checkout>` after each release
# to bump `version` + `sha256`.
cask "burnbar" do
  version "0.1.0"
  sha256 "REPLACE_WITH_RELEASE_ZIP_SHA256" # printed by ./Scripts/package_app.sh

  url "https://github.com/AndyBoWu/Burnbar/releases/download/v#{version}/Burnbar-v#{version}.zip"
  name "Burnbar"
  desc "Track AI-coding token burn in your macOS menu bar"
  homepage "https://github.com/AndyBoWu/Burnbar"

  depends_on macos: ">= :sonoma"

  app "Burnbar.app"

  # v0 is ad-hoc signed (no Developer ID / notarization yet), so downloads are
  # Gatekeeper-quarantined. Strip the quarantine on install so it opens without
  # the "unidentified developer" prompt. (Remove once Developer ID ships.)
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Burnbar.app"]
  end

  uninstall quit: "xyz.andybowu.Burnbar"

  zap trash: [
    "~/Library/LaunchAgents/xyz.andybowu.Burnbar.plist",
    "~/Library/Preferences/xyz.andybowu.Burnbar.plist",
  ]
end
