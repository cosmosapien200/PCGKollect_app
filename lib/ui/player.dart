import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart' hide Interval;
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;

import '../core/protocol.dart';
import '../data/models.dart';
import '../services/dsp.dart';
import '../services/wav.dart';
import 'common.dart';

/// Playback of a recording with a quality timeline (spec 01 §9.2).
///
/// The timeline is always the ORIGINAL sample axis: waveform, green usable /
/// red unusable / grey unscored windows and the playhead. "Useful audio" plays only
/// usable beats (concatenated, mapped back to source time); "Enhance" plays a
/// 20–800 Hz band-passed copy. Both are rendered to a cache file — the stored
/// WAV is never modified and labels/statistics are unaffected.
class RecordingPlayer extends StatefulWidget {
  final String wavPath;
  final String cacheDir;
  final List<Interval> quality;
  final List<Interval> beats;
  const RecordingPlayer({super.key, required this.wavPath, required this.cacheDir, required this.quality, required this.beats});

  @override
  State<RecordingPlayer> createState() => _RecordingPlayerState();
}

class _RecordingPlayerState extends State<RecordingPlayer> {
  final _player = AudioPlayer();
  Int16List? _pcm;
  Float32List? _env;
  UsefulAudio? _useful;
  bool useful = false, enhance = false, loading = true;
  String? error;
  int _srcPos = 0; // current playhead on the source axis (samples)
  StreamSubscription<Duration>? _posSub;

  @override
  void initState() {
    super.initState();
    _load();
    _posSub = _player.positionStream.listen((d) {
      final dst = d.inMicroseconds * kSampleRate ~/ 1000000;
      setState(() => _srcPos = useful && _useful != null ? _useful!.toSource(dst) : dst);
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final bytes = await File(widget.wavPath).readAsBytes();
      final w = WavInfo.parse(bytes);
      _pcm = WavInfo.samples(bytes, w);
      _env = envelope(_pcm!, 600);
      _useful = buildUseful(_pcm!, usableRanges(widget.beats));
      await _prepare();
    } catch (e) {
      error = 'Cannot open audio: $e';
    }
    if (mounted) setState(() => loading = false);
  }

  /// Renders the selected variant and loads it into the player, keeping the source position.
  Future<void> _prepare() async {
    final keep = _srcPos;
    if (!useful && !enhance) {
      await _player.setFilePath(widget.wavPath); // the original, untouched file
    } else {
      setState(() => loading = true);
      var pcm = useful ? _useful!.pcm : _pcm!;
      if (enhance) pcm = bandpass(pcm);
      await Directory(widget.cacheDir).create(recursive: true);
      final f = File(p.join(widget.cacheDir, 'playback_${useful ? 'u' : 'o'}${enhance ? 'e' : ''}.wav'));
      await f.writeAsBytes(WavInfo.build(pcm), flush: true);
      await _player.setFilePath(f.path);
      setState(() => loading = false);
    }
    await _seekSource(keep);
  }

  Future<void> _seekSource(int src) async {
    final dst = useful && _useful != null ? _useful!.toPlayback(src) : src;
    await _player.seek(Duration(microseconds: dst * 1000000 ~/ kSampleRate));
    setState(() => _srcPos = src);
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) return Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error));
    final pcm = _pcm;
    if (pcm == null) return const SizedBox(height: 160, child: Center(child: CircularProgressIndicator()));
    final total = pcm.length;
    final cs = Theme.of(context).colorScheme;
    final noUseful = _useful == null || _useful!.pcm.isEmpty;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      LayoutBuilder(builder: (c, box) {
        void seekAt(double x) => _seekSource((x / box.maxWidth * total).clamp(0, total - 1).round());
        return GestureDetector(
          onTapDown: (d) => seekAt(d.localPosition.dx),
          onHorizontalDragUpdate: (d) => seekAt(d.localPosition.dx),
          child: CustomPaint(
            size: Size(box.maxWidth, 150),
            painter: _TimelinePainter(
              env: _env!,
              quality: widget.quality,
              useful: useful ? _useful!.map : null,
              total: total,
              pos: _srcPos,
              wave: cs.onSurface,
              playhead: cs.primary,
            ),
          ),
        );
      }),
      const SizedBox(height: 4),
      Wrap(spacing: 12, children: const [
        _Legend(Color(0xFF2E9E4F), 'usable'),
        _Legend(Color(0xFFD64545), 'unusable'),
        _Legend(Color(0xFF9E9E9E), 'unscored'),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        StreamBuilder<PlayerState>(
          stream: _player.playerStateStream,
          builder: (c, s) {
            final playing = s.data?.playing ?? false;
            final done = s.data?.processingState == ProcessingState.completed;
            return IconButton.filled(
              iconSize: 32,
              onPressed: loading
                  ? null
                  : () async {
                      if (done) await _seekSource(useful && _useful!.map.isNotEmpty ? _useful!.map.first.srcStart : 0);
                      playing ? _player.pause() : _player.play();
                    },
              icon: Icon(playing && !done ? Icons.pause : Icons.play_arrow),
            );
          },
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text('${fmtDuration(_srcPos / 8)} / ${fmtDuration(total / 8)}  (source time)',
              style: Theme.of(context).textTheme.bodyLarge),
        ),
      ]),
      Wrap(spacing: 8, children: [
        FilterChip(
          label: Text(noUseful ? 'Useful audio (none)' : 'Useful audio only (${fmtDuration(_useful!.pcm.length / 8)})'),
          selected: useful,
          onSelected: noUseful || loading
              ? null
              : (v) async {
                  setState(() => useful = v);
                  await _prepare();
                },
        ),
        FilterChip(
          label: const Text('Enhance 20–800 Hz'),
          selected: enhance,
          onSelected: loading
              ? null
              : (v) async {
                  setState(() => enhance = v);
                  await _prepare();
                },
        ),
      ]),
      if (useful || enhance)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            [
              if (useful) 'Playing usable beats only, joined in order (not the continuous recording).',
              if (enhance) 'Enhanced playback (band-pass filtered); the stored recording is unchanged.',
            ].join(' '),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.tertiary),
          ),
        ),
    ]);
  }
}

class _Legend extends StatelessWidget {
  final Color color;
  final String label;
  const _Legend(this.color, this.label);
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 12, height: 12, color: color),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ]);
}

class _TimelinePainter extends CustomPainter {
  final Float32List env;
  final List<Interval> quality;
  final List<Segment>? useful;
  final int total, pos;
  final Color wave, playhead;
  _TimelinePainter({required this.env, required this.quality, required this.useful, required this.total,
      required this.pos, required this.wave, required this.playhead});

  @override
  void paint(Canvas c, Size s) {
    const band = 16.0;
    final waveH = s.height - band - 6;
    double x(int sample) => sample / total * s.width;

    // dim the parts that are skipped in useful-audio playback
    if (useful != null) {
      c.drawRect(Rect.fromLTWH(0, 0, s.width, waveH), Paint()..color = wave.withValues(alpha: 0.06));
      for (final seg in useful!) {
        c.drawRect(Rect.fromLTRB(x(seg.srcStart), 0, x(seg.srcEnd), waveH),
            Paint()..color = const Color(0xFF2E9E4F).withValues(alpha: 0.18));
      }
    }
    // waveform (min/max columns)
    final n = env.length ~/ 2;
    final mid = waveH / 2;
    final wp = Paint()
      ..color = wave.withValues(alpha: 0.75)
      ..strokeWidth = 1;
    for (var i = 0; i < n; i++) {
      final px = i / n * s.width;
      c.drawLine(Offset(px, mid - env[2 * i + 1] * mid), Offset(px, mid - env[2 * i] * mid), wp);
    }
    // quality band on the sample axis; anything not covered is unscored (grey)
    final top = waveH + 6;
    c.drawRect(Rect.fromLTWH(0, top, s.width, band), Paint()..color = const Color(0xFF9E9E9E));
    for (final q in quality) {
      final color = switch (q.label) {
        'usable' => const Color(0xFF2E9E4F),
        'unusable' => const Color(0xFFD64545),
        _ => const Color(0xFF9E9E9E),
      };
      c.drawRect(Rect.fromLTRB(x(q.startSample), top, x(q.endSample) + 0.5, top + band), Paint()..color = color);
    }
    // playhead
    c.drawLine(Offset(x(pos), 0), Offset(x(pos), s.height), Paint()
      ..color = playhead
      ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_TimelinePainter o) => o.pos != pos || o.useful != useful || o.env != env;
}
