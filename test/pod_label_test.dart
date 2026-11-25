import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_rig/models.dart';

void main() {
  Seat seat(String logicalId, {String? ns}) =>
      Seat.fromJson({'logicalId': logicalId, 'podId': '01M6B9G0N99N', 'podNamespace': ns});

  test('pods read by namespace, then the logical id prefix, then the raw id', () {
    expect(seat('core.lead', ns: 'eng').podLabel, 'eng');
    expect(seat('core.lead').podLabel, 'core');
    expect(seat('solo').podLabel, '01M6B9G0N99N');
  });
}
