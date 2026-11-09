import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../services/media_search.dart';
import '../widgets/mobile_poster_grid.dart';

/// 手机端全屏搜索页。
class MobileSearchPage extends StatefulWidget {
  const MobileSearchPage({super.key});

  @override
  State<MobileSearchPage> createState() => _MobileSearchPageState();
}

class _MobileSearchPageState extends State<MobileSearchPage> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  String _query = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final query = _query.trim();
    final results = searchMediaItems(query);

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 20, 10),
              child: Row(
                children: [
                  IconButton(
                    key: const ValueKey('mobile-search-back'),
                    onPressed: () => Navigator.of(context).maybePop(),
                    tooltip: '返回',
                    icon: const Icon(Icons.arrow_back_ios_new_rounded),
                    iconSize: 20,
                    color: colors.text,
                  ),
                  const SizedBox(width: 2),
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: TextField(
                        key: const ValueKey('mobile-search-field'),
                        controller: _controller,
                        focusNode: _focus,
                        textInputAction: TextInputAction.search,
                        spellCheckConfiguration:
                            const SpellCheckConfiguration.disabled(),
                        onChanged: (value) => setState(() => _query = value),
                        style: TextStyle(fontSize: 14.5, color: colors.text),
                        decoration: InputDecoration(
                          hintText: '搜索片名',
                          hintStyle: TextStyle(
                            color: colors.muted,
                            fontSize: 14,
                          ),
                          prefixIcon: Icon(
                            Icons.search_rounded,
                            size: 20,
                            color: colors.muted,
                          ),
                          suffixIcon: _query.isEmpty
                              ? null
                              : IconButton(
                                  onPressed: () {
                                    _controller.clear();
                                    setState(() => _query = '');
                                    _focus.requestFocus();
                                  },
                                  tooltip: '清空',
                                  iconSize: 18,
                                  color: colors.muted,
                                  icon: const Icon(Icons.close_rounded),
                                ),
                          filled: true,
                          fillColor: colors.surface,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 11,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(13),
                            borderSide: BorderSide(color: colors.border),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(13),
                            borderSide: BorderSide(color: colors.border),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(13),
                            borderSide: BorderSide(
                              color: colors.primary,
                              width: 1.4,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (query.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 4, 22, 2),
                child: Row(
                  children: [
                    Text(
                      '搜索结果',
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                        color: colors.text,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: colors.primarySoft,
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Text(
                        '${results.length}',
                        style: TextStyle(
                          color: colors.primary,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: query.isEmpty
                  ? _SearchHint(
                      icon: Icons.search_rounded,
                      title: '搜索你的媒体库',
                      subtitle: '输入片名，快速找到想看的电影、剧集与动漫。',
                    )
                  : results.isEmpty
                  ? _SearchHint(
                      icon: Icons.search_off_rounded,
                      title: '没有找到「$query」',
                      subtitle: '试试更短的关键词，或先在设置里同步媒体库。',
                    )
                  : MobilePosterGrid(
                      key: const ValueKey('mobile-search-results-grid'),
                      items: results,
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchHint extends StatelessWidget {
  const _SearchHint({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 80),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 34, color: colors.iconMuted),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: colors.text,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: colors.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
