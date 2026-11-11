/// Stores camera credentials using platform-protected secret storage.
///
/// Platform implementations should use Android Keystore and iOS Keychain.
abstract interface class CameraCredentialStore {
  Future<void> saveSecret(String profileId, String secret);

  Future<String?> readSecret(String profileId);

  Future<void> deleteSecret(String profileId);
}
