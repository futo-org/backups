import BackupsCore
import Testing

@Test(
  "quit requests without an explicit quit stay in the menu bar only when they come from the user",
  arguments: [
    (nil, QuitDecision.stayInMenuBar),
    (QuitEvent(hasQuitReason: false, senderBundleIdentifier: QuitPolicy.dockBundleIdentifier), .stayInMenuBar),
    (QuitEvent(hasQuitReason: true, senderBundleIdentifier: QuitPolicy.dockBundleIdentifier), .quit),
    (QuitEvent(hasQuitReason: true, senderBundleIdentifier: nil), .quit),
    (QuitEvent(hasQuitReason: false, senderBundleIdentifier: "com.apple.Terminal"), .quit),
    (QuitEvent(hasQuitReason: false, senderBundleIdentifier: nil), .quit),
  ] as [(QuitEvent?, QuitDecision)])
func quitEventsDecideWhetherToQuit(event: QuitEvent?, expected: QuitDecision) {
  #expect(QuitPolicy().decision(for: event) == expected)
}

@Test func choosingQuitQuitsWhateverAsks() {
  var policy = QuitPolicy()
  policy.chooseQuit()
  policy.updateCycleEnded()
  #expect(policy.decision(for: nil) == .quit)
  #expect(
    policy.decision(for: QuitEvent(hasQuitReason: false, senderBundleIdentifier: QuitPolicy.dockBundleIdentifier))
      == .quit)
}

@Test func anUpdateRelaunchQuitsUntilTheUpdateCycleEnds() {
  var policy = QuitPolicy()
  policy.updateWillRelaunch()
  #expect(policy.decision(for: nil) == .quit)

  policy.updateCycleEnded()
  #expect(policy.decision(for: nil) == .stayInMenuBar)
  #expect(!policy.quitChosen)
}
