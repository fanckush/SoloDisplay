# Homebrew Cask for Lidless.
#
# This file belongs in your tap repo (fanckush/homebrew-lidless) at
# Casks/lidless.rb, not in the main app repo. It is kept here as the source of
# truth. The Release workflow bumps the copy in the tap.
cask "lidless" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/fanckush/Lidless/releases/download/v#{version}/Lidless-#{version}.zip"
  name "Lidless"
  desc "Turns off the MacBook internal display when docked to an external monitor"
  homepage "https://github.com/fanckush/Lidless"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :tahoe"

  app "Lidless.app"

  zap trash: [
    "~/Library/Preferences/dev.lidless.Lidless.plist",
    "~/Library/Application Support/Lidless",
  ]
end
