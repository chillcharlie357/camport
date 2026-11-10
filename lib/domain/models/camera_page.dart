final class CameraPage<T> {
  const CameraPage({required this.items, this.nextCursor});

  final List<T> items;
  final String? nextCursor;
}
