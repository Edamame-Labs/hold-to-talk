cask "holdtotalk" do
  version "TMPL_VERSION"
  sha256 "TMPL_SHA256"

  url "https://github.com/Edamame-Labs/hold-to-talk/releases/download/v#{version}/HoldToTalk-v#{version}.zip"
  name "Hold to Talk"
  desc "Free, open-source voice dictation for macOS"
  homepage "https://holdtotalk.ai/"

  depends_on macos: ">= :sequoia"

  app "Hold To Talk.app"

  zap trash: [
    "~/Library/Application Support/HoldToTalk",
    "~/Library/Preferences/com.holdtotalk.app.plist",
  ]
end
