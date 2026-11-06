/// Strict, minimal ASN.1 DER writer and reader used by `cert_factory.dart` and `key_identity.dart`
/// (docs/plans/inc3.md D2, risk R4). The reader parses attacker-controlled certificates, so it
/// accepts only canonical DER:
///  * definite lengths only, shortest form, at most 4 length bytes, never beyond the input;
///  * single-byte tags (no high-tag-number form);
///  * minimal INTEGER, DER BOOLEAN, BIT STRING with zero padding bits, OID without leading 0x80
///    arc bytes and with arcs below 2^35, UTCTime/GeneralizedTime in the exact RFC 5280 shapes;
///  * a nesting-depth cap, a caller-set size cap, and no trailing bytes.
/// Every failure is a [DerException] with a fixed message that never contains input bytes.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Thrown for any non-canonical or malformed DER. The message is a fixed phrase.
class DerException implements Exception {
  const DerException(this.message);
  final String message;
  @override
  String toString() => 'DerException: $message';
}

/// Single-byte identifier octets used by the certificate profile.
abstract final class DerTag {
  static const int boolean = 0x01;
  static const int integer = 0x02;
  static const int bitString = 0x03;
  static const int octetString = 0x04;
  static const int nullTag = 0x05;
  static const int oid = 0x06;
  static const int utf8String = 0x0c;
  static const int printableString = 0x13;
  static const int utcTime = 0x17;
  static const int generalizedTime = 0x18;
  static const int sequence = 0x30;
  static const int set = 0x31;

  /// `[n] EXPLICIT` (context-specific, constructed), n in 0..30.
  static int explicit(int n) => 0xa0 | n;
}

/// Nesting depth a reader will descend before refusing (certificates need about 6).
const int kDerMaxDepth = 16;

// ---------------------------------------------------------------- writer

Uint8List _lengthBytes(int len) {
  if (len < 0) throw ArgumentError.value(len, 'len');
  if (len < 0x80) return Uint8List.fromList([len]);
  final out = <int>[];
  var v = len;
  while (v > 0) {
    out.insert(0, v & 0xFF);
    v >>= 8;
  }
  if (out.length > 4) throw ArgumentError.value(len, 'len', 'too long');
  return Uint8List.fromList([0x80 | out.length, ...out]);
}

/// One TLV with a single-byte [tag] and definite length.
Uint8List derTlv(int tag, List<int> content) {
  final length = _lengthBytes(content.length);
  final out = Uint8List(1 + length.length + content.length);
  out[0] = tag;
  out.setRange(1, 1 + length.length, length);
  out.setRange(1 + length.length, out.length, content);
  return out;
}

/// Concatenation of already-encoded parts.
Uint8List derConcat(Iterable<List<int>> parts) {
  final b = BytesBuilder(copy: false);
  for (final p in parts) {
    b.add(p);
  }
  return b.takeBytes();
}

Uint8List derSequence(Iterable<List<int>> items) =>
    derTlv(DerTag.sequence, derConcat(items));

Uint8List derSet(Iterable<List<int>> items) =>
    derTlv(DerTag.set, derConcat(items));

/// `[n] EXPLICIT` wrapper around an already-encoded [inner] element.
Uint8List derExplicit(int n, List<int> inner) =>
    derTlv(DerTag.explicit(n), inner);

/// Non-negative INTEGER in minimal two's-complement form.
Uint8List derInteger(BigInt v) {
  if (v.isNegative) throw ArgumentError.value('negative', 'v');
  if (v == BigInt.zero) return derTlv(DerTag.integer, const [0]);
  final bytes = <int>[];
  var x = v;
  while (x > BigInt.zero) {
    bytes.insert(0, (x & BigInt.from(0xFF)).toInt());
    x >>= 8;
  }
  if (bytes.first & 0x80 != 0) bytes.insert(0, 0);
  return derTlv(DerTag.integer, bytes);
}

Uint8List derBoolean(bool v) => derTlv(DerTag.boolean, [v ? 0xFF : 0x00]);

Uint8List derNull() => derTlv(DerTag.nullTag, const []);

Uint8List derOctetString(List<int> bytes) => derTlv(DerTag.octetString, bytes);

/// BIT STRING with [unusedBits] (0..7) padding bits in the last byte.
Uint8List derBitString(List<int> bytes, {int unusedBits = 0}) {
  if (unusedBits < 0 || unusedBits > 7) {
    throw ArgumentError.value(unusedBits, 'unusedBits');
  }
  if (bytes.isEmpty && unusedBits != 0) {
    throw ArgumentError.value(unusedBits, 'unusedBits', 'no data bytes');
  }
  return derTlv(DerTag.bitString, [unusedBits, ...bytes]);
}

Uint8List derUtf8String(String s) => derTlv(DerTag.utf8String, utf8.encode(s));

/// OBJECT IDENTIFIER from dotted text such as `1.2.840.10045.2.1`.
Uint8List derOid(String dotted) {
  final parts = dotted.split('.');
  if (parts.length < 2) throw ArgumentError.value(dotted, 'dotted');
  final arcs = <int>[];
  for (final p in parts) {
    if (p.isEmpty || !RegExp(r'^[0-9]+$').hasMatch(p) || p.length > 10) {
      throw ArgumentError.value(dotted, 'dotted');
    }
    arcs.add(int.parse(p));
  }
  if (arcs[0] > 2 || (arcs[0] < 2 && arcs[1] >= 40)) {
    throw ArgumentError.value(dotted, 'dotted');
  }
  final out = <int>[];
  void base128(int v) {
    final tmp = <int>[v & 0x7F];
    v >>= 7;
    while (v > 0) {
      tmp.insert(0, 0x80 | (v & 0x7F));
      v >>= 7;
    }
    out.addAll(tmp);
  }

  base128(arcs[0] * 40 + arcs[1]);
  for (final a in arcs.skip(2)) {
    base128(a);
  }
  return derTlv(DerTag.oid, out);
}

String _two(int v) => v.toString().padLeft(2, '0');

/// UTCTime for years 1950..2049, GeneralizedTime otherwise (RFC 5280 section 4.1.2.5).
/// Second precision, always `Z`.
Uint8List derTime(DateTime t) {
  final u = t.toUtc();
  final body =
      '${_two(u.month)}${_two(u.day)}${_two(u.hour)}${_two(u.minute)}${_two(u.second)}Z';
  if (u.year >= 1950 && u.year < 2050) {
    return derTlv(DerTag.utcTime, ascii.encode('${_two(u.year % 100)}$body'));
  }
  return derTlv(
    DerTag.generalizedTime,
    ascii.encode('${u.year.toString().padLeft(4, '0')}$body'),
  );
}

// ---------------------------------------------------------------- reader

/// One parsed TLV. [content] and [encoded] are views into the original input.
final class DerElement {
  DerElement._(this.tag, this.content, this.encoded, this._depth);

  final int tag;
  final Uint8List content;

  /// The complete TLV, header included (what a signature or a hash covers).
  final Uint8List encoded;
  final int _depth;

  bool get isConstructed => (tag & 0x20) != 0;

  /// Reader over the children of a constructed element.
  DerReader reader() {
    if (!isConstructed) throw const DerException('element is not constructed');
    if (_depth + 1 > kDerMaxDepth) {
      throw const DerException('nesting too deep');
    }
    return DerReader._(content, _depth + 1);
  }

  void _need(int expected) {
    if (tag != expected) throw const DerException('unexpected tag');
  }

  /// Non-negative INTEGER, minimal encoding.
  BigInt asInteger() {
    _need(DerTag.integer);
    final c = content;
    if (c.isEmpty) throw const DerException('empty integer');
    if (c[0] & 0x80 != 0) throw const DerException('negative integer');
    if (c.length > 1 && c[0] == 0 && c[1] & 0x80 == 0) {
      throw const DerException('non-minimal integer');
    }
    var v = BigInt.zero;
    for (final b in c) {
      v = (v << 8) | BigInt.from(b);
    }
    return v;
  }

  bool asBoolean() {
    _need(DerTag.boolean);
    if (content.length != 1) throw const DerException('bad boolean length');
    if (content[0] == 0x00) return false;
    if (content[0] == 0xFF) return true;
    throw const DerException('non-DER boolean');
  }

  void expectNull() {
    _need(DerTag.nullTag);
    if (content.isNotEmpty) throw const DerException('NULL with content');
  }

  Uint8List asOctetString() {
    _need(DerTag.octetString);
    return content;
  }

  /// BIT STRING: [unusedBits] padding bits (0..7), all zero.
  ({Uint8List bytes, int unusedBits}) asBitString() {
    _need(DerTag.bitString);
    if (content.isEmpty) throw const DerException('empty bit string');
    final unused = content[0];
    if (unused > 7) throw const DerException('bad bit string padding');
    final data = Uint8List.sublistView(content, 1);
    if (data.isEmpty && unused != 0) {
      throw const DerException('bad bit string padding');
    }
    if (data.isNotEmpty && data.last & ((1 << unused) - 1) != 0) {
      throw const DerException('non-zero bit string padding');
    }
    return (bytes: data, unusedBits: unused);
  }

  /// OBJECT IDENTIFIER as dotted text. Arcs are limited to below 2^35.
  String asOid() {
    _need(DerTag.oid);
    final c = content;
    if (c.isEmpty) throw const DerException('empty OID');
    final arcs = <int>[];
    var i = 0;
    while (i < c.length) {
      if (c[i] == 0x80) throw const DerException('non-minimal OID arc');
      var v = 0;
      var n = 0;
      while (true) {
        if (i >= c.length) throw const DerException('truncated OID');
        final b = c[i++];
        n++;
        if (n > 5) throw const DerException('OID arc too large');
        v = (v << 7) | (b & 0x7F);
        if (b & 0x80 == 0) break;
      }
      arcs.add(v);
    }
    final first = arcs[0];
    final head = first < 40
        ? [0, first]
        : first < 80
        ? [1, first - 40]
        : [2, first - 80];
    return [...head, ...arcs.skip(1)].join('.');
  }

  /// UTF8String or PrintableString.
  String asString() {
    if (tag == DerTag.utf8String) {
      try {
        return utf8.decode(content);
      } on FormatException {
        throw const DerException('invalid UTF-8');
      }
    }
    if (tag == DerTag.printableString) {
      for (final b in content) {
        final ok =
            (b >= 0x41 && b <= 0x5A) ||
            (b >= 0x61 && b <= 0x7A) ||
            (b >= 0x30 && b <= 0x39) ||
            " '()+,-./:=?".codeUnits.contains(b);
        if (!ok) throw const DerException('invalid PrintableString');
      }
      return ascii.decode(content);
    }
    throw const DerException('unexpected tag');
  }

  /// UTCTime (`YYMMDDHHMMSSZ`) or GeneralizedTime (`YYYYMMDDHHMMSSZ`, years from 2050 only).
  DateTime asTime() {
    final isUtc = tag == DerTag.utcTime;
    if (!isUtc && tag != DerTag.generalizedTime) {
      throw const DerException('unexpected tag');
    }
    final want = isUtc ? 13 : 15;
    if (content.length != want || content.last != 0x5A) {
      throw const DerException('malformed time');
    }
    final digits = content.sublist(0, want - 1);
    if (digits.any((b) => b < 0x30 || b > 0x39)) {
      throw const DerException('malformed time');
    }
    int num(int from, int len) {
      var v = 0;
      for (var i = from; i < from + len; i++) {
        v = v * 10 + (digits[i] - 0x30);
      }
      return v;
    }

    int year;
    var p = 0;
    if (isUtc) {
      final yy = num(0, 2);
      year = yy >= 50 ? 1900 + yy : 2000 + yy;
      p = 2;
    } else {
      year = num(0, 4);
      if (year < 2050) throw const DerException('malformed time');
      p = 4;
    }
    final month = num(p, 2);
    final day = num(p + 2, 2);
    final hour = num(p + 4, 2);
    final minute = num(p + 6, 2);
    final second = num(p + 8, 2);
    if (month < 1 ||
        month > 12 ||
        day < 1 ||
        hour > 23 ||
        minute > 59 ||
        second > 59) {
      throw const DerException('malformed time');
    }
    final t = DateTime.utc(year, month, day, hour, minute, second);
    if (t.month != month || t.day != day) {
      throw const DerException('malformed time');
    }
    return t;
  }
}

/// Sequential reader over the concatenated TLVs of one level.
final class DerReader {
  DerReader._(this._data, this._depth);

  final Uint8List _data;
  final int _depth;
  int _pos = 0;

  bool get atEnd => _pos >= _data.length;

  /// Tag of the next element without consuming it; null at the end.
  int? peekTag() => atEnd ? null : _data[_pos];

  DerElement read() {
    if (atEnd) throw const DerException('unexpected end');
    final start = _pos;
    final tag = _data[_pos++];
    if (tag == 0x00 || (tag & 0x1F) == 0x1F) {
      throw const DerException('unsupported tag');
    }
    if (_pos >= _data.length) throw const DerException('truncated length');
    final first = _data[_pos++];
    int len;
    if (first < 0x80) {
      len = first;
    } else {
      if (first == 0x80) throw const DerException('indefinite length');
      final n = first & 0x7F;
      if (first == 0xFF || n > 4) throw const DerException('length too large');
      if (_pos + n > _data.length) {
        throw const DerException('truncated length');
      }
      if (_data[_pos] == 0) throw const DerException('non-minimal length');
      len = 0;
      for (var i = 0; i < n; i++) {
        len = (len << 8) | _data[_pos++];
      }
      if (len < 0x80) throw const DerException('non-minimal length');
    }
    if (len > _data.length - _pos) {
      throw const DerException('length exceeds input');
    }
    final content = Uint8List.sublistView(_data, _pos, _pos + len);
    _pos += len;
    final encoded = Uint8List.sublistView(_data, start, _pos);
    return DerElement._(tag, content, encoded, _depth);
  }

  /// Reads the next element and requires [tag].
  DerElement expect(int tag) {
    final e = read();
    if (e.tag != tag) throw const DerException('unexpected tag');
    return e;
  }

  /// Reads the next element only when its tag is [tag]; otherwise leaves it.
  DerElement? readOptional(int tag) => peekTag() == tag ? read() : null;

  /// Requires that nothing is left (no trailing members).
  void finish() {
    if (!atEnd) throw const DerException('trailing data');
  }
}

/// Parses exactly one top-level element from [data]: rejects input above [maxBytes] and any
/// trailing bytes.
DerElement derParseSingle(Uint8List data, {int maxBytes = 4096}) {
  if (data.length > maxBytes) throw const DerException('input too large');
  final r = DerReader._(data, 0);
  final e = r.read();
  r.finish();
  return e;
}
