import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/utils/high_quality_playback.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

PlayUrlModel _playUrl(List<int> ids) => PlayUrlModel.fromJson({
  'dash': {
    'duration': 0,
    'video': [
      for (final id in ids)
        {'id': id, 'codecs': VideoDecodeFormatType.AV1.codes.first},
    ],
  },
  'accept_quality': ids,
  'support_formats': [
    for (final id in ids)
      {'quality': id, 'codecs': VideoDecodeFormatType.AV1.codes},
  ],
});

void main() {
  group('maskCookie', () {
    test('masks values but keeps keys', () {
      expect(
        HighQualityPlayback.maskCookie(
          'SESSDATA=abc123; bili_jct=xyz; DedeUserID=42',
        ),
        'SESSDATA=***; bili_jct=***; DedeUserID=***',
      );
    });

    test('empty cookie', () {
      expect(HighQualityPlayback.maskCookie(''), '');
    });

    test('segments without = are kept as-is', () {
      expect(HighQualityPlayback.maskCookie('foo; bar'), 'foo; bar');
    });
  });

  group('prettyMasked', () {
    test('masks cookie/csrf/money and shortens mid', () {
      final out = HighQualityPlayback.prettyMasked({
        'ui': {
          'ua': 'UA',
          'mid': '12345678',
          'vip': 1,
          'level': 6,
          'money': 99.5,
          'cookie': 'SESSDATA=secret; bili_jct=tok',
          'csrf': 'tok',
        },
        'url': 'https://api.bilibili.com/x?foo=bar',
      });
      expect(out, contains('"cookie": "SESSDATA=***; bili_jct=***"'));
      expect(out, contains('"csrf": "***"'));
      expect(out, contains('"money": "***"'));
      expect(out, contains('"mid": "******78"'));
      expect(out, isNot(contains('secret')));
      expect(out, isNot(contains('tok')));
      expect(out, contains('https://api.bilibili.com/x?foo=bar'));
    });

    test('short mid is fully masked', () {
      final out = HighQualityPlayback.prettyMasked({
        'ui': {'mid': '7'},
        'url': 'u',
      });
      expect(out, contains('"mid": "***"'));
    });
  });

  group('isValidServer', () {
    test('accepts https (with or without trailing slash / spaces)', () {
      expect(HighQualityPlayback.isValidServer('https://example.com'), isTrue);
      expect(
        HighQualityPlayback.isValidServer(' https://example.com/ '),
        isTrue,
      );
    });

    test('rejects http, missing scheme, empty host and other schemes', () {
      expect(HighQualityPlayback.isValidServer('http://example.com'), isFalse);
      expect(HighQualityPlayback.isValidServer(''), isFalse);
      expect(HighQualityPlayback.isValidServer('example.com'), isFalse);
      expect(HighQualityPlayback.isValidServer('ftp://example.com'), isFalse);
    });
  });

  group('endpoint', () {
    test('appends /api/bzview2 with or without trailing slash', () {
      expect(
        HighQualityPlayback.endpoint('https://example.com'),
        'https://example.com/api/bzview2',
      );
      expect(
        HighQualityPlayback.endpoint('https://example.com/'),
        'https://example.com/api/bzview2',
      );
    });

    test('rejects plain http instead of leaking credentials', () {
      expect(
        () => HighQualityPlayback.endpoint('http://example.com'),
        throwsFormatException,
      );
    });
  });

  group('friendlyError', () {
    test('maps receiveTimeout to short Chinese text (no raw exception)', () {
      final e = DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.receiveTimeout,
      );
      final msg = HighQualityPlayback.friendlyError(e);
      expect(msg, contains('响应超时'));
      expect(msg, isNot(contains('DioException')));
    });

    test('maps connectionError', () {
      final e = DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.connectionError,
      );
      expect(HighQualityPlayback.friendlyError(e), contains('无法连接'));
    });

    test('FormatException message passes through', () {
      expect(
        HighQualityPlayback.friendlyError(const FormatException('坏地址')),
        '坏地址',
      );
    });

    test('unknown object falls back to generic text', () {
      expect(
        HighQualityPlayback.friendlyError(const Object()),
        '请求失败，请稍后重试',
      );
    });
  });

  group('clipDebug', () {
    test('short string unchanged', () {
      expect(HighQualityPlayback.clipDebug('abc'), 'abc');
    });

    test('long string truncated with marker', () {
      final out = HighQualityPlayback.clipDebug('a' * 9000);
      expect(out.length, lessThan(9000));
      expect(out, contains('已截断'));
      expect(out, contains('9000 字符'));
    });
  });

  group('trimToQualityCap', () {
    test('removes qualities above cap and updates quality', () {
      final playUrl = _playUrl([16, 64, 80, 116]);
      HighQualityPlayback.trimToQualityCap(playUrl, 80);
      expect(playUrl.acceptQuality, [16, 64, 80]);
      expect(playUrl.quality, 80);
      expect(playUrl.dash!.video!.map((e) => e.id).toList(), [16, 64, 80]);
      expect(
        playUrl.supportFormats!.map((e) => e.quality).toList(),
        [16, 64, 80],
      );
    });

    test('cap <= 0 is a no-op', () {
      final playUrl = _playUrl([16, 64, 80, 116]);
      HighQualityPlayback.trimToQualityCap(playUrl, 0);
      expect(playUrl.acceptQuality, [16, 64, 80, 116]);
    });
  });

  group('midFromCookie', () {
    test('reads DedeUserID', () {
      expect(
        HighQualityPlayback.midFromCookie('a=1; DedeUserID=12345; b=2'),
        12345,
      );
    });

    test('returns 0 when missing or invalid', () {
      expect(HighQualityPlayback.midFromCookie('a=1'), 0);
      expect(HighQualityPlayback.midFromCookie('DedeUserID=xx'), 0);
    });
  });

  group('randomSession', () {
    test('is 32 lowercase hex chars', () {
      final s = HighQualityPlayback.randomSession();
      expect(s, matches(RegExp(r'^[0-9a-f]{32}$')));
    });
  });
}
