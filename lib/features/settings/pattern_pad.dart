import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Android-style 3x3 pattern, including unvisited intermediate dots.
List<int> extendPattern(List<int> pattern, int next) {
  if (next < 0 || next > 8 || pattern.contains(next)) return List.of(pattern);
  final result = List<int>.of(pattern);
  if (result.isNotEmpty) {
    final last = result.last;
    final dx = next % 3 - last % 3;
    final dy = next ~/ 3 - last ~/ 3;
    if ((dx.abs() == 2 && dy == 0) || (dy.abs() == 2 && dx == 0) || (dx.abs() == 2 && dy.abs() == 2)) {
      final middle = ((next ~/ 3 + last ~/ 3) ~/ 2) * 3 + ((next % 3 + last % 3) ~/ 2);
      if (!result.contains(middle)) result.add(middle);
    }
  }
  return result..add(next);
}

class PatternPad extends StatefulWidget {
  const PatternPad({super.key, required this.onCompleted, this.enabled = true});
  final ValueChanged<List<int>> onCompleted;
  final bool enabled;
  @override
  State<PatternPad> createState() => _PatternPadState();
}

class _PatternPadState extends State<PatternPad> {
  List<int> _points = [];
  Offset? _finger;
  void _touch(Offset position, double side) {
    var next = List<int>.of(_points);
    for (var i = 0; i < 9; i++) {
      final point = Offset((i % 3 + .5) * side / 3, (i ~/ 3 + .5) * side / 3);
      if ((point - position).distance < side / 12) {
        next = extendPattern(next, i);
        break;
      }
    }
    setState(() {
      _points = next;
      _finger = position;
    });
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: '패턴 입력 · 3행 3열 점을 4개 이상 연결',
    child: LayoutBuilder(
      builder: (_, constraints) {
        final side = math.min(280.0, constraints.maxWidth);
        return Center(
          child: SizedBox.square(
            dimension: side,
            child: IgnorePointer(
              ignoring: !widget.enabled,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanDown: (details) {
                  _points = [];
                  _touch(details.localPosition, side);
                },
                onPanStart: (details) => _touch(details.localPosition, side),
                onPanUpdate: (details) => _touch(details.localPosition, side),
                onPanEnd: (_) {
                  final result = List<int>.of(_points);
                  setState(() {
                    _points = [];
                    _finger = null;
                  });
                  widget.onCompleted(result);
                },
                onPanCancel: () => setState(() {
                  _points = [];
                  _finger = null;
                }),
                child: CustomPaint(painter: _PatternPainter(_points, _finger, Theme.of(context).colorScheme.primary)),
              ),
            ),
          ),
        );
      },
    ),
  );
}

class _PatternPainter extends CustomPainter {
  _PatternPainter(this.points, this.finger, this.color);
  final List<int> points;
  final Offset? finger;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    Offset point(int i) => Offset((i % 3 + .5) * size.width / 3, (i ~/ 3 + .5) * size.height / 3);
    final line = Paint()
      ..color = color
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    for (var i = 1; i < points.length; i++) {
      canvas.drawLine(point(points[i - 1]), point(points[i]), line);
    }
    if (points.isNotEmpty && finger != null) canvas.drawLine(point(points.last), finger!, line);
    for (var i = 0; i < 9; i++) {
      canvas.drawCircle(
        point(i),
        points.contains(i) ? 12 : 8,
        Paint()..color = points.contains(i) ? color : Colors.grey,
      );
    }
  }

  @override
  bool shouldRepaint(_PatternPainter oldDelegate) => true;
}
