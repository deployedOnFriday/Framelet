import 'dart:io';

import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../services/scraper_service.dart';

/// 手动匹配对话框：搜索剧名 → 从结果中挑选正确的一部。
class MatchSearchDialog extends StatefulWidget {
  const MatchSearchDialog({
    required this.initialQuery,
    required this.preferTv,
    super.key,
  });

  final String initialQuery;

  /// 当前条目是剧集时优先展示剧集结果。
  final bool preferTv;

  @override
  State<MatchSearchDialog> createState() => _MatchSearchDialogState();
}

class _MatchSearchDialogState extends State<MatchSearchDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialQuery,
  );
  final _focus = FocusNode();
  List<ScrapeCandidate> _results = const [];
  bool _searching = false;
  bool _searched = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focus.requestFocus();
      if (_controller.text.trim().isNotEmpty) _search();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _searching = true;
      _error = null;
      _searched = true;
    });
    final results = await ScraperService.searchCandidates(
      query,
      preferTv: widget.preferTv,
    );
    if (!mounted) return;
    setState(() {
      _searching = false;
      _results = results;
      if (results.isEmpty) {
        if (!_hasTmdbKey) {
          _error = '未配置 TMDB 密钥，无法搜索。请到 设置 → 刮削 填写。';
        } else if (ScraperService.lastError.isNotEmpty) {
          _error = '搜索失败：${ScraperService.lastError}';
        } else {
          _error = '没有找到「$query」，换个名字试试（可用英文原名）';
        }
      }
    });
  }

  bool get _hasTmdbKey => (ScraperService.tmdbApiKey ?? '').trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: 760,
        height: 620,
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.manage_search_rounded,
                  color: context.colors.primary,
                ),
                const SizedBox(width: 10),
                Text('手动匹配影片信息', style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                  tooltip: '关闭',
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              widget.preferTv ? '这是剧集条目，搜索剧名后选择正确的电视剧/动漫' : '搜索片名后选择正确的影片',
              style: TextStyle(color: context.colors.muted, fontSize: 12.5),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: TextField(
                      spellCheckConfiguration:
                          const SpellCheckConfiguration.disabled(),
                      controller: _controller,
                      focusNode: _focus,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _search(),
                      decoration: InputDecoration(
                        hintText: '输入剧名/片名，例如 三体、Signal、OurTV',
                        prefixIcon: const Icon(Icons.search_rounded, size: 20),
                        filled: true,
                        fillColor: context.colors.surface,
                        contentPadding: const EdgeInsets.symmetric(vertical: 8),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(11),
                          borderSide: BorderSide(color: context.colors.border),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(11),
                          borderSide: BorderSide(color: context.colors.border),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  height: 44,
                  child: FilledButton(
                    onPressed: _searching ? null : _search,
                    child: _searching
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('搜索'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_searching) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          textAlign: TextAlign.center,
          style: TextStyle(color: context.colors.muted),
        ),
      );
    }
    if (!_searched) {
      return Center(
        child: Text(
          '输入关键词后按回车搜索',
          style: TextStyle(color: context.colors.muted),
        ),
      );
    }
    if (_results.isEmpty) {
      return Center(
        child: Text('没有结果', style: TextStyle(color: context.colors.muted)),
      );
    }
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 0.52,
      ),
      itemCount: _results.length,
      itemBuilder: (context, index) => _CandidateCard(
        candidate: _results[index],
        onTap: () => Navigator.pop(context, _results[index]),
      ),
    );
  }
}

class _CandidateCard extends StatefulWidget {
  const _CandidateCard({required this.candidate, required this.onTap});

  final ScrapeCandidate candidate;
  final VoidCallback onTap;

  @override
  State<_CandidateCard> createState() => _CandidateCardState();
}

class _CandidateCardState extends State<_CandidateCard> {
  bool _hovered = false;
  Future<String?>? _posterFuture;

  @override
  void initState() {
    super.initState();
    final url = widget.candidate.posterUrl;
    if (url != null) {
      // 不用 Image.network：国内网络下 image.tmdb.org 直连会被墙，
      // 候选列表会全变占位图。走刮削服务同一套下载/缓存通道。
      _posterFuture = ScraperService.downloadPoster(
        url,
        cacheKey:
            'candidate_${widget.candidate.tmdbId ?? widget.candidate.name}'
            '_${widget.candidate.year ?? ''}',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final candidate = widget.candidate;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          decoration: BoxDecoration(
            color: context.colors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _hovered
                  ? context.colors.primary.withValues(alpha: 0.5)
                  : context.colors.border,
            ),
            boxShadow: _hovered
                ? [
                    BoxShadow(
                      color: context.colors.primary.withValues(alpha: 0.12),
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(11),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _buildPoster(context),
                      Positioned(
                        right: 6,
                        top: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            candidate.typeLabel,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(9, 8, 9, 9),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      candidate.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: context.colors.text,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      [
                        if (candidate.year != null) '${candidate.year}',
                        if (candidate.rating != null) '★ ${candidate.rating}',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: context.colors.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPoster(BuildContext context) {
    final future = _posterFuture;
    if (future == null) return _posterPlaceholder(context);
    return FutureBuilder<String?>(
      future: future,
      builder: (context, snapshot) {
        final path = snapshot.data;
        if (path != null) {
          return Image.file(
            File(path),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => _posterPlaceholder(context),
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return Container(
            color: context.colors.primarySoft,
            child: const Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        return _posterPlaceholder(context);
      },
    );
  }

  Widget _posterPlaceholder(BuildContext context) {
    return Container(
      color: context.colors.primarySoft,
      child: Center(
        child: Icon(Icons.movie_outlined, color: context.colors.primary),
      ),
    );
  }
}
