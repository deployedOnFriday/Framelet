import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../models/media_source.dart';

abstract final class DemoData {
  static const featured = <MediaItem>[
    MediaItem(
      title: '群山回响',
      subtitle: '一场穿越云海与时间的旅行',
      year: '2026',
      colors: [Color(0xFF244E4B), Color(0xFF8EA984)],
      icon: Icons.landscape_rounded,
      rating: '8.8',
      quality: '4K',
      description: '当熟悉的山谷再次传来呼唤，我们重新出发，寻找被日常忽略的微光。',
    ),
    MediaItem(
      title: '星轨来信',
      subtitle: '在浩瀚宇宙里，等一封迟到的回信',
      year: '2025',
      colors: [Color(0xFF172D4F), Color(0xFF667FA8)],
      icon: Icons.auto_awesome_rounded,
      rating: '8.5',
      quality: 'HDR',
      description: '一段意外接收到的信号，让两位素未谋面的人开始跨越星系的对话。',
    ),
    MediaItem(
      title: '海岸慢行',
      subtitle: '把生活调成自己喜欢的速度',
      year: '2026',
      colors: [Color(0xFF326879), Color(0xFFD5A764)],
      icon: Icons.sailing_rounded,
      rating: '8.2',
      quality: '4K',
      description: '沿着海岸线一路向南，在风浪、旧书店和小餐馆之间重新认识自己。',
    ),
  ];

  static const recent = <MediaItem>[
    MediaItem(
      title: '晨光旅途',
      subtitle: '剩余 42 分钟',
      year: '2025',
      colors: [Color(0xFFBD7850), Color(0xFFE6C689)],
      icon: Icons.wb_sunny_rounded,
      progress: 0.62,
    ),
    MediaItem(
      title: '星海之旅',
      subtitle: '第 12 集 · 剩余 26 分钟',
      year: '2026',
      colors: [Color(0xFF24375F), Color(0xFF6C8DB2)],
      icon: Icons.rocket_launch_rounded,
      progress: 0.38,
    ),
    MediaItem(
      title: '深海探索',
      subtitle: '2024 · 剩余 18 分钟',
      year: '2024',
      colors: [Color(0xFF124E63), Color(0xFF3E9A9B)],
      icon: Icons.scuba_diving_rounded,
      progress: 0.76,
    ),
  ];

  static const movies = <MediaItem>[
    MediaItem(
      title: '梦境之城',
      subtitle: '剧情',
      year: '2026',
      colors: [Color(0xFF4C3B63), Color(0xFFB58192)],
      icon: Icons.nightlight_round,
      rating: '8.6',
      quality: '4K',
    ),
    MediaItem(
      title: '寂静山岭',
      subtitle: '悬疑',
      year: '2025',
      colors: [Color(0xFF314C49), Color(0xFF8C9D82)],
      icon: Icons.forest_rounded,
      rating: '8.3',
    ),
    MediaItem(
      title: '追光少年',
      subtitle: '青春',
      year: '2026',
      colors: [Color(0xFFC57445), Color(0xFFE6B85F)],
      icon: Icons.directions_bike_rounded,
      rating: '8.1',
    ),
    MediaItem(
      title: '云端车站',
      subtitle: '奇幻',
      year: '2024',
      colors: [Color(0xFF557D9A), Color(0xFFC1D4D7)],
      icon: Icons.train_rounded,
      rating: '8.7',
      quality: '4K',
    ),
    MediaItem(
      title: '风过麦田',
      subtitle: '家庭',
      year: '2025',
      colors: [Color(0xFF92733C), Color(0xFFD4BB6A)],
      icon: Icons.agriculture_rounded,
      rating: '8.0',
    ),
    MediaItem(
      title: '蓝色边界',
      subtitle: '冒险',
      year: '2026',
      colors: [Color(0xFF25517B), Color(0xFF4CA0B3)],
      icon: Icons.waves_rounded,
      rating: '8.4',
    ),
  ];

  static const series = <MediaItem>[
    MediaItem(
      title: '人间烟火',
      subtitle: '全 24 集',
      year: '2026',
      colors: [Color(0xFF874F3E), Color(0xFFD69A68)],
      icon: Icons.storefront_rounded,
      rating: '8.9',
    ),
    MediaItem(
      title: '长街灯火',
      subtitle: '更新至 16 集',
      year: '2026',
      colors: [Color(0xFF343C58), Color(0xFF9C6E68)],
      icon: Icons.location_city_rounded,
      rating: '8.4',
    ),
    MediaItem(
      title: '春日来信',
      subtitle: '全 12 集',
      year: '2025',
      colors: [Color(0xFF7C9272), Color(0xFFD6C2A0)],
      icon: Icons.local_florist_rounded,
      rating: '8.2',
    ),
    MediaItem(
      title: '时间修补师',
      subtitle: '全 18 集',
      year: '2025',
      colors: [Color(0xFF415A72), Color(0xFF8CA8AA)],
      icon: Icons.watch_later_rounded,
      rating: '8.5',
    ),
    MediaItem(
      title: '小城故事',
      subtitle: '全 20 集',
      year: '2024',
      colors: [Color(0xFF866C50), Color(0xFFC5A984)],
      icon: Icons.home_work_rounded,
      rating: '8.1',
    ),
    MediaItem(
      title: '星河档案',
      subtitle: '更新至 8 集',
      year: '2026',
      colors: [Color(0xFF303457), Color(0xFF6576A4)],
      icon: Icons.archive_rounded,
      rating: '8.6',
    ),
  ];

  static const anime = <MediaItem>[
    MediaItem(
      title: '风之庭院',
      subtitle: '全 13 集',
      year: '2025',
      colors: [Color(0xFF638879), Color(0xFFC5C888)],
      icon: Icons.air_rounded,
      rating: '8.8',
    ),
    MediaItem(
      title: '月光便利店',
      subtitle: '全 12 集',
      year: '2026',
      colors: [Color(0xFF424A70), Color(0xFFAA8FA5)],
      icon: Icons.store_rounded,
      rating: '8.5',
    ),
    MediaItem(
      title: '云中鲸',
      subtitle: '剧场版',
      year: '2024',
      colors: [Color(0xFF52889D), Color(0xFFB7D4D1)],
      icon: Icons.cloud_rounded,
      rating: '8.7',
    ),
    MediaItem(
      title: '铁道少女',
      subtitle: '全 24 集',
      year: '2025',
      colors: [Color(0xFF9A665C), Color(0xFFD6AA85)],
      icon: Icons.tram_rounded,
      rating: '8.3',
    ),
  ];

  static const variety = <MediaItem>[
    MediaItem(
      title: '山野厨房',
      subtitle: '第 3 季',
      year: '2026',
      colors: [Color(0xFF607647), Color(0xFFC5A866)],
      icon: Icons.outdoor_grill_rounded,
      rating: '8.4',
    ),
    MediaItem(
      title: '周末去远方',
      subtitle: '更新至 10 期',
      year: '2026',
      colors: [Color(0xFF4C7D87), Color(0xFFB77B58)],
      icon: Icons.map_rounded,
      rating: '8.1',
    ),
    MediaItem(
      title: '书中自有答案',
      subtitle: '第 2 季',
      year: '2025',
      colors: [Color(0xFF765B48), Color(0xFFC1A582)],
      icon: Icons.menu_book_rounded,
      rating: '8.6',
    ),
    MediaItem(
      title: '音乐漫游记',
      subtitle: '更新至 6 期',
      year: '2026',
      colors: [Color(0xFF5E4C70), Color(0xFFB1838D)],
      icon: Icons.music_note_rounded,
      rating: '8.2',
    ),
  ];

  static const sources = <MediaSource>[
    MediaSource(
      name: '我的影音库',
      address: 'https://dav.example.com/video',
      username: 'demo@framelet.local',
      directory: '/Movies',
      lastSync: '今天 10:30',
    ),
  ];
}
