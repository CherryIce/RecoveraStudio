import 'package:flutter_test/flutter_test.dart';
import 'package:recovera_studio/features/recovery/data/disk_discovery_service.dart';

void main() {
  test('derives the physical startup disk from APFS physical stores', () {
    final identifiers = MacOSDiskIdentity.startupPhysicalDiskIdentifiers(
      <String, Object?>{
        'ParentWholeDisk': 'disk3',
        'APFSPhysicalStores': <Object?>[
          <String, Object?>{'APFSPhysicalStore': 'disk0s2'},
        ],
      },
    );

    expect(identifiers, containsAll(<String>{'disk0', 'disk3'}));
  });
}
