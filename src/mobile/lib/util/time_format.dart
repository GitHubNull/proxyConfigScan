/// 扫码/使用时间的展示口径：当天显示“今天 HH:mm”，其余“M-dd HH:mm”。
String formatScanTime(int millis, {DateTime? now}) {
  final dt = DateTime.fromMillisecondsSinceEpoch(millis);
  final ref = now ?? DateTime.now();
  final sameDay =
      dt.year == ref.year && dt.month == ref.month && dt.day == ref.day;
  final hm =
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  if (sameDay) return '今天 $hm';
  return '${dt.month}-${dt.day.toString().padLeft(2, '0')} $hm';
}
