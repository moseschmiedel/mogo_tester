"""SHA-256 digest, used to derive collision-free artifact names."""

comptime _K: List[UInt32] = [
    0x428A2F98,
    0x71374491,
    0xB5C0FBCF,
    0xE9B5DBA5,
    0x3956C25B,
    0x59F111F1,
    0x923F82A4,
    0xAB1C5ED5,
    0xD807AA98,
    0x12835B01,
    0x243185BE,
    0x550C7DC3,
    0x72BE5D74,
    0x80DEB1FE,
    0x9BDC06A7,
    0xC19BF174,
    0xE49B69C1,
    0xEFBE4786,
    0x0FC19DC6,
    0x240CA1CC,
    0x2DE92C6F,
    0x4A7484AA,
    0x5CB0A9DC,
    0x76F988DA,
    0x983E5152,
    0xA831C66D,
    0xB00327C8,
    0xBF597FC7,
    0xC6E00BF3,
    0xD5A79147,
    0x06CA6351,
    0x14292967,
    0x27B70A85,
    0x2E1B2138,
    0x4D2C6DFC,
    0x53380D13,
    0x650A7354,
    0x766A0ABB,
    0x81C2C92E,
    0x92722C85,
    0xA2BFE8A1,
    0xA81A664B,
    0xC24B8B70,
    0xC76C51A3,
    0xD192E819,
    0xD6990624,
    0xF40E3585,
    0x106AA070,
    0x19A4C116,
    0x1E376C08,
    0x2748774C,
    0x34B0BCB5,
    0x391C0CB3,
    0x4ED8AA4A,
    0x5B9CCA4F,
    0x682E6FF3,
    0x748F82EE,
    0x78A5636F,
    0x84C87814,
    0x8CC70208,
    0x90BEFFFA,
    0xA4506CEB,
    0xBEF9A3F7,
    0xC67178F2,
]


def _rotr(x: UInt32, n: UInt32) -> UInt32:
    return (x >> n) | (x << (32 - n))


def sha256(data: Span[UInt8, _]) -> List[UInt8]:
    """Returns the 32-byte SHA-256 digest of data."""
    var k = materialize[_K]()
    var h: List[UInt32] = [
        0x6A09E667,
        0xBB67AE85,
        0x3C6EF372,
        0xA54FF53A,
        0x510E527F,
        0x9B05688C,
        0x1F83D9AB,
        0x5BE0CD19,
    ]

    var message = List[UInt8](capacity=len(data) + 72)
    for b in data:
        message.append(b)
    message.append(0x80)
    while len(message) % 64 != 56:
        message.append(0)
    var bit_len = UInt64(len(data)) * 8
    for i in range(8):
        message.append(UInt8((bit_len >> UInt64(56 - 8 * i)) & 0xFF))

    var w = List[UInt32](length=64, fill=0)
    for chunk in range(0, len(message), 64):
        for t in range(16):
            var j = chunk + 4 * t
            w[t] = (
                (UInt32(message[j]) << 24)
                | (UInt32(message[j + 1]) << 16)
                | (UInt32(message[j + 2]) << 8)
                | UInt32(message[j + 3])
            )
        for t in range(16, 64):
            var s0 = (
                _rotr(w[t - 15], 7) ^ _rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
            )
            var s1 = (
                _rotr(w[t - 2], 17) ^ _rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
            )
            w[t] = w[t - 16] + s0 + w[t - 7] + s1

        var a = h[0]
        var b = h[1]
        var c = h[2]
        var d = h[3]
        var e = h[4]
        var f = h[5]
        var g = h[6]
        var hh = h[7]
        for t in range(64):
            var s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25)
            var ch = (e & f) ^ (~e & g)
            var temp1 = hh + s1 + ch + k[t] + w[t]
            var s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22)
            var maj = (a & b) ^ (a & c) ^ (b & c)
            var temp2 = s0 + maj
            hh = g
            g = f
            f = e
            e = d + temp1
            d = c
            c = b
            b = a
            a = temp1 + temp2
        h[0] += a
        h[1] += b
        h[2] += c
        h[3] += d
        h[4] += e
        h[5] += f
        h[6] += g
        h[7] += hh

    var digest = List[UInt8](capacity=32)
    for i in range(8):
        for shift in [24, 16, 8, 0]:
            digest.append(UInt8((h[i] >> UInt32(shift)) & 0xFF))
    return digest^


def hex_encode(data: Span[UInt8, _]) -> String:
    """Returns lowercase hexadecimal text for data."""
    comptime digits = "0123456789abcdef"
    var out = String(capacity_bytes=len(data) * 2)
    for b in data:
        out += digits[byte=Int(b >> 4)]
        out += digits[byte=Int(b & 0xF)]
    return out^
