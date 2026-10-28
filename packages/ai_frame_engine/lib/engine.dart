import 'dart:ffi';

const _asset = 'package:ai_frame_engine/engine.dart';

@Native<Pointer<Void> Function(Pointer<Char>, Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>)>(
  assetId: _asset,
  symbol: 'oplayer_rife_start',
)
external Pointer<Void> start(
  Pointer<Char> path,
  Pointer<Void> mpv,
  Pointer<Void> get,
  Pointer<Void> command,
  Pointer<Void> freeNode,
);

@Native<Int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Int>, Pointer<Double>)>(
  assetId: _asset,
  symbol: 'oplayer_rife_poll',
)
external int poll(Pointer<Void> engine, Pointer<Uint8> pixels, Pointer<Int> info, Pointer<Double> timing);

@Native<Void Function(Pointer<Void>)>(assetId: _asset, symbol: 'oplayer_rife_stop')
external void stop(Pointer<Void> engine);

@Native<Int Function(Pointer<Void>)>(assetId: _asset, symbol: 'oplayer_rife_finished')
external int finished(Pointer<Void> engine);

@Native<Void Function(Pointer<Void>)>(assetId: _asset, symbol: 'oplayer_rife_destroy')
external void destroy(Pointer<Void> engine);

@Native<Int Function(Pointer<Char>, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>, Int, Int, Int)>(
  assetId: _asset,
  symbol: 'oplayer_rife_probe',
)
external int probe(Pointer<Char> path, Pointer<Uint8> a, Pointer<Uint8> b, Pointer<Uint8> out, int w, int h, int gpu);
