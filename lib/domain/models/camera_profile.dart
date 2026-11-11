enum ConnectionKind { cameraAccessPoint, sharedWifi, usb }

final class CameraProfile {
  CameraProfile({
    required this.id,
    required this.displayName,
    required this.connectionKind,
    this.model,
    this.firmware,
    Map<String, String> connectionConfiguration = const {},
  }) : connectionConfiguration = Map<String, String>.unmodifiable(
         connectionConfiguration,
       );

  final String id;
  final String displayName;
  final String? model;
  final String? firmware;
  final ConnectionKind connectionKind;

  /// Non-secret settings persisted locally for this connection.
  /// Credentials and other secrets belong in a credential store.
  final Map<String, String> connectionConfiguration;
}

final class NetworkConnectionResult {
  const NetworkConnectionResult({
    required this.connected,
    required this.requiresUserAction,
    this.message,
  });

  final bool connected;
  final bool requiresUserAction;
  final String? message;
}
