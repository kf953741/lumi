cask "lumi" do
  version "1.3.0"
  sha256 "2d807cb3df6e4dafc5e41478a37e77f669459b8f9abfaf8487ff81de1243dcae"

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
