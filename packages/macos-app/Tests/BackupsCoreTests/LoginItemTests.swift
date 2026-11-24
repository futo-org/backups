import BackupsCore
import Testing

@Test(arguments: [
  (true, LoginItemStatus.notRegistered, LoginItemChange.register),
  (true, .notFound, .register),
  (true, .enabled, .none),
  (true, .requiresApproval, .askForApproval),
  (false, .enabled, .unregister),
  (false, .requiresApproval, .unregister),
  (false, .notRegistered, .none),
  (false, .notFound, .none),
])
func loginItemChangeFollowsTheActualStatus(wanted: Bool, status: LoginItemStatus, change: LoginItemChange) {
  #expect(LoginItemChange.toward(openAtLogin: wanted, from: status) == change)
}
