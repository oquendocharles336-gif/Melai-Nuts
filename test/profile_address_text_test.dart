import 'package:flutter_test/flutter_test.dart';
import 'package:melai_nuts/data/models/customer_profile.dart';
import 'package:melai_nuts/features/customer/screens/customer_profile_screen.dart';

const _address = CustomerAddress(
  id: 'a1',
  label: 'Home',
  recipientName: 'Test',
  phone: '+639171234567',
  line1: '12 Mabini St',
  city: 'Calamba',
  province: 'Laguna',
  postalCode: '4027',
  isDefault: true,
);

void main() {
  test('a saved address is shown, whatever the load state', () {
    for (final failed in [true, false]) {
      for (final loaded in [true, false]) {
        expect(
          deliveryAddressText(address: _address, loaded: loaded, failed: failed),
          '12 Mabini St, Calamba, Laguna 4027',
        );
      }
    }
  });

  test('it never claims none is saved before the addresses were read', () {
    expect(deliveryAddressText(address: null, loaded: false, failed: false), 'Loading your address...');
    expect(deliveryAddressText(address: null, loaded: false, failed: true), contains('Could not load'));
    expect(deliveryAddressText(address: null, loaded: true, failed: true), contains('Could not load'));
  });

  test('none saved is only said once they were read', () {
    expect(deliveryAddressText(address: null, loaded: true, failed: false), contains('No address saved'));
  });
}
