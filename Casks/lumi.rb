cask "lumi" do
  version "1.4.1"
  sha256 "3da42518271028a5119417513ff05ea8ad2c2b9aa1d3b7755f6992a563c22b46"

  url "https://github.com/kf953741/lumi/releases/download/v#{version}/Lumi-v#{version}-arm64.dmg"
  name "Lumi"
  desc "Dynamic Notch & Desktop Mission Control for AI coding agents"
  homepage "https://github.com/kf953741/lumi"

  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "Lumi.app"

  zap trash: [
    "~/Library/LaunchAgents/cc.bigsmart.Lumi.plist",
    "~/Library/Preferences/cc.bigsmart.Lumi.plist",
    "~/.lumi",
  ]
end
