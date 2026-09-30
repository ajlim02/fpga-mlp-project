"""Reproducible synthetic parameters, with an independent integer MLP reference.

Run from any directory. These are verification fixtures, not trained SOH weights.
Weight words use 8 lanes and a 16-address stride for EVERY neuron group.
"""
from pathlib import Path
import random

OUT = Path(__file__).resolve().parent / 'mem'
OUT.mkdir(exist_ok=True)
rng = random.Random(20260930)
weights = [[[rng.randint(-16, 16) for _ in range(ni)] for _ in range(no)]
           for ni, no in [(5, 16), (16, 8), (8, 1)]]
biases = [[rng.randint(-512, 512) for _ in range(no)] for no in (16, 8, 1)]
biases[2][0] = -70000  # Detect accidental 16-bit truncation at the top boundary.

def pack(values, width):
    return sum((v & ((1 << width) - 1)) << (i * width) for i, v in enumerate(values))

def write_hex(name, values, digits):
    (OUT / name).write_text(''.join(f'{v:0{digits}x}\n' for v in values), encoding='ascii')

for layer, (ws, bs) in enumerate(zip(weights, biases), 1):
    wm, bm = [], []
    for group in range((len(ws) + 7) // 8):
        bm.append(pack([bs[n] if n < len(bs) else 0 for n in range(group*8, group*8+8)], 32))
        for f in range(16):
            wm.append(pack([ws[n][f] if n < len(ws) and f < len(ws[n]) else 0
                            for n in range(group*8, group*8+8)], 8))
    write_hex(f'wmem_l{layer}.mem', wm, 16)
    write_hex(f'bmem_l{layer}.mem', bm, 64)

def infer(features):
    for layer, (ws, bs) in enumerate(zip(weights, biases)):
        features = [b + sum(x*w for x, w in zip(features, row)) for row, b in zip(ws, bs)]
        if layer < 2:
            features = [min(127, (max(0, x) + 8) // 16) for x in features]
    return features[0] & 0xffffffff

vectors = [[0]*5, [127]*5, [-128]*5, [-128,127,-1,0,18], [-91,90,-52,51,-106]]
vectors += [[rng.randint(-128,127) for _ in range(5)] for _ in range(19)]
write_hex('features.mem', [pack(v,8) for v in vectors], 10)
write_hex('expected.mem', [infer(v) for v in vectors], 8)
assert len(set(infer(v) for v in vectors)) > 10
print(f'Generated {len(vectors)} independent expected results and six parameter memories.')
