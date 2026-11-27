extends DrivePolicy
## Sakura Rally: the race driver's network, evaluated in 4x4 blocks (Game-development-3rd-party, MIT).
##
## The same network as DrivePolicy (a tanh MLP, here 46 -> 128 -> 128 -> 12) and the same
## weights; only the arithmetic is batched. DrivePolicy.logits() walks every weight in a GDScript
## loop: about 24,000 multiply-adds per decision, each one an interpreted step, which made one
## decision about 0.9 ms on a desktop and several on a phone, sixty times a second in a race.
## Here the weights are packed once into 4x4 blocks (Projection) and the inputs into 4-vectors
## (Vector4), so one interpreted step does 16 multiply-adds in native code: about 1,500 steps a
## decision instead of 24,000. The sums run in 32-bit floats (DrivePolicy sums in 64-bit and
## stores 32-bit values between layers), so the logits agree to about 1e-5 and the chosen
## options are the same except at an exact tie (checked in CI: mobile/ci/race_check.gd).
##
## Use: var f := FastPolicy.new(); f.adopt(DrivePolicy.load_file(path)). act() is DrivePolicy's
## own, it only calls the faster logits().

## Per layer: Array[Projection] (output block major, then input block), Array[Vector4] biases and
## an Array[Vector4] output buffer; the input blocks of every layer.
var _mats: Array = []
var _bias: Array = []
var _bufs: Array = []
var _blocks_in := PackedInt32Array()
var _out_count: int = 0
var _pad := PackedFloat32Array()
var _input: Array[Vector4] = []


## Takes over a loaded policy's layout and weights and packs them. The original stays usable.
func adopt(p: DrivePolicy) -> void:
	path = p.path
	obs_size = p.obs_size
	action_dims = p.action_dims
	layers = p.layers
	meta = p.meta
	_buf_a = p._buf_a.duplicate()
	_buf_b = p._buf_b.duplicate()
	_mats.clear()
	_bias.clear()
	_bufs.clear()
	_blocks_in.clear()
	for l: Dictionary in layers:
		var n_in: int = l["in"]
		var n_out: int = l["out"]
		var w: PackedFloat32Array = l["w"]
		var b: PackedFloat32Array = l["b"]
		var bi := (n_in + 3) / 4
		var bo := (n_out + 3) / 4
		var mats: Array[Projection] = []
		var bias: Array[Vector4] = []
		for ob in bo:
			var o0 := ob * 4
			bias.append(Vector4(_at(b, o0, n_out), _at(b, o0 + 1, n_out), _at(b, o0 + 2, n_out), _at(b, o0 + 3, n_out)))
			for ib in bi:
				# Projection * Vector4: result[r] = sum over c of column c [r] * v[c], so column c
				# holds input (ib*4 + c)'s weights into outputs o0 .. o0+3.
				var cols: Array[Vector4] = []
				for c in 4:
					var i := ib * 4 + c
					cols.append(Vector4(_w(w, o0, i, n_in, n_out), _w(w, o0 + 1, i, n_in, n_out),
							_w(w, o0 + 2, i, n_in, n_out), _w(w, o0 + 3, i, n_in, n_out)))
				mats.append(Projection(cols[0], cols[1], cols[2], cols[3]))
		var buf: Array[Vector4] = []
		buf.resize(bo)
		buf.fill(Vector4.ZERO)
		_mats.append(mats)
		_bias.append(bias)
		_bufs.append(buf)
		_blocks_in.append(bi)
	_out_count = int(layers[layers.size() - 1]["out"]) if not layers.is_empty() else 0
	_pad.resize(_blocks_in[0] * 4 if not _blocks_in.is_empty() else 0)
	_pad.fill(0.0)
	_input.resize(_blocks_in[0] if not _blocks_in.is_empty() else 0)
	_input.fill(Vector4.ZERO)


static func _at(b: PackedFloat32Array, o: int, n: int) -> float:
	return b[o] if o < n else 0.0


static func _w(w: PackedFloat32Array, o: int, i: int, n_in: int, n_out: int) -> float:
	return w[o * n_in + i] if o < n_out and i < n_in else 0.0


## The network's output for one observation, as DrivePolicy.logits().
func logits(obs: PackedFloat32Array) -> PackedFloat32Array:
	if _mats.is_empty():
		return super.logits(obs)
	for i in obs_size:
		_pad[i] = obs[i]
	var x: Array[Vector4] = _input
	for k in x.size():
		var j := k * 4
		x[k] = Vector4(_pad[j], _pad[j + 1], _pad[j + 2], _pad[j + 3])
	var last := _mats.size() - 1
	for li in _mats.size():
		var mats: Array[Projection] = _mats[li]
		var bias: Array[Vector4] = _bias[li]
		var y: Array[Vector4] = _bufs[li]
		var bi: int = _blocks_in[li]
		var m := 0
		for o in y.size():
			var acc: Vector4 = bias[o]
			for i in bi:
				acc += mats[m] * x[i]
				m += 1
			if li != last:
				acc = Vector4(tanh(acc.x), tanh(acc.y), tanh(acc.z), tanh(acc.w))
			y[o] = acc
		x = y
	var out := PackedFloat32Array()
	out.resize(_out_count)
	for o in _out_count:
		out[o] = x[o >> 2][o & 3]
	return out
