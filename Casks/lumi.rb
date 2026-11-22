cask "lumi" do
  version "1.3.0"
  sha256 "9ad1d29ea4901dc6fdec7b9d24701032b54e6a86aaa700c7151ca5ce81ee32a8"

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
