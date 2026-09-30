import 'package:flutter_test/flutter_test.dart';
import 'package:recovera_studio/features/recovery/data/apple_property_list.dart';

void main() {
  test('parses diskutil dictionary, arrays, numbers, and booleans', () {
    const source = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
  <dict>
    <key>AllDisksAndPartitions</key>
    <array>
      <dict>
        <key>DeviceIdentifier</key>
        <string>disk4</string>
        <key>Size</key>
        <integer>64000000000</integer>
        <key>OSInternal</key>
        <false/>
        <key>Partitions</key>
        <array/>
      </dict>
    </array>
  </dict>
</plist>
''';

    final root = ApplePropertyList.parseDictionary(source);
    final disks = root['AllDisksAndPartitions'] as List<Object?>;
    final disk = disks.single as Map<String, Object?>;

    expect(disk['DeviceIdentifier'], 'disk4');
    expect(disk['Size'], 64000000000);
    expect(disk['OSInternal'], isFalse);
    expect(disk['Partitions'], isEmpty);
  });

  test('rejects a non-dictionary plist root', () {
    const source =
        '<plist version="1.0"><array><string>disk0</string></array></plist>';

    expect(
      () => ApplePropertyList.parseDictionary(source),
      throwsA(isA<FormatException>()),
    );
  });
}
