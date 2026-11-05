/// 图片解码宽度的档位化工具。
///
/// `Image.file` 的 `cacheWidth` 变化会创建新的 ImageProvider 并重新解码。
/// 布局宽度在小范围内连续变化时（如侧栏展开动画挤压内容区、窗口拖拽），
/// 逐帧变化的解码宽度会导致每帧重新解码所有可见图片，造成明显卡顿。
/// 把解码宽度向上取整到固定档位后，小幅布局变化不会越过档位边界，
/// ImageProvider 缓存持续命中，只在真正需要更高分辨率时解码一次。
int decodeCacheWidth(
  double layoutWidth,
  double devicePixelRatio, {
  int step = 64,
  int min = 64,
  int max = 2400,
}) {
  if (!layoutWidth.isFinite || layoutWidth <= 0) return min;
  final px = (layoutWidth * devicePixelRatio / step).ceil() * step;
  return px.clamp(min, max);
}
