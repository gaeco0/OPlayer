import 'dart:ffi';

const _asset = 'package:ai_frame_engine/engine.dart';

@Native<Pointer<Void> Function(Pointer<Char>, Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>, Int)>(
  assetId: _asset,
  symbol: 'oplayer_rife_start',
)
external Pointer<Void> start(
  Pointer<Char> path,
  Pointer<Void> mpv,
  Pointer<Void> get,
  Pointer<Void> command,
  Pointer<Void> freeNode,
  int preferNpu,
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

@Native<Int Function(Pointer<Char>, Pointer<Char>, Pointer<Char>, Pointer<Char>)>(
  assetId: _asset,
  symbol: 'oplayer_npu_vendor',
)
external int npuVendor(Pointer<Char> maker, Pointer<Char> soc, Pointer<Char> hardware, Pointer<Char> board);

@Native<Int Function(Int, Pointer<Char>, Int)>(assetId: _asset, symbol: 'oplayer_npu_driver_allowed')
external int npuDriverAllowed(int vendor, Pointer<Char> name, int type);

@Native<Pointer<Void> Function(Pointer<Char>, Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>, Int, Int)>(
  assetId: _asset,
  symbol: 'oplayer_upscale_start',
)
external Pointer<Void> upscaleStart(
  Pointer<Char> path,
  Pointer<Void> mpv,
  Pointer<Void> get,
  Pointer<Void> command,
  Pointer<Void> freeNode,
  int w,
  int h,
);
@Native<Int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Int>, Pointer<Double>, Int)>(
  assetId: _asset,
  symbol: 'oplayer_upscale_poll',
)
external int upscalePoll(
  Pointer<Void> engine,
  Pointer<Uint8> pixels,
  Pointer<Int> info,
  Pointer<Double> timing,
  int blend,
);
@Native<Void Function(Pointer<Void>)>(assetId: _asset, symbol: 'oplayer_upscale_stop')
external void upscaleStop(Pointer<Void> engine);
@Native<Int Function(Pointer<Void>)>(assetId: _asset, symbol: 'oplayer_upscale_finished')
external int upscaleFinished(Pointer<Void> engine);
@Native<Void Function(Pointer<Void>)>(assetId: _asset, symbol: 'oplayer_upscale_destroy')
external void upscaleDestroy(Pointer<Void> engine);
@Native<Int Function(Pointer<Char>, Pointer<Uint8>, Pointer<Uint8>, Int, Int)>(
  assetId: _asset,
  symbol: 'oplayer_upscale_reference',
)
external int upscaleReference(Pointer<Char> path, Pointer<Uint8> input, Pointer<Uint8> output, int w, int h);
