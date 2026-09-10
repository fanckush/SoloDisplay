# Homebrew Cask for SoloDisplay.
#
# This file belongs in your tap repo (fanckush/homebrew-solodisplay) at
# Casks/solodisplay.rb, not in the main app repo. It is kept here as the source of
# truth. The Release workflow bumps the copy in the tap.
cask "solodisplay" do
  version "0.2.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/fanckush/SoloDisplay/releases/download/v#{version}/SoloDisplay-#{version}.zip"
  name "SoloDisplay"
  desc "Turns off the MacBook internal display when docked to an external monitor"
  homepage "https://github.com/fanckush/SoloDisplay"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :tahoe

  app "SoloDisplay.app"

  # The Lidless paths stay listed for one release. An upgrader who zaps should not be left
  # with the old support directory, and its recovery record is adopted at first launch.
  zap trash: [
    "~/Library/Preferences/dev.solodisplay.SoloDisplay.plist",
    "~/Library/Application Support/SoloDisplay",
    "~/Library/Preferences/dev.lidless.Lidless.plist",
    "~/Library/Application Support/Lidless",
  ]
end
