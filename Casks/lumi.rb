cask "lumi" do
  version "1.3.0"
  sha256 "db3e699cf70aa4523a2de4b868174307971de11e7a15f3cb0f29a5c4d3b19b4f"

  url "https://github.com/kf953741/lumi/releases/download/v#{version}/Lumi-v#{version}-arm64.dmg"
  name "Lumi"
  desc "Dynamic Notch & Desktop Mission Control for AI coding agents"
  homepage "https://github.com/kf953741/lumi"

  depends_on macos: ">= :sonoma"

  app "Lumi.app"

  zap trash: [
    "~/Library/LaunchAgents/cc.bigsmart.Lumi.plist",
    "~/Library/Preferences/cc.bigsmart.Lumi.plist",
    "~/.lumi",
  ]
end
