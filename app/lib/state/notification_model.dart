class ServiceNotification {
  const ServiceNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.level,
    required this.createdAt,
  });

  final String id;
  final String title;
  final String body;
  final String level;
  final int createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'body': body,
    'level': level,
    'created_at': createdAt,
  };

  static List<ServiceNotification> parseList(Object? value) {
    if (value is! List) return const [];
    final ids = <String>{};
    final result = <ServiceNotification>[];
    for (final item in value.take(50)) {
      if (item is! Map) continue;
      final id = item['id'];
      final title = item['title'];
      final body = item['body'];
      final level = item['level'];
      final createdAt = item['created_at'];
      if (id is! String ||
          !RegExp(r'^[0-9a-f]{32}$').hasMatch(id) ||
          title is! String ||
          title.trim().isEmpty ||
          title.runes.length > 120 ||
          body is! String ||
          body.trim().isEmpty ||
          body.runes.length > 2000 ||
          level is! String ||
          !['info', 'important', 'maintenance'].contains(level) ||
          createdAt is! int ||
          createdAt <= 0 ||
          createdAt > 8640000000000 ||
          (item['revoked_at'] != null && item['revoked_at'] != 0) ||
          !ids.add(id)) {
        continue;
      }
      result.add(
        ServiceNotification(
          id: id,
          title: title,
          body: body,
          level: level,
          createdAt: createdAt,
        ),
      );
    }
    return List.unmodifiable(result);
  }
}
