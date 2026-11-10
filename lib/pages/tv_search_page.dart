import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../services/media_search.dart';
import '../widgets/tv_poster_grid.dart';

/// 电视端全屏搜索：大输入框 + 大卡片结果墙。
class TvSearchPage extends StatefulWidget {
  const TvSearchPage({super.key});

  @override
  State<TvSearchPage> createState() => _TvSearchPageState();
}

class _TvSearchPageState extends State<TvSearchPage> {
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
    final results = searchMediaItems(_query);

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(40, 28, 40, 0),
              child: Row(
                children: [
                  Text(
                    '搜索',
                    style: TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.w700,
                      color: colors.text,
                    ),
                  ),
                  const SizedBox(width: 28),
                  Expanded(
                    child: SizedBox(
                      height: 62,
                      child: TextField(
                        key: const ValueKey('tv-search-field'),
                        controller: _controller,
                        focusNode: _focus,
                        textInputAction: TextInputAction.search,
                        spellCheckConfiguration:
                            const SpellCheckConfiguration.disabled(),
                        onChanged: (value) => setState(() => _query = value),
                        style: TextStyle(fontSize: 22, color: colors.text),
                        decoration: InputDecoration(
                          hintText: '输入片名（可用遥控器/手机输入法）',
                          hintStyle: TextStyle(
                            color: colors.muted,
                            fontSize: 20,
                          ),
                          prefixIcon: Icon(
                            Icons.search_rounded,
                            size: 26,
                            color: colors.muted,
                          ),
                          filled: true,
                          fillColor: colors.surface,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 18,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide(color: colors.border),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide(color: colors.border),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide(
                              color: colors.primary,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 20),
                  TextButton(
                    key: const ValueKey('tv-search-close'),
                    onPressed: () => Navigator.of(context).maybePop(),
                    style: TextButton.styleFrom(
                      foregroundColor: colors.text,
                      minimumSize: const Size(110, 56),
                      textStyle: const TextStyle(fontSize: 19),
                    ),
                    child: const Text('返回'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Expanded(
              child: _query.trim().isEmpty
                  ? Center(
                      child: Text(
                        '输入关键字开始搜索',
                        style: TextStyle(fontSize: 20, color: colors.muted),
                      ),
                    )
                  : results.isEmpty
                  ? Center(
                      child: Text(
                        '没有找到「${_query.trim()}」',
                        style: TextStyle(fontSize: 20, color: colors.muted),
                      ),
                    )
                  : TvPosterGrid(
                      key: const ValueKey('tv-search-results'),
                      items: results,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
