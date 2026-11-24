/// How far the paired-Watch prerequisites for Whirr have progressed.
///
/// Setup can only transmit from `ready`. The other cases each need a different action from the
/// person, though WatchConnectivity reports them all as one send failure.
enum WatchInstallState: Equatable {
  /// WatchConnectivity has not finished activating, so no prerequisite can be asserted yet.
  case unknown
  /// No Apple Watch is paired with this iPhone.
  case unpaired
  /// A Watch is paired but the Whirr Watch app is not installed on it.
  case appNotInstalled
  /// A Watch is paired and the Whirr Watch app is installed.
  case ready
}
