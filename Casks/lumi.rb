cask "lumi" do
  version "1.3.0"
  sha256 "1d88e9743bdc42fa0cf5f316179c3387e10d38339f0a90056393a6405ed28dd5"

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
