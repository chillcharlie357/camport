final class CameraPage<T> {
  CameraPage({required List<T> items, this.nextCursor})
    : items = List<T>.unmodifiable(items);

  final List<T> items;
  final String? nextCursor;
}
